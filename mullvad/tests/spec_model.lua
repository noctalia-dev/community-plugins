local parse = loadModule("parse.luau")
local model = loadModule("model.luau")

local function tunnel(name)
  return parse.status(json.decode(fixture(name)))
end

local function snap(over)
  local s = {
    daemon = "running", bootEnabled = true, kernelModulesPresent = true,
    busy = false, tunnel = nil, settings = nil,
    account = { loggedIn = true, expiry = "ok", devices = {} },
    relays = {}, realLocation = nil, lastError = nil,
  }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end

local function actionsEq(name, got, want)
  eq(name, table.concat(got or {}, ","), table.concat(want, ","))
end

-- bar
local bar = model.bar(snap({ tunnel = tunnel("status-disconnected.json") }))
eq("bar disconnected label", bar.label, "Off")
eq("bar disconnected color", bar.color, "on_surface_variant")
check("bar has glyph and tooltip", bar.glyph ~= "" and bar.tooltip ~= "")
bar = model.bar(snap({ tunnel = tunnel("synthetic-status-connecting.json") }))
eq("bar connecting label", bar.label, "…")
eq("bar connecting color", bar.color, "primary")
bar = model.bar(snap({ tunnel = tunnel("status-connected.json") }))
eq("bar connected label", bar.label, "SE")
eq("bar connected color", bar.color, "tertiary")
bar = model.bar(snap({ tunnel = tunnel("synthetic-status-multihop.json") }))
eq("bar multihop label", bar.label, "RO→SE")
bar = model.bar(snap({ daemon = "down" }))
eq("bar daemon down label", bar.label, "!")
eq("bar daemon down color", bar.color, "error")
bar = model.bar(snap({ tunnel = tunnel("synthetic-status-error-firewall.json") }))
eq("bar error label", bar.label, "!")
bar = model.bar(snap({ tunnel = tunnel("status-disconnected.json"), account = { loggedIn = false, devices = {} } }))
eq("bar logged out label", bar.label, "!")
eq("bar logged out color", bar.color, "error")
bar = model.bar(snap({ tunnel = tunnel("status-connected.json"), account = { loggedIn = true, expiry = "expired", devices = {} } }))
eq("bar expired label", bar.label, "!")
bar = model.bar(snap({ tunnel = tunnel("status-connected.json"), account = nil }))
eq("bar account unread is not a problem", bar.label, "SE")

bar = model.bar(snap({ tunnel = parse.status(json.decode(fixture("status-disconnected-nolocation.json"))) }))
eq("bar disconnected without location", bar.label, "Off")

-- header
local h = model.header(snap({ daemon = "down" }))
eq("header daemon down kind", h.kind, "daemon_down")
actionsEq("header daemon down actions", h.actions, { "start_service" })
h = model.header(snap({ daemon = "down", tunnel = tunnel("synthetic-status-error-firewall.json") }))
eq("daemon down wins over error", h.kind, "daemon_down")
h = model.header(snap({ tunnel = tunnel("status-connected.json"), bootEnabled = false }))
eq("header boot disabled kind", h.kind, "ok")
actionsEq("header boot disabled actions", h.actions, { "enable_service" })
h = model.header(snap({ tunnel = tunnel("status-connected.json") }))
eq("header ok kind", h.kind, "ok")
actionsEq("header ok no actions", h.actions, {})
h = model.header(snap({ tunnel = tunnel("synthetic-status-error-firewall.json"), kernelModulesPresent = false }))
eq("header error kind", h.kind, "error")
eq("header error text key", h.textKey, "error.kernel_updated")
actionsEq("header error actions", h.actions, { "reboot_notice" })

-- errorInfo
local function info(name, over)
  over = over or {}
  over.tunnel = tunnel(name)
  return model.errorInfo(snap(over))
