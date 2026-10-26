--!nonstrict
-- Progress ring drawn as an SVG in the current palette colors (spec §7.2, spike S3).
--
-- `ui.image` cannot take inline SVG from a plugin, so rings are written to
-- `cache/` in the data dir and shown by path. The file name holds everything the image
-- depends on (geometry, percent, variant, palette hash): the host only reloads an image
-- when its path changes, so a palette change must produce new names. Progress is
-- quantised to whole percents, up to 200 % (the overtime lap), which bounds the cache.

local Types = require("./types.luau")

type Host = Types.Host

local Ring = {}

-- Bump when the drawing changes, so cached files from older code are not reused.
local VERSION = "r1"
local TRACK_OPACITY = 0.18

export type Colors = { track: string, arc: string, over: string }

local function hash(text: string): string
  local h = 5381
  for i = 1, #text do
    h = (h * 33 + string.byte(text, i)) % 4294967296
  end
  return string.format("%08x", h)
end

-- Palette colors of a ring. A muted ring (tracking off) keeps its progress in a
-- neutral color. Track: `on_surface` at low opacity, visible on any surface (S3).
function Ring.colors(host: Host, muted: boolean?): Colors
  local track = host.getColor("on_surface") or "#888888"
  if muted then
    local neutral = host.getColor("on_surface_variant") or "#888888"
    return { track = track, arc = neutral, over = neutral }
  end
  return {
    track = track,
    arc = host.getColor("primary") or "#888888",
    over = host.getColor("tertiary") or "#888888",
  }
end

local function paletteHash(host: Host): string
  local normal, muted = Ring.colors(host, false), Ring.colors(host, true)
  return hash(normal.track .. normal.arc .. normal.over .. muted.arc)
end

local function circle(center: number, radius: number, stroke: number, color: string, extra: string): string
  return string.format(
    '<circle cx="%.2f" cy="%.2f" r="%.2f" fill="none" stroke="%s" stroke-width="%.2f"%s/>',
    center, center, radius, color, stroke, extra
  )
end

local function arc(center: number, radius: number, stroke: number, color: string, fraction: number): string
  if fraction <= 0 then
    return ""
  end
  local length = 2 * math.pi * radius
  return circle(center, radius, stroke, color, string.format(
    ' stroke-linecap="round" stroke-dasharray="%.3f %.3f" transform="rotate(-90 %.2f %.2f)"',
    length * math.min(fraction, 1), length, center, center
  ))
end

-- SVG source of a ring: `percent` 0..200, the part above 100 drawn as a second lap.
function Ring.svg(size: number, stroke: number, percent: number, colors: Colors): string
  local radius = (size - stroke) / 2
  local center = size / 2
  return table.concat({
    string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">', size, size, size, size),
    circle(center, radius, stroke, colors.track, string.format(' stroke-opacity="%.2f"', TRACK_OPACITY)),
    arc(center, radius, stroke, colors.arc, percent / 100),
    arc(center, radius, stroke, colors.over, percent / 100 - 1),
    "</svg>",
  })
end

local function cacheDir(host: Host): string?
  local dir = host.pluginDataDir()
  return dir and dir .. "/cache"
end

-- Path of the ring image for `progress` (0 = empty, 1 = target, 2 = two laps), written
-- on first use. `stroke` is in logical pixels. Returns nil when the cache cannot be
-- written; callers then fall back to `ui.progress`.
function Ring.path(host: Host, size: number, stroke: number, progress: number, muted: boolean?): string?
  local dir = cacheDir(host)
  if not dir then
    return nil
  end
  local percent = math.clamp(math.floor(progress * 100 + 0.5), 0, 200)
  local file = string.format(
    "%s/ring-%s-%d-%d-%d-%s-%s.svg",
    dir, VERSION, size, math.floor(stroke * 10 + 0.5), percent, muted and "m" or "a", paletteHash(host)
  )
  if host.fileExists(file) then
    return file
  end
  host.mkdirAll(dir)
  if not host.writeFile(file, Ring.svg(size, stroke, percent, Ring.colors(host, muted))) then
    return nil
  end
  return file
end

-- Deletes cached rings drawn by older code or for another palette (spec §7.2).
function Ring.prune(host: Host): number
  local dir = cacheDir(host)
  local names = dir and host.listDir(dir)
  if not names then
    return 0
  end
  local suffix = "-" .. paletteHash(host) .. ".svg"
  local prefix = "ring-" .. VERSION .. "-"
  local removed = 0
  for _, name in names do
    local current = string.sub(name, 1, #prefix) == prefix and string.sub(name, -#suffix) == suffix
    if string.match(name, "^ring%-.*%.svg$") and not current then
      host.removeFile(dir .. "/" .. name)
      removed += 1
    end
  end
  return removed
end

return Ring
