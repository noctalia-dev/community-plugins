--!nonstrict
-- Persistent desktop widget for Nothing/CMF earbuds — a compact card styled
-- after Nothing's own phone widget: per-bud battery + the ANC mode row.
-- Noctalia's declarative UI has no ring/arc component, so battery is shown
-- as glyph + thin linear bar + percentage instead of a circular gauge.

local shared = require("./shared.luau")

local status = noctalia.state.get(shared.STATUS_KEY) or {}

local CARD_WIDTH = 200

local function levelFraction(level)
	local n = tonumber(level)
	if n == nil or n < 0 then
		return 0
	end
	return math.max(0, math.min(100, n)) / 100
end

-- icons/*.svg come in a light-on-dark and a dark-on-light ("-light") tint,
-- since ui.image can't recolor an SVG to the theme.
local function iconPath(name)
	return "icons/" .. name .. (noctalia.isDarkMode() and ".svg" or "-light.svg")
end

local function budBattery(entry, icon)
	local level = entry and entry.level or nil
	local charging = entry and entry.charging or false
	local hasLevel = level ~= nil
	local low = hasLevel and level <= 20 and not charging
	local color = low and "error" or (charging and "secondary" or "on_surface")

	local levelRow = {}
	if charging then
		table.insert(levelRow, ui.glyph({ name = "bolt", size = 11, color = color }))
	end
	table.insert(levelRow, ui.label({
		text = hasLevel and (tostring(level) .. "%") or "--",
		fontSize = 11,
		fontWeight = "medium",
		color = color,
		textAlign = "center",
	}))

	return ui.column({ align = "center", gap = 4, flexGrow = 1 }, {
		ui.image({ path = iconPath(icon), width = 18, height = 18, fit = "contain", opacity = hasLevel and 1 or 0.4 }),
		ui.progress({
			progress = levelFraction(level),
			height = 3,
			radius = 2,
			fill = color,
			track = "on_surface/0.12",
			width = 44,
		}),
		ui.row({ align = "center", gap = 2 }, levelRow),
	})
end

local function ancRow(anc)
	local currentMode = anc.mode or "off"
	local buttons = {}
	for _, spec in ipairs(shared.ANC_MODES) do
		local selected = currentMode == spec.mode
		table.insert(buttons, ui.column({
			key = "dw-mode-" .. spec.mode,
			align = "center",
			justify = "center",
			width = 40,
			height = 40,
			radius = 20,
			fill = selected and "primary/0.18" or "on_surface/0.06",
			border = selected and "outline/0" or "outline",
			onClick = function()
				shared.sendCommand("set-anc", spec.mode, spec.mode == "anc" and "high" or nil)
			end,
		}, {
			ui.glyph({ name = spec.glyph, size = 18, color = selected and "primary" or "on_surface_variant" }),
		}))
	end
	return ui.row({ gap = 8, justify = "center" }, buttons)
end

local function placeholder(text)
	desktopWidget.render(ui.column({
		align = "center",
		justify = "center",
		gap = 6,
		padding = 14,
		radius = 16,
		fill = "surface_variant",
		width = CARD_WIDTH,
	}, {
		ui.glyph({ name = "headphones-off", size = 20, color = "on_surface_variant" }),
		ui.label({ text = text, fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
	}))
end

local function render()
	if status.unconfigured then
		placeholder(noctalia.tr("widget.not_configured"))
		return
	end
	if status.connected ~= true then
		placeholder(noctalia.tr("widget.not_connected"))
		return
	end

	local battery = status.battery or {}
	local anc = status.anc or {}

	desktopWidget.render(ui.column({
		gap = 10,
		padding = 12,
		radius = 16,
		fill = "surface_variant",
		width = CARD_WIDTH,
	}, {
		ui.row({ justify = "space_between", gap = 6 }, {
			budBattery(battery.left, "bud-left"),
			budBattery(battery.case, "case"),
			budBattery(battery.right, "bud-right"),
		}),
		ui.separator({ thickness = 1, color = "on_surface/0.1" }),
		ancRow(anc),
	}))
end

noctalia.state.watch(shared.STATUS_KEY, function(value)
	if type(value) == "table" then
		status = value
		render()
	end
end)

-- Tell service.luau a desktop instance is alive so it keeps polling; cleared
-- in onExit when the widget is removed from the desktop (or on shutdown).
noctalia.state.set(shared.DESKTOP_ACTIVE_KEY, true)

function onExit()
	noctalia.state.set(shared.DESKTOP_ACTIVE_KEY, false)
end

render()
