--!nonstrict
-- Panel for OPPO Pods
-- Displays authentic 3D renders from OPPO CDN, symmetrical battery indicators, and noise cancellation controls.

local SNAPSHOT_KEY = "oppo_pods_snapshot"
local COMMAND_KEY = "oppo_pods_command"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}
local hoveredControl = nil

local commandSeq = 0
local function sendCommand(action, value)
	commandSeq += 1
	noctalia.state.set(COMMAND_KEY, {
		action = action,
		value = value,
		nonce = tostring(noctalia.nowMs()) .. "-" .. tostring(commandSeq),
	})
end

local function levelFraction(level)
	local n = tonumber(level)
	if n == nil or n < 0 then
		return 0
	end
	return math.max(0, math.min(100, n)) / 100
end

local function isLow(level, charging)
	return level ~= nil and level >= 0 and level <= 20 and not charging
end

local function batteryColumn(iconName, label, level, charging, isClosed)
	local hasLevel = level ~= nil and level >= 0
	local text = hasLevel and (tostring(level) .. "%") or "--%"
	local meta = ""
	local metaColor = "on_surface_variant"
	if charging then
		meta = noctalia.tr("panel.charging")
		metaColor = "secondary"
	elseif isClosed then
		meta = noctalia.tr("panel.case_offline")
		metaColor = "on_surface_variant"
	end

	local low = isLow(level, charging)
	local fillRole = "primary"
	if low then
		fillRole = "error"
	elseif charging then
		fillRole = "secondary"
	elseif not hasLevel then
		fillRole = "disabled"
	end

	local iconSuffix = noctalia.isDarkMode() and ".svg" or "-light.svg"
	local iconPath = "icons/" .. iconName .. iconSuffix

	return ui.column({
		align = "center",
		justify = "center",
		gap = 4,
		flexGrow = 1,
	}, {
		ui.row({ align = "center", gap = 4 }, {
			ui.image({
				path = iconPath,
				width = 16,
				height = 16,
				fit = "contain",
				opacity = hasLevel and 0.85 or 0.4,
			}),
			ui.label({
				text = label,
				fontSize = 12,
				fontWeight = "medium",
				color = "on_surface_variant",
			}),
		}),
		ui.label({
			text = text,
			fontSize = 15,
			fontWeight = "bold",
			color = low and "error" or (hasLevel and "on_surface" or "on_surface_variant"),
			textAlign = "center",
		}),
		ui.progress({
			progress = levelFraction(level),
			height = 4,
			radius = 2,
			fill = fillRole,
			width = 76,
		}),
		ui.label({
			text = (meta ~= "") and meta or " ",
			fontSize = 11,
			color = metaColor,
			textAlign = "center",
		}),
	})
end

local function headerIconPath()
	return "icons/" .. (noctalia.isDarkMode() and "oppo-pods.svg" or "oppo-pods-light.svg")
end

-- Official render when downloaded; a neutral glyph otherwise, so other models never show an Enco Air4 Pro.
local function deviceVisual(height, opacity)
	if snapshot.device_image and snapshot.device_image ~= "" then
		return ui.image({ path = snapshot.device_image, width = 180, height = height, fit = "contain", opacity = opacity })
	end
	return ui.column({ align = "center", justify = "center", height = height }, {
		ui.glyph({ name = "headphones", size = 72, color = "on_surface_variant" }),
	})
end

local NOISE_MODES = {
	{ mode = "anc", glyph = "shield-check" },
	{ mode = "transparency", glyph = "ear" },
	{ mode = "off", glyph = "volume-off" },
}

local function noiseControls()
	local currentMode = snapshot.noise_mode or "off"

	local modeTiles = {}
	for _, spec in ipairs(NOISE_MODES) do
		local key = "mode-" .. spec.mode
		local selected = currentMode == spec.mode
		local hovered = not selected and hoveredControl == key
		table.insert(modeTiles, ui.column({ align = "center", gap = 6, flexGrow = 1 }, {
			ui.column({
				key = key,
				align = "center",
				justify = "center",
				width = 52,
				height = 52,
				radius = 26,
				fill = selected and "primary/0.18" or (hovered and "primary/0.08" or "on_surface/0.06"),
				border = selected and "primary/0.45" or (hovered and "primary/0.25" or "outline_variant/0.4"),
				borderWidth = 1,
				onClick = function()
					sendCommand("set-noise", spec.mode)
				end,
				onHover = "onControlHover",
			}, {
				ui.glyph({ name = spec.glyph, size = 22, color = (selected or hovered) and "primary" or "on_surface_variant" }),
			}),
			ui.label({
				text = noctalia.tr("panel.mode." .. spec.mode),
				fontSize = 11,
				textAlign = "center",
				color = selected and "on_surface" or "on_surface_variant",
			}),
		}))
	end

	local rows = {
		ui.label({
			text = noctalia.tr("panel.noise_control"),
			fontSize = 11,
			fontWeight = "bold",
			color = "on_surface_variant",
		}),
		ui.row({ gap = 6 }, modeTiles),
	}

	local levels = snapshot.anc_levels or {}
	if currentMode == "anc" and #levels > 0 then
		local levelButtons = {}
		for _, level in ipairs(levels) do
			local selected = snapshot.noise_level == level
			table.insert(levelButtons, ui.button({
				key = "level-" .. level,
				text = noctalia.tr("panel.level." .. level),
				fontSize = 11,
				height = 28,
				width = 0,
				flexGrow = 1,
				variant = selected and "secondary" or "ghost",
				selected = selected,
				onClick = function()
					sendCommand("set-noise", level)
				end,
			}))
		end
		table.insert(rows, ui.row({ gap = 2, padding = 3, radius = 17, fill = "on_surface/0.06" }, levelButtons))
	end

	return ui.column({ gap = 10 }, rows)
