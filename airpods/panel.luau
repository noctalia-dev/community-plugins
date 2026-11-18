--!nonstrict
-- AirPods panel. Renders the battery rows, listening-mode rows, adaptive noise
-- slider, Conversation Awareness and One-Bud ANC toggles, and ear-detection
-- select. It reads the service snapshot and sends commands through the shared
-- state channel, so it never shells out itself.

local SNAPSHOT_KEY = "airpods_snapshot"
local COMMAND_KEY = "airpods_command"

local NOISE_ADAPTIVE = 3
local LEVEL_UNKNOWN = -1

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

local function isLow(pod)
	return pod ~= nil
		and pod.level ~= nil
		and pod.level ~= LEVEL_UNKNOWN
		and pod.level <= 20
		and pod.charging ~= true
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
		ui.label({ text = meta, fontSize = 12, color = "on_surface_variant", width = 56 }),
	})
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
	if snapshot.hasAirPods == true then
		local m = tostring(snapshot.modelName or "")
		local d = tostring(snapshot.deviceName or "")
		if m ~= "" and d ~= "" and d ~= m then
			return d
		end
		return ""
	end
	if snapshot.schemaUnsupported == true then
		return noctalia.tr("panel.schema_unsupported")
	end
	if snapshot.daemonReachable == true then
		return noctalia.tr("panel.not_connected")
	end
	return noctalia.tr("panel.daemon_down")
end

local function variant()
	if snapshot.isHeadset == true then
		return "max"
	end
	if snapshot.isProSeries == true then
		return "pro"
	end
	return "buds"
end

local function iconPath()
	local file = variant() .. (noctalia.isDarkMode() and ".svg" or "-light.svg")
	return "icons/" .. file
end

