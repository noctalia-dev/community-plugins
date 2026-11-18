--!nonstrict
-- Pixel Buds Pro panel. Renders the battery rows, noise-control modes, the
-- 5-band EQ and the on/off settings. It reads the service snapshot and sends
-- commands through the shared state channel, so it never shells out itself.

local SNAPSHOT_KEY = "pixelbuds_snapshot"
local COMMAND_KEY = "pixelbuds_command"

local LEVEL_UNKNOWN = -1
local LOW_LEVEL = 20

local EQ_BAND_KEYS = { "low_bass", "bass", "mid", "treble", "upper_treble" }

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

local function isLow(bud)
	return type(bud) == "table"
		and bud.level ~= nil
		and bud.level ~= LEVEL_UNKNOWN
		and bud.level <= LOW_LEVEL
		and bud.charging ~= true
end

local function sectionTitle(key)
	return ui.label({ text = noctalia.tr(key), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" })
end

local function budRow(label, text, meta, bud)
	local progressProps = { progress = levelFraction(bud and bud.level), flexGrow = 1, radius = 3, height = 6 }
	if isLow(bud) then
		progressProps.fill = "error"
	end
	return ui.row({ align = "center", gap = 10 }, {
		-- Labels size to their text, so fixed-width columns keep the bars aligned.
		ui.column({ minWidth = 48, maxWidth = 48 }, {
			ui.label({ text = label, fontSize = 13, color = "on_surface", opacity = 0.7 }),
		}),
		ui.progress(progressProps),
		ui.column({ minWidth = 40, maxWidth = 40, align = "end" }, {
			ui.label({ text = text, fontSize = 13, color = "on_surface" }),
		}),
		ui.column({ minWidth = 80, maxWidth = 80 }, {
			ui.label({ text = meta, fontSize = 12, color = "on_surface_variant" }),
		}),
	})
end

local function toggleRow(key, labelKey, captionKey, value, action)
	return ui.row({ align = "center", gap = 12 }, {
		ui.column({ flexGrow = 1, gap = 1 }, {
			ui.label({ text = noctalia.tr(labelKey), fontSize = 13, color = "on_surface" }),
			ui.label({ text = noctalia.tr(captionKey), fontSize = 12, color = "on_surface_variant" }),
		}),
		ui.toggle({
			key = key,
			checked = value == true,
			onChange = function(v)
				sendCommand(action, v == "true" or v == true)
			end,
		}),
	})
end

local function formatGain(v)
	local n = tonumber(v) or 0
	if n > 0 then
		return string.format("+%.1f dB", n)
	end
	return string.format("%.1f dB", n)
end

local function needsPbpctrl()
	return snapshot.pbpctrlFound == false and snapshot.mode ~= "basic"
end

local function subtitle()
	if needsPbpctrl() then
		return noctalia.tr("panel.pbpctrl_missing")
	end
	if snapshot.hasBuds == true then
		if snapshot.mode == "basic" then
			return noctalia.tr("panel.connected_basic")
		end
		return noctalia.tr("panel.connected")
	end
	if snapshot.connected == true then
		return noctalia.tr("panel.unreachable")
	end
	return noctalia.tr("panel.not_connected")
end

local function guidance()
	if needsPbpctrl() then
		return noctalia.tr("panel.guidance.pbpctrl_missing")
	end
	if snapshot.connected == true then
		return noctalia.tr("panel.guidance.unreachable")
	end
	return noctalia.tr("panel.guidance.not_connected")
end

local function render()
	local hasBuds = snapshot.hasBuds == true

	local body = {}
	local sections = {}

	local statusText = tostring(snapshot.actionStatus or "")
	if statusText ~= "" then
		table.insert(body, ui.label({ text = statusText, fontSize = 13, color = "error" }))
	end

	if hasBuds and snapshot.mode == "basic" then
		local battery = { sectionTitle("panel.battery") }
		if snapshot.combined ~= nil and snapshot.combined.level ~= LEVEL_UNKNOWN then
			table.insert(battery, budRow(noctalia.tr("panel.buds"), snapshot.combinedText or "--", "", snapshot.combined))
		else
			table.insert(battery, ui.label({
				text = noctalia.tr("panel.basic_no_battery"),
				fontSize = 12,
				color = "on_surface_variant",
			}))
		end
		table.insert(sections, ui.column({ gap = 8 }, battery))
		table.insert(sections, ui.label({
			text = noctalia.tr("panel.basic_hint"),
			fontSize = 12,
			color = "on_surface_variant",
		}))
	elseif hasBuds then
		table.insert(sections, ui.column({ gap = 8 }, {
			sectionTitle("panel.battery"),
			ui.column({ gap = 6 }, {
				budRow(noctalia.tr("panel.left"), snapshot.leftText or "--", snapshot.leftMeta or "", snapshot.left),
				budRow(noctalia.tr("panel.right"), snapshot.rightText or "--", snapshot.rightMeta or "", snapshot.right),
				budRow(noctalia.tr("panel.case"), snapshot.caseText or "--", snapshot.caseMeta or "", snapshot.caseBattery),
			}),
		}))

		local ancSection = { sectionTitle("panel.noise_control_title") }
		for _, mode in ipairs(snapshot.ancModes or {}) do
			local value = mode.value
			table.insert(ancSection, ui.button({
				key = "anc-" .. value,
				text = mode.label,
				variant = "ghost",
				contentAlign = "start",
				selected = snapshot.anc == value,
				onClick = function()
					sendCommand("set-anc", value)
				end,
			}))
		end
		if snapshot.anc == "unknown" then
			table.insert(ancSection, ui.label({
				text = noctalia.tr("panel.anc_unknown_hint"),
				fontSize = 12,
				color = "on_surface_variant",
			}))
		end
		table.insert(sections, ui.column({ gap = 8 }, ancSection))

		if type(snapshot.eq) == "table" then
			local eqSection = {
				ui.row({ align = "center", justify = "space_between" }, {
					sectionTitle("panel.eq_title"),
					ui.button({
						text = noctalia.tr("panel.eq_reset"),
						variant = "ghost",
						onClick = function()
							sendCommand("reset-eq", nil)
						end,
					}),
				}),
			}
			for i, bandKey in ipairs(EQ_BAND_KEYS) do
				local band = i
				table.insert(eqSection, ui.column({ gap = 4 }, {
					ui.row({ justify = "space_between", align = "center" }, {
						ui.label({ text = noctalia.tr("panel.eq_band." .. bandKey), fontSize = 13, color = "on_surface", opacity = 0.7 }),
						ui.label({ text = formatGain(snapshot.eq[i]), fontSize = 13, color = "on_surface" }),
					}),
					ui.slider({
						key = "eq-" .. bandKey,
						min = -6,
						max = 6,
						step = 0.5,
						value = tonumber(snapshot.eq[i]) or 0,
						onChange = function(v)
							sendCommand("set-eq", { band = band, value = tonumber(v) })
						end,
					}),
				}))
			end
			table.insert(sections, ui.column({ gap = 8 }, eqSection))
		end

		local toggles = { sectionTitle("panel.settings_title") }
		if snapshot.ohd ~= nil then
			table.insert(toggles, toggleRow("ohd", "panel.ohd", "panel.ohd_caption", snapshot.ohd, "set-ohd"))
		end
		if snapshot.speechDetection ~= nil then
			table.insert(toggles, toggleRow("speech", "panel.speech_detection", "panel.speech_detection_caption", snapshot.speechDetection, "set-speech"))
		end
		if snapshot.multipoint ~= nil then
			table.insert(toggles, toggleRow("multipoint", "panel.multipoint", "panel.multipoint_caption", snapshot.multipoint, "set-multipoint"))
		end
		if #toggles > 1 then
			table.insert(sections, ui.column({ gap = 10 }, toggles))
		end
	end

	for index, section in ipairs(sections) do
		if index > 1 then
			table.insert(body, ui.separator({ thickness = 1, color = "on_surface/0.5" }))
		end
		table.insert(body, section)
	end

	if not hasBuds then
		table.insert(body, ui.column({ gap = 12, align = "center" }, {
			ui.glyph({ name = "headphones-off", size = 48, color = "on_surface_variant" }),
			ui.label({ text = guidance(), fontSize = 13, color = "on_surface_variant", textAlign = "center" }),
		}))
	end

	-- The model rather than the Bluetooth alias, which usually carries the
	-- owner's name ("Pixel Buds Pro von …").
	local title = noctalia.tr("panel.title")
	if snapshot.deviceFound == true and snapshot.model == "pro" then
		title = noctalia.tr("panel.model.pro")
	elseif snapshot.deviceFound == true and snapshot.model == "pro2" then
		title = noctalia.tr("panel.model.pro2")
	end

	panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.glyph({ name = "headphones", size = 28, color = hasBuds and "primary" or "on_surface_variant" }),
			ui.column({ flexGrow = 1, gap = 2 }, {
				ui.label({ text = title, fontSize = 16, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
				ui.label({ text = subtitle(), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
			}),
			ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
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

function onRefreshClicked()
	sendCommand("refresh", nil)
end

function onCloseClicked()
	panel.close()
end
