--!nonstrict
-- Pure parsing of `mullvad status --json`, `get` command text and command results.

local parse = {}

local STATES = {
  disconnected = true,
  connecting = true,
  connected = true,
  disconnecting = true,
  error = true,
}

-- "se-got-wg-004" -> "se"
local function codeFromHostname(hostname)
  if type(hostname) ~= "string" then
    return nil
  end
  local code = hostname:match("^(%a%a)%-")
  if code then
    return code:lower()
  end
  return nil
end

local function stringOrNil(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

function parse.status(decoded)
  if type(decoded) ~= "table" or not STATES[decoded.state] then
    return nil
  end
  local details = type(decoded.details) == "table" and decoded.details or {}
  local location = type(details.location) == "table" and details.location or {}

  local tunnel = {
    state = decoded.state,
    lockedDown = details.locked_down == true,
    country = stringOrNil(location.country),
    city = stringOrNil(location.city),
    countryCode = codeFromHostname(location.hostname),
    ipv4 = stringOrNil(location.ipv4),
    latitude = type(location.latitude) == "number" and location.latitude or nil,
    longitude = type(location.longitude) == "number" and location.longitude or nil,
    mullvadExit = location.mullvad_exit_ip == true,
    hostname = stringOrNil(location.hostname),
    entryCountry = stringOrNil(location.entry_country),
    entryCountryCode = codeFromHostname(location.entry_hostname),
  }

  if decoded.state == "error" and type(details.cause) == "table" then
    local cause = details.cause
    tunnel.errorReason = stringOrNil(cause.reason)
    local detail = cause.details
    if type(detail) == "table" then
      detail = detail.reason
    end
    tunnel.errorDetail = stringOrNil(detail)
  end

  return tunnel
end

-- ── settings (`mullvad <thing> get` text) ───────────────────────────────────

local ON_OFF = {
  on = true, off = false,
  ["true"] = true, ["false"] = false,
  allow = true, block = false,
  enabled = true, disabled = false,
}

-- The on/off value after the last ':' ("Autoconnect: off" -> false), or nil.
function parse.onOff(text)
  if type(text) ~= "string" then
    return nil
  end
  local value = text:match(":([^:]*)$")
  if value == nil then
    return nil
  end
  return ON_OFF[value:match("^%s*(.-)%s*$"):lower()]
end

-- A location constraint as `relay get` prints it (mullvad 2026.5; mullvad-types
-- LocationConstraintFormatter):
--   any | country se | city got, se | city got, se, hostname se-got-wg-001
--   | <custom list name>   (bare name; "invalid custom list" for a dangling id)
-- A bare name is a custom list only when it is one of `listNames`; any other text
-- is { kind = "unknown", raw = text }, so nothing reads a guess as a setting.
local function location(value, listNames)
  if value == "any" then
    return { kind = "any" }
  end
  local country = value:match("^country (%S+)$")
  if country then
    return { kind = "country", country = country }
  end
  local city, cc, hostname = value:match("^city ([^,]+), ([^,]+), hostname (%S+)$")
  if city then
    return { kind = "hostname", country = cc, city = city, hostname = hostname }
  end
  city, cc = value:match("^city ([^,]+), ([^,]+)$")
  if city then
    return { kind = "city", country = cc, city = city }
  end
  for _, name in ipairs(listNames or {}) do
    if name == value then
      return { kind = "custom_list", list = value }
    end
  end
  return { kind = "unknown", raw = value }
end

-- `mullvad custom-list list` -> { name }: each list name on its own line, its
-- locations below it indented with a tab (mullvad-cli custom_list.rs).
function parse.customListNames(text)
  if type(text) ~= "string" then
    return nil
  end
  local names = {}
  for line in text:gmatch("[^\n]+") do
    if not line:match("^%s") then
      local name = line:match("^(.-)%s*$")
      if name ~= "" then
        names[#names + 1] = name
      end
    end
  end
  return names
end

local function providers(value)
  if value == "any" then
    return "any"
  end
  local list = {}
  for name in (value:gsub("^provider%(s%)%s*", "")):gmatch("[^,]+") do
    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      list[#list + 1] = trimmed
    end
  end
  return list
end

local function ownership(value)
  local lower = value:lower()
  if lower:find("owned", 1, true) then
    return "owned"
  end
  if lower:find("rented", 1, true) then
    return "rented"
  end
  return "any"
end

local IP_VERSIONS = { ipv4 = "v4", ipv6 = "v6" }

-- `mullvad relay get` -> RelayConstraints, or nil when there is no Location line.
-- listNames: the custom list names (parse.customListNames), to recognise a
-- custom-list constraint; without them a bare name reads as unknown.
function parse.relayConstraints(text, listNames)
  if type(text) ~= "string" then
    return nil
  end
  local fields = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^%s*([^:]-)%s*:%s*(.-)%s*$")
    if key ~= nil then
      fields[key] = value
    end
  end
  if fields["Location"] == nil then
    return nil
  end
  return {
    location = location(fields["Location"], listNames),
    providers = providers(fields["Provider(s)"] or "any"),
    ownership = ownership(fields["Ownership"] or "any"),
    ipVersion = IP_VERSIONS[(fields["IP protocol"] or ""):lower()] or "any",
    multihop = parse.onOff(":" .. (fields["Multihop state"] or "")) == true,
    entry = location(fields["Multihop entry"] or "", listNames),
  }
end

-- ── account (`mullvad account …`, mullvad-cli 2026.5 cmds/account.rs) ─────────

local NOT_LOGGED_IN = "Not logged in on any account"
local REVOKED = "The current device has been revoked"

-- `account get` -> { loggedIn, number?, expiresAt?, deviceName? }, nil for text it
-- does not recognise. Logged in prints "Mullvad account:", "Expires at:" and
-- "Device name:" lines; logged out prints NOT_LOGGED_IN; a revoked device prints
-- REVOKED (plus the account number, which is not returned: it is logged out).
-- `number` exists only so the service can mask it; it must go no further.
function parse.account(text)
  if type(text) ~= "string" then
    return nil
  end
  if text:find(NOT_LOGGED_IN, 1, true) or text:find(REVOKED, 1, true) then
    return { loggedIn = false }
  end
  local fields = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([^:]+):%s*(.-)%s*$")
    if key ~= nil then
      fields[key] = value
    end
  end
  local number = stringOrNil(fields["Mullvad account"])
  if number == nil then
    return nil
  end
  return {
    loggedIn = true,
    number = number,
    expiresAt = stringOrNil(fields["Expires at"]),
    deviceName = stringOrNil(fields["Device name"]),
  }
end

-- `account list-devices` -> { name }: a header line, then one device name a line.
function parse.devices(text)
  if type(text) ~= "string" then
    return nil
  end
  local names = nil
  for line in text:gmatch("[^\n]+") do
    local name = line:match("^%s*(.-)%s*$")
    if names ~= nil then
      if name ~= "" then
        names[#names + 1] = name
      end
    elseif name == "Devices on the account:" then
      names = {}
    end
  end
  return names
end

-- CLI errors with a sentence of their own (mullvad-management-interface Error,
-- printed as "Error: <text>"). Anything else stays error.command_failed.
local COMMAND_ERRORS = {
  { "There is no such device", "error.unknown_device" },
  { "This voucher code is invalid", "error.invalid_voucher" },
  { "This voucher code has already been used", "error.used_voucher" },
  { "There are too many devices on the account", "error.too_many_devices" },
  { "The account does not exist", "error.account_not_found" },
}

-- A failed command result -> its error key, or nil when it has no own sentence.
function parse.commandError(result)
  if type(result) ~= "table" or (result.exitCode or 0) == 0 then
    return nil
  end
  local text = tostring(result.stderr or "") .. "\n" .. tostring(result.stdout or "")
  for _, known in ipairs(COMMAND_ERRORS) do
    if text:find(known[1], 1, true) then
      return known[2]
    end
  end
  return nil
end

function parse.isDaemonDown(result)
  if type(result) ~= "table" or (result.exitCode or 0) == 0 then
    return false
  end
  local text = tostring(result.stderr or "") .. "\n" .. tostring(result.stdout or "")
  if text:find("Failed to connect to mullvad-daemon", 1, true) then
    return true
  end
  if text:find("Management RPC server or client error", 1, true) then
    return true
  end
  return false
end

return parse
