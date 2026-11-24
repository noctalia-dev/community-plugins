--!nonstrict
-- Caffeinate Plus service: the only entry that holds state. A port of the
-- Caffeine Spoon's init.lua. noctalia's built-in caffeine does the actual
-- inhibiting; this service decides when it should be on.
--
-- Ownership follows the Spoon: caffeine that was already on before we were
-- asked is left alone by timer expiry, screen lock and plugin disable. Only an
-- explicit "disable" turns it off regardless. The built-in caffeine holds a
-- logind idle inhibitor (who=noctalia, why=Caffeine), which is how we read it.

local C = require("./common.luau")

local LID_UNIT = "caffeinate-plus-lid.service"
local CHECK_CAFFEINE = "systemd-inhibit --list --no-pager --no-legend"
  .. " | grep -qE '^noctalia[[:space:]].*[[:space:]]idle[[:space:]]+Caffeine([[:space:]]|$)'"
-- Lid inhibitor in a transient user unit, after bagusk99/super-caffeine (MIT).
local LID_START = `systemctl --user reset-failed {LID_UNIT} >/dev/null 2>&1 || true; `
  .. `systemd-run --user --quiet --collect --unit={LID_UNIT} --description='Caffeinate Plus lid inhibitor' `
  .. `systemd-inhibit --what=handle-lid-switch --mode=block `
  .. `--who='Caffeinate Plus' --why='Keeping awake with the lid closed' sleep infinity`
local LID_STOP = `systemctl --user stop {LID_UNIT} >/dev/null 2>&1 || true`
local LID_CHECK = `systemctl --user is-active --quiet {LID_UNIT}`

local CAFFEINE_POLL_S = 5
local LOCK_POLL_S = 2
-- After we enable caffeine, its logind inhibitor can lag the IPC reply. Don't
-- read "not listed yet" as "turned off elsewhere" during this window.
local ENABLE_GRACE_S = 4

