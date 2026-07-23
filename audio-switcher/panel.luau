--!nonstrict

local SNAPSHOT_KEY = "audio_switcher_snapshot"
local COMMAND_KEY = "audio_switcher_command"
local RESULT_KEY = "audio_switcher_result"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {
  available = false,
  bluetoothAvailable = false,
  loading = true,
  busy = false,
  scanning = false,
  outputs = {},
  inputs = {},
  defaultOutputId = "",
  defaultInputId = "",
  outputVolume = 0,
  inputVolume = 0,
  outputMuted = false,
  inputMuted = false,
  error = "",
  updatedAt = 0,
}

local activeTab = "output"
local showHidden = false
local editingId = nil
local editAlias = ""
local editIconStyle = "automatic"
local editSlot = ""
local feedback = ""
local feedbackError = false
local requestCounter = 0
-- Slider onChange is also emitted when the host applies a new controlled value.
-- Keep the last callback value only for onDragEnd; rendering from it would turn
-- the first external update into a sticky local draft and freeze later updates.
local outputVolumeCommitValue = nil
local inputVolumeCommitValue = nil
local volumeControlRevision = 0
local env = getfenv()
local render

local ICON_STYLE_VALUES = { "automatic", "speaker", "over_ear", "tws", "wired" }

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local function asArray(value)
  return type(value) == "table" and value or {}
end

local function nextRequestId()
  requestCounter += 1
  return "panel-" .. tostring(requestCounter)
end

local function sendCommand(action, values)
  local command = { action = action, requestId = nextRequestId() }
  if type(values) == "table" then
    for key, value in pairs(values) do command[key] = value end
  end
  noctalia.state.set(COMMAND_KEY, command)
  return command.requestId
end

local function rowCallback(prefix, index, callback)
  local name = prefix .. "_" .. tostring(index)
  env[name] = callback
  return name
end

local function activeDevice(kind)
  local devices = kind == "output" and asArray(snapshot.outputs) or asArray(snapshot.inputs)
  for _, device in ipairs(devices) do
    if device.active then return device end
  end
  return nil
end

local function visibleCount(kind)
  local count = 0
  local devices = kind == "output" and asArray(snapshot.outputs) or asArray(snapshot.inputs)
  for _, device in ipairs(devices) do
    if not device.hidden then count += 1 end
  end
  return count
end

local function hiddenCount(kind)
  local count = 0
  local devices = kind == "output" and asArray(snapshot.outputs) or asArray(snapshot.inputs)
  for _, device in ipairs(devices) do
    if device.hidden then count += 1 end
  end
  return count
end

local function selectedIndex(values, selected)
  for index, value in ipairs(values) do
    if value == selected then return index - 1 end
  end
  return 0
end

local function volumeCard(kind)
  local isOutput = kind == "output"
  local device = activeDevice(kind)
  local volume = tonumber(isOutput and snapshot.outputVolume or snapshot.inputVolume) or 0
  local muted = isOutput and snapshot.outputMuted == true or snapshot.inputMuted == true
  local icon = isOutput and (muted and "volume-off" or "volume") or (muted and "microphone-mute" or "microphone")
  return ui.column({ flexGrow = 1, gap = 8, padding = 12, radius = 12, fill = "surface_variant/0.45" }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = isOutput and "volume" or "microphone", size = 18, color = isOutput and "primary" or "tertiary" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = tr(isOutput and "panel.output_volume" or "panel.input_volume"), fontWeight = "bold" }),
        ui.label({
          text = device and device.name or tr("panel.no_device"),
          fontSize = 11,
          color = "on_surface_variant",
          maxLines = 1,
        }),
      }),
      ui.label({ text = tostring(volume) .. "%", fontSize = 11, color = "on_surface_variant" }),
      ui.button({
        glyph = icon,
        variant = muted and "destructive" or "ghost",
        controlSize = "sm",
        tooltip = tr(muted and "panel.unmute" or "panel.mute"),
        enabled = device ~= nil,
        onClick = isOutput and "onToggleOutputMute" or "onToggleInputMute",
      }),
    }),
    ui.slider({
      key = "volume-" .. kind .. "-" .. tostring(volumeControlRevision),
      min = 0,
      max = 100,
      step = 1,
      value = volume,
      enabled = device ~= nil,
      onChange = isOutput and "onOutputVolumeChange" or "onInputVolumeChange",
      onDragEnd = isOutput and "onOutputVolumeCommit" or "onInputVolumeCommit",
    }),
  })
