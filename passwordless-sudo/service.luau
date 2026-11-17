--!nonstrict
-- Headless owner of the passwordless sudo state.
--
-- Publishes noctalia.state "status":
--   { known, active, mode = "off"|"timed"|"permanent"|"external", deadline, busy }
-- Listens on noctalia.state "command": { action, duration, nonce }
--   action = "enable" | "disable" | "toggle" | "refresh"
--
-- Like Omarchy's indicator it never polls sudo. It probes at load, after every
-- enable or disable attempt (failed ones too), and once a timed grant's
-- deadline has passed. Each probe is `sudo -kn helper __status`: -k ignores
-- cached credentials, so a recent password entry never reads as passwordless.

local common = require("./lib/common.luau")
local tr = noctalia.tr

local status = { known = false, active = false, mode = "off", deadline = 0, busy = false }
local probing = false
local pending = nil -- in-flight enable: { duration, errFile, startedAt }
local probeAgain = false

local function publish()
  noctalia.state.set("status", {
    known = status.known,
    active = status.active,
    mode = status.mode,
    deadline = status.deadline,
    busy = status.busy,
  })
end

local function setInactive()
  status.active = false
  status.mode = "off"
  status.deadline = 0
end

local function helperInstalled()
  return noctalia.fileExists(common.HELPER)
end

-- The installed helper must match the copy shipped with the plugin, so an
-- updated plugin reinstalls it on the next enable.
local function helperCurrent()
  if not helperInstalled() then
    return false
  end
  local dir = noctalia.pluginDir()
  if not dir then
    return true
  end
  local shipped = noctalia.readFile(dir .. "/bin/noctalia-sudo-passwordless")
  local installed = noctalia.readFile(common.HELPER)
  return shipped ~= nil and shipped == installed
end

local probe

local function finishProbe(result)
  probing = false
  status.known = true
  if result.exitCode == 0 then
    local out = noctalia.string.trim(result.stdout or "")
    local deadline = string.match(out, "^timed (%d+)$")
    status.active = true
    if deadline then
      status.mode = "timed"
      status.deadline = tonumber(deadline)
    elseif out == "permanent" then
      status.mode = "permanent"
      status.deadline = 0
    else
      status.mode = "external"
      status.deadline = 0
    end
  else
    local err = noctalia.string.trim(result.stderr or "")
    if result.timedOut or (err ~= "" and not string.find(err, "password is required", 1, true)) then
      noctalia.log("status probe failed (exit " .. tostring(result.exitCode) .. "): " .. err)
    end
    setInactive()
  end
  publish()
  if probeAgain then
    probeAgain = false
    probe()
  end
end

probe = function()
  if probing then
    probeAgain = true
    return
  end
  probing = true
  local argv
  if helperInstalled() then
    argv = { "/usr/bin/sudo", "-kn", "--", common.HELPER, "__status" }
  else
    -- No helper yet: only a rule from elsewhere could make sudo passwordless.
    argv = { "/usr/bin/sudo", "-kn", "--", "/usr/bin/true" }
  end
  local ok = noctalia.runAsync(argv, finishProbe)
  if not ok then
    probing = false
    status.known = true
    setInactive()
    publish()
  end
end

local function setBusy(busy)
  status.busy = busy
  publish()
end

local function enable(duration)
  if status.busy then
    return
  end
  if duration ~= "permanent" then
    local minutes = tonumber(duration)
    if not minutes or minutes < 1 or minutes > 1440 or minutes ~= math.floor(minutes) then
      noctalia.notifyError(tr("notify.title"), tr("notify.bad_duration"))
      return
    end
    duration = tostring(minutes)
  end

  local argv
  if not helperCurrent() then
    -- One authentication installs (or updates) the helper and enables.
    argv = { "/usr/bin/pkexec", "/bin/bash", noctalia.pluginDir() .. "/install.sh", "--enable", duration }
  elseif status.active and status.mode ~= "external" then
    -- Changing the duration of a live grant needs no password, as in Omarchy.
    argv = { "/usr/bin/sudo", "-n", "--", common.HELPER, "__enable", duration }
  else
    argv = { "/usr/bin/pkexec", common.HELPER, "__enable", duration }
  end

  -- pkexec waits on the user's password for as long as it takes, but a
  -- captured runAsync is killed after at most 60 s. Run it detached instead
  -- and have the wrapper report its exit code back over IPC.
  local dataDir = noctalia.pluginDataDir()
  local errFile = (dataDir or "/tmp") .. "/enable.err"
  local wrapper = 'err=$1; shift; "$@" 2>"$err"; rc=$?; '
    .. '/usr/bin/noctalia msg plugin ' .. common.PLUGIN .. ':service all enable-result "$rc"'
  local cmd = { "/bin/sh", "-c", wrapper, "sh", errFile }
  for _, a in ipairs(argv) do
    table.insert(cmd, a)
  end

  pending = { duration = duration, errFile = errFile, startedAt = common.nowSec() }
  setBusy(true)
  if not noctalia.runAsync(cmd) then
    pending = nil
    setBusy(false)
    noctalia.notifyError(tr("notify.enable_failed"), tr("notify.enable_failed_body"))
  end
