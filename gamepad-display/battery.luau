--!nonstrict
-- Headless service: runs the bundled DualSense HID / ds4u IPC daemon and
-- publishes its JSON state to the plugin's other entries.

local RUNTIME_DIR = noctalia.getenv("XDG_RUNTIME_DIR")
if not RUNTIME_DIR or RUNTIME_DIR == "" then
  RUNTIME_DIR = "/tmp"
end
local LOCK_FILE = RUNTIME_DIR .. "/noctalia-dualsense-battery.lock"
local RESTART_AFTER = 20 -- seconds without a line -> restart the daemon

local low_threshold = tonumber(noctalia.getConfig("low_threshold")) or 20
local notify_low = noctalia.getConfig("notify_low")
if notify_low == nil then
  notify_low = true
end
local low_notified = noctalia.state.get("low_notified") == true
local python_notified = false
local last_line = 0
local last_restart = 0

local function log(message)
  noctalia.log("[dualsense] " .. tostring(message))
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function daemon_path()
  local dir = noctalia.pluginDir()
  if not dir then
    return nil
  end
  return dir .. "/code/ds_battery_daemon.py"
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
    if cmdline and string.find(cmdline, "ds_battery_daemon.py", 1, true) then
      noctalia.runAsync("kill " .. pid .. " 2>/dev/null")
    end
  end
  noctalia.removeFile(LOCK_FILE)
end

local function maybe_notify(state)
  local pct = tonumber(state.battery_pct) or -1
  local low = state.connected == true
    and state.charging ~= true
    and pct >= 0
    and pct <= low_threshold

  if not low then
    if low_notified then
      low_notified = false
      noctalia.state.set("low_notified", false)
    end
    return
  end

  if notify_low and not low_notified then
    low_notified = true
    noctalia.state.set("low_notified", true)
    noctalia.notify(
      noctalia.tr("notification.low.title"),
      noctalia.tr("notification.low.body", { pct = pct })
    )
  end
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

  noctalia.state.set("controller", decoded)
  maybe_notify(decoded)
end

local function start_stream()
  last_line = os.time()
  local path = daemon_path()
  if not path then
    log("plugin directory is unavailable")
    return false
  end
  if not noctalia.fileExists(path) then
    log("battery daemon is missing: " .. path)
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
    noctalia.state.set("controller", {
      error = "python3",
      connected = false,
      charging = false,
      battery_pct = -1,
      ts = os.time(),
    })
    return false
  end

  local ok = noctalia.runStream(
    "python3 " .. shell_quote(path) .. " --stream",
    on_line
  )
  if not ok then
    log("failed to start the battery daemon")
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

local function handle_action(cmd_table)
  if type(cmd_table) ~= "table" then
    return
  end
  local action = cmd_table.action
  local path = daemon_path()
  if not path then
    return
  end
  if action == "cycle-profile" then
    noctalia.runAsync("python3 " .. shell_quote(path) .. " --cycle-profile", function()
      restart(true)
    end)
  elseif action == "switch-profile" and type(cmd_table.profile) == "string" and cmd_table.profile ~= "" then
    noctalia.runAsync(
      "python3 " .. shell_quote(path) .. " --switch-profile " .. shell_quote(cmd_table.profile),
      function()
        restart(true)
      end
    )
  elseif action == "buzz" then
    noctalia.runAsync("python3 " .. shell_quote(path) .. " --buzz")
  end
end

function update()
  if last_line > 0 and os.time() - last_line > RESTART_AFTER then
    restart(false)
  end
end

function onIpc(event, payload)
  if event == "buzz" then
    local path = daemon_path()
    if path then
      noctalia.runAsync("python3 " .. shell_quote(path) .. " --buzz")
    end
  elseif event == "cycle-profile" then
    handle_action({ action = "cycle-profile" })
  elseif event == "switch-profile" and type(payload) == "string" and payload ~= "" then
    handle_action({ action = "switch-profile", profile = payload })
  elseif event == "restart" then
    restart(true)
  end
end

function onExit(_signal, _reason)
  kill_stale()
end

noctalia.state.watch("action", function(value)
  handle_action(value)
end)

noctalia.setUpdateInterval(2000)
kill_stale()
start_stream()