end

local function deviceStatus(device)
  if device.active then return tr("device.active") end
  if device.bluetooth and not device.available then return tr("device.bluetooth_disconnected") end
  if device.bluetooth then return tr("device.bluetooth_connected") end
  return tr("device.available")
end

local function deviceSubtitle(device)
  local status = deviceStatus(device)
  local description = noctalia.string.trim(tostring(device.description or ""))
  if description == "" or description == "(null)" or description:lower() == "null" then return status end
  return status .. "  ·  " .. description
end

local function editor(device)
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "edit", size = 16, color = "primary" }),
      ui.label({ text = tr("editor.title"), fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = "onCancelEdit" }),
    }),
    ui.label({ text = tr("editor.alias"), fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = "alias-" .. tostring(device.id),
      value = editAlias,
      placeholder = device.description,
      onChange = "onEditAliasChange",
    }),
    ui.label({ text = tr("editor.icon"), fontSize = 11, color = "on_surface_variant" }),
    ui.select({
      options = {
        tr("editor.icon_options.automatic"),
        tr("editor.icon_options.speaker"),
        tr("editor.icon_options.over_ear"),
        tr("editor.icon_options.tws"),
        tr("editor.icon_options.wired"),
      },
      selectedIndex = selectedIndex(ICON_STYLE_VALUES, editIconStyle),
      width = 220,
      onChange = "onEditIconChange",
    }),
  }
  if device.bluetooth then
    table.insert(children, ui.label({ text = tr("editor.slot"), fontSize = 11, color = "on_surface_variant" }))
    table.insert(children, ui.input({
      key = "slot-" .. tostring(device.id),
      value = editSlot,
      placeholder = "1",
      onChange = "onEditSlotChange",
    }))
    table.insert(children, ui.label({ text = tr("editor.slot_hint"), fontSize = 10, color = "on_surface_variant", maxLines = 2 }))
  end
  table.insert(children, ui.row({ justify = "end", gap = 8 }, {
    ui.button({ text = tr("actions.cancel"), variant = "ghost", onClick = "onCancelEdit" }),
    ui.button({ text = tr("actions.save"), glyph = "device-floppy", variant = "primary", onClick = "onSaveEdit" }),
  }))
  return ui.column({ gap = 7, padding = 10, radius = 9, fill = "surface_variant/0.45", border = "primary/0.35", borderWidth = 1 }, children)
end

local function deviceRow(device, index, kind)
  local useAction = rowCallback("onUse", index, function()
    sendCommand(kind == "output" and "set_output" or "set_input", { id = device.id })
  end)
  local editAction = rowCallback("onEdit", index, function()
    editingId = device.id
    editAlias = tostring(device.name or "")
    editIconStyle = tostring(device.iconStyle or "automatic")
    editSlot = device.slot and tostring(device.slot) or ""
    feedback = ""
    render()
  end)
  local hideAction = rowCallback("onHide", index, function()
    sendCommand("set_hidden", { id = device.id, kind = kind, hidden = not device.hidden })
  end)
  local actionText = device.active and tr("device.current")
    or (device.bluetooth and not device.available and tr("actions.connect_and_use") or tr("actions.use"))
  local actionVariant = device.active and "ghost" or "primary"
  local statusColor = device.active and "secondary" or "on_surface_variant"
  local row = ui.column({ gap = 6 }, {
    ui.row({ align = "center", gap = 8, padding = 7, radius = 9, border = device.active and "primary" or "outline/0.55", borderWidth = 1, fill = device.active and "primary/0.07" or "surface/0" }, {
      ui.glyph({ name = device.icon or (kind == "output" and "volume" or "microphone"), size = 19, color = device.active and "primary" or "on_surface_variant" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = tostring(device.name or device.description or device.id), fontWeight = "bold", maxLines = 1 }),
        ui.label({
          text = deviceSubtitle(device),
          fontSize = 10,
          color = statusColor,
          maxLines = 1,
        }),
      }),
      ui.label({
        text = device.slot and ("#" .. tostring(device.slot)) or "",
        color = "primary",
        fontSize = 11,
        fontWeight = "bold",
        visible = device.bluetooth == true,
      }),
      ui.button({
        text = actionText,
        variant = actionVariant,
        controlSize = "sm",
        enabled = not device.active and snapshot.busy ~= true,
        onClick = useAction,
      }),
      ui.button({ glyph = "edit", variant = "ghost", controlSize = "sm", tooltip = tr("actions.edit"), onClick = editAction }),
      ui.button({
        glyph = device.hidden and "eye" or "eye-off",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr(device.hidden and "actions.show" or "actions.hide"),
        onClick = hideAction,
      }),
    }),
  })
  local children = { row }
  if editingId == device.id then table.insert(children, editor(device)) end
  return ui.column({ gap = 6 }, children)
