--!nonstrict
-- Pixel Shift engine (service). Owns all state: the spacer registry, one
-- record per output (scan, exposure, optimiser result), the player that turns
-- the active strategy into spacer widths, the vertical override, and the lab.

local util = require("./core/util.luau")
local budget = require("./core/budget.luau")
local image = require("./core/image.luau")
local wear = require("./core/wear.luau")
local risk = require("./core/risk.luau")
local layoutMod = require("./core/layout.luau")
local scanstore = require("./core/scanstore.luau")
local exposure = require("./core/exposure.luau")
local optimize = require("./core/optimize.luau")
local schedule = require("./core/schedule.luau")
local decide = require("./core/decide.luau")
local tasks = require("./runtime/tasks.luau")
local capture = require("./runtime/capture.luau")
local store = require("./runtime/store.luau")
local vertical = require("./runtime/vertical.luau")
local labmodel = require("./runtime/labmodel.luau")
local theme = require("./runtime/theme.luau")

-- Fast copy of core/kernels.luau (Noctalia gives only the entry script fast
-- builtin calls; tools/check-kernels.py keeps this identical to the module).
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
end
-- END KERNELS
image.install(K)
risk.install(K)

local PROBE = 8 -- logical px each spacer is widened by while measuring
local SETTLE_MS = 150 -- wait after the spacers acknowledged before capturing
local STALE = 120 -- s without a hello before a spacer is dropped
local MIN_SAMPLES = 6 -- exposure samples before they replace the scan
local OPT_SLICE_MS = 6
local SLICE_MS = 8 -- Noctalia stops a callback after ~25 ms of CPU

-- persisted preferences and per-output records -------------------------------
local saved = store.readJson("state.json") or {}
if type(saved) ~= "table" or saved.version ~= 1 then
	saved = { version = 1 }
end
saved.outputs = saved.outputs or {}
saved.lambdaT = saved.lambdaT or optimize.sliderFromLambda(optimize.LAMBDA_DEFAULT)
if saved.auto == nil then
	saved.auto = true
end
saved.allowVertical = saved.allowVertical == true
saved.paused = saved.paused == true

local spacers = {} -- id -> {output, vertical, t}
local outputs = {} -- name -> O
local widths = {} -- id -> last published width
local forced = nil -- id -> width while a scan measures
local seq = 0
local ui = { output = nil, view = "ghost", mode = "strategy", hotspot = 1 }
local status = { kind = "idle" }
local labOpen, labDirty = false, true
local dataDirty = true -- lab images/data need rebuilding (not just the status line)
local lastData = nil
local themeHex = nil
local optimizer = nil -- {name, opt, started, allowVertical}
local spacerChangedAt = os.time()
local fingerprintDue = true
local lastFingerprint, lastSlow, lastVertical, lastDrift = 0, 0, -1, 0
local verticalCheck = nil -- {at, v, retried}: confirm that an applied override took effect
local errors = {}
local lastCmd = nil

-- Heavy core loops call budget.check(); inside a task or the optimiser this
-- yields once the slice is used up, so no callback comes near the host's
-- CPU budget. Outside a coroutine it does nothing.
local sliceStart = os.clock()
budget.hook = function()
	if (os.clock() - sliceStart) * 1000 >= SLICE_MS and coroutine.isyieldable() then
		coroutine.yield()
	end
end

local function setting(key: string, default)
	local v = noctalia.getConfig(key)
	if v == nil then
		return default
	end
	return v
end

local function profileName(): string
	return setting("panel_profile", "generic")
end

local function persist()
	store.writeJson("state.json", saved)
end

local function setStatus(st)
	status = st
	labDirty = true
	dataDirty = true
end

local function fileName(kind: string, name: string): string
	return kind .. "-" .. string.gsub(name, "[^%w%-]", "_")
end

-- spacers --------------------------------------------------------------------
local function spacersOn(name: string)
	local ids = {}
	for id, info in pairs(spacers) do
		if info.output == name then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

local function publishKnown()
	local known = {}
	for id, info in pairs(spacers) do
		known[id] = info.output
	end
	noctalia.state.set("spacers:known", known)
end

-- bar and outputs --------------------------------------------------------------
local function barInfo()
	local order = noctalia.getSetting("bar.order")
	local name = (type(order) == "table" and order[1]) or "main"
	local prefix = "bar." .. name .. "."
	local thickness = noctalia.getSetting(prefix .. "thickness") or 34
	local margin = noctalia.getSetting(prefix .. "margin_edge") or 0
	-- with the override on (or just changed, before Noctalia reloaded) the
	-- config reports the shifted values; the bar's own ones are in the base
	local base = saved.verticalBase
	if base and (vertical.active() or not vertical.settled()) then
		thickness, margin = base.thickness, base.margin
	end
	local barScale = noctalia.getSetting(prefix .. "scale") or 1
	return {
		name = name,
		position = noctalia.getSetting(prefix .. "position") or "top",
		rawThickness = thickness,
		thickness = math.floor(thickness * barScale + 0.5),
		margin = margin,
		enabled = noctalia.getSetting(prefix .. "enabled") ~= false,
		layout = {
			noctalia.getSetting(prefix .. "start"),
			noctalia.getSetting(prefix .. "center"),
			noctalia.getSetting(prefix .. "end"),
			noctalia.getSetting(prefix .. "widget_spacing"),
			noctalia.getSetting(prefix .. "padding"),
			noctalia.getSetting(prefix .. "font_family"),
			noctalia.getSetting(prefix .. "font_scale"),
			barScale,
		},
	}
