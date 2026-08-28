--!nonstrict

-- Noctalia does not expose Unix-domain sockets to Luau. The bundled transport
-- opens wireviewd's socket and speaks NUL-framed Varlink directly.

local SUPPORTED_APIS = { [1] = true, [2] = true }
local MAX_POINTS = 120
local pluginDirectory = noctalia.pluginDir()
local bridgePath = pluginDirectory and pluginDirectory .. "/varlink_bridge.py" or nil

local SNAPSHOT_KEY = "wireview.snapshot"
local SERIES_KEY = "wireview.series"
local STATUS_KEY = "wireview.status"
local CONFIG_KEY = "wireview.config"
local CONFIG_REQUEST_KEY = "wireview.config.request"
local CONFIG_OPERATION_KEY = "wireview.config.operation"
local SCREEN_REQUEST_KEY = "wireview.screen.request"
local SCREEN_OPERATION_KEY = "wireview.screen.operation"
local FAULT_REQUEST_KEY = "wireview.fault.request"
local FAULT_OPERATION_KEY = "wireview.fault.operation"
local FAULT_OBSERVATIONS_KEY = "wireview.fault.observations"
local KNOWN_FAULT_MASK = 0x003f

local series = {
  power = {},
  current = {},
  temperature = {},
  fan = {},
}
local telemetryPending = false
local telemetryDirty = false
local lastTelemetryAt = nil
local stalePublished = false
local monitorStarted = false
local compatible = false
local statusPending = false
local lastStatusProbeAt = 0
local lastDaemonStatus = nil
local faultObservations = {
  session_id = nil,
  active = {},
  logged = {},
}

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function methodCommand(method, parameters)
  if bridgePath == nil then
    return nil
  end
  local command = "python3 " .. shellQuote(bridgePath) .. " call " .. shellQuote(method)
  if parameters ~= nil then
    local encoded, encodeError = noctalia.json.encode(parameters)
    if encoded == nil then
      noctalia.log("wireview: failed to encode Varlink request: " .. tostring(encodeError))
      return nil
    end
    command = command .. " " .. shellQuote(encoded)
  end
  return command
end

local function decodeReply(result)
  if result.exitCode ~= 0 then
    local message = noctalia.string.trim(result.stderr or "")
    if message == "" then
      message = "The wireviewd request failed with exit code " .. tostring(result.exitCode)
    end
    -- Bridge diagnostics can reach the status label. Keep transport details out
    -- of user-facing errors while retaining the actionable daemon context.
    message = message:gsub("Varlink", "device"):gsub("varlink", "device")
    return nil, message
  end
  local decoded, decodeError = noctalia.json.decode(noctalia.string.trim(result.stdout or ""))
  if type(decoded) ~= "table" then
    return nil, "wireviewd returned invalid JSON: " .. tostring(decodeError)
  end
  return decoded, nil
end

local function hasCapability(status, expected)
  if type(status.api_capabilities) ~= "table" then
    return false
  end
  for _, capability in ipairs(status.api_capabilities) do
    if capability == expected then
      return true
    end
  end
  return false
end

local function publishStatus(state, message, status)
  local previous = lastDaemonStatus or {}
  noctalia.state.set(STATUS_KEY, {
    state = state,
    message = message,
    daemon_version = status and status.daemon_version or previous.daemon_version,
    daemon_build_id = status and status.daemon_build_id or previous.daemon_build_id,
    connected_port = status and status.connected_port or previous.connected_port,
    session_id = status and status.session_id or previous.session_id,
    sequence = status and status.sequence or previous.sequence,
    updated_at = os.time(),
  })
end

local function push(values, value)
  table.insert(values, value)
  if #values > MAX_POINTS then
    table.remove(values, 1)
  end
end

