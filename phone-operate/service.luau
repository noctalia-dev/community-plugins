-- service.luau
-- 合并后端 service：
--   1) phone-connect 的 KDE Connect 逻辑（整体移植，state contract 保持 pc.*）
--   2) phone-operate 的 adb/scrcpy 投屏逻辑（adb 设备并入 pc.devices/pc.order，
--      投屏命令走同一个 pc.cmd 通道，运行状态发布 pc.running）

-- ── require（plugin_api 22 起支持；KDE Connect 命令层仍全内联） ─────────────
local adb = require("./lib/adb.luau")
local scrcpy = require("./lib/scrcpy.luau")
local persistence = require("./lib/persistence.luau")
local shell = require("./lib/shell.luau")
local common = require("./lib/common.luau")

local t = common.t
local shellQuote = shell.quote

-- ── State contract (read by UI entries) ──────────────────────────────────────
--   noctalia.state "pc.backend"   : { available=bool, name="KDE Connect"|"None" }
--   noctalia.state "pc.devices"   : { [id] = deviceRecord }; id 为 kde 设备 id 或
--                                   "adb:<serial>"；adb 记录带 source="adb"、adbId、transport
--   noctalia.state "pc.order"     : { id, ... } device display order
--   noctalia.state "pc.selected"  : string  currently selected device id
--   noctalia.state "pc.cmd"       : { op, device, [args...], seq }  UI -> service
--   noctalia.state "pc.running"   : { [adbId] = true } scrcpy 运行状态
--
-- ── KDE Connect DBus surface ──────────────────────────────────────────────────
--   service   : org.kde.kdeconnect
--   daemon    : /modules/kdeconnect  iface org.kde.kdeconnect.daemon
--   device    : /modules/kdeconnect/devices/<id>  iface org.kde.kdeconnect.device
--   battery   : <dev>/battery  props: charge(i),isCharging(b)
--   mpris     : <dev>/mprisremote iface org.kde.kdeconnect.device.mprisremote

local SVC = "org.kde.kdeconnect"
local DAEMON_PATH = "/modules/kdeconnect"
local DAEMON_IFACE = "org.kde.kdeconnect.daemon"
local DEV_IFACE = "org.kde.kdeconnect.device"
local PROPS_IFACE = "org.freedesktop.DBus.Properties"
local BATTERY_IFACE = "org.kde.kdeconnect.device.battery"
local CONN_IFACE = "org.kde.kdeconnect.device.connectivity_report"
local MPRIS_IFACE = "org.kde.kdeconnect.device.mprisremote"

local function gdbusGetAll(devPath, iface)
	return table.concat({
		"gdbus call --session",
		"--dest", shellQuote(SVC),
		"--object-path", shellQuote(devPath),
		"--method", shellQuote(PROPS_IFACE .. ".GetAll"),
		shellQuote(iface),
	}, " ")
end

-- gdbus 返回值解析（一对一 port 自 phone-connect，已验证真实输出）
local function parseGdbusValue(raw)
	if raw == nil then return nil end
	raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
	local inner = raw:match("^%(<(.+)>%,?%)?$")
	if inner then
		if inner == "true" then return true end
		if inner == "false" then return false end
		local n = tonumber(inner)
		if n then return n end
		local s = inner:match("^'(.*)'$") or inner:match('^"(.*)"$')
		if s then return s end
		return inner
	end
	local bare = raw:match("^%((.-)%,?%)$")
	if bare == nil then bare = raw end
	bare = bare:gsub("%s+$", ""):gsub(",%s*$", "")
	if bare == "true" then return true end
	if bare == "false" then return false end
	local n = tonumber(bare)
	if n then return n end
	local s = bare:match("^'(.*)'$") or bare:match('^"(.*)"$')
	if s then return s end
	return bare
end

local function parseGdbusStringArray(raw)
	if raw == nil then return {} end
	local arr = raw:match("%[(.-)%]")
	if arr == nil then return {} end
	local out = {}
	for item in arr:gmatch("'([^']*)'") do
		table.insert(out, item)
	end
	return out
end

local function parseVariantInner(v)
	if v == "true" then return true end
	if v == "false" then return false end
	local n = tonumber(v)
	if n then return n end
	local s = v:match("^'(.*)'$") or v:match('^"(.*)"$')
	if s ~= nil then return s end
	if v:sub(1, 1) == "[" then
		local arr = {}
		for item in v:gmatch("'([^']*)'") do table.insert(arr, item) end
		for item in v:gmatch('"([^"]*)"') do table.insert(arr, item) end
		return arr
	end
	return v
end

local function parseGdbusVariantDict(raw)
	local out = {}
	if raw == nil then return out end
	for key, vraw in raw:gmatch("'([^']+)'%s*:%s*(%b<>)") do
		out[key] = parseVariantInner(vraw:sub(2, -2))
	end
	return out
end

-- ── 设备数据模型（pc.devices map + pc.order，adb 与 kde 共用） ─────────────────
local devices = {}
local deviceOrder = {}
local intervalMs -- forward-declared
local combinedIntervalMs -- forward-declared

