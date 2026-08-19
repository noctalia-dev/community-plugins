-- panel.luau
-- 合并面板：phone-connect 的完整 UI（设备卡/媒体/短信/操作栏/页脚）+ scrcpy：
--   adb 设备（id 前缀 "adb:"）在右栏显示 投屏/停止、投屏参数、断开；
--   「投屏参数」展开时覆盖左栏。参数读 lib/persistence，写经 pc.cmd 通道。

local persistence = require("./lib/persistence.luau")
local common = require("./lib/common.luau")

local t = common.t
local sendCmd = common.sendCmd

-- ── 每设备 UI 状态 ───────────────────────────────────────────────────────────
local smsDrafts = {}
local function draftFor(id)
	local d = smsDrafts[id]
	if not d then
		d = { dest = "", msg = "" }
		smsDrafts[id] = d
	end
	return d
end

local mediaDragState = {}
local volumeDragState = {}
local mutedPrevVolume = {}
local deviceNameEdits = {}

-- ── scrcpy 参数状态 ──────────────────────────────────────────────────────────
-- 注：无 activePreset 状态变量--按钮高亮由 detectPreset(params) 值推导
local paramsExpanded = false
local pairExpanded = false
local pairAddr = ""
local pairCode = ""
-- 首次无线投屏的配对输入（配对端口 + 调试端口 + 配对码）
local castPort = ""
local castDebugPort = "5555"
local castCode = ""

-- 每设备参数内存缓存 [adbId] = params。paramsPanel 每次 render 会重建，
-- 若每次都从磁盘 loadParams，拖动滑块时 onChange 的内存修改会被磁盘旧值
-- 覆盖（数字回退）。缓存保证 render 期间读到的都是最新值，commit 才写盘。
local paramCache = {}

local function paramsFor(adbId)
	local p = paramCache[adbId]
	if not p then
		p = persistence.loadParams(adbId)
		paramCache[adbId] = p
	end
	return p
end

local PRESETS = {
	hd   = { max_size = 1920, bit_rate = 16, max_fps = 60 },
	perf = { max_size = 1280, bit_rate = 8,  max_fps = 60 },
	save = { max_size = 1024, bit_rate = 4,  max_fps = 30 },
}

-- 当前参数命中的预设档；与任何预设都不匹配则为 "custom"。
-- 按钮高亮由 params 值推导而非独立状态变量：引擎对程序化设值的滑块
-- 也会异步触发 onChange（setValue 回声），独立变量会被回声改写导致
-- 「点预设高亮停在自定义」；值推导则天然免疫回声。
local function detectPreset(params)
	for key, p in pairs(PRESETS) do
		if params.max_size == p.max_size
			and params.bit_rate == p.bit_rate
			and params.max_fps == p.max_fps then
			return key
		end
	end
	return "custom"
end

-- 投屏目标解析：adb 设备用它自身；KDE 设备用 IP 匹配到的 adb 序列号
-- （service 已按局域网 IP 匹配填充 d.adbId），无匹配时回退到 "IP:5555"。
local function castTarget(d)
	if not d then return nil end
	local allDevices = noctalia.state.get("pc.devices") or {}
	local adbId
	if d.source == "adb" then
		adbId = d.adbId
	else
		adbId = d.adbId or (d.ipv4 and (d.ipv4 .. ":5555"))
	end
	if not adbId then return nil end
	local adbDev = allDevices["adb:" .. adbId]
	local ip = adbDev and adbDev.ip or (d.source ~= "adb" and d.ipv4) or common.ipFromSerial(adbId)
	return {
		adbId = adbId,
		ip = ip,
		online = adbDev and adbDev.isReachable == true or false,
		transport = adbDev and adbDev.transport or "wifi",
	}
end

-- ── 工具 ─────────────────────────────────────────────────────────────────────
local fmtTime = function(ms)
	if type(ms) ~= "number" or ms <= 0 then return "0:00" end
	local s = math.floor(ms / 1000)
	local m = math.floor(s / 60)
	s = s % 60
	return string.format("%d:%02d", m, s)
end