local function render()
	local hasAirPods = snapshot.hasAirPods == true
	local hasBattery = snapshot.hasBattery == true

	local body = {}
	local sections = {}

	local statusText = tostring(snapshot.actionStatus or "")
	if statusText == "" and snapshot.daemonReachable == true and tostring(snapshot.lastError or "") ~= "" then
		statusText = snapshot.lastError
	end
	if statusText ~= "" then
		table.insert(body, ui.label({ text = statusText, fontSize = 13, color = "error" }))
	end

	if hasBattery then
		local batteryRows = {}
		if snapshot.isHeadset == true then
			table.insert(batteryRows, podRow(
				noctalia.tr("panel.headphones"),
				snapshot.headsetText or "--",
				snapshot.headsetMeta or "",
				snapshot.headset.level,
				isLow(snapshot.headset)
			))
		else
			table.insert(batteryRows, podRow(
				noctalia.tr("panel.left"),
				snapshot.leftText or "--",
				snapshot.leftMeta or "",
				snapshot.left.level,
				isLow(snapshot.left)
			))
			table.insert(batteryRows, podRow(
				noctalia.tr("panel.right"),
				snapshot.rightText or "--",
				snapshot.rightMeta or "",
				snapshot.right.level,
				isLow(snapshot.right)
			))
			table.insert(batteryRows, podRow(
				noctalia.tr("panel.case"),
				snapshot.caseText or "--",
				snapshot.caseMeta or "",
				snapshot.caseBattery.level,
				isLow(snapshot.caseBattery)
			))
		end
		table.insert(sections, ui.column({ gap = 8 }, {
			ui.label({ text = noctalia.tr("panel.battery"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
			ui.column({ gap = 6 }, batteryRows),
		}))
	end

	if hasAirPods and #snapshot.availableModes > 0 then
		local modeRows = {}
		for _, mode in ipairs(snapshot.availableModes) do
			local modeValue = mode.value
			local modeLabel = mode.label
			table.insert(modeRows, ui.button({
				key = "mode-" .. tostring(modeValue),
				text = modeLabel,
				variant = "ghost",
				contentAlign = "start",
				selected = snapshot.noiseMode == modeValue,
				onClick = function()
					sendCommand("set-noise", modeValue)
				end,
			}))
		end

		local section = { ui.label({ text = noctalia.tr("panel.listening_mode"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }) }
		for _, row in ipairs(modeRows) do
			table.insert(section, row)
		end
		if snapshot.supportsAdaptive == true and snapshot.noiseMode == NOISE_ADAPTIVE then
			table.insert(section, ui.column({ gap = 6 }, {
				ui.row({ justify = "space_between", align = "center" }, {
					ui.label({ text = noctalia.tr("panel.adaptive_noise"), fontSize = 13, color = "on_surface", opacity = 0.7 }),
					ui.label({ text = tostring(snapshot.adaptiveNoiseLevel) .. "%", fontSize = 13, color = "on_surface" }),
				}),
				ui.slider({
					key = "adaptive",
					min = 0,
					max = 100,
					step = 5,
					value = snapshot.adaptiveNoiseLevel,
					onChange = function(value)
						sendCommand("set-adaptive", tonumber(value))
					end,
				}),
			}))
		end
		table.insert(sections, ui.column({ gap = 8 }, section))
	end

	if hasAirPods and snapshot.supportsConversationalAwareness == true then
		table.insert(sections, ui.row({ align = "center", gap = 12 }, {
			ui.column({ flexGrow = 1, gap = 1 }, {
				ui.label({ text = noctalia.tr("panel.conversation_awareness"), fontSize = 13, color = "on_surface" }),
				ui.label({ text = noctalia.tr("panel.conversation_awareness_caption"), fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.toggle({
				key = "ca",
				checked = snapshot.conversationalAwareness == true,
				onChange = function(value)
					sendCommand("set-ca", value == "true")
				end,
			}),
		}))
	end

	if hasAirPods and snapshot.supportsOneBudANC == true then
		table.insert(sections, ui.row({ align = "center", gap = 12 }, {
			ui.column({ flexGrow = 1, gap = 1 }, {
				ui.label({ text = noctalia.tr("panel.one_bud_anc"), fontSize = 13, color = "on_surface" }),
				ui.label({ text = noctalia.tr("panel.one_bud_anc_caption"), fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.toggle({
				key = "onebud",
				checked = snapshot.oneBudANC == true,
				onChange = function(value)
					sendCommand("set-onebud", value == "true")
				end,
			}),
		}))
	end

	if hasAirPods then
		local labels = {}
		local values = {}
		for _, opt in ipairs(snapshot.earOptions or {}) do
			table.insert(labels, opt.label)
			table.insert(values, opt.value)
		end
		local selectedIndex = 0
		for i, value in ipairs(values) do
			if value == snapshot.earDetectionBehavior then
				selectedIndex = i - 1
				break
			end
		end
		table.insert(sections, ui.column({ gap = 6 }, {
			ui.label({ text = noctalia.tr("panel.ear_detection"), fontSize = 13, color = "on_surface" }),
			ui.select({
				key = "ear",
				options = labels,
				selectedIndex = selectedIndex,
				onChange = function(index)
					local i = (tonumber(index) or 0) + 1
					if values[i] ~= nil then
						sendCommand("set-ear", values[i])
					end
				end,
			}),
		}))
	end

	for index, section in ipairs(sections) do
		if index > 1 then
			table.insert(body, ui.separator({ thickness = 1, color = "on_surface/0.5" }))
		end
		table.insert(body, section)
	end

	if not hasAirPods then
		local guidance = snapshot.daemonReachable == true
			and noctalia.tr("panel.guidance.connected")
			or noctalia.tr("panel.guidance.daemon_down")
		table.insert(body, ui.label({ text = guidance, fontSize = 13, color = "on_surface_variant", textAlign = "center" }))
	end

	panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.image({ path = iconPath(), width = 28, height = 28, fit = "contain", opacity = hasAirPods and 1 or 0.5 }),
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
