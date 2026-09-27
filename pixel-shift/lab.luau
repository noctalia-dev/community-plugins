--!nonstrict
-- Burn-in Lab. Pure presentation: renders the model the engine publishes in
-- "lab:model" and sends every action back through "lab:cmd".
--
-- Reading order: where (the whole bar) -> the spot up close and the result
-- -> why and what to change (hotspots) -> adjust (strategy) -> apply.

local model = noctalia.state.get("lab:model")
local draft = {} -- slider values while a drag is in progress
local seqN = 0
local render

-- spacing rhythm (px): inside a group / between related parts / between regions
local TIGHT, NEAR, REGION = 6, 12, 16
local BLOCK = 14 -- between blocks inside one card
local CLEAR = "#00000000"
local PIN_INK = "#15151a" -- pin numbers on the glow
local SIDE_W = 352 -- sidebar card; its content is 328 wide (the risk scale)

-- type scale: result 28, panel title 16, section 13, body 12.5, meta 11
local function tr(key: string, subst): string
	return noctalia.tr(key, subst)
end

local function send(cmd: string, arg)
	seqN += 1
	noctalia.state.set("lab:cmd", { seq = `lab-{noctalia.nowMs()}-{seqN}`, cmd = cmd, arg = arg })
end

-- Selections show at once; the images follow when the engine has rendered
-- them. A model rendered after the click replaces every pending choice.
local pending, pendingAt = {}, 0

local function current(m, field: string)
	local v = pending[field]
	if v ~= nil then
		return v
	end
	return m.ui[field]
end

local function choose(field: string, value)
	pending[field] = value
	pendingAt = noctalia.nowMs()
	send(field, value)
	if model then
		render()
	end
end

local function round(x: number): number
	return math.floor(x + 0.5)
end

local function meta(t: string, color: string?)
	return ui.label({ text = t, fontSize = 11, color = color or "on_surface_variant" })
end

local function body(t: string, width: number?, color: string?)
	return ui.label({ text = t, fontSize = 12.5, color = color or "on_surface", maxWidth = width, maxLines = 4 })
end

local function note(t: string, width: number, color: string?)
	return ui.label({ text = t, fontSize = 11, color = color or "on_surface_variant", maxWidth = width, maxLines = 3 })
end

local function section(t: string)
	return ui.label({ text = t, fontSize = 13, fontWeight = "semibold", color = "on_surface_variant" })
end

local function card(children, props)
	props = props or {}
	props.fill = props.fill or "surface_variant"
	props.radius = props.radius or 14
	props.padding = props.padding or NEAR
	props.gap = props.gap or 10
	return ui.column(props, children)
end

-- A segmented control that marks the choice with a neutral thumb, so the
-- accent colour stays reserved for the one action that commits (Apply).
-- Noctalia keeps a row's fill when a later render leaves it out, so both
-- states set it.
local function segmented(options, value, field: string, onCard: boolean?)
	local items = {}
	for _, o in ipairs(options) do
		local on = o.value == value
		table.insert(items, ui.row({
			paddingH = 12,
			paddingV = 6,
			radius = 999,
			align = "center",
			fill = if on then "on_surface/0.14" else CLEAR,
			onClick = function()
				if not on then
					choose(field, o.value)
				end
			end,
		}, {
			ui.label({
				text = o.label,
				fontSize = 12.5,
				fontWeight = if on then "semibold" else "normal",
				color = if on then "on_surface" else "on_surface_variant",
			}),
		}))
	end
	return ui.row({ fill = if onCard then "surface" else "surface_variant", radius = 999, padding = 3, gap = 2, align = "center" }, items)
end

-- Hotspot pins: the glow's strength follows the spot's level; spots
-- shifting cannot help (changing content, outside the bar) stay neutral.
local LEVEL_ALPHA = { high = "", medium = "b3", low = "73" }