local function copyArray(values)
  local copied = {}
  for _, value in ipairs(values) do
    table.insert(copied, value)
  end
  return copied
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function reconcileObservedFaults(previous, faults, observedAt)
  local nextObserved = {}
  local changed = false
  if type(faults) == "table" then
    for _, rawFault in ipairs(faults) do
      local fault = tostring(rawFault)
      nextObserved[fault] = previous[fault] or observedAt
      if previous[fault] == nil then
        changed = true
      end
    end
  end
  for fault in pairs(previous) do
    if nextObserved[fault] == nil then
      changed = true
    end
  end
  return nextObserved, changed
end

local function publishFaultObservations(snapshot)
  local sessionId = tonumber(snapshot.session_id)
  local observedAt = math.floor((tonumber(snapshot.observed_at_ms) or os.time() * 1000) / 1000)
  local changed = false
  if sessionId ~= faultObservations.session_id then
    faultObservations = { session_id = sessionId, active = {}, logged = {} }
    changed = true
  end
  local active, activeChanged = reconcileObservedFaults(
    faultObservations.active,
    snapshot.active_faults,
    observedAt
  )
  local logged, loggedChanged = reconcileObservedFaults(
    faultObservations.logged,
    snapshot.logged_faults,
    observedAt
  )
  faultObservations.active = active
  faultObservations.logged = logged
  if changed or activeChanged or loggedChanged then
    noctalia.state.set(FAULT_OBSERVATIONS_KEY, {
      session_id = sessionId,
      active = active,
      logged = logged,
    })
  end
end

local function publishTelemetry(snapshot)
  local capability = math.max(tonumber(snapshot.cable_capability_w) or 1, 1)
  push(series.power, clamp((tonumber(snapshot.total_power_w) or 0) / capability, 0, 1))
  push(series.current, clamp((tonumber(snapshot.total_current_a) or 0) / 55, 0, 1))
  push(series.temperature, clamp((tonumber(snapshot.input_temp_c) or 0) / 100, 0, 1))
  push(series.fan, clamp((tonumber(snapshot.fan_duty_percent) or 0) / 100, 0, 1))

  lastTelemetryAt = os.time()
  stalePublished = false
  publishFaultObservations(snapshot)
  noctalia.state.set(SNAPSHOT_KEY, snapshot)
  noctalia.state.set(SERIES_KEY, {
    power = copyArray(series.power),
    current = copyArray(series.current),
    temperature = copyArray(series.temperature),
    fan = copyArray(series.fan),
  })
  publishStatus(
    snapshot.stale == true and "stale" or "ready",
    snapshot.stale == true and "The daemon is serving its last known sample." or "Live device telemetry",
    {
      session_id = snapshot.session_id,
      sequence = snapshot.sequence,
    }
  )
end

local fetchTelemetry

fetchTelemetry = function()
  if not compatible then
    return
  end
  if telemetryPending then
    telemetryDirty = true
    return
  end
  telemetryPending = true
  local command = methodCommand("GetTelemetry")
  if command == nil then
    telemetryPending = false
    return
  end
  noctalia.runAsync(command, function(result)
    telemetryPending = false
    local snapshot, replyError = decodeReply(result)
    if snapshot ~= nil
        and type(snapshot.pin_power_w) == "table"
        and type(snapshot.pin_currents_a) == "table"
        and type(snapshot.pin_voltages_v) == "table"
        and #snapshot.pin_power_w == 6
        and #snapshot.pin_currents_a == 6
        and #snapshot.pin_voltages_v == 6 then
      publishTelemetry(snapshot)
    else
      publishStatus("error", replyError or "wireviewd returned an incomplete telemetry sample")
    end
    if telemetryDirty then
      telemetryDirty = false
      fetchTelemetry()
    end
  end, 5000)
end

