--!nonstrict
-- Pure request -> argv builder. Every request the panel, bar or IPC can send is
-- validated here before any process runs.
--
--   commands.build(request, ctx) -> { argv, ... } | nil, errKey
--
-- The argv list runs in order and stops at the first failure. An empty list
-- means "run nothing, just re-read" (refresh). ctx carries what validation
-- needs: { relays = relays.parse() list, realLocation, currentCountryCode, rand,
-- account = the published snapshot.account }.
-- Later tasks add a builder to BUILDERS per new action.

local relays = require("./relays.luau")

local commands = {}

local DEFAULT_TIMEOUT_MS = 15000
-- Waiting on the tunnel takes longer than reading a setting.
local SLOW_TIMEOUT_MS = 30000
local SLOW = { connect = true, disconnect = true }
-- pkexec waits for the user's password, so it gets a minute.
local AUTH_TIMEOUT_MS = 60000
local SERVICE_ENABLE = { "pkexec", "systemctl", "enable", "--now", "mullvad-daemon" }
-- Actions that launch a program and never wait for it (no callback, not busy).
local DETACHED = { open_app = true, open_account_page = true }
local ACCOUNT_PAGE = "https://mullvad.net/account"

local function findCountry(list, code)
  if type(code) ~= "string" then
    return nil
  end
  for _, c in ipairs(list or {}) do
    if c.code == code then
      return c
    end
  end
  return nil
end

local function hasCity(country, code)
  for _, ci in ipairs(country.cities or {}) do
    if ci.code == code then
      return true
    end
  end
  return false
end

