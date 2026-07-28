--!nonstrict
-- Audio Switcher backend. The service is the single owner of pactl and
-- bluetoothctl subprocesses; panels and compositor keybinds talk to it through
-- shared state and onIpc().

local SNAPSHOT_KEY = "audio_switcher_snapshot"
local COMMAND_KEY = "audio_switcher_command"
local RESULT_KEY = "audio_switcher_result"
local PREFERENCES_VERSION = 1
local REFRESH_INTERVAL_MS = 3000
local BLUETOOTH_CONNECT_RETRIES = 16
local BLUETOOTH_CONNECT_RETRY_SECONDS = 0.25

local dataDir = noctalia.pluginDataDir()
local preferencesPath = dataDir and (dataDir .. "/preferences.json") or nil

local preferences = {
  version = PREFERENCES_VERSION,
  aliases = {},
  hiddenOutputs = {},
  hiddenInputs = {},
  slots = {},
  knownBluetoothInputs = {},
  icons = {},
}

local snapshot = {
  available = false,
  bluetoothAvailable = false,
  loading = true,
  busy = false,
  scanning = false,
  outputs = {},
  inputs = {},
  bluetooth = {},
  defaultOutputId = "",
  defaultInputId = "",
  outputVolume = 0,
  inputVolume = 0,
  outputMuted = false,
  inputMuted = false,
  error = "",
  updatedAt = 0,
  revision = 0,
}

local refreshPending = false
local refreshAgain = false
local actionBusy = false
local scanning = false
local preferencesDirty = false
local volumeOperations = {
  output = { running = false, pending = nil, desiredValue = nil },
  input = { running = false, pending = nil, desiredValue = nil },
}
local volumeRefreshes = {
  output = { running = false, again = false },
  input = { running = false, again = false },
}
local audioEventRevisions = { output = 0, input = 0 }

local refreshAll
local setOutput
local setInput
local connectBluetooth
local assignSlot

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function shellCommand(args)
  local quoted = {}
  for _, value in ipairs(args) do
    table.insert(quoted, shellQuote(value))
  end
  return table.concat(quoted, " ")
end

local function runCommand(args, callback, timeoutMs)
  local started = noctalia.runAsync(shellCommand(args), callback, timeoutMs or 15000)
  if not started and type(callback) == "function" then
    callback({
      exitCode = -1,
      stdout = "",
      stderr = noctalia.tr("errors.command_start"),
      timedOut = false,
      stdoutTruncated = false,
      stderrTruncated = false,
    })
  end
  return started
end

local function runPactl(args, callback, timeoutMs)
  local command = { "pactl" }
  for _, value in ipairs(args) do table.insert(command, value) end
  return runCommand(command, callback, timeoutMs)
end

local function runBluetoothctl(args, callback, timeoutMs)
  local command = { "bluetoothctl" }
  for _, value in ipairs(args) do table.insert(command, value) end
  return runCommand(command, callback, timeoutMs or 30000)
end

local function decodeJson(value)
  local decoded, err = noctalia.json.decode(tostring(value or ""))
  if type(decoded) ~= "table" then
    noctalia.log("audio-switcher: JSON decode failed: " .. tostring(err or "unknown error"))
    return nil
  end
  return decoded
end

local function normalizeMap(value)
  return type(value) == "table" and value or {}
end

local function setPreference(map, key, value)
  if map[key] == value then return false end
  map[key] = value
  preferencesDirty = true
  return true
end

local function validIconStyle(value)
  value = tostring(value or "automatic")
  if value == "speaker" or value == "over_ear" or value == "tws" or value == "wired" then return value end
  return "automatic"
end

local function loadPreferences()
  if preferencesPath == nil then return end
  local raw = noctalia.readFile(preferencesPath)
  if raw == nil then return end
  local decoded = decodeJson(raw)
  if decoded == nil then return end
  preferences.version = PREFERENCES_VERSION
  preferences.aliases = normalizeMap(decoded.aliases)
  preferences.hiddenOutputs = normalizeMap(decoded.hiddenOutputs)
  preferences.hiddenInputs = normalizeMap(decoded.hiddenInputs)
  preferences.slots = normalizeMap(decoded.slots)
  preferences.knownBluetoothInputs = normalizeMap(decoded.knownBluetoothInputs)
  preferences.icons = normalizeMap(decoded.icons)
end

local function savePreferences()
  if not preferencesDirty then return true end
  if preferencesPath == nil then return false end
  local encoded, encodeError = noctalia.json.encode(preferences, true)
  if encoded == nil then
    noctalia.log("audio-switcher: could not encode preferences: " .. tostring(encodeError or "unknown error"))
    return false
  end
  local ok, writeError = noctalia.writeFile(preferencesPath, encoded)
  if not ok then
    noctalia.log("audio-switcher: could not save preferences: " .. tostring(writeError or "unknown error"))
  else
    preferencesDirty = false
  end
  return ok == true