local function pin(h, glow: string, selected: boolean)
	local soft = h.cause == "outside" or h.cause == "dynamic"
	return ui.row({
		width = 22,
		height = 22,
		radius = 11,
		fill = if soft then "on_surface_variant/0.35" else glow .. (LEVEL_ALPHA[h.level or "low"] or ""),
		border = if selected then "on_surface" else CLEAR,
		borderWidth = 2,
		align = "center",
		justify = "center",
		onClick = function()
			choose("hotspot", h.n)
		end,
	}, { ui.label({ text = tostring(h.n), fontSize = 11, fontWeight = "bold", color = if soft then "on_surface" else PIN_INK }) })
end

-- Text on a glow-tinted fill uses the foreground colour: readable in light
-- themes too, where the glow itself is pale.
local function tag(t: string, glow: string, soft: boolean?)
	return ui.row({ fill = if soft then "surface" else glow .. "33", radius = 6, paddingH = 7, paddingV = 2 }, {
		ui.label({ text = t, fontSize = 11, color = if soft then "on_surface_variant" else "on_surface" }),
	})
end

local function pickName(t: number): string
	if t < 0.2 then
		return "calm"
	elseif t < 0.55 then
		return "balanced"
	elseif t < 0.85 then
		return "strong"
	end
	return "max"
end

local function exposureText(e): string
	if e.n <= 0 then
		return tr("lab.exposure.none")
	elseif e.n == 1 then
		return tr("lab.exposure.first")
	elseif e.hours < 0.1 then
		return noctalia.trp("lab.exposure.count", e.n, { count = e.n })
	end
	return noctalia.trp("lab.exposure.span", e.n, { count = e.n, hours = string.format("%.1f", e.hours) })
end

-- header (fixed above the scrolling content) --------------------------------------
local function header(m)
	local d = m and m.data
	local items = { ui.label({ text = tr("lab.title"), fontSize = 16, fontWeight = "semibold", color = "on_surface" }) }
	if d and d.info then
		table.insert(items, meta(`{current(m, "output")} · {d.info.width} × {d.info.thickness} · {exposureText(d.exposure)}`))
	end
	table.insert(items, ui.spacer({ flexGrow = 1 }))
	if m and #m.outputs > 1 then
		local opts = {}
		for _, name in ipairs(m.outputs) do
			table.insert(opts, { label = name, value = name })
		end
		table.insert(items, segmented(opts, current(m, "output"), "output"))
	end
	if d then
		table.insert(items, segmented({
			{ label = tr("lab.view.bar"), value = "bar" },
			{ label = tr("lab.view.ghost"), value = "ghost" },
			{ label = tr("lab.view.risk"), value = "risk" },
		}, current(m, "view"), "view"))
		table.insert(items, ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("lab.rescan"), onClick = function()
			send("rescan")
		end }))
	end
	table.insert(items, ui.button({ glyph = "close", variant = "ghost", tooltip = tr("lab.close"), onClick = function()
		panel.close()
	end }))
	return ui.row({ align = "center", gap = 10 }, items)
end

-- overview: the whole bar as two exact halves ------------------------------------
local function pinRow(hotspots, pins, row: number, width: number, glow: string, chosen: number)
	local list = {}
	for _, p in ipairs(pins) do
		if p.row == row then
			table.insert(list, p)
		end
	end
	table.sort(list, function(a, b)
		return a.x < b.x
	end)
	local children, cursor = {}, 0
	for _, p in ipairs(list) do
		local left = math.clamp(round(p.x - 11), cursor, math.max(cursor, width - 22))
		if left > cursor then
			table.insert(children, ui.box({ width = left - cursor, height = 1, fill = CLEAR }))
		end
		table.insert(children, pin(hotspots[p.n] or { n = p.n }, glow, p.n == chosen))
		cursor = left + 22
	end
	return ui.row({ height = 22, width = width, align = "center" }, children)
end

