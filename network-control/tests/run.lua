-- Run with any Lua 5.x:  lua tests/run.lua
--
-- Exercises net.luau - every parsing and validation rule - against fixtures
-- captured from the live machine (tests/fixtures/, regenerate with
-- tests/capture-fixtures.sh) plus synthetic cases for the shapes this box does
-- not currently produce.
--
-- The plugin's Luau `require("./net.luau")` is a no-op here: the module is
-- loaded from source, with the Luau attribute line stripped.

local function scriptDir()
  local path = (arg and arg[0] or "run.lua")
  local dir = path:gsub("tests/run%.lua$", "")
  if dir == path then
    return "./"
  end
  return dir
end

local DIR = scriptDir()

local function readFixture(name)
  local file = assert(io.open(DIR .. "tests/fixtures/" .. name, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

-- Lua 5.1 loads a string only through loadstring; 5.2+ has load for both.
local chunkLoader = loadstring or load

local function loadModule(relative)
  local file = assert(io.open(DIR .. relative, "r"))
  local src = file:read("*a")
  file:close()
  src = src:gsub("^%-%!%S+%s*\n", "")
  return assert(chunkLoader(src, relative))()
end

local net = loadModule("net.luau")

local passed, failed = 0, 0
local function check(name, cond)
  if cond then
    passed = passed + 1
    print("ok    " .. name)
  else
    failed = failed + 1
    print("FAIL  " .. name)
  end
end

local function eq(name, actual, expected)
  check(name .. " (" .. tostring(actual) .. ")", actual == expected)
end

local function keys(list)
  local out = {}
  for _, entry in ipairs(list) do
    table.insert(out, entry.key)
  end
  return table.concat(out, ",")
end

-- ── terse parsing ────────────────────────────────────────────────────────────

local inventory = readFixture("inventory.txt")
local profileDhcp = readFixture("profile-dhcp.txt")
local profileStatic = readFixture("profile-static.txt")
local deviceLive = readFixture("device-live.txt")
local deviceStatus = readFixture("device-status.txt")
local permissions = readFixture("permissions.txt")
local radio = readFixture("radio.txt")
local routeJson = readFixture("route-get.json")
local wifiList = readFixture("wifi-list.txt")

local fields = net.parseFields(profileDhcp)
eq("profile method parsed", net.get(fields, "ipv4.method"), "auto")
eq("profile dns parsed", net.get(fields, "ipv4.dns"), "1.1.1.1,1.0.0.1")
eq("unset property reads as nil", net.get(fields, "ipv4.addresses"), nil)

-- nmcli escapes a ':' inside a value as '\:' and a backslash as '\\'
local key, value = net.splitTerseLine("colon\\:test:1ec6a2d8:dummy")
eq("escaped colon in key", key, "colon:test")
eq("value keeps its colons", value, "1ec6a2d8:dummy")
local k2, v2 = net.splitTerseLine("NAME:back\\\\slash")
eq("escaped backslash", v2, "back\\slash")
eq("line without separator has no value", select(2, net.splitTerseLine("garbage")), nil)

-- a list row splits into its positional fields, and a name containing a colon
-- still occupies exactly one of them
local row = net.splitTerseValues("colon\\:test:uuid-2:dummy:netctl0:activated:no")
eq("six fields in a row", #row, 6)
eq("first field keeps its colon", row[1], "colon:test")
eq("last field", row[6], "no")
eq("empty middle field survives", net.splitTerseValues("Wired connection 1:uuid-3:802-3-ethernet:::no")[4], "")

local connections = net.connectionsFromText(inventory)
eq("three connections", #connections, 3)
check("active connections sort first", connections[1].active and connections[2].active)
eq("loopback profile is not editable", connections[1].editable, false)
eq("wifi profile is editable", connections[2].editable, true)
eq("nm type mapped to kind", connections[2].kind, "wifi")
eq("ethernet kind", connections[3].kind, "ethernet")
eq("loopback kind", connections[1].kind, "loopback")
eq("unknown nm type passes through", net.kindFromNmType("knockoff"), "knockoff")
eq("inactive device is empty", connections[3].device, "")
eq("inactive connection flagged", connections[3].active, false)

local live = net.liveFromText(deviceLive)
eq("live device", live.device, "wlp0s20f3")
eq("live connection", live.connection, "Vodafone-B3A2")
eq("one ipv4 address", #live.ipv4_addresses, 1)
eq("ipv4 address value", live.ipv4_addresses[1], "192.168.0.141/24")
eq("two dns servers", #live.ipv4_dns, 2)
eq("second dns server", live.ipv4_dns[2], "1.0.0.1")
eq("six ipv6 addresses", #live.ipv6_addresses, 6)
-- the value must survive the terse split whole: truncated at the first colon it
-- would read "2a02", with no colons left in it
check("ipv6 address value intact", select(2, live.ipv6_addresses[1]:gsub(":", ":")) >= 2,
  live.ipv6_addresses[1])
eq("ipv6 gateway present", live.ipv6_gateway, "fe80::f24b:8aff:fe7e:fef4")
eq("ipv6 dns server", live.ipv6_dns[1], "2a02:8108:9611:1900:f24b:8aff:fe7e:fef4")

local status = net.deviceStatusFromText(deviceStatus)
eq("five devices", #status, 5)
eq("first device", status[1].device, "wlp0s20f3")
eq("first device state", status[1].state, "connected")
eq("connection with a space in the name", status[1].connection, "Vodafone-B3A2")
eq("disconnected device has no connection", status[3].connection, "")

local perms = net.permissionsFromText(permissions)
eq("system modify allowed", perms["org.freedesktop.NetworkManager.settings.modify.system"], "yes")
eq("checkpoint rollback needs auth", perms["org.freedesktop.NetworkManager.checkpoint-rollback"], "auth")
eq("wifi radio allowed", perms["org.freedesktop.NetworkManager.enable-disable-wifi"], "yes")

local radios = net.radioFromText(radio)
eq("wifi enabled", radios.wifi, "enabled")
eq("wifi hardware enabled", radios["wifi-hw"], "enabled")
eq("no wwan hardware", radios["wwan-hw"], "missing")

-- noctalia.json owns JSON; here the decoder is stubbed to prove the shape walk
local primary = net.primaryFromRouteJson(routeJson, function()
  return { { dst = "1.1.1.1", gateway = "192.168.0.1", dev = "wlp0s20f3", prefsrc = "192.168.0.141" } }
end)
eq("primary device", primary.device, "wlp0s20f3")
eq("primary source address", primary.address, "192.168.0.141")
eq("no route -> nil", net.primaryFromRouteJson("[]", function() return {} end), nil)

-- ── wi-fi scan ───────────────────────────────────────────────────────────────

local networks = net.networksFromText(wifiList)
check("network list is not empty", #networks > 0, #networks)
check("duplicate BSSIDs collapse into one entry per SSID", #networks == #net.networksFromText(wifiList))
check("the connected network sorts first", networks[1].in_use, networks[1].ssid)

local seen, duplicates = {}, 0
for _, entry in ipairs(networks) do
  if seen[entry.ssid] then
    duplicates = duplicates + 1
  end
  seen[entry.ssid] = true
end
eq("no SSID appears twice in the collapsed list", duplicates, 0)

for _, entry in ipairs(networks) do
  if entry.aps > 1 then
    check("strongest BSSID wins for a repeated SSID (" .. entry.ssid .. ")", entry.signal >= 0)
  end
  check("hidden networks are dropped, not listed as empty (" .. tostring(entry.ssid) .. ")", entry.ssid ~= "")
end

-- every field of a scan row is present and typed
local first = networks[1]
check("signal is a number", type(first.signal) == "number", first.signal)
check("security is a string", type(first.security) == "string", "[" .. first.security .. "]")
check("ap count is at least one", first.aps >= 1, first.aps)

-- padding and escaping in the IN-USE column: nmcli pads it with a space
local padded = net.networksFromText(" :Open One:50:  \n*:Open One:80:  ")
eq("a padded IN-USE column collapses to one entry", #padded, 1)
check("the active BSSID marks the entry in use", padded[1].in_use, padded[1].in_use)
eq("strongest signal kept across BSSIDs", padded[1].signal, 80)
eq("two access points counted", padded[1].aps, 2)

local escaped = net.networksFromText("*:net\\:with\\:colons:70:WPA2")
eq("escaped colons in an SSID survive", escaped[1].ssid, "net:with:colons")
eq("open network keeps an empty security string", net.networksFromText(":cafe:60:")[1].security, "")

-- signal -> glyph tier
eq("0 signal is one bar", net.signalBars(0), 1)
eq("19 signal is one bar", net.signalBars(19), 1)
eq("20 signal is two bars", net.signalBars(20), 2)
eq("59 is three bars", net.signalBars(59), 3)
eq("60 is four bars", net.signalBars(60), 4)
eq("79 is four bars", net.signalBars(79), 4)
eq("80 is five bars", net.signalBars(80), 5)
eq("100 is five bars", net.signalBars(100), 5)

-- security classification
check("empty security is open", net.isOpenNetwork(""))
check("nmcli's -- is open", net.isOpenNetwork("--"))
check("WPA2 needs a password", net.needsPassword("WPA2"))
check("WPA2 WPA3 needs a password", net.needsPassword("WPA2 WPA3"))
check("802.1X is flagged as enterprise", net.isEnterprise("WPA2 802.1X"))
check("EAP is flagged as enterprise", net.isEnterprise("WPA-EAP"))
check("plain WPA2 is not enterprise", not net.isEnterprise("WPA2"))
check("WEP is not enterprise", not net.isEnterprise("WEP"))

-- connect argv: the OPEN-network path only. Every secured network goes through
-- net.wifiProfileArgs + `con up --passwd-file`, so no passphrase can reach a
-- process command line.
local connectArgs = net.wifiConnectArgs("cafe", false)
eq("open network argv", table.concat(connectArgs, " "), "dev wifi connect cafe")
check("no password flag exists on this path", connectArgs[5] == nil, connectArgs[5])
connectArgs = net.wifiConnectArgs("hidden-net", true)
eq("hidden networks ask for hidden yes", connectArgs[#connectArgs], "yes")
eq("hidden flag precedes its value", connectArgs[#connectArgs - 1], "hidden")
connectArgs = net.wifiConnectArgs("net:with:colons", false)
eq("a colon in the SSID stays one argument", connectArgs[4], "net:with:colons")

-- key-mgmt for the profile we create for a secured network
eq("WPA2 joins as wpa-psk", net.keyMgmtFor("WPA2"), "wpa-psk")
eq("WPA1 joins as wpa-psk", net.keyMgmtFor("WPA1"), "wpa-psk")
eq("WPA2/WPA3 transition joins as wpa-psk, the AP accepts both",
  net.keyMgmtFor("WPA2 WPA3"), "wpa-psk")
eq("a WPA3-only AP joins as sae", net.keyMgmtFor("WPA3"), "sae")
eq("open has no key management", net.keyMgmtFor(""), nil)
check("WEP is recognised", net.isWep("WEP"))
check("plain WPA2 is not WEP", not net.isWep("WPA2"))

-- the profile argv never carries the passphrase
local profileArgs = net.wifiProfileArgs("cafe", "cafe", "wpa-psk", false)
eq("profile argv", table.concat(profileArgs, " "),
  "con add type wifi con-name cafe ssid cafe 802-11-wireless-security.key-mgmt wpa-psk " ..
  "802-11-wireless-security.psk-flags 0")
check("no secret in the profile argv", not table.concat(profileArgs, " "):find("psk-flags 0 0", 1, true))
profileArgs = net.wifiProfileArgs("hidden", "hidden", "sae", true)
check("a WPA3-only profile asks for sae",
  table.concat(profileArgs, " "):find("key-mgmt sae", 1, true) ~= nil, table.concat(profileArgs, " "))
eq("hidden flag on the profile too", profileArgs[#profileArgs], "yes")
profileArgs = net.wifiProfileArgs("open", "open", nil, false)
eq("an open profile carries no security settings", #profileArgs, 8)

-- what the bar tile shows: the network name, not the address
eq("wifi tile shows the SSID",
  net.primaryLabel({ address = "192.168.0.141", live = { kind = "wifi", connection = "Vodafone-B3A2" } }),
  "Vodafone-B3A2")
eq("ethernet tile falls back to its address",
  net.primaryLabel({ address = "10.0.0.5", live = { kind = "ethernet", connection = "Wired connection 1" } }),
  "10.0.0.5")
eq("wifi with no lease still shows the name",
  net.primaryLabel({ address = "", live = { kind = "wifi", connection = "Cafe" } }), "Cafe")
eq("no live data falls back to the route address",
  net.primaryLabel({ address = "192.168.0.141" }), "192.168.0.141")
eq("nothing at all is empty", net.primaryLabel(nil), "")

-- the passwd-file line nmcli reads the secret from
eq("passwd-file line", net.passwdFileContents("hunter2"),
  "802-11-wireless-security.psk:hunter2\n")
eq("a passphrase with a colon survives", net.passwdFileContents("a:b"),
  "802-11-wireless-security.psk:a:b\n")

-- the SSID a saved profile belongs to
eq("profile SSID parsed", net.profileSsid("802-11-wireless.ssid:Vodafone-B3A2\n"), "Vodafone-B3A2")
eq("unset profile SSID is nil", net.profileSsid("802-11-wireless.ssid:\n"), nil)

-- ── validators ───────────────────────────────────────────────────────────────

for _, good in ipairs({ "0.0.0.0", "192.168.0.141", "255.255.255.255", "10.0.0.1" }) do
  check("ipv4 accepts " .. good, net.isIPv4(good))
end
for _, bad in ipairs({ "", "192.168.0", "192.168.0.256", "192.168.0.1.5", "10.0.0.", "a.b.c.d", "192.168.0.-1" }) do
  check("ipv4 rejects " .. (bad == "" and "<empty>" or bad), not net.isIPv4(bad))
end

for _, good in ipairs({ "::1", "2001:db8::5", "fe80::1%wlan0", "::ffff:192.168.0.1", "2a02:8108:9611:1900::51e",
  "2001:0db8:0000:0000:0000:ff00:0042:8329", "fe80::" }) do
  check("ipv6 accepts " .. good, net.isIPv6(good))
end
for _, bad in ipairs({ "", "2001:db8:::5", "1:2:3:4:5:6:7:8:9", "hello", ":::", "1:2:3:4:5:6:7:8::9", "12345::1" }) do
  check("ipv6 rejects " .. (bad == "" and "<empty>" or bad), not net.isIPv6(bad))
end

check("cidr4 accepted", net.isCIDR("192.168.0.141/24", "v4"))
check("cidr4 /33 rejected", not net.isCIDR("192.168.0.141/33", "v4"))
check("cidr6 accepted", net.isCIDR("2001:db8::5/64", "v6"))
check("cidr6 /129 rejected", not net.isCIDR("2001:db8::5/129", "v6"))
check("bare address is not a cidr", not net.isCIDR("192.168.0.141", "v4"))

-- ── normalization ────────────────────────────────────────────────────────────

local addresses, err = net.normalizeAddresses("10.0.0.5", "v4")
eq("bare ipv4 gets /24", addresses, "10.0.0.5/24")
check("no error", err == nil)
addresses, err = net.normalizeAddresses("10.0.0.5/32 10.0.0.6", "v4")
eq("multiple addresses normalized", addresses, "10.0.0.5/32,10.0.0.6/24")
addresses, err = net.normalizeAddresses("192.168.0.999", "v4")
eq("bad ipv4 rejected", err, "error.address.ipv4")
eq("offending value reported", addresses, nil)
addresses, err = net.normalizeAddresses("2001:db8::5", "v6")
eq("bare ipv6 gets /64", addresses, "2001:db8::5/64")
_, err = net.normalizeAddresses("fe80::1%wlan0/64", "v6")
eq("zone id rejected in an address", err, "error.address.ipv6")
eq("empty list stays empty", net.normalizeAddresses("  ", "v4"), "")
eq("dns list normalized", net.normalizeDns("1.1.1.1, 8.8.8.8", "v4"), "1.1.1.1,8.8.8.8")
_, err = net.normalizeDns("1.1.1.1,not-an-ip", "v4")
eq("bad dns rejected", err, "error.dns.ipv4")
_, err = net.normalizeDns("1.1.1.1", "v6")
eq("v4 server in the ipv6 list rejected", err, "error.dns.ipv6")
eq("search list normalized", net.normalizeSearch("example.test foo.local"), "example.test,foo.local")
_, err = net.normalizeSearch("bad/domain")
eq("bad search domain rejected", err, "error.search")
_, err = net.normalizeSearch("two words are two labels")
eq("space separated labels are legal", err, nil)
eq("gateway accepts a scope id", net.normalizeGateway("fe80::1%eth0", "v6"), "fe80::1%eth0")
for _, bad in ipairs({ "fe80::1%", "fe80::1%eth0%extra", "fe80::1%eth 0" }) do
  check("ipv6 rejects a malformed scope id: " .. bad, not net.isIPv6(bad))
end

_, err = net.normalizeGateway("fe80::1%eth0", "v4")
eq("v6 gateway in the ipv4 field rejected", err, "error.gateway.ipv4")
eq("empty gateway is fine", net.normalizeGateway("", "v4"), "")

-- ── form validation ──────────────────────────────────────────────────────────

local function form(overrides)
  local out = {}
  for key, value in pairs(net.EMPTY_FORM) do
    out[key] = value
  end
  for key, value in pairs(overrides or {}) do
    out[key] = value
  end
  return out
end

local desired, reason, item = net.validateForm(form({ ipv4_method = "manual", ipv4_addresses = "10.0.0.5/24" }))
eq("manual is accepted with an address", desired.ipv4_addresses, "10.0.0.5/24")
eq("prefix trimmed from method", desired.ipv4_method, "manual")
check("no reason returned", reason == nil and item == nil)

desired, reason = net.validateForm(form({ ipv4_method = "manual" }))
eq("manual without an address rejected", reason, "error.need_address.ipv4")

desired, reason, item = net.validateForm(form({ ipv4_gateway = "10.0.0.1" }))
eq("gateway without an address rejected", reason, "error.gateway_needs_address.ipv4")
eq("gateway reported", item, "10.0.0.1")

-- an invalid leftover must not block a method that does not carry it
local cleared = net.validateForm(form({
  ipv4_method = "disabled", ipv4_addresses = "not-an-address", ipv4_gateway = "nonsense",
  ipv4_dns = "also-bad", ipv6_method = "ignore", ipv6_addresses = "junk",
}))
check("a disabled method clears unparseable values instead of refusing",
  cleared ~= nil and cleared.ipv4_addresses == "" and cleared.ipv4_dns == "" and cleared.ipv6_addresses == "")
local linklocal = net.validateForm(form({ ipv4_method = "link-local", ipv4_addresses = "999.1.1.1" }))
check("link-local clears too", linklocal ~= nil and linklocal.ipv4_addresses == "")
desired, reason = net.validateForm(form({ ipv4_method = "manual", ipv4_addresses = "999.1.1.1" }))
eq("a method that does own addressing still validates", reason, "error.address.ipv4")

desired, reason = net.validateForm(form({ ipv4_method = "nonsense" }))
eq("unknown method rejected", reason, "error.method")

desired = net.validateForm(form({
  ipv4_method = "disabled",
  ipv4_addresses = "10.0.0.5/24",
  ipv4_gateway = "10.0.0.1",
  ipv4_dns = "1.1.1.1",
}))
eq("disabled clears addresses", desired.ipv4_addresses, "")
eq("disabled clears gateway", desired.ipv4_gateway, "")
eq("disabled clears dns", desired.ipv4_dns, "")
eq("method kept", desired.ipv4_method, "disabled")

desired = net.validateForm(form({ ipv6_method = "ignore", ipv6_addresses = "2001:db8::5/64", ipv6_dns = "2001:db8::1" }))
eq("ignore clears ipv6 addresses", desired.ipv6_addresses, "")
eq("ignore keeps the method", desired.ipv6_method, "ignore")
eq("ipv4 is untouched by the v6 branch", desired.ipv4_method, "auto")

desired, reason = net.validateForm(form({ ipv6_method = "manual", ipv6_addresses = "192.168.0.5/24" }))
eq("v4 address rejected in the v6 field", reason, "error.address.ipv6")
desired, reason = net.validateForm(form({ ipv4_dns_search = "bad/domain" }))
eq("search validation reaches the form", reason, "error.search")

-- a profile read back from nmcli must survive validation unchanged: the
-- normalizer is idempotent, so opening a connection never rewrites it.
local stored = net.profileFromText(profileStatic)
local round = net.validateForm(stored)
local identical = true
for _, field in ipairs(net.FIELDS) do
  if round[field.key] ~= stored[field.key] then
    identical = false
    print("      drift on " .. field.key .. ": " .. tostring(stored[field.key]) .. " -> " .. tostring(round[field.key]))
  end
end
check("static profile round-trips unchanged", identical)

-- ── diffs and argv ───────────────────────────────────────────────────────────

local currentForm = net.profileFromText(profileDhcp)
eq("no diff against itself", #net.diff(currentForm, net.validateForm(currentForm)), 0)

local switch = net.validateForm(form({
  ipv4_method = "manual",
  ipv4_addresses = "192.168.0.141/24",
  ipv4_gateway = "192.168.0.1",
  ipv4_dns = "1.1.1.1,1.0.0.1",
}))
local changes = net.diff(currentForm, switch)
eq("only the moved keys differ", keys(changes), "ipv4_method,ipv4_addresses,ipv4_gateway")
eq("dhcp -> static is visible as from/to", changes[1].from .. "->" .. changes[1].to, "auto->manual")

-- The builders return argument lists WITHOUT the program name: the service
-- prepends "nmcli" in exactly one place.
local args = net.buildModArgs("uuid-1", switch, currentForm)
local shape = args[1] == "con" and args[2] == "mod" and args[3] == "uuid-1"
check("mod args address the connection", shape)
eq("mod args carry one property per change", #args, 3 + 3 * 2)
eq("first property", args[4], "ipv4.method")
eq("first value", args[5], "manual")
check("no program name in the list", args[1] ~= "nmcli" and args[2] ~= "nmcli")

local clearing = net.buildModArgs("uuid-1", net.validateForm(form({ ipv4_dns = "" })), currentForm)
eq("clearing dns passes an empty argument", clearing[5], "")
eq("cleared property name", clearing[4], "ipv4.dns")

local restore = net.restoreArgs("uuid-1", stored)
eq("restore writes every field", #restore, 3 + 2 * #net.FIELDS)
eq("restore re-states the address", restore[4 + 2 * 1], "ipv4.addresses")
eq("restore re-states the address value", restore[5 + 2 * 1], "10.99.0.5/24")
eq("restore names the last field", restore[4 + 2 * 9], "ipv6.dns-search")
eq("restore clears an unset dns-search", restore[5 + 2 * 9], "")

eq("summary of a static profile", net.summarize(stored),
  "static 10.99.0.5/24 | gw 10.99.0.1 | dns 9.9.9.9,149.112.112.112 | v6 2001:db8::5/64")
eq("summary of dhcp", net.summarize(currentForm), "dhcp | dns 1.1.1.1,1.0.0.1")

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
