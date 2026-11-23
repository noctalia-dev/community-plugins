--!nonstrict
-- Panel for Nothing/CMF earbuds

local shared = require("./shared.luau")

local STATUS_KEY = shared.STATUS_KEY
local DEVICES_KEY = shared.DEVICES_KEY

local status = noctalia.state.get(STATUS_KEY) or {}
local devicesState = noctalia.state.get(DEVICES_KEY) or { ok = false, devices = {} }
local sendCommand = shared.sendCommand

-- "main" or "more"; see tabBar.
local activeTab = "main"

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
local render

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

-- A round icon button with its label underneath, for a pick-one row.
local function roundChoice(key, icon, label, selected, onClick)
	return ui.column({ align = "center", gap = 4, flexGrow = 1 }, {
		ui.column({
			key = key,
			align = "center",
			justify = "center",
			width = 56,
			height = 56,
			radius = 28,
			fill = selected and "primary/0.18" or "on_surface/0.06",
			-- always reserve the border's stroke width so selecting doesn't
			-- resize the circle and shove its neighbors around; hide it via alpha instead
			border = selected and "outline_variant/0" or "outline_variant",
			onClick = onClick,
		}, {
			-- an image can't take the theme's accent colour, so the filled
			-- circle marks the selection and the icon only dims
			ui.image({
				path = iconPath(icon),
				width = 26,
				height = 26,
				fit = "contain",
				opacity = selected and 1 or 0.6,
			}),
		}),
		-- Room for two lines whether or not the label wraps, so a re-render
		-- that wraps it differently can't push it into the row below.
		ui.column({ height = 30, align = "center" }, {
			ui.label({
				text = label,
				fontSize = 11,
				maxLines = 2,
				textAlign = "center",
				color = selected and "on_surface" or "on_surface_variant",
			}),
		}),
	})
end

local function ancControls(anc, personalAnc)
	local currentMode = anc.mode or "off"
	local currentStrength = anc.strength

	local modeButtons = {}
	for _, spec in ipairs(shared.ANC_MODES) do
		table.insert(modeButtons, roundChoice(
			"mode-" .. spec.mode,
			spec.icon,
			noctalia.tr(spec.labelKey),
			currentMode == spec.mode,
			function()
				sendCommand("set-anc", spec.mode, spec.mode == "anc" and "high" or nil)
			end
		))
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
		-- spacers: the toggle otherwise crowds the mode labels above it and
		-- the section separator below
		table.insert(rows, ui.column({ height = 4 }, {}))
		table.insert(rows, toggleRow(
			"panel.personal_anc.title",
			personalAnc,
			"set-personal-anc",
			noctalia.tr("panel.personal_anc.caption")
		))
		table.insert(rows, ui.column({ height = 2 }, {}))
	end

	return ui.column({ gap = 8, align = "stretch" }, rows)
end

-- Pill-shaped like the presets in the Nothing X app; ui.button has its own
-- corner radius, so this is a plain row with a fill.
local function eqButton(preset, currentPreset)
	local i = preset.index
	local selected = currentPreset == i
	return ui.row({
		key = "eq-" .. tostring(i),
		align = "center",
		justify = "center",
		flexGrow = 1,
		height = 38,
		radius = 19,
		fill = selected and "primary" or "on_surface/0.06",
		onClick = function()
			sendCommand("set-eq", i)
		end,
	}, {
		ui.label({
			text = noctalia.tr("panel.eq." .. preset.name),
			fontSize = 13,
			fontWeight = selected and "bold" or "medium",
			color = selected and "on_primary" or "on_surface_variant",
			textAlign = "center",
		}),
	})
end

local BASS_LEVELS = { 1, 2, 3, 4, 5 }

local function bassControls(bass)
	local rows = { toggleRow("panel.bass.title", bass.enabled, "set-bass-enabled") }
	if bass.enabled then
		local buttons = {}
		for _, level in ipairs(BASS_LEVELS) do
			local selected = bass.level == level
			table.insert(buttons, ui.button({
				key = "bass-" .. tostring(level),
				text = tostring(level),
				variant = selected and "secondary" or "ghost",
				selected = selected,
				flexGrow = 1,
				onClick = function()
					sendCommand("set-bass", level)
				end,
			}))
		end
		table.insert(rows, ui.row({ gap = 4 }, buttons))
	end
	return rows
end

-- The custom curve being dragged, shown instead of the last read until the
-- earbuds report it back, so a slider doesn't jump back mid-drag.
local customDraft = nil
local CUSTOM_BANDS = { "bass", "mid", "treble" }

