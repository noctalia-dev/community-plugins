-- panel.luau  —  merged UI: device card / media / SMS / toolbar / scrcpy cast
-- adb devices (id prefixed "adb:") show cast/stop, cast params, disconnect in right column.
-- Params read via lib/persistence, write via pc.cmd.
local persistence = require("./lib/persistence.luau")
local common = require("./lib/common.luau")
local t, sendCmd = common.t, common.sendCmd

local function tr(key, fb)
	local v = t(key); if not v or v == key then return fb or key end; return v
end

local smsDrafts, smsFavorites, mediaDragState, deviceNameEdits, favNameEdits = {}, persistence.loadFavorites(), {}, {}, {}
local isConnectMode, castPort, castDebugPort, castCode, connectAddr, smsDestRev = false, "", "", "", "", 0

local function draftFor(id)
	id = id or "default"; if not smsDrafts[id] then smsDrafts[id] = { dest = "", msg = "" } end; return smsDrafts[id]
end

-- Per-device param cache — prevents disk reads from overwriting in-memory slider changes
local paramCache = {}
local function paramsFor(adbId)
	if not paramCache[adbId] then paramCache[adbId] = persistence.loadParams(adbId) end; return paramCache[adbId]
end

local PRESETS = {
	hd = { max_size = 1920, bit_rate = 16, max_fps = 60 },
	perf = { max_size = 1280, bit_rate = 8, max_fps = 60 },
	save = { max_size = 1024, bit_rate = 4, max_fps = 30 },
}

-- Derived from values (not separate state) to be immune to slider onChange echo
local function detectPreset(p)
	for k, v in pairs(PRESETS) do
		if p.max_size == v.max_size and p.bit_rate == v.bit_rate and p.max_fps == v.max_fps then return k end
	end
	return "custom"
end

-- Resolve adb cast target for a device
local function castTarget(d)
	if not d then return { adbId = "device", ip = nil, online = false, transport = "wifi" } end
	local all = noctalia.state.get("pc.devices") or {}
	local adbId = d.source == "adb" and d.adbId or d.adbId or (d.ipv4 and (d.ipv4 .. ":5555")) or (d.id and ("kde:" .. d.id)) or d.id or "device"
	local ad = all["adb:" .. adbId] or all[adbId]
	return { adbId = adbId, ip = ad and ad.ip or (d.source ~= "adb" and d.ipv4) or common.ipFromSerial(adbId),
		online = ad and ad.isReachable == true or false, transport = ad and ad.transport or "wifi" }
end

