--!nonstrict
-- The switchboard's two instruments, shared by the bar and desktop widgets:
--   lamps(sessions): one lamp per live session on a small board; a session that needs
--     you blinks (the caller re-renders on a short tick and passes the phase).
--   image(windows):  nested rings in one SVG, innermost first (5h inside 7d): solid arc
--     for what is used, faint arc for where the current rate takes it by the reset.
-- ui.* has no arcs, so the rings are an SVG written once per (values, colors) into the
-- data dir and shown with ui.image; colors come from noctalia.getColor so they follow
-- the theme. Files are kept per state rather than rewritten, since images may be cached
-- by path.
local shared = require("./shared.luau")
local M = {}

local DIR = (noctalia.pluginDataDir() or "/tmp") .. "/gauges"
local KEEP = 80 -- files kept before the folder is cleared; they are cheap to redraw

local LAMP = { waiting = "error", busy = "primary", idle = "on_surface_variant/0.45" }

function M.lamps(sessions, size, blinkOff, max)
  size, max = size or 8, max or 8
  local lamps = {}
  for i, s in ipairs(sessions) do
    if i > max then
      lamps[#lamps + 1] = ui.label({ text = `+{#sessions - max}`, fontSize = size + 2, color = "on_surface_variant" })
      break
    end
    lamps[#lamps + 1] = ui.box({ width = size, height = size, radius = 2, fill = LAMP[s.status] or LAMP.idle,
      opacity = s.status == "waiting" and blinkOff and 0.25 or 1 })
  end
  if #lamps == 0 then
    lamps[1] = ui.box({ width = size, height = size, radius = 2, fill = "on_surface/0.12" })
  end
  return ui.row({ gap = 3, align = "center", paddingH = 4, paddingV = 3, radius = 4, fill = "on_surface/0.06" }, lamps)
end

local function hex(role)
  local c = noctalia.getColor(string.match(role, "^[^/]+"))
  return c and string.gsub(c, "#", "") or "888888"
end

-- windows: { { percent, projected, role } }, innermost first. Returns an image path.
function M.image(windows)
  local track = hex("on_surface")
  local parts = { track }
  for _, w in ipairs(windows) do
    local used = math.max(0, math.min(100, shared.round(w.percent)))
    local proj = math.max(used, math.min(100, 5 * shared.round((w.projected or used) / 5)))
    w.used, w.proj, w.hex = used, proj, hex(w.role)
    parts[#parts + 1] = `{used}-{proj}-{w.hex}`
  end
  local path = `{DIR}/g3-{table.concat(parts, "_")}.svg` -- bump the prefix when the drawing changes
  if noctalia.fileExists(path) then return path end

  noctalia.mkdirAll(DIR)
  local files = noctalia.listDir(DIR) or {}
  if #files > KEEP then
    for _, f in ipairs(files) do noctalia.removeFile(string.find(f, "/") and f or DIR .. "/" .. f) end
  end
  local n = #windows
  -- Thick strokes: the gauge is ~22 px on a bar, so anything thinner blurs into one ring.
  local stroke = n >= 3 and 4.5 or 6.5
  local svg = { '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 40 40">' }
  for i, w in ipairs(windows) do
    -- Outermost ring last in the list; rings step inwards by stroke + 1.5.
    local r = 20 - stroke / 2 - (n - i) * (stroke + 1.5)
    local c = 2 * math.pi * r
    -- Two-value dashes only, rotated to where each arc starts: some SVG renderers drop a
    -- dash pattern that opens with a zero-length dash.
    local function arc(fromPct, toPct, color, opacity)
      local dash = toPct >= 100 and fromPct <= 0 and "" or
        string.format(' stroke-dasharray="%.2f %.2f"', c * (toPct - fromPct) / 100, c)
      svg[#svg + 1] = string.format(
        '<circle cx="20" cy="20" r="%.2f" fill="none" stroke="#%s" stroke-opacity="%.2f" stroke-width="%.1f"%s transform="rotate(%.1f 20 20)"/>',
        r, color, opacity, stroke, dash, -90 + 3.6 * fromPct)
    end
    arc(0, 100, track, 0.12)
    if w.proj > w.used then arc(w.used, w.proj, w.hex, 0.3) end
    if w.used > 0 then arc(0, w.used, w.hex, 1) end
  end
  svg[#svg + 1] = "</svg>"
  noctalia.writeFile(path, table.concat(svg))
  return path
end

-- The windows a bar shows, innermost first: 5h, then 7d, then per-model weeks with "all".
local SHOWN = { ["5h"] = { session = 1 }, ["7d"] = { weekly_all = 1 }, ["5h_7d"] = { session = 1, weekly_all = 2 } }

function M.pick(limits, mode)
  local out = {}
  if not limits or mode == "none" then return out end
  for _, w in ipairs(limits.windows or {}) do
    if mode == "all" or (SHOWN[mode] and SHOWN[mode][w.kind]) then out[#out + 1] = w end
  end
  table.sort(out, function(a, b)
    local function rank(w) return w.kind == "session" and 1 or w.kind == "weekly_all" and 2 or 3 end
    return rank(a) < rank(b)
  end)
  return out
end

return M