end

local function bluetoothOutputId(address)
  return "bluetooth:" .. address:upper() .. ":output"
end

local function bluetoothInputId(address)
  return "bluetooth:" .. address:upper() .. ":input"
end

local function bluetoothAddressFromId(id)
  return tostring(id or ""):match("^bluetooth:([%x:]+):")
end

local function displayName(id, fallback)
  local alias = trim(preferences.aliases[id])
  return alias ~= "" and alias or fallback
end

local function resolvedDeviceIcon(id, automaticIcon)
  local style = validIconStyle(preferences.icons[id])
  local glyphs = {
    speaker = "device-speaker",
    over_ear = "headphones",
    tws = "device-airpods",
    wired = "headset",
  }
  return glyphs[style] or automaticIcon, style
end

local function firstVolumePercent(volume)
  if type(volume) ~= "table" then return 0 end
  for _, channel in pairs(volume) do
    if type(channel) == "table" then
      local percent = tostring(channel.value_percent or ""):match("(%d+)%%")
      if percent ~= nil then return tonumber(percent) or 0 end
    end
  end
  return 0
end

local function propertiesOf(item)
  return type(item.properties) == "table" and item.properties or {}
end

local function bluetoothAddress(properties)
  local value = trim(properties["api.bluez5.address"])
  if value == "" and properties["device.bus"] == "bluetooth" then
    value = trim(properties["device.string"])
  end
  return value:upper()
end

local function makeOutput(item, defaultName)
  local properties = propertiesOf(item)
  local address = bluetoothAddress(properties)
  local isBluetooth = address ~= ""
  local stableId = isBluetooth and bluetoothOutputId(address) or tostring(item.name or "")
  local fallback = tostring(properties["device.alias"] or item.description or item.name or stableId)
  local icon, iconStyle = resolvedDeviceIcon(stableId, isBluetooth and "headphones" or "device-speaker")
  return {
    id = stableId,
    targetName = tostring(item.name or ""),
    name = displayName(stableId, fallback),
    description = tostring(item.description or item.name or ""),
    active = tostring(item.name or "") == defaultName,
    available = true,
    bluetooth = isBluetooth,
    address = address,
    hidden = preferences.hiddenOutputs[stableId] == true,
    slot = isBluetooth and tonumber(preferences.slots[address]) or nil,
    volume = firstVolumePercent(item.volume),
    muted = item.mute == true,
    icon = icon,
    iconStyle = iconStyle,
  }
end

local function makeInput(item, defaultName)
  local properties = propertiesOf(item)
  if tostring(properties["device.class"] or "") == "monitor" or tostring(item.name or ""):match("%.monitor$") then
    return nil
  end
  local address = bluetoothAddress(properties)
  local isBluetooth = address ~= ""
  local stableId = isBluetooth and bluetoothInputId(address) or tostring(item.name or "")
  local fallback = tostring(properties["device.alias"] or item.description or item.name or stableId)
  if isBluetooth then setPreference(preferences.knownBluetoothInputs, address, fallback) end
  local icon, iconStyle = resolvedDeviceIcon(stableId, isBluetooth and "headset" or "microphone")
  return {
    id = stableId,
    targetName = tostring(item.name or ""),
    name = displayName(stableId, fallback),
    description = tostring(item.description or item.name or ""),
    active = tostring(item.name or "") == defaultName,
    available = true,
    bluetooth = isBluetooth,
    address = address,
    hidden = preferences.hiddenInputs[stableId] == true,
    slot = isBluetooth and tonumber(preferences.slots[address]) or nil,
    volume = firstVolumePercent(item.volume),
    muted = item.mute == true,
    icon = icon,
    iconStyle = iconStyle,
  }
end

local function sortDevices(devices)
  table.sort(devices, function(a, b)
    if a.active ~= b.active then return a.active end
    if a.available ~= b.available then return a.available end
    return tostring(a.name):lower() < tostring(b.name):lower()
  end)
end

local function parseInfo(output)
  local decoded = decodeJson(output)
  if decoded == nil then return nil end
  return {
    defaultSink = tostring(decoded.default_sink_name or ""),
    defaultSource = tostring(decoded.default_source_name or ""),
  }
end

local function parseOutputs(output, defaultName)
  local decoded = decodeJson(output)
  local devices = {}
  if decoded == nil then return devices end
  for _, item in ipairs(decoded) do
    if type(item) == "table" and trim(item.name) ~= "" then
      table.insert(devices, makeOutput(item, defaultName))
    end
  end
  sortDevices(devices)
  return devices
