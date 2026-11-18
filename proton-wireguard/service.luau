--!nonstrict
-- Background service. Tracks Proton VPN (through the official `protonvpn`
-- CLI) and every WireGuard connection known to NetworkManager (through
-- `nmcli`), and publishes one snapshot to noctalia.state for the bar, the
-- panel and the shortcut.
--
-- This plugin only *controls* existing setups. It never creates, edits or
-- deletes WireGuard connections/peers, and it never touches Proton's files.
--
-- Detection: Proton is up only when the `proton0` interface exists. Proton's
-- own NetworkManager profiles ("ProtonVPN …") are excluded from the WireGuard
-- list, so the two can never be confused.

noctalia.setUpdateInterval(1000)

local STATE_KEY = "pw.state"
local CMD_KEY = "pw.cmd"
local PROTON_IFACE = "proton0"
-- Dummy interfaces of Proton's NetworkManager kill switch. One of them left
-- behind while proton0 is gone means the kill switch is blocking traffic.
local KS_IFACES = { "pvpnksintrf0", "pvpnksintrf1" }
local LAST_FILE = "last.json"
-- How long after a plugin-requested change a link going down is not reported
-- as a drop.
local QUIET_MS = 5000

local FEATURE_ORDER = { "p2p", "securecore", "tor", "random" }
local FEATURE_FLAG = { p2p = "--p2p", securecore = "--securecore", tor = "--tor", random = "--random" }
local FEATURE_ALIAS = { ["secure-core"] = "securecore", ["secure_core"] = "securecore" }

local ON_OFF = { off = true, on = true }
-- op -> { CLI setting, allowed values, { off value, on value } for "toggle" }
local SETTINGS = {
	killswitch = { "kill-switch", { off = true, standard = true }, { "off", "standard" } },
	netshield = {
		"netshield",
		{ off = true, ["malware-only"] = true, ["malware-ads-trackers"] = true },
		{ "off", "malware-ads-trackers" },
	},
	port_forwarding = { "port-forwarding", ON_OFF, { "off", "on" } },
	vpn_accelerator = { "vpn-accelerator", ON_OFF, { "off", "on" } },
	moderate_nat = { "moderate-nat", ON_OFF, { "off", "on" } },
	ipv6 = { "ipv6", ON_OFF, { "off", "on" } },
}
-- CLI setting name -> key in s.config
local CONFIG_KEY = {
	["kill-switch"] = "killSwitch",
	["netshield"] = "netshield",
	["port-forwarding"] = "portForwarding",
	["vpn-accelerator"] = "vpnAccelerator",
	["moderate-nat"] = "moderateNat",
	["ipv6"] = "ipv6",
}

local function cfgString(key, default)
	local v = noctalia.getConfig(key)
	if type(v) ~= "string" then
		return default
	end
	v = noctalia.string.trim(v)
	if v == "" then
		return default
	end
	return v
end

local function cfgSet(key)
	local set = {}
	local v = noctalia.getConfig(key)
	if type(v) == "table" then
		for _, item in ipairs(v) do
			local name = noctalia.string.trim(tostring(item))
			if name ~= "" then
				set[name] = true
			end
		end
	end
	return set
end

local DNS_HOST, HIDDEN, NOTIFY, QUICK = "", {}, true, "fastest"

local s = {
	proton = {
		installed = noctalia.commandExists("protonvpn") == true,
		signedIn = false,
		checked = false, -- true once `protonvpn info` has answered
		up = false,
		busy = false,
		action = "", -- "connecting" | "disconnecting" | "cancelling"
		canCancel = noctalia.commandExists("pkill") == true,
		blocked = false, -- kill switch is holding traffic while Proton is down
		server = "",
		location = "",
		load = "",
		protocol = "",
		ip = "",
		error = "",
		last = "", -- last target that connected ("" = fastest), see parseTarget
		quick = "fastest", -- what a connect without target does: "fastest" | "last"
	},
	-- "" = not reported by this CLI version
	config = {
		killSwitch = "off",
		netshield = "off",
		portForwarding = "",
		vpnAccelerator = "",
		moderateNat = "",
		ipv6 = "",
	},
	wg = {
		available = noctalia.commandExists("nmcli") == true,
		checked = false, -- true once `nmcli` has answered
		connections = {}, -- { name, uuid, device, state, busy }
	},
	dns = { host = "", checked = false, ok = true },
	countries = {},
	updatedAt = 0,
}

