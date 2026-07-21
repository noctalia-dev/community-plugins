function tr(key)
	return noctalia.tr(key)
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- This could be replaced by noctalia.outputs() and noctalia.focusedOutputName() but currently the focusedOutputName() function returns nil when testing so we can't use it
local function updateMonitors()
  noctalia.runAsync("hyprctl monitors all -j", function(output)
    if output.timedOut or output.exitCode ~= 0 then
      noctalia.notify(tr("notification.monitor_list_failed"), output.stderr or tr("notification.timed_out"))
      return
    end

    local ok, msg = pcall(noctalia.json.decode, output.stdout)
    if not ok or type(msg) ~= "table" then
      noctalia.notify(tr("notification.monitor_list_failed"), msg)
      return
    end

    local monitors = {}
    local focusedMonitor = nil
    for i, monitor in ipairs(msg) do
      monitors[i] = monitor.name
      focusedMonitor = monitor.focused and monitor.name or focusedMonitor
    end

    if #monitors == 0 then
      noctalia.notify(tr("notification.monitor_list_failed"), tr("notification.no_monitors_found"))
      return
    end

    -- update monitor data
    noctalia.state.set("monitors", monitors)
    noctalia.state.set("focusedMonitor", focusedMonitor)

    -- update source and target monitor indices if they are out of bounds or not set
    local sourceMonitor = noctalia.state.get("sourceMonitor") or 0
    local targetMonitor = noctalia.state.get("targetMonitor") or 0
    local isMirroring = noctalia.state.get("isMirroring") or false

    if sourceMonitor >= #monitors then
      sourceMonitor = 0
    end
    if targetMonitor >= #monitors then
      targetMonitor = 0
    end

    -- check if there is an active mirror and set the source and target monitors accordingly
    for _, monitor in ipairs(msg) do
      if monitor.mirrorOf == "none" then
        continue
      end

      local index = table.find(monitors, monitor.name)
      targetMonitor = index - 1
      local mirrorId = tonumber(monitor.mirrorOf)

      for _, source in ipairs(msg) do
        if source.id == mirrorId then
          local sourceIndex = table.find(monitors, source.name)
          sourceMonitor = sourceIndex - 1
          break
        end
      end

      isMirroring = true

      break
    end

    noctalia.state.set("sourceMonitor", sourceMonitor)
    noctalia.state.set("targetMonitor", targetMonitor)
    noctalia.state.set("isMirroring", isMirroring)

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
  -- we can not use the event data itself for the monitor events because hyprland treats a mirror as a monitor remove/add so this would remove a mirrored screen from the list
  if event == "monitoradded" then
    updateMonitors()
  elseif event == "monitorremoved" then
    updateMonitors()
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
  if not socketPath then
    noctalia.notify(tr("notification.monitor_watch_failed"), tr("notification.hyprland_socket_not_found"))
    return
  end

  local cmd = "socat -U - UNIX-CONNECT:" .. shellQuote(socketPath)
  noctalia.runStream(cmd, handleHyprEvent)
end

-- main
updateMonitors()
watchMonitors()

noctalia.state.watch("monitor_refresh", function()
  updateMonitors()
end)

local function stopMirroring()
  local targetIndex = noctalia.state.get("targetMonitor")
  local monitors = noctalia.state.get("monitors") or {}

  if not targetIndex then
    noctalia.notify(tr("notification.stop_mirroring_failed"), tr("notification.invalid_monitor_selection"))
    return
  end

  local targetMonitor = monitors[targetIndex + 1]

  if not targetMonitor then
    noctalia.notify(tr("notification.stop_mirroring_failed"), tr("notification.invalid_monitor_selection"))
    return
  end

  local expr = string.format("hl.monitor({ output = %q, mirror = \"\" })", targetMonitor)
  local cmd = "hyprctl eval " .. shellQuote(expr)

  noctalia.runAsync(cmd, function(output)
    if output.timedOut or output.exitCode ~= 0 then
      noctalia.notify(tr("notification.stop_mirroring_failed"), output.stderr or tr("notification.timed_out"))
      return
    end
  end, 5000)
end

local function startMirroring()
  local sourceIndex = noctalia.state.get("sourceMonitor")
  local targetIndex = noctalia.state.get("targetMonitor")
  local monitors = noctalia.state.get("monitors") or {}

  if not sourceIndex or not targetIndex or sourceIndex == targetIndex then
    noctalia.notify(tr("notification.start_mirroring_failed"), tr("notification.invalid_monitor_selection"))
    return
  end

  local sourceMonitor = monitors[sourceIndex + 1]
  local targetMonitor = monitors[targetIndex + 1]

  if not sourceMonitor or not targetMonitor then
    noctalia.notify(tr("notification.start_mirroring_failed"), tr("notification.invalid_monitor_selection"))
    return
  end

  local expr = string.format("hl.monitor({ output = %q, mirror = %q })", targetMonitor, sourceMonitor)
  local cmd = "hyprctl eval " .. shellQuote(expr)

  noctalia.runAsync(cmd, function(output)
    if output.timedOut or output.exitCode ~= 0 then
      noctalia.notify(tr("notification.start_mirroring_failed"), output.stderr or tr("notification.timed_out"))
      return
    end
  end, 5000)
end

noctalia.state.watch("isMirroring", function(isMirroring)
  if isMirroring then
    startMirroring()
  else
    stopMirroring()
  end
end)
