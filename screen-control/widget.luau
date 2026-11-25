--!nonstrict
-- Screen Control bar widget: a sun, or a moon while night light is on, or a clock while a
-- layout change waits to be kept. Scroll moves the bar's monitor along the brightness and
-- dim scale; a click opens the panel.

local Level = require("./lib/level.luau")

local PANEL = "omerfuyar/screen-control:panel"

local model = nil
local layout = nil

local function send(command)
  command.n = noctalia.nowMs()
  noctalia.state.set("screen-control.command", command)
end

-- The monitor this bar is on, or the first one.
local function ownMonitor()
  local name = barWidget.outputName()
  for _, monitor in ipairs(model.monitors) do
    if monitor.name == name then
      return monitor
    end
  end
  return model.monitors[1]
end

local function render()
  if model == nil or #model.monitors == 0 then
    return
  end
  local own = ownMonitor()
  local waiting = layout ~= nil and layout.pending ~= nil
  local glyph = waiting and "clock-hour-4" or model.night.mode == "on" and "moon" or "sun"
  -- color nil keeps the bar's own color.
  local color = (waiting or own.dim > 0) and "primary" or nil
  barWidget.render(ui.glyph({ name = glyph, color = color }))

  local rows = {}
  if waiting then
    table.insert(rows, { key = noctalia.tr("layout.keep_question"), value = noctalia.trp("layout.keep_countdown", layout.pending) })
  end
  for _, monitor in ipairs(model.monitors) do
    table.insert(rows, { key = monitor.label, value = Level.text(monitor.brightness, monitor.dim) })
  end
  table.insert(rows, { key = noctalia.tr("night.title"), value = noctalia.tr("night." .. model.night.mode) })
  barWidget.setTooltip(rows)
end

noctalia.state.watch("screen-control.model", function(value)
  model = value
  render()
end)

noctalia.state.watch("screen-control.layout", function(value)
  layout = value
  render()
end)

function update()
  noctalia.setUpdateInterval(60000)
  model = model or noctalia.state.get("screen-control.model")
  layout = layout or noctalia.state.get("screen-control.layout")
  render()
end

function onClick()
  noctalia.togglePanel(PANEL)
end

-- steps is negative for up.
function onScroll(axis, steps)
  if axis ~= "vertical" or model == nil or #model.monitors == 0 then
    return
  end
  send({ action = "step", output = ownMonitor().name, delta = -steps * Level.STEP })
end

-- Right click switches night light on, or off when it is on or scheduled.
function onRightClick()
  if model == nil then
    return
  end
  send({ action = "night", mode = model.night.mode == "off" and "on" or "off" })
end
