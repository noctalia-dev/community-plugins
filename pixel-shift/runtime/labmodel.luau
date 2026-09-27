--!nonstrict
-- Builds everything the lab shows for one output: evaluations (cached per
-- strategy), the rendered images, hotspots and curve data. Text is left to
-- the lab; this module only produces numbers, enums and image paths.

local image = require("../core/image.luau")
local color = require("../core/color.luau")
local render = require("../core/render.luau")
local bmp = require("../core/bmp.luau")
local hotspots = require("../core/hotspots.luau")
local simulate = require("../core/simulate.luau")
local optimize = require("../core/optimize.luau")
local util = require("../core/util.luau")
local wear = require("../core/wear.luau")
local store = require("./store.luau")

local M = {}

-- sized for the lab's cards (content 928 px, cards padded by 12)
M.OVERVIEW_W = 904
M.INSPECT_W = 534
M.INSPECT_MAX_H = 112
M.METER_W = 328 -- the risk scale in the sidebar
M.THUMB_ASPECT = 64 / 24 -- hotspot thumbnails, shown at 64 x 24

local function hex(c)
	return string.format("#%02x%02x%02x", c[1], c[2], c[3])
end

function M.evaluate(O, strategy)
	O.evalCache = O.evalCache or {}
	O.evalOrder = O.evalOrder or {}
	local key = `{O.layersId}|{util.stableEncode(strategy.ranges)}|{strategy.vertical or 0}`
	local hit = O.evalCache[key]
	if hit then
		return hit
	end
	local ev = simulate.evaluate(O.layers, O.layout, strategy, O.rref)
	O.evalCache[key] = ev
	table.insert(O.evalOrder, key)
	if #O.evalOrder > 6 then
		O.evalCache[table.remove(O.evalOrder, 1)] = nil
	end
	return ev
end

-- Label key for a spacer: the side of the group it moves most. When that
-- group is also moved the opposite way by another spacer (the centre pair),
-- the label says which side of the centre this spacer sits on.
function M.slotLabel(layout, slot): string
	local best, bestF = nil, 0
	for _, g in ipairs(layout.groups) do
		local f = g.factors[slot]
		if f and math.abs(f) > math.abs(bestF) + 1e-9 then
			best, bestF = g, f
		end
	end
	if not best then
		return "unknown"
	end
	for other, f in pairs(best.factors) do
		if other ~= slot and f * bestF < 0 then
			return if bestF > 0 then "center_l" else "center_r"
		end
	end
	return util.side(((best.c0 or best.own0) + (best.c1 or best.own1)) / 2, layout.w)
end

local function sortedSlots(layout)
	local list = {}
	for slot in pairs(layout.slots) do
		table.insert(list, slot)
	end
	table.sort(list)
	return list
end

-- Everything expensive the lab shows is cached per output until its layers
-- change: full-size views per strategy, hotspots, and the written images per
-- state, so switching back and forth between views, modes and hotspots does
-- not render again.
M.CACHE_ITEMS = 32

local function cacheOf(O)
	local c = O.renderCache
	if not c or c.layersId ~= O.layersId then
		c = { layersId = O.layersId, items = {}, order = {}, fixed = {} }
		O.renderCache = c
	end
	return c
end

-- One per layers epoch (percentiles, the bar raster): kept out of the FIFO.
local function fixed(O, key: string, fn)
	local c = cacheOf(O)
	local hit = c.fixed[key]
	if hit == nil then
		hit = fn()
		c.fixed[key] = hit
	end
	return hit
end

local function peek(O, key: string)
	return cacheOf(O).items[key]
end

-- Colour ramps are 256 OKLCH conversions each: once per theme colour.
local ramps = {}
local function rampsFor(primary: string?)
	local k = primary or ""
	local r = ramps[k]
	if not r then
		r = { glow = color.glowRamp(primary), risk = color.riskRamp(primary) }
		ramps[k] = r
	end
	return r
end

local function cached(O, key: string, fn)
	local c = cacheOf(O)
	local hit = c.items[key]
	if hit ~= nil then
		return hit
	end
	local v = fn()
	c.items[key] = v
	table.insert(c.order, key)
	while #c.order > M.CACHE_ITEMS do
		c.items[table.remove(c.order, 1)] = nil
	end
	return v
end