end

local function outputInfo(name: string)
	for _, o in ipairs(noctalia.outputs()) do
		if o.name == name then
			return o
		end
	end
	return nil
end

local function fingerprintFor(name: string, bar, out): string
	return util.fingerprint({
		format = decide.LAYOUT_FORMAT,
		geo = util.captureGeometry(out, bar).geometry,
		scale = out.scale,
		pos = bar.position,
		thickness = bar.thickness,
		layout = bar.layout,
		spacers = spacersOn(name),
	})
end

local function newOutput(name: string)
	return {
		name = name,
		fp = nil,
		info = nil,
		layout = nil,
		base = nil,
		bg = nil,
		baseL = nil,
		scanLayers = {},
		acc = nil,
		layers = nil,
		layersId = 0,
		rref = risk.reference(wear.profile(profileName())),
		result = nil,
		preview = nil,
		approximate = false,
		needsScan = false,
		needsOptimize = false,
		retryAt = 0,
		failures = 0, -- failed or rejected scans in a row, for the retry backoff
		lastSample = os.time(),
		mismatches = 0,
		mismatchScan = false, -- the pending scan came from mismatched samples
		lastCapture = nil,
		variance = nil,
	}
end

local function rebuildLayers(O)
	local key = profileName()
	local p = wear.profile(key)
	O.rref = risk.reference(p)
	if not O.scanLayers[key] then
		O.scanLayers[key] = layoutMod.layers(p, O.base, O.bg)
	end
	if O.acc and O.acc.n >= MIN_SAMPLES then
		O.layers = exposure.layers(O.acc, key, O.scanLayers[key], O.layout)
		O.variance = exposure.variance(O.acc)
	else
		O.layers = O.scanLayers[key]
		O.variance = nil
	end
	O.layersId += 1
	O.evalCache, O.evalOrder = nil, nil
	labDirty = true
	dataDirty = true
end

local function rebuildLayersAsync(O)
	O.layers = nil
	tasks.spawn("layers:" .. O.name, function()
		rebuildLayers(O)
	end)
end

-- Restore a saved scan when the fingerprint still matches.
local function restore(O, fp: string): boolean
	local meta = saved.outputs[O.name]
	if not meta or meta.fp ~= fp then
		return false
	end
	local l = store.readJson(fileName("layout", O.name) .. ".json")
	local base, bg = scanstore.decode(store.read(fileName("scan", O.name) .. ".bin"))
	if not decide.validLayout(l, base) then
		return false
	end
	O.layout, O.base, O.bg, O.baseL = l, base, bg, image.luma(base)
	O.info = meta.info
	O.acc = exposure.deserialize(store.read(fileName("exposure", O.name) .. ".bin"))
	if O.acc and (O.acc.w ~= base.w or O.acc.h ~= base.h) then
		O.acc = nil
	end
	O.acc = O.acc or exposure.new(base.w, base.h)
	O.result = meta.result
	O.approximate = meta.approximate == true
	O.fp = fp
	rebuildLayers(O)
	return true
end

-- strategies -------------------------------------------------------------------
local function activeStrategy(name: string)
	local meta = saved.outputs[name]
	return (meta and meta.strategy) or { ranges = {}, vertical = 0 }
end

local function applyStrategy(name: string, strategy, record: boolean?)
	local meta = saved.outputs[name] or {}
	saved.outputs[name] = meta
	if record ~= false and meta.strategy and not decide.sameStrategy(meta.strategy, strategy) then
		meta.history = meta.history or {}
		table.insert(meta.history, 1, meta.strategy)
		while #meta.history > 3 do
			table.remove(meta.history)
		end
	end
	meta.strategy = { ranges = table.clone(strategy.ranges), vertical = strategy.vertical or 0, lambdaT = strategy.lambdaT or saved.lambdaT }
	persist()
	labDirty = true
	dataDirty = true
end

local function allowVerticalNow(): boolean
	return saved.allowVertical and saved.verticalBase ~= nil and not errors.vertical
end

-- Vertical shift was just allowed and the bar's own values are not read
-- yet: an optimisation now would leave vertical out.
local function verticalPending(): boolean
	return saved.allowVertical and saved.verticalBase == nil and not errors.vertical
end

