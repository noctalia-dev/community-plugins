--!nonstrict
-- OPNsense traffic backend. Polls /api/diagnostics/traffic/interface, turns the
-- byte counters of every interface into rates and publishes one snapshot for
-- widget and panel. With auto_detect on and no interface configured it picks
-- the interface that carries the default route (/api/interfaces/overview).
-- Rates are published from the point of view of the network behind an
-- interface, see isWanSide.
--
-- The API key never goes into the Noctalia settings: it is read from a
-- key=/secret= file (the format OPNsense offers for download), so it does not
-- end up in settings.toml or anything mirrored from it.

local peaks = require("./lib/peaks.luau")

local SNAPSHOT_KEY = "opnsense_snapshot"
local COMMAND_KEY = "opnsense_command"
local HISTORY = 40
local DETECT_EVERY_MS = 10 * 60 * 1000

local running = false
local lastRun = 0
local counters = {} -- id -> { rx, tx, t }
local rates = {} -- id -> { rx, tx }
local history = { id = "", rx = {}, tx = {}, peakRx = 0, peakTx = 0 }
-- Interface ids hidden with the eye button in the panel, kept in the plugin
-- data dir (scripts cannot write settings). The hidden_interfaces setting
-- hides further ones by id, name or device.
local panelHidden = {}

local function hiddenFile()
	local dir = noctalia.pluginDataDir()
	return dir ~= nil and (dir .. "/hidden.json") or nil
end

local function loadHidden()
	local p = hiddenFile()
	if p ~= nil and noctalia.fileExists(p) then
		local data = noctalia.json.decode(noctalia.readFile(p) or "")
		if type(data) == "table" then
			for _, id in ipairs(data) do
				panelHidden[tostring(id)] = true
			end
		end
	end
end

local function saveHidden()
	local p = hiddenFile()
	if p == nil then
		return
	end
	local ids = {}
	for id in pairs(panelHidden) do
		table.insert(ids, id)
	end
	table.sort(ids)
	noctalia.writeFile(p, noctalia.json.encode(ids))
end

-- nil when visible, else "panel" or "settings" (where it was hidden).
local function hiddenBy(id, name, device)
	local list = noctalia.getConfig("hidden_interfaces")
	for _, entry in ipairs(type(list) == "table" and list or {}) do
		local wanted = noctalia.string.trim(tostring(entry)):lower()
		if wanted ~= "" and (wanted == id:lower() or wanted == name:lower() or wanted == device:lower()) then
			return "settings"
		end
	end
	if panelHidden[id] then
		return "panel"
	end
	return nil
end

peaks.load()
loadHidden()
-- From /api/interfaces/overview: the first interface with a default route
-- (auto-detect) and every one that has one (WAN side, see isWanSide).
local detected = { id = "", at = 0, error = "", upstream = {} }

local function config(key, fallback)
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

local function baseUrl()
	local url = noctalia.string.trim(tostring(config("url", "")))
	url = url:gsub("/+$", ""):gsub("/api$", "")
	return url
end

local function readCredentials()
	local path = noctalia.expandPath(tostring(config("credentials_file", "")))
	if path == "" or not noctalia.fileExists(path) then
		return nil, noctalia.tr("errors.no_credentials", { path = path })
	end
	local raw = noctalia.readFile(path)
	if raw == nil then
		return nil, noctalia.tr("errors.no_credentials", { path = path })
	end
	local key = raw:match("key%s*=%s*([^%s]+)")
	local secret = raw:match("secret%s*=%s*([^%s]+)")
	if key == nil or secret == nil then
		return nil, noctalia.tr("errors.bad_credentials", { path = path })
	end
	return { key = key, secret = secret }
end

-- Noctalia's HTTP client keeps one HTTP/2 connection per host and reuses it.
-- After a suspend that connection is dead, and a timeout only ends the stream,
-- not the connection: every request hangs for 30 s until the kernel gives the
-- socket up (tcp_retries2, about 15 minutes). Plugins cannot ask for a fresh
-- connection, so for a while after a suspend or a timeout the requests go
-- through a curl process instead, which always connects anew.
local FALLBACK_MS = 20 * 60 * 1000
local SLEEP_GAP_S = 15
local fallbackUntil = 0
local lastTickSec = os.time()

