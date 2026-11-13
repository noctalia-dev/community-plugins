--!nonstrict
-- Headless service: starts and keeps the CMF Buds daemon alive.

local C = require("./lib/common.luau")

local statePath = nil
local socketPath = nil
local logPath = nil
local pluginPath = noctalia.pluginDir() or ""
local started = false
-- Set when the plugin shuts down: it stops an in-flight ping (or a
-- reconfiguration) from bringing the daemon back up after it was stopped.
local stopped = false

local function ensurePaths()
  local dir = noctalia.pluginDataDir()
  if dir ~= nil then
    statePath = dir .. "/state.json"
    socketPath = dir .. "/daemon.sock"
    logPath = dir .. "/daemon.log"
  end
end

local function daemonArgv(extra)
  local argv = {
    "python3",
    pluginPath .. "/bin/budsctl.py",
    "daemon",
    "--state", statePath,
    "--socket", socketPath,
    "--log", logPath,
    "--poll", tostring(C.poll_seconds()),
    "--idle-timeout", "300",
    "--device-mac", noctalia.getConfig("device_mac") or "",
    "--device-name", noctalia.getConfig("device_name") or "",
  }
  if extra ~= nil then
    for _, v in ipairs(extra) do
      table.insert(argv, v)
    end
  end
  return argv
end

local function jsonString(value)
  local s = tostring(value or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return s
end

-- The daemon can start with the factory configuration: when the plugin is
-- reloaded, the user configuration is not applied yet and the service starts
-- it with the default values (polling every 20 s instead of what the user
-- set). Every round passes the current configuration, so the daemon always
-- works with what the user set (regardless of when it was started).
local function configureDaemon()
  if stopped then
    return
  end
  local poll = C.poll_seconds()
  local payload = '{"cmd":"configure","poll":' .. tostring(poll)
    .. ',"device_mac":"' .. jsonString(noctalia.getConfig("device_mac")) .. '"'
    .. ',"device_name":"' .. jsonString(noctalia.getConfig("device_name")) .. '"}'
  noctalia.runAsync({
    "python3", pluginPath .. "/bin/budsctl.py", "rpc", payload,
    "--state", statePath,
    "--socket", socketPath,
    "--log", logPath,
    "--poll", tostring(poll),
    "--device-mac", noctalia.getConfig("device_mac") or "",
    "--device-name", noctalia.getConfig("device_name") or "",
    -- The daemon is never started from here: a request that is in flight
    -- when the plugin is disabled must not bring it back.
    "--no-autostart",
  })
end

local function stopDaemon(onStopped)
  if statePath == nil then
    if onStopped ~= nil then
      onStopped()
    end
    return
  end
  noctalia.runAsync({
    "python3", pluginPath .. "/bin/budsctl.py", "stop",
    "--state", statePath,
    "--socket", socketPath,
    "--log", logPath,
  }, function()
    -- The stop waits for the daemon to release its lock, so the next one
    -- can start.
    if onStopped ~= nil then
      onStopped()
    end
  end)
end

local function startDaemon()
  if stopped then
    return
  end
  ensurePaths()
  if statePath == nil then
    return
  end
  -- The daemon uses flock: if one is already running, this attempt exits without doing anything.
  noctalia.runAsync(daemonArgv())
  started = true
end

local function ping()
  if statePath == nil then
    ensurePaths()
    if statePath == nil then
      return
    end
  end
  noctalia.runAsync({
    "python3", pluginPath .. "/bin/budsctl.py", "rpc", "{\"cmd\":\"ping\"}",
    "--state", statePath,
    "--socket", socketPath,
    "--log", logPath,
    "--poll", tostring(C.poll_seconds()),
    "--device-mac", noctalia.getConfig("device_mac") or "",
    "--device-name", noctalia.getConfig("device_name") or "",
    -- The daemon is not started from here: it is the job of the service,
    -- and a ping in flight must not bring it back after a shutdown.
    "--no-autostart",
  }, function(result)
    -- If the daemon died (for example after a crash), it has to be relaunched.
    -- But if the plugin was shut down in the meantime, nothing must be touched.
    if stopped then
      return
    end
    -- The exit code is not enough: the command always exits with zero when it
    -- answers, even when the answer says that the daemon is not there. The
    -- answer itself says whether the daemon answered.
    local decoded, data = pcall(noctalia.json.decode, result.stdout or "")
    local answered = decoded and type(data) == "table" and data.ok == true
    if not answered then
      startDaemon()
    end
  end)
end

function update()
  if not started then
    startDaemon()
  end
  ping()
  configureDaemon()
end

function onEnable()
  stopped = false
  startDaemon()
end

function onConfigChanged()
  -- The daemon is stopped first and started when the stop is finished: the
  -- daemon uses flock, and the new one would quit without doing anything if
  -- the old one still held the lock.
  started = false
  stopDaemon(function()
    if stopped then
      return
    end
    startDaemon()
  end)
end

function onExit(_signal, _reason)
  stopped = true
  started = false
  stopDaemon()
end

noctalia.setUpdateInterval(20000)
startDaemon()
