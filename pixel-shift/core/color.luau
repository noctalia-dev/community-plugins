--!nonstrict
-- sRGB <-> linear light, OKLab/OKLCH, and the theme-derived colour ramps.

local M = {}

M.FALLBACK_PRIMARY = "#8ab4f8"

local TO_LINEAR = table.create(256, 0)
for i = 0, 255 do
	local c = i / 255
	TO_LINEAR[i + 1] = if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end

function M.toLinear8(v: number): number
	return TO_LINEAR[v + 1]
end

function M.toLinear(c: number): number
	return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
end

function M.fromLinear(l: number): number
	if l <= 0 then
		return 0
	elseif l >= 1 then
		return 1
	end
	return if l <= 0.0031308 then 12.92 * l else 1.055 * l ^ (1 / 2.4) - 0.055
end

function M.to8(c: number): number
	local v = math.floor(c * 255 + 0.5)
	return if v < 0 then 0 elseif v > 255 then 255 else v
end

function M.hexToRgb(hex: string?): (number?, number?, number?)
	if type(hex) ~= "string" then
		return nil
	end
	local r, g, b = string.match(hex, "^#(%x%x)(%x%x)(%x%x)")
	if not r then
		return nil
	end
	return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

local function linearToOklab(r, g, b)
	local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
	local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
	local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
	return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end

local function oklabToLinear(L, a, b)
	local l_ = L + 0.3963377774 * a + 0.2158037573 * b
	local m_ = L - 0.1055613458 * a - 0.0638541728 * b
	local s_ = L - 0.0894841775 * a - 1.2914855480 * b
	local l, m, s = l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_
	return 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
end

function M.hexToOklch(hex: string?): (number?, number?, number?)
	local r, g, b = M.hexToRgb(hex)
	if not r then
		return nil
	end
	local L, a, bb = linearToOklab(M.toLinear(r), M.toLinear(g), M.toLinear(b))
	return L, math.sqrt(a * a + bb * bb), math.deg(math.atan2(bb, a)) % 360
end

-- sRGB 0..1, gamut-clipped per channel in linear light.
function M.oklchToSrgb(L: number, C: number, h: number): (number, number, number)
	local rad = math.rad(h)
	local r, g, b = oklabToLinear(L, C * math.cos(rad), C * math.sin(rad))
	return M.fromLinear(r), M.fromLinear(g), M.fromLinear(b)
end

local function clamp(x, a, b)
	return if x < a then a elseif x > b then b else x
end

-- 256-step ramp in the primary's hue; lightness rises L0 -> L1.
local function ramp(hex, L0, L1, chroma)
	local _, C, h = M.hexToOklch(hex)
	if not C then
		_, C, h = M.hexToOklch(M.FALLBACK_PRIMARY)
	end
	local out = table.create(256)
	for i = 0, 255 do
		local t = i / 255
		local r, g, b = M.oklchToSrgb(L0 + (L1 - L0) * t, chroma(C, t), h)
		out[i + 1] = { M.to8(r), M.to8(g), M.to8(b) }
	end
	return out
end

-- Hotspot glow (spec 5.3): theme hue, chroma boosted so near-grey and dark
-- primaries still glow bright and coloured.
function M.glowRamp(hex: string?)
	return ramp(hex, 0.50, 0.90, function(C)
		return clamp(math.max(1.6 * C, 0.13), 0.13, 0.22)
	end)
end

-- Risk view ramp: dark to bright in the theme hue.
function M.riskRamp(hex: string?)
	return ramp(hex, 0.24, 0.95, function(C, t)
		return clamp(C, 0.07, 0.19) * (0.55 + 0.45 * math.sin(math.pi * t * 0.9))
	end)
end

return M