local function loadConfig()
	DNS_HOST = cfgString("dns_check_host", "")
	HIDDEN = cfgSet("hidden_connections")
	NOTIFY = noctalia.getConfig("notify") ~= false
	QUICK = if cfgString("quick_connect", "fastest") == "last" then "last" else "fastest"
	s.dns.host = DNS_HOST
	s.proton.quick = QUICK
end

loadConfig()

local tick = 0
local busyUuids = {}
local expectDown = {} -- uuid -> ms timestamp until which going down is expected
local quietUntil = 0
local cancelRequested = false
local statusBusy, dnsBusy = false, false
local configBusy, configPending = false, false
local listBusy, listPending = false, false

local function publish()
	s.updatedAt = os.time()
	noctalia.state.set(STATE_KEY, s)
end

-- Strip ANSI colours and surrounding whitespace from CLI output.
local function clean(text)
	local t = tostring(text or ""):gsub("\27%[[%d;]*%a", "")
	return noctalia.string.trim(t)
end

local function output(r)
	return clean((r.stdout or "") .. "\n" .. (r.stderr or ""))
end

-- Last non-empty lines of a failed command, short enough for a notification.
local function errorText(r)
	if r.timedOut then
		return "timeout"
	end
	local lines = {}
	for line in output(r):gmatch("[^\r\n]+") do
		line = noctalia.string.trim(line)
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	local msg = table.concat(lines, " ", math.max(1, #lines - 1))
	if #msg > 200 then
		msg = msg:sub(1, 200) .. "…"
	end
	return msg
end

local function anyWgUp()
	for _, c in ipairs(s.wg.connections) do
		if c.state == "activated" then
			return true
		end
	end
	return false
end

-- ── Connection targets ────────────────────────────────────────────────────
--
-- A target is a '+'-separated string, e.g. "CH", "CH#12", "United States",
-- "city:Zurich", "p2p", "NL+p2p", "securecore", "tor", "random". Empty or
-- "fastest" means the fastest server. Returns nil when it cannot be understood.

local function safeName(text)
	return text ~= "" and text:sub(1, 1) ~= "-" and text:find("[%c#+]") == nil
end

local function parseTarget(value)
	local spec = { features = {} }
	for part in tostring(value or ""):gmatch("[^+]+") do
		part = noctalia.string.trim(part)
		local low = (part:lower():gsub("^%-%-", ""))
		low = FEATURE_ALIAS[low] or low
		if low == "" or low == "fastest" then
			-- nothing to add
		elseif FEATURE_FLAG[low] then
			spec.features[low] = true
		elseif low:sub(1, 5) == "city:" then
			local city = noctalia.string.trim(part:sub(6))
			if not safeName(city) then
				return nil
			end
			spec.city = city
		elseif part:match("^%a%a$") then
			spec.country = part:upper()
		elseif part:match("^[%w%-]+#%d+$") then
			spec.server = part:upper()
		elseif safeName(part) then
			spec.country = part -- full country name; the CLI validates it
		else
			return nil
		end
	end
	return spec
end

local function specArgv(spec)
	local argv = { "protonvpn", "connect" }
	if spec.server then
		table.insert(argv, spec.server)
	end
	if spec.country then
		table.insert(argv, "--country")
		table.insert(argv, spec.country)
	end
	if spec.city then
		table.insert(argv, "--city")
		table.insert(argv, spec.city)
	end
	for _, f in ipairs(FEATURE_ORDER) do
		if spec.features[f] then
			table.insert(argv, FEATURE_FLAG[f])
		end
	end
	return argv
end

-- Canonical form of a target, used to remember the last connection.
local function specString(spec)
	local parts = {}
	if spec.server then
		table.insert(parts, spec.server)
	end
	if spec.country then
		table.insert(parts, spec.country)
	end
	if spec.city then
		table.insert(parts, "city:" .. spec.city)
	end
	for _, f in ipairs(FEATURE_ORDER) do
		if spec.features[f] then
			table.insert(parts, f)
		end
	end
	return table.concat(parts, "+")
end

local function lastPath()
	local dir = noctalia.pluginDataDir()
	return if dir then `{dir}/{LAST_FILE}` else nil
end

local function loadLast()
	local path = lastPath()
	if not path or not noctalia.fileExists(path) then
		return
	end
	local text = noctalia.readFile(path)
	local data = if text then noctalia.json.decode(text) else nil
	if type(data) == "table" and type(data.target) == "string" and parseTarget(data.target) then
		s.proton.last = data.target
	end
end

local function saveLast(target)
	if s.proton.last == target then
		return
	end
	s.proton.last = target
	local path = lastPath()
	local text = noctalia.json.encode({ target = target })
	if path and text then
		noctalia.writeFile(path, text)
	end
end

-- ── Proton CLI ────────────────────────────────────────────────────────────

local function pollStatus()
	if statusBusy or not s.proton.installed then
		return
	end
	statusBusy = true
	noctalia.runAsync({ "protonvpn", "status" }, function(r)
		statusBusy = false
		for line in output(r):gmatch("[^\r\n]+") do
			local k, v = line:match("^%s*([%a ]+):%s*(.-)%s*$")
			if k then
				k = k:lower()
				if k == "server" then
					local id, loc = v:match("^(%S+) in (.+)$")
					s.proton.server = id or v
					s.proton.location = loc or ""
				elseif k == "load" then
					s.proton.load = v
				elseif k == "protocol" then
					s.proton.protocol = v
				end
			end
		end
		publish()
	end, 15000)
end

local function pollConfig()
	if not s.proton.installed or not s.proton.signedIn then
		return
	end
	if configBusy then
		configPending = true -- a change landed mid-poll: read again afterwards
		return
	end
	configBusy = true
	noctalia.runAsync({ "protonvpn", "config", "list" }, function(r)
		configBusy = false
		for line in clean(r.stdout):gmatch("[^\r\n]+") do
			local k, v = line:match("^%s*(%S+)%s+(%S+)%s*$")
			local key = k and CONFIG_KEY[k]
			if key then
				s.config[key] = v
			end
		end
		publish()
		if configPending then
			configPending = false
			pollConfig()
		end
	end, 15000)
end

local function loadCountries()
	if not s.proton.installed or not s.proton.signedIn or #s.countries > 0 then
		return
	end
	noctalia.runAsync({ "protonvpn", "countries", "list" }, function(r)
		if r.exitCode ~= 0 then
			return
		end
		local list = {}
		for line in clean(r.stdout):gmatch("[^\r\n]+") do
			local name, code = line:match("^(.-)%s%s+(%u%u)%s*$")
			if name and code then
				table.insert(list, { name = noctalia.string.trim(name), code = code })
			end
		end
		if #list > 0 then
			s.countries = list
			publish()
		end
	end, 60000)
end

local function pollAccount()
	s.proton.installed = noctalia.commandExists("protonvpn") == true
	if not s.proton.installed then
		s.proton.signedIn = false
		s.proton.checked = true
		publish()
		return
	end
	noctalia.runAsync({ "protonvpn", "info" }, function(r)
		local out = output(r)
		local acc = out:match("Account:%s*'([^']*)'") or out:match("Account:%s*(%S+)")
		local was = s.proton.signedIn
		if acc ~= nil then
			s.proton.signedIn = acc ~= "" and acc ~= "None"
		elseif not r.timedOut and (r.exitCode == 0 or out:lower():find("sign in", 1, true)) then
			s.proton.signedIn = false
		end
		-- Otherwise the CLI timed out or crashed: keep what we knew instead of
		-- flipping the panel to "sign in".
		s.proton.checked = true
		if s.proton.signedIn and not was then
			pollConfig()
			loadCountries()
		end
		publish()
	end, 15000)
end

-- ── WireGuard (NetworkManager) ────────────────────────────────────────────

-- Split one line of `nmcli -t` output. Fields are ':'-separated; literal ':'
-- and '\' inside a field are escaped with '\'.
local function splitTerse(line)
	local fields, cur, i = {}, {}, 1
	while i <= #line do
		local ch = line:sub(i, i)
		if ch == "\\" and i < #line then
			table.insert(cur, line:sub(i + 1, i + 1))
			i += 2
		elseif ch == ":" then
			table.insert(fields, table.concat(cur))
			cur = {}
			i += 1
		else
			table.insert(cur, ch)
			i += 1
		end
	end
	table.insert(fields, table.concat(cur))
	return fields
end

local checkDns -- forward declaration

local function pollWireGuard()
	if listBusy then
		listPending = true -- an action finished mid-poll: list again afterwards
		return
	end
	s.wg.available = noctalia.commandExists("nmcli") == true
	if not s.wg.available then
		s.wg.connections = {}
		s.wg.checked = true
		publish()
		return
	end
	listBusy = true
	noctalia.runAsync({ "nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE,STATE", "connection", "show" }, function(r)
		listBusy = false
		local rerun = listPending
		listPending = false
		if r.exitCode == 0 and not r.timedOut then
			local wasUp = anyWgUp()
			local prev = {}
			for _, c in ipairs(s.wg.connections) do
				prev[c.uuid] = c.state
			end
			local now = noctalia.nowMs()
			local list = {}
			for line in (r.stdout or ""):gmatch("[^\r\n]+") do
				local f = splitTerse(line)
				local name, uuid, ctype, device, state = f[1] or "", f[2] or "", f[3] or "", f[4] or "", f[5] or ""
				local isProton = name:find("^ProtonVPN") ~= nil or device == PROTON_IFACE
				if ctype == "wireguard" and not isProton and not HIDDEN[name] and uuid ~= "" then
					table.insert(list, {
						name = name,
						uuid = uuid,
						device = device,
						state = state,
						busy = busyUuids[uuid] == true,
					})
					-- A tunnel that was up went down and nobody asked this plugin for it.
					local expected = busyUuids[uuid] or (expectDown[uuid] or 0) > now
					if NOTIFY and not rerun and prev[uuid] == "activated" and state ~= "activated" and not expected then
						noctalia.notify("WireGuard", noctalia.tr("notify.wg_dropped", { name = name }))
					end
				end
			end
			table.sort(list, function(a, b)
				return a.name:lower() < b.name:lower()
			end)
			s.wg.connections = list
			s.wg.checked = true
			if anyWgUp() ~= wasUp then
				checkDns()
			end
			publish()
		end
		if rerun then
			pollWireGuard()
		end
	end, 10000)
end

-- With Proton and a WireGuard tunnel up at once, Proton's DNS usually wins.
-- If the user configured a test host, check that it still resolves.
checkDns = function()
	if DNS_HOST == "" or not s.proton.up or not anyWgUp() then
		if s.dns.checked then
			s.dns.checked = false
			publish()
		end
		return
	end
	if dnsBusy then
		return
	end
	dnsBusy = true
	noctalia.runAsync({ "getent", "hosts", DNS_HOST }, function(r)
		dnsBusy = false
		s.dns.checked = true
		s.dns.ok = r.exitCode == 0 and not r.timedOut
		publish()
	end, 6000)
end

-- ── Link detection ────────────────────────────────────────────────────────

local function killSwitchHolding()
	for _, iface in ipairs(KS_IFACES) do
		if noctalia.fileExists("/sys/class/net/" .. iface) then
			return true
		end
	end
	return false
end

local function refreshProtonLink()
	local up = noctalia.fileExists("/sys/class/net/" .. PROTON_IFACE) == true
	local blocked = not up and not s.proton.busy and killSwitchHolding()
	local changed = blocked ~= s.proton.blocked
	s.proton.blocked = blocked

	if up ~= s.proton.up then
		changed = true
		s.proton.up = up
		if up then
			s.proton.error = ""
			pollStatus()
		else
			s.proton.server = ""
			s.proton.location = ""
			s.proton.load = ""
			s.proton.protocol = ""
			s.proton.ip = ""
			-- Drop that was not requested from the plugin.
			if NOTIFY and not s.proton.busy and noctalia.nowMs() >= quietUntil then
				local armed = s.config.killSwitch ~= "off" and s.config.killSwitch ~= ""
				noctalia.notify(
					noctalia.tr("proton.title"),
					noctalia.tr(if armed then "notify.dropped_killswitch" else "notify.dropped")
				)
			end
		end
		checkDns()
	end
	if changed then
		publish()
	end
end

-- ── Actions ───────────────────────────────────────────────────────────────

-- Runs `protonvpn disconnect` with s.proton.busy already set by the caller.
local function runDisconnect(quiet)
	noctalia.runAsync({ "protonvpn", "disconnect" }, function(r)
		-- Read the link while still busy, so that the interface going away is
		-- not mistaken for a drop.
		quietUntil = noctalia.nowMs() + QUIET_MS
		refreshProtonLink()
		s.proton.busy = false
		s.proton.action = ""
		-- The interface is the truth: the CLI can exit non-zero after it has
		-- already printed "Disconnected." and torn the tunnel down.
		if s.proton.up then
			if not quiet then
				s.proton.error = errorText(r)
				noctalia.notifyError(noctalia.tr("proton.title"), s.proton.error)
			end
		else
			s.proton.error = ""
		end
		publish()
	end, 30000)
end

local function connect(target)
	if s.proton.busy or not s.proton.installed then
		return
	end
	target = noctalia.string.trim(tostring(target or ""))
	if target:lower() == "last" or (target == "" and QUICK == "last") then
		target = s.proton.last
	end
	local spec = parseTarget(target)
	if not spec then
		noctalia.notifyError(noctalia.tr("notify.connect_failed"), noctalia.tr("notify.bad_target", { target = target }))
		return
	end

	s.proton.busy = true
	s.proton.action = "connecting"
	s.proton.error = ""
	cancelRequested = false
	publish()

	noctalia.runAsync(specArgv(spec), function(r)
		local out = output(r)
		local cancelled = cancelRequested
		cancelRequested = false
		quietUntil = noctalia.nowMs() + QUIET_MS
		refreshProtonLink() -- while still busy: a failed switch is not a "drop"

		if cancelled then
			-- Tear down whatever the interrupted attempt left behind.
			s.proton.action = "disconnecting"
			publish()
			runDisconnect(true)
			return
		end

		s.proton.busy = false
		s.proton.action = ""
		-- The CLI exits 0 for some refusals ("No servers found…", plan limits),
		-- so success also needs the confirmation line or the interface.
		local where = out:match("Connected to ([^\r\n]+)")
		if r.exitCode == 0 and not r.timedOut and (where or s.proton.up) then
			local ip = out:match("IP address is (%S+)")
			s.proton.ip = if ip then (ip:gsub("%.$", "")) else ""
			saveLast(specString(spec))
			if NOTIFY and where then
				noctalia.notify(
					noctalia.tr("proton.title"),
					noctalia.tr("notify.connected", { server = (where:gsub("[%.%s]+$", "")) })
				)
			end
		else
			s.proton.error = errorText(r)
			noctalia.notifyError(noctalia.tr("notify.connect_failed"), s.proton.error)
		end
		pollStatus()
		publish()
	end, 60000)
end

local function disconnect()
	if s.proton.busy or not s.proton.installed then
		return
	end
	s.proton.busy = true
	s.proton.action = "disconnecting"
	publish()
	runDisconnect(false)
end

-- Interrupts a connection attempt in progress. The connect callback then
-- cleans up with `protonvpn disconnect`.
local function cancel()
	if not s.proton.busy or s.proton.action ~= "connecting" or not s.proton.canCancel then
		return
	end
	cancelRequested = true
	s.proton.action = "cancelling"
	publish()
	noctalia.runAsync({ "pkill", "-INT", "-f", "protonvpn connect" }, function() end, 5000)
end

local function setConfig(def, value)
	if not s.proton.installed then
		return
	end
	local setting, allowed, pair = def[1], def[2], def[3]
	value = tostring(value or ""):lower()
	if value == "toggle" then
		value = if s.config[CONFIG_KEY[setting]] == pair[1] then pair[2] else pair[1]
	end
	if not allowed[value] then
		return
	end
	noctalia.runAsync({ "protonvpn", "config", "set", setting, value }, function(r)
		if r.exitCode ~= 0 or r.timedOut then
			noctalia.notifyError(noctalia.tr("proton.title"), errorText(r))
		end
		pollConfig()
	end, 15000)
end

-- Accepts a connection name or UUID.
local function findWg(ref)
	ref = tostring(ref or "")
	for _, c in ipairs(s.wg.connections) do
		if c.uuid == ref or c.name == ref then
			return c
		end
	end
	return nil
end

local function setWg(ref, up)
	local c = findWg(ref)
	if not c or busyUuids[c.uuid] then
		return
	end
	if up == nil then
		up = c.state ~= "activated"
	end
	busyUuids[c.uuid] = true
	c.busy = true
	publish()
	noctalia.runAsync({ "nmcli", "connection", if up then "up" else "down", "uuid", c.uuid }, function(r)
		busyUuids[c.uuid] = nil
		-- Covers the polls right after the action, whatever its outcome.
		expectDown[c.uuid] = noctalia.nowMs() + QUIET_MS
		if r.exitCode ~= 0 or r.timedOut then
			noctalia.notifyError(noctalia.tr("notify.wg_failed", { name = c.name }), errorText(r))
		end
		pollWireGuard()
	end, 30000)
end

local function refreshAll()
	refreshProtonLink()
	pollWireGuard()
	pollAccount()
	pollConfig()
	if s.proton.up then
		pollStatus()
	end
	loadCountries()
	checkDns()
end

local function dispatch(op, value)
	op = (tostring(op or ""):gsub("-", "_"))
	if op == "connect" then
		connect(value)
	elseif op == "disconnect" then
		disconnect()
	elseif op == "cancel" then
		cancel()
	elseif op == "toggle_proton" then
		if s.proton.busy then
			cancel()
		elseif s.proton.up then
			disconnect()
		else
			connect(value)
		end
	elseif SETTINGS[op] then
		setConfig(SETTINGS[op], value)
	elseif op == "wg_up" then
		setWg(value, true)
	elseif op == "wg_down" then
		setWg(value, false)
	elseif op == "toggle_wg" then
		setWg(value, nil)
	elseif op == "signin" then
		if s.proton.installed then
			noctalia.runInTerminal(`bash '{noctalia.pluginDir()}/signin.sh'`)
		end
	elseif op == "refresh" then
		refreshAll()
	end
end

noctalia.state.watch(CMD_KEY, function(cmd)
	if type(cmd) == "table" then
		dispatch(cmd.op, cmd.value)
	end
end)

-- Keybind-friendly IPC, e.g.:
--   noctalia msg plugin gitgxldf1sh/proton-wireguard:service all toggle-proton
--   noctalia msg plugin gitgxldf1sh/proton-wireguard:service all connect CH+p2p
--   noctalia msg plugin gitgxldf1sh/proton-wireguard:service all killswitch toggle
--   noctalia msg plugin gitgxldf1sh/proton-wireguard:service all toggle-wg <name>
function onIpc(event, payload)
	dispatch(event, payload)
end

function onConfigChanged()
	loadConfig()
	s.dns.checked = false
	pollWireGuard()
	checkDns()
	publish()
end

function update()
	tick += 1
	refreshProtonLink()
	if tick % 3 == 0 then
		pollWireGuard()
	end
	if s.proton.up and tick % 15 == 0 then
		pollStatus()
	end
	if tick % 30 == 0 then
		checkDns()
	end
	if tick % 60 == 0 then
		pollConfig()
	end
	if tick % 300 == 0 then
		pollAccount()
	end
end

loadLast()
refreshProtonLink()
pollWireGuard()
pollAccount()
publish()
