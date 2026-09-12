--!nonstrict
-- Pure parsing and validation for Network Control.
--
-- Nothing here touches the plugin host: no noctalia.* globals, no subprocesses.
-- That keeps every rule (nmcli output shapes, address validation, the form
-- normalizer, the argv builder) testable with stock Lua - see tests/run.lua.
--
-- The panel's form and the nmcli property names are deliberately kept apart:
-- the form speaks `ipv4_addresses`, nmcli speaks `ipv4.addresses`. M.FIELDS is
-- the only place that mapping exists, and both directions go through it.

local M = {}

-- form key -> nmcli property, in the order nmcli sees them.
M.FIELDS = {
  { key = "ipv4_method", prop = "ipv4.method" },
  { key = "ipv4_addresses", prop = "ipv4.addresses" },
  { key = "ipv4_gateway", prop = "ipv4.gateway" },
  { key = "ipv4_dns", prop = "ipv4.dns" },
  { key = "ipv4_dns_search", prop = "ipv4.dns-search" },
  { key = "ipv6_method", prop = "ipv6.method" },
  { key = "ipv6_addresses", prop = "ipv6.addresses" },
  { key = "ipv6_gateway", prop = "ipv6.gateway" },
  { key = "ipv6_dns", prop = "ipv6.dns" },
  { key = "ipv6_dns_search", prop = "ipv6.dns-search" },
}

-- Values NetworkManager accepts for ipv4.method / ipv6.method, minus "shared"
-- (that needs a DHCP/DNS helper on the box and is not an addressing mode).
M.V4_METHODS = { "auto", "manual", "link-local", "disabled" }
M.V6_METHODS = { "auto", "manual", "link-local", "ignore", "disabled" }

