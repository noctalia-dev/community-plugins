--!nonstrict
-- Mihomo Control — bar widget.
--
-- Shows live download/upload rates from the service's streamed /traffic data.
-- Left click toggles the control panel; the tooltip holds the connection
-- status, mode, totals, connection count and the current selection of every
-- proxy group.

local PLUGIN_ID = "mdj2812/mihomo-control"
local MIHOMO_GLYPH = utf8.char(0xE001)
local mihomoGlyphFont = noctalia.loadFont("fonts/mihomo-glyph.ttf")
local STATUS_ICON_COLORS = {
  online = "#27924f",
  connecting = "#a35818",
  offline = "#a72f2f",
}

local function panel_id()
  if noctalia.getConfig("panel_placement") == "attached" then
    return PLUGIN_ID .. ":panel-attached"
  end
  return PLUGIN_ID .. ":panel"
end

local function format_rate(bytes_per_second)
  local value = tonumber(bytes_per_second) or 0
  if value >= 1024 * 1024 * 1024 then
    return string.format("%.2f GB/s", value / (1024 * 1024 * 1024))
  end
  if value >= 1024 * 1024 then
    return string.format("%.1f MB/s", value / (1024 * 1024))
  end
  if value >= 1024 then
    return string.format("%.1f KB/s", value / 1024)
  end
  return string.format("%d B/s", value)
end

local function configured_icon_size()
  local value = math.floor(tonumber(noctalia.getConfig("icon_size")) or 16)
  return math.max(10, math.min(32, value))
end

local function render()
  local conn = noctalia.state.get("mihomo.connection") or {}
  local config = noctalia.state.get("mihomo.config") or {}
  local traffic = noctalia.state.get("mihomo.traffic") or {}
  local connections = noctalia.state.get("mihomo.connections") or {}
  local groups = noctalia.state.get("mihomo.groups") or {}

  local online = conn.status == "online"
  local mode = noctalia.tr("panel.mode_" .. (config.mode or "rule"))

  local show_mode = noctalia.getConfig("show_mode") ~= false
  local icon_size = configured_icon_size()
  local icon
  if mihomoGlyphFont ~= nil then
    local color = STATUS_ICON_COLORS[conn.status] or STATUS_ICON_COLORS.offline
    if noctalia.getConfig("icon_color_mode") == "custom" then
      color = noctalia.getConfig("icon_color") or "primary"
    end
    icon = ui.label({
      text = MIHOMO_GLYPH,
      fontFamily = mihomoGlyphFont,
      fontSize = icon_size,
      color = color,
      baseline = "inkCentered",
      maxLines = 1,
    })
  else
    icon = ui.image({ path = "icon.png", width = icon_size, height = icon_size })
  end

  local children = { icon }
  if show_mode then
    table.insert(children, ui.label({
      text = mode,
      fontSize = 12,
      color = "on_surface",
      fontWeight = "medium",
    }))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = show_mode and 6 or 0, align = "center" }, children))

  local status_value = "Offline"
  if online then
    local version = tostring(conn.version or "")
    status_value = version ~= ""
      and noctalia.tr("widget.status_online_with_version", { version = version })
      or noctalia.tr("widget.status_online_plain")
  elseif conn.status == "connecting" then
    status_value = noctalia.tr("widget.status_connecting")
  elseif tostring(conn.error or "") ~= "" then
    status_value = noctalia.tr("widget.status_offline_with_error", { error = conn.error })
  else
    status_value = noctalia.tr("widget.status_offline_plain")
  end

  local tooltip = {
    { key = noctalia.tr("widget.status"), value = status_value },
    { key = noctalia.tr("widget.mode"), value = noctalia.tr("panel.mode_" .. (config.mode or "rule")) },
    { key = noctalia.tr("widget.down"), value = `▼ {format_rate(traffic.down)}` },
    { key = noctalia.tr("widget.up"), value = `▲ {format_rate(traffic.up)}` },
    { key = noctalia.tr("widget.connections"), value = tostring(connections.count or 0) },
  }
  for _, group in ipairs(type(groups) == "table" and groups or {}) do
    if #tooltip < 14 then
      table.insert(tooltip, {
        key = tostring(group.name or ""),
        value = tostring(group.now or "—"),
      })
    end
  end
  barWidget.setTooltip(tooltip)
end

for _, key in {
  "mihomo.connection",
  "mihomo.config",
  "mihomo.traffic",
  "mihomo.connections",
  "mihomo.groups",
} do
  noctalia.state.watch(key, function(_value)
    render()
  end)
end

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel(panel_id())
end

render()