local function fetchConfiguration()
  if not compatible then
    return
  end
  noctalia.state.set(CONFIG_KEY, { loading = true })
  local command = methodCommand("GetConfiguration")
  noctalia.runAsync(command, function(result)
    local reply, replyError = decodeReply(result)
    if reply == nil then
      noctalia.state.set(CONFIG_KEY, { error = replyError })
      return
    end
    local settings, settingsError = noctalia.json.decode(reply.configuration_json or "")
    if type(settings) ~= "table" then
      noctalia.state.set(CONFIG_KEY, {
        error = "wireviewd returned invalid configuration JSON: " .. tostring(settingsError),
      })
      return
    end
    local pollCommand = methodCommand("GetPollInterval")
    noctalia.runAsync(pollCommand, function(pollResult)
      local pollReply = decodeReply(pollResult)
      noctalia.state.set(CONFIG_KEY, {
        revision = reply.revision,
        settings = settings,
        daemon = {
          poll_interval_ms = pollReply and tonumber(pollReply.milliseconds) or nil,
        },
      })
    end, 5000)
  end, 5000)
end

local enumValues = {
  ["fan.mode"] = { curve = true, fixed = true },
  ["fan.temperature_source"] = {
    input = true,
    output = true,
    external1 = true,
    external2 = true,
    maximum = true,
  },
  ["display.default_screen"] = {
    main = true,
    simple = true,
    current = true,
    temperature = true,
    status = true,
  },
}

local integerRanges = {
  ["backlight_percent"] = { 0, 100 },
  ["fan.duty_min_percent"] = { 0, 100 },
  ["fan.duty_max_percent"] = { 0, 100 },
  ["logging_interval_seconds"] = { 0, 255 },
  ["daemon.poll_interval_ms"] = { 100, 5000 },
  ["fault_thresholds.total_current_a"] = { 0, 150 },
  ["fault_thresholds.total_power_w"] = { 0, 2000 },
  ["fault_thresholds.current_imbalance_percent"] = { 0, 100 },
  ["fault_thresholds.current_imbalance_min_load_a"] = { 0, 10 },
}

local decimalRanges = {
  ["fault_thresholds.temperature_c"] = { 0, 120 },
  ["fault_thresholds.wire_current_a"] = { 0, 25.5 },
}

local allowedAveraging = {
  [22] = true,
  [44] = true,
  [89] = true,
  [177] = true,
  [354] = true,
  [709] = true,
  [1417] = true,
}

local function normalizedValue(key, value)
  local enums = enumValues[key]
  if enums ~= nil then
    local text = tostring(value)
    return enums[text] and text or nil
  end
  if key == "averaging_ms" then
    local number = tonumber(value)
    return number ~= nil and allowedAveraging[number] and tostring(math.floor(number)) or nil
  end
  local range = integerRanges[key]
  if range ~= nil then
    local number = tonumber(value)
    if number ~= nil and number == math.floor(number) and number >= range[1] and number <= range[2] then
      return tostring(math.floor(number))
    end
  end
  local decimalRange = decimalRanges[key]
  if decimalRange ~= nil then
    local number = tonumber(value)
    if number ~= nil and number >= decimalRange[1] and number <= decimalRange[2]
        and math.abs(number * 10 - math.floor(number * 10 + 0.5)) < 0.0001 then
      return string.format("%.1f", number)
    end
  end
  return nil
end

local function finishOperation(id, status, message, persist)
  noctalia.state.set(CONFIG_OPERATION_KEY, {
    id = id,
    status = status,
    message = message,
    persist = persist,
  })
end

local screenAliases = {
  main = "main",
  simple = "simple",
  current = "current",
  temp = "temperature",
  temperature = "temperature",
  status = "status",
}

local screenLabels = {
  main = "Main",
  simple = "Simple",
  current = "Current",
  temperature = "Temperature",
  status = "Status",
}

local function normalizedScreen(value)
  return screenAliases[tostring(value):lower()]
end

local function finishScreenOperation(id, status, message, screen)
  noctalia.state.set(SCREEN_OPERATION_KEY, {
    id = id,
    status = status,
    message = message,
    screen = screen,
    updated_at = os.time(),
  })
end