end

-- Game mode has no query on these earbuds: the switch shows the last state set here or pushed by the earbuds.
local function gameModeRow()
	return ui.row({ align = "center", gap = 12 }, {
		ui.column({
			align = "center",
			justify = "center",
			width = 34,
			height = 34,
			radius = 17,
			fill = snapshot.game_mode and "primary/0.18" or "on_surface/0.06",
		}, {
			ui.glyph({ name = "device-gamepad", size = 18, color = snapshot.game_mode and "primary" or "on_surface_variant" }),
		}),
		ui.column({ flexGrow = 1, gap = 1 }, {
			ui.label({ text = noctalia.tr("panel.game_mode"), fontSize = 13, color = "on_surface" }),
			ui.label({ text = noctalia.tr("panel.game_mode_caption"), fontSize = 11, color = "on_surface_variant" }),
		}),
		ui.toggle({
			key = "game-mode",
			checked = snapshot.game_mode == true,
			onChange = function(value)
				sendCommand("set-game", value == "true")
			end,
		}),
	})
end

local function render()
	local connected = snapshot.connected == true
	local body = {}

	if connected then
		-- 1. Official 3D Render from OPPO servers
		table.insert(body, ui.row({
			align = "center",
			justify = "center",
			padding = 2,
		}, {
			deviceVisual(138, 1),
		}))

		-- 2. Symmetrical 3-Column Battery Section (Always Left, Case, Right)
		table.insert(body, ui.row({
			align = "center",
			justify = "space_around",
			gap = 12,
			padding = 4,
		}, {
			batteryColumn("earbud-left", noctalia.tr("panel.left"), snapshot.battery_left, snapshot.charging_left, false),
			batteryColumn("case", noctalia.tr("panel.case"), snapshot.battery_case, snapshot.charging_case, snapshot.case_offline == true),
			batteryColumn("earbud-right", noctalia.tr("panel.right"), snapshot.battery_right, snapshot.charging_right, false),
		}))

		table.insert(body, ui.separator({ thickness = 1, color = "on_surface/0.12" }))

		-- 3. Noise Cancellation Mode Selection
		table.insert(body, noiseControls())

		if snapshot.game_mode_supported then
			table.insert(body, ui.separator({ thickness = 1, color = "on_surface/0.12" }))
			table.insert(body, gameModeRow())
		end
	else
		-- Not connected state
		table.insert(body, ui.column({ align = "center", gap = 12, padding = 24 }, {
			deviceVisual(140, 0.35),
			ui.label({
				text = noctalia.tr("widget.not_connected"),
				fontSize = 15,
				fontWeight = "bold",
				color = "on_surface",
				textAlign = "center",
			}),
			ui.label({
				text = noctalia.tr("panel.guidance"),
				fontSize = 12,
				color = "on_surface_variant",
				textAlign = "center",
			}),
		}))
	end

	local titleText = snapshot.model_name or snapshot.device_name or noctalia.tr("panel.title")
	local statusText = connected and noctalia.tr("panel.status.connected") or noctalia.tr("panel.status.disconnected")

	panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.image({
				path = headerIconPath(),
				width = 30,
				height = 30,
				fit = "contain",
				opacity = connected and 1 or 0.45,
			}),
			ui.column({ flexGrow = 1, gap = 2 }, {
				ui.label({
					text = titleText,
					fontSize = 15,
					fontWeight = "bold",
					color = "on_surface",
					maxLines = 1,
				}),
				ui.label({
					text = statusText,
					fontSize = 11,
					color = connected and "secondary" or "on_surface_variant",
					maxLines = 1,
				}),
			}),
			ui.button({
				glyph = "close",
				variant = "ghost",
				onClick = "onCloseClicked",
			}),
		}),
		-- The panel is deliberately tall enough for the complete layout; no scroll view is needed.
		ui.column({ flexGrow = 1, gap = 10 }, body),
	}))
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

function onOpen(_context)
	sendCommand("refresh", nil)
	render()
end

function onControlHover(entered, key)
	if entered == "true" then
		hoveredControl = key
	elseif hoveredControl == key then
		hoveredControl = nil
	end
	render()
end

function onCloseClicked()
	panel.close()
end