-- ── Helpers ─────────────────────────────────────────────────────────────────
local function fmtTime(ms)
	if type(ms) ~= "number" or ms <= 0 then return "0:00" end
	local s = math.floor(ms / 1000)
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function truncate(s, limit)
	if not s or s == "" then return "" end
	local len = utf8.len(s)
	if not len then return (#s > limit) and (s:sub(1, limit) .. "…") or s end
	if len <= limit then return s end
	local cut = utf8.offset(s, limit + 1)
	return (cut and s:sub(1, cut - 1) or s) .. "…"
end

local function isDeviceConnected(d)
	return d and d.id ~= "default" and ((d.source == "adb" and d.isReachable == true) or (d.isPaired == true and d.isReachable == true)) or false
end
local function isDeviceOffline(d)
	return d and d.id ~= "default" and not isDeviceConnected(d) and d.source ~= "adb" and d.isPaired == true or false
end

-- Notify with the right error for offline / disconnected; returns true if NOT connected
local function notifyIfDisconnected(d)
	if isDeviceConnected(d) then return false end
	if isDeviceOffline(d) then
		noctalia.notifyError(tr("status.offline", "Offline"), tr("error.device_offline_hint", "Device is offline."))
	else
		noctalia.notifyError(tr("error.no_device", "No device connected"), tr("error.no_device_hint", "Connect a device first."))
	end
	return true
end

-- Themed input — avoids repeating 5 style props on every ui.input call
local function mkInput(p)
	p.controlSize = "sm"; p.paddingH = 4; p.fill = "surface/0.8"
	p.border = "outline/0.3"; p.borderWidth = 1; p.radius = 8
	return ui.input(p)
end

-- Resolve drag-frozen slider value; clears stale drag state as side effect
local function frozenDragValue(stateMap, id, fallback)
	local st = id and stateMap[id] or nil
	if st and st.dragging then
		if (os.clock() - (st.at or 0)) < 2.0 then return st.position, true end
		stateMap[id] = nil
	end
	return fallback, false
end

-- ── Device sidebar ──────────────────────────────────────────────────────────
local function deviceSidebar(visibleOrder, devices, sel)
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	local paired, available = {}, {}
	for _, id in ipairs(visibleOrder) do
		local d = devices[id]
		if d then
			local target = paired
			if d.source ~= "adb" and d.isPaired ~= true then target = available end
			table.insert(target, id)
		end
	end

	local items = {}
	for _, id in ipairs(paired) do
		local d = devices[id]
		local isSel = id == sel
		local name = aliasMap[id] or d.name or "Device"
		local reachable = (d.source == "adb" and d.isReachable == true)
			or (d.isPaired == true and d.isReachable == true)
		local status = reachable and tr("status.connected", "Connected")
			or (d.source == "adb" and tr("status.disconnected", "Disconnected")
			or tr("status.offline", "Offline"))
		local isAdb = d.source == "adb"
		local actionBtn = ui.button({ key = "unp-" .. id,
			glyph = isAdb and "plug-off" or "link-off",
			variant = "ghost", controlSize = "sm", glyphSize = 13,
			tooltip = tr(isAdb and "action.disconnect" or "action.unpair", isAdb and "Disconnect" or "Unpair"),
			onClick = function()
				if isAdb then sendCmd({ op = "adb_disconnect", device = d.adbId })
				else sendCmd({ op = "unpair", device = id }) end
			end })
		table.insert(items, ui.row({
			key = "dev-" .. id, gap = 6, paddingH = 8, paddingV = 6, radius = 8, align = "center",
			fill = isSel and "primary/0.12" or "surface/0.8", border = isSel and "primary/0.3" or nil, borderWidth = isSel and 1 or 0,
			onClick = function() sendCmd({ op = "select", device = id }) end,
		}, {
			ui.column({ gap = 1, flexGrow = 1, minWidth = 0 }, {
				ui.label({ text = name, fontSize = 13, fontWeight = isSel and "bold" or "normal", color = "on_surface", maxLines = 1 }),
				ui.label({ text = status, fontSize = 11, color = reachable and "primary" or "on_surface_variant" }),
			}),
			actionBtn,
		}))
	end

	if #available > 0 then
		table.insert(items, ui.label({ text = tr("panel.available", "AVAILABLE"), fontSize = 11,
			fontWeight = "bold", color = "on_surface_variant", paddingH = 4, paddingV = 4 }))
		for _, id in ipairs(available) do
			local d = devices[id]
			table.insert(items, ui.row({ key = "dev-" .. id, gap = 6, paddingH = 8, paddingV = 6, radius = 8, fill = "surface/0.3", align = "center" }, {
				ui.label({ text = d.name or "Device", fontSize = 13, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
				ui.button({ key = "pair-" .. id, glyph = "link", variant = "ghost", controlSize = "sm", glyphSize = 13,
					tooltip = tr("action.pair", "Pair"), onClick = function() sendCmd({ op = "pair", device = id }) end }),
			}))
		end
	end

	local kids = {
		ui.row({ align = "center", justify = "space_between", paddingH = 5, paddingV = 0 }, {
			ui.label({ text = tr("panel.devices", "DEVICES"), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
			ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm",
				tooltip = tr("action.refresh", "Refresh"),
				onClick = function() sendCmd({ op = "refresh" }) end }),
		}),
	}
	if #items > 0 then
		table.insert(kids, ui.scroll({ key = "dev-scroll", flexGrow = 1, gap = 4 }, items))
	else
		table.insert(kids, ui.column({ flexGrow = 1, align = "center", justify = "center" }, {
			ui.label({ text = tr("panel.empty", "No devices found. Pair a device in KDE Connect."),
				fontSize = 12, color = "on_surface_variant", textAlign = "center" }),
		}))
	end
	return ui.column({ key = "sidebar", gap = 6, flexGrow = 1,
		fill = "surface_variant/0.8", radius = 12, padding = 6 }, kids)
end

-- ── Tools card ──────────────────────────────────────────────────────────────
local function toolsCard(d)
	local defs = {
		{ "t-ring", "bell-ringing", "action.ring", "Ring", "ring" },
		{ "t-ping", "message", "action.ping", "Ping", "ping" },
		{ "t-browse", "folder", "action.browse", "Browse", "browse" },
		{ "t-share", "share", "action.share", "Share", "pick_share" },
	}
	if noctalia.getConfig("enable_clipboard_action") then table.insert(defs, 3, { "t-clip", "clipboard", "action.clipboard", "Clipboard", "clipboard" }) end
	local btns = {}
	for _, def in ipairs(defs) do
		table.insert(btns, ui.button({
			key = def[1], glyph = def[2], variant = "ghost", controlSize = "sm", glyphSize = 18, width = 36, height = 36,
			tooltip = tr(def[3], def[4]),
			onClick = function() if not notifyIfDisconnected(d) then sendCmd({ op = def[5], device = d.id }) end end,
		}))
	end
	return ui.row({ key = "tools-card", gap = 2, paddingH = 5, paddingV = 5, radius = 12, fill = "surface_variant/0.8", align = "center", justify = "space_between" }, btns)
end

-- ── Dashboard card ──────────────────────────────────────────────────────────
local function dashboardCard(d)
	local connected, offline = isDeviceConnected(d), isDeviceOffline(d)
	local isKde = d.source ~= "adb"
	local devId = isKde and (d.id or "device") or (d.adbId and ("adb:" .. d.adbId) or (d.id or "device"))
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	local name = aliasMap[devId] or d.name or "Device"
	local imgMap = noctalia.state.get("pc.imageMap") or {}
	local imgPath = isKde and imgMap[d.id] or nil
	if imgPath and imgPath ~= "" and not noctalia.fileExists(imgPath) then imgPath = nil end
	local glyph = isKde and common.deviceGlyph(d) or (d.transport == "wifi" and "wifi" or "usb")

	local function pickImage()
		if connected and isKde then sendCmd({ op = "pick_image", device = d.id }) end
	end
	local function commitName(v)
		local n = (v or ""):gsub("^%s+", ""):gsub("%s+$", "")
		deviceNameEdits[devId] = nil
		if connected and isKde then sendCmd({ op = "set_alias", device = d.id, alias = n }) end
		render()
	end

	-- Profile picture
	local pfp
	if connected and imgPath then
		pfp = ui.image({ path = imgPath, width = 54, height = 54, radius = 10, fit = "cover", onClick = pickImage })
	elseif connected then
		pfp = ui.column({ width = 54, height = 54, radius = 10, fill = "primary/0.15",
			align = "center", justify = "center", onClick = pickImage },
			{ ui.glyph({ name = glyph, size = 30, color = "primary" }) })
	elseif offline and imgPath then
		pfp = ui.image({ path = imgPath, width = 54, height = 54, radius = 10, fit = "cover", opacity = 0.45 })
	else -- offline without image, or fully disconnected
		pfp = ui.column({ width = 54, height = 54, radius = 10, fill = "surface/0.8",
			border = "outline/0.2", borderWidth = 1, align = "center", justify = "center" },
			{ ui.glyph({ name = offline and glyph or "device-mobile-off",
				size = offline and 30 or 26, color = "on_surface_variant" }) })
	end

	-- Device name
	local nameEl
	if connected and deviceNameEdits[devId] then
		nameEl = mkInput({ key = "name-edit", value = name, placeholder = name, width = 120, onSubmit = commitName })
	elseif connected then
		nameEl = ui.row({ gap = 4, align = "center", flexGrow = 1, minWidth = 0,
			onClick = function() deviceNameEdits[devId] = true; render() end }, {
			ui.label({ text = name, fontSize = 14, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
			ui.glyph({ name = "pencil", size = 11, color = "on_surface_variant" }),
		})
	else
		nameEl = ui.label({ text = offline and name or tr("status.disconnected", "Disconnected"),
			fontSize = 14, fontWeight = "bold", flexGrow = 1, maxLines = 1,
			color = offline and "on_surface" or "on_surface_variant" })
	end

	-- Battery (connected KDE only)
	local battEl = nil
	if connected and isKde then
		local charge, hasCharge = d.batteryCharge, type(d.batteryCharge) == "number" and d.batteryCharge >= 0
		local charging = d.batteryCharging == true
		local cc = hasCharge and charge <= 20 and "error" or "on_surface"
		battEl = ui.row({ gap = 3, align = "center" }, {
			ui.glyph({ name = common.batteryGlyph(charge, charging), size = 16, color = cc }),
			ui.label({ text = hasCharge and (tostring(charge) .. "%") or "--", fontSize = 13, fontWeight = "medium", color = cc }),
			charging or nil,
		})
	end

	-- Status row
	local statusRow = nil
	if connected then
		local wg, ipText
		if isKde then
			local s = d.networkStrength
			local tiers = { "wifi-0", "wifi-1", "wifi-2", "wifi-3", "wifi" }
			wg = (type(s) == "number" and s >= 0) and tiers[math.min(5, s > 4 and math.floor(s/20)+1 or s+1)] or "wifi"
			ipText = d.ipv4 or "--"
			if d.ipv6 then ipText = ipText .. " | " .. d.ipv6 end
		else
			wg = d.transport == "usb" and "usb" or "wifi"; ipText = d.adbId or "--"
		end
		statusRow = ui.row({ gap = 4, align = "center" }, {
			ui.glyph({ name = wg, size = 15, color = "primary" }),
			ui.label({ text = ipText, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
		})
	elseif offline then
		statusRow = ui.row({ gap = 4, align = "center" }, {
			ui.glyph({ name = "wifi-off", size = 15, color = "on_surface_variant" }),
			ui.label({ text = tr("status.offline", "Offline"), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
		})
	end

	local infoKids = { ui.row({ gap = 4, align = "center", justify = "space_between" }, { nameEl, battEl }) }
	if statusRow then table.insert(infoKids, statusRow) end

	return ui.column({ key = "dashboard", gap = 4, paddingV = 6, paddingH = 10, radius = 12,
		fill = "surface_variant/0.8" }, {
		ui.row({ gap = 6, align = "center" }, {
			pfp, ui.column({ gap = 2, flexGrow = 1, minWidth = 0, justify = "center" }, infoKids),
		}),
	})
end

-- ── Cast & connect card ─────────────────────────────────────────────────────
local function castCard(d)
	local target = castTarget(d)
	if not target then return nil end
	local adbId, params = target.adbId, paramsFor(target.adbId)
	local casting = (noctalia.state.get("pc.running") or {})[adbId] == true

	local function commit(saveCust)
		persistence.saveParams(adbId, params)
		if saveCust then persistence.saveCustom(adbId, params) end
		sendCmd({ op = "restart_params", device = adbId, params = params })
	end
	local function startCast()
		if target.online then sendCmd({ op = "cast", device = adbId, params = params }); return end
		if target.ip then
			local dbg = castDebugPort ~= "" and castDebugPort
				or (connectAddr ~= "" and (connectAddr:match(":(%d+)$") or connectAddr)) or "5555"
			if castPort ~= "" and castCode ~= "" then
				local port = castPort:match(":(%d+)$") or castPort
				local ip = castPort:match("^(%d+%.%d+%.%d+%.%d+)") or target.ip
				sendCmd({ op = "pair_and_cast", address = ip, port = port,
					debugPort = dbg, code = castCode, params = params })
			else
				sendCmd({ op = "pair_and_cast", address = target.ip, port = "",
					debugPort = dbg, code = "", params = params })
			end
			return
		end
		noctalia.notifyError(tr("error.cast_failed", "Cast failed"),
			tr("panel.cast_offline_hint", "Device is not reachable by adb. Check the USB cable / wireless debugging, then retry."))
	end

	local cur = detectPreset(params)
	local children = {}

	-- Preset buttons
	local function presetBtn(key, label, p)
		return ui.button({ key = "pre-" .. key, text = label,
			variant = cur == key and "secondary" or "ghost", controlSize = "sm",
			onClick = function()
				if key == "custom" then
					local c = persistence.loadCustom(adbId)
					if c then for k, v in pairs(c) do params[k] = v end; commit(false) end
				else
					for k, v in pairs(p) do params[k] = v end; commit(false)
				end
				render()
			end })
	end

	local modeLabel = isConnectMode and tr("action.connect", "Connect") or tr("action.pair", "Pair")
	table.insert(children, ui.row({ align = "center", justify = "space_between", paddingV = 1 }, {
		ui.row({ gap = 6, align = "center" }, {
			ui.toggle({ key = "pair-mode-toggle", checked = isConnectMode, tooltip = modeLabel,
				onChange = function(v) isConnectMode = (v == true or v == "true"); render() end }),
			ui.label({ text = modeLabel, fontSize = 12, fontWeight = "medium", color = "on_surface" }),
		}),
		ui.row({ gap = 2, padding = 2, radius = 8, fill = "surface/0.8", align = "center" }, {
			presetBtn("hd", tr("panel.preset_hd", "HD"), PRESETS.hd),
			presetBtn("perf", tr("panel.preset_perf", "Bal"), PRESETS.perf),
			presetBtn("save", tr("panel.preset_save", "Save"), PRESETS.save),
			presetBtn("custom", tr("panel.preset_custom", "Cust"), nil),
		}),
	}))

	-- Connection / pairing controls
	if target.online then
		table.insert(children, ui.row({ gap = 6, align = "center", padding = 5, radius = 8, fill = "surface/0.8" }, {
			ui.glyph({ name = target.transport == "usb" and "usb" or "wifi", size = 14, color = "primary" }),
			ui.label({ text = string.format("%s (%s)", target.ip or adbId, tr("status.connected", "Connected")),
				fontSize = 11, color = "on_surface", flexGrow = 1 }),
			ui.button({ glyph = "plug-off", tooltip = tr("action.disconnect", "Disconnect"), variant = "ghost",
				controlSize = "sm", glyphSize = 15, width = 36, height = 32,
				onClick = function() sendCmd({ op = "adb_disconnect", device = adbId }) end }),
		}))
	elseif isConnectMode then
		local ph = (target.ip and (target.ip .. ":debugport")) or "ip:debugport"
		local function doConnect()
			local trimmed = (connectAddr or ""):gsub("^%s+", ""):gsub("%s+$", "")
			local full = trimmed:find(":") and trimmed or nil
			if not full then
				local ip = target.ip or common.ipFromSerial(adbId)
				if ip then full = ip .. ":" .. (trimmed ~= "" and trimmed or "5555") end
			end
			if full then sendCmd({ op = "adb_connect", address = full })
			else noctalia.notifyError(tr("error.conn_failed", "Wireless connection failed"),
				tr("error.conn_hint", "Could not connect to the debug port.")) end
		end
		table.insert(children, ui.row({ gap = 4, align = "center" }, {
			mkInput({ key = "connect-addr-input", placeholder = ph, value = connectAddr,
				fontSize = 12, flexGrow = 1, tooltip = tr("action.connect", "Connect") .. " (ip:debugport)",
				onChange = function(v) connectAddr = v end, onSubmit = doConnect }),
			ui.button({ key = "conn-btn", glyph = "plug", tooltip = tr("action.connect", "Connect"),
				variant = "primary", controlSize = "sm", glyphSize = 16, width = 36, height = 32,
				onClick = doConnect }),
		}))
	else
		local function doPair()
			local full = castPort:find(":") and castPort or ((target.ip or "") .. ":" .. castPort)
			if full ~= "" and castCode ~= "" then
				sendCmd({ op = "adb_pair", address = full, code = castCode })
				isConnectMode = true
				if castDebugPort ~= "" then
					local ip = castPort:match("^(%d+%.%d+%.%d+%.%d+)") or target.ip or common.ipFromSerial(adbId)
					if ip then
						sendCmd({ op = "adb_connect",
							address = castDebugPort:find(":") and castDebugPort or (ip .. ":" .. castDebugPort) })
					end
				end
				render()
			else
				noctalia.notifyError(tr("error.pair_failed", "Pairing failed"),
					tr("panel.pair_missing", "Enter both the pairing port and code first."))
			end
		end
		table.insert(children, ui.row({ gap = 4, align = "center" }, {
			mkInput({ key = "pair-port-input", placeholder = tr("panel.pair_port_placeholder", "Pair port"),
				value = castPort, fontSize = 12, flexGrow = 1,
				tooltip = tr("panel.pair_port_placeholder", "Pair port") .. " (5 digits)",
				onChange = function(v) castPort = v end, onSubmit = doPair }),
			mkInput({ key = "pair-debug-input", placeholder = tr("panel.debug_port_placeholder", "Debug port"),
				value = castDebugPort, fontSize = 12, width = 120,
				tooltip = tr("panel.debug_port_placeholder", "Debug port") .. " (5 digits)",
				onChange = function(v) castDebugPort = v end, onSubmit = doPair }),
			mkInput({ key = "pair-code-input", placeholder = "PIN", value = castCode,
				fontSize = 12, width = 80,
				tooltip = tr("panel.pair_code_placeholder", "Pairing code (6 digits)"),
				onChange = function(v) castCode = v end, onSubmit = doPair }),
			ui.button({ key = "pair-btn", glyph = "link", tooltip = tr("action.pair", "Pair"),
				variant = "primary", controlSize = "sm", glyphSize = 16, width = 36, height = 32,
				onClick = doPair }),
		}))
	end

	-- Slider rows: RES / BIT / FPS
	local rows = {}
	for _, s in ipairs({
		{ tr("panel.max_size","RES"), "s-res", "max_size", 256, 3840, 64, 1920, "p" },
		{ tr("panel.bit_rate","BIT"), "s-br",  "bit_rate", 1,   30,   1,  8,    "M" },
		{ tr("panel.max_fps","FPS"),  "s-fps", "max_fps",  1,   240,  1,  60,   "fps" },
	}) do
		local val = params[s[3]] or s[7]
		table.insert(rows, ui.row({ key = "row-" .. s[3], gap = 6, align = "center" }, {
			ui.label({ text = s[1], fontSize = 12, fontWeight = "bold", color = "on_surface_variant", width = 32 }),
			ui.slider({ key = s[2], min = s[4], max = s[5], step = s[6], value = val, controlSize = "sm", flexGrow = 1,
				onChange = function(v) params[s[3]] = tonumber(v); render() end, onDragEnd = function() commit(true); render() end }),
			ui.label({ text = tostring(val) .. s[8], fontSize = 11, textAlign = "end", color = "on_surface", width = 44 }),
		}))
	end

	table.insert(children, ui.row({ gap = 8, align = "center" }, {
		ui.column({ gap = 6, flexGrow = 1, minWidth = 0 }, rows),
		ui.column({ gap = 6, width = 105 }, {
			ui.button({ key = "rec-tog", glyph = "circle", text = tr("panel.record", "Record"),
				variant = params.record and "secondary" or "ghost", controlSize = "sm", width = 105, selected = params.record == true,
				tooltip = tr("panel.record_desc", "Record the mirror to a file"),
				onClick = function() params.record = not params.record; commit(true); render() end }),
			ui.button({ key = "scr-off", glyph = "device-mobile-off", text = tr("panel.turn_screen_off", "Screen Off"),
				variant = params.turn_screen_off and "secondary" or "ghost", controlSize = "sm", width = 105, selected = params.turn_screen_off == true,
				tooltip = tr("panel.turn_screen_off_desc", "Phone screen off while mirroring"),
				onClick = function() params.turn_screen_off = not params.turn_screen_off; commit(true); render() end }),
			ui.button({ key = "cast-btn", text = casting and tr("action.stop", "Stop") or tr("action.cast", "Cast"),
				glyph = casting and "player-stop" or "player-play", variant = casting and "destructive" or "primary", controlSize = "sm", width = 105,
				tooltip = casting and tr("action.stop", "Stop") or tr("action.cast", "Cast"),
				onClick = function() if casting then sendCmd({ op = "stop_cast", device = adbId }) else startCast() end end }),
		}),
	}))

	return ui.column({ key = "cast-card", gap = 6, padding = 8, radius = 12,
		fill = "surface_variant/0.8" }, children)
end

-- ── Messages card ───────────────────────────────────────────────────────────
local function messagesCard(d)
	local draft = draftFor(d.id)
	local query = (draft.dest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local isFav = false
	for _, f in ipairs(smsFavorites) do
		if f.number == draft.dest or (f.name ~= "" and f.name:lower() == query) then isFav = true; break end
	end

	local favItems = {}
	for _, fav in ipairs(smsFavorites) do
		local nMatch = fav.name ~= "" and fav.name:lower():find(query, 1, true) ~= nil
		local numMatch = fav.number:lower():find(query, 1, true) ~= nil
		if query == "" or nMatch or numMatch then
			local num = fav.number
			local sel = function() draftFor(d.id).dest = num; smsDestRev = smsDestRev + 1; render() end
			if favNameEdits[num] then
				local curName = fav.name
				local function commit(v)
					local val = (type(v) == "string" and v ~= "") and v or curName
					fav.name = (val or ""):gsub("^%s+", ""):gsub("%s+$", "")
					favNameEdits[num] = nil; persistence.saveFavorites(smsFavorites); render()
				end
				table.insert(favItems, ui.row({ key = "fav-edit-" .. num, gap = 4, paddingH = 6, paddingV = 2, radius = 6, fill = "surface", align = "center" }, {
					mkInput({ key = "fav-name-in-" .. num, value = curName, placeholder = tr("panel.contact_name", "Contact name"), flexGrow = 1, focus = true, onChange = function(v) curName = v end, onSubmit = commit }),
					ui.button({ glyph = "check", variant = "ghost", controlSize = "sm", glyphSize = 12, onClick = commit }),
					ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", glyphSize = 10, onClick = function() favNameEdits[num] = nil; render() end }),
				}))
			else
				table.insert(favItems, ui.row({ key = "fav-" .. num, gap = 6, paddingH = 6, paddingV = 3, radius = 6, fill = "surface", align = "center", onClick = sel }, {
					ui.glyph({ name = "star-filled", size = 11, color = "primary" }),
					ui.column({ gap = 0, flexGrow = 1, minWidth = 0, onClick = sel }, {
						fav.name ~= "" and ui.label({ text = fav.name, fontSize = 11, fontWeight = "bold", color = "on_surface", maxLines = 1 }) or nil,
						ui.label({ text = num, fontSize = fav.name ~= "" and 10 or 11, color = fav.name ~= "" and "on_surface_variant" or "on_surface", maxLines = 1 }),
					}),
					ui.button({ key = "fav-ren-" .. num, glyph = "pencil", variant = "ghost", controlSize = "sm", glyphSize = 10, tooltip = tr("panel.edit_name", "Edit contact name"), onClick = function() favNameEdits[num] = true; render() end }),
					ui.button({ key = "fav-rm-" .. num, glyph = "x", variant = "ghost", controlSize = "sm", glyphSize = 10, onClick = function()
						for i, f in ipairs(smsFavorites) do if f.number == num then table.remove(smsFavorites, i); break end end
						persistence.saveFavorites(smsFavorites); render()
					end }),
				}))
			end
		end
	end

	local function doSend()
		if notifyIfDisconnected(d) then return end
		local df = draftFor(d.id)
		if df.dest ~= "" and df.msg ~= "" then
			local destNum = df.dest
			for _, f in ipairs(smsFavorites) do
				if f.name ~= "" and f.name:lower() == df.dest:lower() then destNum = f.number; break end
			end
			sendCmd({ op = "sms_send", device = d.id, destination = destNum, text = df.msg })
			df.msg = ""; render()
		end
	end

	return ui.column({ key = "msgs", gap = 4, padding = 8, radius = 12, fill = "surface_variant/0.8", flexGrow = 1 }, {
		ui.row({ gap = 4, align = "center" }, {
			mkInput({ key = "sms-dest-" .. d.id .. "-" .. tostring(smsDestRev), placeholder = tr("panel.phone_placeholder", "1234567890"),
				tooltip = tr("panel.sms_dest", "Phone number"), value = draft.dest, flexGrow = 1, onChange = function(v) draftFor(d.id).dest = v; render() end,
				onSubmit = function(v)
					local q = (v or draft.dest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
					for _, f in ipairs(smsFavorites) do
						if q ~= "" and f.name ~= "" and (f.name:lower() == q or f.name:lower():find(q, 1, true)) then
							draftFor(d.id).dest = f.number; smsDestRev = smsDestRev + 1; render(); return
						end
					end
				end }),
			draft.dest ~= "" and ui.button({ key = "sms-clear", glyph = "x", variant = "ghost", controlSize = "sm", glyphSize = 12,
				tooltip = tr("panel.clear", "Clear"), onClick = function() draftFor(d.id).dest = ""; smsDestRev = smsDestRev + 1; render() end }) or nil,
			ui.button({ key = "fav-btn", glyph = isFav and "star-filled" or "star", variant = isFav and "secondary" or "ghost", controlSize = "sm", glyphSize = 14,
				tooltip = tr("panel.fav_add_tooltip", "Favorite this number"), onClick = function()
					local dest = draft.dest:gsub("^%s+", ""):gsub("%s+$", "")
					if dest == "" then return end
					for i, f in ipairs(smsFavorites) do
						if f.number == dest or (f.name ~= "" and f.name:lower() == dest:lower()) then
							table.remove(smsFavorites, i); persistence.saveFavorites(smsFavorites); render(); return
						end
					end
					table.insert(smsFavorites, { number = dest, name = "" })
					favNameEdits[dest] = true; persistence.saveFavorites(smsFavorites); render()
				end }),
		}),
		ui.scroll({ key = "fav-scroll", flexGrow = 1, gap = 2 }, #favItems > 0 and favItems or {
			ui.row({ align = "center", justify = "center", paddingV = 16, flexGrow = 1 }, {
				ui.label({ text = query ~= "" and tr("panel.no_matches", "No matching contacts") or tr("panel.fav_empty", "No favorite numbers yet"),
					fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
			}),
		}),
		ui.row({ gap = 4, align = "center" }, {
			mkInput({ key = "sms-msg-" .. d.id, placeholder = tr("panel.sms_msg", "Message"), tooltip = tr("panel.sms_msg", "Message"),
				value = draft.msg, flexGrow = 1, onChange = function(v) draftFor(d.id).msg = v end, onSubmit = doSend }),
			ui.button({ key = "sms-send", glyph = "send", variant = "primary", controlSize = "sm", tooltip = tr("panel.sms_send", "Send"), onClick = doSend }),
		}),
	})
end

-- ── Media playback bar ──────────────────────────────────────────────────────
local function mediaBar(d)
	local connected = isDeviceConnected(d)
	local title = connected and d.mediatitle or nil
	local artist = connected and (d.mediaartist or "") or ""
	local playing = connected and (d.mediaisPlaying == true) or false
	local length = connected and (tonumber(d.medialength) or 0) or 0
	local position = connected and (tonumber(d.mediaposition) or 0) or 0
	local canSeek = connected and (d.mediacanSeek == true) or false
	local artUrl = connected and d.mediaArtPath or nil
	if artUrl and artUrl ~= "" and not noctalia.fileExists(artUrl) then artUrl = nil end

	if not connected or not title or title == "" then
		return ui.row({ key = "media-bar", gap = 6, paddingV = 6, paddingH = 6, radius = 12,
			fill = "surface_variant/0.8", align = "center" }, {
			ui.glyph({ name = "music-off", size = 18, color = "on_surface_variant" }),
			ui.label({ text = tr("panel.no_media", "No media playing"), fontSize = 12,
				color = "on_surface_variant", flexGrow = 1 }),
		})
	end

	-- Transport buttons
	local function mediaBtn(action) sendCmd({ op = "media", device = d.id, action = action }); sendCmd({ op = "refresh" }) end
	local transport = ui.row({ gap = 2, align = "center" }, {
		ui.button({ glyph = "player-skip-back", variant = "ghost", controlSize = "sm", tooltip = tr("media.previous", "Previous"), onClick = function() mediaBtn("Previous") end }),
		ui.button({ glyph = playing and "player-pause" or "player-play", variant = "primary", controlSize = "sm",
			tooltip = tr(playing and "media.pause" or "media.play", playing and "Pause" or "Play"),
			onClick = function() d.mediaisPlaying = not playing; noctalia.setUpdateInterval(d.mediaisPlaying and 500 or 3000); render(); mediaBtn("PlayPause") end }),
		ui.button({ glyph = "player-skip-forward", variant = "ghost", controlSize = "sm", tooltip = tr("media.next", "Next"), onClick = function() mediaBtn("Next") end }),
	})

	-- Seek bar
	local seekEl = nil
	if canSeek and length > 0 then
		local sv = frozenDragValue(mediaDragState, d.id, position)
		seekEl = ui.row({ gap = 4, align = "center", flexGrow = 1, minWidth = 0 }, {
			ui.label({ text = fmtTime(sv), fontSize = 9, color = "on_surface_variant", width = 30, textAlign = "end" }),
			ui.slider({ key = "seek", min = 0, max = length, step = 1000,
				value = sv, controlSize = "sm", flexGrow = 1,
				onChange = function(v)
					mediaDragState[d.id] = { dragging = true, position = tonumber(v) or position, at = os.clock() }
				end,
				onDragEnd = function()
					local s = mediaDragState[d.id]; local tgt = (s and s.position) or position
					mediaDragState[d.id] = nil
					sendCmd({ op = "media_seek", device = d.id, offset = tostring(tgt) })
				end }),
			ui.label({ text = fmtTime(length), fontSize = 9, color = "on_surface_variant", width = 30 }),
		})
	end

	local dispTitle = truncate(title, 40)
	local dispArtist = artist ~= "" and truncate(artist, 20) or ""

	local kids = {}
	if artUrl then table.insert(kids, ui.image({ path = artUrl, width = 60, height = 60, radius = 8, fit = "cover" })) end
	table.insert(kids, ui.column({ gap = 5, flexGrow = 1, minWidth = 0 }, {
		ui.row({ gap = 6, align = "center", minWidth = 0 }, {
			ui.label({ text = dispTitle, fontSize = 14, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
			dispArtist ~= "" and ui.label({ text = " • " .. dispArtist, fontSize = 12, color = "on_surface_variant", maxLines = 1 }) or nil,
		}),
		ui.row({ gap = 8, align = "center" }, { transport, seekEl }),
	}))
	return ui.row({ key = "media-bar", gap = 15, paddingV = 8, paddingH = 8, radius = 12,
		fill = "surface_variant/0.8", align = "center" }, kids)
end

-- ── Main render ─────────────────────────────────────────────────────────────
function render()
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	local visibleOrder = {}
	for _, id in ipairs(order) do
		local d = devices[id]
		if d and not common.adbCoveredByKde(d, devices) then table.insert(visibleOrder, id) end
	end
	local sel = noctalia.state.get("pc.selected")
	if not sel or not devices[sel] or common.adbCoveredByKde(devices[sel], devices) then sel = visibleOrder[1] end

	local d = (sel and devices[sel]) or { id = "default", name = "Device", source = "kde", isPaired = false, isReachable = false }

	local upperKids = { dashboardCard(d) }
	local cast = castCard(d)
	if cast then table.insert(upperKids, cast) end
	table.insert(upperKids, messagesCard(d))

	panel.render(ui.column({ gap = 6, padding = 7, flexGrow = 1, align = "stretch" }, {
		ui.row({ gap = 6, flexGrow = 1, align = "stretch" }, {
			ui.column({ width = 220, gap = 6, align = "stretch" }, { deviceSidebar(visibleOrder, devices, sel), toolsCard(d) }),
			ui.column({ flexGrow = 1, minWidth = 0, gap = 6 }, upperKids),
		}),
		mediaBar(d),
	}))
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────
local lastMediaSync = 0
function update()
	local sel = noctalia.state.get("pc.selected")
	local d = sel and (noctalia.state.get("pc.devices") or {})[sel]
	if d and isDeviceConnected(d) and d.mediaisPlaying == true then
		noctalia.setUpdateInterval(500)
		local len, pos = tonumber(d.medialength) or 0, tonumber(d.mediaposition) or 0
		local st = mediaDragState[d.id]
		if not (st and st.dragging) and len > 0 then d.mediaposition = math.min(len, pos + 500); render() end
		local now = os.clock()
		if now - lastMediaSync >= 1.5 then lastMediaSync = now; sendCmd({ op = "refresh" }) end
	else
		noctalia.setUpdateInterval(3000)
	end
end

function onOpen()
	local sel = noctalia.state.get("pc.selected")
	local d = sel and (noctalia.state.get("pc.devices") or {})[sel]
	noctalia.setUpdateInterval((d and d.mediaisPlaying == true) and 500 or 3000)
	render()
end

function onClose() noctalia.setUpdateInterval(3000) end

noctalia.state.watch("pc.devices", render)
noctalia.state.watch("pc.order", render)
noctalia.state.watch("pc.selected", render)
noctalia.state.watch("pc.backend", render)
noctalia.state.watch("pc.imageMap", render)
noctalia.state.watch("pc.trTable", render)
noctalia.state.watch("pc.aliasMap", render)
noctalia.state.watch("pc.running", render)