local function setLocation(country, city)
  local argv = { "mullvad", "relay", "set", "location", country }
  if city ~= nil then
    argv[#argv + 1] = city
  end
  return argv
end

local function connectTo(country, city)
  return { setLocation(country, city), { "mullvad", "connect" } }
end

local function connectCountry(request, ctx)
  local country = findCountry(ctx.relays, request.country)
  if country == nil then
    return nil, "error.unknown_location"
  end
  local city = request.city
  if city ~= nil and (type(city) ~= "string" or not hasCity(country, city)) then
    return nil, "error.unknown_location"
  end
  return connectTo(country.code, city)
end

local function connectMyCountry(request, ctx)
  local code = relays.myCountry(ctx.relays, ctx.realLocation)
  if code == nil then
    return nil, "connect.my_country_unknown"
  end
  return connectTo(code)
end

local function connectRandom(request, ctx)
  local code = relays.randomCountry(ctx.relays, ctx.currentCountryCode, ctx.rand or math.random)
  if code == nil then
    return nil, "error.no_relays"
  end
  return connectTo(code)
end

-- Connect under whatever relay location the daemon already has (any, a custom
-- list, a hostname): sets nothing, so the setting stays as it is.
local function connectCurrent()
  return { { "mullvad", "connect" } }
end

local CONNECT_MODES = {
  country = connectCountry,
  my_country = connectMyCountry,
  random = connectRandom,
  current = connectCurrent,
}
-- Modes that pick a location from the relay list.
local NEEDS_RELAYS = { country = true, my_country = true, random = true }

-- {action=..., on=bool} -> `mullvad <words...> on|off`.
local function onOff(words)
  return function(request)
    if type(request.on) ~= "boolean" then
      return nil, "error.invalid_request"
    end
    local argv = { "mullvad" }
    for _, word in ipairs(words) do
      argv[#argv + 1] = word
    end
    argv[#argv + 1] = request.on and "on" or "off"
    return { argv }
  end
end

-- The multihop entry: "any", or a country, optionally one of its cities, from
-- the relay list.
local function setEntry(request, ctx)
  if request.country == "any" then
    if request.city ~= nil then
      return nil, "error.unknown_location"
    end
    return { { "mullvad", "relay", "set", "entry", "location", "any" } }
  end
  if ctx.relays == nil or #ctx.relays == 0 then
    return nil, "error.no_relays"
  end
  local country = findCountry(ctx.relays, request.country)
  if country == nil then
    return nil, "error.unknown_location"
  end
  local city = request.city
  if city ~= nil and (type(city) ~= "string" or not hasCity(country, city)) then
    return nil, "error.unknown_location"
  end
  local argv = { "mullvad", "relay", "set", "entry", "location", country.code }
  if city ~= nil then
    argv[#argv + 1] = city
  end
  return { argv }
end

local setLockdown = onOff({ "lockdown-mode", "set" })

-- ── account ──────────────────────────────────────────────────────────────────

-- "1234 5678-9012 3456" -> "1234567890123456", or nil, "error.invalid_account"
-- unless exactly 16 digits remain once spaces and dashes are gone.
function commands.normaliseAccount(text)
  if type(text) ~= "string" then
    return nil, "error.invalid_account"
  end
  local digits = text:gsub("[%s%-]", "")
  if #digits ~= 16 or digits:find("%D") then
    return nil, "error.invalid_account"
  end
  return digits
end

-- A voucher code without spaces and dashes; nil, "error.invalid_voucher" unless
-- what remains is non-empty and alphanumeric (so it can never read as a flag).
function commands.normaliseVoucher(text)
  if type(text) ~= "string" then
    return nil, "error.invalid_voucher"
  end
  local code = text:gsub("[%s%-]", "")
  if code == "" or code:find("[^%w]") then
    return nil, "error.invalid_voucher"
  end
  return code
end

-- The number goes into this argv and nowhere else (see service.luau).
local function login(request)
  local number, err = commands.normaliseAccount(request.number)
  if number == nil then
    return nil, err
  end
  return { { "mullvad", "account", "login", number } }
end

-- Only another device of the logged-in account, by a name from the last
-- `account list-devices` (ctx.account.devices); never this device.
local function revokeDevice(request, ctx)
  local account = ctx.account
  local name = request.name
  if type(name) ~= "string" or type(account) ~= "table" or account.loggedIn ~= true
    or name == account.deviceName then
    return nil, "error.unknown_device"
  end
  for _, device in ipairs(account.devices or {}) do
    if device == name then
      -- "--": a name is never read as an option.
      return { { "mullvad", "account", "revoke-device", "--", name } }
    end
  end
  return nil, "error.unknown_device"
end

local function redeem(request)
  local code, err = commands.normaliseVoucher(request.voucher)
  if code == nil then
    return nil, err
  end
  return { { "mullvad", "account", "redeem", code } }
end

-- The terminal fallback for a failed daemon action. The API takes a shell string,
-- so it is built only from these constants, never from request data.
local TERMINAL_COMMANDS = {
  start_service = "sudo systemctl enable --now mullvad-daemon",
  enable_service = "sudo systemctl enable --now mullvad-daemon",
  restart_service = "sudo systemctl restart mullvad-daemon",
}

function commands.terminalCommand(request)
  if type(request) ~= "table" or type(request["for"]) ~= "string" then
    return nil, "error.unknown_action"
  end
  local cmd = TERMINAL_COMMANDS[request["for"]]
  if cmd == nil then
    return nil, "error.unknown_action"
  end
  return cmd
end

local BUILDERS = {
  connect = function(request, ctx)
    local mode = CONNECT_MODES[request.mode]
    if mode == nil then
      return nil, "error.unknown_action"
    end
    if NEEDS_RELAYS[request.mode] and (ctx.relays == nil or #ctx.relays == 0) then
      return nil, "error.no_relays"
    end
    return mode(request, ctx)
  end,
  disconnect = function()
    return { { "mullvad", "disconnect" } }
  end,
  reconnect = function()
    return { { "mullvad", "reconnect" } }
  end,
  refresh = function()
    return {}
  end,
  open_app = function()
    return { { "mullvad-vpn" } }
  end,
  set_lockdown = setLockdown,
  lockdown_off = function(request, ctx)
    return setLockdown({ action = "set_lockdown", on = false }, ctx)
  end,
  start_service = function()
    return { SERVICE_ENABLE }
  end,
  enable_service = function()
    return { SERVICE_ENABLE }
  end,
  restart_service = function()
    return { { "pkexec", "systemctl", "restart", "mullvad-daemon" } }
  end,
  set_multihop = onOff({ "relay", "set", "multihop" }),
  set_auto_connect = onOff({ "auto-connect", "set" }),
  set_entry = setEntry,
  login = login,
  logout = function()
    return { { "mullvad", "account", "logout" } }
  end,
  revoke_device = revokeDevice,
  redeem = redeem,
  enable_polkit_agent = function()
    return { { "noctalia", "msg", "config-set", "shell.polkit_agent", "true" } }
  end,
  open_account_page = function()
    return { { "xdg-open", ACCOUNT_PAGE } }
  end,
}

function commands.build(request, ctx)
  if type(request) ~= "table" then
    return nil, "error.unknown_action"
  end
  local builder = BUILDERS[request.action]
  if builder == nil then
    return nil, "error.unknown_action"
  end
  return builder(request, ctx or {})
end

-- True for a request whose argv the service launches detached: no callback,
-- not busy, no re-read (the program outlives the request).
function commands.detached(request)
  return type(request) == "table" and DETACHED[request.action] == true
end

-- Per-argv timeout: `mullvad connect` / `mullvad disconnect` and the account
-- actions (they wait on Mullvad's API) get longer.
function commands.timeoutMs(argv)
  if argv[1] == "pkexec" then
    return AUTH_TIMEOUT_MS
  end
  if argv[1] == "mullvad" and ((#argv == 2 and SLOW[argv[2]]) or argv[2] == "account") then
    return SLOW_TIMEOUT_MS
  end
  return DEFAULT_TIMEOUT_MS
end

return commands