local function handleScreenRequest(request)
  if type(request) ~= "table" or request.action ~= "set" then
    return
  end
  local screen = normalizedScreen(request.screen)
  if screen == nil then
    finishScreenOperation(request.id, "error", "The screen request was invalid.", nil)
    return
  end
  if not compatible then
    finishScreenOperation(request.id, "error", "The WireView device is not connected.", nil)
    return
  end

  finishScreenOperation(request.id, "running", "Switching the screen shown on the device…", screen)
  local command = methodCommand("SetScreen", { screen = screen })
  noctalia.runAsync(command, function(result)
    local reply, replyError = decodeReply(result)
    if reply == nil then
      finishScreenOperation(request.id, "error", replyError, nil)
      return
    end
    local active = normalizedScreen(reply.active) or screen
    finishScreenOperation(
      request.id,
      "success",
      "Showing " .. screenLabels[active] .. " on the device.",
      active
    )
  end, 10000)
end

local function applyItems(request, items, index)
  if index > #items then
    finishOperation(
      request.id,
      "success",
      request.persist and "Stored on the WireView device." or "Applied until reload or reboot.",
      request.persist
    )
    fetchConfiguration()
    return
  end

  local item = items[index]
  local value = normalizedValue(item.key, item.value)
  if value == nil then
    finishOperation(request.id, "error", "Rejected invalid setting " .. tostring(item.key), request.persist)
    return
  end

  local method
  local parameters
  if item.key == "daemon.poll_interval_ms" then
    method = "SetPollInterval"
    parameters = { milliseconds = tonumber(value) }
  else
    method = "SetConfigurationItem"
    parameters = {
      key = item.key,
      value = value,
      persist = request.persist == true,
      confirm = request.persist == true,
    }
  end

  local command = methodCommand(method, parameters)
  noctalia.runAsync(command, function(result)
    local _, replyError = decodeReply(result)
    if replyError ~= nil then
      finishOperation(request.id, "error", replyError, request.persist)
      fetchConfiguration()
      return
    end
    applyItems(request, items, index + 1)
  end, 60000)
end

local function handleConfigurationRequest(request)
  if type(request) ~= "table" then
    return
  end
  if request.action == "refresh" then
    fetchConfiguration()
    return
  end
  if request.action ~= "apply" or type(request.items) ~= "table" or #request.items > 18 then
    return
  end

  local items = {}
  for _, item in ipairs(request.items) do
    if type(item) == "table" and normalizedValue(item.key, item.value) ~= nil then
      table.insert(items, { key = item.key, value = item.value })
    else
      finishOperation(request.id, "error", "The configuration request was invalid.", request.persist)
      return
    end
  end
  if #items == 0 then
    finishOperation(request.id, "success", "No settings changed.", request.persist)
    return
  end

  finishOperation(request.id, "running", "Writing verified settings to the device…", request.persist)
  applyItems(request, items, 1)
end

local function finishFaultOperation(id, status, message, fault)
  noctalia.state.set(FAULT_OPERATION_KEY, {
    id = id,
    status = status,
    message = message,
    fault = fault,
    updated_at = os.time(),
  })
end

local function masksOverlap(left, right)
  local a = math.floor(tonumber(left) or 0)
  local b = math.floor(tonumber(right) or 0)
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then
      return true
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
  end
  return false
end

local function handleFaultRequest(request)
  if type(request) ~= "table" or request.action ~= "clear" or request.confirm ~= true then
    return
  end
  local activeMask = math.floor(tonumber(request.active_mask) or 0)
  local loggedMask = math.floor(tonumber(request.logged_mask) or 0)
  if activeMask < 0 or loggedMask < 0
      or activeMask > KNOWN_FAULT_MASK or loggedMask > KNOWN_FAULT_MASK
      or (activeMask == 0 and loggedMask == 0) then
    finishFaultOperation(request.id, "error", "The alarm clear request was invalid.", request.fault)
    return
  end

  finishFaultOperation(request.id, "running", "Clearing the device alarm…", request.fault)
  local command = methodCommand("ClearFaults", {
    active_mask = activeMask,
    logged_mask = loggedMask,
    confirm = true,
  })
  noctalia.runAsync(command, function(result)
    local refreshed, replyError = decodeReply(result)
    if refreshed == nil then
      finishFaultOperation(request.id, "error", replyError, request.fault)
      return
    end
    publishTelemetry(refreshed)
    local stillPresent = masksOverlap(refreshed.active_fault_mask, activeMask)
      or masksOverlap(refreshed.logged_fault_mask, loggedMask)
    finishFaultOperation(
      request.id,
      stillPresent and "warning" or "success",
      stillPresent and "Alarm remains on the device because the condition is still present."
        or "Alarm cleared on the device.",
      request.fault
    )
  end, 10000)
