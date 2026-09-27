--!nonstrict
-- Burn-in Lab. Pure presentation: renders the model the engine publishes in
-- "lab:model" and sends every action back through "lab:cmd".
--
-- Reading order: result (score) -> where (overview, inspector) -> why and
-- what to change (hotspots) -> adjust (strategy) -> apply.

local model = noctalia.state.get("lab:model")
local draft = {} -- slider values while a drag is in progress
local seqN = 0
local render

-- spacing rhythm (px): inside a group / between related parts / between regions
local TIGHT, NEAR, REGION = 6, 12, 18

local function tr(key: string, subst): string
	return noctalia.tr(key, subst)
end

local function send(cmd: string, arg)
	seqN += 1
	noctalia.state.set("lab:cmd", { seq = `lab-{noctalia.nowMs()}-{seqN}`, cmd = cmd, arg = arg })
end

local function round(x: number): number
	return math.floor(x + 0.5)
end

local function caption(t: string)
	return ui.label({ text = t, fontSize = 11, color = "on_surface_variant" })
end

local function note(t: string, width: number, color: string?)
	return ui.label({ text = t, fontSize = 11.5, color = color or "on_surface_variant", maxWidth = width, maxLines = 4 })
end

-- onCard: chips inside a surface_variant card sit on the darker surface tone
local function chip(t: string, onCard: boolean?)
	return ui.row({ fill = if onCard then "surface" else "surface_variant", radius = 999, paddingH = 10, paddingV = 4, align = "center" }, {
		ui.label({ text = t, fontSize = 11.5, color = "on_surface_variant" }),
	})
end

local function card(children, props)
	props = props or {}
	props.fill = props.fill or "surface_variant"
	props.radius = props.radius or 14
	props.padding = props.padding or NEAR
	props.gap = props.gap or 10
	return ui.column(props, children)
end

local function segmented(options, current, cmd: string)
	local items = {}
	for _, o in ipairs(options) do
		local on = o.value == current
		table.insert(items, ui.button({
			text = o.label,
			controlSize = "sm",
			variant = if on then "primary" else "ghost",
			selected = on,
			onClick = function()
				send(cmd, o.value)
			end,
		}))
	end
	return ui.row({ fill = "surface_variant", radius = 999, padding = 3, gap = 2, align = "center" }, items)
end

local function pin(n: number, glow: string, selected: boolean)
	local props = {
		width = 20,
		height = 20,
		radius = 10,
		fill = glow,
		align = "center",
		justify = "center",
		onClick = function()
			send("hotspot", n)
		end,
	}
	if selected then
		props.border, props.borderWidth = "on_surface", 2
	end
	return ui.row(props, { ui.label({ text = tostring(n), fontSize = 11, fontWeight = "bold", color = "#15151a" }) })
end

local function tag(t: string, glow: string, soft: boolean?)
	return ui.row({ fill = if soft then "surface" else glow .. "2e", radius = 6, paddingH = 6, paddingV = 2 }, {
		ui.label({ text = t, fontSize = 11, color = if soft then "on_surface_variant" else glow }),
	})
end

local function deltaText(d): string
	local n, s = d.score.none, d.score.strategy
	if n <= 0 then
		return "0%"
	end
	return string.format("%+d%%", round((s - n) / n * 100))
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

-- header -------------------------------------------------------------------------
local function header(m)
	local d = m and m.data
	local items = { ui.label({ text = tr("lab.title"), fontSize = 16, fontWeight = "semibold", color = "on_surface" }) }
	if d and d.info then
		table.insert(items, chip(`{m.ui.output} · {d.info.width}×{d.info.thickness}`))
	end
	if d then
		local e = d.exposure
		table.insert(items, chip(if e.n > 0
			then noctalia.trp("lab.exposure.some", e.n, { count = e.n, hours = string.format("%.1f", e.hours) })
			else tr("lab.exposure.none")))
	end
	table.insert(items, ui.spacer({ flexGrow = 1 }))
	if m and #m.outputs > 1 then
		local opts = {}
		for _, name in ipairs(m.outputs) do
			table.insert(opts, { label = name, value = name })
		end
		table.insert(items, segmented(opts, m.ui.output, "output"))
	end
	if d then
		table.insert(items, segmented({
			{ label = tr("lab.view.bar"), value = "bar" },
			{ label = tr("lab.view.ghost"), value = "ghost" },
			{ label = tr("lab.view.risk"), value = "risk" },
		}, m.ui.view, "view"))
		table.insert(items, segmented({
			{ label = tr("lab.mode.none"), value = "none" },
			{ label = tr("lab.mode.strategy"), value = "strategy" },
		}, m.ui.mode, "mode"))
		table.insert(items, ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("lab.rescan"), onClick = function()
			send("rescan")
		end }))
	end
	table.insert(items, ui.button({ glyph = "close", variant = "ghost", tooltip = tr("lab.close"), onClick = function()
		panel.close()
	end }))
	return ui.row({ align = "center", gap = 10 }, items)
