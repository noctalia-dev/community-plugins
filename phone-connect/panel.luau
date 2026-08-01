-- panel.luau
-- Phone Connect - details panel (layered info-style UI, 500x600).
--
-- Layout: header + device hero + info grid span the top (full width); below
-- them a two-column row: left (flex, scrollable) holds media control + SMS
-- composer; right (fixed width) holds action buttons stacked vertically.
-- Reads state from the service entry; sends commands via "pc.cmd".


-- Local translation: reads from pc.trTable (published by service) so users
-- can switch language at runtime, unlike noctalia.tr() which follows system locale.
local function t(key)
	local table = noctalia.state.get("pc.trTable") or {}
	return table[key] or key
end

local PLUGIN_ID = "icefish/phone-connect"

-- ── Command channel ─────────────────────────────────────────────────────────
local function sendCmd(cmd)
	-- time-based seq prevents silent drops after hot-reload
	cmd.seq = math.floor(os.clock() * 1000000)
	noctalia.state.set("pc.cmd", cmd)
end

-- ── SMS composer local state (ui.input is uncontrolled) ─────────────────────
local smsDestination = ""
local smsMessage = ""

-- ── Media slider drag state (freeze value while dragging) ──────────────────
-- slider is controlled: value is reset every render. While the user drags,
-- we freeze value to their position so the 1s service refresh doesn't yank
-- the slider back. Keyed by device id so multi-device switching is clean.
local dragState = {}   -- [deviceId] = { dragging = true, position = <ms> }

-- ── Helpers ─────────────────────────────────────────────────────────────────
local function glyphForType(t)
	if t == "tablet" then return "device-tablet" end
	if t == "laptop" then return "device-laptop" end
	if t == "desktop" or t == "computer" then return "device-desktop" end
	if t == "tv" then return "device-tv" end
	return "device-mobile"
end

local function batteryGlyph(charge, charging)
	if charging then return "battery-charging" end
	if type(charge) ~= "number" then return "battery" end
	if charge >= 90 then return "battery" end
	if charge >= 60 then return "battery-3" end
	if charge >= 30 then return "battery-2" end
	if charge > 0 then return "battery-1" end
	return "battery-off"
end

local function infoCell(label, value, glyph)
	return ui.column({ gap = 2, padding = 6, radius = 6, fill = "surface/0.5", flexGrow = 1 }, {
		ui.row({ gap = 6, align = "center" }, {
			ui.glyph({ name = glyph, size = 13, color = "on_surface_variant" }),
			ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
		}),
		ui.label({ text = value, fontSize = 13, fontWeight = "medium", color = "on_surface" }),
	})
end

-- ── Device hero card (top, full width) ──────────────────────────────────────
local function heroCard(d)
	local reachable = d.isReachable == true
	local paired = d.isPaired == true
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	local name = aliasMap[d.id] or d.name or "Your-Phone"
	local glyph = glyphForType(d.type)
	local imgMap = noctalia.state.get("pc.imageMap") or {}
	local imgPath = imgMap[d.id]
	-- verify custom image exists
	if imgPath and imgPath ~= "" and not noctalia.fileExists(imgPath) then
		imgPath = nil
	end
	local statusText, statusColor
	if not reachable then
		statusText = paired and t("status.offline") or t("status.not_paired")
		statusColor = "on_surface_variant"
	else
		statusText = t("status.connected")
		statusColor = "primary"
	end
	local charge = d.batteryCharge
	local chargeText = (type(charge) == "number" and charge >= 0)
		and (tostring(charge) .. "%") or "--"
	local chargeColor = "on_surface"
	if type(charge) == "number" and charge <= 20 then chargeColor = "error" end

	return ui.column({ gap = 8, padding = 14, radius = 10, fill = "surface/0.7",
		border = "primary/0.2", borderWidth = 1 }, {
		ui.row({ gap = 14, align = "center" }, {
			imgPath and ui.image({ path = imgPath, width = 52, height = 52, radius = 26, fit = "cover" })
				or ui.box({ width = 52, height = 52, radius = 26, fill = "primary/0.15" }, {
					ui.glyph({ name = glyph, size = 28, color = "primary" }),
				}),
			ui.column({ gap = 4, flexGrow = 1 }, {
				ui.label({ text = name, fontSize = 17, fontWeight = "bold", color = "on_surface" }),
				ui.row({ radius = 10, fill = statusColor .. "/0.15", padding = 4 }, {
					ui.label({ text = statusText, fontSize = 11, color = statusColor }),
				}),
			}),
			ui.column({ gap = 2, align = "center" }, {
				ui.glyph({ name = batteryGlyph(charge, d.batteryCharging), size = 22,
					color = chargeColor }),
				ui.label({ text = chargeText, fontSize = 13, fontWeight = "bold", color = chargeColor }),
			}),
		}),
	})