-- A cached set of written images, rendered again when a file is gone.
local function files(O, ctx, key: string, fn)
	local exists = ctx.fileExists or function(path: string)
		return noctalia.fileExists(path)
	end
	local c = cacheOf(O)
	local hit = c.items[key]
	if hit then
		for _, path in pairs(hit.paths) do
			if not exists(path) then
				hit = nil
				break
			end
		end
	end
	if hit then
		return hit
	end
	c.items[key] = nil
	return cached(O, key, fn)
end

local function strategyKey(strategy): string
	return `{util.stableEncode(strategy.ranges)}|{strategy.vertical or 0}`
end

local function views(O, ctx, evNone, evStrat)
	local c = fixed(O, "pct", function()
		local y0, y1 = O.layout.scoreRows[1], O.layout.scoreRows[2]
		return { eRef = image.percentile(evNone.E, 0.998, y0, y1), rTop = image.percentile(evNone.R, 0.999, y0, y1) }
	end)
	local r = rampsFor(ctx.primary)
	local lum = O.baseL or fixed(O, "lum", function()
		return image.luma(O.base)
	end)
	local function paint(name: string, E, R, lum)
		if name == "risk" then
			return render.riskView(lum, R, c.rTop, r.risk)
		end
		return render.ghostView(E, R, c.eRef, c.rTop, r.glow)
	end
	local function view(name: string, ev, key: string)
		if name == "bar" then
			return if O.lastCapture
				then O.lastCapture
				else fixed(O, "bar", function()
					return render.fromLinear(O.base)
				end)
		end
		return cached(O, `view|{name}|{key}|{ctx.primary}`, function()
			return paint(name, ev.E, ev.R, lum)
		end)
	end
	-- Columns [x0, x1) of a view. Without the full view cached, only that
	-- stretch is painted (plus 3 px: the glow's bloom reaches that far).
	local function stretch(name: string, ev, key: string, x0: number, x1: number)
		local full = if name == "bar" then view("bar") else peek(O, `view|{name}|{key}|{ctx.primary}`)
		if full then
			return full, x0
		end
		local w = O.layout.w
		local c0, c1 = math.max(x0 - 3, 0), math.min(x1 + 3, w)
		return paint(name, image.crop(ev.E, c0, c1), image.crop(ev.R, c0, c1), image.crop(lum, c0, c1)), x0 - c0
	end
	return view, r.glow, stretch
end

local function spotsFor(O, ctx, evStrat, sKey: string)
	return cached(O, `spots|{sKey}|{ctx.profile}`, function()
		local list, worst = hotspots.find({
			R = evStrat.R,
			dw = O.layers.dw,
			wWhite = wear.white(wear.profile(ctx.profile)),
			variance = O.variance,
			layout = O.layout,
			rref = O.rref,
			strategy = ctx.preview,
		})
		return { list = list, worst = worst }
	end)
end

-- What the lab needs first, computed while it is closed (the engine runs
-- this in idle time after the data changed): both evaluations, the
-- percentiles, the hotspots and the default view. Opening it then only
-- crops and encodes.
function M.warm(O, ctx)
	local none = { ranges = {}, vertical = 0 }
	local evNone = M.evaluate(O, none)
	local evStrat = M.evaluate(O, ctx.preview)
	local sKey = strategyKey(ctx.preview)
	local view = views(O, ctx, evNone, evStrat)
	spotsFor(O, ctx, evStrat, sKey)
	view("ghost", evStrat, sKey)
end

-- Renders every view and mode at the current hotspot ahead of time (the
-- engine runs it in the background after the lab showed its first image), so
-- switching between them only publishes cached paths.
function M.prepare(O, ctx, ui)
	for _, view in ipairs({ "ghost", "risk", "bar" }) do
		for _, mode in ipairs({ "strategy", "none" }) do
			M.build(O, { view = view, mode = mode, hotspot = ui and ui.hotspot or 1 }, ctx)
		end
	end
end

function M.build(O, ui, ctx)
	local writeImage = ctx.writeImage or store.writeImage
	local prefix = (O.name or "output") .. "-"
	local function write(slot: string, bytes: string)
		return writeImage(prefix .. slot, bytes) -- slots per output: outputs never evict each other's files
	end
	local layout = O.layout
	local none = { ranges = {}, vertical = 0 }
	local evNone = M.evaluate(O, none)
	local evStrat = M.evaluate(O, ctx.preview)
	local sKey, nKey = strategyKey(ctx.preview), strategyKey(none)
	local view, ramp, stretch = views(O, ctx, evNone, evStrat)
	local glow = hex(ramp[205])
	local shownKey = if ui.mode == "none" then nKey else sKey
	local seq = tostring(O.captureSeq or 0) -- bumped by the engine with every new capture
	local captureKey = if ui.view == "bar" then seq else ""

	local found = spotsFor(O, ctx, evStrat, sKey)
	local spots = found.list
	local selected = math.clamp(ui.hotspot or 1, 1, math.max(#spots, 1))
	local sel = spots[selected]

	-- inspector region: centred on the selected hotspot (or the bar centre)
	-- the inspector shows the scored rows (the bar and its edge) only
	local iy0, iy1 = layout.scoreRows[1], layout.scoreRows[2]
	local zoom = math.clamp(M.INSPECT_MAX_H // (iy1 - iy0), 1, 4)
	local regionW = M.INSPECT_W // zoom
	local cx = if sel then (sel.x0 + sel.x1) // 2 else layout.w // 2
	local rx0 = math.clamp(cx - regionW // 2, 0, math.max(layout.w - regionW, 0))
	local rx1 = math.min(rx0 + regionW, layout.w)

	-- overview halves with the inspected region framed
	local half = layout.w // 2
	local halves = cached(O, `halves|{ui.view}|{shownKey}|{captureKey}|{ctx.primary}`, function()
		local left, right = render.halves(view(ui.view, if ui.mode == "none" then evNone else evStrat, shownKey), M.OVERVIEW_W)
		return { left = left, right = right }
	end)
	local overview = files(O, ctx, `ov|{ui.view}|{shownKey}|{captureKey}|{ctx.primary}|{rx0}`, function()
		local left, right = render.copy(halves.left), render.copy(halves.right)
		render.frameHalves(left, right, rx0, rx1, layout.w, ramp[230], 2)
		return { h = left.h, paths = { left = write("overview-l", bmp.encode(left)), right = write("overview-r", bmp.encode(right)) } }
	end)
	-- the two inspector strips are cached apart: a new strategy leaves "no shift" alone
	-- the spot is framed in both strips, with a little room so a 2 px spot still
	-- reads as a box
	local mark = if sel then `{sel.x0}-{sel.x1}` else "-"
	local function strip(slot: string, ev, key: string)
		return files(O, ctx, `{slot}|{ui.view}|{key}|{captureKey}|{ctx.primary}|{rx0}|{mark}`, function()
			local img, ox = stretch(ui.view, ev, key, rx0, rx1)
			local out = render.zoom(img, ox, ox + rx1 - rx0, iy0, iy1, zoom)
			if sel then
				local pad = math.ceil(4 * (layout.scale or 1))
				local a, b = math.max(sel.x0 - pad, rx0), math.min(sel.x1 + pad, rx1)
				render.outline(out, (a - rx0) * zoom, (b - rx0) * zoom, zoom, ramp[230])
			end
			return { paths = { path = write(slot, bmp.encode(out)) } }
		end)
	end
	local inspector = {
		paths = { none = strip("inspect-none", evNone, nKey).paths.path, strategy = strip("inspect-strategy", evStrat, sKey).paths.path },
	}
	local legend = files(O, ctx, `legend|{ctx.primary}`, function() -- tiny; evicted and redone rarely
		return { paths = { legend = write("legend", bmp.encode(render.legend(ramp, M.METER_W, 8))) } }
	end)
	-- what each hotspot looks like on the bar itself
	-- one fixed 64:24 window centred on each spot
	local thumbs = files(O, ctx, `thumbs|{sKey}|{ctx.profile}|{seq}|{ctx.primary}`, function()
		local barView = view("bar")
		local rows = layout.barRows[2] - layout.barRows[1]
		local winW = math.min(math.floor(rows * M.THUMB_ASPECT + 0.5), layout.w)
		local paths = {}
		for i, s in ipairs(spots) do
			local x0 = math.clamp((s.x0 + s.x1) // 2 - winW // 2, 0, layout.w - winW)
			local img = render.zoom(barView, x0, x0 + winW, layout.barRows[1], layout.barRows[2], 1)
			paths[i] = write(`thumb-{i}`, bmp.encode(img))
		end
		return { paths = paths }
	end)

	-- a spot's peak risk without shifting (% of the reference), for the inspector
	local function peakIn(R, x0: number, x1: number): number
		local best = 0
		for y = iy0, iy1 - 1 do
			for x = math.max(x0, 0), math.min(x1, R.w) - 1 do
				best = math.max(best, image.get(R, x, y))
			end
		end
		return 100 * best / O.rref
	end

	local scale = M.OVERVIEW_W / half
	local pins = {}
	for i, s in ipairs(spots) do
		local x = (s.x0 + s.x1) / 2
		local row = if x < half then 1 else 2
		table.insert(pins, { n = i, row = row, x = (x - (if row == 2 then half else 0)) * scale, selected = i == selected })
	end

	local data = {
		glow = glow,
		info = O.info,
		state = { view = ui.view, mode = ui.mode, hotspot = selected, output = O.name },
		exposure = { n = if O.acc then O.acc.n else 0, hours = if O.acc and O.acc.n > 1 then (O.acc.last - O.acc.first) / 3600 else 0 },
		score = { none = evNone.score, strategy = evStrat.score },
		worst = found.worst,
		approximate = O.approximate,
		overview = {
			left = overview.paths.left,
			right = overview.paths.right,
			w = M.OVERVIEW_W,
			h = overview.h,
			pins = pins,
		},
		inspector = {
			none = inspector.paths.none,
			strategy = inspector.paths.strategy,
			w = (rx1 - rx0) * zoom,
			h = (iy1 - iy0) * zoom,
			zoom = zoom,
			n = if sel then selected else nil,
		},
		legend = legend.paths.legend,
		hotspots = {},
		chips = {},
		manual = {},
		idle = {},
		vertical = ctx.preview.vertical or 0,
		stepMinutes = ctx.stepMinutes,
		maxShift = ctx.maxShift,
		previewing = ctx.previewing,
		canRevert = ctx.canRevert,
		liveSince = ctx.liveSince,
		output = O.name,
	}
	for i, s in ipairs(spots) do
		data.hotspots[i] = { n = i, side = s.side, x0 = s.x0, x1 = s.x1, cause = s.cause, peak = s.peak, level = s.level,
			thumb = thumbs.paths[i],
			-- in the output's logical px, like the bar settings the user knows
			lx0 = math.floor(s.x0 / (layout.scale or 1)),
			lx1 = math.ceil(s.x1 / (layout.scale or 1)),
			peakNone = peakIn(evNone.R, s.x0, s.x1),
		}
	end
	for _, slot in ipairs(sortedSlots(layout)) do
		local label = M.slotLabel(layout, slot)
		if layout.slots[slot].moves then
			local px = ctx.preview.ranges[slot] or 0
			table.insert(data.chips, { slot = label, px = px })
			table.insert(data.manual, { id = slot, slot = label, value = px })
		else
			table.insert(data.idle, label)
		end
	end
	if ctx.result then
		local r = ctx.result
		local c = optimize.curve(r.entries, r.budgets)
		local pick = optimize.pick(r.entries, optimize.lambdaFromSlider(ctx.lambdaT), ctx.allowVertical and r.allowVertical)
		local pickIndex = nil
		for i, B in ipairs(r.budgets) do
			if pick and pick.B == B then
				pickIndex = i
			end
		end
		local h, v = {}, {}
		for i = 1, #r.budgets do
			h[i] = c.h[i] or evNone.score
			v[i] = c.v[i] or false -- JSON-safe: no holes
		end
		data.curve = {
			budgets = r.budgets,
			h = h,
			v = if c.v[1] then v else nil,
			top = math.max(evNone.score, 1),
			pick = pickIndex,
			pickV = pick and pick.V or 0,
			pickScore = pick and pick.score or nil,
			-- what the next step of movement would still buy, for the pick note
			nextPx = if pickIndex and r.budgets[pickIndex + 1] then r.budgets[pickIndex + 1] else nil,
			nextScore = if pickIndex and r.budgets[pickIndex + 1] then h[pickIndex + 1] else nil,
		}
		data.status = { at = r.at, evals = r.evals, seconds = r.seconds }
	end
	return data
end

return M