local function previewFromLambda(name: string)
	local O = outputs[name]
	if not O or not O.result then
		return
	end
	local e = optimize.pick(O.result.entries, optimize.lambdaFromSlider(saved.lambdaT), allowVerticalNow() and O.result.allowVertical)
	if e then
		O.preview = { ranges = table.clone(e.ranges), vertical = e.V }
	end
end

-- player -----------------------------------------------------------------------
local function computeWidths(now: number)
	local out = {}
	local base = setting("step_minutes", 4)
	for name in pairs(outputs) do
		local ids = spacersOn(name)
		local offs = if saved.paused then {} else schedule.offsets(activeStrategy(name), ids, now, base)
		for _, id in ipairs(ids) do
			out[id] = offs[id] or 0
		end
	end
	for id in pairs(spacers) do
		if out[id] == nil then
			out[id] = 0
		end
	end
	if forced then
		for id, w in pairs(forced) do
			out[id] = w
		end
	end
	return out
end

local function publishWidths(force: boolean?)
	local w = computeWidths(os.time())
	local changed = force == true
	for id, v in pairs(w) do
		if widths[id] ~= v then
			changed = true
		end
	end
	if not changed then
		return
	end
	seq += 1
	widths = w
	local msg = { seq = seq }
	for id, v in pairs(w) do
		msg[id] = v
	end
	noctalia.state.set("offsets", msg)
end

local function acked(ids): boolean
	for _, id in ipairs(ids) do
		local a = noctalia.state.get("ack:" .. id)
		if type(a) ~= "number" or a < seq then
			return false
		end
	end
	return true
end

-- The bar's own margin and thickness, kept current while no override is in
-- effect: the user may change the bar at any time.
local function refreshVerticalBase()
	if not saved.allowVertical then
		return
	end
	local fresh = decide.verticalBase(saved.verticalBase, barInfo(), vertical.active(), vertical.settled())
	if fresh ~= saved.verticalBase then
		saved.verticalBase = fresh
		persist()
	end
end

local function playVertical(now: number)
	refreshVerticalBase()
	local V = 0
	for name in pairs(outputs) do
		V = math.max(V, activeStrategy(name).vertical or 0)
	end
	local driftDue = now - lastDrift >= 60
	if driftDue then
		lastDrift = now
	end
	local action, last = decide.verticalAction({
		scanning = tasks.runningPrefix("scan:"),
		allowed = allowVerticalNow(),
		paused = saved.paused,
		v = schedule.vertical(V, now),
		last = lastVertical,
		fileActive = vertical.active(),
		driftDue = driftDue,
	})
	lastVertical = last
	if action == "hold" or action == "clear" then
		verticalCheck = nil
		if action == "clear" then
			vertical.clear()
		end
	elseif action == "apply" then
		vertical.apply(saved.verticalBase, last)
		verticalCheck = if last > 0 then { at = now + 5, v = last } else nil
	elseif verticalCheck and now >= verticalCheck.at then
		local check = verticalCheck
		verticalCheck = nil
		if vertical.effective(saved.verticalBase, check.v) then
			return
		end
		if not check.retried then
			vertical.reload() -- the new file was not picked up: ask once
			verticalCheck = { at = now + 5, v = check.v, retried = true }
			return
		end
		-- a GUI setting for margin or thickness takes precedence: give up
		errors.vertical = true
		vertical.clear()
		lastVertical = 0
		for _, O in pairs(outputs) do
			O.needsOptimize = true
		end
		labDirty = true
		dataDirty = true
	end
end

-- measurement ------------------------------------------------------------------
local function fail(name: string, message: string?)
	local O = outputs[name]
	forced = nil
	publishWidths(true)
	errors.scan = message or "capture failed"
	local retry = ""
	if O then
		O.failures += 1
		local wait = decide.backoff(O.failures)
		O.needsScan = true
		O.retryAt = os.time() + wait
		retry = `; next try in {wait} s`
	end
	noctalia.log(`pixel-shift: scan failed on {name}: {errors.scan}{retry}`)
	setStatus({ kind = "error", message = errors.scan })
end

local function locked(): boolean
	local sid = noctalia.getenv("XDG_SESSION_ID")
	if not sid or sid == "" or not noctalia.commandExists("loginctl") then
		return false
	end
	local res = tasks.await(function(done)
		if not noctalia.runAsync({ "loginctl", "show-session", sid, "-p", "LockedHint", "--value" }, done, 3000) then
			done(nil)
		end
	end)
	return res ~= nil and res.exitCode == 0 and string.find(res.stdout, "yes", 1, true) ~= nil
end