end

-- ── Info grid (top, full width) ──────────────────────────────────────────────
local function infoGrid(d)
	local charge = d.batteryCharge
	local chargeVal = (type(charge) == "number" and charge >= 0)
		and (tostring(charge) .. "%" .. (d.batteryCharging and " ⚡" or "")) or "--"
	local netVal = (d.networkType and d.networkType ~= "")
		and (d.networkType .. (type(d.networkStrength) == "number"
			and d.networkStrength >= 0 and (" • " .. tostring(d.networkStrength) .. "/4") or ""))
		or "--"
	local pairVal = d.isPaired and t("panel.paired") or t("panel.unpaired")
	local typeVal = d.type or t("panel.unknown")
	return ui.row({ gap = 8 }, {
		infoCell(t("panel.battery"), chargeVal, "battery"),
		infoCell(t("panel.network"), netVal, "antenna"),
		infoCell(t("panel.pairing"), pairVal, "link"),
		infoCell(t("panel.type"), typeVal, "device-mobile"),
	})
end

-- ── Right column: action buttons stacked vertically ─────────────────────────
local function vActionBtn(text, glyph, onClick, variant)
	return ui.button({ text = text, glyph = glyph, variant = variant or "outline",
		controlSize = "md", onClick = onClick })
end

local function rightColumn(d)
	local reachable = d.isReachable == true
	local paired = d.isPaired == true
	local btns = {}
	if reachable and paired then
		table.insert(btns, vActionBtn(t("action.ring"), "bell-ringing",
			function() sendCmd({ op = "ring", device = d.id }) end, "primary"))
		table.insert(btns, vActionBtn(t("action.ping"), "message",
			function() sendCmd({ op = "ping", device = d.id }) end))
		table.insert(btns, vActionBtn(t("action.browse"), "folder",
			function() sendCmd({ op = "browse", device = d.id }) end))
		table.insert(btns, vActionBtn(t("action.sms"), "message-2",
			function() sendCmd({ op = "launch_sms_app", device = d.id }) end))
		if noctalia.getConfig("enable_clipboard_action") then
			table.insert(btns, vActionBtn(t("action.clipboard"), "clipboard",
				function() sendCmd({ op = "clipboard", device = d.id }) end))
		end
		table.insert(btns, vActionBtn(t("action.share"), "share",
			function()
				local clip = noctalia.clipboardText()
				if clip then sendCmd({ op = "share_text", device = d.id, text = clip }) end
			end))
		table.insert(btns, vActionBtn(t("action.unpair"), "link-off",
			function() sendCmd({ op = "unpair", device = d.id }) end, "ghost"))
	elseif not paired then
		table.insert(btns, vActionBtn(t("action.pair"), "link",
			function() sendCmd({ op = "pair", device = d.id }) end, "primary"))
	else
		table.insert(btns, vActionBtn(t("action.unpair"), "link-off",
			function() sendCmd({ op = "unpair", device = d.id }) end, "ghost"))
	end
	return ui.column({ width = 110, gap = 8, padding = 8, align = "stretch" }, btns)
end

-- ── Left column: media + SMS (scrollable) ──────────────────────────────────
local function fmtTime(ms)
	if type(ms) ~= "number" or ms <= 0 then return "0:00" end
	local s = math.floor(ms / 1000)
	local m = math.floor(s / 60)
	s = s % 60
	return string.format("%d:%02d", m, s)
end

