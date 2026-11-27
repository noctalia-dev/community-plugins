--!nonstrict
-- Caffeinate Plus service: the only entry that holds state. A port of the
-- Caffeine Spoon's init.lua. noctalia's built-in caffeine does the actual
-- idle inhibiting; this service decides when it should be on. It also holds
-- the lid-close inhibitor and, while that is on, can turn the internal
-- display off on lid close and restore the previous brightness on open.
--
-- Ownership: caffeine that was already on before we were asked is left alone
-- by screen lock and plugin disable. Starting a timer is different: it takes
-- over caffeine, so when the timer ends (or the screen locks) caffeine turns
-- off, whoever turned it on. Cancelling the timer hands caffeine back. An
-- explicit "disable" always turns it off. The built-in caffeine holds a logind
-- idle inhibitor (who=noctalia, why=Caffeine), which is how we read it.
--
-- Derived from the Caffeine Spoon by Chris Jones and Caffeine contributors
-- (MIT); the timer and session logic are Jon Friesen's. See LICENSE.

local C = require("./common.luau")

local dataDir = noctalia.pluginDataDir()
local STATE_FILE = dataDir and (dataDir .. "/state.json") or nil
-- Touched while the lid inhibitor should be held. The unit gives up once it
-- goes stale, so a crash, kill or shutdown can't leave the lid held for good.
local HEARTBEAT_FILE = dataDir and (dataDir .. "/lid-heartbeat") or nil
local HEARTBEAT_EVERY_S = 10
local HEARTBEAT_STALE_S = 30

-- Lid-close display handling. The saved raw brightness lives in the runtime
-- dir under its own name so another plugin can't clobber it.
local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
local BRIGHTNESS_FILE = runtimeDir .. "/caffeinate-plus-brightness"
local LID_CLOSED = {
  "busctl", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1",
  "org.freedesktop.login1.Manager", "LidClosed",
}
local brightnessAvailable = noctalia.commandExists("brightnessctl")
local lidAvailable = noctalia.commandExists("busctl")

local function shellQuote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local LID_UNIT = "caffeinate-plus-lid.service"
local CHECK_CAFFEINE = "systemd-inhibit --list --no-pager --no-legend"
  .. " | grep -qE '^noctalia[[:space:]].*[[:space:]]idle[[:space:]]+Caffeine([[:space:]]|$)'"
-- Lid inhibitor in a transient user unit, after bagusk99/super-caffeine (MIT).
-- Instead of `sleep infinity`, it holds the inhibitor only while the heartbeat
-- file is fresh.
local LID_WATCH = `while [ $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )) -lt {HEARTBEAT_STALE_S} ]; `
  .. `do sleep 5; done`
local LID_START = HEARTBEAT_FILE
  and (
    `systemctl --user reset-failed {LID_UNIT} >/dev/null 2>&1 || true; `
    .. `systemd-run --user --quiet --collect --unit={LID_UNIT} --description='Caffeinate Plus lid inhibitor' `
    .. `systemd-inhibit --what=handle-lid-switch --mode=block `
    .. `--who='Caffeinate Plus' --why='Keeping awake with the lid closed' `
    .. `sh -c {shellQuote(LID_WATCH)} caffeinate-plus-lid {shellQuote(HEARTBEAT_FILE)}`
  )
  or "false" -- no data dir: refuse rather than hold the lid with no way to expire
local LID_STOP = `systemctl --user stop {LID_UNIT} >/dev/null 2>&1 || true`
local LID_CHECK = `systemctl --user is-active --quiet {LID_UNIT}`

local CAFFEINE_POLL_S = 5
local LID_POLL_S = 5
local LOCK_POLL_S = 2
-- After we enable caffeine, its logind inhibitor can lag the IPC reply. Don't
-- read "not listed yet" as "turned off elsewhere" during this window.
local ENABLE_GRACE_S = 4