end

local function deviceList(kind)
  local source = kind == "output" and asArray(snapshot.outputs) or asArray(snapshot.inputs)
  local rows = {}
  local callbackIndex = kind == "output" and 0 or 1000
  for _, device in ipairs(source) do
    if showHidden or not device.hidden then
      table.insert(rows, deviceRow(device, callbackIndex, kind))
      callbackIndex += 1
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.column({ align = "center", justify = "center", gap = 8, padding = 24 }, {
      ui.glyph({ name = kind == "output" and "volume-off" or "microphone-off", size = 32, color = "on_surface_variant" }),
      ui.label({ text = tr(showHidden and "panel.no_devices" or "panel.no_visible_devices"), color = "on_surface_variant", textAlign = "center" }),
    }))
  end
  return ui.column({ gap = 6 }, rows)
end

local function header()
  local output = activeDevice("output")
  local input = activeDevice("input")
  local subtitle = (output and output.name or tr("panel.no_output")) .. "  ·  " .. (input and input.name or tr("panel.no_input"))
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "switch-horizontal", size = 24, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = "bluetooth",
      variant = snapshot.scanning and "primary" or "ghost",
      tooltip = tr(snapshot.scanning and "panel.scanning" or "panel.scan_bluetooth"),
      enabled = snapshot.bluetoothAvailable == true and snapshot.scanning ~= true,
      onClick = "onScanBluetooth",
    }),
    ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("actions.refresh"), onClick = "onRefresh" }),
    ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("actions.settings"), onClick = "onOpenSettingsClicked" }),
    ui.button({ glyph = "close", variant = "ghost", tooltip = tr("actions.close"), onClick = "onCloseClicked" }),
  })
end

