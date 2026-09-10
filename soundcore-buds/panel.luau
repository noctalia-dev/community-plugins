--!nonstrict
-- Soundcore panel: battery, listening mode, touch and device settings.

local SNAPSHOT_KEY = "sankity/soundcore-buds:snapshot"
local COMMAND_KEY = "sankity/soundcore-buds:command"

local NOISE_OFF = 0
local NOISE_ANC = 1
local NOISE_TRANSPARENCY = 2
local NOISE_ADAPTIVE = 3
local LEVEL_UNKNOWN = -1

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {}

-- First tap arms a side, second tap starts the loud tone.
local armedFind = nil
local expandedMode = nil
local lastTopMode = nil

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

local function isLow(pod)
	return pod ~= nil
		and pod.level ~= nil
		and pod.level ~= LEVEL_UNKNOWN
		and pod.level <= 20
		and pod.charging ~= true
end

local function hasText(value)
	return tostring(value or "") ~= ""
end

local function section(children)
	return ui.column({
		fill = "surface_variant",
		radius = 12,
		padding = 12,
		gap = 8,
		border = "outline",
		borderWidth = 1,
	}, children)
end

local function outlineButton(props)
	props.variant = "outline"
	return ui.button(props)
end

local function dropdownState(options, current)
	local labels = {}
	local values = {}
	for _, opt in ipairs(options or {}) do
		table.insert(labels, opt.label)
		table.insert(values, opt.id)
	end
	local selectedIndex = 0
	for i, v in ipairs(values) do
		if v == tostring(current or "") then
			selectedIndex = i - 1
			break
		end
	end
	return labels, values, selectedIndex
end

-- Items carry {id,label}; service lists use {value,label}, also accepted.
local function optionButtons(items, keyPrefix, isSelected, onPick)
	local row = {}
	for _, item in ipairs(items) do
		local id = item.id
		if id == nil then
			id = item.value
		end
		table.insert(row, outlineButton({
			key = keyPrefix .. tostring(id),
			text = item.label,
			contentAlign = "center",
			flexGrow = 1,
			selected = isSelected(id),
			onClick = function()
				onPick(id)
			end,
		}))
	end
	return row
end

local function selectRow(label, data, id, action)
	local labels, values, selectedIndex = dropdownState(data.options, data.value)
	return ui.column({ gap = 6 }, {
		ui.label({ text = label, fontSize = 13, color = "on_surface" }),
		ui.select({
			key = "sound-" .. id,
			options = labels,
			selectedIndex = selectedIndex,
			onChange = function(index)
				local i = (tonumber(index) or 0) + 1
				if values[i] ~= nil then
					sendCommand(action, { id = id, value = values[i] })
				end
			end,
		}),
	})
end

local function labeledToggle(label, caption, key, checked, onChange)
	local textCol = {
		ui.label({ text = label, fontSize = 13, color = "on_surface" }),
	}
	if caption ~= nil and caption ~= "" then
		table.insert(textCol, ui.label({ text = caption, fontSize = 12, color = "on_surface_variant" }))
	end
	return ui.row({ align = "center", gap = 12 }, {
		ui.column({ flexGrow = 1, gap = 1 }, textCol),
		ui.toggle({
			key = key,
			checked = checked == true,
			onChange = onChange,
		}),
	})
end

local function toggleRow(label, caption, checked, key, id)
	return labeledToggle(label, caption, key, checked, function(value)
		sendCommand("set-toggle", { id = id, enabled = value == "true" })
	end)
end

local function podRow(label, text, meta, level, low)
	local progressProps = { progress = levelFraction(level), flexGrow = 1, radius = 3, height = 6 }
	if low then
		progressProps.fill = "error"
	end
	return ui.row({ align = "center", gap = 10 }, {
		ui.label({ text = label, fontSize = 13, color = "on_surface", opacity = 0.7, width = 64 }),
		ui.progress(progressProps),
		ui.label({ text = text, fontSize = 13, color = "on_surface", width = 40, textAlign = "end" }),
		ui.label({ text = meta, fontSize = 12, color = "on_surface_variant", width = 72 }),
	})
end

