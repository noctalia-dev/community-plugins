--!nonstrict

local SNAPSHOT_KEY = "audio_switcher_snapshot"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {
  available = false,
  loading = true,
  outputs = {},
  inputs = {},
  outputVolume = 0,
  inputVolume = 0,
  outputMuted = false,
}

local function activeDevice(devices, fallback)
  for _, device in ipairs(type(devices) == "table" and devices or {}) do
    if device.active == true then return device end
  end
  return nil
end

local function percent(value)
  return tostring(math.floor((tonumber(value) or 0) + 0.5)) .. "%"
end

local function render()
  local outputDevice = activeDevice(snapshot.outputs)
  local inputDevice = activeDevice(snapshot.inputs)
  local outputName = outputDevice and tostring(outputDevice.name or "") or noctalia.tr("panel.no_output")
  local inputName = inputDevice and tostring(inputDevice.name or "") or noctalia.tr("panel.no_input")
  local outputVolume = percent(snapshot.outputVolume)
  local inputVolume = percent(snapshot.inputVolume)

  local glyph = snapshot.outputMuted == true and "volume-off" or "volume"
  if outputDevice ~= nil and snapshot.outputMuted ~= true then
    glyph = tostring(outputDevice.icon or "volume")
  end

  barWidget.setGlyph(glyph)
  if snapshot.busy == true then
    barWidget.setGlyphColor("secondary")
  elseif snapshot.available == true then
    barWidget.setGlyphColor("default")
  else
    barWidget.setGlyphColor("error")
  end

  local showPercentage = noctalia.getConfig("show_percentage") ~= false
  barWidget.setText(showPercentage and not barWidget.isVertical() and outputVolume or "")
  local tooltipItems = {{key = noctalia.tr("widget.output"), value = `{outputName} ({outputVolume})`},
                        {key = noctalia.tr("widget.input"), value = `{inputName} ({inputVolume})`}}
  if noctalia.getConfig("show_actions_in_tooltip") == true then
    table.insert(tooltipItems, {key = noctalia.tr("widget.action.scroll.key"), value = noctalia.tr("widget.action.scroll.description")})
    table.insert(tooltipItems, {key = noctalia.tr("widget.action.left_click.key"), value = noctalia.tr("widget.action.left_click.description")})
    table.insert(tooltipItems, {key = noctalia.tr("widget.action.right_click.key"), value = noctalia.tr("widget.action.right_click.description")})
    table.insert(tooltipItems, {key = noctalia.tr("widget.action.middle_click.key"), value = noctalia.tr("widget.action.middle_click.description")})
  end
  barWidget.setTooltip(tooltipItems)
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function onConfigChanged()
  render()
end

render()