end

local function parseInputs(output, defaultName)
  local decoded = decodeJson(output)
  local devices = {}
  if decoded == nil then return devices end
  for _, item in ipairs(decoded) do
    if type(item) == "table" and trim(item.name) ~= "" then
      local device = makeInput(item, defaultName)
      if device ~= nil then table.insert(devices, device) end
    end
  end
  sortDevices(devices)
  return devices
end

local function parseBluetoothDeviceLines(output)
  local devices = {}
  for line in (tostring(output or "") .. "\n"):gmatch("(.-)\n") do
    local address, name = line:match("^Device%s+([%x:]+)%s+(.+)$")
    if address ~= nil then
      table.insert(devices, { address = address:upper(), name = trim(name) })
    end
  end
  return devices
end

local function parseYes(value)
  return tostring(value or ""):lower() == "yes"
end

local function parseBluetoothInfo(seed, output)
  local device = {
    id = bluetoothOutputId(seed.address),
    address = seed.address,
    name = seed.name,
    description = seed.name,
    icon = "bluetooth",
    paired = false,
    trusted = false,
    connected = false,
    audio = false,
    battery = nil,
    slot = tonumber(preferences.slots[seed.address]),
    hidden = preferences.hiddenOutputs[bluetoothOutputId(seed.address)] == true,
  }
  for line in (tostring(output or "") .. "\n"):gmatch("(.-)\n") do
    local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
    if key == "Alias" and value ~= "" then
      device.description = value
      device.name = displayName(device.id, value)
    elseif key == "Icon" then
      device.icon = value:find("headset", 1, true) and "headset" or value:find("headphone", 1, true) and "headphones" or "device-speaker"
      if value:find("audio", 1, true) then device.audio = true end
    elseif key == "Paired" then
      device.paired = parseYes(value)
    elseif key == "Trusted" then
      device.trusted = parseYes(value)
    elseif key == "Connected" then
      device.connected = parseYes(value)
    elseif key == "Battery Percentage" then
      device.battery = tonumber(value:match("%((%d+)%)") or value:match("(%d+)") or "")
    end
    local uuid = line:match("%(([%x%-]+)%)")
    if uuid ~= nil then
      uuid = uuid:lower()
      if uuid:find("0000110b", 1, true)
        or uuid:find("0000110a", 1, true)
        or uuid:find("0000111e", 1, true)
        or uuid:find("0000184e", 1, true)
        or uuid:find("00001850", 1, true)
        or uuid:find("00001853", 1, true) then
        device.audio = true
      end
    end
  end
  device.icon, device.iconStyle = resolvedDeviceIcon(device.id, device.icon)
  return device
end

local function findOutputById(id)
  for _, device in ipairs(snapshot.outputs) do
    if device.id == id then return device end
  end
  return nil
end

local function findInputById(id)
  for _, device in ipairs(snapshot.inputs) do
    if device.id == id then return device end
  end
  return nil
end

local function findBluetooth(address)
  address = tostring(address or ""):upper()
  for _, device in ipairs(snapshot.bluetooth) do
    if device.address == address then return device end
  end
  return nil
end

local function mergeDisconnectedBluetoothOutputs()
  local present = {}
  for _, output in ipairs(snapshot.outputs) do
    if output.address ~= "" then
      present[output.address] = true
      output.slot = tonumber(preferences.slots[output.address])
    end
  end
  for _, input in ipairs(snapshot.inputs) do
    if input.address ~= "" then input.slot = tonumber(preferences.slots[input.address]) end
  end
  for _, device in ipairs(snapshot.bluetooth) do
    if device.audio and not present[device.address] then
      local id = bluetoothOutputId(device.address)
      table.insert(snapshot.outputs, {
        id = id,
        targetName = "",
        name = displayName(id, device.description),
        description = device.description,
        active = false,
        available = false,
        bluetooth = true,
        address = device.address,
        hidden = preferences.hiddenOutputs[id] == true,
        slot = tonumber(preferences.slots[device.address]),
        volume = 0,
        muted = false,
        icon = device.icon,
        iconStyle = device.iconStyle,
      })
    end
  end
  sortDevices(snapshot.outputs)
end

local function publishSnapshot()
  snapshot.busy = actionBusy
  snapshot.scanning = scanning
  snapshot.revision += 1
  noctalia.state.set(SNAPSHOT_KEY, snapshot)
end

local function resultMessage(command, ok, message)
  noctalia.state.set(RESULT_KEY, {
    requestId = tostring(command and command.requestId or ""),
    action = tostring(command and command.action or ""),
    ok = ok,
    message = message or "",
  })
