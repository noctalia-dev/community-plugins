--!nonstrict
-- Classic rounded track and circular knob, drawn at their actual dimensions.
-- Audio writes are serialized and coalesced; old reads cannot undo a new click.
local SINK = "@DEFAULT_AUDIO_SINK@"
local vol, muted = 0.5, false
local hovering, progress, target = false, 0, 0
local pointerX, trackWidth = nil, 0
local handleWidth = 0
local renderedSliderValue = nil
local sliderEchoes = {}
local dragging, dragWidth, leaveDelay = false, nil, 0
local generation = 0
local wantedVolume, wantedMute = nil, nil
local writePending, pollPending = false, false
local pollElapsed = 300
local render, poll, flush, step
local LEAVE_GRACE_MS = 120
local function clamp(v, low, high) return math.max(low, math.min(high, v)) end
local function number(key, default)
  local value = noctalia.getConfig(key)
  return type(value) == "number" and value or default
end
local function boolean(key, default)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then return value end
  return default
end
local function thickness() return clamp(number("slider_thickness", 12), 4, 24) end
local function colour()
  local role = tostring(noctalia.getConfig("bar_color") or "primary")
  return role == "onsurface" and "on_surface" or role
end
poll = function()
  if pollPending or writePending or wantedVolume ~= nil or wantedMute ~= nil then return end
  pollPending = true
  local readGeneration = generation
  noctalia.runAsync({"wpctl", "get-volume", SINK}, function(result)
    pollPending = false
    if readGeneration ~= generation or writePending or wantedVolume ~= nil or wantedMute ~= nil then
      poll()
      return
    end
    local value = string.match(result.stdout or "", "Volume:%s*([%d%.]+)")
    if result.exitCode == 0 and value then
      vol = tonumber(value) or vol
      muted = string.find(result.stdout or "", "MUTED") ~= nil
      render()
    end
  end, 3000)
end
flush = function()
  if writePending then return end
  local command = nil
  if wantedMute ~= nil then
    command = {"wpctl", "set-mute", SINK, wantedMute and "1" or "0"}
    wantedMute = nil
  elseif wantedVolume ~= nil then
    command = {"wpctl", "set-volume", "-l", "1.0", SINK, tostring(wantedVolume)}
    wantedVolume = nil
  end
  if command == nil then poll(); return end
  writePending = true
  noctalia.runAsync(command, function(result)
    writePending = false
    if result.exitCode ~= 0 then barWidget.setTooltip("Audio change failed; refreshing actual volume") end
    flush()
  end, 3000)
end
local function requestVolume(value)
  vol = clamp(value, 0, 1)
  wantedVolume = vol
  generation += 1
  render()
  flush()
end
function onVolumeDrag(value)
  local requested = tonumber(value)
  if requested then
    -- Native setValue also emits onChange. Its queued callback can arrive after
    -- another animation render, so compare against all outstanding layout values.
    for i, value in ipairs(sliderEchoes) do
      if math.abs(requested - value) < 0.000001 then
        table.remove(sliderEchoes, i)
        return
      end
    end
    if renderedSliderValue ~= nil and math.abs(requested - renderedSliderValue) < 0.000001 then return end
  end
  if requested and trackWidth > 4 then
    dragging, dragWidth, leaveDelay = true, trackWidth, 0
    local x = 2 + requested * (trackWidth - 4)
    requestVolume(requested <= 0 and 0 or requested >= 1 and 1 or (x - handleWidth / 2) / math.max(1, trackWidth - handleWidth))
  end
end
function onVolumeDragEnd()
  dragging, dragWidth = false, nil
  if not hovering then leaveDelay = 500 end
  step()
  flush()
end
function onSpeakerClick()
  muted = not muted
  wantedMute = muted
  generation += 1
  render()
  flush()
end
function onInlineHover(state) onHover(state == "true") end
function onVolumeBarMove(x)
  pointerX = tonumber(x)
  if not hovering then onHover(true) end
end
function onVolumeBarLeave()
  pointerX = nil
  onHover(false)
end
function onVolumeBarClick()
  if pointerX == nil or trackWidth <= 0 then return end
  local radius = handleWidth / 2
  requestVolume((pointerX * trackWidth - radius) / math.max(1, trackWidth - radius * 2))
