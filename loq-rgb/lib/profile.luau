--!nonstrict
-- Shared profile model for the service, the panel and the bar widget.
-- A profile is a plain table (strings, numbers, booleans, arrays) so it can travel through
-- noctalia.state and be saved as JSON. Zone counts vary per keyboard, so nothing here assumes 24.
local M = {}

M.MODES = { "palette", "gradient", "custom", "static", "firmware" }
-- Offered in the palette editor; roles unknown to the active theme are hidden.
-- Only roles valid at plugin_api 32: the container roles (including surface_container) need API 43
-- and surface_variant is retired, so none of them are listed.
M.ROLE_CANDIDATES = {
  "primary", "secondary", "tertiary",
  "surface", "on_surface", "error",
}

local function clamp(n, lo, hi)
  return math.max(lo, math.min(hi, n))
end

local function round(n)
  return math.floor(n + 0.5)
end

-- "#rrggbb" or "rrggbb" -> lowercase "rrggbb", otherwise nil
function M.normHex(s)
  if type(s) ~= "string" then
    return nil
  end
  local h = string.match(s, "^#?(%x%x%x%x%x%x)$")
  if h then
    return string.lower(h)
  end
  return nil
end

local function isMode(m)
  for _, v in ipairs(M.MODES) do
    if v == m then
      return true
    end
  end
  return false
end

-- POSIX single-quote escaping, for the few places that need a shell string.
function M.shellQuote(s)
  return "'" .. (string.gsub(tostring(s), "'", "'\\''")) .. "'"
end

function M.defaults()
  return {
    mode = "palette",
    on = true,
    br = 100,
    static = "ff0000",
    roles = { "primary", "secondary", "tertiary" },
    smooth = false,
    ga = "ff0066",   -- gradient start
    gb = "0066ff",   -- gradient end
    gm = "00ff88",   -- gradient middle point
    gzf = 0.5,       -- middle point position, 0..1 along the keyboard
    gmid = false,    -- three-point gradient
    custom = { "ffffff" },
  }
end

-- Validated copy of an untrusted table (state channel, file): invalid fields fall back to defaults.
function M.sanitize(t)
  local p = M.defaults()
  if type(t) ~= "table" then
    return p
  end
  if isMode(t.mode) then p.mode = t.mode end
  if type(t.on) == "boolean" then p.on = t.on end
  if type(t.br) == "number" then p.br = round(clamp(t.br, 0, 100)) end
  for _, k in ipairs({ "static", "ga", "gb", "gm" }) do
    local h = M.normHex(t[k])
    if h then p[k] = h end
  end
  if type(t.gzf) == "number" then p.gzf = clamp(t.gzf, 0, 1) end
  if type(t.gmid) == "boolean" then p.gmid = t.gmid end
  if type(t.smooth) == "boolean" then p.smooth = t.smooth end
  if type(t.roles) == "table" then
    local r = {}
    for _, v in ipairs(t.roles) do
      if type(v) == "string" and string.match(v, "^[%w_]+$") and #r < 12 then
        table.insert(r, v)
      end
    end
    if #r > 0 then p.roles = r end
  end
  if type(t.custom) == "table" then
    local c = {}
    for _, v in ipairs(t.custom) do
      local h = M.normHex(v)
      if h and #c < 64 then
        table.insert(c, h)
      end
    end
    if #c > 0 then p.custom = c end
  end
  return p
end

