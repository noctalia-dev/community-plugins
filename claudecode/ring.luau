--!nonstrict
-- Circular progress rings for the bar pill.
--
-- Noctalia's ui.* vocabulary has no arc primitive and barWidget has no drawing
-- surface, but both the bar (barWidget.setImage) and the panels (ui.image) load
-- images through an librsvg-backed loader. So a ring is an SVG we generate here,
-- write to the plugin data dir and hand back as a path.
--
-- SVG needs literal hex, and the plugin API has no palette-role resolver, so the
-- palette is resolved by reading the same files the shell reads:
--
--   theme.source = "custom"    ~/.config/noctalia/palettes/<name>.json
--   theme.source = "community" <state>/community-palettes/<name>.json
--   theme.source = "wallpaper" reproduced with `noctalia theme <image> --dark`
--   theme.source = "builtin"   compiled into the shell binary — not readable;
--                              the ring_color / ring_track_color settings win
--
-- Anything that fails falls back the same way, so the ring always draws.

local M = {}

-- Palette JSON key per role (the roles this plugin actually asks for).
local ROLE_KEYS = {
  primary = "mPrimary",
  secondary = "mSecondary",
  tertiary = "mTertiary",
  error = "mError",
  surface = "mSurface",
  on_surface = "mOnSurface",
  surface_variant = "mSurfaceVariant",
  on_surface_variant = "mOnSurfaceVariant",
  outline = "mOutline",
}

-- Last-resort hexes when no palette resolves and no setting is configured.
-- Amber / red for the pace cues: those read the same in every theme.
local HARD_FALLBACK = {
  tertiary = "#D8A657",
  error = "#E06C75",
}
local FALLBACK_FILL = "#89B4FA"
local FALLBACK_TRACK = "#585B70"

-- ── palette resolution ──────────────────────────────────────────────────────

local palette = nil -- role -> "#rrggbb", or nil when unresolved
local paletteSig = nil -- signature the cached palette was built for
local pendingSig = nil -- signature of an in-flight async (wallpaper) resolve
local onPalette = nil -- called when an async resolve lands

local function env(name)
  local v = noctalia.getenv(name)
  if v == nil or v == "" then return nil end
  return v
end

local function stateDirs()
  local dirs = {}
  local n = env("NOCTALIA_STATE_HOME")
  if n then
    table.insert(dirs, n)
    table.insert(dirs, `{n}/noctalia`)
  end
  local x = env("XDG_STATE_HOME")
  if x then table.insert(dirs, `{x}/noctalia`) end
  local home = env("HOME")
  if home then table.insert(dirs, `{home}/.local/state/noctalia`) end
  return dirs
end

local function configPaletteDirs()
  local dirs = {}
  local x = env("XDG_CONFIG_HOME")
  if x then table.insert(dirs, `{x}/noctalia/palettes`) end
  local home = env("HOME")
  if home then table.insert(dirs, `{home}/.config/noctalia/palettes`) end
  return dirs
end

-- The shell stores community palettes under their URL-encoded name; a custom
-- palette keeps its folder name verbatim. Try both spellings either way.
local function findPaletteFile(dirs, name)
  local names = { name }
  local encoded = noctalia.string.urlEncode(name)
  if encoded ~= name then table.insert(names, encoded) end
  for _, dir in dirs do
    for _, n in names do
      local path = `{dir}/{n}.json`
      if noctalia.fileExists(path) then return path end
    end
  end
  return nil
end

-- A decoded palette document -> { role = hex }, or nil when it has no colors.
local function rolesFrom(doc, dark)
  if type(doc) ~= "table" then return nil end
  local variant = doc[dark and "dark" or "light"]
  if type(variant) ~= "table" then variant = doc end
  local out, found = {}, false
  for role, key in ROLE_KEYS do
    local hex = variant[key]
    if type(hex) == "string" and hex:sub(1, 1) == "#" then
      out[role] = hex
      found = true
    end
  end
  if not found then return nil end
  return out
end