end

-- overview -----------------------------------------------------------------------
local function pinRow(pins, row: number, width: number, glow: string)
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
		local left = math.clamp(round(p.x - 10), cursor, math.max(cursor, width - 20))
		if left > cursor then
			table.insert(children, ui.box({ width = left - cursor, height = 1, fill = "#00000000" }))
		end
		table.insert(children, pin(p.n, glow, p.selected))
		cursor = left + 20
	end
	return ui.row({ height = 22, width = width, align = "center" }, children)
end

local function overview(d)
	local o = d.overview
	return ui.column({ gap = 4, align = "start" }, {
		caption(tr("lab.overview")),
		pinRow(o.pins, 1, o.w, d.glow),
		ui.image({ path = o.left, width = o.w, height = o.h, fit = "stretch", radius = 6 }),
		pinRow(o.pins, 2, o.w, d.glow),
		ui.image({ path = o.right, width = o.w, height = o.h, fit = "stretch", radius = 6 }),
	})
end

-- inspector ----------------------------------------------------------------------
local function inspector(d)
	local i = d.inspector
	local spot = i.n and d.hotspots[i.n]
	local title = if spot then tr("hotspot.side." .. spot.side) else tr("lab.inspect_center")
	return ui.column({ gap = TIGHT, width = 560, align = "start" }, {
		caption(tr("lab.inspect_none", { title = title, zoom = i.zoom })),
		ui.image({ path = i.none, width = i.w, height = i.h, fit = "stretch", radius = 6 }),
		ui.row({ gap = 8, align = "center" }, { caption(tr("lab.inspect_strategy")), tag(deltaText(d), d.glow) }),
		ui.image({ path = i.strategy, width = i.w, height = i.h, fit = "stretch", radius = 6 }),
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

-- sidebar: the result and its reasons in one surface -----------------------------
local function sidebar(m, d)
	local selected = m.ui.hotspot
	local items = {
		caption(tr("lab.risk_title")),
		ui.row({ gap = 10, align = "center" }, {
			ui.label({ text = `{round(d.score.none)} → {round(d.score.strategy)}`, fontSize = 28, fontWeight = "bold", color = "on_surface" }),
			tag(deltaText(d), d.glow),
		}),
		ui.row({ gap = TIGHT, align = "center" }, {
			caption(tr("lab.safe")),
			ui.image({ path = d.legend, width = 120, height = 8, fit = "stretch", radius = 4 }),
			caption(tr("lab.risky")),
		}),
	}
	if d.approximate then
		table.insert(items, note(tr("lab.approximate"), 320, "error"))
	end
	if m.anchor then
		table.insert(items, note(tr("lab.anchored", { widget = m.anchor }), 320, "error"))
	end
	for _, n in ipairs(placementNotes(m, 320)) do
		table.insert(items, n)
	end
	if #d.idle > 0 then
		table.insert(items, note(noctalia.trp("lab.moves_nothing", #d.idle, { count = #d.idle }), 320, "error"))
	end
	table.insert(items, ui.separator({ spacing = 2 }))
	if #d.hotspots == 0 then
		table.insert(items, note(tr("lab.no_hotspots"), 320))
	end
	for _, h in ipairs(d.hotspots) do
		local isSel = h.n == selected
		local body = {
			ui.row({ gap = 8, align = "center" }, {
				ui.label({
					text = tr("hotspot.range", { side = tr("hotspot.side." .. h.side), x0 = h.x0, x1 = h.x1 }),
					fontSize = 12.5,
					fontWeight = if isSel then "semibold" else "normal",
					color = "on_surface",
				}),
				tag(tr("cause." .. h.cause), d.glow, h.cause == "outside" or h.cause == "dynamic"),
			}),
		}
		if isSel then
			table.insert(body, note(tr("hint." .. h.cause), 280))
		end
		local props = { gap = 9, paddingH = 8, paddingV = 6, radius = 10, align = "start", onClick = function()
			send("hotspot", h.n)
		end }
		if isSel then
			props.fill = "surface"
		end
		table.insert(items, ui.row(props, { pin(h.n, d.glow, false), ui.column({ gap = 4, flexGrow = 1 }, body) }))
	end
	return card(items, { gap = 8 })
end

-- strategy -----------------------------------------------------------------------
local function statusLine(m, d)
	local st = m.status or {}
	if st.kind == "optimizing" then
		return caption(tr("lab.optimizing", { percent = round((st.progress or 0) * 100) }))
	elseif d.status then
		return ui.row({ gap = 4, align = "center" }, {
			ui.glyph({ name = "check", size = 13, color = "on_surface_variant" }),
			caption(tr("lab.optimized", {
				time = noctalia.formatTime(noctalia.timeFormat(), d.status.at),
				count = d.status.evals,
				seconds = string.format("%.1f", d.status.seconds),
			})),
		})
	end
	return caption(tr("lab.not_optimized"))
end

-- Risk for every movement budget, one bar per budget (paired with the
-- vertical variant when it exists). The auto pick carries the glow colour.
local CHART_W, CHART_H = 500, 100

local function barChart(d)
	local c = d.curve
	local n = #c.budgets
	local top = c.top or 1
	local paired = c.v ~= nil
	local barW = if paired then 12 else 20
	local groupW = math.floor(CHART_W / n)
	local muted, glowSoft = "on_surface_variant/0.3", d.glow .. "59"

	local function bar(score: number, fill: string, label: boolean)
		local height = math.max(3, round((score or 0) / top * (CHART_H - 20)))
		local children = {}
		if label then
			table.insert(children, ui.label({ text = tostring(round(score)), fontSize = 11, fontWeight = "semibold", color = d.glow }))
		end
		table.insert(children, ui.box({ width = barW, height = height, radius = 4, fill = fill }))
		return ui.column({ gap = 2, align = "center" }, children)
	end

	local groups = {}
	for i = 1, n do
		local picked = i == c.pick
		local bars = {}
		local hFill = if picked and c.pickV == 0 then d.glow else muted
		table.insert(bars, bar(c.h[i], hFill, picked and c.pickV == 0))
		if paired and c.v[i] then
			local vFill = if picked and c.pickV > 0 then d.glow else glowSoft
			table.insert(bars, bar(c.v[i], vFill, picked and c.pickV > 0))
		end
		local label = if i == n then `{c.budgets[i]} px` else tostring(c.budgets[i])
		table.insert(groups, ui.column({ width = groupW, gap = 4, align = "center" }, {
			ui.row({ gap = 3, align = "end", height = CHART_H }, bars),
			ui.label({ text = label, fontSize = 10.5, color = if picked then d.glow else "on_surface_variant" }),
		}))
	end
	local rows = { ui.row({ width = CHART_W, align = "end" }, groups) }
	if paired then
		table.insert(rows, ui.row({ gap = 12, align = "center" }, {
			ui.row({ gap = 4, align = "center" }, { ui.box({ width = 10, height = 10, radius = 3, fill = muted }), caption(tr("lab.curve_h")) }),
			ui.row({ gap = 4, align = "center" }, { ui.box({ width = 10, height = 10, radius = 3, fill = glowSoft }), caption(tr("lab.curve_v")) }),
		}))
	end
	return ui.column({ gap = TIGHT, align = "start" }, rows)
end

local function curveBlock(m, d)
	local lambda = draft.lambda or round(m.lambdaT * 100)
	return ui.column({ gap = 10, width = CHART_W, align = "start" }, {
		caption(tr("lab.curve_title")),
		barChart(d),
		ui.row({ width = CHART_W, gap = 10, align = "center" }, {
			caption(tr("lab.calm")),
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
			caption(tr("lab.max")),
		}),
	})
end

local function chips(d)
	local items = {}
	for _, c in ipairs(d.chips) do
		table.insert(items, chip(tr("lab.chip_px", { slot = tr("slot." .. c.slot), px = c.px }), true))
	end
	if d.vertical > 0 then
		table.insert(items, chip(tr("lab.chip_vertical", { px = d.vertical }), true))
	end
	table.insert(items, chip(tr("lab.chip_step", { minutes = d.stepMinutes }), true))
	local rowA, rowB = {}, {}
	for i, it in ipairs(items) do
		table.insert(if i <= 3 then rowA else rowB, it)
	end
	return ui.column({ gap = TIGHT, align = "start" }, { ui.row({ gap = TIGHT }, rowA), ui.row({ gap = TIGHT }, rowB) })
end

local function verticalToggle(m)
	local items = {
		ui.row({ gap = 8, align = "center" }, {
			ui.toggle({ checked = m.allowVertical, onChange = function(v)
				send("allowVertical", v == "true")
			end }),
			ui.label({ text = tr("lab.allow_vertical"), fontSize = 12.5, color = "on_surface" }),
		}),
		note(tr("lab.allow_vertical_note"), 330),
	}
	if m.verticalError then
		table.insert(items, note(tr("lab.vertical_error"), 330, "error"))
	end
	return ui.column({ gap = 4 }, items)
end

local function slider(label: string, key: string, value: number, max: number, suffix: string, commit)
	local v = draft[key] or value
	return ui.row({ gap = 10, align = "center" }, {
		ui.label({ text = label, fontSize = 12, color = "on_surface_variant", width = 92 }),
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
		ui.label({ text = string.format(suffix, v), fontSize = 12, color = "on_surface", width = 48 }),
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
		ui.label({ text = tr("lab.strategy"), fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
		segmented({ { label = tr("lab.auto"), value = true }, { label = tr("lab.manual"), value = false } }, m.auto, "auto"),
		statusLine(m, d),
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
	if d.canRevert then
		table.insert(head, ui.button({ text = tr("lab.revert"), variant = "ghost", controlSize = "sm", onClick = function()
			send("revert")
		end }))
	end
	table.insert(head, ui.button({ text = tr("lab.apply"), variant = "primary", controlSize = "sm", enabled = d.previewing, onClick = function()
		send("apply")
	end }))

	local body
	if st.kind == "optimizing" then
		local rows = {
			ui.progress({ progress = st.progress or 0, fill = d.glow, track = "surface", height = 6, radius = 3 }),
			note(tr("lab.optimizing_note"), 860),
		}
		if st.best and st.best < 1e9 then
			table.insert(rows, caption(tr("lab.best_so_far", { score = round(st.best) })))
		end
		body = ui.column({ gap = TIGHT }, rows)
	elseif m.auto and d.curve and d.curve.budgets and d.curve.h then
		local t = (draft.lambda or round(m.lambdaT * 100)) / 100
		body = ui.row({ gap = REGION, align = "start" }, {
			curveBlock(m, d),
			ui.column({ gap = 10, flexGrow = 1, align = "start" }, {
				ui.label({ text = tr("lab.pick_title", { name = tr("lab.pick_names." .. pickName(t)) }), fontSize = 12.5, fontWeight = "semibold", color = "on_surface" }),
				note(tr("lab.pick_note"), 330),
				chips(d),
				verticalToggle(m),
			}),
		})
	elseif m.auto then
		body = caption(tr("lab.not_optimized"))
	else
		body = ui.row({ gap = REGION, align = "start" }, { manualBlock(m, d), ui.column({ gap = 10, width = 330 }, { chips(d), verticalToggle(m) }) })
	end
	return card({ ui.row({ gap = 10, align = "center" }, head), body }, { gap = NEAR })
end

-- states -------------------------------------------------------------------------
local function onboarding()
	return card({
		ui.label({ text = tr("lab.onboarding.title"), fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
		note(tr("lab.onboarding.body"), 860),
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
				ui.label({ text = tr("lab.paused"), fontSize = 12.5, color = "on_surface", flexGrow = 1 }),
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
	local children = { header(m) }
	if not m then
		table.insert(children, caption(tr("lab.starting")))
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
			table.insert(children, overview(d))
			table.insert(children, ui.row({ gap = REGION, align = "start" }, {
				inspector(d),
				ui.column({ gap = 10, flexGrow = 1 }, { sidebar(m, d) }),
			}))
			table.insert(children, strategyCard(m, d))
		elseif not b then
			local items = placementNotes(m, 860)
			table.insert(items, 1, caption(tr("lab.waiting")))
			table.insert(children, card(items))
		end
	end
	panel.render(ui.scroll({ flexGrow = 1, gap = REGION }, children))
end

local isOpen = false

noctalia.state.watch("lab:model", function(v)
	model = v
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