end

local function notifyResult(ok, message)
  if trim(message) == "" then return end
  if ok then
    noctalia.notify(noctalia.tr("title"), message)
  else
    noctalia.notifyError(noctalia.tr("title"), message)
  end
end

local function finishAction(command, ok, message, shouldNotify)
  actionBusy = false
  resultMessage(command, ok, message)
  if shouldNotify ~= false then notifyResult(ok, message) end
  publishSnapshot()
  refreshAll()
end

local function launchOrFail(args, callback, timeoutMs)
  return runPactl(args, callback, timeoutMs)
end

local function reconcileVolumeDisplay(kind, actualValue)
  local operation = volumeOperations[kind]
  local desired = tonumber(operation.desiredValue)
  if desired == nil then return actualValue end

  -- A pactl list started before the latest wheel request can complete after it
  -- and report an intermediate value. Keep showing the newest request until a
  -- refresh made after the command has settled confirms it.
  if not operation.running and operation.pending == nil and math.abs(actualValue - desired) <= 1 then
    operation.desiredValue = nil
    return actualValue
  end
  return desired
end

local function updateActiveDeviceVolume(kind, volume, muted)
  local devices = kind == "output" and snapshot.outputs or snapshot.inputs
  for _, device in ipairs(devices) do
    if device.active then
      device.volume = volume
      device.muted = muted
      return
    end
  end
end

local function loadCurrentVolume(kind, callback)
  local target = kind == "output" and "@DEFAULT_SINK@" or "@DEFAULT_SOURCE@"
  local volumeCommand = kind == "output" and "get-sink-volume" or "get-source-volume"
  local muteCommand = kind == "output" and "get-sink-mute" or "get-source-mute"
  runPactl({ "-f", "json", volumeCommand, target }, function(volumeResult)
    if volumeResult.exitCode ~= 0 then
      callback(false)
      return
    end
    local volumeData = decodeJson(volumeResult.stdout)
    if volumeData == nil or type(volumeData.volume) ~= "table" then
      callback(false)
      return
    end
    local volume = firstVolumePercent(volumeData.volume)
    runPactl({ "-f", "json", muteCommand, target }, function(muteResult)
      if muteResult.exitCode ~= 0 then
        callback(false)
        return
      end
      local muteData = decodeJson(muteResult.stdout)
      if muteData == nil then
        callback(false)
        return
      end
      callback(true, volume, muteData.mute == true)
    end)
  end)
end

local function refreshCurrentVolume(kind)
  local state = volumeRefreshes[kind]
  if state.running then
    state.again = true
    return
  end
  state.running = true
  state.again = false
  loadCurrentVolume(kind, function(ok, actualVolume, muted)
    if ok then
      local volume = reconcileVolumeDisplay(kind, actualVolume)
      if kind == "output" then
        snapshot.outputVolume = volume
        snapshot.outputMuted = muted
      else
        snapshot.inputVolume = volume
        snapshot.inputMuted = muted
      end
      updateActiveDeviceVolume(kind, volume, muted)
      publishSnapshot()
    end
    state.running = false
    if state.again then refreshCurrentVolume(kind) end
  end)
end

local function loadAudio(callback)
  local outputEventRevision = audioEventRevisions.output
  local inputEventRevision = audioEventRevisions.input
  runPactl({ "-f", "json", "info" }, function(infoResult)
    if infoResult.exitCode ~= 0 then
      callback(false, trim(infoResult.stderr))
      return
    end
    local info = parseInfo(infoResult.stdout)
    if info == nil then
      callback(false, noctalia.tr("errors.invalid_audio_data"))
      return
    end
    runPactl({ "-f", "json", "list", "sinks" }, function(sinkResult)
      if sinkResult.exitCode ~= 0 then
        callback(false, trim(sinkResult.stderr))
        return
      end
      runPactl({ "-f", "json", "list", "sources" }, function(sourceResult)
        if sourceResult.exitCode ~= 0 then
          callback(false, trim(sourceResult.stderr))
          return
        end
        local currentOutputVolume = snapshot.outputVolume
        local currentInputVolume = snapshot.inputVolume
        local currentOutputMuted = snapshot.outputMuted
        local currentInputMuted = snapshot.inputMuted
        snapshot.outputs = parseOutputs(sinkResult.stdout, info.defaultSink)
        snapshot.inputs = parseInputs(sourceResult.stdout, info.defaultSource)
        snapshot.defaultOutputId = ""
        snapshot.defaultInputId = ""
        snapshot.outputVolume = 0
        snapshot.inputVolume = 0
        snapshot.outputMuted = false
        snapshot.inputMuted = false
        for _, output in ipairs(snapshot.outputs) do
          if output.active then
            snapshot.defaultOutputId = output.id
            snapshot.outputVolume = output.volume
            snapshot.outputMuted = output.muted
            break
          end
        end
        for _, input in ipairs(snapshot.inputs) do
          if input.active then
            snapshot.defaultInputId = input.id
            snapshot.inputVolume = input.volume
            snapshot.inputMuted = input.muted
            break
          end
        end
        if audioEventRevisions.output ~= outputEventRevision then
          snapshot.outputVolume = currentOutputVolume
          snapshot.outputMuted = currentOutputMuted
        else
          snapshot.outputVolume = reconcileVolumeDisplay("output", snapshot.outputVolume)
        end
        if audioEventRevisions.input ~= inputEventRevision then
          snapshot.inputVolume = currentInputVolume
          snapshot.inputMuted = currentInputMuted
        else
          snapshot.inputVolume = reconcileVolumeDisplay("input", snapshot.inputVolume)
        end
        updateActiveDeviceVolume("output", snapshot.outputVolume, snapshot.outputMuted)
        updateActiveDeviceVolume("input", snapshot.inputVolume, snapshot.inputMuted)
        callback(true, "")
      end)
    end)
  end)