local function useFallback()
	return noctalia.nowMs() < fallbackUntil and noctalia.commandExists("curl")
end

local function startFallback()
	fallbackUntil = noctalia.nowMs() + FALLBACK_MS
end

-- The key never reaches a command line: the shell reads it from the key file
-- and hands it to curl as a config on stdin (printf is a shell builtin).
local CURL_SCRIPT = [[
k=$(sed -n 's/^key=//p' "$1"); s=$(sed -n 's/^secret=//p' "$1")
printf 'user = "%s:%s"\n' "$k" "$s" | curl -sS -K - ${3:+-k} --max-time 10 -H 'Accept: application/json' -w '\n%{http_code}' "$2"
]]

local function curlRequest(path, cb)
	local keyFile = noctalia.expandPath(tostring(config("credentials_file", "")))
	local insecure = config("allow_insecure_tls", false) == true and "1" or ""
	local args = { "sh", "-c", CURL_SCRIPT, "sh", keyFile, baseUrl() .. "/api/" .. path, insecure }
	return noctalia.runAsync(args, function(result)
		local out = result.stdout or ""
		local body, status = out:match("^(.*)\n(%d+)%s*$")
		if result.exitCode ~= 0 or status == nil then
			cb({ ok = false, status = 0, body = "" })
			return
		end
		cb({ ok = true, status = tonumber(status), body = body })
	end, 15000)
end

local function request(creds, path, cb)
	if useFallback() then
		return curlRequest(path, cb)
	end
	return noctalia.http({
		url = baseUrl() .. "/api/" .. path,
		headers = { "Accept: application/json" },
		basic_username = creds.key,
		basic_password = creds.secret,
		allow_insecure_tls = config("allow_insecure_tls", false) == true,
	}, function(response)
		if not response.ok or (response.status or 0) == 0 then
			-- Likely the dead connection described above.
			startFallback()
		end
		cb(response)
	end)
end

-- Turns a failed response into a message; nil when the response is usable.
local function responseError(response, privilege)
	if not response.ok or (response.status or 0) == 0 then
		return noctalia.tr("errors.unreachable", { url = baseUrl() })
	elseif response.status == 401 then
		return noctalia.tr("errors.unauthorized")
	elseif response.status == 403 then
		return noctalia.tr("errors.forbidden", { privilege = privilege })
	elseif response.status ~= 200 then
		return noctalia.tr("errors.http", { status = tostring(response.status) })
	end
	return nil
end

local function publish(snapshot)
	snapshot.updatedAt = noctalia.nowMs()
	noctalia.state.set(SNAPSHOT_KEY, snapshot)
end

local function publishError(err)
	publish({ error = err, interfaces = {}, selected = "", rx = 0, tx = 0, history = history })
end

local function detect(creds)
	request(creds, "interfaces/overview/interfaces_info", function(response)
		detected.at = noctalia.nowMs()
		local err = responseError(response, "Status: Interfaces")
		if err ~= nil then
			detected.error = err
			return
		end
		local data = noctalia.json.decode(response.body or "")
		detected.id = ""
		detected.upstream = {}
		for _, row in ipairs(type(data) == "table" and data.rows or {}) do
			local id = tostring(row.identifier or "")
			if id ~= "" and type(row.routes) == "table" then
				for _, route in ipairs(row.routes) do
					if route == "default" then
						detected.upstream[id] = true
						if detected.id == "" then
							detected.id = id
						end
					end
				end
			end
		end
		detected.error = detected.id == "" and noctalia.tr("errors.no_default_route") or ""
	end)
end