end
local i = info("synthetic-status-error-firewall.json", { kernelModulesPresent = false })
eq("kernel updated key", i.key, "error.kernel_updated")
actionsEq("kernel updated actions", i.actions, { "reboot_notice" })
i = info("synthetic-status-error-firewall.json")
eq("firewall key", i.key, "error.firewall")
actionsEq("firewall actions", i.actions, { "restart_service", "disconnect" })
i = info("synthetic-status-error-auth_failed.json")
eq("auth failed key", i.key, "error.auth_failed")
actionsEq("auth failed actions", i.actions, { "open_account_tab" })
i = info("synthetic-status-error-ipv6_unavailable.json")
eq("ipv6 key", i.key, "error.ipv6_unavailable")
actionsEq("ipv6 actions", i.actions, { "disconnect" })
i = info("synthetic-status-error-set_dns_error.json")
eq("dns key", i.key, "error.set_dns")
actionsEq("dns actions", i.actions, { "restart_service", "disconnect" })
i = info("synthetic-status-error-start_tunnel_error.json")
eq("start tunnel key", i.key, "error.start_tunnel")
actionsEq("start tunnel actions", i.actions, { "disconnect" })
i = info("synthetic-status-error-tunnel_parameter_error.json")
eq("parameter key", i.key, "error.tunnel_parameter")
actionsEq("parameter actions", i.actions, { "disconnect" })
i = info("synthetic-status-error-is_offline.json")
eq("offline key", i.key, "error.offline")
actionsEq("offline actions", i.actions, { "disconnect" })
i = info("synthetic-status-error-foo_bar.json")
eq("unknown key", i.key, "error.unknown")
actionsEq("unknown actions", i.actions, { "disconnect" })
h = model.header(snap({ tunnel = tunnel("synthetic-status-error-foo_bar.json") }))
eq("unknown header reason sub", h.subs.reason, "foo bar")

i = info("synthetic-status-blocked-lockdown.json")
eq("lockdown blocking key", i.key, "error.lockdown_blocking")
actionsEq("lockdown blocking actions", i.actions, { "connect", "lockdown_off" })
i = info("synthetic-status-blocked-lockdown.json", { settings = { lockdown = false } })
eq("locked_down blocks even if settings.lockdown is false", i.key, "error.lockdown_blocking")

i = info("status-disconnected.json", { account = { loggedIn = false, devices = {} } })
eq("logged out key", i.key, "error.logged_out")
actionsEq("logged out actions", i.actions, { "open_account_tab" })
i = info("status-disconnected.json", { account = { loggedIn = true, expiry = "expired", devices = {} } })
eq("expired key", i.key, "error.expired")
actionsEq("expired actions", i.actions, { "open_account_page" })
i = info("status-disconnected.json", { account = { loggedIn = false, expiry = "expired", devices = {} } })
eq("expired beats logged out", i.key, "error.expired")
i = info("status-disconnected.json", { account = nil })
eq("no account is no problem", i, nil)
i = info("synthetic-status-blocked-lockdown.json", { account = { loggedIn = true, expiry = "expired", devices = {} } })
eq("lockdown beats expired", i.key, "error.lockdown_blocking")
i = info("synthetic-status-error-firewall.json", { settings = { lockdown = true }, account = { loggedIn = false, devices = {} } })
eq("tunnel error beats logged out", i.key, "error.firewall")
eq("daemon down has no errorInfo", model.errorInfo(snap({ daemon = "down" })), nil)

-- scrub
eq("scrub account number", model.scrub("acct 1234567890123456 x"), "acct ################ x")
eq("scrub longer run", model.scrub("1234567890123456789"), "###################")
eq("scrub leaves short numbers", model.scrub("port 51820 id 123456789012345"), "port 51820 id 123456789012345")