local function mediaSection(d)
	local title = d.mediatitle
	if not title or title == "" then return nil end
	local artist = d.mediaartist or ""
	local album = d.mediaalbum or ""
	local playing = d.mediaisPlaying == true
	local volume = tonumber(d.mediavolume) or 0
	local length = tonumber(d.medialength) or 0
	local position = tonumber(d.mediaposition) or 0
	local canSeek = d.mediacanSeek == true
	local artUrl = d.mediaArtPath

	-- only use art if the file exists (phone path via SFTP mount)
	if artUrl and artUrl ~= "" and not noctalia.fileExists(artUrl) then
		artUrl = nil
	end

		local header = ui.row({ gap = 6, align = "center" }, {
			ui.glyph({ name = "music", size = 13, color = "primary" }),
			ui.label({ text = t("panel.now_playing"), fontSize = 10,
				color = "primary", fontWeight = "bold", flexGrow = 1 }),
		})

		local titleBlock
		if artUrl then
			titleBlock = ui.row({ gap = 8, align = "center" }, {
				ui.image({ path = artUrl, width = 32, height = 32, radius = 4, fit = "cover" }),
				ui.column({ gap = 1, flexGrow = 1 }, {
					ui.label({ text = title, fontSize = 12, fontWeight = "medium", color = "on_surface" }),
					ui.label({ text = artist, fontSize = 10, color = "on_surface_variant" }),
					ui.label({ text = album, fontSize = 9, color = "on_surface_variant" }),
				}),
			})
		else
			titleBlock = ui.column({ gap = 1 }, {
				ui.label({ text = title, fontSize = 12, fontWeight = "medium", color = "on_surface" }),
				ui.label({ text = artist, fontSize = 10, color = "on_surface_variant" }),
				ui.label({ text = album, fontSize = 9, color = "on_surface_variant" }),
			})
		end

		local transport = ui.row({ gap = 4, align = "center" }, {
			ui.button({ glyph = "player-skip-back", variant = "ghost", controlSize = "sm",
				onClick = function() sendCmd({ op = "media", device = d.id, action = "Previous" }) end }),
			ui.button({ glyph = playing and "player-pause" or "player-play",
				variant = "primary", controlSize = "sm",
				onClick = function() sendCmd({ op = "media", device = d.id, action = "PlayPause" }) end }),
			ui.button({ glyph = "player-skip-forward", variant = "ghost", controlSize = "sm",
				onClick = function() sendCmd({ op = "media", device = d.id, action = "Next" }) end }),
			ui.button({ glyph = "player-stop", variant = "ghost", controlSize = "sm",
				onClick = function() sendCmd({ op = "media", device = d.id, action = "Stop" }) end }),
		})

	local progress
		if canSeek and length > 0 then
			local st = dragState[d.id]
			local sliderValue = (st and st.dragging and st.position) or position
			progress = ui.column({ gap = 2 }, {
				ui.slider({ min = 0, max = length, step = 1000, value = sliderValue,
					controlSize = "sm",
					onChange = function(v)
						dragState[d.id] = { dragging = true, position = tonumber(v) or position }
					end,
					onDragEnd = function()
						local st2 = dragState[d.id]
						local target = (st2 and st2.position) or position
						dragState[d.id] = nil
						sendCmd({ op = "media_seek", device = d.id, offset = tostring(target) })
					end }),
				ui.row({ justify = "space_between" }, {
					ui.label({ text = fmtTime(sliderValue), fontSize = 9, color = "on_surface_variant" }),
					ui.label({ text = fmtTime(length), fontSize = 9, color = "on_surface_variant" }),
				}),
			})
		end

		local children = { header, titleBlock, transport }
		if progress then table.insert(children, progress) end
		return ui.column({ gap = 6, padding = 8, radius = 8, fill = "primary/0.08" }, children)
end

local function smsComposer(d)
	return ui.column({ gap = 8, padding = 12, radius = 8, fill = "surface/0.5",
		border = "on_surface/0.1", borderWidth = 1 }, {
		ui.label({ text = t("panel.sms"), fontSize = 12, fontWeight = "bold",
			color = "on_surface" }),
		ui.input({ key = "sms-dest", placeholder = t("panel.sms_dest"),
			value = smsDestination, controlSize = "sm",
			onChange = function(v) smsDestination = v end }),
		ui.input({ key = "sms-msg", placeholder = t("panel.sms_msg"),
			value = smsMessage, controlSize = "sm",
			onChange = function(v) smsMessage = v end }),
		ui.button({ text = t("panel.sms_send"), glyph = "send",
			variant = "primary", controlSize = "sm",
			onClick = function()
				if smsDestination ~= "" and smsMessage ~= "" then
					sendCmd({ op = "sms_send", device = d.id,
						destination = smsDestination, text = smsMessage })
					smsMessage = ""
					render()
				end
			end }),
	})