local function scanTask(name: string)
	tasks.spawn("scan:" .. name, function()
		local O = outputs[name]
		local out = outputInfo(name)
		local ids = spacersOn(name)
		if not O or not out or #ids == 0 then
			if O then
				O.needsScan = false
			end
			return
		end
		if locked() then
			O.failures += 1
			O.retryAt = os.time() + decide.backoff(O.failures)
			noctalia.log(`pixel-shift: session locked, measuring {name} later`)
			return
		end
		setStatus({ kind = "scanning", output = name })
		noctalia.log("pixel-shift: measuring " .. name)
		-- measure the bar at its own size: without the vertical override, after
		-- Noctalia reloaded (the vertical player holds while a scan runs)
		vertical.clear()
		tasks.waitFor(vertical.settled, vertical.SETTLE_MS + 1000)
		local bar = barInfo()
		if not bar.enabled then
			O.needsScan = false
			setStatus({ kind = "idle" })
			return
		end
		local geom = util.captureGeometry(out, bar)
		local zero = {}
		for _, id in ipairs(ids) do
			zero[id] = 0
		end
		-- set the spacer widths, wait until every spacer drew them, capture
		local function shot(map)
			forced = map
			publishWidths(true)
			local drawn = tasks.waitFor(function()
				return acked(ids)
			end, 2000)
			if not drawn then
				return nil, "the spacers did not respond"
			end
			tasks.sleep(SETTLE_MS)
			return capture.grab(geom.geometry, geom.transpose)
		end

		local baseA, err = shot(zero)
		if not baseA then
			return fail(name, err)
		end
		local probes = {}
		for _, id in ipairs(ids) do
			local m = table.clone(zero)
			m[id] = PROBE
			local img, perr = shot(m)
			if not img then
				return fail(name, perr)
			end
			probes[id] = img
		end
		local all = {}
		for _, id in ipairs(ids) do
			all[id] = PROBE
		end
		local allImg, aerr = shot(all)
		if not allImg then
			return fail(name, aerr)
		end
		local baseB, berr = shot(zero)
		if not baseB then
			return fail(name, berr)
		end
		forced = nil
		publishWidths(true)

		-- noctalia.outputs() reports the integer buffer scale (2 for 1.5), so the
		-- physical scale comes from the capture itself.
		local scale = baseA.w / (if geom.transpose then out.height else out.width)
		local barPx = math.floor(bar.thickness * scale + 0.5)
		local barRows, scoreRows = util.rowLayout(geom.flipped, baseA.h, barPx)
		local lin = wear.linearFromRgb8(baseA)
		local baseL = image.luma(lin)
		local probeL = {}
		for id, img in pairs(probes) do
			probeL[id] = image.luma(wear.linearFromRgb8(img))
		end
		local l, diff = layoutMod.build({
			base = baseL,
			baseB = image.luma(wear.linearFromRgb8(baseB)),
			probes = probeL,
			probePx = PROBE,
			scale = scale,
			barRows = barRows,
			scoreRows = scoreRows,
			vDir = geom.vDir,
		})
		local bg = layoutMod.background(lin, l, diff)
		local verr = layoutMod.verify(l, baseL, image.luma(bg), image.luma(wear.linearFromRgb8(allImg)))

		-- nothing moved: a lock screen or fullscreen app covers the bar, or the
		-- spacers sit where they cannot move anything
		local outcome = decide.scanOutcome(l, decide.anyMoving(O.layout), O.failures + 1)
		if not outcome.accept then
			O.failures += 1
			O.retryAt = os.time() + outcome.retryIn
			noctalia.log(`pixel-shift: nothing moved while measuring {name} (bar covered?); keeping the previous measurement, next try in {outcome.retryIn} s`)
			setStatus({ kind = "idle" })
			return
		end
		l.format = decide.LAYOUT_FORMAT
		O.layout, O.base, O.bg, O.baseL = l, lin, bg, baseL
		O.scanLayers = {}
		O.approximate = verr > layoutMod.VERIFY_LIMIT
		O.lastCapture = baseA
		O.info = { width = out.width, thickness = bar.thickness, scale = scale, bright = exposure.brightFraction(baseA) }
		local fp = fingerprintFor(name, bar, out)
		local meta = saved.outputs[name] or {}
		saved.outputs[name] = meta
		if meta.fp ~= fp or not O.acc or O.acc.w ~= lin.w or O.acc.h ~= lin.h then
			O.acc = exposure.new(lin.w, lin.h)
			store.remove(fileName("exposure", name) .. ".bin")
			meta.result = nil
		end
		O.fp = fp
		meta.fp = fp
		meta.info = O.info
		meta.approximate = O.approximate
		O.result = meta.result
		store.writeJson(fileName("layout", name) .. ".json", l)
		store.write(fileName("scan", name) .. ".bin", scanstore.encode(lin, bg))
		persist()
		errors.scan = nil
		rebuildLayers(O)
		O.mismatches, O.mismatchRef, O.mismatchScan = 0, nil, false
		O.needsOptimize = outcome.optimize -- after every scan where something moves
		if outcome.retryIn then
			O.failures += 1
			O.needsScan, O.retryAt = true, os.time() + outcome.retryIn
		else
			O.failures = 0
			O.needsScan = false
		end
		noctalia.log(`pixel-shift: measured {name}: {#l.groups} groups, verify error {string.format("%.2f", verr)}`)
		setStatus({ kind = "idle" })
	end, function(err)
		fail(name, "measuring failed: " .. tostring(err))
	end)