-- ── 头部：连接数 + 设备切换器 + 刷新/关闭 ─────────────────────────────────────
local function headerRow(order, devices, sel)
	local connected = 0
	for _, id in ipairs(order) do
		local d = devices[id]
		if d and d.isPaired and d.isReachable then connected = connected + 1 end
	end
	local connText = t("panel.devices_connected"):gsub("{connected}", tostring(connected))
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	local multi = #order > 1
	local kids = {
		ui.glyph({ name = "device-mobile", size = 18, color = "primary" }),
		ui.label({ text = connText, fontSize = 13, fontWeight = "medium",
			color = "on_surface", flexGrow = multi and 0 or 1 }),
	}
	if multi then
		for idx, id in ipairs(order) do
			local d = devices[id]
			if d then
				local isSel = id == sel
				local devName = aliasMap[id] or d.name or "Your-Phone"
				table.insert(kids, ui.button({
					key = "sw-" .. id,
					text = tostring(idx),
					glyph = d.source == "adb"
						and (d.transport == "wifi" and "wifi" or "usb")
						or common.deviceGlyph(d),
					variant = isSel and "primary" or "outline",
					controlSize = "sm",
					selected = isSel,
					flexGrow = 1,
					tooltip = devName,
					onClick = function()
						-- 切换设备不自动展开投屏参数，避免打断浏览
						paramsExpanded = false
						sendCmd({ op = "select", device = id })
					end,
				}))
			end
		end
	end
	table.insert(kids, ui.button({ key = "add-device", glyph = "plus", variant = "ghost",
		controlSize = "sm", width = 32, height = 32, tooltip = t("panel.pair_add"),
		onClick = function()
			pairExpanded = true
			render()
		end }))
	table.insert(kids, ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm",
		tooltip = t("action.refresh"),
		onClick = function() sendCmd({ op = "refresh" }) end }))
	table.insert(kids, ui.button({ glyph = "close", variant = "ghost", controlSize = "sm",
		tooltip = t("panel.close"),
		onClick = function() panel.close() end }))
	return ui.row({ gap = 8, align = "center" }, kids)
end

-- ── 设备卡 ───────────────────────────────────────────────────────────────────
local function adbDeviceCard(d)
	local online = d.isReachable == true
	local runningMap = noctalia.state.get("pc.running") or {}
	local casting = runningMap[d.adbId] == true
	local statusText = online and t("status.connected") or t("status.offline")
	local statusColor = online and "primary" or "on_surface_variant"

	return ui.row({ key = "device-card", gap = 10, padding = 12, radius = 10, fill = "surface/0.7",
		border = "primary/0.2", borderWidth = 1, align = "center" }, {
		ui.box({ width = 44, height = 44, radius = 22, fill = "primary/0.15" }, {
			ui.glyph({ name = d.transport == "wifi" and "wifi" or "usb",
				size = 24, color = "primary" }),
		}),
		ui.column({ gap = 3, flexGrow = 1, minWidth = 0 }, {
			ui.label({ text = d.name, fontSize = 14, fontWeight = "bold",
				color = "on_surface", maxLines = 1 }),
			ui.row({ gap = 6, align = "center" }, {
				ui.row({ radius = 8, fill = statusColor .. "/0.15", paddingH = 6, paddingV = 2 }, {
					ui.label({ text = statusText, fontSize = 10, color = statusColor }),
				}),
				casting and ui.row({ radius = 8, fill = "primary/0.15", paddingH = 6, paddingV = 2 }, {
					ui.label({ text = t("status.mirroring"), fontSize = 10, color = "primary" }),
				}) or nil,
			}),
		}),
	})
end

