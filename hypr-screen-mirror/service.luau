function tr(key)
	return noctalia.tr(key)
end

-- This could be replaced by noctalia.outputs() and noctalia.focusedOutputName() but currently the focusedOutputName() function returns nil when testing so we can't use it
local function initMonitors()
  noctalia.runAsync("hyprctl monitors -j", function(output)
    if output.timedOut or output.exitCode ~= 0 then
      noctalia.notify(tr("notification.monitor_list_failed"), output.stderr or tr("notification.timed_out"))
      return
    end

    local ok, msg = pcall(noctalia.json.decode, output.stdout)
    if not ok or type(msg) ~= "table" then
      noctalia.notify(tr("notification.monitor_list_failed"), msg)
    end

    local monitors = {}
    local focusedMonitor = nil
    for i, monitor in ipairs(msg) do
      monitors[i] = monitor.name
      focusedMonitor = monitor.focused and monitor.name or focusedMonitor
    end

    noctalia.state.set("monitors", monitors)
    noctalia.state.set("focusedMonitor", focusedMonitor)

  end, 5000)
end

local function hyprlandSocketPath()
  local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
  local instanceSig = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")

  if not runtimeDir or not instanceSig then
    return nil
  end

  return string.format("%s/hypr/%s/.socket2.sock", runtimeDir, instanceSig)
end

local function handleHyprEvent(line)
  local event, data = line:match("^([^>]+)>>(.*)$")
  if event == "monitoradded" then
    local monitors = noctalia.state.get("monitors") or {}
    if not table.find(monitors, data) then
      table.insert(monitors, data)
    end
    noctalia.state.set("monitors", monitors)
  elseif event == "monitorremoved" then
    local monitors = noctalia.state.get("monitors") or {}
    for i, v in ipairs(monitors) do
      if v == data then
        table.remove(monitors, i)
        break
      end
    end
    noctalia.state.set("monitors", monitors)
  elseif event == "focusedmon" then
    -- data is MONNAME,WORKSPACENAME
    local monitorName = data:match("([^,]+)")
    if not monitorName then
      return
    end
    noctalia.state.set("focusedMonitor", monitorName)
  end
end

-- Watches the Hyprland socket for monitor events and updates the state accordingly
local function watchMonitors()
  local socketPath = hyprlandSocketPath()
  local cmd = string.format("socat -U - UNIX-CONNECT:%s", socketPath)

  noctalia.runStream(cmd, handleHyprEvent)
end

-- main
initMonitors()
watchMonitors()
