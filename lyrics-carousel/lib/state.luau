--!nonstrict
-- What every entry shares: the settings they read, the position the service
-- published moved forward to now, and the state name the renderer expects.
--
-- Pure Lua (no `require`, no globals): `noctalia` is injected, so the three
-- entries and the tests use the same arithmetic instead of three copies that
-- drift apart.

local M = {}

-- The settings this plugin draws with. They are declared in the manifest, so
-- `noctalia.getConfig` resolves every one of them.
M.SETTING_KEYS = {
  "font_size",
  "direction",
  "marker",
  "marker_style",
  "karaoke",
  "ghost",
  "header",
  "footer",
  "spacing",
  "active_scale",
  "visible_above",
  "visible_below",
  "accent",
  "custom_color",
  "offset_ms",
  "instrumental",
  "instrumental_icon",
  "instrumental_text",
  "silence_threshold",
}

--- Reads the drawing settings: `{ [key] = value }`.
function M.read(noctalia)
  local values = {}
  for _, key in ipairs(M.SETTING_KEYS) do
    values[key] = noctalia.getConfig(key)
  end
  return values
end

--- Position in seconds, as of `nowMs`.
--
-- The service publishes the position it read and the moment it read it, so
-- the surfaces can move it forward between polls. A paused song does not
-- move. A clock that goes backwards never rewinds the lyric.
function M.position(track, nowMs)
  if type(track) ~= "table" then
    return 0
  end
  local position = (tonumber(track.positionMs) or 0) / 1000
  if track.playing and tonumber(track.positionAtMs) ~= nil then
    position = position + math.max(0, (tonumber(nowMs) or 0) - track.positionAtMs) / 1000
  end
  return position
end

--- The state name `render.surface` understands.
function M.stateOf(track, lyrics, loading)
  if type(track) ~= "table" then
    return "idle"
  end
  if type(lyrics) == "table" then
    return "lyrics"
  end
  if loading then
    return "loading"
  end
  return "empty"
end

--- The settings the renderer uses, with the per-track break applied.
--
-- `brain` is the "this song, not this one" switch: false paints the active
-- line without the karaoke fill until the track changes. It is state, not a
-- setting, so it never survives the song it was meant for.
function M.karaoke(cfg, brain)
  if brain ~= false or (cfg or {}).karaoke == false then
    return cfg
  end
  local copy = {}
  for key, value in pairs(cfg) do
    copy[key] = value
  end
  copy.karaoke = false
  return copy
end

--- Title and artist, for the tooltip and the header.
function M.label(track)
  if type(track) ~= "table" then
    return ""
  end
  local title = tostring(track.title or "")
  local artist = tostring(track.artist or "")
  if title == "" then
    return artist
  end
  if artist ~= "" then
    return title .. " — " .. artist
  end
  return title
end

--- The tooltip: what is playing, or why nothing is.
function M.tooltip(track, tr)
  local label = M.label(track)
  if label ~= "" then
    return label
  end
  if tr ~= nil then
    return tr("nothing_playing")
  end
  return ""
end

return M
