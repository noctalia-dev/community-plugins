--!nonstrict
-- OLED wear model: wear rate per pixel = sum over channels of k_c * L_c^n,
-- n = 1.6 (luminance acceleration). WOLED routes min(R,G,B) through a white
-- subpixel. Values are relative; there is no absolute lifetime here.

local image = require("./image.luau")
local color = require("./color.luau")

local rf, wf = buffer.readf32, buffer.writef32

local budget = require("./budget.luau")
local K = require("./kernels.luau")

local M = {}

-- The pixel loop lives in kernels.luau; the engine swaps in its own fast copy.
function M.install(kernels)
	K = kernels
end

M.N = 1.6
M.PROFILES = {
	generic = { k = { 0.55, 0.75, 1.0 } },
	woled = { k = { 0.5, 0.6, 0.9 }, white = 1.0 },
	qdoled = { k = { 1.0, 1.0, 1.0 } },
}
M.ORDER = { "generic", "woled", "qdoled" }

function M.profile(name: string?)
	return M.PROFILES[name or "generic"] or M.PROFILES.generic
end

local function unit(v)
	return if v < 0 then 0 elseif v > 1 then 1 else v
end

function M.pixel(p, r: number, g: number, b: number): number
	local n = M.N
	r, g, b = unit(r), unit(g), unit(b)
	local k = p.k
	if p.white then
		local m = math.min(r, g, b)
		return p.white * m ^ n + k[1] * (r - m) ^ n + k[2] * (g - m) ^ n + k[3] * (b - m) ^ n
	end
	return k[1] * r ^ n + k[2] * g ^ n + k[3] * b ^ n
end

function M.white(p): number
	return M.pixel(p, 1, 1, 1)
end

function M.linearFromRgb8(img): image.LinearRGB
	local lin = image.rgbNew(img.w, img.h)
	local src = img.data
	local rd, gd, bd = lin.r.data, lin.g.data, lin.b.data
	for i = 0, img.w * img.h - 1 do
		if i % 1024 == 0 then
			budget.check()
		end
		local s, o = i * 3, i * 4
		wf(rd, o, color.toLinear8(buffer.readu8(src, s)))
		wf(gd, o, color.toLinear8(buffer.readu8(src, s + 1)))
		wf(bd, o, color.toLinear8(buffer.readu8(src, s + 2)))
	end
	return lin
end

-- The linear value of each 8-bit level as linearFromRgb8 stores it (f32).
local lut32 = nil
local function linearLut()
	if not lut32 then
		lut32 = table.create(256, 0)
		local b = buffer.create(4)
		for v = 0, 255 do
			buffer.writef32(b, 0, color.toLinear8(v))
			lut32[v + 1] = buffer.readf32(b, 0)
		end
	end
	return lut32
end

-- image.luma(linearFromRgb8(img)) in one pass, bit for bit.
function M.lumaFromRgb8(img): image.Image
	return image.lumaRgb8(img, linearLut())
end

function M.map(p, lin: image.LinearRGB): image.Image
	local out = image.new(lin.w, lin.h)
	K.wearMap(lin.r.data, lin.g.data, lin.b.data, lin.w * lin.h, p.k[1], p.k[2], p.k[3], p.white, M.N, out.data)
	return out
end

return M