end

local function saveExposure(O)
	store.write(fileName("exposure", O.name) .. ".bin", exposure.serialize(O.acc))
end

local function sampleTask(name: string)
	tasks.spawn("sample:" .. name, function()
		local O = outputs[name]
		if not O or not O.layout then
			return
		end
		O.lastSample = os.time()
		if locked() then
			return
		end
		local out, bar = outputInfo(name), barInfo()
		if not out then
			return
		end
		local geom = util.captureGeometry(out, bar)
		local img = capture.grab(geom.geometry, geom.transpose)
		if not img or exposure.isBlank(img, O.info and O.info.bright) then
			noctalia.log("pixel-shift: sample skipped on " .. name .. " (no capture or blank output)")
			return
		end
		if img.w ~= O.layout.w or img.h ~= O.layout.h then
			noctalia.log("pixel-shift: sample size changed on " .. name .. ", measuring again")
			O.needsScan, O.retryAt = true, 0
			return
		end
		local now = os.time()
		local offs = if saved.paused then {} else schedule.offsets(activeStrategy(name), spacersOn(name), now, setting("step_minutes", 4))
		local vRows = if vertical.active() and lastVertical > 0 then math.floor(lastVertical * O.layout.scale + 0.5) else 0
		local back = exposure.unshift(wear.linearFromRgb8(img), O.layout, util.displacements(O.layout, offs), vRows)
		local backL = image.luma(back)
		if not exposure.matchesBaseline(backL, O.baseL, O.layout) then
			-- something covers the bar, or it looks different now; measure again
			-- only when several samples in a row show the same picture
			local agrees = O.mismatchRef ~= nil and exposure.matchesBaseline(backL, O.mismatchRef, O.layout)
			local n, rescan = decide.mismatch(O.mismatches, agrees)
			O.mismatches = n
			O.mismatchRef = if rescan then nil elseif agrees then O.mismatchRef else backL
			if rescan and not O.needsScan then
				O.needsScan, O.retryAt, O.mismatchScan = true, 0, true
			end
			noctalia.log(`pixel-shift: sample on {name} does not match the measured bar{if rescan then ", measuring again" else ""}`)
			return
		end
		if O.mismatchScan then
			O.needsScan, O.mismatchScan, O.failures = false, false, 0 -- the bar is back as measured
		end
		O.mismatches, O.mismatchRef = 0, nil
		O.lastCapture = img
		exposure.add(O.acc, back, now)
		if decide.persistExposure(O.acc.n) then
			saveExposure(O)
		end
		if O.acc.n == MIN_SAMPLES or (O.acc.n > MIN_SAMPLES and O.acc.n % 12 == 0) then
			rebuildLayers(O)
		end
		labDirty = true
		dataDirty = true
	end)
end

-- optimiser --------------------------------------------------------------------
local function startOptimize(name: string)
	local O = outputs[name]
	if not O or not O.layers then
		return
	end
	O.needsOptimize = false
	if not decide.anyMoving(O.layout) then
		return -- nothing to optimise; the lab explains why
	end
	local maxV = if allowVerticalNow() then 2 else 0
	local ok, opt = pcall(optimize.new, { layers = O.layers, layout = O.layout, rref = O.rref, maxShift = setting("max_shift", 16), maxV = maxV })
	if not ok then
		noctalia.log(`pixel-shift: optimiser could not start on {name}: {tostring(opt)}`)
		setStatus({ kind = "error", message = tostring(opt) })
		return
	end
	optimizer = { name = name, started = os.clock(), allowVertical = maxV > 0, opt = opt }
	setStatus({ kind = "optimizing", output = name, progress = 0 })
end

local function finishOptimize()
	local run = optimizer
	optimizer = nil
	local O = outputs[run.name]
	if run.opt.error then
		noctalia.log("pixel-shift: optimiser error: " .. run.opt.error)
		setStatus({ kind = "error", message = run.opt.error })
		return
	end
	if not O then
		return setStatus({ kind = "idle" })
	end
	O.result = {
		entries = run.opt.entries,
		budgets = run.opt.budgets,
		evals = run.opt.evals,
		at = os.time(),
		seconds = run.cpu or 0, -- time spent inside the optimiser slices
		allowVertical = run.allowVertical,
	}
	noctalia.log(`pixel-shift: optimized {run.name}: {#O.result.entries} strategies, {O.result.evals} evaluations, {string.format("%.1f", O.result.seconds)} s in {run.steps or 0} slices`)
	local meta = saved.outputs[run.name] or {}
	saved.outputs[run.name] = meta
	meta.result = O.result
	if saved.auto and decide.autoApply(O.layout) then
		local level = decide.autoLevel(meta.strategy, saved.lambdaT)
		local e = optimize.pick(O.result.entries, optimize.lambdaFromSlider(level), run.allowVertical)
		if e then
			applyStrategy(run.name, { ranges = e.ranges, vertical = e.V, lambdaT = level })
		end
	end
	O.preview = nil
	persist()
	setStatus({ kind = "idle" })
