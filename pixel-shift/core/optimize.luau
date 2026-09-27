--!nonstrict
-- Finds shift ranges that minimise visible burn-in. For every movement
-- budget B (max group displacement, logical px) and vertical range V it runs
-- a cached coordinate descent over the spacer ranges. Work is resumable:
-- step(ms) advances the search a slice at a time.

local simulate = require("./simulate.luau")
local risk = require("./risk.luau")
local budget = require("./budget.luau")

local M = {}

M.LAMBDA_CALM = 3.0
M.LAMBDA_MAX = 0.1
M.LAMBDA_DEFAULT = 0.7

function M.lambdaFromSlider(t: number): number
	return M.LAMBDA_CALM * (M.LAMBDA_MAX / M.LAMBDA_CALM) ^ math.clamp(t, 0, 1)
end

function M.sliderFromLambda(l: number): number
	return math.log(l / M.LAMBDA_CALM) / math.log(M.LAMBDA_MAX / M.LAMBDA_CALM)
end

-- Largest horizontal displacement any group sees (logical px) plus V.
function M.movement(layout, ranges, V: number?): number
	local m = 0
	for _, g in ipairs(layout.groups) do
		local d = 0
		for slot, f in pairs(g.factors) do
			d += (ranges[slot] or 0) * math.abs(f) / layout.scale
		end
		m = math.max(m, d)
	end
	return m + (V or 0)
end

local Opt = {}
Opt.__index = Opt

function M.new(ctx)
	local self = setmetatable({
		ctx = ctx,
		cache = {},
		evals = 0,
		entries = {},
		best = math.huge,
		progress = 0,
		done = false,
		error = nil,
	}, Opt)
	self.slots = {}
	for slot, info in pairs(ctx.layout.slots) do
		if info.moves then
			table.insert(self.slots, slot)
		end
	end
	table.sort(self.slots)
	self.budgets = ctx.budgets
	if not self.budgets then
		self.budgets = {}
		for B = 0, ctx.maxShift, 2 do
			table.insert(self.budgets, B)
		end
	end
	self.vs = { 0 }
	for v = 1, ctx.maxV or 0 do
		table.insert(self.vs, v)
	end
	self.co = coroutine.create(function()
		self:_run()
	end)
	return self
end

function Opt:_groupHist(gi, ranges, V)
	local layout = self.ctx.layout
	local g = layout.groups[gi]
	local key = `{gi}|{simulate.kernelKey(simulate.kernels(g, ranges))}|{simulate.vRows(layout, V)}`
	local h = self.cache[key]
	if not h then
		h = simulate.groupHist(self.ctx.layers, layout, gi, ranges, V, self.ctx.rref, self.active)
		self.cache[key] = h
		self.evals += 1
		coroutine.yield()
	end
	return h
end

function Opt:_score(ranges, V)
	budget.check() -- cached scores come back to back; give the host a turn
	local total = risk.newHist(2 * self.ctx.rref)
	risk.merge(total, self.static)
	for gi = 1, #self.ctx.layout.groups do
		risk.merge(total, self:_groupHist(gi, ranges, V))
	end
	return risk.score(total, self.ctx.rref)
end

-- Largest range for `slot` that keeps every group it moves within budget B.
function Opt:_maxW(slot, B, ranges)
	local layout = self.ctx.layout
	local limit = self.ctx.maxShift
	for _, g in ipairs(layout.groups) do
		local f = g.factors[slot]
		if f and f ~= 0 then
			local other = 0
			for s2, f2 in pairs(g.factors) do
				if s2 ~= slot then
					other += (ranges[s2] or 0) * math.abs(f2) / layout.scale
				end
			end
			limit = math.min(limit, math.floor((B - other) * layout.scale / math.abs(f) + 1e-9))
		end
	end
	return math.max(limit, 0)
end

function Opt:_descend(B, V, start)
	local ranges = table.clone(start)
	local score = self:_score(ranges, V)
	for _ = 1, 2 do
		local improved = false
		for _, slot in ipairs(self.slots) do
			local cur = ranges[slot] or 0
			local bestW, bestS = cur, score
			for W = 0, self:_maxW(slot, B, ranges) do
				if W ~= cur then
					ranges[slot] = W
					local s = self:_score(ranges, V)
					if s < bestS - 1e-9 then
						bestW, bestS = W, s
					end
				end
			end
			ranges[slot] = bestW
			score = bestS
			if bestW ~= cur then
				improved = true
			end
		end
		if not improved then
			break
		end
	end
	return ranges, score
end

function Opt:_run()
	local fmax = 0
	for _, g in ipairs(self.ctx.layout.groups) do
		for _, f in pairs(g.factors) do
			fmax = math.max(fmax, math.abs(f))
		end
	end
	self.active = simulate.activeRanges(self.ctx.layers, self.ctx.layout, math.ceil(self.ctx.maxShift * fmax) + 2)
	self.static = simulate.staticHist(self.ctx.layers, self.ctx.layout, self.ctx.rref, self.active)
	coroutine.yield()
	local total = #self.vs * #self.budgets
	local finished = 0
	for _, V in ipairs(self.vs) do
		local start = {}
		for _, slot in ipairs(self.slots) do
			start[slot] = 0
		end
		for _, B in ipairs(self.budgets) do
			local ranges, score = self:_descend(B, V, start)
			start = ranges
			table.insert(self.entries, {
				B = B,
				V = V,
				ranges = ranges,
				score = score,
				movement = M.movement(self.ctx.layout, ranges, V),
			})
			self.best = math.min(self.best, score)
			finished += 1
			self.progress = finished / total
		end
	end
	self.done = true
end

function Opt:step(budgetMs: number): boolean
	if self.done then
		return true
	end
	local t0 = os.clock()
	repeat
		local ok, err = coroutine.resume(self.co)
		if not ok then
			self.error = tostring(err)
			self.done = true
		end
	until self.done or (os.clock() - t0) * 1000 >= budgetMs
	return self.done
end

-- Per budget: best score without vertical (h) and best with any V >= 1 (v).
function M.curve(entries, budgets)
	local h, v = {}, {}
	for i, B in ipairs(budgets) do
		for _, e in ipairs(entries) do
			if e.B == B then
				if e.V == 0 then
					h[i] = e.score
				elseif v[i] == nil or e.score < v[i] then
					v[i] = e.score
				end
			end
		end
	end
	return { h = h, v = v }
end

function M.pick(entries, lambda: number, allowVertical: boolean)
	local best, bestJ = nil, math.huge
	for _, e in ipairs(entries) do
		if allowVertical or e.V == 0 then
			local J = e.score + lambda * e.movement
			if J < bestJ - 1e-9 then
				best, bestJ = e, J
			end
		end
	end
	return best
end

return M