local function readPaletteFile(path, dark)
  local text = noctalia.readFile(path)
  if type(text) ~= "string" or text == "" then return nil end
  local doc = noctalia.json.decode(text)
  return rolesFrom(doc, dark)
end

-- Wallpaper palettes are matugen-derived in memory; re-derive them with the CLI.
local function resolveWallpaper(sig, dark, connector)
  local image = connector and noctalia.wallpaperPath(connector) or nil
  if image == nil or image == "" then return end
  local argv = { "noctalia", "theme", image, dark and "--dark" or "--light" }
  local scheme = noctalia.getSetting("theme.wallpaper_scheme")
  if type(scheme) == "string" and scheme ~= "" then
    table.insert(argv, "--scheme")
    table.insert(argv, scheme)
  end
  if dark and noctalia.getSetting("theme.pure_black_dark") == true then
    table.insert(argv, "--pure-black")
  end

  pendingSig = sig
  noctalia.runAsync(argv, function(result)
    if pendingSig ~= sig then return end -- superseded by a later theme change
    pendingSig = nil
    if type(result) ~= "table" or result.exitCode ~= 0 then return end
    local roles = rolesFrom(noctalia.json.decode(result.stdout or ""), dark)
    if roles == nil then return end
    palette, paletteSig = roles, sig
    if onPalette then onPalette() end
  end, 8000)
end

-- Re-resolve when the effective theme changed. Cheap and idempotent.
local function refreshPalette(connector)
  local source = noctalia.getSetting("theme.source")
  if type(source) ~= "string" then source = "" end
  local dark = noctalia.isDarkMode()

  local name = ""
  if source == "custom" then
    name = noctalia.getSetting("theme.custom_palette") or ""
  elseif source == "community" then
    name = noctalia.getSetting("theme.community_palette") or ""
  elseif source == "builtin" then
    name = noctalia.getSetting("theme.builtin") or ""
  elseif source == "wallpaper" then
    name = tostring(noctalia.getSetting("theme.wallpaper_scheme") or "")
    if connector then name = `{name}@{connector}` end
  end

  local sig = `{source}/{name}/{dark and "dark" or "light"}`
  if sig == paletteSig then return end

  if source == "custom" and name ~= "" then
    local path = findPaletteFile(configPaletteDirs(), name)
    palette = path and readPaletteFile(path, dark) or nil
  elseif source == "community" and name ~= "" then
    local dirs = {}
    for _, dir in stateDirs() do table.insert(dirs, `{dir}/community-palettes`) end
    local path = findPaletteFile(dirs, name)
    palette = path and readPaletteFile(path, dark) or nil
  else
    palette = nil
  end

  paletteSig = sig
  if source == "wallpaper" and palette == nil then
    resolveWallpaper(sig, dark, connector)
  end
end

-- Called when an async palette resolve lands, so the caller can redraw.
function M.setOnPaletteChanged(callback)
  onPalette = callback
end

-- Palette role -> hex. `fallback` is the configured color for this slot; a role
-- name there is resolved too, so "outline" in a color setting keeps working.
function M.color(role, fallback, isTrack)
  if palette and palette[role] then return palette[role] end
  if type(fallback) == "string" and fallback ~= "" then
    if fallback:sub(1, 1) == "#" then return fallback end
    if palette and palette[fallback] then return palette[fallback] end
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

  refreshPalette(opts.connector)

  local frac = tonumber(spec.frac) or 0
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  local track = M.color("surface_variant", opts.trackColor, true)
  local fill = M.color(spec.role, opts.fillColor, false)

  local dir = noctalia.pluginDataDir()
  if dir == nil then return nil end
  local path = `{dir}/pill-ring.svg`

  local key = `{paletteSig or "-"}|{size}|{num(lw)}|{num(frac)}|{fill}|{track}`
  if key == lastKey and lastPath == path and noctalia.fileExists(path) then
    return path
  end

  local ok = noctalia.writeFile(path, buildSvg(size, lw, frac, track, fill))
  if not ok then return nil end
  lastKey, lastPath = key, path
  return path
end

return M