end

local function loadBluetooth(callback)
  if not noctalia.commandExists("bluetoothctl") then
    snapshot.bluetoothAvailable = false
    snapshot.bluetooth = {}
    callback()
    return
  end
  runBluetoothctl({ "devices" }, function(listResult)
    if listResult.exitCode ~= 0 then
      snapshot.bluetoothAvailable = false
      snapshot.bluetooth = {}
      callback()
      return
    end
    snapshot.bluetoothAvailable = true
    local seeds = parseBluetoothDeviceLines(listResult.stdout)
    local devices = {}
    local index = 1
    local function nextDevice()
      local seed = seeds[index]
      if seed == nil then
        local audioDevices = {}
        for _, device in ipairs(devices) do
          if device.audio then table.insert(audioDevices, device) end
        end
        table.sort(audioDevices, function(a, b)
          if a.connected ~= b.connected then return a.connected end
          if a.paired ~= b.paired then return a.paired end
          return a.name:lower() < b.name:lower()
        end)
        for _, device in ipairs(audioDevices) do
          if device.connected then
            assignSlot(device.address)
            device.slot = tonumber(preferences.slots[device.address])
          end
        end
        snapshot.bluetooth = audioDevices
        callback()
        return
      end
      index += 1
      runBluetoothctl({ "info", seed.address }, function(infoResult)
        if infoResult.exitCode == 0 then
          table.insert(devices, parseBluetoothInfo(seed, infoResult.stdout))
        end
        nextDevice()
      end)
    end
    nextDevice()
  end)
end

refreshAll = function()
  if refreshPending then
    refreshAgain = true
    return
  end
  refreshPending = true
  refreshAgain = false
  snapshot.loading = #snapshot.outputs == 0 and #snapshot.inputs == 0
  publishSnapshot()

  if not noctalia.commandExists("pactl") then
    snapshot.available = false
    snapshot.loading = false
    snapshot.error = noctalia.tr("errors.pactl_missing")
    refreshPending = false
    publishSnapshot()
    return
  end

  loadAudio(function(audioOk, audioError)
    snapshot.available = audioOk
    snapshot.error = audioOk and "" or (trim(audioError) ~= "" and audioError or noctalia.tr("errors.audio_unavailable"))
    loadBluetooth(function()
      mergeDisconnectedBluetoothOutputs()
      snapshot.loading = false
      snapshot.updatedAt = os.time()
      refreshPending = false
      savePreferences()
      publishSnapshot()
      if refreshAgain then refreshAll() end
    end)
  end)
end

local function moveStreams(kind, targetName, callback)
  local listKind = kind == "output" and "sink-inputs" or "source-outputs"
  local moveCommand = kind == "output" and "move-sink-input" or "move-source-output"
  runPactl({ "-f", "json", "list", listKind }, function(result)
    local streams = result.exitCode == 0 and decodeJson(result.stdout) or nil
    if type(streams) ~= "table" or #streams == 0 then
      callback()
      return
    end
    local pending = 0
    for _, stream in ipairs(streams) do
      local index = tonumber(stream.index)
      if index ~= nil then
        pending += 1
        runPactl({ moveCommand, tostring(index), targetName }, function()
          pending -= 1
          if pending == 0 then callback() end
        end)
      end
    end
    if pending == 0 then callback() end
  end)
end