end

-- output bookkeeping -------------------------------------------------------------
local function refreshOutputs()
	for _, info in pairs(spacers) do
		if info.output ~= "" and not outputs[info.output] then
			outputs[info.output] = newOutput(info.output)
		end
	end
	for name in pairs(outputs) do
		if #spacersOn(name) == 0 then
			outputs[name] = nil
		end
	end
	local bar = barInfo()
	for name, O in pairs(outputs) do
		local out = outputInfo(name)
		if out then
			local fp = fingerprintFor(name, bar, out)
			if O.fp ~= fp and not tasks.running("restore:" .. name) then
				O.fp = fp
				tasks.spawn("restore:" .. name, function()
					if not restore(O, fp) then
						-- a bar not measured yet: now, and with a fresh backoff
						O.needsScan, O.retryAt, O.failures, O.mismatchScan = true, 0, 0, false
					elseif not decide.anyMoving(O.layout) then
						O.needsScan, O.failures = true, 1
						O.retryAt = os.time() + decide.backoff(1)
					else
						O.needsScan, O.failures = false, 0
						O.needsOptimize = O.result == nil
					end
				end)
			end
		end
	end
end

-- lab -----------------------------------------------------------------------------
local SPACER_TYPE = "mgeldi/pixel-shift:spacer"

-- Spacers configured where they cannot move anything, for the lab's advice.
local function misplacedSpacers(bar)
	return decide.placement({ start = bar.layout[1], center = bar.layout[2], ["end"] = bar.layout[3] }, function(n)
		return n == SPACER_TYPE or noctalia.getSetting(`widget.{n}.type`) == SPACER_TYPE
	end)
end

-- An anchored centre widget pins the whole centre section, so the centre
-- spacers cannot move it. Returns that widget's name for the lab's hint.
local function anchoredCenterWidget(bar): string?
	local center = bar.layout[2]
	if type(center) ~= "table" then
		return nil
	end
	for _, name in ipairs(center) do
		if type(name) == "string" and noctalia.getSetting(`widget.{name}.anchor`) == true then
			return name
		end
	end
	return nil
end

-- The lab's advice about the bar config. Noctalia logs a warning for every
-- lookup of a widget key that is not set, so this is read again only when the
-- bar's sections change, or after a minute, never on every lab render.
local barAdviceCache = { key = nil, at = 0, anchor = nil, placement = {} }
local function barAdvice()
	local bar = barInfo()
	local key = util.stableEncode({ bar.name, bar.layout[1], bar.layout[2], bar.layout[3] })
	local now = os.time()
	if key ~= barAdviceCache.key or now - barAdviceCache.at >= 60 then
		barAdviceCache = { key = key, at = now, anchor = anchoredCenterWidget(bar), placement = misplacedSpacers(bar) }
	end
	return barAdviceCache
end

local function renderLab()
	local names = {}
	for name in pairs(outputs) do
		table.insert(names, name)
	end
	table.sort(names)
	if ui.output == nil or outputs[ui.output] == nil then
		ui.output = names[1]
	end
	local count = 0
	for _ in pairs(spacers) do
		count += 1
	end
	local advice = barAdvice()
	local st = table.clone(status)
	if optimizer then
		st.progress, st.best = optimizer.opt.progress, optimizer.opt.best
	end
	local model = {
		stamp = noctalia.nowMs(),
		status = st,
		outputs = names,
		ui = table.clone(ui),
		paused = saved.paused,
		auto = saved.auto,
		lambdaT = saved.lambdaT,
		allowVertical = saved.allowVertical,
		verticalError = errors.vertical == true,
		scanError = errors.scan,
		grim = capture.available(),
		spacerCount = count,
		anchor = advice.anchor,
		placement = advice.placement,
	}
	local O = ui.output and outputs[ui.output]
	if not dataDirty and lastData then
		model.data = lastData
	elseif O and O.layout and O.layers then
		local meta = saved.outputs[ui.output] or {}
		local active = activeStrategy(ui.output)
		local ok, data = pcall(labmodel.build, O, ui, {
			primary = themeHex,
			profile = profileName(),
			preview = O.preview or active,
			active = active,
			previewing = O.preview ~= nil,
			result = O.result,
			allowVertical = allowVerticalNow(),
			lambdaT = saved.lambdaT,
			maxShift = setting("max_shift", 16),
			stepMinutes = setting("step_minutes", 4),
			canRevert = meta.history ~= nil and #meta.history > 0,
		})
		if ok then
			model.data = data
			lastData = data
			dataDirty = false
		else
			noctalia.log("pixel-shift: lab render failed: " .. tostring(data))
		end
	end
	noctalia.state.set("lab:model", model)
