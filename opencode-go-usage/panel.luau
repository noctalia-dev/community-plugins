--!nonstrict
-- Details panel entry: 5-hour / weekly / monthly limit cards with progress bars,
-- reset countdowns and per-period daily headroom.
--
--   panel.render(tree)                 declarative ui.* tree
--   noctalia.state.watch("usage", cb)   re-render when the service publishes
--   noctalia.state.set("usage.cmd", 1)  ask the service to refetch now
--
-- Children lists are built with table.insert rather than `if ... else nil`
-- expressions: a nil in the middle of a constructor leaves a hole, and the host
-- walks the children array positionally.

local WARNING = "#F5A623"

local usage = noctalia.state.get("usage")
local busy = false

local function formatPct(fraction)
	if type(fraction) ~= "number" or fraction < 0 then
		return noctalia.tr("panel.empty")
	end
	local v = fraction * 100
	if v > 999 then
		v = 999
	end
	local r = math.floor(v * 10 + 0.5) / 10
	if r == math.floor(r) then
		return string.format("%d%%", r)
	end
	return string.format("%.1f%%", r)
end

-- Signed average headroom per remaining day, e.g. "+12.3%".
local function formatDaily(fraction)
	if type(fraction) ~= "number" or fraction < 0 then
		return nil
	end
	local v = fraction * 100
	local r = math.floor(v * 10 + 0.5) / 10
	local sign = v > 0 and "+" or ""
	if r == math.floor(r) then
		return string.format("%s%d%%", sign, r)
	end
	return string.format("%s%.1f%%", sign, r)
end

local function limitColor(fraction)
	if fraction >= 0.97 then
		return "error"
	elseif fraction >= 0.70 then
		return WARNING
	end
	return "primary"
end

-- Card chrome, matched to the community usage-bar plugin: a hairline outline on a
-- faint surface fill, and pill-shaped chips for the values that sit on top of it.
local CARD = { gap = 5, padding = 7, radius = 9, fill = "surface_variant/0.34", border = "outline/0.08", borderWidth = 1 }

local function chip(text, color, fontSize, fontWeight)
	return ui.row({ paddingH = 6, paddingV = 2, radius = 5, align = "center", justify = "center", fill = color .. "/0.10" }, {
		ui.label({ text = text, fontSize = fontSize or 12, fontWeight = fontWeight or "bold", color = color }),
	})
end

local function limitCard(card)
	local children = {}
	local tint = limitColor(card.percent)

	table.insert(children, ui.row({ gap = 8, align = "center" }, {
		ui.label({ text = card.name, fontSize = 13, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
		ui.spacer({ flexGrow = 1 }),
		chip(formatPct(card.percent), tint, 12, "bold"),
	}))

	table.insert(children, ui.progress({
		progress = math.min(1, math.max(0, card.percent)),
		fill = tint,
		track = "on_surface/0.10",
		height = 5,
		radius = 2,
	}))

	local bottom = {}
	if card.reset and card.reset ~= "" then
		table.insert(bottom, ui.glyph({ name = "clock", size = 10, color = "on_surface_variant" }))
		table.insert(bottom, ui.label({ text = card.reset, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
	end

	local daily = formatDaily(card.daily)
	local right = {}
	if daily then
		table.insert(right, ui.label({ text = daily, fontSize = 10, fontWeight = "medium", color = "secondary", maxLines = 1 }))
	end

	if #bottom > 0 or #right > 0 then
		table.insert(children, ui.row({ gap = 6, align = "center" }, {
			ui.row({ gap = 4, align = "center" }, bottom),
			ui.spacer({ flexGrow = 1 }),
			ui.row({ gap = 3, align = "center", justify = "end" }, right),
		}))
	end

	return ui.column({ gap = CARD.gap, padding = CARD.padding, radius = CARD.radius, fill = CARD.fill, border = CARD.border, borderWidth = CARD.borderWidth }, children)
end

local function headerRow()
	local children = {
		ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
	}
	table.insert(children, ui.spacer({ flexGrow = 1 }))
	if usage and usage.tier and usage.tier ~= "" then
		local cancelling = usage.tier == "cancelling"
		local tierColor = cancelling and "error" or "primary"
		table.insert(children, chip(noctalia.tr("tier." .. usage.tier), tierColor, 11, "semibold"))
	end
	table.insert(children, ui.button({
		glyph = "refresh",
		variant = "ghost",
		controlSize = "sm",
		width = 24,
		height = 24,
		glyphSize = 13,
		tooltip = noctalia.tr("panel.refresh"),
		enabled = not busy,
		onClick = "onRefresh",
	}))
	return ui.row({ align = "center", gap = 8, paddingH = 4, paddingV = 2 }, children)
end

local function render()
	local children = {}

	table.insert(children, headerRow())

	if not usage then
		table.insert(children, ui.label({
			text = noctalia.tr("panel.waiting"),
			color = "on_surface_variant",
		}))
	elseif not usage.ok then
		table.insert(children, ui.label({
			text = usage.message or noctalia.tr("panel.unavailable"),
			color = "error",
			fontWeight = "medium",
		}))
		if usage.code == "need_key" then
			table.insert(children, ui.label({
				text = noctalia.tr("panel.key_hint"),
				fontSize = 12,
				color = "on_surface_variant",
			}))
		end
	else
		local shown = 0
		for _, key in { "fiveHour", "week", "month" } do
			local card = usage[key]
			if type(card) == "table" and card.percent >= 0 then
				table.insert(children, limitCard(card))
				shown += 1
			end
		end
		if shown == 0 then
			table.insert(children, ui.label({
				text = noctalia.tr("panel.no_meters"),
				color = "on_surface_variant",
			}))
		end
	end

	table.insert(children, ui.spacer({ flexGrow = 1 }))

	panel.render(ui.column({ gap = 6, paddingH = 0, paddingV = 0, flexGrow = 1, align = "stretch" }, children))
end

function onRefresh()
	busy = true
	render()
	noctalia.state.set("usage.cmd", (noctalia.state.get("usage.cmd") or 0) + 1)
end

noctalia.state.watch("usage", function(value)
	usage = value
	busy = false
	render()
end)

function onOpen(_context)
	render()
end

render()
