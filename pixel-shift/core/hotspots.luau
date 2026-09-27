--!nonstrict
-- Groups risky pixels into regions and names the likely cause, so the lab
-- can say what shifting cannot fix and what to change instead.

local image = require("./image.luau")
local util = require("./util.luau")
local simulate = require("./simulate.luau")

local budget = require("./budget.luau")

local M = {}

M.FLOOR = 0.15 -- fraction of the reference risk a spot needs to be listed
M.GAP = 6 -- logical px between hot columns that still belong to one spot
M.MAX = 4
M.HIGH, M.MEDIUM = 50, 25 -- peak (% of the reference) of "high" and "medium" spots
M.VAR_DYNAMIC = 0.002 -- luma variance across samples

local function regionsIn(R, thr, y0, y1, outside, out, gap)
	local cur
	for x = 0, R.w - 1 do
		if x % 16 == 0 then
			budget.check()
		end
		local hot = false
		for y = y0, y1 - 1 do
			if image.get(R, x, y) > thr then
				hot = true
				break
			end
		end
		if hot then
			if cur and x - cur.x1 <= gap then
				cur.x1 = x + 1
			else
				cur = { x0 = x, x1 = x + 1, y0 = y0, y1 = y1, outside = outside }
				table.insert(out, cur)
			end
		end
	end
end

local function refine(reg, R, thr)
	local peak, ry0, ry1 = 0, math.huge, -1
	for y = reg.y0, reg.y1 - 1 do
		budget.check()
		for x = reg.x0, reg.x1 - 1 do
			local v = image.get(R, x, y)
			if v > peak then
				peak = v
			end
			if v > thr then
				ry0 = math.min(ry0, y)
				ry1 = math.max(ry1, y)
			end
		end
	end
	reg.peakRaw, reg.y0, reg.y1 = peak, ry0, ry1 + 1
end

local function groupAt(layout, x)
	for _, g in ipairs(layout.groups) do
		if x >= g.own0 and x < g.own1 then
			return g
		end
	end
	return nil
end

-- Longest run along a row (region rows, region columns +-40 px) of dw above thr.
local function longestRun(dw, reg, thr)
	local best = 0
	local a, b = math.max(reg.x0 - 40, 0), math.min(reg.x1 + 40, dw.w)
	for y = reg.y0, reg.y1 - 1 do
		budget.check()
		local run = 0
		for x = a, b - 1 do
			if image.get(dw, x, y) > thr then
				run += 1
				best = math.max(best, run)
			else
				run = 0
			end
		end
	end
	return best
end

local function gradients(R, reg)
	local gx, gy = 0, 0
	for y = math.max(reg.y0 - 1, 0), math.min(reg.y1, R.h - 1) - 1 do
		budget.check()
		for x = math.max(reg.x0 - 1, 0), math.min(reg.x1, R.w - 1) - 1 do
			local v = image.get(R, x, y)
			gx += math.abs(image.get(R, x + 1, y) - v)
			gy += math.abs(image.get(R, x, y + 1) - v)
		end
	end
	return gx, gy
end

local function meanOver(img, reg, pred)
	local sum, n = 0, 0
	for y = reg.y0, reg.y1 - 1 do
		budget.check()
		for x = reg.x0, reg.x1 - 1 do
			local v = image.get(img, x, y)
			if pred == nil or pred(v) then
				sum += v
				n += 1
			end
		end
	end
	return if n > 0 then sum / n else 0
end

local function cause(reg, opts)
	if reg.outside then
		return "outside"
	end
	if opts.variance and meanOver(opts.variance, reg) > M.VAR_DYNAMIC then
		return "dynamic"
	end
	for _, d in ipairs(opts.layout.dynamic or {}) do
		if reg.x0 < d[2] and reg.x1 > d[1] then
			return "dynamic"
		end
	end
	local range = 0
	local g = groupAt(opts.layout, (reg.x0 + reg.x1) // 2)
	if g then
		for _, k in ipairs(simulate.kernels(g, opts.strategy.ranges)) do
			range += k[1]
		end
	end
	if longestRun(opts.dw, reg, 0.1 * opts.wWhite) > 2 * range + 6 then
		return "wide"
	end
	local gx, gy = gradients(opts.R, reg)
	if gy > 2 * gx then
		return "horizontal"
	end
	local lit = meanOver(opts.dw, reg, function(v)
		return v > 0.1 * opts.wWhite
	end)
	if lit > 0.6 * opts.wWhite then
		return "bright"
	end
	return "static"
end

local function level(peak: number): string
	return if peak >= M.HIGH then "high" elseif peak >= M.MEDIUM then "medium" else "low"
end

-- Returns up to MAX spots, strongest first ("outside the bar" last), and the
-- strongest risk anywhere in the scored rows (% of the reference), so the lab
-- can say how clean a bar without listed spots is.
function M.find(opts)
	local R, layout = opts.R, opts.layout
	local thr = M.FLOOR * opts.rref
	local gap = math.ceil(M.GAP * (layout.scale or 1))
	local sy0, sy1 = layout.scoreRows[1], layout.scoreRows[2]
	local worst = 0
	for y = sy0, sy1 - 1 do
		budget.check()
		for x = 0, R.w - 1 do
			local v = image.get(R, x, y)
			if v > worst then
				worst = v
			end
		end
	end
	local regions = {}
	regionsIn(R, thr, sy0, sy1, false, regions, gap)
	if sy0 > 0 then
		regionsIn(R, thr, 0, sy0, true, regions, gap)
	end
	if sy1 < R.h then
		regionsIn(R, thr, sy1, R.h, true, regions, gap)
	end
	for _, reg in ipairs(regions) do
		refine(reg, R, thr)
		reg.peak = 100 * reg.peakRaw / opts.rref
		reg.cause = cause(reg, opts)
		reg.side = util.side((reg.x0 + reg.x1) / 2, R.w)
	end
	-- what the user can act on first; "outside the bar" goes last
	table.sort(regions, function(a, b)
		local ao, bo = a.cause == "outside", b.cause == "outside"
		if ao ~= bo then
			return bo
		end
		return a.peak > b.peak
	end)
	local out = {}
	for i = 1, math.min(M.MAX, #regions) do
		local r = regions[i]
		out[i] = { x0 = r.x0, x1 = r.x1, y0 = r.y0, y1 = r.y1, peak = r.peak, level = level(r.peak), cause = r.cause, side = r.side }
	end
	return out, 100 * worst / opts.rref
end

return M