end

local function finishEnable(code)
  local p = pending
  pending = nil
  setBusy(false)
  if not p then
    probe()
    return
  end
  local duration = p.duration
  if code == 0 then
    if duration == "permanent" then
      noctalia.notify(tr("notify.title"), tr("notify.enabled_permanent"))
    else
      noctalia.notify(tr("notify.title"), tr("notify.enabled_timed", { span = common.formatRemaining(tonumber(duration) * 60) }))
    end
  elseif code == 126 then
    -- Authentication dialog dismissed.
    noctalia.log("enable cancelled at authentication")
  elseif code == 127 then
    noctalia.notifyError(tr("notify.title"), tr("notify.not_authorized"))
  else
    local detail = noctalia.readFile(p.errFile)
    detail = detail and noctalia.string.trim(detail) or ""
    noctalia.notifyError(tr("notify.enable_failed"), detail ~= "" and detail or tr("notify.enable_failed_body"))
  end
  -- Refresh after every attempt: a failed renewal can still remove a grant.
  probe()
end

local function disable()
  if status.busy then
    return
  end
  if not helperInstalled() then
    probe()
    return
  end
  local wasExternal = status.mode == "external"
  setBusy(true)
  -- Noninteractive: works because the grant itself is NOPASSWD. If it expired
  -- between display and click, this fails and the probe clears the indicator.
  noctalia.runAsync({ "/usr/bin/sudo", "-n", "--", common.HELPER, "__disable" }, function(result)
    setBusy(false)
    if result.exitCode == 0 then
      noctalia.runAsync({ "/usr/bin/sudo", "-kn", "--", common.HELPER, "__status" }, function(check)
        if check.exitCode == 0 then
          noctalia.notifyError(tr("notify.title"), tr("notify.still_external"))
        elseif not wasExternal then
          noctalia.notify(tr("notify.title"), tr("notify.disabled"))
        end
        probe()
      end)
    else
      noctalia.notify(tr("notify.title"), tr("notify.already_disabled"))
      probe()
    end
  end)
end

local function handle(action, duration)
  if action == "enable" then
    enable(duration)
  elseif action == "disable" then
    disable()
  elseif action == "toggle" then
    if status.active then
      disable()
    else
      noctalia.togglePanel(common.PANEL)
    end
  elseif action == "refresh" then
    probe()
  elseif action == "enable-result" then
    finishEnable(tonumber(duration) or -1)
  end
end

noctalia.state.watch("command", function(cmd)
  -- state outlives a service reload; never replay an old enable/disable.
  if type(cmd) ~= "table" or type(cmd.nonce) ~= "number" or noctalia.nowMs() - cmd.nonce > 5000 then
    return
  end
  handle(cmd.action, cmd.duration)
end)

-- noctalia msg plugin crsmthw/passwordless-sudo:service all <refresh|disable|toggle|enable MINUTES|permanent>
-- (enable-result is internal: the detached pkexec wrapper reports its exit code)
function onIpc(event, payload)
  handle(event, payload and noctalia.string.trim(payload) or nil)
end

-- Local deadline check only; probes sudo once the deadline has passed.
-- nowMs is wall-clock time, so expiry during suspend is caught on wake.
function update()
  -- Never stay busy forever if the result IPC was lost (e.g. shell restart).
  if pending and common.nowSec() - pending.startedAt > 600 then
    finishEnable(-1)
  end
  if status.active and status.mode == "timed" and not probing and common.nowSec() >= status.deadline + 1 then
    probe()
  end
end

noctalia.setUpdateInterval(5000)
publish()
probe()