local function toolbar()
  local kind = activeTab
  local hidden = hiddenCount(kind)
  return ui.row({ align = "center", gap = 4 }, {
    ui.button({
      text = tr("tabs.outputs"),
      glyph = "volume",
      variant = activeTab == "output" and "primary" or "ghost",
      selected = activeTab == "output",
      onClick = "onShowOutputs",
    }),
    ui.button({
      text = tr("tabs.inputs"),
      glyph = "microphone",
      variant = activeTab == "input" and "primary" or "ghost",
      selected = activeTab == "input",
      onClick = "onShowInputs",
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.label({
      text = tr("panel.visible_count", { count = visibleCount(kind) }),
      fontSize = 10,
      color = "on_surface_variant",
    }),
    ui.button({
      text = hidden > 0 and tr("panel.hidden_count", { count = hidden }) or tr("panel.hidden"),
      glyph = showHidden and "eye" or "eye-off",
      variant = showHidden and "primary" or "ghost",
      selected = showHidden,
      enabled = hidden > 0 or showHidden,
      onClick = "onToggleHidden",
    }),
    ui.button({
      text = tr("actions.cycle"),
      glyph = "refresh",
      variant = "outline",
      enabled = snapshot.busy ~= true,
      onClick = activeTab == "output" and "onCycleOutput" or "onCycleInput",
    }),
  })
end

render = function()
  local statusRows = {}
  if snapshot.loading then
    table.insert(statusRows, ui.label({ text = tr("panel.loading"), color = "primary" }))
  end
  if snapshot.busy then
    table.insert(statusRows, ui.label({ text = tr("panel.switching"), color = "primary" }))
  end
  if tostring(snapshot.error or "") ~= "" then
    table.insert(statusRows, ui.label({ text = snapshot.error, color = "error", maxLines = 2 }))
  end
  if feedback ~= "" then
    table.insert(statusRows, ui.label({ text = feedback, color = feedbackError and "error" or "secondary", maxLines = 2 }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    header(),
    ui.row({ gap = 12, align = "stretch" }, { volumeCard("output"), volumeCard("input") }),
    toolbar(),
    ui.column({ gap = 3 }, statusRows),
    ui.scroll({ flexGrow = 1, gap = 6 }, { deviceList(activeTab) }),
    ui.label({
      text = tr("panel.keybind_hint"),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 2,
    }),
  }))
end

function onOpen(_context)
  feedback = ""
  feedbackError = false
  sendCommand("refresh")
  render()
end

function onConfigChanged()
  render()
end

function onCloseClicked() panel.close() end
function onRefresh() sendCommand("refresh") end
function onScanBluetooth() sendCommand("scan_bluetooth") end
function onCycleOutput() sendCommand("cycle_output") end
function onCycleInput() sendCommand("cycle_input") end
function onOpenSettingsClicked()
  local started = noctalia.runAsync("noctalia msg settings-open plugins", function(result)
    if result.timedOut == true or tonumber(result.exitCode) ~= 0 then
      noctalia.notifyError(tr("title"), tr("errors.command_start"))
    end
  end, 5000)
  if not started then
    noctalia.notifyError(tr("title"), tr("errors.command_start"))
  end
end

function onShowOutputs()
  activeTab = "output"
  editingId = nil
  showHidden = false
  render()
end

function onShowInputs()
  activeTab = "input"
  editingId = nil
  showHidden = false
  render()
end

function onToggleHidden()
  showHidden = not showHidden
  editingId = nil
  render()
end

function onCancelEdit()
  editingId = nil
  render()
end

function onEditAliasChange(value) editAlias = tostring(value or "") end
function onEditIconChange(index, _label)
  editIconStyle = ICON_STYLE_VALUES[(math.floor(tonumber(index) or 0)) + 1] or "automatic"
end
function onEditSlotChange(value) editSlot = tostring(value or "") end

function onSaveEdit()
  local devices = activeTab == "output" and asArray(snapshot.outputs) or asArray(snapshot.inputs)
  for _, device in ipairs(devices) do
    if device.id == editingId then
      sendCommand("update_device", {
        id = device.id,
        address = device.address,
        alias = editAlias,
        iconStyle = editIconStyle,
        slot = editSlot,
      })
      editingId = nil
      render()
      return
    end
  end
end

function onOutputVolumeChange(value)
  outputVolumeCommitValue = math.floor(tonumber(value) or 0)
end

function onInputVolumeChange(value)
  inputVolumeCommitValue = math.floor(tonumber(value) or 0)
end

-- Noctalia's slider onDragEnd callback has no arguments. Keep the latest
-- onChange value for the commit without using it as controlled render state.
function onOutputVolumeCommit()
  local value = outputVolumeCommitValue or snapshot.outputVolume
  outputVolumeCommitValue = nil
  sendCommand("set_output_volume", { value = value })
end
function onInputVolumeCommit()
  local value = inputVolumeCommitValue or snapshot.inputVolume
  inputVolumeCommitValue = nil
  sendCommand("set_input_volume", { value = value })
end
function onToggleOutputMute() sendCommand("toggle_output_mute") end
function onToggleInputMute() sendCommand("toggle_input_mute") end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" or not tostring(result.requestId or ""):match("^panel%-") then return end
  feedback = tostring(result.message or "")
  feedbackError = result.ok ~= true
  if result.ok ~= true and (result.action == "set_output_volume" or result.action == "set_input_volume") then
    outputVolumeCommitValue = nil
    inputVolumeCommitValue = nil
    -- A failed optimistic edit may have moved the native slider while the
    -- controlled snapshot stayed unchanged. Recreate both controls so their
    -- visual values are seeded from the authoritative snapshot again.
    volumeControlRevision += 1
  end
  render()
end)

render()