local function deviceCard(d)
	if d.source == "adb" then
		return adbDeviceCard(d)
	end

	local reachable = d.isPaired == true and d.isReachable == true
	local aliasMap = noctalia.state.get("pc.aliasMap") or {}
	local name = aliasMap[d.id] or d.name or "Your-Phone"
	local glyph = common.deviceGlyph(d)
	local imgMap = noctalia.state.get("pc.imageMap") or {}
	local imgPath = imgMap[d.id]
	if imgPath and imgPath ~= "" and not noctalia.fileExists(imgPath) then
		noctalia.log("[phone-operate] image not found: " .. imgPath)
	end

	local statusText, statusColor
	if not reachable then
		statusText = t("status.offline")
		statusColor = "on_surface_variant"
	else
		statusText = t("status.connected")
		statusColor = "primary"
	end

	local charge = d.batteryCharge
	local hasCharge = type(charge) == "number" and charge >= 0
	local chargeText = hasCharge and (tostring(charge) .. "%") or "--"
	local chargeColor = "on_surface"
	if hasCharge and charge <= 20 then chargeColor = "error" end
	local charging = d.batteryCharging == true

	local netText = (d.networkType and d.networkType ~= "")
		and (d.networkType .. (type(d.networkStrength) == "number"
			and d.networkStrength >= 0 and (" " .. tostring(d.networkStrength) .. "/4") or ""))
		or "--"

	local vol = tonumber(d.mediavolume)
	local hasVol = type(vol) == "number" and vol >= 0
	local muted = hasVol and vol <= 0
	local vDrag = volumeDragState[d.id]
	local vFrozen = vDrag and vDrag.dragging and (os.clock() - (vDrag.at or 0)) < 2.0
	if vDrag and vDrag.dragging and not vFrozen then volumeDragState[d.id] = nil end
	local volValue = vFrozen and vDrag.position or (hasVol and vol or 0)
	local volLabel = hasVol and (tostring(math.floor(volValue)) .. "%") or "--"

	local function toggleMute()
		if not hasVol then return end
		if muted then
			local restore = mutedPrevVolume[d.id] or 50
			sendCmd({ op = "media_set_volume", device = d.id, volume = tostring(restore) })
		else
			mutedPrevVolume[d.id] = vol
			sendCmd({ op = "media_set_volume", device = d.id, volume = "0" })
		end
	end

	local volumeGroup
	if hasVol then
		volumeGroup = ui.row({ gap = 4, align = "center", width = 132 }, {
			ui.button({
				glyph = muted and "volume-off" or "volume",
				variant = "ghost",
				controlSize = "sm",
				glyphSize = 13,
				tooltip = t(muted and "media.unmute" or "media.mute"),
				onClick = toggleMute,
			}),
			ui.label({ text = volLabel, fontSize = 10, color = "on_surface_variant", width = 34 }),
			ui.slider({
				key = "vol-" .. d.id,
				min = 0, max = 100, step = 1, value = volValue,
				controlSize = "sm", enabled = reachable, flexGrow = 1,
				onChange = function(v)
					volumeDragState[d.id] = { dragging = true, position = tonumber(v) or 0, at = os.clock() }
				end,
				onDragEnd = function()
					local st = volumeDragState[d.id]
					local target = (st and st.position) or (hasVol and vol or 0)
					volumeDragState[d.id] = nil
					sendCmd({ op = "media_set_volume", device = d.id, volume = tostring(target) })
				end,
			}),
		})
	end

	local function pickImage()
		sendCmd({ op = "pick_image", device = d.id })
	end

	local function commitName(v)
		local newName = (v or ""):gsub("^%s+", ""):gsub("%s+$", "")
		deviceNameEdits[d.id] = nil
		sendCmd({ op = "set_alias", device = d.id, alias = newName })
		render()
	end

	return ui.row({ key = "device-card", gap = 10, padding = 12, radius = 10, fill = "surface/0.7",
		border = "primary/0.2", borderWidth = 1, align = "center" }, {
		imgPath and ui.image({ path = imgPath, width = 44, height = 44,
			radius = 22, fit = "cover", onClick = pickImage })
			or ui.box({ width = 44, height = 44, radius = 22, fill = "primary/0.15",
				onClick = pickImage }, {
				ui.glyph({ name = glyph, size = 24, color = "primary" }),
				ui.glyph({ name = "pencil", size = 10, color = "on_surface_variant" }),
			}),
		ui.column({ gap = 3, flexGrow = 1, minWidth = 0 }, {
			deviceNameEdits[d.id] and ui.input({
				key = "name-edit-" .. d.id,
				value = name,
				placeholder = name,
				controlSize = "sm",
				onSubmit = commitName,
			})
			or ui.row({ gap = 4, align = "center", onClick = function()
					deviceNameEdits[d.id] = true
					render()
				end }, {
				ui.label({ text = name, fontSize = 14, fontWeight = "bold",
					color = "on_surface", maxLines = 1 }),
				ui.glyph({ name = "pencil", size = 10, color = "on_surface_variant" }),
			}),
			ui.row({ gap = 6, align = "center" }, {
				ui.row({ radius = 8, fill = statusColor .. "/0.15", paddingH = 6, paddingV = 2 }, {
					ui.label({ text = statusText, fontSize = 10, color = statusColor }),
				}),
			}),
		}),
		volumeGroup,
		ui.column({ gap = 2, align = "center", width = 52 }, {
			ui.glyph({ name = "antenna", size = 16,
				color = (reachable and d.networkType and d.networkType ~= "") and "primary" or "on_surface_variant" }),
			ui.label({ text = netText, fontSize = 9, color = "on_surface_variant" }),
		}),
		ui.column({ gap = 2, align = "center", width = 52 }, {
			ui.glyph({ name = common.batteryGlyph(charge, charging), size = 16, color = chargeColor }),
			ui.label({ text = chargeText, fontSize = 10, fontWeight = "medium", color = chargeColor }),
		}),
	})
end