end

local function setAllowVertical(on: boolean)
	errors.vertical = nil
	saved.allowVertical = on
	if on then
		refreshVerticalBase() -- now if the config allows, else within a few seconds
	else
		saved.verticalBase = nil -- read again next time: the bar may change meanwhile
		vertical.clear()
		lastVertical = 0
		verticalCheck = nil
	end
	persist()
	for _, O in pairs(outputs) do
		O.needsOptimize = true
	end
end

local function setPaused(p: boolean)
	saved.paused = p
	persist()
	noctalia.state.set("paused", p)
	publishWidths(true)
	labDirty = true
	dataDirty = true
end

local function handle(cmd: string, arg)
	if cmd ~= "output" then
		ui.output = decide.pickOutput(ui.output, outputs) -- scripts may act before the lab opened
	end
	local name = ui.output
	local O = name and outputs[name]
	if cmd == "view" or cmd == "mode" then
		ui[cmd] = arg
	elseif cmd == "hotspot" then
		ui.hotspot = tonumber(arg) or 1
	elseif cmd == "output" then
		ui.output, ui.hotspot = arg, 1
	elseif cmd == "rescan" then
		if O then
			O.needsScan, O.retryAt, O.failures, O.mismatchScan = true, 0, 0, false
		end
	elseif cmd == "optimize" then
		local target = (type(arg) == "string" and outputs[arg]) or O
		if target then
			target.needsOptimize = true
		end
	elseif cmd == "cancel" then
		optimizer = nil
		setStatus({ kind = "idle" })
	elseif cmd == "auto" then
		saved.auto = arg == true
		if O then
			O.preview = nil
			if saved.auto then
				previewFromLambda(name)
			end
		end
		persist()
	elseif cmd == "lambda" then
		saved.lambdaT = math.clamp(tonumber(arg) or saved.lambdaT, 0, 1)
		persist()
		if name then
			previewFromLambda(name)
		end
	elseif cmd == "range" and O and type(arg) == "table" then
		local p = O.preview or activeStrategy(name)
		O.preview = { ranges = table.clone(p.ranges), vertical = p.vertical or 0 }
		O.preview.ranges[arg.id] = math.clamp(math.floor(tonumber(arg.value) or 0), 0, setting("max_shift", 16))
	elseif cmd == "verticalRange" and O then
		local p = O.preview or activeStrategy(name)
		O.preview = { ranges = table.clone(p.ranges), vertical = math.clamp(math.floor(tonumber(arg) or 0), 0, 2) }
	elseif cmd == "allowVertical" then
		setAllowVertical(arg == true)
	elseif cmd == "apply" then
		if O and O.preview then
			applyStrategy(name, O.preview)
			O.preview = nil
		end
	elseif cmd == "revert" then
		local meta = name and saved.outputs[name]
		if meta and meta.history and #meta.history > 0 then
			local prev = table.remove(meta.history, 1)
			if prev.lambdaT then
				saved.lambdaT = prev.lambdaT
			end
			applyStrategy(name, prev, false)
			if O then
				O.preview = nil
			end
		end
	elseif cmd == "toggle" then
		setPaused(not saved.paused)
	elseif cmd == "pause" or cmd == "resume" then
		setPaused(cmd == "pause")
	elseif cmd == "open" then
		labOpen = arg ~= false
		if labOpen and not tasks.running("theme") then
			tasks.spawn("theme", function()
				local hex = theme.resolve(ui.output)
				if hex ~= themeHex then
					themeHex = hex
					dataDirty = true
				end
				labDirty = true
				dataDirty = true
			end)
		end
	elseif cmd == "openBarSettings" then
		noctalia.runAsync({ "noctalia", "msg", "settings-open", "bar" })
	end
	labDirty = true
	dataDirty = true
end

-- wiring ----------------------------------------------------------------------------
noctalia.state.watch("spacer:hello", function(v)
	if type(v) ~= "table" or type(v.id) ~= "string" then
		return
	end
	local prev = spacers[v.id]
	spacers[v.id] = { output = v.output or "", vertical = v.vertical == true, t = os.time() }
	if not prev or prev.output ~= spacers[v.id].output then
		spacerChangedAt, fingerprintDue = os.time(), true
		publishKnown()
		publishWidths(true)
	end
end)

noctalia.state.watch("spacer:bye", function(v)
	if type(v) == "table" and spacers[v.id] then
		spacers[v.id] = nil
		spacerChangedAt, fingerprintDue = os.time(), true
		publishKnown()
	end
end)

noctalia.state.watch("lab:cmd", function(c)
	if type(c) ~= "table" or c.seq == nil or c.seq == lastCmd then
		return
	end
	lastCmd = c.seq
	handle(c.cmd, c.arg)
end)