local function batteryRows()
	local pods = {}
	if snapshot.isHeadset == true then
		pods = {
			{ label = noctalia.tr("panel.headphones"), text = snapshot.headsetText or "--", meta = snapshot.headsetMeta or "", pod = snapshot.headset },
		}
	else
		pods = {
			{ label = noctalia.tr("panel.left"), text = snapshot.leftText or "--", meta = snapshot.leftMeta or "", pod = snapshot.left },
			{ label = noctalia.tr("panel.right"), text = snapshot.rightText or "--", meta = snapshot.rightMeta or "", pod = snapshot.right },
		}
		if snapshot.caseBattery.level ~= LEVEL_UNKNOWN then
			table.insert(pods, { label = noctalia.tr("panel.case"), text = snapshot.caseText or "--", meta = "", pod = snapshot.caseBattery })
		end
	end
	local rows = {}
	for _, p in ipairs(pods) do
		table.insert(rows, podRow(p.label, p.text, p.meta, p.pod.level, isLow(p.pod)))
	end
	return rows
end


local function title()
	local m = tostring(snapshot.modelName or "")
	if m ~= "" then
		return m
	end
	local d = tostring(snapshot.deviceName or "")
	if d ~= "" then
		return d
	end
	return noctalia.tr("panel.title")
end

local function subtitle()
	if snapshot.connected == true then
		local m = tostring(snapshot.modelName or "")
		local d = tostring(snapshot.deviceName or "")
		if m ~= "" and d ~= "" and d ~= m then
			return d
		end
		return ""
	end
	if snapshot.backendOk == false then
		return noctalia.tr("errors.not_installed")
	end
	return noctalia.tr("panel.daemon_down")
end

local function iconPath()
	local base = "icons/pro"
	if noctalia.isDarkMode() then
		return base .. ".svg"
	end
	return base .. "-light.svg"
end

