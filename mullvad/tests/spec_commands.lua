local commands = loadModule("commands.luau")
local relays = loadModule("relays.luau")

local list = relays.parse(fixture("relay-list.txt"))
local romania = { country = "Romania", latitude = 44.4, longitude = 26.1 }

local function ctx(over)
  local c = { relays = list, realLocation = romania, currentCountryCode = nil, rand = function() return 1 end }
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

local function argvs(cmds)
  if cmds == nil then return "nil" end
  local out = {}
  for i, argv in ipairs(cmds) do out[i] = table.concat(argv, " ") end
  return table.concat(out, " | ")
end

local cmds, err = commands.build({ action = "connect", mode = "country", country = "se", city = "got" }, ctx())
eq("connect country+city", argvs(cmds), "mullvad relay set location se got | mullvad connect")
eq("connect country+city no error", err, nil)

cmds = commands.build({ action = "connect", mode = "country", country = "se" }, ctx())
eq("connect country only", argvs(cmds), "mullvad relay set location se | mullvad connect")

cmds, err = commands.build({ action = "connect", mode = "country", country = "xx" }, ctx())
eq("unknown country gives nil", cmds, nil)
eq("unknown country error", err, "error.unknown_location")

cmds, err = commands.build({ action = "connect", mode = "country", country = "se", city = "zzz" }, ctx())
eq("unknown city gives nil", cmds, nil)
eq("unknown city error", err, "error.unknown_location")

cmds, err = commands.build({ action = "connect", mode = "country", country = "ro", city = "got" }, ctx())
eq("city of another country rejected", err, "error.unknown_location")

cmds, err = commands.build({ action = "connect", mode = "country", country = 5 }, ctx())
eq("non-string country rejected", err, "error.unknown_location")

cmds = commands.build({ action = "connect", mode = "my_country" }, ctx())
eq("connect my country", argvs(cmds), "mullvad relay set location ro | mullvad connect")

cmds, err = commands.build({ action = "connect", mode = "my_country" }, { relays = list, rand = function() return 1 end })
eq("my country unknown gives nil", cmds, nil)
eq("my country without real location", err, "connect.my_country_unknown")

