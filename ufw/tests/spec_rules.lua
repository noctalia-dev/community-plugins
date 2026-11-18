-- rules.luau: ufw.conf, /etc/default/ufw and user*.rules parsing, against sandbox fixtures.
local rules = loadModule("rules.luau")

local function find(list, pred)
  for _, r in ipairs(list) do
    if pred(r) then
      return r
    end
  end
  return nil
end

eq("rules: conf on", rules.parseConf(fixture("conf-on.conf")).enabled, true)
eq("rules: conf off", rules.parseConf(fixture("conf-off.conf")).enabled, false)
eq("rules: conf missing ENABLED", rules.parseConf("# nothing\nLOGLEVEL=low\n").enabled, nil)
eq("rules: conf loglevel", rules.parseConf(fixture("conf-on.conf")).loglevel, "low")

local d = rules.parseDefaults(fixture("default-ipv6-no"))
eq("rules: defaults ipv6 no", d.ipv6, false)
eq("rules: defaults input DROP", d.input, "DROP")
eq("rules: defaults input ACCEPT", rules.parseDefaults(fixture("default-accept")).input, "ACCEPT")
eq("rules: defaults ipv6 default true", rules.parseDefaults("").ipv6, true)

local simple, done = rules.parseRules(fixture("simple-v4v6.rules"), fixture("simple-v6.rules"), true)
eq("rules: simple complete", done, true)
eq("rules: simple merges to one rule", #simple, 1)
check("rules: simple v4 and v6", simple[1].v4 == true and simple[1].v6 == true)
eq("rules: simple proto any", simple[1].proto, "any")
eq("rules: simple port", simple[1].port, "49152")
eq("rules: simple from any", simple[1].from, "any")
eq("rules: simple to any", simple[1].to, "any")
eq("rules: simple action", simple[1].action, "allow")
eq("rules: simple direction", simple[1].direction, "in")
eq("rules: simple removable untouched", simple[1].removable, nil)

local list = rules.parseRules(fixture("shapes.rules"), fixture("shapes6.rules"), true)
eq("rules: shapes count", #list, 15)

local api = find(list, function(r) return r.port == "8080" end)
eq("rules: comment hex decoded", api.comment, "api dev server")

local src = find(list, function(r) return r.from == "192.0.2.0/24" end)
eq("rules: v4-only source rule port", src.port, "22")
check("rules: v4-only flags", src.v4 == true and src.v6 == false)
local src6 = find(list, function(r) return r.from == "2001:db8::/32" end)
check("rules: v6-only flags", src6.v4 == false and src6.v6 == true)
eq("rules: v6-only port", src6.port, "2222")

-- each shape, in file order
local function shape(i, action, dir, proto, port, app, iface, route)
  local r = list[i]
  local tag = "rules: shape " .. i .. " "
  eq(tag .. "action", r.action, action)
  eq(tag .. "direction", r.direction, dir)
  eq(tag .. "proto", r.proto, proto)
  eq(tag .. "port", r.port, port)
  eq(tag .. "app", r.app, app)
  eq(tag .. "iface", r.iface, iface)
  eq(tag .. "route", r.route, route)
end
shape(1, "allow", "in", "tcp", "80", nil, nil, false)
shape(2, "allow", "in", "udp", "5173", nil, nil, false)
shape(3, "allow", "in", "tcp", "8080", nil, nil, false)
shape(4, "allow", "in", "tcp", "22", nil, nil, false)
shape(5, "allow", "in", "any", nil, nil, nil, false)
eq("rules: shape 5 from", list[5].from, "198.51.100.7")
shape(6, "limit", "in", "tcp", "22", nil, nil, false)
shape(7, "deny", "in", "any", "4444", nil, nil, false)
shape(8, "reject", "in", "udp", "4445", nil, nil, false)
shape(9, "allow", "in", "tcp", "60000:60010", nil, nil, false)
shape(10, "allow", "in", "tcp", "80,443", nil, nil, false)
shape(11, "allow", "in", "any", "43117", nil, "eth9", false)
shape(12, "allow", "out", "any", "43118", nil, nil, false)
shape(13, "allow", "in", "tcp", "80", "WWW", nil, false)
shape(14, "allow", "in", "any", nil, nil, "eth9>eth8", true)
shape(15, "allow", "in", "tcp", "2222", nil, nil, false)

local no6 = rules.parseRules(fixture("shapes.rules"), fixture("shapes6.rules"), false)
eq("rules: ipv6=false ignores user6 count", #no6, 14)
check("rules: ipv6=false no v6 flags", find(no6, function(r) return r.v6 end) == nil)
local nilV6, nilV6Done = rules.parseRules(fixture("shapes.rules"), nil, true)
eq("rules: nil v6 text ok", #nilV6, 14)
eq("rules: ipv6 on with no v6 text is incomplete", nilV6Done, false)
local _, v4OnlyDone = rules.parseRules(fixture("shapes.rules"), nil, false)
eq("rules: ipv6 off needs no v6 text", v4OnlyDone, true)

local _, trunc = rules.parseRules(fixture("truncated.rules"), nil, true)
eq("rules: truncated file is incomplete", trunc, false)
local _, v6trunc = rules.parseRules(fixture("shapes.rules"), fixture("truncated.rules"), true)
eq("rules: truncated v6 is incomplete", v6trunc, false)
local _, v6off = rules.parseRules(fixture("shapes.rules"), fixture("truncated.rules"), false)
eq("rules: truncated v6 ignored when ipv6 off", v6off, true)

local garb, gdone = rules.parseRules(fixture("garbage.rules"), nil, false)
eq("rules: garbage tuple skipped, others parsed", #garb, 13)
eq("rules: garbage file still complete", gdone, true)

local a = rules.parseRules("### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 in comment=6161\n### END RULES ###\n", nil, true)
local b = rules.parseRules("### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 in comment=626262\n### END RULES ###\n", nil, true)
eq("rules: ids stable and comment-free", a[1].id, b[1].id)
eq("rules: id format", a[1].id, "allow|in|tcp|80|any||any|||0|")

-- the source app (tuple token 8) is kept and is part of the id; the log suffix is kept but is not
local sappRules = rules.parseRules(table.concat({
  "### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 in",
  "### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 - WWW in",
  "### tuple ### allow_log-all udp 53 0.0.0.0/0 any 0.0.0.0/0 Mail%20submission - out",
  "### END RULES ###",
  "",
}, "\n"), nil, true)
eq("rules: sapp rule is separate", #sappRules, 3)
eq("rules: sapp parsed", sappRules[2].sapp, "WWW")
eq("rules: sapp in id", sappRules[2].id, "allow|in|tcp|80|any||any|||0|WWW")
check("rules: sapp changes id", sappRules[1].id ~= sappRules[2].id)
eq("rules: no sapp is nil", sappRules[1].sapp, nil)
eq("rules: log-all parsed", sappRules[3].log, "log-all")
eq("rules: log-all action stripped", sappRules[3].action, "allow")
eq("rules: dapp with space", sappRules[3].app, "Mail submission")
eq("rules: no log is nil", sappRules[1].log, nil)
eq("rules: lone app rule has appTuples 1", list[13].appTuples, 1)
eq("rules: plain rule has no appTuples", list[1].appTuples, nil)
local xmpp = rules.parseRules(table.concat({
  "### tuple ### allow tcp 5222 0.0.0.0/0 any 0.0.0.0/0 XMPP - in",
  "### tuple ### allow tcp 5269 0.0.0.0/0 any 0.0.0.0/0 XMPP - in",
  "### tuple ### allow tcp 5222 0.0.0.0/0 any 192.0.2.0/24 XMPP - in",
  "### END RULES ###",
  "",
}, "\n"), "### tuple ### allow tcp 5222 ::/0 any ::/0 XMPP - in\n### tuple ### allow tcp 5269 ::/0 any ::/0 XMPP - in\n### END RULES ###\n", true)
eq("rules: multi-tuple app rows", #xmpp, 3)
eq("rules: multi-tuple app appTuples", xmpp[1].appTuples, 2)
eq("rules: multi-tuple app appTuples sibling", xmpp[2].appTuples, 2)
eq("rules: same app from elsewhere is its own tuple", xmpp[3].appTuples, 1)
local withRoute = rules.parseRules("### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 WWW - in\n"
  .. "### tuple ### route:allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 WWW - in\n### END RULES ###\n", nil, true)
eq("rules: a route rule for the same app shares the app tuple", withRoute[1].appTuples, 2)
eq("rules: v4 and v6 share id", list[1].id, rules.ruleId({ action = "allow", direction = "in", proto = "tcp", port = "80", from = "0.0.0.0/0", to = "::/0" }))

-- parseDump
local dump = table.concat({
  "@@op 1 ok",
  "@@msg something",
  "@@file conf",
  "ENABLED=yes",
  "LOGLEVEL=low",
  "@@file defaults",
  "IPV6=no",
  "@@file v4",
  "### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 in",
  "### END RULES ###",
  "@@end",
  "",
}, "\n")
local parts = rules.parseDump(dump)
eq("rules: parseDump conf", parts.conf, "ENABLED=yes\nLOGLEVEL=low\n")
eq("rules: parseDump defaults", parts.defaults, "IPV6=no\n")
eq("rules: parseDump v4", parts.v4, "### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 in\n### END RULES ###\n")
eq("rules: parseDump missing section is nil", parts.v6, nil)
local cut = rules.parseDump("@@file conf\nENABLED=no\n")
eq("rules: parseDump without @@end keeps content", cut.conf, "ENABLED=no\n")