local function setDefaultTarget(command, kind, device)
  local setCommand = kind == "output" and "set-default-sink" or "set-default-source"
  if device == nil or trim(device.targetName) == "" then
    finishAction(command, false, noctalia.tr("errors.device_unavailable"))
    return
  end
  actionBusy = true
  publishSnapshot()
  launchOrFail({ setCommand, device.targetName }, function(result)
    if result.exitCode ~= 0 then
      finishAction(command, false, trim(result.stderr) ~= "" and trim(result.stderr) or noctalia.tr("errors.switch_failed"))
      return
    end
    moveStreams(kind, device.targetName, function()
      local messageKey = kind == "output" and "notifications.output_selected" or "notifications.input_selected"
      finishAction(command, true, noctalia.tr(messageKey, { device = device.name }))
    end)
  end)
end

assignSlot = function(address)
  address = tostring(address or ""):upper()
  if address == "" or tonumber(preferences.slots[address]) ~= nil then return end
  local used = {}
  for _, value in pairs(preferences.slots) do
    local number = tonumber(value)
    if number ~= nil then used[number] = true end
  end
  local slot = 1
  while used[slot] do slot += 1 end
  setPreference(preferences.slots, address, slot)
  savePreferences()
end

local function waitForBluetoothOutput(command, address, attempt)
  runPactl({ "-f", "json", "list", "sinks" }, function(result)
    if result.exitCode == 0 then
      local devices = parseOutputs(result.stdout, "")
      for _, device in ipairs(devices) do
        if device.address == address then
          setDefaultTarget(command, "output", device)
          return
        end
      end
    end
    if attempt >= BLUETOOTH_CONNECT_RETRIES then
      finishAction(command, false, noctalia.tr("errors.bluetooth_audio_timeout"))
      return
    end
    runCommand({ "sleep", tostring(BLUETOOTH_CONNECT_RETRY_SECONDS) }, function()
      waitForBluetoothOutput(command, address, attempt + 1)
    end, 1000)
  end)
end

local function connectTarget(command, target)
  local function afterPair()
    runBluetoothctl({ "connect", target.address }, function(connectResult)
      if connectResult.exitCode ~= 0 then
        finishAction(command, false, trim(connectResult.stderr) ~= "" and trim(connectResult.stderr) or noctalia.tr("errors.bluetooth_connect_failed"))
        return
      end
      assignSlot(target.address)
      waitForBluetoothOutput(command, target.address, 0)
    end)
  end
  if target.paired then
    afterPair()
  else
    runBluetoothctl({ "pair", target.address }, function(pairResult)
      if pairResult.exitCode ~= 0 then
        finishAction(command, false, trim(pairResult.stderr) ~= "" and trim(pairResult.stderr) or noctalia.tr("errors.bluetooth_pair_failed"))
        return
      end
      afterPair()
    end)
  end
end

connectBluetooth = function(command, address)
  if actionBusy then
    resultMessage(command, false, noctalia.tr("errors.busy"))
    return
  end
  address = tostring(address or ""):upper()
  local target = findBluetooth(address)
  if target == nil then
    finishAction(command, false, noctalia.tr("errors.bluetooth_device_not_found"))
    return
  end
  actionBusy = true
  publishSnapshot()

  local connected = {}
  for _, device in ipairs(snapshot.bluetooth) do
    if device.connected and device.address ~= address then table.insert(connected, device.address) end
  end
  local index = 1
  local function disconnectNext()
    local current = connected[index]
    if current == nil then
      connectTarget(command, target)
      return
    end
    index += 1
    runBluetoothctl({ "disconnect", current }, function()
      disconnectNext()
    end)
  end
  disconnectNext()
end

setOutput = function(command, id)
  if actionBusy then
    resultMessage(command, false, noctalia.tr("errors.busy"))
    return
  end
  local device = findOutputById(id)
  if device == nil then
    finishAction(command, false, noctalia.tr("errors.device_not_found"))
    return
  end
  if device.bluetooth and not device.available then
    connectBluetooth(command, device.address)
    return
  end
  setDefaultTarget(command, "output", device)
end

setInput = function(command, id)
  if actionBusy then
    resultMessage(command, false, noctalia.tr("errors.busy"))
    return
  end
  local device = findInputById(id)
  if device == nil then
    finishAction(command, false, noctalia.tr("errors.device_not_found"))
    return
  end
  setDefaultTarget(command, "input", device)
end

local function cycleDevice(command, kind)
  local devices = kind == "output" and snapshot.outputs or snapshot.inputs
  local visible = {}
  local activeIndex = 0
  for _, device in ipairs(devices) do
    if not device.hidden and (kind == "output" or device.available) then
      table.insert(visible, device)
      if device.active then activeIndex = #visible end
    end
  end
  if #visible == 0 then
    finishAction(command, false, noctalia.tr("errors.no_visible_devices"))
    return
  end
  local nextIndex = activeIndex % #visible + 1
  if kind == "output" then setOutput(command, visible[nextIndex].id) else setInput(command, visible[nextIndex].id) end
