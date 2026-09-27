--!nonstrict
-- Hot inner loops on raw f32 buffers, used by image.luau and risk.luau.
--
-- Noctalia runs modules loaded with require() without Luau's fast builtin
-- calls, so buffer reads there cost ~4x more than in a plugin's entry
-- script. engine.luau therefore carries a verbatim copy of the block between
-- the KERNELS markers and installs it (image.install / risk.install). Tests
-- and every other caller use this module. tools/check-kernels.py fails the
-- test run if the two copies ever differ.
--
-- Loops handle several pixels per iteration because Noctalia also charges
-- ~76 ns per loop iteration for its CPU-budget interrupt.

local budget = require("./budget.luau")

-- BEGIN KERNELS
local K = {}
do
	local rf, wf = buffer.readf32, buffer.writef32
	local rd, wd = buffer.readf64, buffer.writef64

	-- d += sd * k over n bytes
	function K.add(d: buffer, sd: buffer, n: number, k: number)
		local o = 0
		while o + 28 < n do
			if o % 65536 == 0 then
				budget.check()
			end
			wf(d, o, rf(d, o) + rf(sd, o) * k)
			wf(d, o + 4, rf(d, o + 4) + rf(sd, o + 4) * k)
			wf(d, o + 8, rf(d, o + 8) + rf(sd, o + 8) * k)
			wf(d, o + 12, rf(d, o + 12) + rf(sd, o + 12) * k)
			wf(d, o + 16, rf(d, o + 16) + rf(sd, o + 16) * k)
			wf(d, o + 20, rf(d, o + 20) + rf(sd, o + 20) * k)
			wf(d, o + 24, rf(d, o + 24) + rf(sd, o + 24) * k)
			wf(d, o + 28, rf(d, o + 28) + rf(sd, o + 28) * k)
			o += 32
		end
		while o < n do
			wf(d, o, rf(d, o) + rf(sd, o) * k)
			o += 4
		end
	end

	-- acc[x] += src[row][x] * sign
	local function accAdd(acc, src, row: number, w: number, sign: number)
		local x = 0
		while x + 7 < w do
			local a, o = x * 8, row + x * 4
			wd(acc, a, rd(acc, a) + rf(src, o) * sign)
			wd(acc, a + 8, rd(acc, a + 8) + rf(src, o + 4) * sign)
			wd(acc, a + 16, rd(acc, a + 16) + rf(src, o + 8) * sign)
			wd(acc, a + 24, rd(acc, a + 24) + rf(src, o + 12) * sign)
			wd(acc, a + 32, rd(acc, a + 32) + rf(src, o + 16) * sign)
			wd(acc, a + 40, rd(acc, a + 40) + rf(src, o + 20) * sign)
			wd(acc, a + 48, rd(acc, a + 48) + rf(src, o + 24) * sign)
			wd(acc, a + 56, rd(acc, a + 56) + rf(src, o + 28) * sign)
			x += 8
		end
		while x < w do
			wd(acc, x * 8, rd(acc, x * 8) + rf(src, row + x * 4) * sign)
			x += 1
		end
	end

	-- acc[x] += src[inRow][x] - src[outRow][x]
	local function accSlide(acc, src, inRow: number, outRow: number, w: number)
		local x = 0
		while x + 7 < w do
			local a, i, o = x * 8, inRow + x * 4, outRow + x * 4
			wd(acc, a, rd(acc, a) + rf(src, i) - rf(src, o))
			wd(acc, a + 8, rd(acc, a + 8) + rf(src, i + 4) - rf(src, o + 4))
			wd(acc, a + 16, rd(acc, a + 16) + rf(src, i + 8) - rf(src, o + 8))
			wd(acc, a + 24, rd(acc, a + 24) + rf(src, i + 12) - rf(src, o + 12))
			wd(acc, a + 32, rd(acc, a + 32) + rf(src, i + 16) - rf(src, o + 16))
			wd(acc, a + 40, rd(acc, a + 40) + rf(src, i + 20) - rf(src, o + 20))
			wd(acc, a + 48, rd(acc, a + 48) + rf(src, i + 24) - rf(src, o + 24))
			wd(acc, a + 56, rd(acc, a + 56) + rf(src, i + 28) - rf(src, o + 28))
			x += 8
		end
		while x < w do
			wd(acc, x * 8, rd(acc, x * 8) + rf(src, inRow + x * 4) - rf(src, outRow + x * 4))
			x += 1
		end
	end

	-- dst[row][x] = acc[x] * inv
	local function accWrite(acc, dst, row: number, w: number, inv: number)
		local x = 0
		while x + 7 < w do
			local a, o = x * 8, row + x * 4
			wf(dst, o, rd(acc, a) * inv)
			wf(dst, o + 4, rd(acc, a + 8) * inv)
			wf(dst, o + 8, rd(acc, a + 16) * inv)
			wf(dst, o + 12, rd(acc, a + 24) * inv)
			wf(dst, o + 16, rd(acc, a + 32) * inv)
			wf(dst, o + 20, rd(acc, a + 40) * inv)
			wf(dst, o + 24, rd(acc, a + 48) * inv)
			wf(dst, o + 28, rd(acc, a + 56) * inv)
			x += 8
		end
		while x < w do
			wf(dst, row + x * 4, rd(acc, x * 8) * inv)
			x += 1
		end
	end

	-- Centred box of radius r with replicated edges.
	function K.hbox(s: buffer, d: buffer, w: number, h: number, r: number)
		local inv = 1 / (2 * r + 1)
		local ahead, back = (r + 1) * 4, r * 4
		local m1 = w - r - 2 -- last column whose window needs no clamping
		for y = 0, h - 1 do
			budget.check()
			local row = y * w * 4
			local acc = 0
			for k = -r, r do
				local x = if k < 0 then 0 elseif k >= w then w - 1 else k
				acc += rf(s, row + x * 4)
			end
			local x = 0
			while x < w and x <= r do
				wf(d, row + x * 4, acc * inv)
				local xo = x - r
				if xo < 0 then
					xo = 0
				end
				local xi = x + r + 1
				if xi >= w then
					xi = w - 1
				end
				acc += rf(s, row + xi * 4) - rf(s, row + xo * 4)
				x += 1
			end
			local o = row + x * 4
			while x + 7 <= m1 do
				wf(d, o, acc * inv)
				acc += rf(s, o + ahead) - rf(s, o - back)
				wf(d, o + 4, acc * inv)
				acc += rf(s, o + 4 + ahead) - rf(s, o + 4 - back)
				wf(d, o + 8, acc * inv)
				acc += rf(s, o + 8 + ahead) - rf(s, o + 8 - back)
				wf(d, o + 12, acc * inv)
				acc += rf(s, o + 12 + ahead) - rf(s, o + 12 - back)
				wf(d, o + 16, acc * inv)
				acc += rf(s, o + 16 + ahead) - rf(s, o + 16 - back)
				wf(d, o + 20, acc * inv)
				acc += rf(s, o + 20 + ahead) - rf(s, o + 20 - back)
				wf(d, o + 24, acc * inv)
				acc += rf(s, o + 24 + ahead) - rf(s, o + 24 - back)
				wf(d, o + 28, acc * inv)
				acc += rf(s, o + 28 + ahead) - rf(s, o + 28 - back)
				o += 32
				x += 8
			end
			while x < w do
				wf(d, row + x * 4, acc * inv)
				local xo = x - r
				if xo < 0 then
					xo = 0
				end
				local xi = x + r + 1
				if xi >= w then
					xi = w - 1
				end
				acc += rf(s, row + xi * 4) - rf(s, row + xo * 4)
				x += 1
			end
		end
	end

	-- Vertical box, computed row by row with one accumulator per column.
	function K.vbox(s: buffer, d: buffer, w: number, h: number, r: number)
		local inv = 1 / (2 * r + 1)
		local stride = w * 4
		local acc = buffer.create(w * 8)
		for k = -r, r do
			local y = if k < 0 then 0 elseif k >= h then h - 1 else k
			accAdd(acc, s, y * stride, w, 1)
		end
		for y = 0, h - 1 do
			budget.check()
			accWrite(acc, d, y * stride, w, inv)
			local yo = y - r
			if yo < 0 then
				yo = 0
			end
			local yi = y + r + 1
			if yi >= h then
				yi = h - 1
			end
			if yi ~= yo then
				accSlide(acc, s, yi * stride, yo * stride, w)
			end
		end
	end

	-- Mean of src over offsets 0..range in direction dir: dir = +1 means content
	-- moved right, so out(x) averages src(x - o). Zero outside the image.
	-- (range >= 1; the caller handles range 0 as a copy)
	function K.dirBoxH(s: buffer, d: buffer, w: number, h: number, range: number, dir: number)
		local inv = 1 / (range + 1)
		local span = (range + 1) * 4
		for y = 0, h - 1 do
			budget.check()
			local row = y * w * 4
			local acc = 0
			if dir >= 0 then
				local x = 0
				while x < w and x <= range do
					acc += rf(s, row + x * 4)
					wf(d, row + x * 4, acc * inv)
					x += 1
				end
				local o = row + x * 4
				while x + 7 < w do
					acc += rf(s, o) - rf(s, o - span)
					wf(d, o, acc * inv)
					acc += rf(s, o + 4) - rf(s, o + 4 - span)
					wf(d, o + 4, acc * inv)
					acc += rf(s, o + 8) - rf(s, o + 8 - span)
					wf(d, o + 8, acc * inv)
					acc += rf(s, o + 12) - rf(s, o + 12 - span)
					wf(d, o + 12, acc * inv)
					acc += rf(s, o + 16) - rf(s, o + 16 - span)
					wf(d, o + 16, acc * inv)
					acc += rf(s, o + 20) - rf(s, o + 20 - span)
					wf(d, o + 20, acc * inv)
					acc += rf(s, o + 24) - rf(s, o + 24 - span)
					wf(d, o + 24, acc * inv)
					acc += rf(s, o + 28) - rf(s, o + 28 - span)
					wf(d, o + 28, acc * inv)
					o += 32
					x += 8
				end
				while x < w do
					acc += rf(s, row + x * 4) - rf(s, row + (x - range - 1) * 4)
					wf(d, row + x * 4, acc * inv)
					x += 1
				end
			else
				local x = w - 1
				while x >= 0 and x + range + 1 >= w do
					acc += rf(s, row + x * 4)
					wf(d, row + x * 4, acc * inv)
					x -= 1
				end
				local o = row + x * 4
				while x - 7 >= 0 do
					acc += rf(s, o) - rf(s, o + span)
					wf(d, o, acc * inv)
					acc += rf(s, o - 4) - rf(s, o - 4 + span)
					wf(d, o - 4, acc * inv)
					acc += rf(s, o - 8) - rf(s, o - 8 + span)
					wf(d, o - 8, acc * inv)
					acc += rf(s, o - 12) - rf(s, o - 12 + span)
					wf(d, o - 12, acc * inv)
					acc += rf(s, o - 16) - rf(s, o - 16 + span)
					wf(d, o - 16, acc * inv)
					acc += rf(s, o - 20) - rf(s, o - 20 + span)
					wf(d, o - 20, acc * inv)
					acc += rf(s, o - 24) - rf(s, o - 24 + span)
					wf(d, o - 24, acc * inv)
					acc += rf(s, o - 28) - rf(s, o - 28 + span)
					wf(d, o - 28, acc * inv)
					o -= 32
					x -= 8
				end
				while x >= 0 do
					acc += rf(s, row + x * 4) - rf(s, row + (x + range + 1) * 4)
					wf(d, row + x * 4, acc * inv)
					x -= 1
				end
			end
		end
	end

	-- Vertical counterpart of dirBoxH (dir = +1: content moved down), row by row
	-- with one accumulator per column.
	function K.dirBoxV(s: buffer, d: buffer, w: number, h: number, range: number, dir: number)
		local inv = 1 / (range + 1)
		local stride = w * 4
		local acc = buffer.create(w * 8)
		if dir >= 0 then
			for y = 0, h - 1 do
				budget.check()
				local yo = y - range - 1
				if yo >= 0 then
					accSlide(acc, s, y * stride, yo * stride, w)
				else
					accAdd(acc, s, y * stride, w, 1)
				end
				accWrite(acc, d, y * stride, w, inv)
			end
		else
			for y = h - 1, 0, -1 do
				budget.check()
				local yo = y + range + 1
				if yo < h then
					accSlide(acc, s, y * stride, yo * stride, w)
				else
					accAdd(acc, s, y * stride, w, 1)
				end
				accWrite(acc, d, y * stride, w, inv)
			end
		end
	end

	-- R = |E - a| + cw * |E - b| over n bytes (a, b: the two blurs of E)
	function K.riskCombine(e: buffer, a: buffer, b: buffer, r: buffer, n: number, cw: number)
		local o = 0
		while o + 12 < n do
			if o % 65536 == 0 then
				budget.check()
			end
			local v0, v1, v2, v3 = rf(e, o), rf(e, o + 4), rf(e, o + 8), rf(e, o + 12)
			wf(r, o, math.abs(v0 - rf(a, o)) + cw * math.abs(v0 - rf(b, o)))
			wf(r, o + 4, math.abs(v1 - rf(a, o + 4)) + cw * math.abs(v1 - rf(b, o + 4)))
			wf(r, o + 8, math.abs(v2 - rf(a, o + 8)) + cw * math.abs(v2 - rf(b, o + 8)))
			wf(r, o + 12, math.abs(v3 - rf(a, o + 12)) + cw * math.abs(v3 - rf(b, o + 12)))
			o += 16
		end
		while o < n do
			local v = rf(e, o)
			wf(r, o, math.abs(v - rf(a, o)) + cw * math.abs(v - rf(b, o)))
			o += 4
		end
	end

	-- r = |e - a| + cw * |e - b| with e = ew + ec, a = aw + ac, b = bw + bc:
	-- risk.map from its parts (the static window and the moved content)
	function K.riskCombineParts(ew: buffer, ec: buffer, aw: buffer, ac: buffer, bw: buffer, bc: buffer, r: buffer, n: number, cw: number)
		local o = 0
		while o + 4 < n do
			if o % 65536 == 0 then
				budget.check()
			end
			local e0, e1 = rf(ew, o) + rf(ec, o), rf(ew, o + 4) + rf(ec, o + 4)
			wf(r, o, math.abs(e0 - (rf(aw, o) + rf(ac, o))) + cw * math.abs(e0 - (rf(bw, o) + rf(bc, o))))
			wf(r, o + 4, math.abs(e1 - (rf(aw, o + 4) + rf(ac, o + 4))) + cw * math.abs(e1 - (rf(bw, o + 4) + rf(bc, o + 4))))
			o += 8
		end
		while o < n do
			local e = rf(ew, o) + rf(ec, o)
			wf(r, o, math.abs(e - (rf(aw, o) + rf(ac, o))) + cw * math.abs(e - (rf(bw, o) + rf(bc, o))))
			o += 4
		end
	end

	-- d[i] += s[i] for i = 1..n (histogram merge; n is a multiple of 8)
	function K.mergeBins(d, s, n: number)
		for i = 1, n, 8 do
			d[i] += s[i]
			d[i + 1] += s[i + 1]
			d[i + 2] += s[i + 2]
			d[i + 3] += s[i + 3]
			d[i + 4] += s[i + 4]
			d[i + 5] += s[i + 5]
			d[i + 6] += s[i + 6]
			d[i + 7] += s[i + 7]
		end
	end

	-- bins[floor(v * scale)] += 1 for count floats starting at byte offset o
	function K.histogram(bins, data: buffer, o: number, count: number, scale: number, top: number)
		local stop = o + count * 4
		while o + 12 < stop do
			local i0 = math.min(math.max(math.floor(rf(data, o) * scale), 0), top)
			local i1 = math.min(math.max(math.floor(rf(data, o + 4) * scale), 0), top)
			local i2 = math.min(math.max(math.floor(rf(data, o + 8) * scale), 0), top)
			local i3 = math.min(math.max(math.floor(rf(data, o + 12) * scale), 0), top)
			bins[i0 + 1] += 1
			bins[i1 + 1] += 1
			bins[i2 + 1] += 1
			bins[i3 + 1] += 1
			o += 16
		end
		while o < stop do
			local i = math.min(math.max(math.floor(rf(data, o) * scale), 0), top)
			bins[i + 1] += 1
			o += 4
		end
	end

	-- smallest and largest of count f32 values from byte offset o
	function K.minMax(data: buffer, o: number, count: number): (number, number)
		local lo, hi = math.huge, -math.huge
		local stop, k = o + count * 4, 0
		while o + 12 < stop do
			k += 1
			if k % 4096 == 0 then
				budget.check()
			end
			local a, b, c, d = rf(data, o), rf(data, o + 4), rf(data, o + 8), rf(data, o + 12)
			lo = math.min(lo, a, b, c, d)
			hi = math.max(hi, a, b, c, d)
			o += 16
		end
		while o < stop do
			local a = rf(data, o)
			lo, hi = math.min(lo, a), math.max(hi, a)
			o += 4
		end
		return lo, hi
	end

	-- like K.histogram, of (v - lo) * scale
	function K.histogramFrom(bins, data: buffer, o: number, count: number, lo: number, scale: number, top: number)
		local stop, k = o + count * 4, 0
		while o + 12 < stop do
			k += 1
			if k % 4096 == 0 then
				budget.check()
			end
			local i0 = math.min(math.max(math.floor((rf(data, o) - lo) * scale), 0), top)
			local i1 = math.min(math.max(math.floor((rf(data, o + 4) - lo) * scale), 0), top)
			local i2 = math.min(math.max(math.floor((rf(data, o + 8) - lo) * scale), 0), top)
			local i3 = math.min(math.max(math.floor((rf(data, o + 12) - lo) * scale), 0), top)
			bins[i0 + 1] += 1
			bins[i1 + 1] += 1
			bins[i2 + 1] += 1
			bins[i3 + 1] += 1
			o += 16
		end
		while o < stop do
			local i = math.min(math.max(math.floor((rf(data, o) - lo) * scale), 0), top)
			bins[i + 1] += 1
			o += 4
		end
	end

	-- f32 luma of n RGB8 pixels through a table of f32-rounded linear values,
	-- exactly as image.luma computes it from wear.linearFromRgb8's planes
	function K.lumaRgb8(src: buffer, n: number, lut, dst: buffer)
		local ru = buffer.readu8
		local i, s, d = 0, 0, 0
		while i + 1 < n do
			if i % 4096 == 0 then
				budget.check()
			end
			wf(dst, d, 0.2126 * lut[ru(src, s) + 1] + 0.7152 * lut[ru(src, s + 1) + 1] + 0.0722 * lut[ru(src, s + 2) + 1])
			wf(dst, d + 4, 0.2126 * lut[ru(src, s + 3) + 1] + 0.7152 * lut[ru(src, s + 4) + 1] + 0.0722 * lut[ru(src, s + 5) + 1])
			i += 2
			s += 6
			d += 8
		end
		if i < n then
			wf(dst, d, 0.2126 * lut[ru(src, s) + 1] + 0.7152 * lut[ru(src, s + 1) + 1] + 0.0722 * lut[ru(src, s + 2) + 1])
		end
	end

	-- wear rate per pixel, exactly as wear.pixel computes it: k1 r^n + k2 g^n +
	-- k3 b^n on channels clamped to 0..1, or with a white subpixel (WOLED)
	-- taking min(r, g, b) first
	function K.wearMap(r: buffer, g: buffer, b: buffer, count: number, k1: number, k2: number, k3: number, white: number?, n: number, out: buffer)
		for o = 0, (count - 1) * 4, 4 do
			if o % 8192 == 0 then
				budget.check()
			end
			local vr, vg, vb = rf(r, o), rf(g, o), rf(b, o)
			vr = if vr < 0 then 0 elseif vr > 1 then 1 else vr
			vg = if vg < 0 then 0 elseif vg > 1 then 1 else vg
			vb = if vb < 0 then 0 elseif vb > 1 then 1 else vb
			if white then
				local m = math.min(vr, vg, vb)
				wf(out, o, white * m ^ n + k1 * (vr - m) ^ n + k2 * (vg - m) ^ n + k3 * (vb - m) ^ n)
			else
				wf(out, o, k1 * vr ^ n + k2 * vg ^ n + k3 * vb ^ n)
			end
		end
	end

	-- Lab images -----------------------------------------------------------
	local ru8, wu8 = buffer.readu8, buffer.writeu8
	local floor, clamp, min = math.floor, math.clamp, math.min

	local function to8(v: number): number
		v = floor(v + 0.5)
		return if v < 0 then 0 elseif v > 255 then 255 else v
	end

	-- 24-bit BMP rows (bottom-up, BGR, each padded to rowSize) from RGB8
	function K.bmpRows(src: buffer, w: number, h: number, dst: buffer, base: number, rowSize: number)
		local n = w * 3
		for y = 0, h - 1 do
			if y % 16 == 0 then
				budget.check()
			end
			local d = base + (h - 1 - y) * rowSize
			buffer.copy(dst, d, src, y * n, n)
			local o, last = d, d + n
			while o + 12 <= last do
				local r0, r1, r2, r3 = ru8(dst, o), ru8(dst, o + 3), ru8(dst, o + 6), ru8(dst, o + 9)
				wu8(dst, o, ru8(dst, o + 2))
				wu8(dst, o + 2, r0)
				wu8(dst, o + 3, ru8(dst, o + 5))
				wu8(dst, o + 5, r1)
				wu8(dst, o + 6, ru8(dst, o + 8))
				wu8(dst, o + 8, r2)
				wu8(dst, o + 9, ru8(dst, o + 11))
				wu8(dst, o + 11, r3)
				o += 12
			end
			while o < last do
				local r = ru8(dst, o)
				wu8(dst, o, ru8(dst, o + 2))
				wu8(dst, o + 2, r)
				o += 3
			end
		end
	end

	-- cols RGB8 pixels from src at s, each repeated z times, written from d
	function K.zoomRow(src: buffer, s: number, cols: number, z: number, dst: buffer, d: number)
		for _ = 1, cols do
			local r, g, b = ru8(src, s), ru8(src, s + 1), ru8(src, s + 2)
			for _ = 1, z do
				wu8(dst, d, r)
				wu8(dst, d + 1, g)
				wu8(dst, d + 2, b)
				d += 3
			end
			s += 3
		end
	end

	-- area-average downscale of RGB8 w x h to newW x newH
	function K.scaleDown(src: buffer, w: number, h: number, newW: number, newH: number, dst: buffer)
		local f = w / newW
		for oy = 0, newH - 1 do
			budget.check()
			local sy0 = floor(oy * f)
			local sy1 = math.max(sy0 + 1, min(floor((oy + 1) * f), h))
			for ox = 0, newW - 1 do
				local sx0 = floor(ox * f)
				local sx1 = math.max(sx0 + 1, min(floor((ox + 1) * f), w))
				local r, g, b = 0, 0, 0
				for y = sy0, sy1 - 1 do
					local s = (y * w + sx0) * 3
					for _ = sx0, sx1 - 1 do
						r += ru8(src, s)
						g += ru8(src, s + 1)
						b += ru8(src, s + 2)
						s += 3
					end
				end
				local n = (sy1 - sy0) * (sx1 - sx0)
				local d = (oy * newW + ox) * 3
				wu8(dst, d, to8(r / n))
				wu8(dst, d + 1, to8(g / n))
				wu8(dst, d + 2, to8(b / n))
			end
		end
	end

	-- f32: dst = what the bar leaves on a flat grey screen, from exposure E
	function K.ghostGray(E: buffer, n: number, inv: number, dst: buffer)
		for o = 0, (n - 1) * 4, 4 do
			if o % 8192 == 0 then
				budget.check()
			end
			local e = clamp(rf(E, o) * inv, 0, 1)
			wf(dst, o, (0.60 - 0.40 * e ^ 0.8) * 0.533) -- neutral 0.32: the glow carries, not the grey
		end
	end

	-- f32: dst = clamp(src * inv, 0, 1)
	function K.clampScale(src: buffer, n: number, inv: number, dst: buffer)
		for o = 0, (n - 1) * 4, 4 do
			if o % 8192 == 0 then
				budget.check()
			end
			wf(dst, o, clamp(rf(src, o) * inv, 0, 1))
		end
	end

	-- RGB8: grey base (f32 0..1) under the glow ramp, by risk t plus bloom
	function K.glowPixels(base: buffer, t: buffer, bloom: buffer, n: number, ramp, dst: buffer)
		for i = 0, n - 1 do
			if i % 2048 == 0 then
				budget.check()
			end
			local o = i * 4
			local tt = min(rf(t, o) + 0.35 * rf(bloom, o), 1)
			local u = clamp((tt - 0.16) / (0.55 - 0.16), 0, 1)
			local a = u * u * (3 - 2 * u)
			local c = ramp[floor(tt * 255) + 1]
			local g = rf(base, o) * 255 * (1 - a)
			local d = i * 3
			-- to8() written out: a call per pixel costs a host interrupt check
			local r, gg, b = floor(g + c[1] * a + 0.5), floor(g + c[2] * a + 0.5), floor(g + c[3] * a + 0.5)
			wu8(dst, d, if r < 0 then 0 elseif r > 255 then 255 else r)
			wu8(dst, d + 1, if gg < 0 then 0 elseif gg > 255 then 255 else gg)
			wu8(dst, d + 2, if b < 0 then 0 elseif b > 255 then 255 else b)
		end
	end

	-- RGB8: the bar dimmed to 20 % of its sRGB luma under the risk ramp
	function K.riskPixels(lum: buffer, R: buffer, n: number, inv: number, ramp, dst: buffer)
		for i = 0, n - 1 do
			if i % 2048 == 0 then
				budget.check()
			end
			local o = i * 4
			local tr = clamp(rf(R, o) * inv, 0, 1) ^ 0.7
			local a = clamp(1.4 * tr, 0, 1)
			local l = rf(lum, o) -- srgb() and to8() written out, as in K.glowPixels
			local sl = if l <= 0 then 0 elseif l >= 1 then 1 elseif l <= 0.0031308 then 12.92 * l else 1.055 * l ^ (1 / 2.4) - 0.055
			local g = sl * 0.2 * 255 * (1 - a)
			local c = ramp[floor(tr * 255) + 1]
			local d = i * 3
			local r, gg, b = floor(g + c[1] * a + 0.5), floor(g + c[2] * a + 0.5), floor(g + c[3] * a + 0.5)
			wu8(dst, d, if r < 0 then 0 elseif r > 255 then 255 else r)
			wu8(dst, d + 1, if gg < 0 then 0 elseif gg > 255 then 255 else gg)
			wu8(dst, d + 2, if b < 0 then 0 elseif b > 255 then 255 else b)
		end
	end

	-- RGB8 from linear f32 channel planes
	function K.fromLinear3(r: buffer, g: buffer, b: buffer, n: number, dst: buffer)
		for i = 0, n - 1 do
			if i % 2048 == 0 then
				budget.check()
			end
			local o, d = i * 4, i * 3
			local lr, lg, lb = rf(r, o), rf(g, o), rf(b, o) -- srgb() and to8() written out
			local vr = floor((if lr <= 0 then 0 elseif lr >= 1 then 1 elseif lr <= 0.0031308 then 12.92 * lr else 1.055 * lr ^ (1 / 2.4) - 0.055) * 255 + 0.5)
			local vg = floor((if lg <= 0 then 0 elseif lg >= 1 then 1 elseif lg <= 0.0031308 then 12.92 * lg else 1.055 * lg ^ (1 / 2.4) - 0.055) * 255 + 0.5)
			local vb = floor((if lb <= 0 then 0 elseif lb >= 1 then 1 elseif lb <= 0.0031308 then 12.92 * lb else 1.055 * lb ^ (1 / 2.4) - 0.055) * 255 + 0.5)
			wu8(dst, d, if vr < 0 then 0 elseif vr > 255 then 255 else vr)
			wu8(dst, d + 1, if vg < 0 then 0 elseif vg > 255 then 255 else vg)
			wu8(dst, d + 2, if vb < 0 then 0 elseif vb > 255 then 255 else vb)
		end
	end
end
-- END KERNELS

return K