local function signed(n)
	return n > 0 and ("+" .. tostring(n)) or tostring(n)
end

local function customEqControls(curve)
	if customDraft ~= nil then
		local caughtUp = true
		for _, band in ipairs(CUSTOM_BANDS) do
			caughtUp = caughtUp and customDraft[band] == curve[band]
		end
		if caughtUp then
			customDraft = nil
		end
	end
	local shown = customDraft or curve
	local rows = {}
	for _, band in ipairs(CUSTOM_BANDS) do
		local value = tonumber(shown[band]) or 0
		table.insert(rows, ui.row({ align = "center", gap = 8 }, {
			ui.column({ width = 48 }, {
				ui.label({ text = noctalia.tr("panel.custom_eq." .. band), fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.slider({
				key = "custom-" .. band,
				min = -6,
				max = 6,
				step = 1,
				value = value,
				flexGrow = 1,
				onChange = function(v)
					local n = math.floor((tonumber(v) or 0) + 0.5)
					local draft = { bass = shown.bass or 0, mid = shown.mid or 0, treble = shown.treble or 0 }
					if draft[band] == n then
						return
					end
					draft[band] = n
					customDraft = draft
					sendCommand("set-custom-eq", string.format("%d,%d,%d", draft.bass, draft.mid, draft.treble))
					render()
				end,
			}),
			ui.column({ width = 48, align = "end" }, {
				ui.label({ text = signed(value) .. " dB", fontSize = 12, color = "on_surface" }),
			}),
		}))
	end
	return ui.column({ gap = 2, padding = 4 }, rows)
end

-- The preset list comes from the model (CMF models have their own); a
-- model with none we can trust gets no preset buttons.
local function eqControls(presets, currentPreset, soundProfile, bass, custom)
	local rows = {}
	if #presets > 0 then
		table.insert(rows, sectionHeader("panel.eq.title"))
	end
	local row = {}
	for _, preset in ipairs(presets) do
		table.insert(row, eqButton(preset, currentPreset))
		if #row == 2 then
			table.insert(rows, ui.row({ gap = 6 }, row))
			row = {}
		end
	end
	if #row > 0 then
		-- pad the short row so its pill lines up under the ones above
		table.insert(row, ui.column({ flexGrow = 1 }, {}))
		table.insert(rows, ui.row({ gap = 6 }, row))
	end
	if custom ~= nil then
		table.insert(rows, customEqControls(custom))
	end
	-- Only present when a hearing test has been saved from the Nothing X app.
	if soundProfile ~= nil then
		table.insert(rows, toggleRow("panel.sound_profile.title", soundProfile, "set-sound-profile"))
	end
	-- Only present on models with bass boost that answered the read.
	if bass ~= nil then
		for _, r in ipairs(bassControls(bass)) do
			table.insert(rows, r)
		end
	end
	return ui.column({ gap = 6, align = "stretch" }, rows)
end

-- Only on models with spatial audio that answered the read. `pending` is
-- the mode being written: shown as picked until the headphones answer.
local function spatialControls(modes, current, pending)
	local buttons = {}
	for _, mode in ipairs(modes) do
		local selected = (pending or current) == mode
		local label = noctalia.tr("panel.spatial." .. mode)
		local function pick()
			sendCommand("set-spatial", mode)
		end
		local icon = shared.SPATIAL_ICONS[mode]
		if icon ~= nil then
			table.insert(buttons, roundChoice("spatial-" .. mode, icon, label, selected, pick))
		else
			table.insert(buttons, ui.button({
				key = "spatial-" .. mode,
				text = label,
				variant = selected and "secondary" or "ghost",
				selected = selected,
				flexGrow = 1,
				onClick = pick,
			}))
		end
	end
	local header = sectionHeader("panel.spatial.title")
	if pending ~= nil then
		header = ui.row({ align = "center", gap = 8 }, {
			header,
			ui.label({ text = noctalia.tr("panel.applying"), fontSize = 11, color = "on_surface_variant" }),
		})
	end
	return ui.column({ gap = 8, align = "stretch" }, {
		header,
		ui.row({ gap = 6 }, buttons),
	})
end

-- Switching codec restarts the headphones, so a click only arms the choice
-- and a second one confirms it.
local pendingCodec = nil

-- `switching` is the codec being written, before the restart starts.
local function codecControls(codecs, current, restarting, switching)
	local caption = "panel.codec.caption"
	if restarting then
		caption = "panel.codec.restarting"
	elseif switching ~= nil then
		caption = "panel.codec.switching"
	elseif pendingCodec ~= nil then
		caption = "panel.codec.confirm"
	end
	local buttons = {}
	if restarting or switching ~= nil then
		-- nothing to click until the headphones are back
	elseif pendingCodec ~= nil then
		local target = pendingCodec
		buttons = {
			ui.button({
				key = "codec-confirm",
				text = noctalia.tr("panel.codec.restart"),
				variant = "secondary",
				onClick = function()
					pendingCodec = nil
					sendCommand("set-codec", target)
				end,
			}),
			ui.button({
				key = "codec-cancel",
				text = noctalia.tr("panel.codec.cancel"),
				variant = "ghost",
				onClick = function()
					pendingCodec = nil
					render()
				end,
			}),
		}
	else
		for _, codec in ipairs(codecs) do
			local selected = current == codec
			table.insert(buttons, ui.button({
				key = "codec-" .. codec,
				text = noctalia.tr("panel.codec." .. codec),
				variant = selected and "secondary" or "ghost",
				selected = selected,
				onClick = function()
					if not selected then
						pendingCodec = codec
						render()
					end
				end,
			}))
		end
	end
	return ui.row({ align = "center", gap = 12 }, {
		ui.column({ flexGrow = 1, gap = 1 }, {
			ui.label({ text = noctalia.tr("panel.codec.title"), fontSize = 13, color = "on_surface" }),
			ui.label({ text = noctalia.tr(caption), fontSize = 11, color = "on_surface_variant" }),
		}),
		ui.row({ align = "center", gap = 4 }, buttons),
	})
end

local function copyDetailsButton()
	return ui.button({
		text = noctalia.tr("panel.copy_details"),
		glyph = "copy",
		variant = "ghost",
		onClick = function()
			sendCommand("copy-details", nil)
		end,
	})
end

-- A change the earbuds didn't take (or that never reached them). The
-- details hold the frames that went back and forth, for a bug report.
local function writeFailed(code)
	local key = code == "not_applied" and "panel.write_not_applied" or "panel.write_failed"
	return ui.row({ align = "center", gap = 8, padding = 4 }, {
		ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
		ui.label({ text = noctalia.tr(key), fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
		copyDetailsButton(),
	})
end

local TABS = { "main", "more" }

-- Outside the scroll area, so it stays put while the content scrolls. Text
-- tabs with an accent underline on the active one, over a hairline.
local function tabBar()
	local tabs = {}
	for _, tab in ipairs(TABS) do
		local selected = activeTab == tab
		table.insert(tabs, ui.column({
			key = "tab-" .. tab,
			align = "center",
			gap = 6,
			flexGrow = 1,
			onClick = function()
				if activeTab ~= tab then
					activeTab = tab
					render()
				end
			end,
		}, {
			ui.label({
				text = noctalia.tr("panel.tab." .. tab),
				fontSize = 13,
				fontWeight = selected and "bold" or "medium",
				color = selected and "primary" or "on_surface_variant",
			}),
			ui.box({ width = 56, height = 3, radius = 2, fill = selected and "primary" or "on_surface/0" }),
		}))
	end
	return ui.column({ gap = 0 }, {
		ui.row({ gap = 6 }, tabs),
		ui.separator({ thickness = 1, color = "on_surface/0.12" }),
	})
end

local function devicePicker(devices)
	local list = (devices and devices.devices) or {}
	local sections = {
		ui.column({ align = "stretch", gap = 6, padding = 12 }, {
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

	return ui.column({ gap = 8, align = "stretch" }, sections)
end

-- Manual override alongside the auto-mono setting: works whether or not
-- "mono when one bud is out" is on, so it also doubles as a way to force
-- mono off if auto-detection gets it wrong. The caption says which of the
-- two is in charge, since the toggle alone can't.
local function monoCaption(s)
	if s.model and s.model.battery_single then
		return noctalia.tr("panel.mono.caption_headphones")
	end
	if s.mono_by_auto then
		return noctalia.tr("panel.mono.caption_auto_active")
	elseif s.mono_auto then
		return noctalia.tr("panel.mono.caption_auto")
	end
	return noctalia.tr("panel.mono.caption")
end

local function audioControls(s)
	local rows = {
		sectionHeader("panel.audio.title"),
		toggleRow("panel.latency.title", s.latency_mode, "set-latency", noctalia.tr("panel.latency.caption")),
		toggleRow("panel.mono.title", s.mono_active, "set-mono", monoCaption(s)),
	}
	-- Only on models that can switch codec and answered the read.
	local codecs = (s.model or {}).codecs or {}
	local switching = (s.writing or {}).codec
	if #codecs > 1 and (s.codec ~= nil or s.restarting or switching ~= nil) then
		table.insert(rows, codecControls(codecs, s.codec, s.restarting == true, switching))
	end
	return ui.column({ gap = 8, align = "stretch" }, rows)
end

-- A short hint of what to try; the specifics (errno, step, raw replies) go
-- into Copy details instead, for a bug report. Both only once a poll has
-- actually failed, not while the first one is still running.
local function notConnected(code, connecting)
	local rows = {
		ui.label({
			text = noctalia.tr(connecting and "panel.connecting" or "widget.not_connected"),
			fontSize = 14,
			textAlign = "center",
			color = "on_surface",
		}),
	}
	if code ~= nil and not connecting then
		local key = shared.ERROR_HINTS[code] and code or "unknown"
		table.insert(rows, ui.label({
			text = noctalia.tr("panel.error." .. key),
			fontSize = 12,
			color = "on_surface_variant",
			textAlign = "center",
		}))
		table.insert(rows, ui.row({ justify = "center" }, { copyDetailsButton() }))
	end
	return ui.column({ align = "stretch", gap = 8, padding = 24 }, rows)
end

function render()
	local body = {}

	if status.unconfigured then
		table.insert(body, devicePicker(devicesState))
	else
		if status.connected ~= true then
			table.insert(body, notConnected(status.error, status.connecting == true))
		else
			local battery = status.battery or {}
			local model = status.model or {}
			local batteries
			if model.battery_single or type(battery.single) == "table" then
				batteries = { batteryColumn(noctalia.tr("panel.headphones"), battery.single, "headphones") }
			else
				batteries = {
					batteryColumn(noctalia.tr("panel.left"), battery.left, "bud-left"),
					batteryColumn(noctalia.tr("panel.case"), battery.case, "case"),
					batteryColumn(noctalia.tr("panel.right"), battery.right, "bud-right"),
				}
			end
			-- Main holds what gets used every day; the rest is one tap away on More.
			if activeTab == "more" then
				local spatialModes = model.spatial or {}
				local pendingSpatial = (status.writing or {}).spatial
				if #spatialModes > 0 and (status.spatial ~= nil or pendingSpatial ~= nil) then
					table.insert(body, spatialControls(spatialModes, status.spatial, pendingSpatial))
					table.insert(body, sectionSeparator())
				end
				table.insert(body, audioControls(status))
				-- For a bug report while connected; the error row has its own.
				if status.write_error == nil then
					table.insert(body, ui.row({ justify = "center" }, { copyDetailsButton() }))
				end
			else
				table.insert(body, ui.row({ align = "center", justify = "space_between", gap = 12, padding = 4 }, batteries))
				if model.anc ~= false then
					table.insert(body, sectionSeparator())
					table.insert(body, ancControls(status.anc or {}, status.personal_anc))
				end
				local presets = model.eq_presets or shared.EQ_PRESETS
				if #presets > 0 or status.bass ~= nil then
					table.insert(body, sectionSeparator())
					-- The curve's sliders sit right under the presets, while Custom is the one selected.
					local custom = nil
					if model.custom_eq ~= nil and status.eq_preset == model.custom_eq and type(status.custom_eq) == "table" then
						custom = status.custom_eq
					end
					table.insert(body, eqControls(presets, status.eq_preset, status.sound_profile, status.bass, custom))
				end
			end
			if status.write_error ~= nil then
				table.insert(body, writeFailed(status.write_error))
			end
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

	local header = {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = titleText, fontSize = 15, fontWeight = "bold", color = "on_surface" }),
			ui.row({ align = "center", gap = 2 }, headerActions),
		}),
	}
	if status.connected == true and not status.unconfigured then
		table.insert(header, tabBar())
	end

	panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10 }, {
		ui.column({ gap = 8 }, header),
		-- stretch: sections get the full width on the first layout too, so
		-- their rows don't bunch up in the middle or overlap wrapped text
		ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, body),
	}))
end

noctalia.state.watch(STATUS_KEY, function(value)
	if type(value) == "table" then
		-- A curve the headphones turned down: show what they really have.
		if value.write_error ~= nil and status.write_error == nil then
			customDraft = nil
		end
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
	pendingCodec = nil
	customDraft = nil
	activeTab = "main"
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
