--!nonstrict
-- Circular progress rings for the bar pill.
--
-- Noctalia's ui.* vocabulary has no arc primitive and barWidget has no drawing
-- surface, but both the bar (barWidget.setImage) and the panels (ui.image) load
-- images through an librsvg-backed loader. So a ring is an SVG we generate here,
-- write to the plugin data dir and hand back as a path.
--
-- SVG needs literal hex, so palette roles are resolved with noctalia.getColor
-- against the active theme, whatever its source. The ring_color /
-- ring_track_color settings and the hard fallbacks below only apply when a role
-- does not resolve, so the ring always draws.

local M = {}

-- Last-resort hexes when no palette resolves and no setting is configured.
-- Amber / red for the pace cues: those read the same in every theme.
local HARD_FALLBACK = {
  tertiary = "#D8A657",
  error = "#E06C75",
}
local FALLBACK_FILL = "#89B4FA"
local FALLBACK_TRACK = "#585B70"

-- Palette role -> hex. `fallback` is the configured color for this slot; a role
-- name there is resolved too, so "outline_variant" in a color setting keeps working.
function M.color(role, fallback, isTrack)
  local color = noctalia.getColor(role)
  if color then return color end
  if type(fallback) == "string" and fallback ~= "" then
    if fallback:sub(1, 1) == "#" then return fallback end
    local named = noctalia.getColor(fallback)
    if named then return named end
  end
  if HARD_FALLBACK[role] then return HARD_FALLBACK[role] end
  return isTrack and FALLBACK_TRACK or FALLBACK_FILL
end

-- ── svg ─────────────────────────────────────────────────────────────────────

local function num(v)
  return string.format("%.3f", v)
end

-- One ring: full-circle track plus an arc sweeping clockwise from 12 o'clock.
local function ringMarkup(cx, cy, r, lw, frac, track, fill)
  if r < lw then return "" end -- too small to read as a ring; skip it
  local parts = {
    `<circle cx="{num(cx)}" cy="{num(cy)}" r="{num(r)}" fill="none" stroke="{track}" stroke-width="{num(lw)}"/>`,
  }
  if frac >= 0.999 then
    table.insert(parts, `<circle cx="{num(cx)}" cy="{num(cy)}" r="{num(r)}" fill="none" stroke="{fill}" stroke-width="{num(lw)}"/>`)
  elseif frac > 0.001 then
    local angle = -math.pi / 2 + frac * 2 * math.pi
    local ex, ey = cx + r * math.cos(angle), cy + r * math.sin(angle)
    local large = frac > 0.5 and 1 or 0
    local d = `M {num(cx)} {num(cy - r)} A {num(r)} {num(r)} 0 {large} 1 {num(ex)} {num(ey)}`
    table.insert(parts, `<path d="{d}" fill="none" stroke="{fill}" stroke-width="{num(lw)}" stroke-linecap="round"/>`)
  end
  return table.concat(parts, "")
end

local function buildSvg(size, lw, frac, track, fill)
  local cx = size / 2
  return table.concat({
    `<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">`,
    ringMarkup(cx, cx, (size - lw) / 2, lw, frac, track, fill),
    "</svg>",
  }, "")
end

-- ── public entry point ──────────────────────────────────────────────────────

local lastKey = nil
local lastPath = nil

-- One ring: `spec` is { frac = 0..1, role = palette role for the arc }. Returns an
-- absolute path to a ready SVG, or nil when one cannot be written (the caller
-- falls back to the glyph pill).
function M.path(spec, opts)
  opts = opts or {}
  local size = math.floor(tonumber(opts.size) or 16)
  if size < 8 then size = 8 end
  local lw = tonumber(opts.thickness) or 3
  if lw > size / 4 then lw = size / 4 end
  if lw < 1 then lw = 1 end

  local frac = tonumber(spec.frac) or 0
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  local track = M.color("surface_container", opts.trackColor, true)
  local fill = M.color(spec.role, opts.fillColor, false)

  local dir = noctalia.pluginDataDir()
  if dir == nil then return nil end
  local path = `{dir}/pill-ring.svg`

  local key = `{size}|{num(lw)}|{num(frac)}|{fill}|{track}`
  if key == lastKey and lastPath == path and noctalia.fileExists(path) then
    return path
  end

  local ok = noctalia.writeFile(path, buildSvg(size, lw, frac, track, fill))
  if not ok then return nil end
  lastKey, lastPath = key, path
  return path
end

return M
