--!nonstrict
-- Turns scan captures into the bar's motion layout (which columns move with
-- which spacer, and how far), then separates content from the static
-- background so the simulator can move only the content.

local image = require("./image.luau")
local wear = require("./wear.luau")

local budget = require("./budget.luau")

local M = {}

M.DIFF = 0.02 -- linear luma change that counts as "changed"
M.MIN_COL = 0.05 -- summed change for a column to count
M.MERGE_GAP = 12 -- px: changed runs closer than this merge
M.MEDIAN_R = 12 -- px: median window for the edge-row background line
M.CONTENT = 0.02 -- deviation from that line that marks content
M.VERIFY_LIMIT = 0.35
M.SHIFT_TOL = 1 -- px a measured shift may differ from the exact one (rounding)
M.MINORITY = 0.2 -- share of a spacer's moved content that may disagree before it is measured again

local function runsOf(cols, minSum, gap)
	local runs, cur = {}, nil
	for x = 0, #cols - 1 do
		if cols[x + 1] > minSum then
			if cur and x - cur[2] <= gap then
				cur[2] = x + 1
			else
				cur = { x, x + 1 }
				table.insert(runs, cur)
			end
		end
	end
	return runs
end

-- Columns whose content changed between two captures taken with identical
-- spacer widths (clock ticks, visualizers).
function M.dynamicColumns(a, b, y0, y1)
	local set = {}
	for x = 0, a.w - 1 do
		if x % 64 == 0 then
			budget.check()
		end
		for y = y0, y1 - 1 do
			if math.abs(image.get(a, x, y) - image.get(b, x, y)) > M.DIFF then
				set[x] = true
				break
			end
		end
	end
	return set
end

-- Mean absolute difference of probe(x + s) against base(x) over columns
-- [x0, x1), for every shift s in [-maxShift, maxShift] with columns to compare.
function M.shiftCosts(base, probe, x0, x1, y0, y1, maxShift, ignore)
	local w = base.w
	local bd, pd = base.data, probe.data
	local rf = buffer.readf32
	local costs, counts = {}, {}
	for s = -maxShift, maxShift do
		local sum, n = 0, 0
		for x = x0, x1 - 1 do
			if x % 32 == 0 then
				budget.check()
			end
			local px = x + s
			if px >= 0 and px < w and not (ignore[x] or ignore[px]) then
				for y = y0, y1 - 1 do
					sum += math.abs(rf(bd, (y * w + x) * 4) - rf(pd, (y * w + px) * 4))
				end
				n += 1
			end
		end
		if n > 0 then
			costs[s], counts[s] = sum / n, n
		end
	end
	return costs, counts
end

-- Best shift s with probe(x + s) ~ base(x). Returns s, its cost, and the cost at s = 0.
function M.matchShift(base, probe, x0, x1, y0, y1, maxShift, ignore)
	local costs = M.shiftCosts(base, probe, x0, x1, y0, y1, maxShift, ignore)
	local best, bestS = math.huge, 0
	for s = -maxShift, maxShift do
		local c = costs[s]
		if c and c < best - 1e-12 then
			best, bestS = c, s
		end
	end
	return bestS, best, costs[0] or best
end