function onIpc(event, payload)
	if event == "debug" then
		local ids = {}
		for id, info in pairs(spacers) do
			table.insert(ids, id .. "@" .. info.output)
		end
		local outs = {}
		for name, O in pairs(outputs) do
			table.insert(outs, `{name}: fp={tostring(O.fp)} layout={O.layout ~= nil} scan={O.needsScan} opt={O.needsOptimize} retry={O.retryAt}`)
		end
		local ws = {}
		for id, v in pairs(widths) do
			table.insert(ws, `{id}={v}`)
		end
		table.sort(ws)
		noctalia.log(`pixel-shift debug: spacers=[{table.concat(ids, ", ")}] outputs=[{table.concat(outs, "; ")}] status={status.kind} tasks={tasks.active()} optimizer={optimizer ~= nil} widths=[{table.concat(ws, ", ")}]`)
		return
	end
	if event == "pause" or event == "resume" or event == "toggle" or event == "rescan" or event == "optimize" then
		handle(event, payload)
	elseif event == "view" or event == "mode" or event == "output" or event == "hotspot" then
		handle(event, payload) -- drive the lab from scripts
	elseif event == "lambda" then
		handle("lambda", tonumber(payload)) -- protection level 0 (calm) .. 1 (max); "apply" makes it active
	elseif event == "apply" or event == "revert" then
		handle(event, nil)
	elseif event == "allow-vertical" then
		handle("allowVertical", payload == "on" or payload == "true")
	elseif event == "sample" then
		for name, O in pairs(outputs) do
			if O.layout then
				sampleTask(name)
			end
		end
	elseif event == "lab" then
		noctalia.togglePanel("mgeldi/pixel-shift:lab")
	end
end

function onConfigChanged()
	for _, O in pairs(outputs) do
		if O.layout then
			rebuildLayersAsync(O)
			O.needsOptimize = true
		end
	end
end

function onOutputsChanged()
	fingerprintDue = true
end

function onExit(_signal, reason)
	if reason ~= "reload" then
		vertical.clear()
	end
end

function update()
	local now = os.time()
	sliceStart = os.clock()
	tasks.tick()
	if optimizer then
		local left = math.max(1, OPT_SLICE_MS - (os.clock() - sliceStart) * 1000)
		sliceStart = os.clock()
		local stepDone = optimizer.opt:step(left)
		optimizer.cpu = (optimizer.cpu or 0) + (os.clock() - sliceStart)
		optimizer.steps = (optimizer.steps or 0) + 1
		if stepDone then
			finishOptimize()
		elseif now ~= lastSlow then
			labDirty = true -- progress only: the lab reuses its images
		end
	end
	if now ~= lastSlow then
		lastSlow = now
		local pruned, changed = util.pruneRegistry(spacers, now, STALE)
		if changed then
			spacers = pruned
			spacerChangedAt, fingerprintDue = now, true
			publishKnown()
		end
		-- right after a vertical step the config still reloads: bar values,
		-- fingerprints and captures wait until it has settled
		local settled = vertical.settled()
		if settled and now - spacerChangedAt >= 3 and (fingerprintDue or now - lastFingerprint >= 60) then
			lastFingerprint, fingerprintDue = now, false
			refreshOutputs()
		end
		if settled and not tasks.active() and not optimizer then
			local today = os.date("%Y-%m-%d", now)
			if tonumber(os.date("%H", now)) >= 4 and saved.lastNightly ~= today then
				saved.lastNightly = today
				persist()
				for _, O in pairs(outputs) do
					if O.acc and O.acc.n >= MIN_SAMPLES then
						rebuildLayersAsync(O)
						O.needsOptimize = true
					end
				end
			end
			local every = setting("sample_minutes", 10) * 60
			for name, O in pairs(outputs) do
				if O.needsScan and O.retryAt <= now then
					if capture.available() then
						scanTask(name)
					end
					break
				elseif O.needsOptimize and O.layers and not verticalPending() then
					startOptimize(name)
					break
				elseif O.layout and now - O.lastSample >= every then
					sampleTask(name)
					break
				end
			end
		end
		if not forced then
			publishWidths(false)
		end
		playVertical(now)
	end
	if labOpen and labDirty and not tasks.active() then
		labDirty = false
		tasks.spawn("lab", renderLab)
	end
	noctalia.setUpdateInterval(if optimizer or tasks.active() then 33 else 1000)
end

-- start ---------------------------------------------------------------------------
if vertical.active() and not saved.allowVertical then
	vertical.clear() -- stale file from a crash
end
noctalia.state.set("lab:model", nil) -- its image paths die with cleanRenders()
store.cleanRenders()
noctalia.state.set("paused", saved.paused)
noctalia.state.set("engine:epoch", noctalia.nowMs())
noctalia.setUpdateInterval(250)