-- Are the images behind the current selection still being rendered?
local function updating(m, d): boolean
	if next(pending) ~= nil then
		return true
	end
	local st = d.state
	return st ~= nil and (st.view ~= m.ui.view or st.mode ~= m.ui.mode or st.output ~= m.ui.output)
end

local function overview(m, d)
	local o = d.overview
	local chosen = current(m, "hotspot")
	local head = {
		section(tr("lab.overview")),
		meta(tr("lab.view_note." .. current(m, "view"))),
		ui.spacer({ flexGrow = 1 }),
	}
	if updating(m, d) then
		table.insert(head, meta(tr("lab.updating")))
	end
	-- no shift / with strategy changes this view only, so it lives here
	table.insert(head, segmented({
		{ label = tr("lab.mode.none"), value = "none" },
		{ label = tr("lab.mode.strategy"), value = "strategy" },
	}, current(m, "mode"), "mode", true))
	return card({
		ui.row({ gap = 10, align = "center" }, head),
		ui.column({ gap = 2, align = "start" }, {
			pinRow(d.hotspots, o.pins, 1, o.w, d.glow, chosen),
			ui.image({ path = o.left, width = o.w, height = o.h, fit = "stretch", radius = 6 }),
			pinRow(d.hotspots, o.pins, 2, o.w, d.glow, chosen),
			ui.image({ path = o.right, width = o.w, height = o.h, fit = "stretch", radius = 6 }),
		}),
	}, { gap = 8 })
end

-- inspector: the selected spot up close, before and after -------------------------
local function inspector(m, d)
	local i = d.inspector
	local spot = i.n and d.hotspots[i.n]
	local title = if spot
		then tr("lab.inspect_title", { n = spot.n, side = tr("hotspot.side." .. spot.side) })
		else tr("lab.inspect_center")
	local change = {}
	if spot then
		table.insert(change, meta(tr("lab.spot_change", { a = round(spot.peakNone or 0), b = round(spot.peak) }), "on_surface"))
	end
	return card({
		ui.row({ gap = 8, align = "center" }, { section(title), ui.spacer({ flexGrow = 1 }), meta(tr("lab.zoom", { zoom = i.zoom })) }),
		ui.column({ gap = TIGHT, align = "start" }, {
			meta(tr("lab.strip_none")),
			ui.image({ path = i.none, width = i.w, height = i.h, fit = "stretch", radius = 6 }),
		}),
		ui.column({ gap = TIGHT, align = "start" }, {
			ui.row({ gap = 8, align = "center" }, { meta(tr("lab.strip_strategy")), table.unpack(change) }),
			ui.image({ path = i.strategy, width = i.w, height = i.h, fit = "stretch", radius = 6 }),
		}),
		ui.spacer({ flexGrow = 1 }),
		ui.row({ gap = 8, align = "center" }, {
			ui.image({ path = d.legend, width = 48, height = 6, fit = "stretch", radius = 3 }),
			meta(tr("lab.glow_legend")),
		}),
	}, { gap = BLOCK, flexGrow = 1 })
end

