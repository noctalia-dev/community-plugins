--!nonstrict

local SNAPSHOT_KEY = "fan_monitor.status"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {
  available = false,
  fans = {},
  primary_rpm = 0,
  max_rpm = 0,
  driver = "none",
  last_updated = 0,
}

local function getDisplayText()
  local showLabel = noctalia.getConfig("show_label") ~= false
  if not showLabel or barWidget.isVertical() then
    return ""
  end

  if not snapshot.available then
    return "--"
  end

  local showUnit = noctalia.getConfig("show_unit") ~= false
  local rpm = snapshot.primary_rpm or 0
  if showUnit then
    return string.format("%d RPM", rpm)
  else
    return string.format("%d", rpm)
  end
end

local function updateColors()
  local colorize = noctalia.getConfig("colorize_by_speed") ~= false
  if not snapshot.available then
    barWidget.setGlyphColor("error")
    return
  end

  if not colorize then
    barWidget.setGlyphColor("default")
    return
  end

  local rpm = snapshot.primary_rpm or 0
  local highThreshold = tonumber(noctalia.getConfig("high_rpm_threshold")) or 4000

  if rpm == 0 then
    barWidget.setGlyphColor("secondary")
  elseif rpm >= highThreshold then
    barWidget.setGlyphColor("error")
  elseif rpm >= math.floor(highThreshold * 0.6) then
    barWidget.setGlyphColor("primary")
  else
    barWidget.setGlyphColor("default")
  end
end

local function updateTooltip()
  local rows = {}
  if snapshot.available then
    table.insert(rows, {
      key = noctalia.tr("widget.tooltip.status"),
      value = noctalia.tr("widget.tooltip.monitoring"),
    })

    for _, fan in ipairs(snapshot.fans or {}) do
      local val = string.format("%d RPM", fan.rpm)
      if fan.max_rpm and fan.max_rpm > 0 then
        val = string.format("%d RPM (%d%% of max %d)", fan.rpm, fan.percent, fan.max_rpm)
      end
      local label = fan.label or "Fan"
      if fan.driver and fan.driver ~= "" then
        label = string.format("%s (%s)", label, fan.driver)
      end
      table.insert(rows, { key = label, value = val })
    end

    if snapshot.driver and snapshot.driver ~= "none" then
      table.insert(rows, {
        key = noctalia.tr("widget.tooltip.driver"),
        value = snapshot.driver,
      })
    end
  else
    table.insert(rows, {
      key = noctalia.tr("widget.tooltip.status"),
      value = noctalia.tr("widget.tooltip.unavailable"),
    })
  end

  table.insert(rows, {
    key = "Action",
    value = noctalia.tr("widget.tooltip.click_hint"),
  })

  barWidget.setTooltip(rows)
end

local function render()
  barWidget.setGlyph("car-fan")
  barWidget.setText(getDisplayText())
  updateColors()
  updateTooltip()
end

noctalia.state.watch(SNAPSHOT_KEY, function(val)
  if type(val) == "table" then
    snapshot = val
    render()
  end
end)

function onConfigChanged()
  render()
end

function onClick()
  noctalia.runAsync("noctalia msg plugin muhamm-ad-ahmad/fan-monitor:service all refresh")
end

render()
