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

-- Best shift s in [-maxShift, maxShift] with probe(x + s) ~ base(x) over
-- columns [x0, x1). Returns s, its mean absolute difference, and the one at s = 0.
function M.matchShift(base, probe, x0, x1, y0, y1, maxShift, ignore)
	local w = base.w
	local bd, pd = base.data, probe.data
	local rf = buffer.readf32
	local best, bestS, zero = math.huge, 0, nil
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
			local sad = sum / n
			if s == 0 then
				zero = sad
			end
			if sad < best - 1e-12 then
				best, bestS = sad, s
			end
		end
	end
	return bestS, best, zero or best
end

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

function M.build(opts)
	local base = opts.base
	local w, h = base.w, base.h
	local y0, y1 = opts.barRows[1], opts.barRows[2]
	local ignore = if opts.baseB then M.dynamicColumns(base, opts.baseB, y0, y1) else {}
	local maxShift = math.ceil(opts.probePx * opts.scale) + 2
	local diff = image.new(w, h)
	local pieces, slots = {}, {}

	for _, slot in ipairs(sortedKeys(opts.probes)) do
		local probe = opts.probes[slot]
		slots[slot] = { moves = false }
		local cols = table.create(w, 0)
		for y = y0, y1 - 1 do
			budget.check()
			for x = 0, w - 1 do
				local d = math.abs(image.get(base, x, y) - image.get(probe, x, y))
				if d > M.DIFF then
					image.set(diff, x, y, 1)
					if not ignore[x] then
						cols[x + 1] += d
					end
				end
			end
		end
		for _, r in ipairs(runsOf(cols, M.MIN_COL, M.MERGE_GAP)) do
			local a, b = math.max(r[1] - maxShift, 0), math.min(r[2] + maxShift, w)
			local s, sad, zero = M.matchShift(base, probe, a, b, y0, y1, maxShift, ignore)
			if s ~= 0 and sad < zero * 0.5 then
				slots[slot].moves = true
				table.insert(pieces, { x0 = a, x1 = b, slot = slot, f = s / opts.probePx })
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
	for _, p in ipairs(pieces) do
		local g = groups[#groups]
		local same = g and g.factors[p.slot] ~= nil and math.abs(g.factors[p.slot] - p.f) < 1e-9
		if g and (p.x0 <= g.x1 or (same and p.x0 <= g.x1 + M.MERGE_GAP)) then
			g.x1 = math.max(g.x1, p.x1)
			if g.factors[p.slot] == nil then
				g.factors[p.slot] = p.f
			end
		else
			table.insert(groups, { x0 = p.x0, x1 = p.x1, factors = { [p.slot] = p.f } })
		end
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
		diff
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