-- result: the two scores on one scale ---------------------------------------------
local function result(d)
	local W = 328
	local strat, none = d.score.strategy, d.score.none
	local function at(v: number): number
		return math.clamp(v, 0, 100) / 100 * W
	end
	local sx, nx = at(strat), at(none)
	-- the two value labels share one row, each centred on its tick when there is room
	local sLabel = ui.label({ text = tostring(round(strat)), fontSize = 11, fontWeight = "semibold", color = "on_surface", width = 32, textAlign = "center" })
	local nLabel = ui.label({ text = tostring(round(none)), fontSize = 11, color = "on_surface_variant", width = 32, textAlign = "center" })
	local a = math.clamp(round(sx) - 16, 0, W - 32)
	local b = math.clamp(round(nx) - 16, a + 34, math.max(a + 34, W - 32))
	return ui.column({ gap = TIGHT, align = "start" }, {
		section(tr("lab.risk_title")),
		ui.row({ gap = 8, align = "end" }, {
			ui.label({ text = tostring(round(strat)), fontSize = 28, fontWeight = "bold", color = "on_surface" }),
			ui.column({ gap = 0, align = "start" }, {
				body(tr("lab.with_strategy"), nil, "on_surface_variant"),
				meta(tr("lab.without_shift", { value = round(none) })),
			}),
		}),
		ui.column({ gap = 2, align = "start" }, {
			ui.row({ width = W, height = 16, align = "center" }, {
				ui.box({ width = a, height = 1, fill = CLEAR }),
				sLabel,
				ui.box({ width = math.max(b - a - 32, 0), height = 1, fill = CLEAR }),
				nLabel,
			}),
			ui.row({ width = W, height = 8 }, {
				ui.box({ width = math.clamp(round(sx) - 1, 0, W - 2), height = 1, fill = CLEAR }),
				ui.box({ width = 2, height = 8, radius = 1, fill = "on_surface" }),
				ui.box({ width = math.max(math.clamp(round(nx) - 1, 0, W - 2) - math.clamp(round(sx) - 1, 0, W - 2) - 2, 0), height = 1, fill = CLEAR }),
				ui.box({ width = 2, height = 8, radius = 1, fill = "on_surface_variant" }),
			}),
			ui.image({ path = d.legend, width = W, height = 8, fit = "stretch", radius = 4 }),
			ui.row({ width = W, align = "center" }, { meta(tr("lab.scale_start")), ui.spacer({ flexGrow = 1 }), meta(tr("lab.scale_end")) }),
		}),
	})
end

-- Spacers configured where they cannot move anything, named with the fix.
local function placementNotes(m, width: number)
	local out = {}
	for _, p in ipairs(m.placement or {}) do
		table.insert(out, note(tr("lab.placement." .. p.want, { widget = p.widget }), width, "error"))
	end
	return out
end

local function alert(t: string, width: number, action)
	local items = {
		ui.row({ gap = 6, align = "start" }, {
			ui.glyph({ name = "alert-triangle", size = 13, color = "on_surface_variant" }),
			note(t, width - 19),
		}),
	}
	if action then
		table.insert(items, action)
	end
	return ui.column({ gap = TIGHT, align = "start" }, items)
end

-- hotspots: one line each; the selected one opens with where, why and a fix -------
local function hotspotRow(m, d, h, selected: boolean)
	local soft = h.cause == "outside" or h.cause == "dynamic"
	local line = {
		pin(h, d.glow, selected),
		ui.image({ path = h.thumb, width = 64, height = 24, fit = "stretch", radius = 4 }),
		ui.label({
			text = tr("cause." .. h.cause),
			fontSize = 12.5,
			fontWeight = if selected then "semibold" else "normal",
			color = if soft then "on_surface_variant" else "on_surface",
		}),
		ui.spacer({ flexGrow = 1 }),
		meta(tr("hotspot.level." .. (h.level or "low")), if h.level == "high" and not soft then "on_surface" else "on_surface_variant"),
	}
	local rows = { ui.row({ gap = 8, align = "center" }, line) }
	if selected then
		-- on the glow tint, secondary text uses the foreground colour
		local detail = {
			meta(tr("lab.spot_meta", { side = tr("hotspot.side." .. h.side), x0 = h.lx0, x1 = h.lx1, peak = round(h.peak) }), "on_surface"),
			note(tr("hint." .. h.cause), 290, "on_surface"),
		}
		if h.cause == "horizontal" and not m.allowVertical then
			table.insert(detail, ui.button({ text = tr("lab.hint_vertical"), variant = "ghost", controlSize = "sm", onClick = function()
				send("allowVertical", true)
			end }))
		end
		table.insert(rows, ui.column({ gap = 4, align = "start", paddingH = 30 }, detail))
	end
	return ui.column({
		gap = TIGHT,
		paddingH = 6,
		paddingV = 5,
		radius = 10,
		fill = if selected then d.glow .. "1f" else CLEAR, -- set both ways, see segmented()
		onClick = function()
			if not selected then
				choose("hotspot", h.n)
			end
		end,
	}, rows)
