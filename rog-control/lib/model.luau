--!nonstrict
-- Shared vocabulary for every ROG Control entry: what asusd and supergfxd call
-- things, what the user sees, and the few derived values more than one entry needs.

local M = {}

M.PANEL_ID = "genuinemoron/rog-control:panel"
M.STATE = "rog.state"
M.REQUEST = "rog.request"

-- asusd PlatformProfile values, in the order a person thinks about them:
-- quietest to fastest. ASUS calls them Silent, Performance and Turbo on Windows;
-- "Balanced" reads better next to the other two here.
M.PROFILES = {
  { value = 2, key = "profile.silent", glyph = "leaf" },
  { value = 0, key = "profile.balanced", glyph = "scale" },
  { value = 1, key = "profile.turbo", glyph = "rocket" },
}

-- Graphics modes, numbered as supergfxd's GfxMode so both back ends share them.
-- Only these three are offered; supergfxd's VFIO, eGPU and "no modeset" modes are
-- for setups this panel isn't aimed at.
M.GPU_ECO = 1
M.GPU_STANDARD = 0
M.GPU_ULTIMATE = 5
M.GPU_MODES = {
  { value = M.GPU_ECO, key = "gpu.eco", glyph = "leaf" },
  { value = M.GPU_STANDARD, key = "gpu.standard", glyph = "device-laptop" },
  { value = M.GPU_ULTIMATE, key = "gpu.ultimate", glyph = "bolt" },
}

-- supergfxd UserActionRequired values that need the user to act.
M.GPU_ACTION_LOGOUT = 0
M.GPU_ACTION_REBOOT = 1
M.GPU_ACTION_NONE = 4

-- rog-aura AuraModeNum values asusd may list in SupportedBasicModes.
M.AURA_MODES = {
  [0] = "aura.static",
  [1] = "aura.breathe",
  [2] = "aura.rainbow_cycle",
  [3] = "aura.rainbow_wave",
  [10] = "aura.pulse",
}

-- Rainbow effects cycle colours, so a single-colour keyboard can't show them.
M.RAINBOW_MODES = { [2] = true, [3] = true }

-- The effects worth offering: the ones asusd supports that have a name here, minus
-- the rainbows on a single-colour keyboard. Keeps asusd's order.
function M.auraModes(supported, colour)
  local out = {}
  for _, v in ipairs(supported or {}) do
    if M.AURA_MODES[v] ~= nil and (colour or not M.RAINBOW_MODES[v]) then
      table.insert(out, v)
    end
  end
  return out
end

-- rog-slash SlashMode byte values, in asusctl's listing order.
M.SLASH_MODES = {
  { value = 0x06, name = "Static" },
  { value = 0x10, name = "Bounce" },
  { value = 0x12, name = "Slash" },
  { value = 0x13, name = "Loading" },
  { value = 0x1d, name = "BitStream" },
  { value = 0x1a, name = "Transmission" },
  { value = 0x19, name = "Flow" },
  { value = 0x25, name = "Flux" },
  { value = 0x24, name = "Phantom" },
  { value = 0x26, name = "Spectrum" },
  { value = 0x32, name = "Hazard" },
  { value = 0x33, name = "Interfacing" },
  { value = 0x34, name = "Ramp" },
  { value = 0x42, name = "GameOver" },
  { value = 0x43, name = "Start" },
  { value = 0x44, name = "Buzzer" },
}

function M.profile(value)
  for _, p in ipairs(M.PROFILES) do
    if p.value == value then
      return p
    end
  end
  return nil
end

-- Profiles asusd offers on this machine, in M.PROFILES order.
function M.availableProfiles(choices)
  local offered = {}
  for _, v in ipairs(choices or {}) do
    offered[v] = true
  end
  local list = {}
  for _, p in ipairs(M.PROFILES) do
    if next(offered) == nil or offered[p.value] then
      table.insert(list, p)
    end
  end
  return list
end

-- The profile after (or before, delta = -1) the current one, wrapping around.
function M.stepProfile(current, choices, delta)
  local list = M.availableProfiles(choices)
  if #list == 0 then
    return nil
  end
  local index = 1
  for i, p in ipairs(list) do
    if p.value == current then
      index = i
      break
    end
  end
  return list[((index - 1 + delta) % #list) + 1].value
end

function M.gpuMode(value)
  for _, g in ipairs(M.GPU_MODES) do
    if g.value == value then
      return g
    end
  end
  return nil
end

-- A theme accent turned into a keyboard colour. Dark-mode accents are pastel, and
-- an LED shows low saturation as plain white, so keep the hue and move saturation
-- into a calm band that still reads as a colour: tinted, never neon.
function M.ledColour(hex)
  local h = string.match(hex or "", "^#?(%x%x%x%x%x%x)")
  if h == nil then
    return nil
  end
  local r = tonumber(string.sub(h, 1, 2), 16) / 255
  local g = tonumber(string.sub(h, 3, 4), 16) / 255
  local b = tonumber(string.sub(h, 5, 6), 16) / 255
  local maxc, minc = math.max(r, g, b), math.min(r, g, b)
  local delta = maxc - minc
  local hue = 0
  if delta > 0 then
    if maxc == r then
      hue = ((g - b) / delta) % 6
    elseif maxc == g then
      hue = (b - r) / delta + 2
    else
      hue = (r - g) / delta + 4
    end
    hue /= 6
  end
  local sat = maxc > 0 and delta / maxc or 0
  sat = math.clamp(sat * 1.5, 0.45, 0.75)
  -- HSV -> RGB at full value
  local i = math.floor(hue * 6)
  local f = hue * 6 - i
  local p, q, t = 1 - sat, 1 - f * sat, 1 - (1 - f) * sat
  local rr, gg, bb
  i %= 6
  if i == 0 then
    rr, gg, bb = 1, t, p
  elseif i == 1 then
    rr, gg, bb = q, 1, p
  elseif i == 2 then
    rr, gg, bb = p, 1, t
  elseif i == 3 then
    rr, gg, bb = p, q, 1
  elseif i == 4 then
    rr, gg, bb = t, p, 1
  else
    rr, gg, bb = 1, p, q
  end
  return math.round(rr * 255), math.round(gg * 255), math.round(bb * 255)
end

function M.hex(r, g, b)
  return string.format("#%02x%02x%02x", r, g, b)
end

return M