-- ── 右栏操作按钮 ─────────────────────────────────────────────────────────────
-- 右栏固定宽 + 按钮内容宽（右栏宽 - scroll padding 16）。按钮固定宽度让
-- label 在 maxWidth 内省略号，不溢出；改右栏宽时同步改这里。
local RIGHT_COL_WIDTH = 110
local RIGHT_BTN_WIDTH = RIGHT_COL_WIDTH - 16

local function vActionBtn(text, glyph, onClick, variant, tooltip)
	return ui.button({ text = text, glyph = glyph, variant = variant or "outline",
		controlSize = "sm", width = RIGHT_BTN_WIDTH, tooltip = tooltip, onClick = onClick })
end

local function rightColumn(d)
	if d.source == "adb" then
		local runningMap = noctalia.state.get("pc.running") or {}
		local casting = runningMap[d.adbId] == true
		local btns = {}
		-- 未投屏时点「投屏」展开左侧参数面板（含开始投屏），不再直接开投
		table.insert(btns, vActionBtn(casting and t("action.stop") or t("action.cast"),
			casting and "player-stop" or "player-play",
			function()
				if casting then
					sendCmd({ op = "stop_cast", device = d.adbId })
				else
					paramsExpanded = true
					render()
				end
			end, casting and "destructive" or "primary"))
		table.insert(btns, vActionBtn(t("panel.params"), "adjustments",
			function()
				paramsExpanded = not paramsExpanded
				render()
			end, paramsExpanded and "primary" or "outline"))
		table.insert(btns, vActionBtn(t("action.disconnect"), "plug-off",
			function() sendCmd({ op = "adb_disconnect", device = d.adbId }) end, "ghost"))
		return ui.column({ key = "right-col", width = RIGHT_COL_WIDTH }, {
			ui.scroll({ key = "right-scroll", flexGrow = 1, gap = 8, padding = 8, align = "stretch" }, btns),
		})
	end

	local reachable = d.isReachable == true
	local paired = d.isPaired == true
	local btns = {}
	-- KDE 设备：若按局域网 IP 匹配到了 adb 设备（service 填充 d.adbId），
	-- 提供投屏入口；否则只能显示基础操作
	local cast = castTarget(d)
	if reachable and paired then
		if cast then
			local runningMap = noctalia.state.get("pc.running") or {}
			local casting = runningMap[cast.adbId] == true
			table.insert(btns, vActionBtn(casting and t("action.stop") or t("action.cast"),
				casting and "player-stop" or "player-play",
				function()
					if casting then
						sendCmd({ op = "stop_cast", device = cast.adbId })
					else
						paramsExpanded = true
						render()
					end
				end, casting and "destructive" or "primary"))
		end
		table.insert(btns, vActionBtn(t("action.ring"), "bell-ringing",
			function() sendCmd({ op = "ring", device = d.id }) end, cast and "outline" or "primary"))
		table.insert(btns, vActionBtn(t("action.ping"), "message",
			function() sendCmd({ op = "ping", device = d.id }) end))
		table.insert(btns, vActionBtn(t("action.browse"), "folder",
			function() sendCmd({ op = "browse", device = d.id }) end))
		if noctalia.getConfig("enable_clipboard_action") then
			table.insert(btns, vActionBtn(t("action.clipboard"), "clipboard",
				function() sendCmd({ op = "clipboard", device = d.id }) end))
		end
		table.insert(btns, vActionBtn(t("action.share"), "share",
			function() sendCmd({ op = "pick_share", device = d.id }) end))
		table.insert(btns, vActionBtn(t("action.unpair"), "link-off",
			function() sendCmd({ op = "unpair", device = d.id }) end, "ghost"))
	elseif not paired then
		table.insert(btns, vActionBtn(t("action.pair"), "link",
			function() sendCmd({ op = "pair", device = d.id }) end, "primary"))
	else
		table.insert(btns, vActionBtn(t("action.unpair"), "link-off",
			function() sendCmd({ op = "unpair", device = d.id }) end, "ghost"))
	end
	return ui.column({ key = "right-col", width = RIGHT_COL_WIDTH }, {
		ui.scroll({ key = "right-scroll", flexGrow = 1, gap = 8, padding = 8, align = "stretch" }, btns),
	})
end

