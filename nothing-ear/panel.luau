--!nonstrict
-- Panel for Nothing/CMF earbuds

local shared = require("./shared.luau")

local STATUS_KEY = shared.STATUS_KEY
local DEVICES_KEY = shared.DEVICES_KEY

local status = noctalia.state.get(STATUS_KEY) or {}
local devicesState = noctalia.state.get(DEVICES_KEY) or { ok = false, devices = {} }
local sendCommand = shared.sendCommand

local function levelFraction(level)
	local n = tonumber(level)
	if n == nil or n < 0 then
		return 0
	end
	return math.max(0, math.min(100, n)) / 100
end

local function iconPath(name)
	return "icons/" .. name .. (noctalia.isDarkMode() and ".svg" or "-light.svg")
end

local function batteryColumn(label, entry, icon)
	local level = entry and entry.level or nil
	local charging = entry and entry.charging or false
	local hasLevel = level ~= nil
	local text = hasLevel and (tostring(level) .. "%") or "--"
	local low = hasLevel and level <= 20 and not charging

	local levelRow = {}
	if charging then
		table.insert(levelRow, ui.glyph({ name = "bolt", size = 14, color = "secondary" }))
	end
	table.insert(levelRow, ui.label({
		text = text,
		fontSize = 16,
		fontWeight = "bold",
		color = low and "error" or (hasLevel and "on_surface" or "on_surface_variant"),
		textAlign = "center",
	}))

	return ui.column({ align = "center", justify = "center", gap = 4, flexGrow = 1 }, {
		ui.image({ path = iconPath(icon), width = 22, height = 22, fit = "contain", opacity = hasLevel and 1 or 0.4 }),
		ui.label({ text = label, fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
		ui.row({ align = "center", gap = 2 }, levelRow),
		ui.progress({
			progress = levelFraction(level),
			height = 4,
			radius = 2,
			fill = low and "error" or (charging and "secondary" or "primary"),
			width = 76,
		}),
	})
end

local ANC_STRENGTHS = { "high", "mid", "low", "adaptive" }

local function sectionHeader(key)
	return ui.label({ text = noctalia.tr(key), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" })
end

local function sectionSeparator()
	return ui.separator({ thickness = 1, color = "on_surface/0.12" })
end

local function toggleRow(labelKey, enabled, action, caption)
	local text = { ui.label({ text = noctalia.tr(labelKey), fontSize = 13, color = "on_surface" }) }
	if caption ~= nil then
		table.insert(text, ui.label({ text = caption, fontSize = 11, color = "on_surface_variant" }))
	end
	return ui.row({ align = "center", gap = 12 }, {
		ui.column({ flexGrow = 1, gap = 1 }, text),
		ui.toggle({
			checked = enabled == true,
			onChange = function(v)
				sendCommand(action, v)
			end,
		}),
	})
end

local function ancControls(anc, personalAnc)
	local currentMode = anc.mode or "off"
	local currentStrength = anc.strength

	local modeButtons = {}
	for _, spec in ipairs(shared.ANC_MODES) do
		local selected = currentMode == spec.mode
		table.insert(modeButtons, ui.column({ align = "center", gap = 4, flexGrow = 1 }, {
			ui.column({
				key = "mode-" .. spec.mode,
				align = "center",
				justify = "center",
				width = 56,
				height = 56,
				radius = 28,
				fill = selected and "primary/0.18" or "on_surface/0.06",
				-- always reserve the border's stroke width so selecting a mode doesn't
				-- resize the circle and shove its neighbors around; hide it via alpha instead
				border = selected and "outline/0" or "outline",
				onClick = function()
					sendCommand("set-anc", spec.mode, spec.mode == "anc" and "high" or nil)
				end,
			}, {
				ui.glyph({
					name = spec.glyph,
					size = 22,
					color = selected and "primary" or "on_surface_variant",
				}),
			}),
			ui.label({
				text = noctalia.tr(spec.labelKey),
				fontSize = 11,
				textAlign = "center",
				color = selected and "on_surface" or "on_surface_variant",
			}),
		}))
	end

	local rows = {
		sectionHeader("panel.noise_control"),
		ui.row({ gap = 6 }, modeButtons),
	}

	if currentMode == "anc" then
		local strengthButtons = {}
		for _, s in ipairs(ANC_STRENGTHS) do
			local selected = currentStrength == s
			table.insert(strengthButtons, ui.button({
				key = "strength-" .. s,
				text = noctalia.tr("panel.strength." .. s),
				variant = selected and "secondary" or "ghost",
				selected = selected,
				onClick = function()
					sendCommand("set-anc", "anc", s)
				end,
			}))
		end
		table.insert(rows, ui.row({ gap = 8, justify = "center" }, strengthButtons))
	end
	-- Only present when the earbuds answered the read.
	if personalAnc ~= nil then
		table.insert(rows, toggleRow("panel.personal_anc.title", personalAnc, "set-personal-anc"))
	end

	return ui.column({ gap = 8 }, rows)
end

local function eqButton(preset, currentPreset)
	local i = preset.index
	local selected = currentPreset == i
	return ui.button({
		key = "eq-" .. tostring(i),
		text = noctalia.tr("panel.eq." .. preset.name),
		variant = selected and "secondary" or "ghost",
		selected = selected,
		flexGrow = 1,
		onClick = function()
			sendCommand("set-eq", i)
		end,
	})
end

local function eqControls(currentPreset, soundProfile)
	local topRow = {}
	local bottomRow = {}
	for n, preset in ipairs(shared.EQ_PRESETS) do
		table.insert(n <= 3 and topRow or bottomRow, eqButton(preset, currentPreset))
	end
	-- pad the short row so its buttons line up under the three above
	while #bottomRow < #topRow do
		table.insert(bottomRow, ui.column({ flexGrow = 1 }, {}))
	end
	local rows = {
		sectionHeader("panel.eq.title"),
		ui.row({ gap = 4 }, topRow),
		ui.row({ gap = 4 }, bottomRow),
	}
	-- Only present when a hearing test has been saved from the Nothing X app.
	if soundProfile ~= nil then
		table.insert(rows, toggleRow("panel.sound_profile.title", soundProfile, "set-sound-profile"))
	end
	return ui.column({ gap = 6 }, rows)
end

local function devicePicker(devices)
	local list = (devices and devices.devices) or {}
	local sections = {
		ui.column({ align = "center", gap = 6, padding = 12 }, {
			ui.label({ text = noctalia.tr("widget.not_configured"), fontSize = 14, textAlign = "center", color = "on_surface" }),
			ui.label({ text = noctalia.tr("panel.guidance"), fontSize = 12, color = "on_surface_variant", textAlign = "center" }),
		}),
	}

	if #list > 0 then
		local rows = {}
		for _, d in ipairs(list) do
			table.insert(rows, ui.button({
				key = "device-" .. tostring(d.mac),
				text = tostring(d.name) .. "  ·  " .. tostring(d.mac),
				glyph = d.likely and "headphones" or "bluetooth",
				variant = d.likely and "secondary" or "ghost",
				contentAlign = "start",
				onClick = function()
					sendCommand("select-device", d.mac)
				end,
			}))
		end
		table.insert(sections, ui.label({ text = noctalia.tr("panel.devices.title"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }))
		table.insert(sections, ui.column({ gap = 3 }, rows))
	else
		table.insert(sections, ui.label({ text = noctalia.tr("panel.devices.none"), fontSize = 12, color = "on_surface_variant", textAlign = "center" }))
	end

	table.insert(sections, ui.button({
		text = noctalia.tr("panel.devices.scan"),
		glyph = "refresh",
		variant = "ghost",
		onClick = function()
			sendCommand("scan-devices", nil)
		end,
	}))

	return ui.column({ gap = 8 }, sections)
end

-- Manual override alongside the auto-mono setting: works whether or not
-- "mono when one bud is out" is on, so it also doubles as a way to force
-- mono off if auto-detection gets it wrong. The caption says which of the
-- two is in charge, since the toggle alone can't.
local function monoCaption(s)
	if s.mono_by_auto then
		return noctalia.tr("panel.mono.caption_auto_active")
	elseif s.mono_auto then
		return noctalia.tr("panel.mono.caption_auto")
	end
	return noctalia.tr("panel.mono.caption")
end

local function audioControls(s)
	return ui.column({ gap = 8 }, {
		sectionHeader("panel.audio.title"),
		toggleRow("panel.latency.title", s.latency_mode, "set-latency", noctalia.tr("panel.latency.caption")),
		toggleRow("panel.mono.title", s.mono_active, "set-mono", monoCaption(s)),
	})
end

local function render()
	local body = {}

	if status.unconfigured then
		table.insert(body, devicePicker(devicesState))
	else
		if status.connected ~= true then
			table.insert(body, ui.column({ align = "center", gap = 8, padding = 24 }, {
				ui.label({ text = noctalia.tr("widget.not_connected"), fontSize = 14, textAlign = "center", color = "on_surface" }),
			}))
		else
			local battery = status.battery or {}
			table.insert(body, ui.row({ align = "center", justify = "space_between", gap = 12, padding = 4 }, {
				batteryColumn(noctalia.tr("panel.left"), battery.left, "bud-left"),
				batteryColumn(noctalia.tr("panel.case"), battery.case, "case"),
				batteryColumn(noctalia.tr("panel.right"), battery.right, "bud-right"),
			}))
			local model = status.model or {}
			if model.anc ~= false then
				table.insert(body, sectionSeparator())
				table.insert(body, ancControls(status.anc or {}, status.personal_anc))
			end
			table.insert(body, sectionSeparator())
			table.insert(body, eqControls(status.eq_preset, status.sound_profile))
			table.insert(body, sectionSeparator())
			table.insert(body, audioControls(status))
		end
	end

	local titleText = (status.model and status.model.name) or noctalia.tr("panel.title")

	local headerActions = {}
	if not status.unconfigured then
		table.insert(headerActions, ui.button({
			glyph = "bluetooth",
			variant = "ghost",
			tooltip = noctalia.tr("panel.devices.switch"),
			onClick = function()
				sendCommand("forget-device", nil)
			end,
		}))
	end
	table.insert(headerActions, ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }))

	panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = titleText, fontSize = 15, fontWeight = "bold", color = "on_surface" }),
			ui.row({ align = "center", gap = 2 }, headerActions),
		}),
		ui.scroll({ flexGrow = 1, gap = 8 }, body),
	}))
end

noctalia.state.watch(STATUS_KEY, function(value)
	if type(value) == "table" then
		status = value
		render()
	end
end)

noctalia.state.watch(DEVICES_KEY, function(value)
	if type(value) == "table" then
		devicesState = value
		render()
	end
end)

function onOpen(_context)
	sendCommand("panel_open", nil)
	render()
end

function onClose()
	sendCommand("panel_close", nil)
end

function onCloseClicked()
	panel.close()
end

render()
