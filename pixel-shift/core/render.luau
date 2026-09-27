--!nonstrict
-- Lab images: the ghost preview with theme-coloured glow proportional to
-- risk (one absolute scale for every view), the risk view, and the helpers
-- that size them for the panel.

local image = require("./image.luau")
local ppm = require("./ppm.luau")
local color = require("./color.luau")

local rf = buffer.readf32
local wu8, ru8 = buffer.writeu8, buffer.readu8

local budget = require("./budget.luau")

local M = {}

local function smoothstep(e0, e1, x)
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function byte(v)
	v = math.floor(v + 0.5)
	return if v < 0 then 0 elseif v > 255 then 255 else v
end

-- What the bar leaves on a flat mid-grey screen: grey 0..1 (sRGB).
function M.ghostGray(E, eRef: number)
	local out = image.new(E.w, E.h)
	local inv = 1 / math.max(eRef, 1e-9)
	for o = 0, (E.w * E.h - 1) * 4, 4 do
		if o % 4096 == 0 then
			budget.check()
		end
		local e = math.clamp(rf(E.data, o) * inv, 0, 1)
		buffer.writef32(out.data, o, (0.60 - 0.40 * e ^ 0.8) * 0.72)
	end
	return out
end

-- Composite the risk glow over a grey base (spec 5.2).
function M.glow(base, R, rTop: number, ramp)
	local w, h = R.w, R.h
	local t = image.new(w, h)
	local inv = 1 / math.max(rTop, 1e-9)
	for o = 0, (w * h - 1) * 4, 4 do
		if o % 4096 == 0 then
			budget.check()
		end
		buffer.writef32(t.data, o, math.clamp(rf(R.data, o) * inv, 0, 1))
	end
	local bloom = image.gauss3(t, 1)
	local out = ppm.new(w, h)
	for i = 0, w * h - 1 do
		if i % 1024 == 0 then
			budget.check()
		end
		local o = i * 4
		local tt = math.min(rf(t.data, o) + 0.35 * rf(bloom.data, o), 1)
		local a = smoothstep(0.16, 0.55, tt)
		local c = ramp[math.floor(tt * 255) + 1]
		local g = rf(base.data, o) * 255
		local d = i * 3
		wu8(out.data, d, byte(g * (1 - a) + c[1] * a))
		wu8(out.data, d + 1, byte(g * (1 - a) + c[2] * a))
		wu8(out.data, d + 2, byte(g * (1 - a) + c[3] * a))
	end
	return out
end

function M.ghostView(E, R, eRef: number, rTop: number, ramp)
	return M.glow(M.ghostGray(E, eRef), R, rTop, ramp)
end

-- Dimmed bar (20 % of its sRGB luma) with the risk ramp on top.
function M.riskView(lum, R, rTop: number, ramp)
	local w, h = R.w, R.h
	local out = ppm.new(w, h)
	local inv = 1 / math.max(rTop, 1e-9)
	for i = 0, w * h - 1 do
		if i % 1024 == 0 then
			budget.check()
		end
		local o = i * 4
		local tr = math.clamp(rf(R.data, o) * inv, 0, 1) ^ 0.7
		local a = math.clamp(1.4 * tr, 0, 1)
		local g = color.fromLinear(rf(lum.data, o)) * 0.2 * 255
		local c = ramp[math.floor(tr * 255) + 1]
		local d = i * 3
		wu8(out.data, d, byte(g * (1 - a) + c[1] * a))
		wu8(out.data, d + 1, byte(g * (1 - a) + c[2] * a))
		wu8(out.data, d + 2, byte(g * (1 - a) + c[3] * a))
	end
	return out
end

function M.fromLinear(lin)
	local out = ppm.new(lin.w, lin.h)
	for i = 0, lin.w * lin.h - 1 do
		if i % 1024 == 0 then
			budget.check()
		end
		local o, d = i * 4, i * 3
		wu8(out.data, d, color.to8(color.fromLinear(rf(lin.r.data, o))))
		wu8(out.data, d + 1, color.to8(color.fromLinear(rf(lin.g.data, o))))
		wu8(out.data, d + 2, color.to8(color.fromLinear(rf(lin.b.data, o))))
	end
	return out
