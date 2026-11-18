--!nonstrict

local SNAPSHOT = "battery.snapshot"
local PANEL_ID = "piero-93/battery-power-management:panel"

local snap = noctalia.state.get(SNAPSHOT) or {
  percent = 0,
  status = "Unknown",
  watt = 0,
  profile = "balanced",
  hasProfile = false,
}
local isVertical = false

local function accent()
  if snap.status == "Charging" then
    return "primary"
  end
  if noctalia.getConfig("colorize_by_profile") ~= false then
    if snap.profile == "power-saver" then
      return tostring(noctalia.getConfig("color_power_saver") or "secondary")
    elseif snap.profile == "performance" then
      return tostring(noctalia.getConfig("color_performance") or "error")
    end
  end
  return "on_surface"
end

local function batteryGlyph()
  local s = snap.status
  if s == "Charging" then
    return "battery-charging"
  elseif s == "Full" then
    return "battery-charging-2"
  end
  local p = snap.percent or 0
  if p >= 86 then
    return "battery-4"
  elseif p >= 56 then
    return "battery-3"
  elseif p >= 31 then
    return "battery-2"
  elseif p >= 11 then
    return "battery-1"
  end
  return "battery"
end

local function profileGlyph()
  if snap.profile == "power-saver" then
    return "leaf"
  elseif snap.profile == "performance" then
    return "gauge"
  elseif noctalia.getConfig("show_balanced_icon") == true then
    return "scale"
  end
  return ""
end

local function tooltipRows()
  local statusText = noctalia.tr("status." .. (snap.status or "Unknown"):lower():gsub("%s", "_"))
  local rows = {
    { key = noctalia.tr("tooltip.level"), value = (snap.percent or 0) .. "%" },
    { key = noctalia.tr("tooltip.status"), value = statusText },
    { key = noctalia.tr("tooltip.power"), value = string.format("%.1f W", snap.watt or 0) },
  }
  if snap.eta and snap.eta ~= "" then
    local timeKey = snap.status == "Charging" and "tooltip.to_full" or "tooltip.remaining"
    table.insert(rows, { key = noctalia.tr(timeKey), value = snap.eta })
  end
  if snap.hasProfile then
    table.insert(rows, { key = noctalia.tr("tooltip.profile"), value = noctalia.tr("panel.profile_" .. snap.profile) })
  end
  return rows
end

local function render()
  local color = accent()
  local children = { ui.glyph({ name = batteryGlyph(), color = color }) }

  if not isVertical then
    local sign = snap.status == "Charging" and "+" or "-"
    table.insert(children, ui.label({
      text = string.format("%d%% %s%.1fW", snap.percent or 0, sign, snap.watt or 0),
      fontWeight = "bold",
      color = color,
    }))
  end

  if noctalia.getConfig("show_profile") ~= false and snap.hasProfile then
    local pg = profileGlyph()
    if pg ~= "" then
      table.insert(children, ui.glyph({ name = pg, color = color }))
    end
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
  noctalia.togglePanel(PANEL_ID)
end

noctalia.setUpdateInterval(30000)
render()
