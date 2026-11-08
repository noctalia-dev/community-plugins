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

local DNS_HOST = cfgString("dns_check_host", "")
local HIDDEN = cfgSet("hidden_connections")
local NOTIFY = noctalia.getConfig("notify") ~= false

local s = {
	proton = {
		installed = noctalia.commandExists("protonvpn") == true,
		signedIn = false,
		checked = false, -- true once `protonvpn info` has answered
		up = false,
		busy = false,
		action = "",
		server = "",
		location = "",
		load = "",
		protocol = "",
		ip = "",
		error = "",
	},
	config = { killSwitch = "off", netshield = "off" },
	wg = {
		available = noctalia.commandExists("nmcli") == true,
		checked = false, -- true once `nmcli` has answered
		connections = {}, -- { name, uuid, device, state, busy }
	},
	dns = { host = DNS_HOST, checked = false, ok = true },
	countries = {},
	updatedAt = 0,
}

local tick = 0
local busyUuids = {}
local statusBusy, configBusy, dnsBusy, listBusy = false, false, false, false

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
	if configBusy or not s.proton.installed or not s.proton.signedIn then
		return
	end
	configBusy = true
	noctalia.runAsync({ "protonvpn", "config", "list" }, function(r)
		configBusy = false
		for line in clean(r.stdout):gmatch("[^\r\n]+") do
			local k, v = line:match("^%s*(%S+)%s+(%S+)%s*$")
			if k == "kill-switch" then
				s.config.killSwitch = v
			elseif k == "netshield" then
				s.config.netshield = v
			end
		end
		publish()
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
		s.proton.signedIn = acc ~= nil and acc ~= "" and acc ~= "None"
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
		if r.exitCode ~= 0 then
			return
		end
		local wasUp = anyWgUp()
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

local function refreshProtonLink()
	local up = noctalia.fileExists("/sys/class/net/" .. PROTON_IFACE) == true
	if up == s.proton.up then
		return
	end
	s.proton.up = up
	if up then
		pollStatus()
	else
		s.proton.server = ""
		s.proton.location = ""
		s.proton.load = ""
		s.proton.protocol = ""
		s.proton.ip = ""
		-- Drop that was not requested from the plugin.
		if NOTIFY and not s.proton.busy then
			noctalia.notify(noctalia.tr("proton.title"), noctalia.tr("notify.dropped"))
		end
	end
	checkDns()
	publish()
end

-- ── Actions ───────────────────────────────────────────────────────────────

local function connect(target)
	if s.proton.busy or not s.proton.installed then
		return
	end
	local argv = { "protonvpn", "connect" }
	target = tostring(target or "")
	if target:match("^%a%a$") then
		table.insert(argv, "--country")
		table.insert(argv, target:upper())
	elseif target:match("^[%w%-]+#%d+$") then
		table.insert(argv, target:upper())
	end

	s.proton.busy = true
	s.proton.action = "connecting"
	s.proton.error = ""
	publish()

	noctalia.runAsync(argv, function(r)
		s.proton.busy = false
		s.proton.action = ""
		local out = output(r)
		if r.exitCode == 0 and not r.timedOut then
			local ip = out:match("IP address is (%S+)")
			s.proton.ip = if ip then (ip:gsub("%.$", "")) else ""
			local where = out:match("Connected to ([^\r\n]+)")
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
		refreshProtonLink()
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
	noctalia.runAsync({ "protonvpn", "disconnect" }, function(r)
		s.proton.busy = false
		s.proton.action = ""
		if r.exitCode ~= 0 or r.timedOut then
			s.proton.error = errorText(r)
			noctalia.notifyError(noctalia.tr("proton.title"), s.proton.error)
		end
		refreshProtonLink()
		publish()
	end, 30000)
end

local function setConfig(setting, value, allowed)
	if not allowed[value] or not s.proton.installed then
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
	op = tostring(op or ""):gsub("-", "_")
	if op == "connect" then
		connect(value)
	elseif op == "disconnect" then
		disconnect()
	elseif op == "toggle_proton" then
		if s.proton.up then
			disconnect()
		else
			connect(value)
		end
	elseif op == "killswitch" then
		setConfig("kill-switch", value, { off = true, standard = true })
	elseif op == "netshield" then
		setConfig("netshield", value, { off = true, ["malware-only"] = true, ["malware-ads-trackers"] = true })
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
--   noctalia msg plugin gitgxldf1sh/proton-wireguard:service all connect CH
--   noctalia msg plugin gitgxldf1sh/proton-wireguard:service all toggle-wg <name>
function onIpc(event, payload)
	dispatch(event, payload)
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

refreshProtonLink()
pollWireGuard()
pollAccount()
publish()