-- barView
local bv = model.barView(nil, true)
eq("barView loading glyph", bv.glyph, "shield")
eq("barView loading color", bv.color, "on_surface_variant")
eq("barView loading label", bv.label, "")
check("barView loading tooltip", bv.tooltip ~= "")
eq("barView non-table loading", model.barView("x", true).glyph, "shield")
local loaded = snap({ tunnel = tunnel("status-disconnected.json") })
bv = model.barView(loaded, true)
eq("barView loaded label", bv.label, model.bar(loaded).label)
eq("barView loaded glyph", bv.glyph, model.bar(loaded).glyph)
eq("barView nil showLabel keeps label", model.barView(loaded, nil).label, "Off")
eq("barView show_label false", model.barView(loaded, false).label, "")
eq("barView show_label false keeps glyph", model.barView(loaded, false).glyph, model.bar(loaded).glyph)
eq("barView loading show_label false", model.barView(nil, false).label, "")

-- account (Task 13)
eq("maskAccount keeps the last 4", model.maskAccount("1234567890123456"), "•••• •••• •••• 3456")
eq("maskAccount of nothing", model.maskAccount(nil), nil)
check("maskAccount output has no 16-digit run", not model.maskAccount("1234567890123456"):find(string.rep("%d", 16)))
local NOW = 1700000000 -- 2023-11-14 22:13:20 UTC
eq("expiresAtSeconds UTC", model.expiresAtSeconds("2023-11-14 22:13:20 +00:00"), NOW)
eq("expiresAtSeconds positive offset", model.expiresAtSeconds("2023-11-15 01:13:20 +03:00"), NOW)
eq("expiresAtSeconds negative offset", model.expiresAtSeconds("2023-11-14 17:13:20 -05:00"), NOW)
eq("expiresAtSeconds fractional seconds", model.expiresAtSeconds("2023-11-14 22:13:20.123456 +00:00"), NOW)
eq("expiresAtSeconds leap day", model.expiresAtSeconds("2024-02-29 00:00:00 +00:00"), 1709164800)
eq("expiresAtSeconds garbage", model.expiresAtSeconds("next week"), nil)
eq("expiryLevel +30 d", model.expiryLevel("2023-12-14 22:13:20 +00:00", NOW), "ok")
eq("expiryLevel +3 d", model.expiryLevel("2023-11-17 22:13:20 +00:00", NOW), "warn")
eq("expiryLevel -1 d", model.expiryLevel("2023-11-13 22:13:20 +00:00", NOW), "expired")
eq("expiryLevel exactly 7 d is ok", model.expiryLevel("2023-11-21 22:13:20 +00:00", NOW), "ok")
eq("expiryLevel unparsable", model.expiryLevel("soon", NOW), nil)

-- flags
eq("flag se", model.flag("se"), "🇸🇪")
eq("flag RO", model.flag("RO"), "🇷🇴")
eq("flag gb", model.flag("gb"), "🇬🇧")
eq("flag nil", model.flag(nil), "")
eq("flag one letter", model.flag("x"), "")
eq("flag digit", model.flag("1a"), "")
eq("flag three letters", model.flag("swe"), "")
eq("withFlag on", model.withFlag("Sweden", "se", true), "🇸🇪 Sweden")
eq("withFlag off", model.withFlag("Sweden", "se", false), "Sweden")
eq("withFlag unset", model.withFlag("Sweden", "se", nil), "Sweden")
eq("withFlag no code", model.withFlag("Sweden", nil, true), "Sweden")
eq("bar label never gets a flag", model.barView(snap({ tunnel = tunnel("status-connected.json") }), true, true).label, "SE")

