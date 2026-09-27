--!nonstrict
-- Running exposure of the bar across the day: summed wear per profile (so
-- the panel profile can change later) plus luma sums for a variance map that
-- reveals dynamic content. Samples are stored un-shifted (home positions).

local image = require("./image.luau")
local wear = require("./wear.luau")

local budget = require("./budget.luau")

local M = {}
M.MAGIC = "PSX1"
local HEADER = "<c4I4I4I4dd"
local PLANES = { "generic", "woled", "qdoled", "lum", "lum2" }

function M.new(w: number, h: number)
	local acc = { w = w, h = h, n = 0, first = 0, last = 0, wear = {}, lum = image.new(w, h), lum2 = image.new(w, h) }
	for _, name in ipairs(wear.ORDER) do
		acc.wear[name] = image.new(w, h)
	end
	return acc
end

-- Fraction of pixels with a channel above 12/255.
function M.brightFraction(img): number
	local d = img.data
	local n = img.w * img.h
	local bright = 0
	for i = 0, n - 1 do
		if i % 1024 == 0 then
			budget.check()
		end
		local o = i * 3
		if buffer.readu8(d, o) > 12 or buffer.readu8(d, o + 1) > 12 or buffer.readu8(d, o + 2) > 12 then
			bright += 1
		end
	end
	return if n > 0 then bright / n else 0
end

-- A capture with (almost) nothing lit: the output is off or covered by
-- black. `expected` is the scanned bar's own bright fraction, so a minimal
-- black bar is not taken for a dark screen.
function M.isBlank(img, expected: number?): boolean
	local limit = 0.01
	if expected then
		limit = math.min(limit, expected * 0.5)
	end
	return M.brightFraction(img) < limit
end

-- Structure of the bar rows for the match test: each pixel as one of 64
-- perceptual levels, and each row's dominant level (its background).
local LEVELS = 64
local CONTENT = 8 -- levels a pixel must stand out from its row to count as content
local SAME = 8 -- levels two content pixels may differ and still line up
local ROWS_MIN = 0.6 -- share of rows whose background must agree
local SHARED_MIN = 0.3 -- share of content that must line up (Dice, ±1 px)

local function profile(L, y0: number, y1: number)
	local w, rows = L.w, y1 - y0
	local lv = buffer.create(w * rows)
	local modes = table.create(rows, 0)
	local hist = table.create(LEVELS, 0)
	for r = 0, rows - 1 do
		budget.check()
		for i = 1, LEVELS do
			hist[i] = 0
		end
		local src = (y0 + r) * w * 4
		for x = 0, w - 1 do
			local v = buffer.readf32(L.data, src + x * 4)
			local l = if v <= 0 then 0 else math.min(LEVELS - 1, math.floor(v ^ (1 / 2.4) * LEVELS))
			buffer.writeu8(lv, r * w + x, l)
			hist[l + 1] += 1
		end
		local best, mode = -1, 0
		for i = 1, LEVELS do
			if hist[i] > best then
				best, mode = hist[i], i - 1
			end
		end
		modes[r + 1] = mode
	end
	return { lv = lv, modes = modes, w = w, rows = rows }
end

local profiles = setmetatable({}, { __mode = "k" }) -- baseline image -> profile

local function cachedProfile(L, y0: number, y1: number)
	local hit = profiles[L]
	if hit and hit.y0 == y0 and hit.y1 == y1 then
		return hit.p
	end
	local p = profile(L, y0, y1)
	profiles[L] = { y0 = y0, y1 = y1, p = p }
	return p
end

-- A content pixel of about level `l` at x-1..x+1 in row `off` of profile p?
local function near(p, off: number, x: number, l: number, mode: number): boolean
	for xx = math.max(x - 1, 0), math.min(x + 1, p.w - 1) do
		local q = buffer.readu8(p.lv, off + xx)
		if math.abs(q - mode) >= CONTENT and math.abs(q - l) <= SAME then
			return true
		end
	end
	return false
end

