--!nonstrict
-- Control panel for Honor Choice Earbuds X5

local SNAPSHOT_KEY = "honor_earbuds_snapshot"
local COMMAND_KEY = "honor_earbuds_command"

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}

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

local function earbudAvailable(level)
	return level == nil or level > 0
end

local function batteryColumn(glyphName, label, level, charging, isEarbud)
	local hasLevel = level ~= nil and level >= 0
	-- A battery reading of 0 means the earbud is off (usually sitting in the case).
	local connected = hasLevel and (not isEarbud or level > 0)
	local text
	if connected then
		text = tostring(level) .. "%"
	elseif isEarbud and hasLevel then
		text = noctalia.tr("panel.status.disconnected")
	else
		text = "--%"
	end
	local meta = connected and charging and noctalia.tr("panel.charging") or " "
	local low = connected and level <= 20 and not charging

	local fillRole = "primary"
	if not connected then
		fillRole = "outline_variant"
	elseif low then
		fillRole = "error"
	elseif charging then
		fillRole = "secondary"
	end

	return ui.column({
		align = "center",
		justify = "center",
		gap = 4,
	}, {
		ui.row({ align = "center", gap = 4 }, {
			ui.glyph({
				name = glyphName,
				size = 16,
				color = connected and "primary" or "outline_variant",
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
			color = low and "error" or (connected and "on_surface" or "on_surface_variant"),
			textAlign = "center",
		}),
		ui.progress({
			progress = connected and levelFraction(level) or 0,
			height = 4,
			radius = 2,
			fill = fillRole,
			width = 72,
		}),
		ui.label({
			text = meta,
			fontSize = 11,
			color = connected and charging and "secondary" or "on_surface_variant",
			textAlign = "center",
		}),
	})
end

local function render()
	local connected = snapshot.connected == true
	local canControlNoise = earbudAvailable(snapshot.battery_left) and earbudAvailable(snapshot.battery_right)
	local body = {}

	if connected then
		-- Battery indicators
		table.insert(body, ui.row({
			align = "center",
			justify = "space_between",
			padding = 8,
		}, {
			batteryColumn("ear", noctalia.tr("panel.left"), snapshot.battery_left, snapshot.charging_left, true),
			batteryColumn("ear", noctalia.tr("panel.right"), snapshot.battery_right, snapshot.charging_right, true),
			batteryColumn("package", noctalia.tr("panel.case"), snapshot.battery_case, snapshot.charging_case, false),
		}))

		-- Separator
		table.insert(body, ui.separator({ color = "on_surface/0.12" }))

		-- Noise Cancellation Modes
		local currentMode = snapshot.noise_mode or "off"
		local modeButtons = {
			ui.button({
				key = "mode-anc",
				text = noctalia.tr("panel.mode.anc"),
				glyph = "shield-check",
				variant = (currentMode == "anc") and "primary" or "ghost",
				selected = (currentMode == "anc"),
				contentAlign = "start",
				enabled = canControlNoise,
				tooltip = not canControlNoise and noctalia.tr("panel.noise_requires_both") or nil,
				onClick = function()
					sendCommand("set-noise", "anc")
				end,
			}),
			ui.button({
				key = "mode-transparency",
				text = noctalia.tr("panel.mode.transparency"),
				glyph = "ear",
				variant = (currentMode == "transparency") and "primary" or "ghost",
				selected = (currentMode == "transparency"),
				contentAlign = "start",
				enabled = canControlNoise,
				tooltip = not canControlNoise and noctalia.tr("panel.noise_requires_both") or nil,
				onClick = function()
					sendCommand("set-noise", "transparency")
				end,
			}),
			ui.button({
				key = "mode-off",
				text = noctalia.tr("panel.mode.off"),
				glyph = "volume-off",
				variant = (currentMode == "off") and "primary" or "ghost",
				selected = (currentMode == "off"),
				contentAlign = "start",
				enabled = canControlNoise,
				tooltip = not canControlNoise and noctalia.tr("panel.noise_requires_both") or nil,
				onClick = function()
					sendCommand("set-noise", "off")
				end,
			}),
		}

		local noiseChildren = {
			ui.label({
				text = noctalia.tr("panel.noise_control"),
				fontSize = 11,
				fontWeight = "bold",
				color = "on_surface_variant",
			}),
		}
		if not canControlNoise then
			table.insert(noiseChildren, ui.label({
				text = noctalia.tr("panel.noise_requires_both"),
				fontSize = 11,
				color = "on_surface_variant",
			}))
		end
		table.insert(noiseChildren, ui.column({ gap = 3 }, modeButtons))
		table.insert(body, ui.column({ gap = 4 }, noiseChildren))


	else
		-- Disconnected State
		table.insert(body, ui.column({ align = "center", gap = 12, padding = 32 }, {
			ui.glyph({
				name = "headphones-off",
				size = 48,
				color = "outline_variant",
			}),
			ui.label({
				text = noctalia.tr("widget.not_connected"),
				fontSize = 15,
				fontWeight = "bold",
				color = "on_surface",
				textAlign = "center",
			}),
			ui.button({
				text = noctalia.tr("panel.refresh"),
				glyph = "reload",
				variant = "primary",
				onClick = function()
					sendCommand("refresh", true)
				end,
			}),
		}))
	end

	local titleText = snapshot.model_name or "HONOR CHOICE Earbuds X5"
	local statusText = connected and noctalia.tr("panel.status.connected") or noctalia.tr("panel.status.disconnected")
	if connected and snapshot.mac then
		statusText = statusText .. " • " .. snapshot.mac
	end

	panel.render(ui.column({ gap = 8, padding = 12 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.glyph({
				name = "headphones",
				size = 28,
				color = connected and "primary" or "outline_variant",
			}),
			ui.column({ gap = 2 }, {
				ui.label({
					text = titleText,
					fontSize = 14,
					fontWeight = "bold",
					color = "on_surface",
					maxLines = 1,
				}),
				ui.label({
					text = statusText,
					fontSize = 11,
					color = connected and "secondary" or "on_surface_variant",
				}),
			}),
			ui.button({
				glyph = "reload",
				variant = "ghost",
				onClick = function()
					sendCommand("refresh", true)
				end,
			}),
		}),
		ui.separator({ color = "on_surface/0.12" }),
		ui.column({ gap = 8 }, body),
	}))
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
	if type(value) == "table" then
		snapshot = value
		render()
	end
end)

render()