-- Header and bar tooltip text, rendered through the real en.json (R4, R5): with
-- a flag "{city} {flag} {country}", without one "{city}, {country}"; a missing
-- piece leaves no stray space, comma or flag; the tooltip adds " · IP".
do
  local root = (arg and arg[0] or ""):gsub("tests/run%.lua$", "")
  local file = assert(io.open(root .. "translations/en.json", "r"))
  local strings = json.decode(file:read("*a"))
  file:close()
  local function realTr(key, subst)
    local node = strings
    for part in key:gmatch("[^.]+") do
      node = type(node) == "table" and node[part] or nil
    end
    if type(node) ~= "string" then return "MISSING:" .. key end
    return (node:gsub("{(%w+)}", function(name)
      local v = subst and subst[name]
      return v ~= nil and tostring(v) or ("{" .. name .. "}")
    end))
  end
  local prevNoctalia = _G.noctalia
  _G.noctalia = { tr = realTr }
  local function connectedWith(over)
    local t = tunnel("status-connected.json")
    for k, v in pairs(over) do
      if v == false then t[k] = nil else t[k] = v end
    end
    return snap({ tunnel = t, relays = { { code = "se", name = "Sweden" } } })
  end
  local function headerText(s, flags)
    local hh = model.header(s, flags)
    return realTr(hh.textKey, hh.subs)
  end
  local full = connectedWith({})
  eq("text: tooltip with a flag and the IP", model.bar(full, true).tooltip, "Mullvad: connected to Stockholm 🇸🇪 Sweden · 203.0.113.7")
  eq("text: tooltip without flags keeps the comma", model.bar(full, false).tooltip, "Mullvad: connected to Stockholm, Sweden · 203.0.113.7")
  eq("text: tooltip without an IP", model.bar(connectedWith({ ipv4 = false }), true).tooltip, "Mullvad: connected to Stockholm 🇸🇪 Sweden")
  eq("text: tooltip without a city", model.bar(connectedWith({ city = false }), true).tooltip, "Mullvad: connected to 🇸🇪 Sweden · 203.0.113.7")
  eq("text: tooltip without a country has no flag", model.bar(connectedWith({ country = false }), true).tooltip, "Mullvad: connected to Stockholm · 203.0.113.7")
  eq("text: tooltip with no place", model.bar(connectedWith({ city = false, country = false }), true).tooltip, "Mullvad: connected · 203.0.113.7")
  eq("text: tooltip with nothing known", model.bar(connectedWith({ city = false, country = false, ipv4 = false }), true).tooltip, "Mullvad: connected")
  eq("text: header with a flag has no comma", headerText(full, true), "Connected to Stockholm 🇸🇪 Sweden")
  eq("text: header without flags keeps the comma", headerText(full, false), "Connected to Stockholm, Sweden")
  eq("text: header without a city", headerText(connectedWith({ city = false }), true), "Connected to 🇸🇪 Sweden")
  eq("text: header without a city, no flags", headerText(connectedWith({ city = false }), false), "Connected to Sweden")
  eq("text: header without a country has no flag", headerText(connectedWith({ country = false }), true), "Connected to Stockholm")
  eq("text: header with no place", headerText(connectedWith({ city = false, country = false }), true), "Connected")
  local noReason = snap({ tunnel = { state = "error" } })
  eq("text: tunnel error without a reason has no empty brackets", headerText(noReason), "Mullvad is blocking traffic after an error.")
  eq("text: bar tooltip for it too", model.bar(noReason).tooltip, "Mullvad is blocking traffic after an error.")
  eq("text: tunnel error with a reason names it",
    headerText(snap({ tunnel = tunnel("synthetic-status-error-foo_bar.json") })), "Mullvad is blocking traffic after an error (foo bar).")
  _G.noctalia = prevNoctalia
end

eq("flag aa", model.flag("aa"), "🇦🇦")
eq("flag zz", model.flag("zz"), "🇿🇿")
eq("tunnelCountryCode from the hostname", model.tunnelCountryCode({ tunnel = { countryCode = "se", country = "Sweden" } }), "se")
eq("tunnelCountryCode by name from the relay list",
  model.tunnelCountryCode({ tunnel = { country = "Sweden" }, relays = { { code = "se", name = "Sweden" } } }), "se")
eq("tunnelCountryCode unknown name", model.tunnelCountryCode({ tunnel = { country = "Atlantis" }, relays = { { code = "se", name = "Sweden" } } }), nil)
eq("tunnelCountryCode nil tunnel", model.tunnelCountryCode({ relays = {} }), nil)
eq("no code, no flag", model.withFlag("Atlantis", model.tunnelCountryCode({ tunnel = { country = "Atlantis" }, relays = {} }), true), "Atlantis")