end

local function leftColumn(d)
	local items = {}
	local media = mediaSection(d)
	if media then table.insert(items, media) end
	if d.isReachable and d.isPaired then
		table.insert(items, smsComposer(d))
	end
	-- if nothing to show, a placeholder so the column isn't empty
	if #items == 0 then
		table.insert(items, ui.column({ gap = 8, padding = 20, align = "center" }, {
			ui.glyph({ name = "music-off", size = 28, color = "on_surface_variant" }),
			ui.label({ text = t("panel.no_media"), color = "on_surface_variant" }),
		}))
	end
	return ui.column({ width = 304, flexGrow = 1 }, {
		ui.scroll({ flexGrow = 1, gap = 12, padding = 0 }, items),
	})
end

-- ── Device switcher (bottom, full width, only if >1 device) ─────────────────
local function switcher(devices, order, sel)
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	if #order <= 1 then return nil end
	local items = {}
	for _, id in ipairs(order) do
		local d = devices[id]
		if d then
			local isSel = id == sel
			table.insert(items, ui.row({
				key = "sw-" .. id, gap = 8, align = "center", padding = 8, radius = 6,
				fill = isSel and "primary/0.12" or "surface/0.4",
				onClick = function() sendCmd({ op = "select", device = id }) end,
			}, {
				ui.glyph({ name = glyphForType(d.type), size = 14,
					color = d.isReachable and "primary" or "on_surface_variant" }),
					ui.label({ text = aliasMap[id] or d.name or "Your-Phone", fontSize = 12, flexGrow = 1, color = "on_surface" }),
				ui.label({ text = (type(d.batteryCharge) == "number" and d.batteryCharge >= 0)
					and (tostring(d.batteryCharge) .. "%") or "", fontSize = 10,
					color = "on_surface_variant" }),
			}))
		end
	end
	return ui.column({ gap = 4, padding = 8, radius = 8, fill = "surface/0.3" }, items)
end

-- ── Main render ─────────────────────────────────────────────────────────────
function render()
	local backend = noctalia.state.get("pc.backend") or { available = false }
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local sel = noctalia.state.get("pc.selected")
	if not sel or not devices[sel] then sel = order[1] end

	local body = {}
	-- header (full width top)
	table.insert(body, ui.row({ gap = 8, align = "center" }, {
		ui.glyph({ name = "device-mobile", size = 18, color = "primary" }),
		ui.label({ text = t("panel.title"), fontSize = 16, fontWeight = "bold",
			color = "on_surface", flexGrow = 1 }),
		ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm",
			onClick = function() sendCmd({ op = "refresh" }) end }),
		ui.button({ glyph = "close", variant = "ghost", controlSize = "sm",
			onClick = function() panel.close() end }),
	}))

	if not backend.available then
		table.insert(body, ui.column({ gap = 8, padding = 40, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "phone-off", size = 40, color = "on_surface_variant" }),
			ui.label({ text = t("status.no_backend"), color = "on_surface_variant" }),
		}))
	elseif not sel or not devices[sel] then
		table.insert(body, ui.column({ gap = 8, padding = 40, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "phone-off", size = 40, color = "on_surface_variant" }),
			ui.label({ text = t("panel.empty"), color = "on_surface_variant" }),
		}))
	else
		local d = devices[sel]
		-- top: hero + info (full width)
		table.insert(body, heroCard(d))
		table.insert(body, infoGrid(d))
		-- middle: two-column row (left content flex, right actions fixed)
		table.insert(body, ui.row({ gap = 14, flexGrow = 1, align = "stretch", justify = "center" }, {
			leftColumn(d),
			rightColumn(d),
		}))
		-- bottom: device switcher (only if multiple devices)
		local sw = switcher(devices, order, sel)
		if sw then table.insert(body, sw) end
	end

	panel.render(ui.column({ gap = 10, padding = 12 }, body))
end

function onOpen(_context) render() end
function onClose() end

noctalia.state.watch("pc.devices", render)
noctalia.state.watch("pc.order", render)
noctalia.state.watch("pc.selected", render)
noctalia.state.watch("pc.backend", render)
noctalia.state.watch("pc.imageMap", render)
noctalia.state.watch("pc.trTable", render)
noctalia.state.watch("pc.aliasMap", render)