end

local function sidebar(m, d)
	local selected = current(m, "hotspot")
	local blocks = { result(d) }
	local notes = {}
	if d.approximate then
		table.insert(notes, alert(tr("lab.approximate"), 328, ui.button({ text = tr("lab.measure_again"), variant = "ghost", controlSize = "sm", onClick = function()
			send("rescan")
		end })))
	end
	if m.anchor then
		table.insert(notes, note(tr("lab.anchored", { widget = m.anchor }), 328, "error"))
	end
	for _, n in ipairs(placementNotes(m, 328)) do
		table.insert(notes, n)
	end
	if #d.idle > 0 then
		table.insert(notes, note(noctalia.trp("lab.moves_nothing", #d.idle, { count = #d.idle }), 328, "error"))
	end
	if #notes > 0 then
		table.insert(blocks, ui.column({ gap = TIGHT, align = "start" }, notes))
	end
	local list = { ui.row({ gap = 8, align = "center" }, { section(tr("lab.hotspots")), ui.spacer({ flexGrow = 1 }), meta(tr("lab.strongest_first")) }) }
	if #d.hotspots == 0 then
		table.insert(list, note(tr("lab.no_hotspots", { worst = round(d.worst or 0) }), 328))
	end
	for _, h in ipairs(d.hotspots) do
		table.insert(list, hotspotRow(m, d, h, h.n == selected))
	end
	table.insert(blocks, ui.column({ gap = 4 }, list))
	return card(blocks, { gap = BLOCK, width = SIDE_W })
end

-- strategy -------------------------------------------------------------------------
-- What runs on the bar now, or that the shown strategy is only a preview.
local function stateLine(m, d)
	local st = m.status or {}
	if st.kind == "optimizing" then
		return meta(tr("lab.optimizing", { percent = round((st.progress or 0) * 100) }))
	elseif d.previewing then
		return tag(tr("lab.preview"), d.glow)
	elseif d.liveSince then
		return ui.row({ gap = 4, align = "center" }, {
			ui.glyph({ name = "check", size = 13, color = "on_surface_variant" }),
			meta(tr("lab.live", { output = d.output or "", time = noctalia.formatTime(noctalia.timeFormat(), d.liveSince) })),
		})
	elseif d.status then
		return meta(tr("lab.optimized", {
			time = noctalia.formatTime(noctalia.timeFormat(), d.status.at),
			count = d.status.evals,
			seconds = string.format("%.1f", d.status.seconds),
		}))
	end
	return meta(tr("lab.not_optimized"))
end

-- Risk for every movement budget, one bar per budget (paired with the
-- vertical variant when it exists). The pick carries the glow; the first bar
-- restates the no-shift score, so the chart and the result read as one story.
local CHART_W, CHART_H = 500, 80
local RIGHT_W = 904 - CHART_W - REGION -- the strategy card's right column

local function barChart(d)
	local c = d.curve
	local n = #c.budgets
	local top = c.top or 1
	local paired = c.v ~= nil
	local barW = if paired then 12 else 20
	local groupW = math.floor(CHART_W / n)
	local muted, glowSoft = "on_surface_variant/0.45", d.glow .. "8c"

	local function bar(score: number, fill: string, label: string?, ink: string?)
		local height = math.max(3, round((score or 0) / top * (CHART_H - 18)))
		local children = {}
		if label then
			table.insert(children, ui.label({ text = label, fontSize = 11, fontWeight = "semibold", color = ink or "on_surface" }))
		end
		table.insert(children, ui.box({ width = barW, height = height, radius = 4, fill = fill }))
		return ui.column({ gap = 2, align = "center" }, children)
	end

	local groups = {}
	for i = 1, n do
		local picked = i == c.pick
		local bars = {}
		local hLabel = if picked and c.pickV == 0 then tostring(round(c.h[i])) elseif i == 1 then tostring(round(c.h[i])) else nil
		table.insert(bars, bar(c.h[i], if picked and c.pickV == 0 then d.glow else muted, hLabel, if picked then "on_surface" else "on_surface_variant"))
		if paired and c.v[i] then
			table.insert(bars, bar(c.v[i], if picked and c.pickV > 0 then d.glow else glowSoft, if picked and c.pickV > 0 then tostring(round(c.v[i])) else nil))
		end
		local label = if i == n then `{c.budgets[i]} px` else tostring(c.budgets[i])
		table.insert(groups, ui.column({ width = groupW, gap = 4, align = "center" }, {
			ui.row({ gap = 3, align = "end", height = CHART_H }, bars),
			ui.label({ text = label, fontSize = 11, fontWeight = if picked then "semibold" else "normal", color = if picked then "on_surface" else "on_surface_variant" }),
		}))
	end
	local rows = { ui.row({ width = CHART_W, align = "end" }, groups) }
	if paired then
		table.insert(rows, ui.row({ gap = NEAR, align = "center" }, {
			ui.row({ gap = 4, align = "center" }, { ui.box({ width = 10, height = 10, radius = 3, fill = muted }), meta(tr("lab.curve_h")) }),
			ui.row({ gap = 4, align = "center" }, { ui.box({ width = 10, height = 10, radius = 3, fill = glowSoft }), meta(tr("lab.curve_v")) }),
		}))
	end
	return ui.column({ gap = TIGHT, align = "start" }, rows)
end

local function curveBlock(m, d)
	local lambda = draft.lambda or round(m.lambdaT * 100)
	return ui.column({ gap = 10, width = CHART_W, align = "start" }, {
		meta(tr("lab.curve_title")),
		barChart(d),
		ui.row({ width = CHART_W, gap = 10, align = "center" }, {
			meta(tr("lab.calm")),
			ui.slider({
				min = 0,
				max = 100,
				step = 1,
				value = lambda,
				flexGrow = 1,
				onChange = function(v)
					draft.lambda = tonumber(v)
					render()
				end,
				onDragEnd = function()
					if draft.lambda then
						send("lambda", draft.lambda / 100)
						draft.lambda = nil
					end
				end,
			}),
			meta(tr("lab.max")),
		}),
	})
end

local function chips(d)
	local items = {}
	for _, c in ipairs(d.chips) do
		table.insert(items, tag(tr("lab.chip_px", { slot = tr("slot." .. c.slot), px = c.px }), d.glow, true))
	end
	if d.vertical > 0 then
		table.insert(items, tag(tr("lab.chip_vertical", { px = d.vertical }), d.glow, true))
	end
	local rowA, rowB = {}, {}
	for i, it in ipairs(items) do
		table.insert(if i <= 3 then rowA else rowB, it)
	end
	local rows = { meta(tr("lab.movement", { minutes = d.stepMinutes })), ui.row({ gap = TIGHT }, rowA) }
	if #rowB > 0 then
		table.insert(rows, ui.row({ gap = TIGHT }, rowB))
	end
	return ui.column({ gap = TIGHT, align = "start" }, rows)
end

local function verticalToggle(m)
	local items = {
		ui.row({ gap = 8, align = "center" }, {
			ui.toggle({ checked = m.allowVertical, onChange = function(v)
				send("allowVertical", v == "true")
			end }),
			body(tr("lab.allow_vertical")),
		}),
		note(tr("lab.allow_vertical_note"), RIGHT_W),
	}
	if m.verticalError then
		table.insert(items, note(tr("lab.vertical_error"), RIGHT_W, "error"))
	end
	return ui.column({ gap = 4 }, items)
end

-- The pick in words, from the chart: how far it moves and what more would buy.
local function pickSummary(m, d)
	local c = d.curve
	local t = (draft.lambda or round(m.lambdaT * 100)) / 100
	local name = tr("lab.pick_names." .. pickName(t))
	local px = c.pick and c.budgets[c.pick] or 0
	local title = if (c.pickV or 0) > 0
		then tr("lab.pick_title_v", { name = name, px = px, v = c.pickV })
		else tr("lab.pick_title", { name = name, px = px })
	local score, none = round(c.pickScore or d.score.strategy), round(d.score.none)
	local save = if c.nextPx then math.max(round((c.pickScore or 0) - (c.nextScore or 0)), 0) else 0
	local line = if not c.nextPx
		then tr("lab.pick_note_last", { px = px, score = score, none = none })
		elseif save < 1 then tr("lab.pick_note_flat", { px = px, score = score, none = none })
		else tr("lab.pick_note", { px = px, score = score, none = none, more = c.nextPx - px, save = save })
	return ui.column({ gap = 4, align = "start" }, {
		body(title, RIGHT_W, "on_surface"),
		note(line .. " " .. tr("lab.pick_note_tail"), RIGHT_W),
	})
end

local function slider(label: string, key: string, value: number, max: number, suffix: string, commit)
	local v = draft[key] or value
	return ui.row({ gap = 10, align = "center" }, {
		ui.label({ text = label, fontSize = 12.5, color = "on_surface_variant", width = 92 }),
		ui.slider({
			min = 0,
			max = max,
			step = 1,
			value = v,
			flexGrow = 1,
			onChange = function(x)
				draft[key] = tonumber(x)
				render()
			end,
			onDragEnd = function()
				if draft[key] then
					commit(draft[key])
					draft[key] = nil
				end
			end,
		}),
		ui.label({ text = string.format(suffix, v), fontSize = 12.5, color = "on_surface", width = 48 }),
	})
end

local function manualBlock(m, d)
	local rows = {}
	for _, s in ipairs(d.manual) do
		table.insert(rows, slider(tr("slot." .. s.slot), "range:" .. s.id, s.value, d.maxShift, "%d px", function(x)
			send("range", { id = s.id, value = x })
		end))
	end
	if m.allowVertical then
		table.insert(rows, slider(tr("lab.manual_vertical"), "vertical", d.vertical, 2, "±%d px", function(x)
			send("verticalRange", x)
		end))
	end
	return ui.column({ gap = 8, flexGrow = 1 }, rows)
end

local function strategyCard(m, d)
	local st = m.status or {}
	local head = {
		section(tr("lab.strategy")),
		segmented({ { label = tr("lab.auto"), value = true }, { label = tr("lab.manual"), value = false } }, if pending.auto ~= nil then pending.auto else m.auto, "auto", true),
		stateLine(m, d),
		ui.spacer({ flexGrow = 1 }),
	}
	if st.kind == "optimizing" then
		table.insert(head, ui.button({ text = tr("lab.cancel"), variant = "ghost", controlSize = "sm", onClick = function()
			send("cancel")
		end }))
	else
		table.insert(head, ui.button({ text = tr("lab.reoptimize"), variant = "ghost", controlSize = "sm", onClick = function()
			send("optimize")
		end }))
	end
	if d.canRevert and not d.previewing then
		table.insert(head, ui.button({ text = tr("lab.revert"), variant = "ghost", controlSize = "sm", tooltip = tr("lab.revert_tip"), onClick = function()
			send("revert")
		end }))
	end
	if d.previewing then
		-- the accent colour belongs to the one action that changes the bar
		table.insert(head, ui.button({ text = tr("lab.discard"), variant = "ghost", controlSize = "sm", onClick = function()
			send("discard")
		end }))
		table.insert(head, ui.button({ text = tr("lab.apply"), variant = "primary", controlSize = "sm", onClick = function()
			send("apply")
		end }))
	end

	local content
	if st.kind == "optimizing" then
		local rows = {
			ui.progress({ progress = st.progress or 0, fill = d.glow, track = "surface", height = 6, radius = 3 }),
			note(tr("lab.optimizing_note"), 860),
		}
		if st.best and st.best < 1e9 then
			table.insert(rows, meta(tr("lab.best_so_far", { score = round(st.best) })))
		end
		content = ui.column({ gap = TIGHT }, rows)
	elseif m.auto and d.curve and d.curve.budgets and d.curve.h then
		content = ui.row({ gap = REGION, align = "start" }, {
			curveBlock(m, d),
			ui.column({ gap = BLOCK, flexGrow = 1, align = "start" }, {
				pickSummary(m, d),
				chips(d),
				verticalToggle(m),
			}),
		})
	elseif m.auto then
		content = meta(tr("lab.not_optimized"))
	else
		content = ui.row({ gap = REGION, align = "start" }, {
			manualBlock(m, d),
			ui.column({ gap = BLOCK, width = RIGHT_W }, { chips(d), verticalToggle(m) }),
		})
	end
	return card({ ui.row({ gap = 10, align = "center" }, head), content }, { gap = NEAR })
end

-- states -------------------------------------------------------------------------
local function onboarding()
	return card({
		ui.label({ text = tr("lab.onboarding.title"), fontSize = 13, fontWeight = "semibold", color = "on_surface" }),
		body(tr("lab.onboarding.body"), 860, "on_surface_variant"),
		ui.markdown({ text = tr("lab.onboarding.steps") }),
		ui.row({ gap = 8 }, {
			ui.button({ text = tr("lab.onboarding.open_settings"), variant = "primary", onClick = function()
				send("openBarSettings")
			end }),
		}),
	}, { padding = 16, gap = NEAR })
end

local function banner(m)
	if m.paused then
		return card({
			ui.row({ gap = 10, align = "center" }, {
				body(tr("lab.paused")),
				ui.spacer({ flexGrow = 1 }),
				ui.button({ text = tr("lab.resume"), variant = "primary", controlSize = "sm", onClick = function()
					send("resume")
				end }),
			}),
		}, { padding = 10 })
	elseif m.status and m.status.kind == "scanning" then
		return card({ note(tr("lab.scanning"), 860) }, { padding = 10 })
	elseif m.status and m.status.kind == "error" then
		return card({ note(tr("lab.error", { message = m.status.message or "" }), 860, "error") }, { padding = 10 })
	end
	return nil
end

render = function()
	local m = model
	local children = {}
	if not m then
		table.insert(children, meta(tr("lab.starting")))
	elseif m.grim == false then
		table.insert(children, card({ note(tr("lab.no_grim"), 860, "error") }))
	elseif (m.spacerCount or 0) == 0 then
		table.insert(children, onboarding())
	else
		local b = banner(m)
		if b then
			table.insert(children, b)
		end
		local d = m.data
		if d then
			table.insert(children, overview(m, d))
			table.insert(children, ui.row({ gap = REGION, align = "stretch" }, { inspector(m, d), sidebar(m, d) }))
			table.insert(children, strategyCard(m, d))
		elseif not b then
			local items = placementNotes(m, 860)
			table.insert(items, 1, meta(tr("lab.waiting")))
			table.insert(children, card(items))
		end
	end
	-- the header stays put; only the cards below it scroll
	panel.render(ui.column({ gap = REGION, flexGrow = 1 }, {
		header(m),
		ui.scroll({ flexGrow = 1, gap = REGION }, children),
	}))
end

local isOpen = false

noctalia.state.watch("lab:model", function(v)
	model = v
	if v and (v.stamp or 0) >= pendingAt then
		pending = {} -- rendered after the last click: shows every choice
	end
	render()
end)

-- a restarted engine does not know the panel is open; tell it again
noctalia.state.watch("engine:epoch", function()
	if isOpen then
		send("open", true)
	end
end)

function onOpen()
	isOpen = true
	send("open", true)
	model = noctalia.state.get("lab:model")
	render()
end

function onClose()
	isOpen = false
	send("open", false)
end
