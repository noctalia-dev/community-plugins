--!nonstrict
-- MacBook Fan & Thermal Bar Widget
-- High-efficiency declarative bar widget rendering fan speed and thermal status.

local SNAPSHOT = "macbook_fan.snapshot"
local dir = (noctalia.pluginDir and noctalia.pluginDir()) or ""
local isLocal = string.find(dir, "local/") ~= nil
local PLUGIN_ID = isLocal and "local/macbook-fan" or "blackx16/macbook-fan"
local PANEL_AUTO = PLUGIN_ID .. ":panel"
local PANEL_MANUAL = PLUGIN_ID .. ":panel_manual"

local snap = noctalia.state.get(SNAPSHOT) or {
  rpm = 0,
  min_rpm = 1200,
  max_rpm = 6500,
  target_rpm = 1200,
  percent = 0,
  temp = 0,
  daemon_active = false,
  driver_available = false,
  control_mode = "auto",
  display_mode = "rpm",
}

local lastRender = {
  text = nil,
  accent = nil,
  glyph = nil,
  isVertical = nil,
}

local lastTooltipKey = nil

local function getAccentRole()
  if not snap.driver_available then
    return "error"
  end

  local colorize = noctalia.getConfig("colorize_by_temp")
  if colorize == false then
    return "primary"
  end

  local t = snap.temp or 0
  local r = snap.rpm or 0
  if t >= 80 or r >= 5000 then
    return "error"
  elseif t >= 65 or r >= 3200 then
    return "secondary"
  end

  return "primary"
end

local function getDisplayText()
  if not snap.driver_available then
    return noctalia.tr("widget.no_smc")
  end

  local mode = snap.display_mode or "rpm"
  if mode == "percent" then
    return string.format("%d%%", snap.percent or 0)
  elseif mode == "both" then
    return string.format("%d RPM · %d%%", snap.rpm or 0, snap.percent or 0)
  else
    return string.format("%d RPM", snap.rpm or 0)
  end
end

local function getStatusText()
  local t = snap.temp or 0
  local r = snap.rpm or 0
  if t >= 80 or r >= 5000 then
    return noctalia.tr("widget.status_heavy")
  elseif t >= 65 or r >= 3200 then
    return noctalia.tr("widget.status_elevated")
  end
  return noctalia.tr("widget.status_normal")
end

local function render()
  local isVertical = barWidget.isVertical()
  local accent = getAccentRole()
  local text = getDisplayText()
  local glyphName = snap.driver_available and "car-fan" or "alert-triangle"

  -- Memoize barWidget.render to eliminate redundant layout cycles and C++ bridge calls
  if text ~= lastRender.text
     or accent ~= lastRender.accent
     or glyphName ~= lastRender.glyph
     or isVertical ~= lastRender.isVertical then
    lastRender.text = text
    lastRender.accent = accent
    lastRender.glyph = glyphName
    lastRender.isVertical = isVertical

    local container = isVertical and ui.column or ui.row
    barWidget.render(container({ gap = 4, align = "center" }, {
      ui.glyph({
        name = glyphName,
        color = accent,
      }),
      ui.label({
        text = text,
        color = accent,
        fontWeight = "bold",
      }),
    }))
  end

  -- Memoize structured tooltip construction
  local tooltipKey = string.format(
    "%d|%d|%.1f|%s|%s|%s|%s",
    snap.rpm or 0,
    snap.percent or 0,
    snap.temp or 0,
    snap.control_mode or "",
    tostring(snap.daemon_active),
    tostring(snap.driver_available),
    tostring(snap.target_rpm or 0)
  )

  if tooltipKey ~= lastTooltipKey then
    lastTooltipKey = tooltipKey
    local modeText = (snap.control_mode == "manual")
        and string.format(noctalia.tr("widget.mode_manual"), snap.target_rpm or snap.rpm or 0)
      or noctalia.tr("widget.mode_auto")

    barWidget.setTooltip({
      { key = noctalia.tr("tooltip.speed"), value = string.format("%d RPM (%d%%)", snap.rpm or 0, snap.percent or 0) },
      { key = noctalia.tr("tooltip.temperature"), value = string.format("%.1f °C", snap.temp or 0) },
      { key = noctalia.tr("tooltip.limits"), value = string.format("%d – %d RPM", snap.min_rpm or 1200, snap.max_rpm or 6500) },
      { key = noctalia.tr("tooltip.controller"), value = snap.daemon_active and "mbpfan (active)" or "mbpfan (inactive)" },
      { key = noctalia.tr("tooltip.mode"), value = modeText },
      { key = noctalia.tr("tooltip.status"), value = getStatusText() },
    })
  end
end

-- Watch state updates reactively from service.luau
noctalia.state.watch(SNAPSHOT, function(value)
  if type(value) == "table" then
    snap = value
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
  local allowPopup = noctalia.getConfig("allow_popup")
  if allowPopup ~= false then
    local targetPanel = (snap.control_mode == "manual") and PANEL_MANUAL or PANEL_AUTO
    noctalia.togglePanel(targetPanel)
  end
end

render()
