--!nonstrict
-- Lab images: the ghost preview with theme-coloured glow proportional to
-- risk (one absolute scale for every view), the risk view, and the helpers
-- that size them for the panel.

local image = require("./image.luau")
local ppm = require("./ppm.luau")
local budget = require("./budget.luau")
local K = require("./kernels.luau")

local M = {}

-- The pixel loops live in kernels.luau; the engine swaps in its own fast
-- copy (see there for why).
function M.install(kernels)
	K = kernels
end

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
	K.ghostGray(E.data, E.w * E.h, 1 / math.max(eRef, 1e-9), out.data)
	return out
end

-- Composite the risk glow over a grey base (spec 5.2).
function M.glow(base, R, rTop: number, ramp)
	local w, h = R.w, R.h
	local t = image.new(w, h)
	K.clampScale(R.data, w * h, 1 / math.max(rTop, 1e-9), t.data)
	local bloom = image.gauss3(t, 1)
	local out = ppm.new(w, h)
	K.glowPixels(base.data, t.data, bloom.data, w * h, ramp, out.data)
	return out
end

function M.ghostView(E, R, eRef: number, rTop: number, ramp)
	return M.glow(M.ghostGray(E, eRef), R, rTop, ramp)
end

-- Dimmed bar (20 % of its sRGB luma) with the risk ramp on top.
function M.riskView(lum, R, rTop: number, ramp)
	local out = ppm.new(R.w, R.h)
	K.riskPixels(lum.data, R.data, R.w * R.h, 1 / math.max(rTop, 1e-9), ramp, out.data)
	return out
end

function M.fromLinear(lin)
	local out = ppm.new(lin.w, lin.h)
	K.fromLinear3(lin.r.data, lin.g.data, lin.b.data, lin.w * lin.h, out.data)
	return out
end

-- Area-average downscale to width newW, keeping the aspect ratio.
function M.scaleDown(img, newW: number)
	local newH = math.max(1, math.floor(img.h / (img.w / newW) + 0.5))
	local out = ppm.new(newW, newH)
	K.scaleDown(img.data, img.w, img.h, newW, newH, out.data)
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
-- Each source row is expanded once and copied for the other z - 1 rows.
function M.zoom(img, x0: number, x1: number, y0: number, y1: number, z: number)
	x0, x1 = math.max(x0, 0), math.min(x1, img.w)
	y0, y1 = math.max(y0, 0), math.min(y1, img.h)
	local cols = x1 - x0
	local w, h = cols * z, (y1 - y0) * z
	local out = ppm.new(w, h)
	local src, dst = img.data, out.data
	local rowBytes = w * 3
	for sy = y0, y1 - 1 do
		budget.check()
		local first = (sy - y0) * z * rowBytes
		local s = (sy * img.w + x0) * 3
		if z == 1 then
			buffer.copy(dst, first, src, s, cols * 3)
		else
			K.zoomRow(src, s, cols, z, dst, first)
			for r = 1, z - 1 do
				buffer.copy(dst, first + r * rowBytes, dst, first, rowBytes)
			end
		end
	end
	return out
end

function M.copy(img)
	local out = ppm.new(img.w, img.h)
	buffer.copy(out.data, 0, img.data, 0, img.w * img.h * 3)
	return out
end

-- Outline of the full-width columns [x0, x1) on the two overview halves from
-- M.halves (fullW wide before halving), drawn in place at the halves' own
-- resolution so the 1 px line stays crisp.
function M.frameHalves(left, right, x0: number, x1: number, fullW: number, rgb, thickness: number?)
	local t = thickness or 1
	local mid = fullW // 2
	local function part(img, h0: number, h1: number)
		local a, b = math.max(x0, h0), math.min(x1, h1)
		if a >= b then
			return
		end
		local f = img.w / (h1 - h0)
		local px0 = math.min(math.floor((a - h0) * f), img.w - 1)
		local px1 = math.max(px0 + 1, math.min(img.w, math.ceil((b - h0) * f)))
		for k = 0, t - 1 do
			for x = px0, px1 - 1 do
				ppm.set(img, x, math.min(k, img.h - 1), rgb[1], rgb[2], rgb[3])
				ppm.set(img, x, math.max(img.h - 1 - k, 0), rgb[1], rgb[2], rgb[3])
			end
			for y = 0, img.h - 1 do
				if a == x0 then
					ppm.set(img, math.min(px0 + k, img.w - 1), y, rgb[1], rgb[2], rgb[3])
				end
				if b == x1 then
					ppm.set(img, math.max(px1 - 1 - k, 0), y, rgb[1], rgb[2], rgb[3])
				end
			end
		end
	end
	part(left, 0, mid)
	part(right, mid, fullW)
end

-- A box of `t` px lines around columns [x0, x1) over the full height, drawn
-- in place (the same language as the overview's frame).
function M.outline(img, x0: number, x1: number, t: number, rgb)
	x0, x1 = math.max(x0, 0), math.min(x1, img.w)
	if x1 <= x0 then
		return
	end
	for k = 0, t - 1 do
		for x = x0, x1 - 1 do
			ppm.set(img, x, math.min(k, img.h - 1), rgb[1], rgb[2], rgb[3])
			ppm.set(img, x, math.max(img.h - 1 - k, 0), rgb[1], rgb[2], rgb[3])
		end
		for y = 0, img.h - 1 do
			ppm.set(img, math.min(x0 + k, img.w - 1), y, rgb[1], rgb[2], rgb[3])
			ppm.set(img, math.max(x1 - 1 - k, 0), y, rgb[1], rgb[2], rgb[3])
		end
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