end

local probeStatus

local function handleMonitorLine(line)
  local cleaned = tostring(line):gsub("^%c+", "")
  local event = noctalia.json.decode(cleaned)
  if type(event) ~= "table" then
    return
  end
  if event.event == "snapshot" then
    finishScreenOperation(nil, "unknown", nil, nil)
    compatible = false
    probeStatus()
  elseif event.event == "screen_changed" then
    local screen = normalizedScreen(event.screen)
    if screen ~= nil then
      finishScreenOperation(
        "event:" .. tostring(event.sequence or os.time()),
        "success",
        "Showing " .. screenLabels[screen] .. " on the device.",
        screen
      )
    end
  elseif event.event == "telemetry_updated"
      or event.event == "connected"
      or event.event == "disconnected" then
    if event.event == "disconnected" then
      finishScreenOperation(nil, "unknown", nil, nil)
    end
    fetchTelemetry()
  end
end

local function startMonitor()
  if monitorStarted then
    return
  end
  local command = "while true; do python3 " .. shellQuote(bridgePath)
    .. " monitor 2>/dev/null; sleep 1; done"
  monitorStarted = noctalia.runStream(command, handleMonitorLine)
  if not monitorStarted then
    publishStatus("error", "Noctalia could not start the device monitor.")
  end
end

probeStatus = function()
  if statusPending then
    return
  end
  statusPending = true
  lastStatusProbeAt = os.time()
  publishStatus("connecting", "Connecting to wireviewd…")
  local command = methodCommand("GetStatus")
  noctalia.runAsync(command, function(result)
    statusPending = false
    local status, replyError = decodeReply(result)
    if status == nil then
      compatible = false
      publishStatus("offline", replyError)
      return
    end
    if not SUPPORTED_APIS[tonumber(status.api_version)] then
      compatible = false
      publishStatus(
        "incompatible",
        "wireviewd API " .. tostring(status.api_version) .. " is not supported by this plugin.",
        status
      )
      return
    end
    if not hasCapability(status, "telemetry")
        or not hasCapability(status, "configuration-items")
        or not hasCapability(status, "device-control") then
      compatible = false
      publishStatus("incompatible", "wireviewd is missing required API capabilities.", status)
      return
    end

    lastDaemonStatus = status
    compatible = true
    publishStatus(status.state == "ready" and "ready" or "connecting", status.state, status)
    fetchTelemetry()
    fetchConfiguration()
  end, 5000)
end

local function start()
  if not noctalia.commandExists("python3") then
    publishStatus("missing", "Install Python 3 to connect to wireviewd.")
    return
  end
  if bridgePath == nil then
    publishStatus("error", "Noctalia did not provide the plugin directory.")
    return
  end
  startMonitor()
  probeStatus()
end

noctalia.state.watch(CONFIG_REQUEST_KEY, handleConfigurationRequest)
noctalia.state.watch(SCREEN_REQUEST_KEY, handleScreenRequest)
noctalia.state.watch(FAULT_REQUEST_KEY, handleFaultRequest)

function update()
  noctalia.setUpdateInterval(1000)
  if not compatible and not statusPending and os.time() - lastStatusProbeAt >= 3 then
    probeStatus()
  end
  if compatible and not stalePublished
      and lastTelemetryAt ~= nil and os.time() - lastTelemetryAt > 8 then
    stalePublished = true
    publishStatus("stale", "No telemetry event has arrived for eight seconds.")
  end
end

start()