end

-- Area-average downscale to width newW, keeping the aspect ratio.
function M.scaleDown(img, newW: number)
	local f = img.w / newW
	local newH = math.max(1, math.floor(img.h / f + 0.5))
	local out = ppm.new(newW, newH)
	for oy = 0, newH - 1 do
		budget.check()
		local sy0 = math.floor(oy * f)
		local sy1 = math.max(sy0 + 1, math.min(math.floor((oy + 1) * f), img.h))
		for ox = 0, newW - 1 do
			local sx0 = math.floor(ox * f)
			local sx1 = math.max(sx0 + 1, math.min(math.floor((ox + 1) * f), img.w))
			local r, g, b, n = 0, 0, 0, 0
			for y = sy0, sy1 - 1 do
				for x = sx0, sx1 - 1 do
					local s = (y * img.w + x) * 3
					r += ru8(img.data, s)
					g += ru8(img.data, s + 1)
					b += ru8(img.data, s + 2)
					n += 1
				end
			end
			local d = (oy * newW + ox) * 3
			wu8(out.data, d, byte(r / n))
			wu8(out.data, d + 1, byte(g / n))
			wu8(out.data, d + 2, byte(b / n))
		end
	end
	return out
end

local function cropRgb(img, x0, x1, y0, y1)
	local w, h = x1 - x0, y1 - y0
	local out = ppm.new(w, h)
	for y = 0, h - 1 do
		buffer.copy(out.data, y * w * 3, img.data, ((y + y0) * img.w + x0) * 3, w * 3)
	end
	return out
end

-- The whole bar as two exact halves, each scaled to targetW.
function M.halves(img, targetW: number)
	local mid = img.w // 2
	return M.scaleDown(cropRgb(img, 0, mid, 0, img.h), targetW),
		M.scaleDown(cropRgb(img, mid, img.w, 0, img.h), targetW)
end

-- Nearest-neighbour zoom of a region (pixels stay crisp in the inspector).
function M.zoom(img, x0: number, x1: number, y0: number, y1: number, z: number)
	x0, x1 = math.max(x0, 0), math.min(x1, img.w)
	y0, y1 = math.max(y0, 0), math.min(y1, img.h)
	local w, h = (x1 - x0) * z, (y1 - y0) * z
	local out = ppm.new(w, h)
	for y = 0, h - 1 do
		budget.check()
		local sy = y0 + y // z
		for x = 0, w - 1 do
			buffer.copy(out.data, (y * w + x) * 3, img.data, (sy * img.w + x0 + x // z) * 3, 3)
		end
	end
	return out
end

-- 1 px outline around columns [x0, x1) over the full height, drawn in place.
function M.frame(img, x0: number, x1: number, rgb)
	x0, x1 = math.max(x0, 0), math.min(x1, img.w)
	for x = x0, x1 - 1 do
		ppm.set(img, x, 0, rgb[1], rgb[2], rgb[3])
		ppm.set(img, x, img.h - 1, rgb[1], rgb[2], rgb[3])
	end
	for y = 0, img.h - 1 do
		ppm.set(img, x0, y, rgb[1], rgb[2], rgb[3])
		ppm.set(img, x1 - 1, y, rgb[1], rgb[2], rgb[3])
	end
end

-- Horizontal legend strip: neutral grey fading into the glow ramp.
function M.legend(ramp, w: number, h: number)
	local out = ppm.new(w, h)
	for x = 0, w - 1 do
		local t = x / math.max(w - 1, 1)
		local a = smoothstep(0.16, 0.55, t)
		local c = ramp[math.floor(t * 255) + 1]
		local g = 0.43 * 255
		for y = 0, h - 1 do
			ppm.set(out, x, y, byte(g * (1 - a) + c[1] * a), byte(g * (1 - a) + c[2] * a), byte(g * (1 - a) + c[3] * a))
		end
	end
	return out
end

return M