-- Does the capture still show the scanned bar? Compared in perceptual levels
-- over the bar rows: each row's background must agree, and the content that
-- stands out from it must mostly line up with the scan's. A new window title
-- changes part of the content; a lock screen or a fullscreen app changes the
-- background or all of it, however dark it is.
function M.matchesBaseline(capL, baseL, layout): boolean
	local y0, y1 = layout.barRows[1], layout.barRows[2]
	local rows = y1 - y0
	if rows <= 0 then
		return true
	end
	local b = cachedProfile(baseL, y0, y1)
	local f = profile(capL, y0, y1)
	local agree = 0
	for r = 1, rows do
		if math.abs(b.modes[r] - f.modes[r]) <= 1 then
			agree += 1
		end
	end
	if agree < rows * ROWS_MIN then
		return false
	end
	local w = b.w
	local nb, nf, shared = 0, 0, 0
	for r = 0, rows - 1 do
		budget.check()
		local mB, mF = b.modes[r + 1], f.modes[r + 1]
		local off = r * w
		for x = 0, w - 1 do
			local lb = buffer.readu8(b.lv, off + x)
			if math.abs(lb - mB) >= CONTENT then
				nb += 1
				if near(f, off, x, lb, mF) then
					shared += 1
				end
			end
			local lf = buffer.readu8(f.lv, off + x)
			if math.abs(lf - mF) >= CONTENT then
				nf += 1
				if near(b, off, x, lf, mB) then
					shared += 1
				end
			end
		end
	end
	if nb + nf < math.max(16, rows * w * 0.001) then
		return true -- nothing stands out in either: the background decides
	end
	return shared / (nb + nf) >= SHARED_MIN
end

-- Undo the displacement active when the frame was captured: group gi's
-- content sits disp[gi] px right of home, and vRows rows along vDir.
function M.unshift(lin, layout, disp, vRows: number)
	local function fix(img)
		local out = img
		for gi, g in ipairs(layout.groups) do
			local d = disp[gi] or 0
			if d ~= 0 then
				out = image.shiftColumns(out, g.x0, g.x1, d)
			end
		end
		if vRows ~= 0 then
			out = image.shiftRows(out, vRows * layout.vDir)
		end
		return out
	end
	return image.rgbMap(lin, fix)
end

function M.add(acc, lin, t: number)
	for name, sum in pairs(acc.wear) do
		image.add(sum, wear.map(wear.profile(name), lin))
	end
	local L = image.luma(lin)
	image.add(acc.lum, L)
	image.add(acc.lum2, image.square(L))
	acc.n += 1
	if acc.n == 1 then
		acc.first = t
	end
	acc.last = t
end

local function scaled(img, s)
	local out = image.new(img.w, img.h)
	image.add(out, img, s)
	return out
end

function M.meanWear(acc, name: string)
	return scaled(acc.wear[name] or acc.wear.generic, 1 / math.max(acc.n, 1))
end

function M.variance(acc)
	local inv = 1 / math.max(acc.n, 1)
	local mean = scaled(acc.lum, inv)
	local out = scaled(acc.lum2, inv)
	image.add(out, image.square(mean), -1)
	return out
end

-- Simulation layers from the day's exposure: inside group columns the scan's
-- background plus the mean extra wear; elsewhere the mean wear itself.
function M.layers(acc, name: string, scan, layout)
	local mean = M.meanWear(acc, name)
	local wbg = image.copy(mean)
	local dw = image.new(mean.w, mean.h)
	for _, g in ipairs(layout.groups) do
		for y = 0, mean.h - 1 do
			budget.check()
			for x = math.max(g.x0, 0), math.min(g.x1, mean.w) - 1 do
				local b = image.get(scan.wbg, x, y)
				image.set(wbg, x, y, b)
				image.set(dw, x, y, image.get(mean, x, y) - b)
			end
		end
	end
	return { wbg = wbg, dw = dw }
end

local function planes(acc)
	return { acc.wear.generic, acc.wear.woled, acc.wear.qdoled, acc.lum, acc.lum2 }
end

function M.serialize(acc): string
	local parts = { string.pack(HEADER, M.MAGIC, acc.w, acc.h, acc.n, acc.first, acc.last) }
	for _, img in ipairs(planes(acc)) do
		table.insert(parts, buffer.tostring(img.data))
	end
	return table.concat(parts)
end

function M.deserialize(s: string?)
	if type(s) ~= "string" or #s < string.packsize(HEADER) then
		return nil
	end
	local magic, w, h, n, first, last, pos = string.unpack(HEADER, s)
	if magic ~= M.MAGIC or w <= 0 or h <= 0 then
		return nil
	end
	local plane = w * h * 4
	if #s ~= pos - 1 + #PLANES * plane then
		return nil
	end
	local acc = M.new(w, h)
	acc.n, acc.first, acc.last = n, first, last
	local src = buffer.fromstring(s)
	for _, img in ipairs(planes(acc)) do
		buffer.copy(img.data, 0, src, pos - 1, plane)
		pos += plane
	end
	return acc
end

return M
