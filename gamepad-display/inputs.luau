--!nonstrict
-- Headless service: runs the bundled evdev input daemon and publishes the
-- controller's live button / stick / trigger state to the widget entries.
--
-- This is deliberately separate from the battery service: the input reader uses
-- the kernel evdev node, so it never competes with ds4u or the battery daemon
-- for hidraw reports. DualSense, DualShock 4 and 8BitDo pads are supported, and
-- the pad you touch last is the one shown.

local RUNTIME_DIR = noctalia.getenv("XDG_RUNTIME_DIR")
if not RUNTIME_DIR or RUNTIME_DIR == "" then
  RUNTIME_DIR = "/tmp"
end
local LOCK_FILE = RUNTIME_DIR .. "/noctalia-dualsense-inputs.lock"
local RESTART_AFTER = 20 -- seconds without a line -> restart the daemon

local last_line = 0
local last_restart = 0
local python_notified = false

local function log(message)
  noctalia.log("[dualsense-inputs] " .. tostring(message))
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function daemon_path()
  local dir = noctalia.pluginDir()
  if not dir then
    return nil
  end
  return dir .. "/code/ds_inputs_daemon.py"
end

-- Kill a daemon left behind by a previous Noctalia process. The lock file is
-- ours, but check the command line anyway so a recycled PID is never hit.
local function kill_stale()
  local raw = noctalia.readFile(LOCK_FILE)
  if not raw then
    return
  end
  local pid = string.match(raw, "^(%d+)")
  if pid and tonumber(pid) and tonumber(pid) > 1 then
    local cmdline = noctalia.readFile("/proc/" .. pid .. "/cmdline")
    if cmdline and string.find(cmdline, "ds_inputs_daemon.py", 1, true) then
      noctalia.runAsync("kill " .. pid .. " 2>/dev/null")
    end
  end
  noctalia.removeFile(LOCK_FILE)
end

local function on_line(line)
  if line == nil or line == "" then
    return
  end

  -- Any line proves the daemon is alive, even if this one is malformed.
  last_line = os.time()

  local decoded, err = noctalia.json.decode(line)
  if type(decoded) ~= "table" then
    log("could not decode daemon output: " .. tostring(err or line))
    return
  end

  noctalia.state.set("inputs", decoded)
end

local function start_stream()
  last_line = os.time()
  local path = daemon_path()
  if not path then
    log("plugin directory is unavailable")
    return false
  end
  if not noctalia.fileExists(path) then
    log("input daemon is missing: " .. path)
    return false
  end

  if not noctalia.commandExists("python3") then
    if not python_notified then
      python_notified = true
      log("python3 not found on PATH")
      noctalia.notifyError(
        noctalia.tr("notification.python.title"),
        noctalia.tr("notification.python.body")
      )
    end
    noctalia.state.set("inputs", {
      error = "python3",
      connected = false,
      ts = os.time(),
    })
    return false
  end

  local ok = noctalia.runStream(
    "python3 " .. shell_quote(path) .. " --stream",
    on_line
  )
  if not ok then
    log("failed to start the input daemon")
  end
  return ok
end

local function restart(force)
  local now = os.time()
  if not force and now - last_restart < RESTART_AFTER then
    return
  end
  last_restart = now
  kill_stale()
  start_stream()
end

function update()
  if last_line > 0 and os.time() - last_line > RESTART_AFTER then
    restart(false)
  end
end

function onIpc(event, _payload)
  if event == "restart" then
    restart(true)
  end
end

function onExit(_signal, _reason)
  kill_stale()
end

noctalia.setUpdateInterval(2000)
kill_stale()
start_stream()