-- A spacer widened by probePx moves its section by the full width (start and
-- end sections) or by half of it (the centred section), nothing else. Judges
-- the shift costs of one changed run: "moved" with that exact shift, "odd"
-- when a shift no spacer can cause fits clearly better (a widget before it
-- changed width between the captures), or "still".
-- Shifts compared over far fewer columns (the rest ignored as changing
-- content) are left out: their mean cost is not comparable.
function M.judgeShift(costs, probePx: number, scale: number, maxShift: number, counts): (string, number?)
	local nMax = 0
	for _, n in pairs(counts or {}) do
		nMax = math.max(nMax, n)
	end
	local function usable(s: number): boolean
		return costs[s] ~= nil and (counts == nil or counts[s] >= 0.5 * nMax)
	end
	local zero = if usable(0) then costs[0] else nil
	local bestAny = math.huge
	for s = -maxShift, maxShift do
		if s ~= 0 and usable(s) and costs[s] < bestAny then
			bestAny = costs[s]
		end
	end
	if zero == nil or bestAny >= zero * 0.5 then
		return "still", nil
	end
	local full = probePx * scale
	local bestE, bestC = nil, math.huge
	for _, e in ipairs({ full, -full, full / 2, -full / 2 }) do
		for s = math.ceil(e - M.SHIFT_TOL), math.floor(e + M.SHIFT_TOL) do
			if usable(s) and costs[s] < bestC then
				bestC, bestE = costs[s], e
			end
		end
	end
	if bestE and bestC < zero * 0.5 and bestC <= bestAny * 1.25 + 1e-9 then
		return "moved", bestE
	end
	return "odd", nil
