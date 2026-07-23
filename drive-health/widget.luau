--!nonstrict

local snapshot = noctalia.state.get("snapshot")

local function number(value, fallback)
  local parsed = tonumber(value)
  return parsed ~= nil and parsed or fallback
end
local function temperatureColor(value)
  local warning = number(noctalia.getConfig("warning_temperature"), 65)
  local critical = math.max(warning + 1, number(noctalia.getConfig("critical_temperature"), 80))
  if value == nil then
    return "on_surface_variant"
  elseif value >= critical then
    return "error"
  elseif value >= warning then
    return "secondary"
  end
  return "primary"
end

local function render()
  local summary = snapshot and snapshot.summary or nil
  if summary == nil then
    barWidget.render(ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "server-2", size = 15, color = "on_surface_variant" }),
      ui.label({ text = "…", color = "on_surface_variant" }),
    }))
    barWidget.setTooltip(noctalia.tr("widget.loading"))
    return
  end

  local count = number(summary.disk_count, number(summary.ssd_count, 0))
  local ssdCount = number(summary.ssd_count, 0)
  local hddCount = number(summary.hdd_count, 0)
  local hottest = tonumber(summary.hottest_drive_temperature_c or summary.hottest_ssd_temperature_c)
  local remaining = tonumber(summary.worst_ssd_remaining_life_percent)
  local unavailable = number(summary.smart_unavailable_count, number(summary.ssd_smart_unavailable_count, 0))
  local unhealthy = number(summary.unhealthy_count, number(summary.ssd_unhealthy_count, 0))
  local alerts = number(summary.active_alert_count, 0)
  local criticalAlerts = number(summary.critical_alert_count, 0)
  local tempText = hottest ~= nil and string.format("%.0f°", hottest) or "--°"
  local lifeText = remaining ~= nil and string.format("%.0f%%", remaining) or "--%"
  local stateColor = (criticalAlerts > 0 or unhealthy > 0) and "error" or (alerts > 0 and "secondary" or temperatureColor(hottest))
  local container = barWidget.isVertical() and ui.column or ui.row

  local children = {
    ui.glyph({ name = alerts > 0 and "alert-triangle" or "server-2", size = 15, color = stateColor }),
    ui.row({ fill = stateColor .. "/0.18", radius = 8, paddingH = 6, align = "center" }, {
      ui.label({ text = tempText, color = stateColor, fontWeight = "bold" }),
    }),
  }

  if not barWidget.isVertical() then
    if remaining ~= nil then
      table.insert(children, ui.label({ text = lifeText, color = "on_surface" }))
    end
    if alerts > 0 then
      table.insert(children, ui.row({ fill = stateColor .. "/0.18", radius = 8, paddingH = 5, align = "center" }, {
        ui.label({ text = tostring(math.floor(alerts)), fontSize = 10, fontWeight = "bold", color = stateColor }),
      }))
    end
    if unavailable > 0 then
      table.insert(children, ui.glyph({ name = "alert-circle", size = 12, color = "secondary" }))
    end
  end

  barWidget.render(container({ gap = 6, align = "center" }, children))

  local tooltip = noctalia.tr("widget.tooltip", {
    count = count,
    ssds = ssdCount,
    hdds = hddCount,
    temperature = tempText,
    remaining = lifeText,
  })
  if unavailable > 0 then
    tooltip ..= "\n" .. noctalia.tr("widget.smart_unavailable", { count = unavailable })
  end
  if alerts > 0 then
    tooltip ..= "\n" .. noctalia.tr("widget.active_alerts", { count = math.floor(alerts) })
    local issues = snapshot and snapshot.issues or {}
    for index, issue in ipairs(issues) do
      if index > 3 then
        break
      end
      tooltip ..= "\n• " .. tostring(issue.message or issue.title)
    end
  else
    tooltip ..= "\n" .. noctalia.tr("widget.no_alerts")
  end
  barWidget.setTooltip(tooltip)
end

noctalia.state.watch("snapshot", function(value)
  snapshot = value
  render()
end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel("gustav0ar/drive-health:drives")
end