-- ── 左栏：媒体 + 短信（connect 原版） ──────────────────────────────────────────
local function mediaSection(d)
	local title = d.mediatitle
	if not title or title == "" then
		return ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface/0.5" }, {
			ui.row({ gap = 6, align = "center" }, {
				ui.glyph({ name = "music", size = 13, color = "primary" }),
				ui.label({ text = t("panel.now_playing"), fontSize = 10,
					color = "primary", fontWeight = "bold", flexGrow = 1 }),
			}),
			ui.row({ gap = 8, align = "center" }, {
				ui.glyph({ name = "music-off", size = 20, color = "on_surface_variant" }),
				ui.label({ text = t("panel.no_media"), fontSize = 11,
					color = "on_surface_variant" }),
			}),
		})
	end
	local artist = d.mediaartist or ""
	local album = d.mediaalbum or ""
	local playing = d.mediaisPlaying == true
	local length = tonumber(d.medialength) or 0
	local position = tonumber(d.mediaposition) or 0
	local canSeek = d.mediacanSeek == true
	local artUrl = d.mediaArtPath

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
			ui.image({ path = artUrl, width = 36, height = 36, radius = 4, fit = "cover" }),
			ui.column({ gap = 1, flexGrow = 1 }, {
				ui.label({ text = title, fontSize = 12, fontWeight = "medium",
					color = "on_surface", maxLines = 1 }),
				ui.label({ text = artist, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
				ui.label({ text = album, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
			}),
		})
	else
		titleBlock = ui.column({ gap = 1 }, {
			ui.label({ text = title, fontSize = 12, fontWeight = "medium",
				color = "on_surface", maxLines = 1 }),
			ui.label({ text = artist, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
			ui.label({ text = album, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
		})
	end

	local transport = ui.row({ gap = 4, align = "center" }, {
		ui.button({ glyph = "player-skip-back", variant = "ghost", controlSize = "sm",
			tooltip = t("media.previous"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Previous" }) end }),
		ui.button({ glyph = playing and "player-pause" or "player-play",
			variant = "primary", controlSize = "sm",
			tooltip = t(playing and "media.pause" or "media.play"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "PlayPause" }) end }),
		ui.button({ glyph = "player-skip-forward", variant = "ghost", controlSize = "sm",
			tooltip = t("media.next"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Next" }) end }),
		ui.button({ glyph = "player-stop", variant = "ghost", controlSize = "sm",
			tooltip = t("media.stop"),
			onClick = function() sendCmd({ op = "media", device = d.id, action = "Stop" }) end }),
	})

	local progress
	if canSeek and length > 0 then
		local st = mediaDragState[d.id]
		local frozen = st and st.dragging and (os.clock() - (st.at or 0)) < 2.0
		if st and st.dragging and not frozen then mediaDragState[d.id] = nil end
		local sliderValue = frozen and st.position or position
		progress = ui.column({ gap = 2 }, {
			ui.slider({ min = 0, max = length, step = 1000, value = sliderValue,
				controlSize = "sm",
				onChange = function(v)
					mediaDragState[d.id] = { dragging = true, position = tonumber(v) or position, at = os.clock() }
				end,
				onDragEnd = function()
					local st2 = mediaDragState[d.id]
					local target = (st2 and st2.position) or position
					mediaDragState[d.id] = nil
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
	return ui.column({ gap = 6, padding = 10, radius = 8, fill = "primary/0.08" }, children)
end

local function smsComposer(d)
	local draft = draftFor(d.id)
	return ui.column({ gap = 8, padding = 12, radius = 8, fill = "surface/0.5",
		border = "on_surface/0.1", borderWidth = 1 }, {
		ui.label({ text = t("panel.sms"), fontSize = 12, fontWeight = "bold",
			color = "on_surface" }),
		ui.input({ key = "sms-dest-" .. d.id, placeholder = t("panel.sms_dest"),
			value = draft.dest, controlSize = "sm",
			onChange = function(v) draftFor(d.id).dest = v end }),
		ui.input({ key = "sms-msg-" .. d.id, placeholder = t("panel.sms_msg"),
			value = draft.msg, controlSize = "sm",
			onChange = function(v) draftFor(d.id).msg = v end }),
		ui.button({ text = t("panel.sms_send"), glyph = "send",
			variant = "primary", controlSize = "sm",
			onClick = function()
				local df = draftFor(d.id)
				if df.dest ~= "" and df.msg ~= "" then
					sendCmd({ op = "sms_send", device = d.id,
						destination = df.dest, text = df.msg })
					df.msg = ""
					render()
				end
			end }),
	})
end

-- ── 投屏参数面板（adb 设备，覆盖左栏） ────────────────────────────────────────
local function paramsPanel(target)
	local adbId = target.adbId
	-- 用内存缓存，避免每次 render 从磁盘加载导致拖动回退
	local params = paramsFor(adbId)

	local function commit(saveCustom)
		persistence.saveParams(adbId, params)
		-- custom 档只在用户手动调整时更新（滑块/开关），预设应用不覆盖它，
		-- 否则点预设后自定义档会被预设值污染
		if saveCustom then
			persistence.saveCustom(adbId, params)
		end
		sendCmd({ op = "restart_params", device = adbId, params = params })
	end

	local function applyPreset(_key, p)
		for k, v in pairs(p) do params[k] = v end
		commit(false)
		render()
	end

	local function startCast()
		noctalia.log("[phone-operate] startCast: adbId=" .. tostring(adbId)
			.. " online=" .. tostring(target.online)
			.. " ip=" .. tostring(target.ip)
			.. " transport=" .. tostring(target.transport))
		-- 设备已在线（USB 或 wifi 已连接）：直接投屏
		if target.online then
			sendCmd({ op = "cast", device = adbId, params = params })
			return
		end
		-- wifi 首次连接：需配对端口 + 配对码 + 调试端口
		if target.ip then
			if castPort == "" or castCode == "" then
				noctalia.notifyError(t("error.pair_failed"), t("panel.pair_missing"))
				return
			end
			sendCmd({ op = "pair_and_cast", address = target.ip, port = castPort,
				debugPort = castDebugPort, code = castCode, params = params })
			return
		end
		-- 离线且无 IP（如 USB 设备未被 adb 识别）：明确提示，而不是静默失败
		noctalia.notifyError(t("error.cast_failed"), t("panel.cast_offline_hint"))
	end

	local children = {}

	-- 按钮高亮由参数值推导（detectPreset），与状态变量无关，
	-- 引擎的 setValue 回声不会影响高亮正确性
	local currentPreset = detectPreset(params)

	table.insert(children, ui.row({ gap = 4 }, {
		ui.button({ text = t("panel.preset_hd"), variant = "ghost", controlSize = "sm",
			selected = currentPreset == "hd",
			onClick = function() applyPreset("hd", PRESETS.hd) end, flexGrow = 1 }),
		ui.button({ text = t("panel.preset_perf"), variant = "ghost", controlSize = "sm",
			selected = currentPreset == "perf",
			onClick = function() applyPreset("perf", PRESETS.perf) end, flexGrow = 1 }),
		ui.button({ text = t("panel.preset_save"), variant = "ghost", controlSize = "sm",
			selected = currentPreset == "save",
			onClick = function() applyPreset("save", PRESETS.save) end, flexGrow = 1 }),
		ui.button({ text = t("panel.preset_custom"), variant = "ghost", controlSize = "sm",
			selected = currentPreset == "custom",
			onClick = function()
				local c = persistence.loadCustom(adbId)
				if c then
					for k, v in pairs(c) do params[k] = v end
					commit(false)
				end
				render()
			end, flexGrow = 1 }),
	}))

	local function paramSlider(labelKey, val, min, max, step, suffix, setter)
		table.insert(children, ui.row({ key = "row-" .. labelKey, gap = 8, align = "center" }, {
			-- 参数名 minWidth：中文/英文都能完整显示，不截断；slider 是
			-- 唯一 flexGrow，吃掉剩余宽度（label 不用 flexGrow，避免平分）。
			ui.label({ text = t(labelKey), minWidth = 72,
				fontSize = 11, color = "on_surface_variant" }),
			ui.slider({
				key = "slider-" .. labelKey,
				min = min, max = max, step = step, value = val,
				controlSize = "sm",
				onChange = function(v)
					setter(tonumber(v))
					render()
				end,
				onDragEnd = function()
					commit(true)
					render()
				end,
				flexGrow = 1,
			}),
			ui.label({ text = tostring(val) .. suffix, width = 52, fontSize = 11,
				textAlign = "end", color = "on_surface" }),
		}))
	end

	paramSlider("panel.max_size", params.max_size or 1920, 256, 3840, 64, "",
		function(v) params.max_size = v end)
	paramSlider("panel.bit_rate", params.bit_rate or 8, 1, 30, 1, "M",
		function(v) params.bit_rate = v end)
	paramSlider("panel.max_fps", params.max_fps or 60, 1, 240, 1, "",
		function(v) params.max_fps = v end)

	local function toggleBlock(labelKey, descKey, checked, setter)
		table.insert(children, ui.column({ gap = 2 }, {
			ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = t(labelKey), fontSize = 12, color = "on_surface", flexGrow = 1 }),
				ui.toggle({
					checked = checked,
				onChange = function(v)
					setter(v == "true")
					commit(true)
					render()
				end,
				}),
			}),
			ui.label({ text = t(descKey), fontSize = 10, color = "on_surface_variant" }),
		}))
	end

	toggleBlock("panel.turn_screen_off", "panel.turn_screen_off_desc",
		params.turn_screen_off or false, function(v) params.turn_screen_off = v end)
	toggleBlock("panel.record", "panel.record_desc",
		params.record or false, function(v) params.record = v end)

	-- 首次无线连接：配对端口 + 配对码（仅当设备未在线且知道 IP 时显示）
	local pairInput
	if not target.online and target.ip then
		pairInput = ui.column({ key = "cast-pair", gap = 6, padding = 10, radius = 8,
			fill = "primary/0.08", border = "primary/0.25", borderWidth = 1 }, {
			ui.label({ text = t("panel.pair_first_title"), fontSize = 11, fontWeight = "bold",
				color = "primary" }),
			ui.label({ text = t("panel.pair_first_hint"), fontSize = 10, color = "on_surface_variant" }),
			ui.input({ key = "cast-port", placeholder = t("panel.pair_port_placeholder"),
				value = castPort, controlSize = "sm",
				onChange = function(v) castPort = v end }),
			ui.row({ key = "cast-pair-debug", gap = 6 }, {
				ui.input({ key = "cast-debug", placeholder = t("panel.debug_port_placeholder"),
					value = castDebugPort, controlSize = "sm", flexGrow = 1,
					onChange = function(v) castDebugPort = v end }),
				ui.input({ key = "cast-code", placeholder = t("panel.pair_code_placeholder"),
					value = castCode, controlSize = "sm", width = 120,
					onChange = function(v) castCode = v end }),
			}),
		})
	end

	-- 开始投屏：在线直接投；离线 wifi 需先配对
	local startBtn = ui.button({ key = "cast-start", text = t("panel.start_cast"), glyph = "player-play",
		variant = "primary", controlSize = "md",
		onClick = startCast })

	local scrollItems = {
		startBtn,
	}
	if pairInput then
		table.insert(scrollItems, pairInput)
	end
	for _, c in ipairs(children) do
		table.insert(scrollItems, c)
	end
	-- 底部小字提示（替代原「投屏参数」标题卡片，节省空间），居中显示
	table.insert(scrollItems, ui.label({ key = "params-hint-foot", text = t("panel.params_hint"),
		fontSize = 12, color = "on_surface_variant", textAlign = "center" }))
	return ui.column({ key = "left-panel", width = 340 }, {
		ui.scroll({ key = "left-panel-scroll", flexGrow = 1, gap = 10, padding = 0 }, scrollItems),
	})
end

-- ── 左栏 ─────────────────────────────────────────────────────────────────────
local function leftColumn(d)
	-- 投屏参数面板：adb 设备，或 KDE 设备匹配到 adb 目标时（paramsExpanded 时展开）
	local target = castTarget(d)
	if target and paramsExpanded then
		return paramsPanel(target)
	end
	if d.source == "adb" then
		return ui.column({ key = "left-hint", flexGrow = 1, minWidth = 340 }, {
			ui.scroll({ key = "left-hint-scroll", flexGrow = 1, gap = 12, padding = 0 }, {
				ui.column({ gap = 6, padding = 10, radius = 8, fill = "surface/0.5" }, {
					ui.row({ gap = 6, align = "center" }, {
						ui.glyph({ name = "device-mobile", size = 13, color = "primary" }),
						ui.label({ text = t("panel.params"), fontSize = 10,
							color = "primary", fontWeight = "bold", flexGrow = 1 }),
					}),
					ui.label({ text = t("panel.adb_hint"), fontSize = 11, color = "on_surface_variant" }),
				}),
			}),
		})
	end
	local items = {}
	table.insert(items, mediaSection(d))
	if d.isReachable and d.isPaired then
		table.insert(items, smsComposer(d))
	end
	return ui.column({ key = "left-media", flexGrow = 1, minWidth = 340 }, {
		ui.scroll({ key = "left-media-scroll", flexGrow = 1, gap = 12, padding = 0 }, items),
	})
end

-- ── 页脚：设备地址 ────────────────────────────────────────────────────────────
local function infoFooter(d)
	local function cell(label, val)
		return ui.column({ gap = 2, padding = 6, radius = 6, fill = "surface/0.5",
			flexGrow = 1 }, {
			ui.label({ text = label, fontSize = 9, color = "on_surface_variant" }),
			ui.label({ text = val or "--", fontSize = 10, maxLines = 1,
				color = val and "on_surface" or "on_surface_variant" }),
		})
	end
	if d.source == "adb" then
		return ui.row({ gap = 8 }, {
			cell("ADB ID", d.adbId),
			cell("USB/WiFi", d.transport or "usb"),
		})
	end
	return ui.row({ gap = 8 }, {
		cell("IPv4", d.ipv4),
		cell("IPv6", d.ipv6),
	})
end

-- ── adb 无线配对（折叠） ──────────────────────────────────────────────────────
local function pairSection()
	if not pairExpanded then
		return nil
	end
	return ui.column({ key = "pair-expanded", gap = 8, padding = 10, radius = 8, fill = "surface/0.5",
		border = "on_surface/0.1", borderWidth = 1 }, {
		ui.row({ gap = 8 }, {
			ui.input({ key = "pair-addr", placeholder = t("panel.pair_addr_placeholder"),
				controlSize = "sm",
				onChange = function(v) pairAddr = v end, flexGrow = 1 }),
			ui.input({ key = "pair-code", placeholder = t("panel.pair_code_placeholder"),
				controlSize = "sm", width = 140,
				onChange = function(v) pairCode = v end }),
		}),
		ui.markdown({ text = t("panel.pair_hint") }),
		ui.row({ gap = 8 }, {
			ui.button({ text = t("panel.pair_btn"), glyph = "link",
				variant = "secondary", controlSize = "sm",
				onClick = function()
					if pairAddr ~= "" and pairCode ~= "" then
						sendCmd({ op = "adb_pair", address = pairAddr, code = pairCode })
						pairAddr, pairCode = "", ""
						pairExpanded = false
						render()
					end
				end, flexGrow = 1 }),
			ui.button({ text = t("panel.cancel"), variant = "ghost", controlSize = "sm",
				onClick = function()
					pairExpanded = false
					render()
				end, flexGrow = 1 }),
		}),
	})
end

-- ── 主渲染 ───────────────────────────────────────────────────────────────────
function render()
	local backend = noctalia.state.get("pc.backend") or { available = false }
	local devices = noctalia.state.get("pc.devices") or {}
	local order = noctalia.state.get("pc.order") or {}
	-- 过滤：被 KDE 设备覆盖的 adb 设备不显示独立卡，统一由 KDE 设备卡管理
	local visibleOrder = {}
	for _, id in ipairs(order) do
		local d = devices[id]
		if d and not common.adbCoveredByKde(d, devices) then
			table.insert(visibleOrder, id)
		end
	end
	local sel = noctalia.state.get("pc.selected")
	if not sel or not devices[sel] or common.adbCoveredByKde(devices[sel], devices) then
		sel = visibleOrder[1]
	end

	-- 中间内容区（设备卡 + 两栏 + 页脚）：包在 scroll 里，内容超高时可滚动，
	-- 不会把底部的配对区挤出面板（修复投屏参数面板展开时配对区出界/不可见）。
	local middle
	if not backend.available and #visibleOrder == 0 then
		middle = ui.column({ gap = 8, padding = 40, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "phone-off", size = 40, color = "on_surface_variant" }),
			ui.label({ text = t("status.no_backend"), color = "on_surface_variant" }),
		})
	elseif not sel or not devices[sel] then
		middle = ui.column({ gap = 8, padding = 40, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "phone-off", size = 40, color = "on_surface_variant" }),
			ui.label({ text = t("panel.empty"), color = "on_surface_variant" }),
		})
	else
		local d = devices[sel]
		middle = ui.scroll({ key = "body-scroll", flexGrow = 1, gap = 10 }, {
			deviceCard(d),
			-- 两栏最小高度：媒体/参数区内容少时也有足够高度，但不触发
			-- 滚动条（内容总高 = 设备卡 + 两栏需 ≤ viewport，否则右侧
			-- 出现无意义的滚动条）。viewport 约 476，扣设备卡约 78 得 370
			-- （留 28px 缓冲覆盖字体/缩放差异）。
			ui.row({ key = "main-row", gap = 14, minHeight = 370,
				align = "stretch", justify = "center" }, {
				leftColumn(d),
				rightColumn(d),
			}),
		})
	end

	local rootChildren = {
		headerRow(visibleOrder, devices, sel),
		middle,
	}
	-- 配对表单（展开时）在 IP 地址上方
	local pair = pairSection()
	if pair then table.insert(rootChildren, pair) end
	-- IP 地址固定在底部（scroll 之外），与底部只留一半间距
	if sel and devices[sel] then
		table.insert(rootChildren, infoFooter(devices[sel]))
	end

	panel.render(ui.column({ gap = 5, padding = 12, flexGrow = 1 }, rootChildren))
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
noctalia.state.watch("pc.running", render)