end
render = function()
  local color = colour()
  local glyph = muted and "volume-off" or (vol < 0.4 and "volume-2" or "volume")
  local icon = ui.glyph({key = "speaker", name = glyph, size = 20, color = color})
  local speakerClick = nil
  if noctalia.getConfig("icon_click") ~= "panel" then speakerClick = "onSpeakerClick" end
  -- Native sliders have a fixed 38px input height. All overlapping layers use
  -- that same height, centering only their visible shapes inside it.
  local inputHeight = 38
  local children = {ui.row({key = "speaker-target", width = 24, height = inputHeight, align = "center",
    onHover = "onInlineHover", onClick = speakerClick}, {icon})}
  trackWidth = 0
  local draggingEnabled = boolean("drag_enabled", false)
  if progress > 0.01 or dragging then
    trackWidth = dragWidth or math.max(1, clamp(number("slider_width", 90), 40, 300) * progress)
    local h = math.min(thickness(), trackWidth)
    local showKnob = boolean("show_knob", true)
    local flat = noctalia.getConfig("point_style") == "flat"
    local diameter = math.min(trackWidth, math.floor(h * 1.5 + 0.5))
    handleWidth = showKnob and (flat and math.min(3, trackWidth) or diameter) or 0
    local knobStart = clamp(vol, 0, 1) * (trackWidth - handleWidth)
    local filledWidth = knobStart + handleWidth / 2
    local layers = {
      ui.row({key = "track-layer", width = trackWidth, height = inputHeight, align = "center"}, {
        ui.box({key = "track", width = trackWidth, height = h, radius = h / 2, fill = "#00000033"}),
      }),
      ui.row({key = "fill-layer", gap = 0, width = trackWidth, height = inputHeight, align = "center"}, flat and {
        ui.progress({key = "flat-fill", width = trackWidth, height = h, radius = h / 2,
          progress = filledWidth / trackWidth, fill = color, track = "#00000000"}),
      } or {
        ui.box({key = "fill", width = filledWidth, height = h, radius = flat and 0 or math.min(h, filledWidth) / 2, fill = color}),
        ui.box({width = trackWidth - filledWidth, height = 1, fill = "#00000000"}),
      }),
    }
    if showKnob then
      table.insert(layers, ui.row({key = "knob-layer", gap = 0, width = trackWidth, height = inputHeight, align = "center"}, {
        ui.box({width = knobStart, height = 1, fill = "#00000000"}),
        ui.box({key = "knob", width = handleWidth, height = diameter, radius = flat and 0 or diameter / 2,
          fill = tostring(noctalia.getConfig("knob_color") or "on_primary"),
          border = "on_surface/0.65", borderWidth = 1}),
        ui.box({width = math.max(0, trackWidth - handleWidth - knobStart), height = 1, fill = "#00000000"}),
      }))
    end
    if draggingEnabled and trackWidth > 4 then
      -- API 32 sliders ignore width: flexGrow inside a fixed-width wrapper
      -- supplies the actual input width. Undo its 2px inset to follow the handle.
      local sliderValue = clamp((filledWidth - 2) / (trackWidth - 4), 0, 1)
      if renderedSliderValue == nil or math.abs(sliderValue - renderedSliderValue) > 0.000001 then
        table.insert(sliderEchoes, sliderValue)
        if #sliderEchoes > 64 then table.remove(sliderEchoes, 1) end
      end
      renderedSliderValue = sliderValue
      table.insert(layers, ui.row({key = "volume-drag-wrapper", width = trackWidth, height = inputHeight, align = "center"}, {
        ui.slider({key = "volume-drag", flexGrow = 1, controlSize = "md",
          min = 0, max = 1, step = 0, value = sliderValue, opacity = 0,
          onChange = "onVolumeDrag", onDragEnd = "onVolumeDragEnd"}),
      }))
    else
      table.insert(layers, ui.graph({key = "volume-pointer", width = trackWidth, height = inputHeight, values = {0, 0},
        color = "#00000000", lineWidth = 0, fillOpacity = 0,
        onPointerMove = "onVolumeBarMove", onPointerLeave = "onVolumeBarLeave"}))
    end
    table.insert(children, ui.row({key = "volume-hit", width = trackWidth, height = inputHeight,
      gap = -trackWidth, align = "center", opacity = muted and 0.65 or 1,
      onClick = "onVolumeBarClick"}, layers))
  end
  if boolean("show_percent", true) then
    table.insert(children, ui.label({key = "percentage", text = muted and "muted" or `{math.floor(vol * 100 + 0.5)}%`}))
  end
  barWidget.render((barWidget.isVertical() and ui.column or ui.row)({gap = 6, align = "center",
    onHover = "onInlineHover"}, children))
end
step = function()
  local interval = 300
  if dragging then target = 1
  elseif leaveDelay > 0 then
    leaveDelay = math.max(0, leaveDelay - 16)
    if leaveDelay == 0 then target = 0 end
  end
  if math.abs(progress - target) > 0.01 then
    progress += (target - progress) * 0.16
    interval = 16
  else progress = target end
  if leaveDelay > 0 or dragging then interval = 16 end
  render()
  noctalia.setUpdateInterval(interval)
  pollElapsed += interval
  if pollElapsed >= 300 then pollElapsed = 0; poll() end
end
function update() step() end
function onHover(value)
  hovering = value
  if value then target, leaveDelay = 1, 0
  else
    -- Child targets emit leave/enter pairs when crossing the widget. Match the
    -- short grace without dragging, or the longer slider handoff delay when
    -- dragging is enabled. Repeated leaves do not restart the timer.
    if leaveDelay == 0 then leaveDelay = boolean("drag_enabled", false) and 1200 or LEAVE_GRACE_MS end
  end
  step()
end
function onConfigChanged() render() end
function onScroll(axis, steps)
  local n = tonumber(steps) or 0
  if axis ~= "vertical" or n == 0 then return end
  local up = n < 0
  if boolean("invert_scroll", false) then up = not up end
  requestVolume(vol + (up and 1 or -1) * math.abs(n) * clamp(number("scroll_step", 5), 1, 25) / 100)
end