end

local function findAddressBySlot(slot)
  slot = tonumber(slot)
  if slot == nil then return nil end
  for address, value in pairs(preferences.slots) do
    if tonumber(value) == slot then return address end
  end
  return nil
end

local function updateAlias(command)
  local id = tostring(command.id or "")
  if id == "" then
    resultMessage(command, false, noctalia.tr("errors.device_not_found"))
    return
  end
  local alias = trim(command.alias)
  setPreference(preferences.aliases, id, alias ~= "" and alias or nil)
  savePreferences()
  resultMessage(command, true, noctalia.tr("notifications.preferences_saved"))
  refreshAll()
end

local function updateHidden(command)
  local id = tostring(command.id or "")
  local map = command.kind == "input" and preferences.hiddenInputs or preferences.hiddenOutputs
  setPreference(map, id, command.hidden == true and true or nil)
  savePreferences()
  resultMessage(command, true, noctalia.tr("notifications.preferences_saved"))
  refreshAll()
end

local function updateSlot(command)
  local address = tostring(command.address or bluetoothAddressFromId(command.id) or ""):upper()
  local slot = tonumber(command.slot)
  if address == "" or slot == nil or slot < 1 or slot > 99 or math.floor(slot) ~= slot then
    resultMessage(command, false, noctalia.tr("errors.invalid_slot"))
    return
  end
  for otherAddress, value in pairs(preferences.slots) do
    if otherAddress ~= address and tonumber(value) == slot then
      resultMessage(command, false, noctalia.tr("errors.slot_in_use", { slot = slot }))
      return
    end
  end
  setPreference(preferences.slots, address, slot)
  savePreferences()
  resultMessage(command, true, noctalia.tr("notifications.slot_saved", { slot = slot }))
  refreshAll()
end

local function updateDevice(command)
  local id = tostring(command.id or "")
  local address = tostring(command.address or bluetoothAddressFromId(id) or ""):upper()
  if id == "" then
    resultMessage(command, false, noctalia.tr("errors.device_not_found"))
    return
  end

  local slot = nil
  if address ~= "" and trim(command.slot) ~= "" then
    slot = tonumber(command.slot)
    if slot == nil or slot < 1 or slot > 99 or math.floor(slot) ~= slot then
      resultMessage(command, false, noctalia.tr("errors.invalid_slot"))
      return
    end
    for otherAddress, value in pairs(preferences.slots) do
      if otherAddress ~= address and tonumber(value) == slot then
        resultMessage(command, false, noctalia.tr("errors.slot_in_use", { slot = slot }))
        return
      end
    end
  end

  local alias = trim(command.alias)
  setPreference(preferences.aliases, id, alias ~= "" and alias or nil)
  local iconStyle = validIconStyle(command.iconStyle)
  setPreference(preferences.icons, id, iconStyle ~= "automatic" and iconStyle or nil)
  if address ~= "" and slot ~= nil then setPreference(preferences.slots, address, slot) end
  savePreferences()
  resultMessage(command, true, noctalia.tr("notifications.preferences_saved"))
  refreshAll()
end

local function setVolume(command, kind)
  local requested = tonumber(command.value)
  if requested == nil then
    resultMessage(command, false, noctalia.tr("errors.invalid_volume"))
    return
  end
  local value = math.max(0, math.min(150, math.floor(requested)))
  local operation = volumeOperations[kind]
  local request = { command = command, value = value }
  operation.desiredValue = value

  -- Publish wheel/slider requests immediately so an open panel follows the
  -- requested volume while pactl serializes a burst of wheel events. A failed
  -- command is reconciled by the authoritative refresh below.
  if kind == "output" then
    snapshot.outputVolume = value
  else
    snapshot.inputVolume = value
  end
  publishSnapshot()

  if operation.running then
    -- Keep only the newest requested value. This bounds memory usage and avoids
    -- out-of-order pactl completions while a wheel emits events quickly.
    operation.pending = request
    return
  end

  local applyNext
  applyNext = function(nextRequest)
    operation.running = true
    local target = kind == "output" and "@DEFAULT_SINK@" or "@DEFAULT_SOURCE@"
    local pactlCommand = kind == "output" and "set-sink-volume" or "set-source-volume"
    runPactl({ pactlCommand, target, tostring(nextRequest.value) .. "%" }, function(result)
      resultMessage(nextRequest.command, result.exitCode == 0, trim(result.stderr))
      local pending = operation.pending
      operation.pending = nil
      if pending ~= nil then
        applyNext(pending)
      else
        operation.running = false
        if result.exitCode ~= 0 then operation.desiredValue = nil end
        refreshAll()
      end
    end)
  end

  applyNext(request)