local active = false -- built-in caffeine is on (last observed)
local owned = false -- we turned it on (the Spoon's ownsDisplayIdle)
local session = false -- a keep-awake session we started (toggle on or timer)
local endsAt = nil -- unix seconds, when a timer is running
local lidEnabled = noctalia.getConfig("lid_inhibit") == true
local lidHeld = false
local lidBusy = false
local busy = 0 -- caffeine commands in flight
local graceUntil = 0
local lastCaffeinePoll = 0
local lastLockPoll = 0
local lockPollPending = false
local caffeinePollPending = false

local dataDir = noctalia.pluginDataDir()
local STATE_FILE = dataDir and (dataDir .. "/state.json") or nil

---- Publishing and persistence

local function remaining()
  if endsAt then
    return math.max(0, endsAt - os.time())
  end
  return nil
end

local function publish()
  noctalia.state.set(C.STATUS, {
    active = active,
    owned = owned,
    session = session,
    endsAt = endsAt,
    remaining = remaining(),
    lidEnabled = lidEnabled,
    lidHeld = lidHeld,
    busy = busy > 0,
  })
end

local function save()
  if not STATE_FILE then
    return
  end
  local body = noctalia.json.encode({
    owned = owned,
    session = session,
    endsAt = endsAt,
    lidEnabled = lidEnabled,
  })
  if body then
    noctalia.writeFile(STATE_FILE, body)
  end
end

local function load()
  if not STATE_FILE or not noctalia.fileExists(STATE_FILE) then
    return
  end
  local body = noctalia.readFile(STATE_FILE)
  local data = body and noctalia.json.decode(body)
  if type(data) ~= "table" then
    return
  end
  owned = data.owned == true
  session = data.session == true
  endsAt = if type(data.endsAt) == "number" then data.endsAt else nil
  if type(data.lidEnabled) == "boolean" then
    lidEnabled = data.lidEnabled
  end
end

local function changed()
  save()
  publish()
end

---- Lid inhibitor: held while lidEnabled and we own a session

local function syncLid()
  local want = lidEnabled and session
  if lidBusy or want == lidHeld then
    return
  end
  lidBusy = true
  noctalia.runAsync(if want then LID_START else LID_STOP, function(_r)
    noctalia.runAsync(LID_CHECK, function(r)
      lidHeld = r.exitCode == 0
      lidBusy = false
      if want and not lidHeld then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notify.lid_failed"))
        lidEnabled = false
        changed()
        return
      end
      publish()
      syncLid() -- catch a change made while we were busy
    end)
  end)
end

---- Built-in caffeine

local function caffeine(on, callback)
  busy += 1
  publish()
  noctalia.runAsync({ "noctalia", "msg", if on then "caffeine-enable" else "caffeine-disable" }, function(r)
    busy -= 1
    if r.exitCode == 0 then
      active = on
      if on then
        graceUntil = os.time() + ENABLE_GRACE_S
      end
    else
      local err = noctalia.string.trim(r.stderr or "")
      noctalia.notifyError(noctalia.tr("title"), if err ~= "" then err else noctalia.string.trim(r.stdout or ""))
    end
    publish()
    if callback then
      callback(r.exitCode == 0)
    end
  end)
end

-- Caffeine went off without us (built-in tile, CLI): drop our session.
local function forgetSession()
  endsAt = nil
  owned = false
  session = false
  syncLid()
  changed()
end

local function refresh(callback)
  caffeinePollPending = true
  noctalia.runAsync(CHECK_CAFFEINE, function(r)
    caffeinePollPending = false
    lastCaffeinePoll = os.time()
    local seen = r.exitCode == 0
    if busy == 0 and not (not seen and os.time() < graceUntil) then
      active = seen
      if not active and session then
        forgetSession()
      end
    end
    publish()
    if callback then
      callback()
    end
  end)
end

---- Spoon semantics

local function cancelTimer()
  endsAt = nil
end

-- Clears the timer and releases caffeine only if we turned it on.
local function endSession()
  cancelTimer()
  if owned then
    caffeine(false)
  end
  owned = false
  session = false
  syncLid()
  changed()
end

local function setState(on)
  cancelTimer()
  if not on then
    caffeine(false)
    owned = false
    session = false
  else
    if not active then
      owned = true
      caffeine(true, function(ok)
        if not ok then
          forgetSession()
        end
      end)
    end
    session = true
  end
  syncLid()
  changed()
end

local function enableForDuration(seconds)
  setState(true)
  endsAt = os.time() + seconds
  changed()
end

local function addMinutes(minutes)
  if endsAt then
    endsAt += minutes * 60
    if endsAt <= os.time() then
      endSession()
      return
    end
    changed()
  elseif minutes > 0 then
    enableForDuration(minutes * 60)
  end
end

---- Commands (bar, panel, shortcut through noctalia.state; keybinds through IPC)

local function handle(action, arg)
  if action == "toggle" then
    refresh(function()
      setState(not active)
    end)
  elseif action == "enable" or action == "on" then
    refresh(function()
      setState(true)
    end)
  elseif action == "disable" or action == "off" then
    setState(false)
  elseif action == "for" then
    local mins = tonumber(arg)
    if mins and mins > 0 and mins < math.huge then
      refresh(function()
        enableForDuration(math.floor(mins * 60))
      end)
    end
  elseif action == "add" then
    local mins = tonumber(arg)
    if mins and mins == mins and math.abs(mins) < math.huge then
      addMinutes(mins)
    end
  elseif action == "cancel-timer" then
    cancelTimer()
    changed()
  elseif action == "lid" then
    if arg == "on" or arg == "true" then
      lidEnabled = true
    elseif arg == "off" or arg == "false" then
      lidEnabled = false
    else
      lidEnabled = not lidEnabled
    end
    syncLid()
    changed()
  elseif action == "status" then
    noctalia.log(
      `caffeinate-plus: active={active} owned={owned} session={session} remaining={remaining()} lid={lidEnabled}/{lidHeld}`
    )
  elseif action ~= nil then
    noctalia.log(`caffeinate-plus: unknown command {action}`)
  end
end

noctalia.state.watch(C.CMD, function(cmd)
  if type(cmd) == "table" then
    handle(cmd.action, cmd.arg)
  end
end)

function onIpc(event, payload)
  handle(event, payload)
end

-- lid_inhibit is the default; the panel toggle overrides it until the setting
-- itself changes (editing presets must not reset the panel's choice).
local configLid = noctalia.getConfig("lid_inhibit") == true

function onConfigChanged()
  local fromConfig = noctalia.getConfig("lid_inhibit") == true
  if fromConfig ~= configLid then
    configLid = fromConfig
    lidEnabled = fromConfig
    syncLid()
  end
  changed()
end

---- Tick: timer expiry, lock check, outside changes

local function checkLock()
  if lockPollPending then
    return
  end
  lockPollPending = true
  noctalia.runAsync({ "noctalia", "msg", "status" }, function(r)
    lockPollPending = false
    lastLockPoll = os.time()
    if r.exitCode ~= 0 then
      return
    end
    local status = noctalia.json.decode(r.stdout or "")
    if type(status) == "table" and status.locked == true and session then
      endSession()
    end
  end)
end

noctalia.setUpdateInterval(1000)

function update()
  local now = os.time()
  if endsAt and now >= endsAt then
    endSession()
    return
  end
  if session and noctalia.getConfig("cancel_on_lock") ~= false and now - lastLockPoll >= LOCK_POLL_S then
    checkLock()
  end
  if busy == 0 and not caffeinePollPending and now - lastCaffeinePoll >= CAFFEINE_POLL_S then
    refresh()
  end
  if endsAt then
    publish() -- the countdown
  end
end

---- Startup and teardown

load()
publish()
noctalia.runAsync(LID_CHECK, function(r)
  lidHeld = r.exitCode == 0
  refresh(function()
    -- refresh() already dropped a session whose caffeine is gone (shell restart).
    if endsAt and os.time() >= endsAt then
      endSession()
    else
      syncLid()
      changed()
    end
  end)
end)

function onExit(_signal, reason)
  -- Disable/uninstall removes the controls, so release what we own, as the
  -- Spoon's stop() does. Fire-and-forget: the VM goes away when this returns.
  -- Reload keeps the session; state.json lets the next load pick it up.
  if reason == "disable" or reason == "uninstall" then
    local cmd = LID_STOP
    if owned then
      cmd = "noctalia msg caffeine-disable >/dev/null 2>&1; " .. cmd
    end
    noctalia.runAsync(cmd)
    if STATE_FILE then
      noctalia.removeFile(STATE_FILE)
    end
  end
end