-- OPNsense counts from the firewall's side of an interface: "received" on a
-- LAN interface is what its clients send. WAN-side interfaces keep that view
-- (received = download); all others are flipped so download is what the
-- network behind the interface downloads. WAN side is the wan_interfaces
-- setting when set, else interfaces with a default route plus any whose
-- identifier or name contains "wan" (OPNsense's default WAN, PPPoE parents).
local function isWanSide(id, name, device)
	local list = noctalia.getConfig("wan_interfaces")
	local configured = false
	for _, entry in ipairs(type(list) == "table" and list or {}) do
		local wanted = noctalia.string.trim(tostring(entry)):lower()
		if wanted ~= "" then
			configured = true
			if wanted == id:lower() or wanted == name:lower() or wanted == device:lower() then
				return true
			end
		end
	end
	if configured then
		return false
	end
	return detected.upstream[id] == true
		or id:lower():find("wan", 1, true) ~= nil
		or name:lower():find("wan", 1, true) ~= nil
end

-- Matches the configured name against identifier (opt1), description (WAN) and
-- device (pppoe0), case-insensitively.
local function resolve(interfaces)
	local wanted = noctalia.string.trim(tostring(config("interface", ""))):lower()
	if wanted == "" then
		if config("auto_detect", false) ~= true then
			return nil, noctalia.tr("errors.no_interface")
		end
		if detected.id == "" then
			return nil, detected.error ~= "" and detected.error or noctalia.tr("errors.detecting")
		end
		wanted = detected.id:lower()
	end
	for _, iface in ipairs(interfaces) do
		if iface.id:lower() == wanted or iface.name:lower() == wanted or iface.device:lower() == wanted then
			return iface
		end
	end
	return nil, noctalia.tr("errors.unknown_interface", { name = wanted })
end

local function push(list, value)
	table.insert(list, value)
	while #list > HISTORY do
		table.remove(list, 1)
	end
end

local function handleTraffic(response)
	local err = responseError(response, "Reporting: Traffic")
	if err ~= nil then
		publishError(err)
		return
	end
	local data = noctalia.json.decode(response.body or "")
	if type(data) ~= "table" or type(data.interfaces) ~= "table" then
		publishError(noctalia.tr("errors.bad_response"))
		return
	end

	-- Resolve against every interface first, so the selected one is never
	-- dropped; hidden ones get no rate, no counter state and no panel row.
	local all = {}
	for id, info in pairs(data.interfaces) do
		table.insert(all, { id = id, name = tostring(info.name or id), device = tostring(info.device or "") })
	end
	local iface, resolveErr = resolve(all)
	local selectedId = iface ~= nil and iface.id or ""

	-- Rates use the firewall's own timestamp of the counters, not the arrival
	-- time of the response: a response delayed on a stalled connection followed
	-- by a prompt one squeezes a long byte delta into a short local interval.
	-- Wall clock as a fallback.
	local now = tonumber(data.time) or os.time()
	local maxGap = math.max(tonumber(config("poll_interval", 2)) or 2, 1) * 5
	local interfaces = {}
	local hidden = {}
	for _, base in ipairs(all) do
		local id = base.id
		local info = data.interfaces[id]
		local by = id ~= selectedId and hiddenBy(id, base.name, base.device) or nil
		local rx = tonumber(info["bytes received"])
		local tx = tonumber(info["bytes transmitted"])
		if by ~= nil then
			counters[id] = nil
			rates[id] = nil
			table.insert(hidden, { id = id, name = base.name, device = base.device, by = by })
		elseif rx ~= nil and tx ~= nil then
			local prev = counters[id]
			if prev ~= nil and now > prev.t then
				local dt = now - prev.t
				-- Skip a sample whose counters went backwards (firewall reboot,
				-- interface reattach) or lie too far apart (missed polls): an
				-- average over such a gap is no current rate.
				if rx >= prev.rx and tx >= prev.tx and dt <= maxGap then
					rates[id] = { rx = (rx - prev.rx) / dt, tx = (tx - prev.tx) / dt }
				else
					rates[id] = nil
				end
			end
			counters[id] = { rx = rx, tx = tx, t = now }
			local rate = rates[id] or { rx = 0, tx = 0 }
			local wanSide = isWanSide(id, base.name, base.device)
			if not wanSide then
				rate = { rx = rate.tx, tx = rate.rx }
			end
			table.insert(interfaces, {
				id = id,
				name = base.name,
				device = base.device,
				rx = rate.rx,
				tx = rate.tx,
				wanSide = wanSide,
				ready = rates[id] ~= nil,
			})
		end
	end
	local function byName(a, b)
		return a.name:lower() < b.name:lower()
	end
	table.sort(interfaces, byName)
	table.sort(hidden, byName)

	if iface == nil then
		publish({ error = resolveErr, interfaces = interfaces, hidden = hidden, selected = "", rx = 0, tx = 0, history = history })
		return
	end
	for _, row in ipairs(interfaces) do
		if row.id == iface.id then
			iface = row
		end
	end
	if history.id ~= iface.id then
		history = { id = iface.id, rx = {}, tx = {} }
	end
	local nowSec = os.time()
	if iface.ready then
		push(history.rx, iface.rx)
		push(history.tx, iface.tx)
		peaks.record(iface.id, iface.rx, iface.tx, nowSec)
		peaks.save(false)
	end
	-- Peaks of the selected interface within the hold time; `since` and the
	-- *At fields are Unix seconds for the panel.
	local hold = math.max(tonumber(config("peak_hold_hours", 0)) or 0, 0)
	local peak = peaks.current(iface.id, hold, nowSec)
	history.peakRx = peak.rx
	history.peakRxAt = peak.rxAt
	history.peakTx = peak.tx
	history.peakTxAt = peak.txAt
	history.since = peak.since
	history.hold = hold
	publish({
		error = "",
		interfaces = interfaces,
		hidden = hidden,
		selected = iface.id,
		selectedName = iface.name,
		selectedDevice = iface.device,
		ready = iface.ready,
		rx = iface.rx,
		tx = iface.tx,
		history = history,
	})
end

local function poll()
	if running then
		return
	end
	lastRun = noctalia.nowMs()
	if baseUrl() == "" then
		publishError(noctalia.tr("errors.no_url"))
		return
	end
	local creds, err = readCredentials()
	if creds == nil then
		publishError(err)
		return
	end
	-- Also without auto-detect: the default routes mark the WAN side. Without
	-- the "Status: Interfaces" privilege this fails and only matters for
	-- auto-detect, which reports it.
	if detected.at == 0 or noctalia.nowMs() - detected.at >= DETECT_EVERY_MS then
		detected.at = noctalia.nowMs()
		detect(creds)
	end
	running = true
	local viaFallback = useFallback()
	local accepted = request(creds, "diagnostics/traffic/interface", function(response)
		running = false
		handleTraffic(response)
		-- A native timeout just switched to curl: retry now instead of waiting.
		if not viaFallback and useFallback() and (response.status or 0) == 0 then
			poll()
		end
	end)
	if not accepted then
		running = false
		publishError(noctalia.tr("errors.unreachable", { url = baseUrl() }))
	end
end

local function setHidden(id, hide)
	panelHidden[id] = hide or nil
	saveHidden()
	poll()
end

local function resetPeaks()
	if history.id ~= "" then
		peaks.reset(history.id, os.time())
	end
	poll()
end

noctalia.state.watch(COMMAND_KEY, function(cmd)
	if type(cmd) ~= "table" then
		return
	end
	if cmd.action == "refresh" then
		detected.at = 0
		poll()
	elseif cmd.action == "reset_peaks" then
		resetPeaks()
	elseif (cmd.action == "hide" or cmd.action == "unhide") and type(cmd.id) == "string" then
		setHidden(cmd.id, cmd.action == "hide")
	end
end)

function onIpc(event, payload)
	if event == "refresh" then
		detected.at = 0
		poll()
	elseif event == "reset-peaks" then
		resetPeaks()
	elseif (event == "hide" or event == "unhide") and type(payload) == "string" and payload ~= "" then
		setHidden(noctalia.string.trim(payload), event == "hide")
	end
end

-- Tick fast and poll once the configured interval passed, so a changed
-- poll_interval takes effect without a restart.
noctalia.setUpdateInterval(250)

function update()
	-- The tick stops while the machine sleeps; a gap in wall-clock time means
	-- it just woke up, so skip the dead connection right away.
	local nowSec = os.time()
	if nowSec - lastTickSec > SLEEP_GAP_S then
		startFallback()
		counters = {}
		lastRun = 0
	end
	lastTickSec = nowSec
	local interval = math.max(tonumber(config("poll_interval", 2)) or 2, 1) * 1000
	if noctalia.nowMs() - lastRun >= interval then
		poll()
	end
end

poll()