local function render()
	local connected = snapshot.connected == true
	local hasBattery = snapshot.hasBattery == true

	local body = {}
	local sections = {}

	local statusText = tostring(snapshot.actionStatus or "")
	if statusText == "" and tostring(snapshot.lastError or "") ~= "" then
		statusText = snapshot.lastError
	end
	if statusText ~= "" then
		table.insert(body, ui.label({ text = statusText, fontSize = 13, color = "error" }))
	end

	if hasBattery then
		table.insert(sections, section({
			ui.label({ text = noctalia.tr("panel.battery"), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
			ui.column({ gap = 6 }, batteryRows()),

		}))
	end


	if connected and snapshot.availableModes ~= nil and #snapshot.availableModes > 0 then
		local topModes = {}
		if snapshot.supportsNoiseOff then
			table.insert(topModes, { value = NOISE_OFF, label = noctalia.tr("panel.mode.off") })
		end
		if snapshot.supportsTransparency then
			table.insert(topModes, { value = NOISE_TRANSPARENCY, label = noctalia.tr("panel.mode.transparency") })
		end
		if snapshot.supportsAnc then
			table.insert(topModes, { value = NOISE_ANC, label = noctalia.tr("panel.mode.anc_short") })
		end
		if expandedMode ~= nil then
			local stillValid = false
			for _, m in ipairs(topModes) do
				if m.value == expandedMode then
					stillValid = true
					break
				end
			end
			if not stillValid then
				expandedMode = nil
			end
		end
		if snapshot.topMode ~= lastTopMode then
		-- Follow external changes; a manual collapse is preserved.
		expandedMode = snapshot.topMode
		lastTopMode = snapshot.topMode
	elseif expandedMode == nil then
		expandedMode = snapshot.topMode
	end
		local modeRows = {
			ui.label({ text = noctalia.tr("panel.listening_mode"), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
		}
		local topRow = optionButtons(topModes, "mode-", function(id)
			return snapshot.topMode == id
		end, function(id)
			if snapshot.topMode == id then
				expandedMode = (expandedMode == id) and nil or id
				render()
			else
				expandedMode = id
				sendCommand("set-noise", id)
			end
		end)
		table.insert(modeRows, ui.row({ gap = 6 }, topRow))
		if expandedMode == NOISE_ANC then
			local cancel = tostring(snapshot.noiseCancelMode or "")
			if #(snapshot.cancelModes or {}) > 0 then
				table.insert(modeRows, ui.row({ gap = 6 }, optionButtons(snapshot.cancelModes, "cancel-", function(id)
					return cancel == id
				end, function(id)
					sendCommand("set-cancel-mode", id)
				end)))
			end
			if cancel == "Manual" and snapshot.supportsManualAnc == true then
				local lo = snapshot.manualAncMin or 1
				local hi = snapshot.manualAncMax or 5
				table.insert(modeRows, ui.column({ gap = 6 }, {
					ui.row({ justify = "space_between", align = "center" }, {
						ui.label({ text = noctalia.tr("panel.anc_strength"), fontSize = 13, color = "on_surface", opacity = 0.7 }),
						ui.label({ text = tostring(snapshot.manualAnc), fontSize = 13, color = "on_surface" }),
					}),
					ui.slider({
						key = "anc-strength",
						min = lo,
						max = hi,
						step = 1,
						value = snapshot.manualAnc,
						onChange = function(value)
							sendCommand("set-anc-level", tonumber(value))
						end,
					}),
				}))
			end
			local snd = snapshot.sound or {}
			local selects = snd.selects or {}
			local toggles = snd.toggles or {}
			if toggles.windNoiseSuppression ~= nil then
				table.insert(modeRows, toggleRow(
					noctalia.tr("panel.sound.wind"),
					"",
					toggles.windNoiseSuppression,
					"mode-wind-nc",
					"windNoiseSuppression"
				))
			end
			if toggles.realTimeAdaptiveNoiseCanceling ~= nil then
				table.insert(modeRows, toggleRow(
					noctalia.tr("panel.device.rt_anc"),
					noctalia.tr("panel.device.rt_anc_caption"),
					toggles.realTimeAdaptiveNoiseCanceling,
					"mode-rtanc",
					"realTimeAdaptiveNoiseCanceling"
				))
			end
			if cancel == "MultiScene" and selects.multiSceneNoiseCanceling ~= nil then
				table.insert(modeRows, selectRow(
					noctalia.tr("panel.sound.multiscene"),
					selects.multiSceneNoiseCanceling,
					"multiSceneNoiseCanceling",
					"set-select"
				))
			end
		elseif expandedMode == NOISE_TRANSPARENCY then
			local snd = snapshot.sound or {}
			local selects = snd.selects or {}
			local toggles = snd.toggles or {}
			local variant = selects.transparencyMode
			if variant ~= nil then
				local current = tostring(variant.value or "")
				if #(variant.options or {}) > 0 then
					table.insert(modeRows, ui.row({ gap = 6 }, optionButtons(variant.options, "transparency-", function(id)
						return current == id
					end, function(id)
						sendCommand("set-select", { id = "transparencyMode", value = id })
					end)))
				end
			end
			if toggles.windNoiseSuppression ~= nil then
				table.insert(modeRows, toggleRow(
					noctalia.tr("panel.sound.wind"),
					"",
					toggles.windNoiseSuppression,
					"mode-wind",
					"windNoiseSuppression"
				))
			end
		end
		table.insert(sections, section(modeRows))
	end

	if connected and snapshot.touch ~= nil and snapshot.touch.available == true then
		local byId = {}
		for _, control in ipairs(snapshot.touch.controls or {}) do
			byId[control.id] = control
		end
		local function touchMini(prefix, control)
			if control == nil then
				return ui.spacer({ flexGrow = 1 })
			end
			local controlId = control.id
			local labels, values, selectedIndex = dropdownState(control.options, control.value)
			return ui.row({ gap = 4, flexGrow = 1 }, {
				ui.label({ text = prefix, fontSize = 12, color = "on_surface_variant", width = 12 }),
				ui.select({
					key = "touch-" .. tostring(controlId),
					options = labels,
					selectedIndex = selectedIndex,
					flexGrow = 1,
					onChange = function(index)
						local i = (tonumber(index) or 0) + 1
						if values[i] ~= nil then
							sendCommand("set-touch", { id = controlId, value = values[i] })
						end
					end,
				}),
			})
		end
		local touchSection = {
			ui.label({ text = noctalia.tr("panel.touch.title"), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
			ui.label({ text = noctalia.tr("panel.touch.hint"), fontSize = 12, color = "on_surface_variant" }),
		}
		for _, group in ipairs({
			{ label = noctalia.tr("panel.touch.single"), left = "leftSinglePress", right = "rightSinglePress" },
			{ label = noctalia.tr("panel.touch.double"), left = "leftDoublePress", right = "rightDoublePress" },
			{ label = noctalia.tr("panel.touch.triple"), left = "leftTriplePress", right = "rightTriplePress" },
			{ label = noctalia.tr("panel.touch.hold"), left = "leftLongPress", right = "rightLongPress" },
		}) do
			table.insert(touchSection, ui.column({ gap = 4 }, {
				ui.label({ text = group.label, fontSize = 13, fontWeight = "medium", color = "on_surface" }),
				ui.row({ gap = 8 }, {
					touchMini("L", byId[group.left]),
					touchMini("R", byId[group.right]),
				}),
			}))
		end
		if snapshot.touch.supportsTone == true then
			table.insert(touchSection, labeledToggle(
				noctalia.tr("panel.touch.tone"),
				noctalia.tr("panel.touch.tone_caption"),
				"touch-tone",
				snapshot.touch.tone,
				function(value)
					sendCommand("touch-tone", value == "true")
				end
			))
		end
		if snapshot.touch.reset == true then
			table.insert(touchSection, outlineButton({
				key = "touch-reset",
				text = noctalia.tr("panel.touch.reset"),
				contentAlign = "start",
				onClick = function()
					sendCommand("touch-reset", nil)
				end,
			}))
		end
		table.insert(sections, section(touchSection))
	end

	if connected and snapshot.isHeadset ~= true then
		if armedFind ~= nil and snapshot.findingSide ~= "" then
			armedFind = nil
		end
		local finding = tostring(snapshot.findingSide or "")
		local findSection = {
			ui.label({ text = noctalia.tr("panel.find.title"), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
			ui.label({
				text = finding ~= ""
					and noctalia.tr("panel.find.playing")
					or noctalia.tr("panel.find.caption"),
				fontSize = 12,
				color = "on_surface_variant",
			}),
		}
		for _, side in ipairs({ "left", "right" }) do
			local label = side == "left" and noctalia.tr("panel.left") or noctalia.tr("panel.right")
			local text = label
			if finding == side then
				text = label .. " — " .. noctalia.tr("panel.find.stop")
			elseif armedFind == side then
				text = label .. " — " .. noctalia.tr("panel.find.confirm")
			end
			table.insert(findSection, outlineButton({
				key = "find-" .. side,
				text = text,
				contentAlign = "start",
				selected = finding == side,
				onClick = function()
					if tostring((noctalia.state.get(SNAPSHOT_KEY) or {}).findingSide or "") == side then
						armedFind = nil
						sendCommand("stop-find", nil)
					elseif armedFind == side then
						armedFind = nil
						sendCommand("find", side)
					else
						armedFind = side
						render()
					end
				end,
			}))
		end
		table.insert(sections, section(findSection))
	else
		armedFind = nil
	end

	if connected and snapshot.sound ~= nil then
		local snd = snapshot.sound
		local selects = snd.selects or {}
		local toggles = snd.toggles or {}
		local devRows = {
			ui.label({ text = noctalia.tr("panel.device.title"), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
		}
		if toggles.dualConnections ~= nil then
			table.insert(devRows, toggleRow(
				noctalia.tr("panel.device.dual"),
				noctalia.tr("panel.device.dual_caption"),
				toggles.dualConnections,
				"dev-dual",
				"dualConnections"
			))
		end
		if selects.autoPowerOff ~= nil then
			table.insert(devRows, selectRow(
				noctalia.tr("panel.device.auto_off"),
				selects.autoPowerOff,
				"autoPowerOff",
				"set-select"
			))
		end
		if toggles.lowBatteryPrompt ~= nil then
			table.insert(devRows, toggleRow(
				noctalia.tr("panel.device.low_batt"),
				"",
				toggles.lowBatteryPrompt,
				"dev-lowbatt",
				"lowBatteryPrompt"
			))
		end
		if toggles.limitHighVolume ~= nil then
			table.insert(devRows, toggleRow(
				noctalia.tr("panel.device.limit"),
				noctalia.tr("panel.device.limit_caption"),
				toggles.limitHighVolume,
				"dev-limit",
				"limitHighVolume"
			))
			if toggles.limitHighVolume == true and snd.limitDb ~= -1 then
				local lo = snd.limitDbMin or 75
				local hi = snd.limitDbMax or 100
				table.insert(devRows, ui.column({ gap = 6 }, {
					ui.row({ justify = "space_between", align = "center" }, {
						ui.label({ text = noctalia.tr("panel.device.limit_db"), fontSize = 13, color = "on_surface", opacity = 0.7 }),
						ui.label({ text = tostring(snd.limitDb) .. " dB", fontSize = 13, color = "on_surface" }),
					}),
					ui.slider({
						key = "limit-db",
						min = lo,
						max = hi,
						step = snd.limitDbStep or 5,
						value = snd.limitDb,
						onChange = function(value)
							sendCommand("set-int", { id = "limitHighVolumeDbLimit", value = tonumber(value) })
						end,
					}),
				}))
			end
			if toggles.limitHighVolume == true and selects.limitHighVolumeRefreshRate ~= nil then
				table.insert(devRows, selectRow(
					noctalia.tr("panel.device.limit_rate"),
					selects.limitHighVolumeRefreshRate,
					"limitHighVolumeRefreshRate",
					"set-select"
				))
			end
		end
		if #devRows > 1 then
			table.insert(sections, section(devRows))
		end
	end

	if connected and snapshot.info ~= nil then
		local info = snapshot.info
		local infoRows = {}
		if hasText(info.fwL) or hasText(info.fwR) then
			table.insert(infoRows, noctalia.tr("panel.info.fw") .. ": " .. tostring(info.fwL or "--") .. " / " .. tostring(info.fwR or "--"))
		end
		if hasText(info.adaptive) then
			table.insert(infoRows, noctalia.tr("panel.info.adaptive") .. ": " .. tostring(info.adaptive))
		end
		if hasText(info.serial) then
			table.insert(infoRows, noctalia.tr("panel.info.serial") .. ": " .. tostring(info.serial))
		end
		if info.dualDevices ~= nil and #info.dualDevices > 0 then
			table.insert(infoRows, noctalia.tr("panel.info.dual_devices") .. ": " .. table.concat(info.dualDevices, ", "))
		end
		if #infoRows > 0 then
			local labels = {}
			for _, line in ipairs(infoRows) do
				table.insert(labels, ui.label({ text = line, fontSize = 12, color = "on_surface_variant" }))
			end
			table.insert(sections, section({
				ui.label({ text = noctalia.tr("panel.info.title"), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
				ui.column({ gap = 2 }, labels),
			}))
		end
	end

	for _, section in ipairs(sections) do
		table.insert(body, section)
	end

	local function refreshButton(key)
		return outlineButton({
			key = key,
			text = "Refresh",
			contentAlign = "center",
			onClick = function()
				sendCommand("refresh", nil)
			end,
		})
	end
	if not connected then
		local guidance = snapshot.backendOk == false
			and noctalia.tr("errors.not_installed")
			or noctalia.tr("panel.guidance.daemon_down")
		table.insert(body, ui.label({ text = guidance, fontSize = 13, color = "on_surface_variant", textAlign = "center" }))
		table.insert(body, refreshButton("refresh-offline"))
	elseif snapshot.stale == true then
		table.insert(body, refreshButton("refresh-stale"))
	end

	if snapshot.busy == true then
		table.insert(body, ui.label({ text = "…", fontSize = 12, color = "on_surface_variant", textAlign = "center" }))
	end

	panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.image({ path = iconPath(), width = 28, height = 28, fit = "contain", opacity = connected and 1 or 0.5 }),
			ui.column({ flexGrow = 1, gap = 2 }, {
				ui.label({ text = title(), fontSize = 16, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
				ui.label({ text = subtitle(), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
			}),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ flexGrow = 1, gap = 12 }, body),
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

function onCloseClicked()
	panel.close()
end

-- Stop a running tone when the panel closes.
function onClose()
	armedFind = nil
	sendCommand("stop-find", nil)
end

-- Direct keys while the panel is focused. Mode values mirror NOISE_* above.
function onKey(chord, pressed)
	if pressed ~= true then
		return
	end
	if chord == "o" then
		sendCommand("set-noise", 0)
	elseif chord == "t" then
		sendCommand("set-noise", 2)
	elseif chord == "a" then
		sendCommand("set-noise", 3)
	elseif chord == "n" then
		sendCommand("set-noise", 1)
	elseif chord == "f" and snapshot.isHeadset ~= true then
		if tostring((noctalia.state.get(SNAPSHOT_KEY) or {}).findingSide or "") ~= "" then
			armedFind = nil
			sendCommand("stop-find", nil)
		elseif armedFind == "left" then
			armedFind = nil
			sendCommand("find", "left")
		else
			armedFind = "left"
			render()
		end
	elseif chord == "r" then
		sendCommand("refresh", nil)
	end
end
