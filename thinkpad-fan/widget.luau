--!nonstrict

local SNAPSHOT = "fan.snapshot"
local PANEL_ID = "piero-93/thinkpad-fan:panel"

local snap = noctalia.state.get(SNAPSHOT) or { rpm = 0, level = "auto", temp = 0, available = false }
local isVertical = false

-- level "0" forces the fans off (danger); any non-auto, non-0 level is a manual override.
local function accent()
  if noctalia.getConfig("colorize_by_status") == false then
    return "on_surface"
  end
  if snap.level == "0" then
    return "error"
  elseif snap.level ~= "auto" then
    return "primary"
  end
  return "on_surface"
end

local function levelText()
  if snap.level == "auto" then
    return noctalia.tr("level.auto")
  elseif snap.level == "disengaged" then
    return noctalia.tr("level.full")
  end
  return snap.level
end

local function tooltipRows()
  return {
    { key = noctalia.tr("tooltip.speed"), value = (snap.rpm or 0) .. " RPM" },
    { key = noctalia.tr("tooltip.level"), value = levelText() },
    { key = noctalia.tr("tooltip.temperature"), value = (snap.temp or 0) .. " °C" },
  }
end

local function render()
  local color = accent()
  local children = { ui.glyph({ name = "car-fan", color = color }) }

  if not isVertical then
    table.insert(children, ui.label({
      text = (snap.rpm or 0) .. " RPM",
      fontWeight = "bold",
      color = color,
    }))
  end

  local container = isVertical and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(tooltipRows())
end

noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)

function update()
  isVertical = barWidget.isVertical()
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  if noctalia.getConfig("allow_popup") ~= false then
    noctalia.togglePanel(PANEL_ID)
  end
end

noctalia.setUpdateInterval(30000)
render()
