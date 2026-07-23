--!nonstrict

local PANEL_ID = "blackbartblues/audio-switcher:audio-switcher"
local SNAPSHOT_KEY = "audio_switcher_snapshot"
local COMMAND_KEY = "audio_switcher_command"
local RESULT_KEY = "audio_switcher_result"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {
  available = false,
  loading = true,
  outputs = {},
  inputs = {},
  outputVolume = 0,
  inputVolume = 0,
  outputMuted = false,
}
local requestId = 0
local outputVolumeDraft = nil

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
  local outputVolume = percent(outputVolumeDraft or snapshot.outputVolume)
  local inputVolume = percent(snapshot.inputVolume)

  local glyph = snapshot.outputMuted == true and "volume-off" or "volume"
  if outputDevice ~= nil and snapshot.outputMuted ~= true then
    glyph = tostring(outputDevice.icon or "volume")
  end

  barWidget.setGlyph(glyph)
  if snapshot.busy == true then
    barWidget.setGlyphColor("secondary")
  elseif snapshot.available == true then
    barWidget.setGlyphColor("primary")
  else
    barWidget.setGlyphColor("error")
  end

  local showPercentage = noctalia.getConfig("show_percentage") ~= false
  barWidget.setText(showPercentage and not barWidget.isVertical() and outputVolume or "")
  barWidget.setTooltip(noctalia.tr("widget.tooltip", {
    output = outputName,
    output_volume = outputVolume,
    input = inputName,
    input_volume = inputVolume,
  }))
end

local function dispatch(action)
  requestId += 1
  noctalia.state.set(COMMAND_KEY, {
    action = action,
    requestId = "widget-" .. tostring(os.time()) .. "-" .. tostring(requestId),
  })
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
  if type(value) == "table" then
    if outputVolumeDraft ~= nil and tonumber(value.outputVolume) == outputVolumeDraft then
      outputVolumeDraft = nil
    end
    snapshot = value
    render()
  end
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" or not tostring(result.requestId or ""):match("^widget%-scroll%-") then return end
  if result.ok ~= true then
    outputVolumeDraft = nil
    render()
  end
end)

function update()
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  dispatch("cycle_output")
end

function onMiddleClick()
  dispatch("cycle_input")
end

function onScroll(axis, steps)
  if axis ~= "vertical" then return end
  local detents = tonumber(steps) or 0
  if detents == 0 then return end
  local step = math.max(1, math.min(25, math.floor(tonumber(noctalia.getConfig("scroll_step")) or 5)))
  local current = tonumber(outputVolumeDraft or snapshot.outputVolume) or 0
  outputVolumeDraft = math.max(0, math.min(100, math.floor(current - detents * step + 0.5)))
  render()
  requestId += 1
  noctalia.state.set(COMMAND_KEY, {
    action = "set_output_volume",
    value = outputVolumeDraft,
    requestId = "widget-scroll-" .. tostring(os.time()) .. "-" .. tostring(requestId),
  })
end

noctalia.setUpdateInterval(60000)
render()