-- Custom colors resampled (nearest) to n zones, so a profile survives a keyboard change.
function M.fitCustom(p, n)
  local src, out = p.custom, {}
  for i = 0, n - 1 do
    out[i + 1] = src[math.min(#src, math.floor(i * #src / n) + 1)]
  end
  return out
end

-- Zone index (0-based) of the gradient's middle point, or nil when the keyboard is too small.
function M.midIndex(p, n)
  if n < 3 then
    return nil
  end
  return clamp(round(p.gzf * (n - 1)), 1, n - 2)
end

-- ---------------------------------------------------------------- colour maths
local function toRgb(h)
  return tonumber(string.sub(h, 1, 2), 16), tonumber(string.sub(h, 3, 4), 16), tonumber(string.sub(h, 5, 6), 16)
end

function M.toRgb(h)
  return toRgb(h)
end

function M.mix(a, b, t)
  local ar, ag, ab = toRgb(a)
  local br, bg, bb = toRgb(b)
  local function m(x, y)
    return math.floor(x + (y - x) * t + 0.5)
  end
  return string.format("%02x%02x%02x", m(ar, br), m(ag, bg), m(ab, bb))
end

-- h: 0..360, s and v: 0..1
function M.hsvToHex(h, s, v)
  local c = v * s
  local hp = (h % 360) / 60
  local x = c * (1 - math.abs(hp % 2 - 1))
  local r, g, b = 0, 0, 0
  if hp < 1 then r, g, b = c, x, 0
  elseif hp < 2 then r, g, b = x, c, 0
  elseif hp < 3 then r, g, b = 0, c, x
  elseif hp < 4 then r, g, b = 0, x, c
  elseif hp < 5 then r, g, b = x, 0, c
  else r, g, b = c, 0, x end
  local m = v - c
  return string.format("%02x%02x%02x",
    math.floor((r + m) * 255 + 0.5), math.floor((g + m) * 255 + 0.5), math.floor((b + m) * 255 + 0.5))
end

function M.hexToHsv(hex)
  local r8, g8, b8 = toRgb(hex)
  local r, g, b = r8 / 255, g8 / 255, b8 / 255
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then h = 60 * (((g - b) / d) % 6)
    elseif mx == g then h = 60 * ((b - r) / d + 2)
    else h = 60 * ((r - g) / d + 4) end
  end
  local sat = 0
  if mx > 0 then sat = d / mx end
  return h, sat, mx
end

-- ---------------------------------------------------------------- palette
-- Hex colours of the palette roles the active theme knows.
function M.roleColors(roles)
  local out = {}
  for _, r in ipairs(roles) do
    local c = M.normHex(noctalia.getColor(r))
    if c then
      table.insert(out, c)
    end
  end
  return out
end

-- Changes whenever the theme recolours one of the selected roles (wallpaper change, dark mode...).
function M.paletteSignature(p)
  return table.concat(M.roleColors(p.roles), ",")
end

-- The n colours (hex array, zone 0 = index 1) of a profile, or nil + reason.
function M.colors(p, n)
  local out = {}
  if n < 1 then
    return nil, "no zones"
  end
  if p.mode == "static" then
    for i = 1, n do out[i] = p.static end
  elseif p.mode == "custom" then
    out = M.fitCustom(p, n)
  elseif p.mode == "gradient" then
    local mid = nil
    if p.gmid then mid = M.midIndex(p, n) end
    for i = 0, n - 1 do
      local c
      if n == 1 then
        c = p.ga
      elseif mid then
        if i <= mid then
          c = M.mix(p.ga, p.gm, i / mid)
        else
          c = M.mix(p.gm, p.gb, (i - mid) / (n - 1 - mid))
        end
      else
        c = M.mix(p.ga, p.gb, i / (n - 1))
      end
      out[i + 1] = c
    end
  elseif p.mode == "palette" then
    local rc = M.roleColors(p.roles)
    if #rc == 0 then
      return nil, "no palette role available"
    end
    for i = 0, n - 1 do
      if p.smooth and #rc > 1 and n > 1 then
        local pos = i / (n - 1) * (#rc - 1)
        local a = math.min(math.floor(pos), #rc - 2)
        out[i + 1] = M.mix(rc[a + 1], rc[a + 2], pos - a)
      else
        out[i + 1] = rc[math.min(math.floor(i * #rc / n), #rc - 1) + 1]
      end
    end
  else
    return nil, "this mode has no colours"
  end
  return out
end

return M