end

local function toggleMute(command, kind)
  local target = kind == "output" and "@DEFAULT_SINK@" or "@DEFAULT_SOURCE@"
  local pactlCommand = kind == "output" and "set-sink-mute" or "set-source-mute"
  runPactl({ pactlCommand, target, "toggle" }, function(result)
    resultMessage(command, result.exitCode == 0, trim(result.stderr))
    refreshAll()
  end)
end

local function disconnectBluetooth(command, address)
  if actionBusy then
    resultMessage(command, false, noctalia.tr("errors.busy"))
    return
  end
  actionBusy = true
  publishSnapshot()
  runBluetoothctl({ "disconnect", tostring(address or ""):upper() }, function(result)
    local ok = result.exitCode == 0
    finishAction(command, ok, ok and noctalia.tr("notifications.bluetooth_disconnected") or trim(result.stderr))
  end)
end

local function scanBluetooth(command)
  if scanning then
    resultMessage(command, false, noctalia.tr("errors.scan_in_progress"))
    return
  end
  scanning = true
  publishSnapshot()
  runBluetoothctl({ "--timeout", "6", "scan", "on" }, function(result)
    scanning = false
    resultMessage(command, result.exitCode == 0, result.exitCode == 0 and noctalia.tr("notifications.scan_complete") or trim(result.stderr))
    refreshAll()
  end, 10000)
end

local function executeCommand(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then return end
  local action = command.action
  if action == "refresh" then
    refreshAll()
  elseif action == "set_output" then
    setOutput(command, tostring(command.id or ""))
  elseif action == "set_input" then
    setInput(command, tostring(command.id or ""))
  elseif action == "cycle_output" then
    cycleDevice(command, "output")
  elseif action == "cycle_input" then
    cycleDevice(command, "input")
  elseif action == "connect_bluetooth" then
    connectBluetooth(command, tostring(command.address or ""))
  elseif action == "disconnect_bluetooth" then
    disconnectBluetooth(command, tostring(command.address or ""))
  elseif action == "scan_bluetooth" then
    scanBluetooth(command)
  elseif action == "set_alias" then
    updateAlias(command)
  elseif action == "set_hidden" then
    updateHidden(command)
  elseif action == "set_slot" then
    updateSlot(command)
  elseif action == "update_device" then
    updateDevice(command)
  elseif action == "set_output_volume" then
    setVolume(command, "output")
  elseif action == "set_input_volume" then
    setVolume(command, "input")
  elseif action == "toggle_output_mute" then
    toggleMute(command, "output")
  elseif action == "toggle_input_mute" then
    toggleMute(command, "input")
  end
end

local function ipcCommand(action, payload)
  return {
    requestId = "ipc-" .. tostring(os.time()),
    action = action,
    payload = payload,
  }
end

function onIpc(event, payload)
  if event == "cycle-output" then
    executeCommand(ipcCommand("cycle_output", payload))
  elseif event == "cycle-input" then
    executeCommand(ipcCommand("cycle_input", payload))
  elseif event == "connect" then
    local command = ipcCommand("connect_bluetooth", payload)
    command.address = findAddressBySlot(payload)
    if command.address == nil then
      resultMessage(command, false, noctalia.tr("errors.slot_not_found", { slot = tostring(payload or "") }))
      notifyResult(false, noctalia.tr("errors.slot_not_found", { slot = tostring(payload or "") }))
      return
    end
    executeCommand(command)
  elseif event == "refresh" then
    refreshAll()
  end
end

loadPreferences()
noctalia.state.watch(COMMAND_KEY, function(command)
  executeCommand(command)
end)

if noctalia.commandExists("pactl") then
  local streamStarted = noctalia.runStream("LC_ALL=C pactl subscribe", function(line)
    local isChange = tostring(line):find("Event 'change'", 1, true) ~= nil
    if tostring(line):find(" on sink #", 1, true) ~= nil then
      audioEventRevisions.output += 1
      if isChange then refreshCurrentVolume("output") else refreshAll() end
    elseif tostring(line):find(" on source #", 1, true) ~= nil then
      audioEventRevisions.input += 1
      if isChange then refreshCurrentVolume("input") else refreshAll() end
    elseif tostring(line):find(" on server", 1, true) ~= nil then
      refreshAll()
    end
  end)
  if not streamStarted then noctalia.log("audio-switcher: could not subscribe to pactl events") end
end

noctalia.setUpdateInterval(REFRESH_INTERVAL_MS)

function update()
  refreshAll()
end

refreshAll()