local active = false -- built-in caffeine is on (last observed)
local owned = false -- we turned it on, or a timer took it over
local timerClaimed = false -- the timer took over caffeine that was already on
local session = false -- a keep-awake session we started (toggle on or timer)
local endsAt = nil -- unix seconds, when a timer is running
local lidEnabled = noctalia.getConfig("lid_inhibit") == true
local lidHeld = false
local lidBusy = false
local dimEnabled = noctalia.getConfig("dim_on_lid_close") ~= false
local dimmed = brightnessAvailable and BRIGHTNESS_FILE and noctalia.fileExists(BRIGHTNESS_FILE) or false
local dimBusy = false -- brightnessctl get/set in flight
local restoring = false
local lidClosed = false
local lidReadPending = false
local busy = 0 -- caffeine commands in flight
local graceUntil = 0
local lastCaffeinePoll = 0
local lastLockPoll = 0
local lockPollPending = false
local caffeinePollPending = false
local lastHeartbeat = 0
local lastLidPoll = 0

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
    dimEnabled = dimEnabled,
    dimmed = dimmed,
    lidClosed = lidClosed,
    dimAvailable = brightnessAvailable and lidAvailable,
    busy = busy > 0,
  })
end

local function save()
  if not STATE_FILE then
    return
  end
  local body = noctalia.json.encode({
    owned = owned,
    timerClaimed = timerClaimed,
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
  timerClaimed = data.timerClaimed == true
  session = data.session == true
  endsAt = if type(data.endsAt) == "number" then data.endsAt else nil
  if type(data.lidEnabled) == "boolean" then
    lidEnabled = data.lidEnabled
  end
end

---- Display off on lid close (only while our session holds the lid)

local function applyOffBrightness()
  if not brightnessAvailable or not BRIGHTNESS_FILE or dimmed or dimBusy then
    return
  end
  dimBusy = true

  local function setOff()
    noctalia.runAsync({ "brightnessctl", "set", "0%" }, function(r)
      dimBusy = false
      if r.exitCode == 0 then
        dimmed = true
        publish()
      end
    end)
  end

  if noctalia.fileExists(BRIGHTNESS_FILE) then
    setOff()
    return
  end

  noctalia.runAsync({ "brightnessctl", "get" }, function(r)
    local saved = r.exitCode == 0 and string.match(r.stdout or "", "%d+") or nil
    if not saved then
      dimBusy = false
      return
    end
    noctalia.writeFile(BRIGHTNESS_FILE, saved)
    setOff()
  end)
end

local function restoreBrightness()
  if not brightnessAvailable or not BRIGHTNESS_FILE or restoring then
    return
  end
  restoring = true

  local saved = noctalia.readFile(BRIGHTNESS_FILE)
  if saved then
    saved = string.match(saved, "%d+")
  end
  if not saved then
    noctalia.removeFile(BRIGHTNESS_FILE)
    dimmed = false
    restoring = false
    publish()
    return
  end

  noctalia.runAsync({ "brightnessctl", "set", saved }, function(r)
    if r.exitCode == 0 then
      dimmed = false
    end
    noctalia.removeFile(BRIGHTNESS_FILE)
    restoring = false
    publish()
  end)
end

-- Only act when Ignore lid close is on and we own a session: without the
-- inhibitor the lid would suspend the machine anyway.
local function refreshDim()
  if not lidAvailable or lidReadPending then
    return
  end
  lidReadPending = true
  noctalia.runAsync(LID_CLOSED, function(r)
    lidReadPending = false
    local closed = r.exitCode == 0 and string.find(r.stdout or "", "true", 1, true) ~= nil
    if closed ~= lidClosed then
      lidClosed = closed
      publish()
    end
    if dimEnabled and lidEnabled and session and closed then
      applyOffBrightness()
    elseif dimmed then
      restoreBrightness()
    end
  end)
end

local function changed()
  save()
  publish()
  refreshDim()
end

---- Lid inhibitor: held while lidEnabled and we own a session

local function heartbeat()
  if HEARTBEAT_FILE then
    noctalia.writeFile(HEARTBEAT_FILE, tostring(os.time()))
    lastHeartbeat = os.time()
  end
end

local function syncLid()
  local want = lidEnabled and session
  if lidBusy or want == lidHeld then
    return
  end
  lidBusy = true
  if want then
    heartbeat() -- fresh before the unit's first check
  end
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

-- The unit is the source of truth, as in super-caffeine: poll it, and if it
-- went away on its own (a stale heartbeat after a suspend, an OOM kill, a
-- manual stop), syncLid() starts it again while a session still wants it.
local function refreshLid()
  lastLidPoll = os.time()
  noctalia.runAsync(LID_CHECK, function(r)
    if lidBusy then
      return -- syncLid() is mid-change and checks the unit itself
    end
    local held = r.exitCode == 0
    if held ~= lidHeld then
      lidHeld = held
      publish()
      syncLid()
    end
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
  timerClaimed = false
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

---- Session semantics

-- Drops the timer without changing caffeine. If the timer had taken over
-- caffeine that was already on, hand it back: a later lock or disable leaves
-- it alone again.
local function cancelTimer()
  endsAt = nil
  if timerClaimed then
    owned = false
    timerClaimed = false
  end
end

-- Timer expiry, screen lock, plugin disable: clears the timer and releases
-- caffeine if we own it (we turned it on, or a timer took it over).
local function endSession()
  endsAt = nil
  timerClaimed = false
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

-- Starting a timer takes over caffeine: when it ends, caffeine turns off even
-- if it was on before. Replacing a running timer keeps an earlier takeover.
local function enableForDuration(seconds)
  local claimed = timerClaimed
  setState(true) -- hands back any takeover; claimed restores it below
  if not owned then
    owned = true
    claimed = true
  end
  timerClaimed = claimed
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
      if endsAt == nil and mins > 0 then
        -- Starting a timer turns caffeine on: read its current state first, as
        -- `for` does, so the timer records whether it took over caffeine that was
        -- already on, and Cancel timer can hand it back.
        refresh(function()
          addMinutes(mins)
        end)
      else
        addMinutes(mins)
      end
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
      `caffeinate-plus: active={active} owned={owned} claimed={timerClaimed} session={session} remaining={remaining()} lid={lidEnabled}/{lidHeld} dim={dimEnabled}/{dimmed}`
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

-- lid_inhibit is a default: the panel toggle overrides it until the setting
-- itself changes (editing presets must not reset the panel's choice).
-- dim_on_lid_close has no panel control, so the setting is authoritative.
local configLid = noctalia.getConfig("lid_inhibit") == true
local configDim = noctalia.getConfig("dim_on_lid_close") ~= false

function onConfigChanged()
  local fromConfig = noctalia.getConfig("lid_inhibit") == true
  if fromConfig ~= configLid then
    configLid = fromConfig
    lidEnabled = fromConfig
    syncLid()
  end
  local dimFromConfig = noctalia.getConfig("dim_on_lid_close") ~= false
  if dimFromConfig ~= configDim then
    configDim = dimFromConfig
    dimEnabled = dimFromConfig
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
  if lidEnabled and session and (lidHeld or lidBusy) and now - lastHeartbeat >= HEARTBEAT_EVERY_S then
    heartbeat()
  end
  if not lidBusy and (lidHeld or (lidEnabled and session)) and now - lastLidPoll >= LID_POLL_S then
    refreshLid()
  end
  if (dimEnabled and lidEnabled and session) or dimmed then
    refreshDim()
  end
end

---- Startup and teardown

load()
if lidEnabled and session then
  heartbeat() -- after a reload, before the running unit's next check
end
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
  -- Reload keeps the session; state.json and the heartbeat let the next load
  -- pick it up.
  if reason == "reload" then
    return
  end
  -- Anything else (shutdown, disable, uninstall) releases the lid. Removing the
  -- heartbeat is synchronous, so the unit exits within seconds even if the
  -- fire-and-forget stop below never runs.
  if HEARTBEAT_FILE then
    noctalia.removeFile(HEARTBEAT_FILE)
  end
  local cmd = LID_STOP
  -- Never leave the internal display dark after we're gone. The saved value
  -- is read now because the fire-and-forget command outlives this VM.
  if BRIGHTNESS_FILE and noctalia.fileExists(BRIGHTNESS_FILE) then
    local saved = noctalia.readFile(BRIGHTNESS_FILE)
    local value = saved and string.match(saved, "%d+")
    if value then
      cmd = `brightnessctl set {shellQuote(value)} >/dev/null 2>&1 || true; `
        .. `rm -f {shellQuote(BRIGHTNESS_FILE)}; ` .. cmd
    else
      noctalia.removeFile(BRIGHTNESS_FILE)
    end
  end
  -- Disable/uninstall removes the controls, so also release caffeine if we
  -- turned it on, as the Spoon's stop() does. Shutdown leaves it: the shell
  -- that holds it is going away anyway.
  if reason == "disable" or reason == "uninstall" then
    if owned then
      cmd = "noctalia msg caffeine-disable >/dev/null 2>&1; " .. cmd
    end
    if STATE_FILE then
      noctalia.removeFile(STATE_FILE)
    end
  end
  -- Fire-and-forget: the VM goes away when this returns.
  noctalia.runAsync(cmd)
end
