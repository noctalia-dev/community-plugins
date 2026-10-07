--!nonstrict
-- Shared post-it paper colors and the small color math the surfaces need.
--
-- A note either names its paper or leaves it dynamic. Dynamic paper comes in
-- two modes, chosen plugin-wide by `theme_colors`:
--   classic -> the hardcoded paper colors below, picked per note
--   theme   -> Noctalia palette roles, so notes follow the wallpaper colors
--
-- The classic colors are light, so their text is always the dark ink below.
-- Role names resolve live against the palette and pair with on_* roles.

local M = {}

M.NAMES = { "yellow", "orange", "pink", "red", "purple", "blue", "green", "gray" }

-- Two papers you can only ask for by name. Neither is ever generated: a wall of
-- translucent sheets is a wall you cannot read, and a wall of black ones is a
-- wall of holes. Picked deliberately, one of either is a good accent.
M.GLASS = "glass"
M.BLACK = "black"

local CLASSIC = {
  yellow = "#FFF0A5",
  orange = "#FFD3A3",
  pink   = "#FFC2D6",
  red    = "#FFB3AC",
  purple = "#DCC6F7",
  blue   = "#B9DDFF",
  green  = "#C5EDAE",
  gray   = "#DFE2E8",
}

-- Hex takes its alpha as #rrggbbaa; only role names accept the "role/0.6" form.
local INK = "#22262F"
local INK_MUTED = "#22262FA6"

-- Theme papers. Only the four accent roles: `surface_variant` is the panel
-- background of whatever scheme is loaded, so on a dark one it hands back a
-- near-black sheet that reads as a UI card someone forgot to style, not as
-- paper. Four looks instead of eight is the better trade.
--
-- Roles resolve live in the host, so a sheet recolors with the theme - which on
-- a generated scheme follows the wallpaper - without anything here reacting.
-- Each fill is paired with its own on_* role, the only text color guaranteed to
-- contrast with it.
local THEME_ROLES = {
  { fill = "primary", text = "on_primary" },
  { fill = "secondary", text = "on_secondary" },
  { fill = "tertiary", text = "on_tertiary" },
  { fill = "error", text = "on_error" },
}

-- Overlays for the tape and the drop shadow. Translucent black and white work
-- on both a hex paper and a palette role, because they are painted as children
-- of the paper and blend with whatever is behind them.

-- The drop shadow: one color, laid down as a single box per edge and feathered
-- with `softness`. The falloff is the feathering, not a stack of bands.
M.SHADOW = "#0000002E"

-- Matte tape: lightens the paper a little, with a hairline of shadow on each
-- edge. Too opaque and it stops reading as tape and starts reading as a label.
M.TAPE = "#FFFFFF59"
M.TAPE_EDGE = "#00000021"

-- Stable small hash of a string, so a post-it's generated look (paper tint,
-- tape) stays the same across restarts instead of shuffling.
function M.hash(text)
  local h = 5381
  for i = 1, #tostring(text) do
    h = (h * 33 + string.byte(text, i)) % 2147483647
  end
  return h
end

-- Deterministic pick from a list, driven by that hash.
function M.pick(list, text, salt)
  local h = M.hash(tostring(salt or "") .. "|" .. tostring(text))
  return list[(h % #list) + 1]
end

function M.isKnown(name)
  if type(name) ~= "string" then
    return false
  end
  return CLASSIC[name] ~= nil or name == M.GLASS or name == M.BLACK
end

local function clamp255(value)
  if value < 0 then
    return 0
  end
  if value > 255 then
    return 255
  end
  return value
end

-- Nudges each channel of a hex color by `delta`. Used for the per-note paper
-- jitter: two yellow post-its side by side should not look printed.
function M.shift(hex, delta)
  if string.sub(hex, 1, 1) ~= "#" or #hex < 7 then
    return hex
  end
  local r = clamp255(tonumber(string.sub(hex, 2, 3), 16) + delta)
  local g = clamp255(tonumber(string.sub(hex, 4, 5), 16) + delta)
  local b = clamp255(tonumber(string.sub(hex, 6, 7), 16) + delta)
  return string.format("#%02X%02X%02X", r, g, b)
end

-- Group opacity would fade the text along with the paper, so translucency goes
-- into the fill color itself: an alpha byte on hex, the "/a" suffix on a role.
function M.withAlpha(color, alpha)
  if alpha >= 0.999 then
    return color
  end
  if string.sub(color, 1, 1) == "#" then
    -- A hex color can already carry an alpha byte (glass does). Replacing it
    -- would throw that away, so the two fade together.
    local existing = 255
    if #color >= 9 then
      existing = tonumber(string.sub(color, 8, 9), 16) or 255
    end
    return string.format("%s%02X", string.sub(color, 1, 7),
      math.floor(existing * alpha + 0.5))
  end
  -- A role can already carry an alpha (glass does). Two suffixes would be a
  -- malformed color, so the two fade together instead.
  local base, existing = string.match(color, "^([%a_]+)/([%d.]+)$")
  if base ~= nil then
    return string.format("%s/%.2f", base, (tonumber(existing) or 1) * alpha)
  end
  return string.format("%s/%.2f", color, alpha)
end

-- Paper for a note.
--
--   a named color  -> that classic paper, fixed, whatever the theme does
--   no color ("")  -> dynamic: a palette role when theme colors are on, else a
--                     classic paper picked from the seed
--
-- Fixed is fixed on purpose: picking "yellow" and watching it turn green with
-- the next wallpaper is not a color choice, it is a surprise.
function M.paper(name, seed, useTheme)
  -- Glass: a pane rather than a sheet. A white veil over whatever is behind it,
  -- with a hairline edge, because a translucent rectangle with no edge reads as
  -- a smudge. Text is the theme's on_surface, which flips with light and dark
  -- schemes and keeps the veil readable either way. There is no blur behind it:
  -- the plugin API exposes none, and the shell's own blur is wired to its
  -- panels, not to plugin widgets.
  if name == M.GLASS then
    return "#FFFFFF52", "on_surface", "on_surface/0.6", "#FFFFFF59"
  end

  -- Black paper, white ink: the one sheet that reads as written on rather than
  -- printed, and the only fixed paper whose text is not the dark ink.
  if name == M.BLACK then
    return "#1C1F26", "#F3F4F6", "#F3F4F6A6"
  end

  if M.isKnown(name) then
    return CLASSIC[name], INK, INK_MUTED
  end

  if useTheme then
    local role = M.pick(THEME_ROLES, seed, "role")
    return role.fill, role.text, role.text .. "/0.7"
  end

  -- -6..+6 across the channels, which reads as paper stock variation.
  local generated = M.pick(M.NAMES, seed, "color")
  return M.shift(CLASSIC[generated], (M.hash(seed) % 13) - 6), INK, INK_MUTED
end

return M