-- wifi 序列号形如 "192.168.1.3:5555"，host 即设备 IP；usb 序列号无 IP
local function adbIpOf(serial)
	return serial:match("^(%d+%.%d+%.%d+%.%d+):%d+$")
end

-- 用局域网 IP 判断 adb 与 KDE Connect 是否同一台设备：
-- 给 KDE 设备记录填充 adbId（匹配到的 adb 序列号），使 KDE 设备卡也能发起投屏。
-- 单设备兜底仅当「adb 唯一 且 KDE 设备也唯一」时启用：USB 直连单台手机时，
-- adb 设备无 IP、KDE 设备 IP 匹配不上，兜底关联避免缺少投屏入口。
-- 多 KDE 设备时禁用兜底——否则所有 KDE 设备都会被关联到同一台 adb 设备，
-- 第二台设备点投屏会误投第一台（设备串台）。
local function matchKdeToAdb()
	local ipToAdb = {}
	local adbIds = {}
	local kdeIds = {}
	for _, id in ipairs(deviceOrder) do
		local d = devices[id]
		if d then
			if d.source == "adb" then
				if d.ip then ipToAdb[d.ip] = d.adbId end
				adbIds[#adbIds + 1] = d.adbId
			else
				kdeIds[#kdeIds + 1] = id
			end
		end
	end
	local singleAdb = (#adbIds == 1) and adbIds[1] or nil
	local singleKde = (#kdeIds == 1) and kdeIds[1] or nil
	for _, id in ipairs(deviceOrder) do
		local d = devices[id]
		if d and d.source ~= "adb" then
			local match = d.ipv4 and ipToAdb[d.ipv4] or nil
			if not match and singleAdb and singleKde == id and d.isReachable == true then
				match = singleAdb
			end
			if d.adbId ~= match then
				d.adbId = match
				devices[id] = d
			end
		end
	end
end

local function snapshotDevices()
	local snap = {}
	for _, id in ipairs(deviceOrder) do
		local d = devices[id]
		if d then snap[id] = d end
	end
	return snap
end

local function publishDevices()
	matchKdeToAdb()
	noctalia.state.set("pc.devices", snapshotDevices())
	noctalia.state.set("pc.order", deviceOrder)
end

-- ── 持久状态（selected / imageMap / aliasMap） ───────────────────────────────
local DATA_FILE

local function dataPath()
	if DATA_FILE then return DATA_FILE end
	local dir = noctalia.pluginDataDir()
	if not dir then return nil end
	DATA_FILE = dir .. "/state.json"
	return DATA_FILE
end

local function loadData()
	local p = dataPath()
	if not p then return {} end
	local raw = noctalia.readFile(p)
	if not raw then return {} end
	local ok, data = pcall(noctalia.json.decode, raw)
	if ok and type(data) == "table" then return data end
	return {}
end

local function saveData(data)
	local p = dataPath()
	if not p then return end
	local ok, encoded = pcall(noctalia.json.encode, data)
	if ok and encoded then noctalia.writeFile(p, encoded) end
end

-- 持久化单个字段：{ key = value } 合并进 state.json 后写盘
local function persistField(key, value)
	local data = loadData()
	data[key] = value
	saveData(data)
end

do
	local saved = loadData()
	if saved.selected and type(saved.selected) == "string" and saved.selected ~= "" then
		noctalia.state.set("pc.selected", saved.selected)
	end
	noctalia.state.set("pc.imageMap", saved.imageMap or {})
	noctalia.state.set("pc.aliasMap", saved.aliasMap or {})
end

-- ── 翻译加载（嵌套 JSON 压平为 dotted keys 发布到 pc.trTable） ─────────────────
local function flattenTable(tbl, prefix)
	local out = {}
	for k, v in pairs(tbl) do
		local full = prefix and (prefix .. "." .. k) or k
		if type(v) == "table" then
			local sub = flattenTable(v, full)
			for sk, sv in pairs(sub) do out[sk] = sv end
		else
			out[full] = v
		end
	end
	return out
end

local function loadTranslations(lang)
	local dir = noctalia.pluginDir()
	if not dir then return {} end
	local raw = noctalia.readFile(dir .. "/translations/" .. lang .. ".json")
	if not raw then return {} end
	local ok, data = pcall(noctalia.json.decode, raw)
	if ok and type(data) == "table" then return flattenTable(data) end
	return {}
end

local function publishTranslations(lang)
	local tbl = loadTranslations(lang or "en")
	noctalia.state.set("pc.trTable", tbl)
	noctalia.state.set("pc.lang", lang)
end

publishTranslations(noctalia.getConfig("language") or "en")

-- ── 后端可用性 ───────────────────────────────────────────────────────────────
local function detectBackend()
	local hasGdbus = noctalia.commandExists("gdbus")
	local hasCli = noctalia.commandExists("kdeconnect-cli")
	local available = noctalia.commandExists("kdeconnectd") or hasGdbus or hasCli
	if hasGdbus then
		noctalia.runAsync(
			"gdbus call --session --dest org.freedesktop.DBus "
				.. "--object-path /org/freedesktop/DBus "
				.. "--method org.freedesktop.DBus.NameHasOwner "
				.. shellQuote(SVC),
			function(res)
				local owned = false
				if res and res.exitCode == 0 then
					owned = parseGdbusValue(res.stdout or "") == true
				end
				noctalia.state.set("pc.backend", {
					available = owned,
					name = owned and "KDE Connect" or "None",
					hasGdbus = hasGdbus,
					hasCli = hasCli,
				})
			end
		)
	else
		noctalia.state.set("pc.backend", {
			available = available,
			name = available and "KDE Connect" or "None",
			hasGdbus = false,
			hasCli = hasCli,
		})
	end
end

-- ── KDE 设备属性拉取 ─────────────────────────────────────────────────────────
local function fetchDeviceProps(id, cb)
	local devPath = DAEMON_PATH .. "/devices/" .. id
	noctalia.runAsync(gdbusGetAll(devPath, DEV_IFACE), function(res)
		local d = devices[id] or { id = id }
			if res and res.exitCode == 0 then
				local p = parseGdbusVariantDict(res.stdout or "")
				d.name = p.name
				d.type = p.type
				d.isReachable = p.isReachable
				d.isPaired = p.isPaired
				local v4, v6
			if type(p.reachableAddresses) == "table" then
				for _, a in ipairs(p.reachableAddresses) do
					if type(a) == "string" then
						if not v4 and a:find(".", 1, true) then v4 = a end
						if not v6 and a:find(":", 1, true) then v6 = a end
					end
				end
			end
			d.ipv4 = v4
			d.ipv6 = v6
		else
			d.isReachable = false
		end
		devices[id] = d
		publishDevices()
		if cb then cb() end
	end)
end

local function fetchMpris(id, cb)
	local d = devices[id]
	if not d then
		if cb then cb() end
		return
	end
	local devPath = DAEMON_PATH .. "/devices/" .. id
	noctalia.runAsync(gdbusGetAll(devPath .. "/mprisremote", MPRIS_IFACE), function(res)
		local d2 = devices[id]
		if d2 and res and res.exitCode == 0 then
			local p = parseGdbusVariantDict(res.stdout or "")
			d2.mediaisPlaying = p.isPlaying
			d2.mediatitle = p.title
			d2.mediaartist = p.artist
			d2.mediaalbum = p.album
			d2.mediavolume = p.volume
			d2.medialocalAlbumArtUrl = p.localAlbumArtUrl
			d2.medialength = p.length
			d2.mediaposition = p.position
			d2.mediacanSeek = p.canSeek
			local art = d2.medialocalAlbumArtUrl
			if art and art ~= "" then
				if art:sub(1, 7) == "file://" then art = art:sub(8) end
				d2.mediaArtPath = art
			end
			devices[id] = d2
		end
		publishDevices()
		noctalia.setUpdateInterval(combinedIntervalMs())
		if cb then cb() end
	end)
end

local function runCli(args, cb)
	noctalia.runAsync("kdeconnect-cli " .. args, function(res)
		if res and res.exitCode ~= 0 then
			noctalia.log("[phone-operate] kdeconnect-cli failed: " .. (res.stderr or ""))
		end
		if cb then cb(res) end
	end)
end

local function fetchDeviceExtras(id)
	local d = devices[id]
	if not d then return end
	if not (d.isPaired and d.isReachable) then return end
	local devPath = DAEMON_PATH .. "/devices/" .. id
	noctalia.runAsync(gdbusGetAll(devPath .. "/battery", BATTERY_IFACE), function(res)
		if res and res.exitCode == 0 then
			local d2 = devices[id]
			if d2 then
				local p = parseGdbusVariantDict(res.stdout or "")
				d2.batteryCharge = p.charge
				d2.batteryCharging = p.isCharging
				devices[id] = d2
				publishDevices()
			end
		end
	end)
	noctalia.runAsync(gdbusGetAll(devPath .. "/connectivity_report", CONN_IFACE),
		function(res)
			if res and res.exitCode == 0 then
				local d2 = devices[id]
				if d2 then
					local p = parseGdbusVariantDict(res.stdout or "")
					d2.networkType = p.cellularNetworkType
					d2.networkStrength = p.cellularNetworkStrength
					devices[id] = d2
					publishDevices()
					if (type(d2.networkType) ~= "string" or d2.networkType == "")
						and d2.networkStrength == -1 then
						local now = os.time()
						local last = d2._netRefreshAt or 0
						if now - last > 120 then
							d2._netRefreshAt = now
							devices[id] = d2
							runCli("--refresh -d " .. shellQuote(id))
						end
					end
				end
			end
		end)
	fetchMpris(id)
end

-- ── KDE 全量刷新 ─────────────────────────────────────────────────────────────
local refreshing = false
local refreshLockedAt = 0
local ensureMonitors -- forward-declared

local function refreshDevices()
	if refreshing then
		if os.clock() - refreshLockedAt > 3.0 then
			refreshing = false
			noctalia.log("[phone-operate] refresh lock stale; reset")
		else
			return
		end
	end
	refreshing = true
	refreshLockedAt = os.clock()
	noctalia.runAsync(
		"gdbus call --session --dest " .. SVC
			.. " --object-path " .. DAEMON_PATH
			.. " --method " .. DAEMON_IFACE .. ".devices false false",
		function(res)
			refreshing = false
			if not res or res.exitCode ~= 0 then
				noctalia.log("[phone-operate] devices() failed: " .. (res and res.stderr or "nil"))
				return
			end
			local ids = parseGdbusStringArray(res.stdout or "")
			local seen = {}
			for _, id in ipairs(ids) do seen[id] = true end
			-- 只清除消失的 kde 设备，保留 "adb:" 条目
			for i = #deviceOrder, 1, -1 do
				local oid = deviceOrder[i]
				if oid:sub(1, 4) ~= "adb:" and not seen[oid] then
					devices[oid] = nil
					table.remove(deviceOrder, i)
				end
			end
			for _, id in ipairs(ids) do
				if not devices[id] then
					table.insert(deviceOrder, id)
					devices[id] = { id = id }
				end
			end
			local idx = 1
			local function fetchNext()
				if idx > #deviceOrder then
					publishDevices()
					for _, id2 in ipairs(deviceOrder) do
						if id2:sub(1, 4) ~= "adb:" then fetchDeviceExtras(id2) end
					end
					ensureMonitors()
					return
				end
				local id = deviceOrder[idx]
				idx = idx + 1
				if id:sub(1, 4) == "adb:" then
					fetchNext()
				else
					fetchDeviceProps(id, fetchNext)
				end
			end
			fetchNext()
		end)
end

-- ── 实时媒体同步（gdbus monitor，best-effort） ────────────────────────────────
local monitors = {}
local daemonMonitorActive = false
local lastDaemonEventAt = 0
local lastMediaEventAt = {}

ensureMonitors = function()
	if not daemonMonitorActive then
		local ok = noctalia.runStream(
			"gdbus monitor --session --dest " .. SVC
				.. " --object-path " .. shellQuote(DAEMON_PATH),
			function(line)
				if line == nil or line == "" then return end
				local now = os.clock()
				if now - lastDaemonEventAt > 0.5 then
					lastDaemonEventAt = now
					refreshDevices()
				end
			end)
		if ok then daemonMonitorActive = true end
	end
	for _, id in ipairs(deviceOrder) do
		local d = devices[id]
		if not monitors[id] and d and d.source ~= "adb" and d.isPaired and d.isReachable then
			local ok = noctalia.runStream(
				"gdbus monitor --session --dest " .. SVC
					.. " --object-path " .. shellQuote(DAEMON_PATH .. "/devices/" .. id .. "/mprisremote"),
				function(line)
					if line == nil or line == "" then return end
					if not line:lower():find("propertieschanged") then return end
					local now = os.clock()
					local last = lastMediaEventAt[id] or 0
					if now - last > 0.25 then
						lastMediaEventAt[id] = now
						fetchMpris(id)
					end
				end)
			if ok then monitors[id] = true end
		end
	end
	for id in pairs(monitors) do
		if not devices[id] then monitors[id] = nil end
	end
end

-- ── 文件选择器结果轮询 ────────────────────────────────────────────────────────
local pendingPick = nil

local function pollPendingPick()
	if not pendingPick then return end
	local raw = noctalia.readFile(pendingPick.path)
	if raw and raw ~= "" then
		local p = raw:gsub("[\r\n%s]+$", "")
		if p ~= "" then
			if pendingPick.purpose == "share" then
				noctalia.runAsync(
					"kdeconnect-cli --share " .. shellQuote(p)
						.. " -d " .. shellQuote(pendingPick.device),
					function(res)
						if res and res.exitCode ~= 0 then
							noctalia.notifyError(t("error.share_failed"), res.stderr or "")
						end
					end)
				noctalia.notify(t("notify.file_shared"), p)
			else
				local map = noctalia.state.get("pc.imageMap") or {}
				map[pendingPick.device] = p
				noctalia.state.set("pc.imageMap", map)
				persistField("imageMap", map)
				noctalia.log("[phone-operate] picked image for " .. pendingPick.device .. ": " .. p)
			end
		end
		noctalia.removeFile(pendingPick.path)
		pendingPick = nil
	elseif os.time() - pendingPick.started > 120 then
		noctalia.removeFile(pendingPick.path)
		pendingPick = nil
	end
end

-- ── gdbus 子接口方法 ──────────────────────────────────────────────────────────
local function gdbusDeviceMethod(id, method, cb)
	local path = DAEMON_PATH .. "/devices/" .. id
	noctalia.runAsync(
		"gdbus call --session --dest " .. SVC
			.. " --object-path " .. path
			.. " --method " .. DEV_IFACE .. "." .. method,
		function(res)
			if res and res.exitCode ~= 0 then
				noctalia.log("[phone-operate] " .. method .. " failed: " .. (res.stderr or ""))
			end
			if cb then cb(res) end
		end)
end

local function gdbusSubMethod(id, sub, method, extraArgs, cb)
	local path = DAEMON_PATH .. "/devices/" .. id .. "/" .. sub
	local iface = "org.kde.kdeconnect.device." .. sub
	local cmd = "gdbus call --session --dest " .. SVC
		.. " --object-path " .. shellQuote(path)
		.. " --method " .. shellQuote(iface .. "." .. method)
	if extraArgs and extraArgs ~= "" then cmd = cmd .. " " .. extraArgs end
	noctalia.runAsync(cmd, function(res)
		if res and res.exitCode ~= 0 then
			noctalia.log("[phone-operate] " .. sub .. "." .. method .. " failed: " .. (res.stderr or ""))
		end
		if cb then cb(res) end
	end)
end

local function gdbusSubMethodValue(id, sub, method, cb)
	gdbusSubMethod(id, sub, method, "", function(res)
		if not res or res.exitCode ~= 0 then cb(nil); return end
		cb(parseGdbusValue(res.stdout or ""))
	end)
end

-- ── scrcpy 状态与 adb 轮询 ────────────────────────────────────────────────────
local scrcpyRunning = {}
local lastRunningJson = nil

local function publishRunning()
	local json = noctalia.json.encode(scrcpyRunning)
	if json ~= lastRunningJson then
		lastRunningJson = json
		noctalia.state.set("pc.running", scrcpyRunning)
	end
end

local function refreshAdbDevices()
	adb.listDevicesAsync(function(adbList)
		if adbList == nil then
			-- adb 命令失败：保留上次的设备列表，避免设备从面板消失
			return
		end
		for id in pairs(devices) do
			if id:sub(1, 4) == "adb:" then devices[id] = nil end
		end
		for i = #deviceOrder, 1, -1 do
			if deviceOrder[i]:sub(1, 4) == "adb:" then table.remove(deviceOrder, i) end
		end
		for _, ad in ipairs(adbList) do
			local customName = persistence.loadName(ad.id)
			local label = customName or ad.model or ad.id
			local ip = adbIpOf(ad.id)
			devices["adb:" .. ad.id] = {
				id = "adb:" .. ad.id,
				adbId = ad.id,
				source = "adb",
				name = label,
				type = "phone",
				isPaired = true,
				isReachable = ad.online == true,
				transport = ad.transport,
				model = ad.model,
				ip = ip,
			}
			table.insert(deviceOrder, "adb:" .. ad.id)
		end
		publishDevices()
		-- USB 设备没有 IP：异步取 WiFi IP（带缓存），用于与 KDE Connect 匹配。
		-- 无线设备序列号自带 IP，跳过。
		local now = os.time()
		for _, ad in ipairs(adbList) do
			if not adbIpOf(ad.id) and ad.online == true then
				local d = devices["adb:" .. ad.id]
				if d and (not d.ip or now - (d._ipFetchedAt or 0) > 60) then
					d._ipFetchedAt = now
					devices["adb:" .. ad.id] = d
					adb.deviceIpAsync(ad.id, function(ip)
						local d2 = devices["adb:" .. ad.id]
						if d2 and ip and ip ~= "" then
							d2.ip = ip
							devices["adb:" .. ad.id] = d2
							publishDevices()
						end
					end)
				end
			end
		end
	end)
end

local function cleanupRecordings()
	local maxFiles = noctalia.getConfig("record_max_files") or 10
	local dir = noctalia.pluginDataDir()
	noctalia.runAsync(string.format(
		"ls -1t %s/rec_*.mp4 2>/dev/null | tail -n +%d | xargs -r rm -f",
		shellQuote(dir), maxFiles + 1
	), function() end)
end

local function pruneRunning()
	local pending = {}
	for adbId, _ in pairs(scrcpyRunning) do
		pending[#pending + 1] = adbId
	end
	if #pending == 0 then
		publishRunning()
		return
	end
	local done = 0
	for _, adbId in ipairs(pending) do
		scrcpy.isRunning(adbId, function(alive)
			if not alive then scrcpyRunning[adbId] = nil end
			done = done + 1
			if done >= #pending then publishRunning() end
		end)
	end
end

-- ── 命令执行（pc.cmd 通道） ───────────────────────────────────────────────────
-- 大部分 op 由 UI（panel/widget/launcher）经 pc.cmd 发送。以下 op 当前无 UI
-- 发送方，保留作为外部 IPC（noctalia msg ...）的功能接口：
--   share_text / share_file（分享文本/文件）、accept / reject（接受/拒绝配对）、
--   launch_sms_app（打开短信 App）、stop_all_cast（停止全部投屏）、
--   adb_connect（无线连接）、usb_mode（切回 USB）。
local function handleCommand(cmd)
	if type(cmd) ~= "table" then return end
	local op = cmd.op
	local dev = cmd.device or ""
	local function mutating(fn)
		fn(function() refreshDevices() end)
	end
	if op == "refresh" then
		refreshDevices()
		refreshAdbDevices()
	elseif op == "select" then
		noctalia.state.set("pc.selected", dev)
		persistField("selected", dev)
	elseif op == "ring" then
		runCli("--ring -d " .. shellQuote(dev))
	elseif op == "ping" then
		local msg = cmd.message or ""
		if msg ~= "" then
			runCli("--ping-msg " .. shellQuote(msg) .. " -d " .. shellQuote(dev))
		else
			runCli("--ping -d " .. shellQuote(dev))
		end
	elseif op == "clipboard" then
		runCli("--send-clipboard -d " .. shellQuote(dev))
	elseif op == "share_text" then
		runCli("--share-text " .. shellQuote(cmd.text or "") .. " -d " .. shellQuote(dev))
	elseif op == "share_file" then
		runCli("--share " .. shellQuote(cmd.path or "") .. " -d " .. shellQuote(dev))
	elseif op == "set_alias" then
		local map = noctalia.state.get("pc.aliasMap") or {}
		local alias = cmd.alias or ""
		if alias == "" then map[dev] = nil else map[dev] = alias end
		noctalia.state.set("pc.aliasMap", map)
		persistField("aliasMap", map)
	elseif op == "pick_image" or op == "pick_share" then
		if pendingPick then
			noctalia.notifyError(t("error.pick_in_progress"))
		else
			local picker
			if noctalia.commandExists("kdialog") then
				picker = "kdialog --getopenfilename ~ ''"
			elseif noctalia.commandExists("zenity") then
				picker = "zenity --file-selection"
			else
				noctalia.notifyError(t("error.pick_failed"), "kdialog/zenity not found")
				return
			end
			local tmp = noctalia.pluginDataDir() .. "/pick-" .. tostring(dev) .. ".tmp"
			pendingPick = {
				device = dev,
				path = tmp,
				started = os.time(),
				purpose = (op == "pick_share") and "share" or "image",
			}
			noctalia.removeFile(tmp)
			noctalia.runAsync(picker .. " > " .. shellQuote(tmp) .. " 2>/dev/null &")
		end
	elseif op == "pair" then
		mutating(function(cb) gdbusDeviceMethod(dev, "requestPairing", cb) end)
	elseif op == "accept" then
		mutating(function(cb) gdbusDeviceMethod(dev, "acceptPairing", cb) end)
	elseif op == "reject" then
		mutating(function(cb) gdbusDeviceMethod(dev, "cancelPairing", cb) end)
	elseif op == "unpair" then
		mutating(function(cb) gdbusDeviceMethod(dev, "unpair", cb) end)
	elseif op == "browse" then
		local function tryOpen()
			gdbusSubMethodValue(dev, "sftp", "mountPoint", function(mp)
				if not mp or mp == "" then
					noctalia.notifyError(t("error.browse_failed"), "no mount point")
					return
				end
				local path = DAEMON_PATH .. "/devices/" .. dev .. "/sftp"
				local cmd2 = "gdbus call --session --dest " .. SVC
					.. " --object-path " .. shellQuote(path)
					.. " --method org.kde.kdeconnect.device.sftp.getDirectories"
				noctalia.runAsync(cmd2, function(res)
					local dirPath = mp
					if res and res.exitCode == 0 then
						local first = (res.stdout or ""):match("'([^']+)'")
						if first then dirPath = first end
					end
					noctalia.runAsync("xdg-open " .. shellQuote(dirPath))
					noctalia.notify(t("notify.opening_browser"), dirPath)
				end)
			end)
		end
		gdbusSubMethodValue(dev, "sftp", "isMounted", function(mounted)
			if mounted then
				tryOpen()
			else
				gdbusSubMethodValue(dev, "sftp", "mountAndWait", function(ok)
					if ok then
						tryOpen()
					else
						gdbusSubMethodValue(dev, "sftp", "getMountError", function(errMsg)
							noctalia.notifyError(t("error.browse_failed"),
								errMsg or "mount failed (sshfs installed?)")
						end)
					end
				end)
			end
		end)
	elseif op == "sms_send" then
		local args = "--send-sms " .. shellQuote(cmd.text or "")
			.. " --destination " .. shellQuote(cmd.destination or "")
			.. " -d " .. shellQuote(dev)
		if cmd.attachment and cmd.attachment ~= "" then
			args = args .. " --attachment " .. shellQuote(cmd.attachment)
		end
		runCli(args, function(res)
			if res and res.exitCode == 0 then
				noctalia.notify(t("notify.sms_sent"), cmd.destination or "")
			end
		end)
	elseif op == "launch_sms_app" then
		gdbusSubMethod(dev, "sms", "launchApp", "", nil)
	elseif op == "media" then
		local action = cmd.action or "PlayPause"
		gdbusSubMethod(dev, "mprisremote", "sendAction",
			shellQuote(action), function()
				noctalia.runAsync("sleep 0.6", function() refreshDevices() end)
			end)
	elseif op == "media_seek" then
		local offset = tonumber(cmd.offset) or 0
		local path = DAEMON_PATH .. "/devices/" .. dev .. "/mprisremote"
		noctalia.runAsync(
			"gdbus call --session --dest " .. SVC
				.. " --object-path " .. shellQuote(path)
				.. " --method " .. shellQuote(PROPS_IFACE .. ".Set")
				.. " " .. MPRIS_IFACE .. " position "
				.. shellQuote("<int32 " .. tostring(offset) .. ">"),
			function()
				noctalia.runAsync("sleep 0.3", function() refreshDevices() end)
			end)
	elseif op == "media_set_volume" then
		local vol = tonumber(cmd.volume) or 0
		local path = DAEMON_PATH .. "/devices/" .. dev .. "/mprisremote"
		noctalia.runAsync(
			"gdbus call --session --dest " .. SVC
				.. " --object-path " .. shellQuote(path)
				.. " --method " .. shellQuote(PROPS_IFACE .. ".Set")
				.. " " .. shellQuote(MPRIS_IFACE) .. " volume "
				.. shellQuote("<int32 " .. tostring(vol) .. ">"),
			function() refreshDevices() end)
		-- ── scrcpy 操作（source="adb" 的设备） ──
		elseif op == "cast" then
			local adbId = cmd.device
			local params = cmd.params or persistence.loadParams(adbId)
			persistence.saveParams(adbId, params)
			local devRec = devices["adb:" .. adbId]
			noctalia.log("[phone-operate] cast: " .. tostring(adbId)
				.. " inList=" .. tostring(devRec ~= nil)
				.. " online=" .. tostring(devRec and devRec.isReachable))
			if not devRec or devRec.isReachable ~= true then
				-- 设备不在 adb 列表或离线：可能是残留的 USB 快照，明确提示
				noctalia.notifyError(t("error.cast_failed"),
					t("panel.cast_offline_hint") .. " (" .. tostring(adbId) .. ")")
				return
			end
			local ok = scrcpy.start({ id = adbId }, params)
			noctalia.log("[phone-operate] scrcpy.start returned: " .. tostring(ok))
			if ok == false then
				noctalia.notifyError(t("error.cast_failed"), "scrcpy launch failed")
				return
			end
			scrcpyRunning[adbId] = true
			publishRunning()
			if params.record then cleanupRecordings() end
			noctalia.notify(t("notify.started"):gsub("{name}", devRec.name or adbId))
		elseif op == "pair_and_cast" then
			-- 无线投屏：先尝试直接 connect（设备可能已配对/已连接过，
			-- 配对码是一次性的，重复配对会失败）；全部失败才执行 adb pair。
			local ip = cmd.address or ""
			local port = tostring(cmd.port or "")
			local debugPort = tostring(cmd.debugPort or "")
			local code = tostring(cmd.code or "")
			local params = cmd.params or persistence.loadParams(ip .. ":5555")
			noctalia.log("[phone-operate] pair_and_cast: " .. tostring(ip) .. ":" .. tostring(port)
				.. " debugPort=" .. tostring(debugPort))
			if ip == "" then
				noctalia.log("[phone-operate] pair_and_cast: missing address")
				noctalia.notifyError(t("error.pair_failed"), "missing address")
				return
			end
			-- 候选调试端口：用户填的 → 5555。注意：配对端口不是调试端口
			-- （配对端口一次性，配对后即失效），connect 它会得到 offline/拒绝，
			-- 所以不作为 connect 候选。
			local candidates = { debugPort, "5555" }

			local function finishCast(serial)
				persistence.addHistory(serial, ip, "wifi")
				persistence.saveParams(serial, params)
				scrcpyRunning[serial] = true
				local ok = scrcpy.start({ id = serial }, params)
				noctalia.log("[phone-operate] scrcpy.start -> " .. tostring(ok))
				publishRunning()
				if params.record then cleanupRecordings() end
				refreshAdbDevices()
				noctalia.notify(t("notify.started"):gsub("{name}", ip))
			end

			local function tryConnect(candidatesLeft, onAllFail, offlineSeen)
				local tried = {}
				local function next()
					local target
					for _, c in ipairs(candidatesLeft) do
						if c and c ~= "" and not tried[c] then
							tried[c] = true
							target = c
							break
						end
					end
					if not target then
						if offlineSeen then
							-- 连上过但设备 offline：是 Wi-Fi 连接问题，配对解决不了
							noctalia.notifyError(t("error.device_offline"), ip)
						else
							onAllFail()
						end
						return
					end
					local trySerial = ip .. ":" .. target
					adb.connectAsync(trySerial, function(connOk, connOut)
						noctalia.log("[phone-operate] adb connect -> " .. tostring(connOk)
							.. " (" .. tostring(trySerial) .. ")"
							.. (connOut and (" | " .. connOut:gsub("[\r\n]+", " ")) or ""))
						if connOk then
							-- connect 返回 "already connected" 但设备可能 offline
							-- （无线调试连接在手机休眠后常见）：查状态确认可投屏
							adb.deviceStateAsync(trySerial, function(state)
								noctalia.log("[phone-operate] device state (" .. trySerial .. ") = "
									.. tostring(state))
								if state == "device" then
									finishCast(trySerial)
								elseif state == "offline" then
									-- offline 连接无意义：断开后试下一个端口
									adb.disconnect(trySerial)
									next(true)
								else
									-- 不存在或未授权：试下一个端口
									next(false)
								end
							end)
							return
						end
						next(false)
					end)
				end
				next(false)
			end

			-- 第一步：直接 connect（已配对过则直接成功，无需重新配对）
			tryConnect(candidates, function()
				-- 全部 connect 失败：需要配对（配对码一次性，需用户提供新的）
				if port == "" or code == "" then
					noctalia.notifyError(t("error.conn_failed"), t("error.conn_hint"))
					return
				end
				adb.pairAsync(ip .. ":" .. port, code, function(pairOk, pairOut)
					noctalia.log("[phone-operate] adb pair -> " .. tostring(pairOk)
						.. (pairOut and (" | " .. pairOut:gsub("[\r\n]+", " ")) or ""))
					if not pairOk then
						noctalia.notifyError(t("error.pair_failed"), pairOut or "")
						return
					end
					noctalia.notify(t("notify.pair_success"))
					-- 配对端口是一次性的，配对后 adb 可能残留 offline 连接；
					-- 断开它，避免 connect 调试端口时被误判为 already connected。
					adb.disconnect(ip .. ":" .. port)
					adb.disconnect(ip .. ":" .. debugPort)
					adb.disconnect(ip .. ":5555")
					-- 给 adb 一点时间完成配对状态
					noctalia.runAsync("sleep 1", function()
						-- 配对成功后再次尝试 connect（只试调试端口 + 5555）
						tryConnect(candidates, function()
							noctalia.notifyError(t("error.conn_failed"), t("error.conn_hint"))
						end)
					end)
				end)
			end)
		elseif op == "stop_cast" then
			scrcpy.stop(cmd.device)
			scrcpyRunning[cmd.device] = nil
			publishRunning()
			local d = devices["adb:" .. cmd.device]
			noctalia.notify(t("notify.stopped"):gsub("{name}", d and d.name or cmd.device))
		elseif op == "restart_params" then
			local adbId = cmd.device
			local wasRunning = scrcpyRunning[adbId] ~= nil
			if wasRunning then scrcpy.stop(adbId) end
			local params = cmd.params or persistence.loadParams(adbId)
			persistence.saveParams(adbId, params)
			if wasRunning then scrcpy.start({ id = adbId }, params) end
			publishRunning()
		elseif op == "stop_all_cast" then
			for adbId, _ in pairs(scrcpyRunning) do
				scrcpy.stop(adbId)
			end
			scrcpyRunning = {}
			publishRunning()
		elseif op == "adb_pair" then
		adb.pairAsync(cmd.address, cmd.code, function(ok)
			if ok then
				noctalia.notify(t("notify.pair_success"))
			end
		end)
	elseif op == "adb_connect" then
		adb.connectAsync(cmd.address, function(ok)
			if ok then
				persistence.addHistory(cmd.address, cmd.address, "wifi")
				refreshAdbDevices()
			end
		end)
	elseif op == "adb_disconnect" then
		adb.disconnect(cmd.device)
		scrcpyRunning[cmd.device] = nil
		publishRunning()
		refreshAdbDevices()
	elseif op == "usb_mode" then
		adb.usbMode(cmd.device)
	else
		noctalia.log("[phone-operate] unknown cmd op: " .. tostring(op))
	end
end

-- ── 轮询间隔合并（kde 与 adb 取较快） ─────────────────────────────────────────
intervalMs = function()
	if pendingPick then return 1000 end
	local secs = tonumber(noctalia.getConfig("state_update_interval")) or 30
	if secs <= 0 then return 3600000 end
	for _, d in pairs(devices) do
		if d.mediaisPlaying == true then return 1000 end
	end
	return secs * 1000
end

combinedIntervalMs = function()
	local poll = tonumber(noctalia.getConfig("poll_interval_ms")) or 3000
	local k = intervalMs()
	if k < poll then return k end
	return poll
end

-- ── 生命周期 ──────────────────────────────────────────────────────────────────
local reapCounter = 0

function update()
	local secs = tonumber(noctalia.getConfig("state_update_interval")) or 30
	noctalia.setUpdateInterval(combinedIntervalMs())
	pollPendingPick()
	refreshAdbDevices()
	if secs <= 0 then
		-- kde 自动刷新被禁用；adb 仍轮询
	else
		detectBackend()
		refreshDevices()
	end
	reapCounter = reapCounter + 1
	if reapCounter >= 5 then
		reapCounter = 0
		pruneRunning()
	end
end

function onConfigChanged()
	noctalia.setUpdateInterval(combinedIntervalMs())
	local lang = noctalia.getConfig("language") or "en"
	if lang ~= noctalia.state.get("pc.lang") then
		publishTranslations(lang)
	end
end

function onIpc(event, payload)
	if event == "refresh" then
		refreshDevices()
		refreshAdbDevices()
	elseif event == "cmd" and payload then
		local ok, cmd = pcall(noctalia.json.decode, payload)
		if ok and type(cmd) == "table" then
			handleCommand(cmd)
		else
			noctalia.log("[phone-operate] onIpc cmd: invalid json payload")
		end
	end
end

-- 顶层初始化（加载时运行一次）
detectBackend()
refreshDevices()
refreshAdbDevices()

-- 启动时自动连接历史无线 adb 设备（单次尝试，失败不重试不打扰）
do
	local history = persistence.loadHistory()
	for _, entry in ipairs(history) do
		if entry.transport == "wifi" then
			adb.connectAsync(entry.id, function(ok)
				if ok then refreshAdbDevices() end
			end)
		end
	end
end

local lastCmdSeq = 0
noctalia.state.watch("pc.cmd", function(cmd)
	if type(cmd) ~= "table" then return end
	local seq = tonumber(cmd.seq) or 0
	if seq <= lastCmdSeq then return end
	lastCmdSeq = seq
	cmd.seq = nil
	handleCommand(cmd)
end)