end

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- opts.pairs[slot] = {base, probe}: each probe with the base captured just
-- before it (opts.probes with the shared opts.base still works). Returns the
-- layout, the changed-pixel mask, and the slots whose probe showed a shift no
-- spacer can cause, or content moving by two different amounts; the caller
-- captures those again.
function M.build(opts)
	local base = opts.base
	local w, h = base.w, base.h
	local y0, y1 = opts.barRows[1], opts.barRows[2]
	local pairsBySlot = opts.pairs
	if not pairsBySlot then
		pairsBySlot = {}
		for slot, probe in pairs(opts.probes) do
			pairsBySlot[slot] = { base = base, probe = probe }
		end
	end
	-- columns that changed between any two captures with identical widths
	local ignore = if opts.baseB then M.dynamicColumns(base, opts.baseB, y0, y1) else {}
	for _, pair in pairs(pairsBySlot) do
		if pair.base ~= base then
			for x in pairs(M.dynamicColumns(base, pair.base, y0, y1)) do
				ignore[x] = true
			end
		end
	end
	local maxShift = math.ceil(opts.probePx * opts.scale) + M.SHIFT_TOL + 1
	local diff = image.new(w, h)
	local pieces, slots, implausible = {}, {}, {}

	for _, slot in ipairs(sortedKeys(pairsBySlot)) do
		local own, probe = pairsBySlot[slot].base, pairsBySlot[slot].probe
		slots[slot] = { moves = false }
		local cols = table.create(w, 0)
		for y = y0, y1 - 1 do
			budget.check()
			for x = 0, w - 1 do
				local d = math.abs(image.get(own, x, y) - image.get(probe, x, y))
				if d > M.DIFF then
					image.set(diff, x, y, 1)
					if not ignore[x] then
						cols[x + 1] += d
					end
				end
			end
		end
		-- content moving by an amount no spacer can cause means something else
		-- moved too. Pieces count by the width of their change, so a sliver
		-- next to changing text cannot outvote a section.
		local oddWeight, total = 0, 0
		for _, r in ipairs(runsOf(cols, M.MIN_COL, M.MERGE_GAP)) do
			local a, b = math.max(r[1] - maxShift, 0), math.min(r[2] + maxShift, w)
			local costs, counts = M.shiftCosts(own, probe, a, b, y0, y1, maxShift, ignore)
			local verdict, e = M.judgeShift(costs, opts.probePx, opts.scale, maxShift, counts)
			local weight = r[2] - r[1]
			if verdict == "moved" then
				slots[slot].moves = true
				table.insert(pieces, { x0 = a, x1 = b, slot = slot, f = e / opts.probePx, weight = weight })
				total += weight
			elseif verdict == "odd" then
				oddWeight += weight
				total += weight
			end
		end
		if total > 0 and oddWeight > M.MINORITY * total then
			table.insert(implausible, slot)
		end
	end

	-- Start and end spacers move their whole section one way (the full
	-- width). Content that seems to move the other way with the full width is
	-- changing content that happened to line up: it is dropped (it counts as
	-- static) and the spacer measured again. Centre spacers (half the width)
	-- may move content both ways.
	local dir = {}
	for _, p in ipairs(pieces) do
		if math.abs(math.abs(p.f) - opts.scale) < 1e-9 then
			local d = dir[p.slot] or { pos = 0, neg = 0 }
			dir[p.slot] = d
			if p.f > 0 then
				d.pos += p.weight
			else
				d.neg += p.weight
			end
		end
	end
	for i = #pieces, 1, -1 do
		local p = pieces[i]
		local d = dir[p.slot]
		if d and d.pos > 0 and d.neg > 0 and math.abs(math.abs(p.f) - opts.scale) < 1e-9 then
			local keep = if d.pos >= d.neg then 1 else -1
			if p.f * keep < 0 then
				table.remove(pieces, i)
				if not table.find(implausible, p.slot) then
					table.insert(implausible, p.slot)
				end
			end
		end
	end

	table.sort(pieces, function(p, q)
		return p.x0 < q.x0
	end)
	-- Pieces join the previous group when they overlap it (the centre group,
	-- moved by two spacers) or when the same spacer moves them by the same
	-- amount across a small gap (both edges of one wide pill).
	local groups = {}
	local function vote(g, p)
		local v = g.votes[p.slot] or {}
		g.votes[p.slot] = v
		v[p.f] = (v[p.f] or 0) + (p.weight or 1)
		local best, bestW = nil, -1
		for f, wgt in pairs(v) do
			if wgt > bestW then
				best, bestW = f, wgt
			end
		end
		g.factors[p.slot] = best
	end
	for _, p in ipairs(pieces) do
		local g = groups[#groups]
		local same = g and g.factors[p.slot] ~= nil and math.abs(g.factors[p.slot] - p.f) < 1e-9
		if g and (p.x0 <= g.x1 or (same and p.x0 <= g.x1 + M.MERGE_GAP)) then
			g.x1 = math.max(g.x1, p.x1)
		else
			g = { x0 = p.x0, x1 = p.x1, factors = {}, votes = {} }
			table.insert(groups, g)
		end
		vote(g, p)
	end
	-- A spacer moves its whole section by one amount. It is measured again
	-- when its content disagrees: a real share of one group outvoted, or two
	-- groups moved by different amounts (the full and half the width).
	local function again(slot)
		if not table.find(implausible, slot) then
			table.insert(implausible, slot)
		end
	end
	local magnitudes = {}
	for _, g in ipairs(groups) do
		for slot, v in pairs(g.votes) do
			-- by magnitude: a spacer inside the centre moves content both ways
			local byMagnitude, total, best = {}, 0, 0
			for f, wgt in pairs(v) do
				local m = math.abs(f)
				byMagnitude[m] = (byMagnitude[m] or 0) + wgt
				total += wgt
			end
			for _, wgt in pairs(byMagnitude) do
				best = math.max(best, wgt)
			end
			if total - best > M.MINORITY * total then
				again(slot)
			end
		end
		g.votes = nil -- not part of the saved layout
		for slot, f in pairs(g.factors) do
			local m = magnitudes[slot]
			if m == nil then
				magnitudes[slot] = math.abs(f)
			elseif math.abs(m - math.abs(f)) > 1e-9 then
				again(slot)
			end
		end
	end
	table.sort(implausible)

	-- The capture with every spacer widened is an independent check: a group
	-- moved by several spacers must show their summed shift there. When it
	-- does not, the spacer whose removal explains the capture is dropped from
	-- the group (changing content that happened to line up while it was
	-- probed) and measured again.
	if opts.all then
		local ad, bd, rf = opts.all.data, base.data, buffer.readf32
		local function cost(g, d: number): number
			local sum, n = 0, 0
			for x = math.max(g.x0, 0), math.min(g.x1, w) - 1 do
				if x % 32 == 0 then
					budget.check()
				end
				local px = x + d
				if px >= 0 and px < w and not (ignore[x] or ignore[px]) then
					for y = y0, y1 - 1 do
						sum += math.abs(rf(ad, (y * w + px) * 4) - rf(bd, (y * w + x) * 4))
					end
					n += 1
				end
			end
			return if n > 0 then sum / n else math.huge
		end
		local function shiftOf(g, skip: string?): number
			local d = 0
			for slot, f in pairs(g.factors) do
				if slot ~= skip then
					d += f * opts.probePx
				end
			end
			return math.floor(d + 0.5)
		end
		for _, g in ipairs(groups) do
			budget.check()
			local list = sortedKeys(g.factors)
			if #list > 1 then
				-- the full model against the model without each one spacer
				local full = cost(g, shiftOf(g))
				local bestSlot, bestCost = nil, full
				for _, slot in ipairs(list) do
					local c = cost(g, shiftOf(g, slot))
					if c < bestCost then
						bestSlot, bestCost = slot, c
					end
				end
				if bestSlot and bestCost < 0.8 * full then
					g.factors[bestSlot] = nil
					again(bestSlot)
				end
			end
		end
		table.sort(implausible)
	end

	-- Ownership: every column belongs to the nearest group (split at the
	-- midpoints). A group then grows toward the side it moves to, so content
	-- that appears later there (a longer window title) still moves with it.
	local bounds = {}
	for i, g in ipairs(groups) do
		local left = if i > 1 then (groups[i - 1].x1 + g.x0) // 2 else 0
		local right = if i < #groups then (g.x1 + groups[i + 1].x0) // 2 else w
		bounds[i] = { left, right }
	end
	for i, g in ipairs(groups) do
		g.c0, g.c1 = g.x0, g.x1 -- measured content extent, for labels
		g.own0, g.own1 = bounds[i][1], bounds[i][2]
		for _, f in pairs(g.factors) do
			if f > 0 then
				g.x1 = g.own1
			elseif f < 0 then
				g.x0 = g.own0
			end
		end
	end

	local dynamic, cur = {}, nil
	for x = 0, w - 1 do
		if ignore[x] then
			if cur and cur[2] == x then
				cur[2] = x + 1
			else
				cur = { x, x + 1 }
				table.insert(dynamic, cur)
			end
		end
	end

	return {
		w = w,
		h = h,
		scale = opts.scale,
		probePx = opts.probePx,
		barRows = opts.barRows,
		scoreRows = opts.scoreRows,
		vDir = opts.vDir or 1,
		groups = groups,
		slots = slots,
		dynamic = dynamic,
	},
		diff,
		implausible
end

-- Median of a small list (sorts a copy).
local function median(values)
	local c = table.clone(values)
	table.sort(c)
	return c[(#c + 1) // 2]
end

-- Background estimate per column: the bar's top and bottom edge rows are
-- normally padding, so their colour (median over +-MEDIAN_R columns to shrug
-- off the odd widget touching the edge) is interpolated down each column.
local function edgeLine(chan, y0, y1)
	local w = chan.w
	local top, bot = table.create(w, 0), table.create(w, 0)
	local rows = math.min(2, math.max(1, (y1 - y0) // 4))
	for x = 0, w - 1 do
		local a, b = 0, 0
		for k = 0, rows - 1 do
			a += image.get(chan, x, y0 + k)
			b += image.get(chan, x, y1 - 1 - k)
		end
		top[x + 1], bot[x + 1] = a / rows, b / rows
	end
	local mt, mb = table.create(w, 0), table.create(w, 0)
	local win = {}
	for x = 0, w - 1 do
		if x % 64 == 0 then
			budget.check()
		end
		table.clear(win)
		for k = math.max(x - M.MEDIAN_R, 0), math.min(x + M.MEDIAN_R, w - 1) do
			table.insert(win, top[k + 1])
		end
		mt[x + 1] = median(win)
		table.clear(win)
		for k = math.max(x - M.MEDIAN_R, 0), math.min(x + M.MEDIAN_R, w - 1) do
			table.insert(win, bot[k + 1])
		end
		mb[x + 1] = median(win)
	end
	return function(x, y)
		local f = (y - y0 + 0.5) / (y1 - y0)
		return mt[x + 1] + (mb[x + 1] - mt[x + 1]) * f
	end
end

-- Background under the content. Inside group columns, pixels that deviate
-- from the edge-row line (or changed during the scan) are content and get
-- replaced by interpolation along the row from the nearest background pixels.
-- Outside groups the capture itself is the background.
function M.background(lin, l, diff)
	local w = lin.w
	local chans = { lin.r, lin.g, lin.b }
	local bg = image.rgbMap(lin, image.copy)
	local outs = { bg.r, bg.g, bg.b }
	local raw = image.new(w, lin.h)
	local y0, y1 = l.barRows[1], l.barRows[2]
	local lines = { edgeLine(lin.r, y0, y1), edgeLine(lin.g, y0, y1), edgeLine(lin.b, y0, y1) }

	for _, g in ipairs(l.groups) do
		for y = y0, y1 - 1 do
			budget.check()
			for x = math.max(g.x0, 0), math.min(g.x1, w) - 1 do
				local dev = 0
				for c = 1, 3 do
					dev = math.max(dev, math.abs(image.get(chans[c], x, y) - lines[c](x, y)))
				end
				if dev > M.CONTENT or image.get(diff, x, y) > 0 then
					image.set(raw, x, y, 1)
				end
			end
		end
	end

	-- dilate by one column so anti-aliased fringes count as content
	local content = image.copy(raw)
	for y = y0, y1 - 1 do
		budget.check()
		for x = 0, w - 1 do
			if image.get(raw, x, y) > 0 then
				if x > 0 then
					image.set(content, x - 1, y, 1)
				end
				if x < w - 1 then
					image.set(content, x + 1, y, 1)
				end
			end
		end
	end

	for y = y0, y1 - 1 do
		budget.check()
		local x = 0
		while x < w do
			if image.get(content, x, y) > 0 then
				local a = x
				while x < w and image.get(content, x, y) > 0 do
					x += 1
				end
				local b = x
				for c = 1, 3 do
					local lv = if a > 0 then image.get(chans[c], a - 1, y) else nil
					local rv = if b < w then image.get(chans[c], b, y) else nil
					lv = lv or rv or lines[c](a, y)
					rv = rv or lv
					for xx = a, b - 1 do
						local f = (xx - a + 1) / (b - a + 1)
						image.set(outs[c], xx, y, lv + (rv - lv) * f)
					end
				end
			else
				x += 1
			end
		end
	end
	return bg, content
end

function M.layers(p, lin, bg)
	local wbg = wear.map(p, bg)
	local dw = wear.map(p, lin)
	image.add(dw, wbg, -1)
	return { wbg = wbg, dw = dw }
end

-- Predicted luma with every spacer widened by probePx, compared with the
-- actual capture. Returns |error| / |content| over the bar rows.
function M.verify(l, baseL, bgL, actualL)
	local contentL = image.copy(baseL)
	image.add(contentL, bgL, -1)
	local pred = image.copy(bgL)
	local owned = image.new(baseL.w, 1)
	for _, g in ipairs(l.groups) do
		local d = 0
		for _, f in pairs(g.factors) do
			d += f * l.probePx
		end
		local layer = image.maskColumns(contentL, g.x0, g.x1)
		image.add(pred, image.shiftColumns(layer, 0, layer.w, -math.floor(d + 0.5)))
		for x = math.max(g.x0, 0), math.min(g.x1, baseL.w) - 1 do
			image.set(owned, x, 0, 1)
		end
	end
	local err, mass = 0, 0
	for y = l.barRows[1], l.barRows[2] - 1 do
		budget.check()
		for x = 0, baseL.w - 1 do
			local c = image.get(contentL, x, y)
			if image.get(owned, x, 0) == 0 then
				image.set(pred, x, y, image.get(pred, x, y) + c)
			end
			err += math.abs(image.get(pred, x, y) - image.get(actualL, x, y))
			mass += math.abs(c)
		end
	end
	return err / math.max(mass, 1e-6)
end

return M