-- rand(n) == 1 picks the first country of the pool; the current one is excluded.
cmds = commands.build({ action = "connect", mode = "random" }, ctx())
eq("connect random first", argvs(cmds), "mullvad relay set location " .. list[1].code .. " | mullvad connect")
cmds = commands.build({ action = "connect", mode = "random" }, ctx({ currentCountryCode = list[1].code }))
eq("connect random skips current", argvs(cmds), "mullvad relay set location " .. list[2].code .. " | mullvad connect")
cmds = commands.build({ action = "connect", mode = "random" }, ctx({ rand = function(n) return n end }))
eq("connect random last", argvs(cmds), "mullvad relay set location " .. list[#list].code .. " | mullvad connect")

-- R32: no pick and a relay setting the panel cannot show: connect under the
-- daemon's own setting, without setting a location.
cmds, err = commands.build({ action = "connect", mode = "current" }, ctx())
eq("connect current is a plain connect", argvs(cmds), "mullvad connect")
eq("connect current is one argv", cmds and #cmds, 1)
eq("connect current argv is exactly mullvad connect", cmds and #cmds[1], 2)
eq("connect current no error", err, nil)
cmds = commands.build({ action = "connect", mode = "current" }, ctx({ relays = {} }))
eq("connect current needs no relay list", argvs(cmds), "mullvad connect")

cmds, err = commands.build({ action = "connect", mode = "random" }, ctx({ relays = {} }))
eq("random with no relays", err, "error.no_relays")
cmds, err = commands.build({ action = "connect", mode = "country", country = "se" }, { realLocation = romania })
eq("country before relays load", err, "error.no_relays")

cmds, err = commands.build({ action = "connect", mode = "sideways" }, ctx())
eq("unknown connect mode", err, "error.unknown_action")

eq("disconnect", argvs(commands.build({ action = "disconnect" }, ctx())), "mullvad disconnect")
eq("reconnect", argvs(commands.build({ action = "reconnect" }, ctx())), "mullvad reconnect")

cmds, err = commands.build({ action = "refresh" }, ctx())
check("refresh runs no commands", type(cmds) == "table" and #cmds == 0 and err == nil)

-- Ruling R3: an unknown action runs nothing.
cmds, err = commands.build({ action = "format_disk" }, ctx())
eq("unknown action gives nil", cmds, nil)
eq("unknown action error", err, "error.unknown_action")
cmds, err = commands.build({}, ctx())
eq("missing action error", err, "error.unknown_action")

-- every argv is a fresh table of strings
cmds = commands.build({ action = "connect", mode = "country", country = "se" }, ctx())
local allStrings = true
for _, argv in ipairs(cmds) do
  for _, part in ipairs(argv) do
    if type(part) ~= "string" then allStrings = false end
  end
end
check("argv parts are strings", allStrings)

-- timeouts
eq("connect timeout", commands.timeoutMs({ "mullvad", "connect" }), 30000)
eq("disconnect timeout", commands.timeoutMs({ "mullvad", "disconnect" }), 30000)
eq("set location timeout", commands.timeoutMs({ "mullvad", "relay", "set", "location", "se" }), 15000)
eq("reconnect timeout", commands.timeoutMs({ "mullvad", "reconnect" }), 15000)

-- open_app (v1 Advanced tab): exactly the Mullvad app, launched detached
cmds, err = commands.build({ action = "open_app" }, ctx())
eq("open_app is one argv", cmds and #cmds, 1)
eq("open_app argv is exactly mullvad-vpn", cmds and #cmds[1] == 1 and cmds[1][1], "mullvad-vpn")
eq("open_app no error", err, nil)
eq("open_app is detached", commands.detached({ action = "open_app" }), true)
eq("connect is not detached", commands.detached({ action = "connect" }), false)
eq("non-table request is not detached", commands.detached("open_app"), false)

-- Connect tab toggles (Task 7): exact argv
local function one(request)
  local c, e = commands.build(request, ctx())
  return argvs(c), e
end
eq("set_lockdown on", one({ action = "set_lockdown", on = true }), "mullvad lockdown-mode set on")
eq("set_lockdown off", one({ action = "set_lockdown", on = false }), "mullvad lockdown-mode set off")
eq("set_multihop on", one({ action = "set_multihop", on = true }), "mullvad relay set multihop on")
eq("set_multihop off", one({ action = "set_multihop", on = false }), "mullvad relay set multihop off")
eq("set_auto_connect on", one({ action = "set_auto_connect", on = true }), "mullvad auto-connect set on")
eq("set_auto_connect off", one({ action = "set_auto_connect", on = false }), "mullvad auto-connect set off")
eq("set_entry country", one({ action = "set_entry", country = "se" }), "mullvad relay set entry location se")
eq("set_entry country+city", one({ action = "set_entry", country = "se", city = "got" }), "mullvad relay set entry location se got")
for _, action in ipairs({ "set_lockdown", "set_multihop", "set_auto_connect" }) do
  local c, e = commands.build({ action = action, on = "yes" }, ctx())
  eq(action .. " needs a boolean", c, nil)
  eq(action .. " invalid error", e, "error.invalid_request")
  c, e = commands.build({ action = action }, ctx())
  eq(action .. " without on", e, "error.invalid_request")
end
eq("set_entry any", one({ action = "set_entry", country = "any" }), "mullvad relay set entry location any")
eq("set_entry any needs no relay list", argvs(commands.build({ action = "set_entry", country = "any" }, {})),
  "mullvad relay set entry location any")
cmds, err = commands.build({ action = "set_entry", country = "any", city = "got" }, ctx())
eq("set_entry any with a city", err, "error.unknown_location")
cmds, err = commands.build({ action = "set_entry", country = "xx" }, ctx())
eq("set_entry unknown country", err, "error.unknown_location")
cmds, err = commands.build({ action = "set_entry", country = "ro", city = "got" }, ctx())
eq("set_entry city of another country", err, "error.unknown_location")
cmds, err = commands.build({ action = "set_entry", country = "se" }, { realLocation = romania })
eq("set_entry before relays load", err, "error.no_relays")
eq("set_lockdown timeout", commands.timeoutMs({ "mullvad", "lockdown-mode", "set", "on" }), 15000)

-- every key the service or builder can put in lastError has an English string
local file = io.open("mullvad/translations/en.json", "r")
local en = file and json.decode(file:read("*a"))
if file then file:close() end
local function hasKey(key)
  local node = en
  for part in key:gmatch("[^.]+") do
    node = type(node) == "table" and node[part] or nil
  end
  return type(node) == "string"
end
for _, key in ipairs({ "error.busy", "error.timeout", "error.unknown_action", "error.unknown_location",
  "error.no_relays", "error.command_failed", "connect.my_country_unknown", "error.invalid_request" }) do
  check("en.json has " .. key, en ~= nil and hasKey(key))
end

-- daemon control (Task 14)
local enableArgv = "pkexec systemctl enable --now mullvad-daemon"
eq("start_service argv", argvs(commands.build({ action = "start_service" }, ctx())), enableArgv)
eq("enable_service argv", argvs(commands.build({ action = "enable_service" }, ctx())), enableArgv)
eq("restart_service argv", argvs(commands.build({ action = "restart_service" }, ctx())), "pkexec systemctl restart mullvad-daemon")
eq("lockdown_off argv equals set_lockdown off",
  argvs(commands.build({ action = "lockdown_off" }, ctx())),
  argvs(commands.build({ action = "set_lockdown", on = false }, ctx())))
eq("pkexec timeout is 60 s", commands.timeoutMs({ "pkexec", "systemctl", "restart", "mullvad-daemon" }), 60000)
eq("mullvad timeout unchanged", commands.timeoutMs({ "mullvad", "relay", "get" }), 15000)

-- account (Task 13)
eq("normaliseAccount strips spaces and dashes", commands.normaliseAccount("1234 5678-9012 3456"), "1234567890123456")
local n, nerr = commands.normaliseAccount("1234")
eq("normaliseAccount too short", n, nil)
eq("normaliseAccount error key", nerr, "error.invalid_account")
eq("normaliseAccount 17 digits", select(2, commands.normaliseAccount("12345678901234567")), "error.invalid_account")
eq("normaliseAccount letters", select(2, commands.normaliseAccount("1234567890abcdef")), "error.invalid_account")
eq("normaliseAccount non-string", select(2, commands.normaliseAccount(1234567890123456)), "error.invalid_account")
eq("commands.login normalises separators", argvs(commands.build({ action = "login", number = "1234-5678-9012-3456" }, ctx())),
  "mullvad account login 1234567890123456")
cmds, err = commands.build({ action = "login", number = "12" }, ctx())
eq("login bad number builds nothing", cmds, nil)
eq("login bad number error", err, "error.invalid_account")
eq("logout argv", argvs(commands.build({ action = "logout" }, ctx())), "mullvad account logout")

local account = { loggedIn = true, deviceName = "Test Device", devices = { "Test Device", "Other Device 1" } }
eq("revoke argv ends options before the name",
  argvs(commands.build({ action = "revoke_device", name = "Other Device 1" }, ctx({ account = account }))),
  "mullvad account revoke-device -- Other Device 1")
cmds, err = commands.build({ action = "revoke_device", name = "Test Device" }, ctx({ account = account }))
eq("revoking the current device is rejected", cmds, nil)
eq("revoking the current device error", err, "error.unknown_device")
eq("revoke of a name not on the account", select(2, commands.build({ action = "revoke_device", name = "No Such Device" },
  ctx({ account = account }))), "error.unknown_device")
eq("revoke before the account is read", select(2, commands.build({ action = "revoke_device", name = "Other Device 1" },
  ctx())), "error.unknown_device")
eq("revoke non-string name", select(2, commands.build({ action = "revoke_device", name = 3 }, ctx({ account = account }))),
  "error.unknown_device")

eq("normaliseVoucher strips spaces and dashes", commands.normaliseVoucher("ABCD-1234 EFGH"), "ABCD1234EFGH")
eq("redeem argv", argvs(commands.build({ action = "redeem", voucher = "INVALID0000" }, ctx())), "mullvad account redeem INVALID0000")
eq("redeem empty", select(2, commands.build({ action = "redeem", voucher = " - " }, ctx())), "error.invalid_voucher")
eq("redeem punctuation", select(2, commands.build({ action = "redeem", voucher = "AB;rm" }, ctx())), "error.invalid_voucher")
eq("redeem leading dash cannot become a flag", argvs(commands.build({ action = "redeem", voucher = "--help" }, ctx())),
  "mullvad account redeem help")
eq("redeem non-string", select(2, commands.build({ action = "redeem" }, ctx())), "error.invalid_voucher")

eq("open_account_page argv", argvs(commands.build({ action = "open_account_page" }, ctx())), "xdg-open https://mullvad.net/account")
check("open_account_page is detached", commands.detached({ action = "open_account_page" }))
check("login is not detached", not commands.detached({ action = "login" }))
eq("account calls get 30 s (they reach Mullvad's API)", commands.timeoutMs({ "mullvad", "account", "login", "x" }), 30000)

for _, key in ipairs({ "error.invalid_account", "error.unknown_device", "error.invalid_voucher", "error.used_voucher",
  "error.too_many_devices", "error.account_not_found" }) do
  check("en.json has " .. key, en ~= nil and hasKey(key))
end

-- every program an action can run is a manifest dependency
local toml = io.open("mullvad/plugin.toml"):read("a")
local deps = {}
for name in (toml:match("\ndependencies = %[(.-)%]") or ""):gmatch('"([^"]+)"') do deps[name] = true end
local accountCtx = ctx({ account = { loggedIn = true, deviceName = "A", devices = { "A", "B" } } })
for _, request in ipairs({ { action = "open_account_page" }, { action = "open_app" }, { action = "login", number = "1234567890123456" },
  { action = "revoke_device", name = "B" }, { action = "redeem", voucher = "X" }, { action = "start_service" } }) do
  local built = commands.build(request, accountCtx)
  check("dependency listed for " .. request.action, built ~= nil and deps[built[1][1]] == true)
end
