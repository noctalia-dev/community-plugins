--!nonstrict
-- Full-screen lyrics overlay on a plugin layer, drawn with ui.* only. The
-- service publishes the calm wallpaper zones, so the block roams the empty
-- areas of the wallpaper instead of sitting on the subject in the middle.
--
-- Network: none. Filesystem: none. Processes: none.

local ZONE_LAYOUT = {
  topLeft = { h = "start", v = "start" },
  topCenter = { h = "center", v = "start" },
  topRight = { h = "end", v = "start" },
  centerLeft = { h = "start", v = "center" },
  center = { h = "center", v = "center" },
  centerRight = { h = "end", v = "center" },
  bottomLeft = { h = "start", v = "end" },
  bottomCenter = { h = "center", v = "end" },
  bottomRight = { h = "end", v = "end" },
}

local layout = nil
local lastLine = nil
local lastZoneKey = nil
local zoneIndex = 0

local function cfg(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value
end

local function calmZones()
  local list = noctalia.state.get("overlay_zones")
  if type(list) ~= "table" or #list == 0 then
    return { "center" }
  end
  return list
end

-- Sequential tour by default; "shuffle" hops anywhere inside the calm set.
local function pickZone(list)
  list = list or calmZones()
  local name
  if cfg("wallpaper_order", "tour") == "shuffle" then
    name = list[math.random(#list)]
  else
    zoneIndex = zoneIndex % #list + 1
    name = list[zoneIndex]
  end
  return ZONE_LAYOUT[name] or ZONE_LAYOUT.center
end

function update()
  noctalia.setUpdateInterval(200)

  local size = cfg("overlay_font_size", 52)
  local margin = cfg("overlay_margin", 64)
  local mode = cfg("display_mode", "karaoke")
  local maxWidth = math.floor(size * 28)

  local current = noctalia.state.get("current") or ""
  local nextLine = noctalia.state.get("next") or ""
  local previous = noctalia.state.get("previous") or ""

  -- Placement also follows the calm zones: a cleared set (sampling disabled,
  -- missing sampler or a failed sample) must return the line to the centre
  -- immediately, and a new wallpaper's zones must apply without waiting for
  -- the lyric text to change.
  local zones = calmZones()
  local zoneKey = table.concat(zones, ",")
  if current ~= lastLine or zoneKey ~= lastZoneKey or layout == nil then
    lastLine = current
    lastZoneKey = zoneKey
    layout = pickZone(zones)
  end

  local alignment = layout.h
  local rows = {}

  if mode == "line" and cfg("show_next_line", true) and previous ~= "" then
    table.insert(rows, ui.label({
      text = previous,
      fontSize = math.max(12, math.floor(size * 0.42)),
      color = "on_surface/0.3",
      textAlign = alignment,
      maxLines = 1,
      maxWidth = maxWidth,
      shadow = true,
    }))
  end

  if mode == "karaoke" and cfg("show_progress", true) then
    local fill = {
      text = current,
      fontSize = size,
      fontWeight = "bold",
      color = "on_surface/0.45",
      fillColor = "primary",
      fillProgress = noctalia.state.get("progress") or 0,
      textAlign = alignment,
      maxWidth = maxWidth,
      maxLines = 2,
      shadow = true,
    }
    local ranges = noctalia.state.get("word_ranges")
    if type(ranges) == "table" and #ranges > 0 then
      fill.fillRanges = ranges
      fill.fillProgress = noctalia.state.get("word_progress") or 0
    end
    table.insert(rows, ui.fillLabel(fill))
  else
    table.insert(rows, ui.label({
      text = current,
      fontSize = size,
      fontWeight = "bold",
      color = "on_surface",
      textAlign = alignment,
      maxLines = 2,
      maxWidth = maxWidth,
      shadow = true,
    }))
  end

  if cfg("show_next_line", true) and nextLine ~= "" then
    table.insert(rows, ui.label({
      text = nextLine,
      fontSize = math.max(12, math.floor(size * 0.42)),
      color = "on_surface/0.35",
      textAlign = alignment,
      maxLines = 1,
      maxWidth = maxWidth,
      shadow = true,
    }))
  end

  layer.render(ui.column({
    flexGrow = 1,
    align = layout.h,
    justify = layout.v,
    padding = margin,
    gap = 6,
  }, rows))
end