-- Methods that own no addressing at all: NetworkManager refuses addresses,
-- gateway and DNS alongside them ("this property is not allowed for
-- 'method=disabled'"), so the normalizer clears those fields instead of letting
-- the write fail.
M.ADDRESSLESS_METHODS = { disabled = true, ["link-local"] = true, ignore = true }

M.EMPTY_FORM = {
  ipv4_method = "auto",
  ipv4_addresses = "",
  ipv4_gateway = "",
  ipv4_dns = "",
  ipv4_dns_search = "",
  ipv6_method = "auto",
  ipv6_addresses = "",
  ipv6_gateway = "",
  ipv6_dns = "",
  ipv6_dns_search = "",
}

-- The `-f` argument is built from the same list used to parse the reply, so the
-- two can never drift apart.
M.INVENTORY_ORDER = { "NAME", "UUID", "TYPE", "DEVICE", "STATE", "ACTIVE" }
M.STATUS_ORDER = { "DEVICE", "TYPE", "STATE", "CONNECTION" }
M.INVENTORY_FIELDS = table.concat(M.INVENTORY_ORDER, ",")
M.STATUS_FIELDS = table.concat(M.STATUS_ORDER, ",")

-- NetworkManager type -> the short kind the UI switches glyphs on. `dev show`
-- reports the short form already; `con show` reports the D-Bus type name.
M.KINDS = {
  ["802-11-wireless"] = "wifi",
  ["802-11-olpc-mesh"] = "mesh",
  ["802-3-ethernet"] = "ethernet",
  ["802-11-wireless-security"] = "wifi",
  ["wireguard"] = "vpn",
  ["vpn"] = "vpn",
  ["tun"] = "tunnel",
  ["tap"] = "tunnel",
  ["bridge"] = "bridge",
  ["bond"] = "bond",
  ["team"] = "bond",
  ["vlan"] = "vlan",
  ["dummy"] = "dummy",
  ["loopback"] = "loopback",
  ["bluetooth"] = "bluetooth",
  ["gsm"] = "wwan",
  ["cdma"] = "wwan",
}

function M.kindFromNmType(nmType)
  return M.KINDS[nmType] or nmType or ""
end
M.PROFILE_FIELDS = "ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.dns-search,"
  .. "ipv6.method,ipv6.addresses,ipv6.gateway,ipv6.dns,ipv6.dns-search"
M.DEVICE_FIELDS = "GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.CONNECTION,"
  .. "IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS,IP6.GATEWAY,IP6.DNS"

function M.trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return string.match(s, "^%s*(.-)%s*$")
end

-- ── nmcli output ─────────────────────────────────────────────────────────────
--
-- Everything is read in terse mode (`nmcli -t`): one object per line for a list
-- (`con show`), one `KEY:value` per line for a single object (`con show <id>`,
-- `dev show <dev>`). Multiline mode does NOT separate objects with a blank line
-- on this NM build, so it cannot be parsed back into objects at all.
--
-- In terse mode a literal ':' inside a value arrives escaped as '\:' and a
-- backslash as '\\', so the split has to walk the line rather than match a
-- pattern. Repeated values keep their index: `IP4.ADDRESS[1]`, `[2]`, ... A
-- value that is unset prints empty.

-- All fields of one terse line, split at unescaped colons. Walking the line is
-- the only way: a literal ':' inside a value arrives as '\:' and a backslash as
-- '\\', so a pattern would split in the wrong place.
function M.splitTerseValues(line)
  local values, chars = {}, {}
  local index, length = 1, #line
  while index <= length do
    local char = string.sub(line, index, index)
    if char == "\\" and index < length then
      table.insert(chars, string.sub(line, index + 1, index + 1))
      index = index + 2
    elseif char == ":" then
      table.insert(values, table.concat(chars))
      chars = {}
      index = index + 1
    else
      table.insert(chars, char)
      index = index + 1
    end
  end
  table.insert(values, table.concat(chars))
  return values
end

-- The single-object shapes (`con show <id>`, `dev show <dev>`) print one
-- `KEY:value` per line, and the key never contains a colon. Everything after the
-- first one is the value: in this mode nmcli does NOT escape colons inside
-- values, so `ipv6.addresses:2001:db8::5/64` has to survive the split intact.
function M.splitTerseLine(line)
  local values = M.splitTerseValues(line)
  if #values < 2 then
    return values[1] or "", nil
  end
  return values[1], table.concat(values, ":", 2)
end

-- One object, as a key -> value map (indexes intact).
function M.parseFields(text)
  local fields = {}
  if type(text) ~= "string" then
    return fields
  end
  for line in string.gmatch(text, "[^\n]+") do
    local key, value = M.splitTerseLine(line)
    if value ~= nil then
      fields[key] = value
    end
  end
  return fields
end

-- A list shape: one object per line, its values positional. `order` is the same
-- list used to build the `-f` argument, which is why it lives next to it.
function M.parseRows(text, order)
  local rows = {}
  if type(text) ~= "string" or type(order) ~= "table" then
    return rows
  end
  for line in string.gmatch(text, "[^\n]+") do
    local values = M.splitTerseValues(line)
    local row = {}
    for index, name in ipairs(order) do
      row[name] = values[index] or ""
    end
    table.insert(rows, row)
  end
  return rows
end

-- A single value from a parsed object, or nil when absent or empty.
function M.get(fields, key)
  if type(fields) ~= "table" then
    return nil
  end
  local value = fields[key]
  if value == nil or value == "" or value == "--" then
    return nil
  end
  return value
end

-- Every `key[1]`, `key[2]`, ... in order.
function M.list(fields, key)
  local out = {}
  if type(fields) ~= "table" then
    return out
  end
  local index = 1
  while true do
    local value = fields[key .. "[" .. index .. "]"]
    if value == nil then
      break
    end
    if value ~= "" and value ~= "--" then
      table.insert(out, value)
    end
    index = index + 1
  end
  return out
end

-- `nmcli -t -f M.INVENTORY_FIELDS con show` -> connection list.
function M.connectionsFromText(text)
  local out = {}
  for _, row in ipairs(M.parseRows(text, M.INVENTORY_ORDER)) do
    local uuid = M.get(row, "UUID")
    if uuid ~= nil then
      local kind = M.get(row, "TYPE") or ""
      table.insert(out, {
        name = M.get(row, "NAME") or uuid,
        uuid = uuid,
        kind = M.kindFromNmType(kind),
        device = M.get(row, "DEVICE") or "",
        state = M.get(row, "STATE") or "",
        active = M.get(row, "ACTIVE") == "yes",
        -- A loopback profile has no addressing to speak of.
        editable = kind ~= "loopback",
      })
    end
  end
  return M.sortConnections(out)
end

function M.sortConnections(list)
  table.sort(list, function(a, b)
    if a.active ~= b.active then
      return a.active
    end
    return string.lower(a.name) < string.lower(b.name)
  end)
  return list
end

-- `nmcli -t -f M.PROFILE_FIELDS con show <id>` -> the form shape. Comma-joined
-- strings here: this is the stored configuration, not what is live.
function M.profileFromText(text)
  local fields = M.parseFields(text)
  local form = {}
  for _, field in ipairs(M.FIELDS) do
    form[field.key] = M.get(fields, field.prop) or ""
  end
  return form
end

-- `nmcli -t -f M.DEVICE_FIELDS dev show <dev>` -> runtime state. Addresses and
-- DNS arrive indexed and stay lists, because the panel has to show what the
-- interface actually holds.
function M.liveFromText(text)
  local fields = M.parseFields(text)
  if next(fields) == nil then
    return nil
  end
  return {
    device = M.get(fields, "GENERAL.DEVICE") or "",
    kind = M.get(fields, "GENERAL.TYPE") or "",
    state = M.get(fields, "GENERAL.STATE") or "",
    connection = M.get(fields, "GENERAL.CONNECTION") or "",
    ipv4_addresses = M.list(fields, "IP4.ADDRESS"),
    ipv4_gateway = M.get(fields, "IP4.GATEWAY") or "",
    ipv4_dns = M.list(fields, "IP4.DNS"),
    ipv6_addresses = M.list(fields, "IP6.ADDRESS"),
    ipv6_gateway = M.get(fields, "IP6.GATEWAY") or "",
    ipv6_dns = M.list(fields, "IP6.DNS"),
  }
end

-- `nmcli -t -f M.STATUS_ORDER dev status` -> [{ device, kind, state, connection }]
function M.deviceStatusFromText(text)
  local out = {}
  for _, row in ipairs(M.parseRows(text, M.STATUS_ORDER)) do
    local device = M.get(row, "DEVICE")
    if device ~= nil then
      table.insert(out, {
        device = device,
        kind = M.get(row, "TYPE") or "",
        state = M.get(row, "STATE") or "",
        connection = M.get(row, "CONNECTION") or "",
      })
    end
  end
  return out
end

-- ── Wi-Fi scan ───────────────────────────────────────────────────────────────

M.WIFI_ORDER = { "IN-USE", "SSID", "SIGNAL", "SECURITY" }
M.WIFI_FIELDS = table.concat(M.WIFI_ORDER, ",")

-- `nmcli -t -f M.WIFI_FIELDS dev wifi list` -> one entry per SSID, strongest
-- first. nmcli prints one row per BSSID, so a repeater or a mesh shows up
-- several times; a person picks a network, not an access point.
--
-- Two shapes to survive: IN-USE is the one padded column ("*" or " "), and a
-- hidden network prints an empty SSID, which is nothing selectable - that is
-- what the manual SSID field is for.
function M.networksFromText(text)
  local bySsid, list = {}, {}
  for _, row in ipairs(M.parseRows(text, M.WIFI_ORDER)) do
    local ssid = row["SSID"]
    local signal = tonumber(row["SIGNAL"]) or 0
    if ssid ~= nil and ssid ~= "" then
      local entry = bySsid[ssid]
      if entry == nil then
        entry = { ssid = ssid, signal = signal, security = row["SECURITY"] or "", in_use = false, aps = 0 }
        bySsid[ssid] = entry
        table.insert(list, entry)
      end
      entry.aps = entry.aps + 1
      if signal > entry.signal then
        entry.signal = signal
      end
      if M.trim(row["IN-USE"]) == "*" then
        entry.in_use = true
      end
      if entry.security == "" and row["SECURITY"] ~= "" then
        entry.security = row["SECURITY"]
      end
    end
  end
  table.sort(list, function(a, b)
    if a.in_use ~= b.in_use then
      return a.in_use
    end
    if a.signal ~= b.signal then
      return a.signal > b.signal
    end
    return string.lower(a.ssid) < string.lower(b.ssid)
  end)
  return list
end

-- 0..100 -> 1..5, the range the antenna-bars glyphs come in.
function M.signalBars(signal)
  local value = tonumber(signal) or 0
  if value >= 80 then
    return 5
  end
  if value >= 60 then
    return 4
  end
  if value >= 40 then
    return 3
  end
  if value >= 20 then
    return 2
  end
  return 1
end

M.OPEN_SECURITY = { [""] = true, ["--"] = true }

function M.isOpenNetwork(security)
  return M.OPEN_SECURITY[M.trim(security)] == true
end

-- WPA-Enterprise needs an identity, and often a CA certificate and a phase-2
-- method, which this plugin does not collect yet. It says so instead of failing
-- halfway through a connect.
function M.isEnterprise(security)
  local text = string.lower(M.trim(security))
  return string.find(text, "802.1x", 1, true) ~= nil or string.find(text, "eap", 1, true) ~= nil
end

function M.needsPassword(security)
  return not M.isOpenNetwork(security)
end

function M.isWep(security)
  return string.find(M.trim(security), "WEP", 1, true) ~= nil
end

-- key-mgmt for the profile this plugin creates for a secured network.
-- WPA2/WPA3 transition mode is joined as WPA2 (`wpa-psk`) on purpose: the AP
-- offers both, and only a WPA3-only AP needs SAE. nil when the security string
-- says nothing useful (an open network, or a stale/hidden scan row).
function M.keyMgmtFor(security)
  local text = string.upper(M.trim(security))
  local wpa3 = string.find(text, "WPA3", 1, true) ~= nil
  local wpa12 = string.find(text, "WPA1", 1, true) ~= nil or string.find(text, "WPA2", 1, true) ~= nil
  if wpa3 and not wpa12 then
    return "sae"
  end
  if wpa12 then
    return "wpa-psk"
  end
  return nil
end

-- `nmcli dev wifi connect`, used for OPEN networks only. NetworkManager creates
-- the profile itself and there is no secret to place anywhere, which is the whole
-- reason this path stays this simple: anything with a passphrase goes through
-- M.wifiProfileArgs + `con up --passwd-file` instead.
function M.wifiConnectArgs(ssid, hidden)
  local args = { "dev", "wifi", "connect", ssid }
  if hidden == true then
    table.insert(args, "hidden")
    table.insert(args, "yes")
  end
  return args
end

-- `nmcli con add` for a secured Wi-Fi profile. The passphrase is deliberately
-- NOT part of this argument list: it arrives afterwards through `passwd-file`,
-- which keeps it out of the process command line (world-readable in /proc) and
-- out of every plugin file. keyMgmt nil builds an open profile.
function M.wifiProfileArgs(name, ssid, keyMgmt, hidden)
  local args = { "con", "add", "type", "wifi", "con-name", name, "ssid", ssid }
  if keyMgmt ~= nil then
    table.insert(args, "802-11-wireless-security.key-mgmt")
    table.insert(args, keyMgmt)
    -- 0 = store the secret in the profile once activation succeeds, which is
    -- exactly where nmcli's own `password` argument would have ended up.
    table.insert(args, "802-11-wireless-security.psk-flags")
    table.insert(args, "0")
  end
  if hidden == true then
    table.insert(args, "802-11-wireless.hidden")
    table.insert(args, "yes")
  end
  return args
end

-- What the bar tile calls the network it is on: the SSID, which for a Wi-Fi
-- profile is the profile name. The address belongs in the tooltip, not the bar.
-- Anything that is not Wi-Fi (Ethernet, a dummy link) has no name worth showing,
-- so it falls back to its address.
function M.primaryLabel(primary)
  if type(primary) ~= "table" then
    return ""
  end
  local live = primary.live
  if type(live) == "table" and live.kind == "wifi" and (live.connection or "") ~= "" then
    return live.connection
  end
  if (primary.address or "") ~= "" then
    return primary.address
  end
  if type(live) == "table" then
    return live.connection or ""
  end
  return ""
end

-- nmcli's passwd-file format: one `setting.property:secret` per line.
function M.passwdFileContents(password)
  return "802-11-wireless-security.psk:" .. password .. "\n"
end

-- `nmcli -t -f 802-11-wireless.ssid con show <uuid>` -> the SSID a saved profile
-- is for, so a scan entry can be marked as already known.
function M.profileSsid(text)
  return M.get(M.parseFields(text), "802-11-wireless.ssid")
end

-- `nmcli -t general permissions` -> { ["org.freedesktop..."] = "yes" }
function M.permissionsFromText(text)
  local out = {}
  if type(text) ~= "string" then
    return out
  end
  for line in string.gmatch(text, "[^\n]+") do
    local key, value = string.match(line, "^(.-):(.*)$")
    if key ~= nil then
      out[M.trim(key)] = M.trim(value)
    end
  end
  return out
end

-- `nmcli radio` -> { wifi = "enabled", wwan = "missing", wifi-hw = ... }.
-- nmcli space-aligns the values under their headers, so both lines are tokenized
-- the same way and zipped.
function M.radioFromText(text)
  local out = {}
  if type(text) ~= "string" then
    return out
  end
  local lines = {}
  for line in string.gmatch(text, "[^\n]+") do
    table.insert(lines, line)
  end
  if #lines < 2 then
    return out
  end
  local function tokens(line)
    local list = {}
    for token in string.gmatch(line .. " ", "(%S+)%s+") do
      table.insert(list, token)
    end
    return list
  end
  local header, values = tokens(lines[1]), tokens(lines[2])
  for index, column in ipairs(header) do
    out[string.lower(column)] = values[index] or "unknown"
  end
  return out
end

-- `ip -j route get <ip>` -> the interface the kernel would actually use, with
-- the source address it would pick. This is the honest answer when several
-- default routes exist with different metrics (a stray static route on a dummy
-- link outranks Wi-Fi). Falls back to nil when there is no route at all.
function M.primaryFromRouteJson(text, decode)
  if type(text) ~= "string" or type(decode) ~= "function" then
    return nil
  end
  local decoded = decode(text)
  local route = type(decoded) == "table" and (decoded.dev ~= nil and decoded or decoded[1]) or nil
  if type(route) ~= "table" or type(route.dev) ~= "string" or route.dev == "" then
    return nil
  end
  return { device = route.dev, gateway = route.gateway or "", address = route.prefsrc or "" }
end

-- ── validation ───────────────────────────────────────────────────────────────

local function isOctet(s)
  if type(s) ~= "string" or s == "" or #s > 3 or not string.match(s, "^%d+$") then
    return false
  end
  local n = tonumber(s)
  return n >= 0 and n <= 255
end

function M.isIPv4(s)
  if type(s) ~= "string" or s == "" then
    return false
  end
  local parts = {}
  for part in (s .. "."):gmatch("([^%.]*)%.") do
    table.insert(parts, part)
  end
  if #parts ~= 4 then
    return false
  end
  for _, part in ipairs(parts) do
    if not isOctet(part) then
      return false
    end
  end
  return true
end

-- Permissive enough for the forms a human types (`::1`, `fe80::1%wlan0`,
-- `::ffff:192.168.0.1`), strict enough to reject what nmcli would refuse.
function M.isIPv6(s)
  if type(s) ~= "string" or s == "" then
    return false
  end
  local body = s
  local zone = string.find(body, "%", 1, true)
  if zone ~= nil then
    -- A scope id is one non-empty interface name after a single '%':
    -- "fe80::1%" and "fe80::1%eth0%extra" are not addresses.
    local scope = string.sub(body, zone + 1)
    if zone == 1 or scope == "" or string.find(scope, "%", 1, true) ~= nil
      or string.match(scope, "^[%w_%-%.]+$") == nil then
      return false
    end
    body = string.sub(body, 1, zone - 1)
  end
  if string.find(body, "%.") then
    -- Embedded IPv4 tail: rewrite the last two groups as hex and validate.
    local head, v4 = string.match(body, "^(.*):([%d%.]+)$")
    if head == nil or not M.isIPv4(v4) then
      return false
    end
    body = head .. ":0:0"
  end
  if body == "" or string.find(body, "[^%x:]") then
    return false
  end
  local _, doubled = string.gsub(body, "::", "::")
  if doubled > 1 then
    return false
  end
  local head, tail = body, ""
  if doubled == 1 then
    local left, right = string.match(body, "^(.-)::(.*)$")
    if left == nil then
      return false
    end
    head, tail = left, right
  end
  local function groups(part)
    if part == "" then
      return 0
    end
    local count = 0
    for group in (part .. ":"):gmatch("([^:]*):") do
      count = count + 1
      if group == "" or #group > 4 then
        return nil
      end
    end
    return count
  end
  local headCount, tailCount = groups(head), groups(tail)
  if headCount == nil or tailCount == nil then
    return false
  end
  local total = headCount + tailCount
  if doubled == 1 then
    -- "::" stands for at least one zero group.
    return total <= 7
  end
  return total == 8
end

function M.isCIDR(s, family)
  local ip, prefix = string.match(tostring(s), "^([^/]+)/(%d+)$")
  if ip == nil then
    return false
  end
  local max = family == "v6" and 128 or 32
  if tonumber(prefix) > max then
    return false
  end
  if family == "v6" then
    return M.isIPv6(ip)
  end
  return M.isIPv4(ip)
end

-- Comma or space separated, empties dropped.
function M.splitList(s)
  local out = {}
  if type(s) ~= "string" then
    return out
  end
  for item in string.gmatch(s, "[^,%s]+") do
    table.insert(out, item)
  end
  return out
end

local function familyName(family)
  return family == "v6" and "ipv6" or "ipv4"
end

-- "192.168.1.50" -> "192.168.1.50/24": a bare address silently becomes /32 in
-- NetworkManager, which is almost never what someone typing it wants.
function M.normalizeAddresses(text, family)
  local items = M.splitList(text)
  if #items == 0 then
    return ""
  end
  local out = {}
  for _, item in ipairs(items) do
    -- A zone id ("fe80::1%wlan0") belongs on a gateway, not in a stored
    -- address, where the prefix has to be last.
    if string.find(item, "%", 1, true) ~= nil then
      return nil, "error.address." .. familyName(family), item
    elseif M.isCIDR(item, family) then
      table.insert(out, item)
    elseif family == "v6" and M.isIPv6(item) then
      table.insert(out, item .. "/64")
    elseif family == "v4" and M.isIPv4(item) then
      table.insert(out, item .. "/24")
    else
      return nil, "error.address." .. familyName(family), item
    end
  end
  return table.concat(out, ",")
end

function M.normalizeDns(text, family)
  local items = M.splitList(text)
  if #items == 0 then
    return ""
  end
  local out = {}
  for _, item in ipairs(items) do
    -- Written out rather than as `family == "v6" and isIPv6 or isIPv4`: an
    -- and/or chain silently falls through to the other family's check.
    local ok
    if family == "v6" then
      ok = M.isIPv6(item)
    else
      ok = M.isIPv4(item)
    end
    if not ok then
      return nil, "error.dns." .. familyName(family), item
    end
    table.insert(out, item)
  end
  return table.concat(out, ",")
end

function M.normalizeSearch(text)
  local items = M.splitList(text)
  if #items == 0 then
    return ""
  end
  local out = {}
  for _, item in ipairs(items) do
    if not string.match(item, "^[%w_%-%.]+$") then
      return nil, "error.search", item
    end
    table.insert(out, item)
  end
  return table.concat(out, ",")
end

function M.normalizeGateway(text, family)
  local value = M.trim(text)
  if value == "" then
    return ""
  end
  local ok
  if family == "v6" then
    ok = M.isIPv6(value)
  else
    ok = M.isIPv4(value)
  end
  if not ok then
    return nil, "error.gateway." .. familyName(family), value
  end
  return value
end

-- The panel's draft -> the ten canonical strings, or the first reason it is not
-- applicable as (nil, translation key, offending text).
function M.validateForm(form)
  if type(form) ~= "table" then
    return nil, "error.form", nil
  end
  local desired = {}
  for _, field in ipairs(M.FIELDS) do
    desired[field.key] = M.trim(form[field.key]) or ""
  end

  for _, family in ipairs({ "v4", "v6" }) do
    local prefix = family == "v4" and "ipv4" or "ipv6"
    local methods = family == "v4" and M.V4_METHODS or M.V6_METHODS
    local known = false
    for _, method in ipairs(methods) do
      if desired[prefix .. "_method"] == method then
        known = true
      end
    end
    if not known then
      return nil, "error.method", desired[prefix .. "_method"]
    end

    if M.ADDRESSLESS_METHODS[desired[prefix .. "_method"]] then
      -- These methods own no addressing at all: NetworkManager rejects addresses,
      -- gateway and DNS alongside them. Clearing happens *before* validation, so a
      -- value the user typed earlier and never fixed cannot block a write that
      -- does not carry it.
      desired[prefix .. "_addresses"] = ""
      desired[prefix .. "_gateway"] = ""
      desired[prefix .. "_dns"] = ""
      desired[prefix .. "_dns_search"] = ""
    else
      local addresses, addressErr, addressItem = M.normalizeAddresses(desired[prefix .. "_addresses"], family)
      if addressErr ~= nil then
        return nil, addressErr, addressItem
      end
      -- Manual without an address is the one combination NM refuses to activate;
      -- catching it here means the profile is never written into that state.
      if desired[prefix .. "_method"] == "manual" and addresses == "" then
        return nil, "error.need_address." .. familyName(family), nil
      end

      local gateway, gatewayErr, gatewayItem = M.normalizeGateway(desired[prefix .. "_gateway"], family)
      if gatewayErr ~= nil then
        return nil, gatewayErr, gatewayItem
      end

      local dns, dnsErr, dnsItem = M.normalizeDns(desired[prefix .. "_dns"], family)
      if dnsErr ~= nil then
        return nil, dnsErr, dnsItem
      end

      local search, searchErr, searchItem = M.normalizeSearch(desired[prefix .. "_dns_search"])
      if searchErr ~= nil then
        return nil, searchErr, searchItem
      end

      if gateway ~= "" and addresses == "" then
        -- nmcli: "gateway cannot be set if there are no addresses configured".
        return nil, "error.gateway_needs_address." .. familyName(family), gateway
      end

      desired[prefix .. "_addresses"] = addresses
      desired[prefix .. "_gateway"] = gateway
      desired[prefix .. "_dns"] = dns
      desired[prefix .. "_dns_search"] = search
    end
  end

  return desired
end

-- ── diffs and argv ───────────────────────────────────────────────────────────

-- Only the keys whose normalized value actually moves.
function M.diff(current, desired)
  local out = {}
  if type(desired) ~= "table" then
    return out
  end
  for _, field in ipairs(M.FIELDS) do
    local from = current ~= nil and M.trim(current[field.key]) or ""
    local to = M.trim(desired[field.key]) or ""
    if from ~= to then
      table.insert(out, { key = field.key, prop = field.prop, from = from, to = to })
    end
  end
  return out
end

-- Arguments for `nmcli con mod`, carrying only what changed. An empty value is a
-- real argument and clears the property - that is nmcli's documented way of
-- unsetting a list field.
--
-- The program name is deliberately NOT included: the caller prepends it in one
-- place. A builder that returned a full argv next to callers that prepend
-- "nmcli" would ask nmcli to run a program called nmcli.
function M.buildModArgs(uuid, desired, current)
  local args = { "con", "mod", uuid }
  for _, change in ipairs(M.diff(current, desired)) do
    table.insert(args, change.prop)
    table.insert(args, change.to)
  end
  return args
end

-- Full restore of a saved profile: every field written, empty ones cleared, so a
-- rollback cannot leave a half-configured connection behind. Like buildModArgs,
-- an argument list without the program name.
function M.restoreArgs(uuid, fields)
  local args = { "con", "mod", uuid }
  for _, field in ipairs(M.FIELDS) do
    table.insert(args, field.prop)
    table.insert(args, M.trim(fields ~= nil and fields[field.key] or "") or "")
  end
  return args
end

-- A one-line description of the addressing, for tooltips and notifications.
function M.summarize(fields)
  if type(fields) ~= "table" then
    return ""
  end
  local parts = {}
  local method = fields.ipv4_method or "auto"
  if method == "manual" then
    table.insert(parts, "static " .. (fields.ipv4_addresses ~= "" and fields.ipv4_addresses or "?"))
    if fields.ipv4_gateway ~= "" then
      table.insert(parts, "gw " .. fields.ipv4_gateway)
    end
  else
    table.insert(parts, method == "auto" and "dhcp" or method)
  end
  if fields.ipv4_dns ~= "" then
    table.insert(parts, "dns " .. fields.ipv4_dns)
  end
  if fields.ipv6_method == "manual" and fields.ipv6_addresses ~= "" then
    table.insert(parts, "v6 " .. fields.ipv6_addresses)
  end
  return table.concat(parts, " | ")
end

return M
