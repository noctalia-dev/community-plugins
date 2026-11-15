-- commands.luau: validation, staging, ufw argv building, the batch script and pkexec results.
local commands = loadModule("commands.luau")
local rules = loadModule("rules.luau")

local US = string.char(31)

local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  for k in pairs(a) do
    if type(k) ~= "number" then
      return false
    end
  end
  return true
end

local function show(t)
  if type(t) ~= "table" then
    return tostring(t)
  end
  local parts = {}
  for i = 1, #t do
    parts[i] = string.format("%q", tostring(t[i]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function argvEq(name, actual, expected)
  if same(actual, expected) then
    check(name, true)
  else
    check(name .. " (got " .. show(actual) .. ", want " .. show(expected) .. ")", false)
  end
end

local function parseOne(tuples, v6tuples)
  local v4 = table.concat(tuples, "\n") .. "\n### END RULES ###\n"
  local v6 = nil
  if v6tuples ~= nil then
    v6 = table.concat(v6tuples, "\n") .. "\n### END RULES ###\n"
  end
  local list = rules.parseRules(v4, v6, true)
  return list[1]
end

---------------------------------------------------------------------------
-- validateAdd: Review Focus #4
local VALID = {
  { " 43119 ", "both", nil, 43119, "both", nil },
  { "043119", "both", nil, 43119, "both", nil },
  { "43119", "both", nil, 43119, "both", nil },
  { "53", "udp", nil, 53, "udp", nil },
  { "8080", "tcp", "api dev server", 8080, "tcp", "api dev server" },
  { "1", "tcp", "", 1, "tcp", nil },
  { "65535", "udp", "   ", 65535, "udp", nil },
  { "22", "tcp", "  trimmed  ", 22, "tcp", "trimmed" },
  { "443", "both", string.rep("a", 64), 443, "both", string.rep("a", 64) },
  { "443", "both", "on", 443, "both", "on" },
  { "443", "both", "x in y", 443, "both", "x in y" },
}
for i, case in ipairs(VALID) do
  local op, err = commands.validateAdd(case[1], case[2], case[3])
  local tag = "commands: validateAdd valid " .. i .. " "
  check(tag .. "ok", op ~= nil and err == nil)
  if op ~= nil then
    eq(tag .. "port", op.port, case[4])
    eq(tag .. "proto", op.proto, case[5])
    eq(tag .. "comment", op.comment, case[6])
  end
end

local INVALID = {
  { "43119/tcp", "both", nil, "add.error_proto_in_port" },
  { "43119/udp", "tcp", nil, "add.error_proto_in_port" },
  { "/", "both", nil, "add.error_proto_in_port" },
  { "0", "both", nil, "add.error_port" },
  { "00", "both", nil, "add.error_port" },
  { "65536", "both", nil, "add.error_port" },
  { "99999999999999999999", "both", nil, "add.error_port" },
  { "abc", "both", nil, "add.error_port" },
  { "", "both", nil, "add.error_port" },
  { "   ", "both", nil, "add.error_port" },
  { "-1", "both", nil, "add.error_port" },
  { "+80", "both", nil, "add.error_port" },
  { "80.0", "both", nil, "add.error_port" },
  { "0x50", "both", nil, "add.error_port" },
  { "80 81", "both", nil, "add.error_port" },
  { "80,443", "both", nil, "add.error_port" },
  { "60000:60010", "both", nil, "add.error_port" },
  { nil, "both", nil, "add.error_port" },
  { 43119, "both", nil, "add.error_port" },
  { "43119", "both", "it's", "add.error_comment" },
  { "43119", "both", 'say "hi"', "add.error_comment" },
  { "43119", "both", "back\\slash", "add.error_comment" },
  { "43119", "both", "tab\there", "add.error_comment" },
  { "43119", "both", "new\nline", "add.error_comment" },
  { "43119", "both", "caf\195\169", "add.error_comment" },
  { "43119", "both", "del\127", "add.error_comment" },
  { "43119", "both", "unit" .. US .. "sep", "add.error_comment" },
  { "43119", "both", string.rep("a", 65), "add.error_comment" },
  -- ufw itself refuses these as the whole comment (found in the sandbox)
  { "43119", "both", "in", "add.error_comment" },
  { "43119", "both", "out", "add.error_comment" },
  { "43119", "both", "log", "add.error_comment" },
  { "43119", "both", "log-all", "add.error_comment" },
  { "43119", "both", " IN ", "add.error_comment" },
  -- ufw's launcher strips any argv starting with --rootdir= / --datadir=, so no leading '-'
  { "43119", "both", "--rootdir=/tmp/x", "add.error_comment" },
  { "43119", "both", "-h", "add.error_comment" },
  { "43119", "both", 42, "add.error_comment" },
  { "43119", "sctp", nil, "add.error_proto" },
}
for i, case in ipairs(INVALID) do
  local op, err = commands.validateAdd(case[1], case[2], case[3])
  eq("commands: validateAdd invalid " .. i .. " " .. string.format("%q", tostring(case[1])), err, case[4])
  check("commands: validateAdd invalid " .. i .. " gives no op", op == nil)
end

-- oversized raw input is refused before trimming (trim must stay cheap on ufw.request input)
local hugeSpaces = string.rep(" ", 20000)
local clock = os.clock()
local _, eHugePort = commands.validateAdd(hugeSpaces .. "43119" .. hugeSpaces, "tcp", nil)
local _, eHugeComment = commands.validateAdd("43119", "tcp", hugeSpaces .. "x" .. hugeSpaces)
local _, eHugeComment2 = commands.validateAdd("43119", "tcp", string.rep("a", 20000))
eq("commands: validateAdd 20 KB port rejected", eHugePort, "add.error_port")
eq("commands: validateAdd 20 KB comment rejected", eHugeComment, "add.error_comment")
eq("commands: validateAdd 20 KB plain comment rejected", eHugeComment2, "add.error_comment")
local okPadded = commands.validateAdd(string.rep(" ", 120) .. "43119" .. string.rep(" ", 120), "tcp", string.rep(" ", 100) .. "x" .. string.rep(" ", 100))
check("commands: validateAdd padding under the cap still trims", okPadded ~= nil and okPadded.port == 43119 and okPadded.comment == "x")
local _, eCap = commands.validateAdd(string.rep("1", 257), "tcp", nil)
eq("commands: validateAdd 257-byte port rejected", eCap, "add.error_port")
check("commands: validateAdd on 20 KB input is fast", os.clock() - clock < 0.05)

local nilProto = commands.validateAdd("43119", nil, nil)
eq("commands: validateAdd nil proto means both", nilProto and nilProto.proto, "both")

---------------------------------------------------------------------------
-- addArgs
argvEq("commands: addArgs both", commands.addArgs({ kind = "add", port = 43119, proto = "both" }), { "rule", "allow", "43119" })
argvEq("commands: addArgs tcp", commands.addArgs({ kind = "add", port = 43119, proto = "tcp" }), { "rule", "allow", "43119/tcp" })
argvEq("commands: addArgs udp", commands.addArgs({ kind = "add", port = 53, proto = "udp" }), { "rule", "allow", "53/udp" })
argvEq("commands: addArgs comment", commands.addArgs({ kind = "add", port = 8080, proto = "tcp", comment = "api dev server" }),
  { "rule", "allow", "8080/tcp", "comment", "api dev server" })

---------------------------------------------------------------------------
-- deleteArgs for every fixture shape (shapes.rules + shapes6.rules, file order)
local list = rules.parseRules(fixture("shapes.rules"), fixture("shapes6.rules"), true)
local DELETES = {
  { "delete", "allow", "in", "proto", "tcp", "from", "any", "to", "any", "port", "80" },
  { "delete", "allow", "in", "proto", "udp", "from", "any", "to", "any", "port", "5173" },
  { "delete", "allow", "in", "proto", "tcp", "from", "any", "to", "any", "port", "8080" },
  { "delete", "allow", "in", "proto", "tcp", "from", "192.0.2.0/24", "to", "0.0.0.0/0", "port", "22" },
  { "delete", "allow", "in", "from", "198.51.100.7", "to", "0.0.0.0/0" },
  { "delete", "limit", "in", "proto", "tcp", "from", "any", "to", "any", "port", "22" },
  { "delete", "deny", "in", "from", "any", "to", "any", "port", "4444" },
  { "delete", "reject", "in", "proto", "udp", "from", "any", "to", "any", "port", "4445" },
  { "delete", "allow", "in", "proto", "tcp", "from", "any", "to", "any", "port", "60000:60010" },
  { "delete", "allow", "in", "proto", "tcp", "from", "any", "to", "any", "port", "80,443" },
  { "delete", "allow", "in", "on", "eth9", "from", "any", "to", "any", "port", "43117" },
  { "delete", "allow", "out", "from", "any", "to", "any", "port", "43118" },
  { "delete", "allow", "in", "from", "any", "to", "any", "app", "WWW" },
  { "route", "delete", "allow", "in", "on", "eth9", "out", "on", "eth8", "from", "any", "to", "any" },
  { "delete", "allow", "in", "proto", "tcp", "from", "2001:db8::/32", "to", "::/0", "port", "2222" },
}
eq("commands: fixture shape count", #list, #DELETES)
for i, rule in ipairs(list) do
  local want = DELETES[i]
  if want == false then
    eq("commands: deleteArgs shape " .. i .. " is nil", commands.deleteArgs(rule), nil)
    eq("commands: shape " .. i .. " not removable", commands.isRemovableShape(rule), false)
  else
    argvEq("commands: deleteArgs shape " .. i, commands.deleteArgs(rule), want)
    eq("commands: shape " .. i .. " removable", commands.isRemovableShape(rule), true)
  end
end

-- extra shapes (also round-tripped in spec_sandbox.py)
local EXTRA = {
  { "log", { "### tuple ### allow_log tcp 41001 0.0.0.0/0 any 0.0.0.0/0 in" },
    { "### tuple ### allow_log tcp 41001 ::/0 any ::/0 in" },
    { "delete", "allow", "in", "log", "proto", "tcp", "from", "any", "to", "any", "port", "41001" } },
  { "log-all on iface", { "### tuple ### allow_log-all any 41002 0.0.0.0/0 any 0.0.0.0/0 in_eth9" },
    { "### tuple ### allow_log-all any 41002 ::/0 any ::/0 in_eth9" },
    { "delete", "allow", "in", "on", "eth9", "log-all", "from", "any", "to", "any", "port", "41002" } },
  { "v4-only anywhere", { "### tuple ### allow tcp 41003 0.0.0.0/0 any 0.0.0.0/0 in" }, nil,
    { "delete", "allow", "in", "proto", "tcp", "from", "0.0.0.0/0", "to", "0.0.0.0/0", "port", "41003" } },
  { "v6-only anywhere", nil, { "### tuple ### allow udp 41004 ::/0 any ::/0 in" },
    { "delete", "allow", "in", "proto", "udp", "from", "::/0", "to", "::/0", "port", "41004" } },
  { "source port", { "### tuple ### allow udp 41006 0.0.0.0/0 41005 192.0.2.0/24 in" }, nil,
    { "delete", "allow", "in", "proto", "udp", "from", "192.0.2.0/24", "port", "41005", "to", "0.0.0.0/0", "port", "41006" } },
  { "destination address", { "### tuple ### allow tcp 41007 10.0.0.0/8 any 0.0.0.0/0 in" }, nil,
    { "delete", "allow", "in", "proto", "tcp", "from", "0.0.0.0/0", "to", "10.0.0.0/8", "port", "41007" } },
  { "app with space", { "### tuple ### allow tcp 80,443 0.0.0.0/0 any 0.0.0.0/0 WWW%20Full - in" },
    { "### tuple ### allow tcp 80,443 ::/0 any ::/0 WWW%20Full - in" },
    { "delete", "allow", "in", "from", "any", "to", "any", "app", "WWW Full" } },
  { "out on iface", { "### tuple ### deny any 41008 0.0.0.0/0 any 0.0.0.0/0 out_eth9" },
    { "### tuple ### deny any 41008 ::/0 any ::/0 out_eth9" },
    { "delete", "deny", "out", "on", "eth9", "from", "any", "to", "any", "port", "41008" } },
  { "route one iface with port", { "### tuple ### route:allow tcp 41009 0.0.0.0/0 any 0.0.0.0/0 in_eth9" },
    { "### tuple ### route:allow tcp 41009 ::/0 any ::/0 in_eth9" },
    { "route", "delete", "allow", "in", "on", "eth9", "proto", "tcp", "from", "any", "to", "any", "port", "41009" } },
}
for _, case in ipairs(EXTRA) do
  local rule
  if case[2] == nil then
    rule = rules.parseRules("### END RULES ###\n", table.concat(case[3], "\n") .. "\n### END RULES ###\n", true)[1]
  else
    rule = parseOne(case[2], case[3])
  end
  argvEq("commands: deleteArgs " .. case[1], commands.deleteArgs(rule), case[4])
  eq("commands: " .. case[1] .. " removable", commands.isRemovableShape(rule), true)
end

-- not removable
local xmppRules = rules.parseRules("### tuple ### allow tcp 5222 0.0.0.0/0 any 0.0.0.0/0 XMPP - in\n"
  .. "### tuple ### allow tcp 5269 0.0.0.0/0 any 0.0.0.0/0 XMPP - in\n### END RULES ###\n", nil, true)
eq("commands: multi-tuple app rule not removable", commands.isRemovableShape(xmppRules[1]), false)
eq("commands: multi-tuple app rule has no deleteArgs", commands.deleteArgs(xmppRules[2]), nil)
local bareApp = { action = "allow", direction = "in", proto = "tcp", port = "80", app = "WWW", from = "any", to = "any", route = false, v4 = true, v6 = true }
eq("commands: app rule without appTuples not removable", commands.isRemovableShape(bareApp), false)
local sappRule = parseOne({ "### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 - WWW in" })
eq("commands: source-app rule not removable", commands.isRemovableShape(sappRule), false)
eq("commands: source-app rule has no deleteArgs", commands.deleteArgs(sappRule), nil)
local esp = parseOne({ "### tuple ### allow esp any 0.0.0.0/0 any 192.0.2.0/24 in" })
eq("commands: esp rule not removable", commands.isRemovableShape(esp), false)
local appPort = parseOne({ "### tuple ### allow tcp 80 0.0.0.0/0 41010 0.0.0.0/0 WWW - in" })
eq("commands: app with source port not removable", commands.isRemovableShape(appPort), false)
local dashIface = parseOne({ "### tuple ### allow any 41011 0.0.0.0/0 any 0.0.0.0/0 in_--rootdir=/x" })
check("commands: dash iface tuple parsed", dashIface ~= nil and dashIface.iface == "--rootdir=/x")
eq("commands: iface starting with - has no deleteArgs", commands.deleteArgs(dashIface), nil)
eq("commands: iface starting with - not removable", commands.isRemovableShape(dashIface), false)
local usApp = parseOne({ "### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 W" .. US .. "W - in" })
check("commands: unit separator app tuple parsed", usApp ~= nil and usApp.app == "W" .. US .. "W" and usApp.appTuples == 1)
eq("commands: unit separator in a field has no deleteArgs", commands.deleteArgs(usApp), nil)
eq("commands: deleteArgs nil rule", commands.deleteArgs(nil), nil)

---------------------------------------------------------------------------
-- stage
local base = rules.parseRules(fixture("simple-v4v6.rules"), fixture("simple-v6.rules"), true) -- allow 49152 (any)
local tcp43119 = parseOne({ "### tuple ### allow tcp 43119 0.0.0.0/0 any 0.0.0.0/0 in" }, { "### tuple ### allow tcp 43119 ::/0 any ::/0 in" })
local any43119 = parseOne({ "### tuple ### allow any 43119 0.0.0.0/0 any 0.0.0.0/0 in" }, { "### tuple ### allow any 43119 ::/0 any ::/0 in" })
local current = { base[1], tcp43119 }

local p1, e1 = commands.stage({}, current, { action = "stage_add", port = " 3001 ", proto = "udp", comment = " hi " }, "op1")
eq("commands: stage add ok", e1, nil)
eq("commands: stage add count", #p1, 1)
eq("commands: stage add id", p1[1].id, "op1")
eq("commands: stage add kind", p1[1].kind, "add")
eq("commands: stage add port", p1[1].port, 3001)
eq("commands: stage add proto", p1[1].proto, "udp")
eq("commands: stage add comment", p1[1].comment, "hi")

local pNum, eNum = commands.stage({}, current, { action = "stage_add", port = 3005, proto = "tcp" }, "n")
eq("commands: stage add accepts a JSON number port", eNum, nil)
eq("commands: stage add number port value", pNum[1] and pNum[1].port, 3005)
local _, eFrac = commands.stage({}, current, { action = "stage_add", port = 30.5, proto = "tcp" }, "n")
eq("commands: stage add rejects a fractional number port", eFrac, "add.error_port")
local _, eHuge = commands.stage({}, current, { action = "stage_add", port = 1e300, proto = "tcp" }, "n")
eq("commands: stage add rejects a huge number port", eHuge, "add.error_port")
local _, eInvalid = commands.stage({}, current, { action = "stage_add", port = "43119/tcp", proto = "both" }, "x")
eq("commands: stage add invalid port", eInvalid, "add.error_proto_in_port")

local pDup, eDup = commands.stage({}, current, { action = "stage_add", port = "43119", proto = "tcp" }, "x")
eq("commands: stage duplicate of existing", eDup, "add.error_exists")
eq("commands: stage duplicate leaves pending", #pDup, 0)
local _, eAnyVsTcp = commands.stage({}, current, { action = "stage_add", port = "49152", proto = "tcp" }, "x")
eq("commands: stage tcp overlaps existing any", eAnyVsTcp, "add.error_exists")
local _, eOverlap = commands.stage({}, current, { action = "stage_add", port = "43119", proto = "both" }, "x")
eq("commands: stage both overlaps existing tcp", eOverlap, "add.error_exists")
local _, eOverlapAny = commands.stage({}, { any43119 }, { action = "stage_add", port = "43119", proto = "tcp" }, "x")
eq("commands: stage 43119/tcp overlaps existing 43119", eOverlapAny, "add.error_exists")
local _, eUdpOk = commands.stage({}, current, { action = "stage_add", port = "43119", proto = "udp" }, "x")
eq("commands: stage udp next to tcp ok", eUdpOk, nil)
local _, ePendDup = commands.stage(p1, current, { action = "stage_add", port = "3001", proto = "both" }, "x")
eq("commands: stage overlaps pending add", ePendDup, "add.error_exists")
local _, ePendSame = commands.stage(p1, current, { action = "stage_add", port = "03001", proto = "udp" }, "x")
eq("commands: stage duplicates pending add", ePendSame, "add.error_exists")
local _, eFromNotPlain = commands.stage({}, { list[4] }, { action = "stage_add", port = "22", proto = "tcp" }, "x")
eq("commands: source-limited rule is not a duplicate", eFromNotPlain, nil)

local pR, eR = commands.stage(p1, current, { action = "stage_remove", rule = tcp43119.id }, "op2")
eq("commands: stage remove ok", eR, nil)
eq("commands: stage remove count", #pR, 2)
eq("commands: stage remove kind", pR[2].kind, "remove")
eq("commands: stage remove ruleId", pR[2].ruleId, tcp43119.id)
eq("commands: stage remove id", pR[2].id, "op2")
eq("commands: stage does not mutate input", #p1, 1)
local pR2, eR2 = commands.stage(pR, current, { action = "stage_remove", rule = tcp43119.id }, "op3")
eq("commands: double remove no error", eR2, nil)
eq("commands: double remove does nothing", #pR2, 2)

local _, eGone = commands.stage({}, current, { action = "stage_remove", rule = "allow|in|tcp|1|any||any|||0|" }, "x")
eq("commands: stage remove unknown rule", eGone, "error.not_removable")
local pNR, eNR = commands.stage({}, { sappRule }, { action = "stage_remove", rule = sappRule.id }, "x")
eq("commands: stage remove unremovable", eNR, "error.not_removable")
eq("commands: stage remove unremovable leaves pending", #pNR, 0)

local pU = commands.stage(pR, current, { action = "unstage", id = "op1" }, "x")
eq("commands: unstage add removes it", #pU, 1)
eq("commands: unstage keeps the other", pU[1].id, "op2")
local pU2 = commands.stage(pU, current, { action = "unstage", id = "op2" }, "x")
eq("commands: unstage remove", #pU2, 0)
local pU3 = commands.stage(pR, current, { action = "unstage", id = "nope" }, "x")
eq("commands: unstage unknown id does nothing", #pU3, 2)
local pNum = commands.stage({ { id = "12", kind = "add", port = 3001, proto = "tcp" } }, current, { action = "unstage", id = 12 }, "x")
eq("commands: unstage takes a JSON-number id", #pNum, 0)
local pFrac = commands.stage({ { id = "12", kind = "add", port = 3001, proto = "tcp" } }, current, { action = "unstage", id = 12.5 }, "x")
eq("commands: unstage with a fractional id does nothing", #pFrac, 1)
local _, eProto = commands.stage({}, current, { action = "stage_add", port = "3001", proto = "sctp" }, "x")
eq("commands: stage add with a bad proto names the proto", eProto, "add.error_proto")

local pD, eD = commands.stage(pR, current, { action = "discard" }, "x")
eq("commands: discard empties", #pD, 0)
eq("commands: discard ok", eD, nil)
local pX, eX = commands.stage(pR, current, { action = "nonsense" }, "x")
eq("commands: unknown stage action", eX, "error.unknown_action")
eq("commands: unknown stage action keeps pending", #pX, 2)

---------------------------------------------------------------------------
-- reconcile
local pending = {
  { id = "a", kind = "add", port = 43119, proto = "tcp" },  -- now exists (tcp43119)
  { id = "b", kind = "add", port = 3002, proto = "both" }, -- still new
  { id = "c", kind = "remove", ruleId = base[1].id },      -- still there
  { id = "d", kind = "remove", ruleId = any43119.id },      -- vanished
}
local rec, dropped = commands.reconcile(pending, current, true)
eq("commands: reconcile dropped count", dropped, 2)
eq("commands: reconcile kept count", #rec, 2)
eq("commands: reconcile keeps new add", rec[1].id, "b")
eq("commands: reconcile keeps live remove", rec[2].id, "c")
local _, nowUnremovable = commands.reconcile({ { id = "u", kind = "remove", ruleId = xmppRules[1].id } }, xmppRules)
eq("commands: reconcile drops a remove whose rule became unremovable", nowUnremovable, 1)
local _, none = commands.reconcile({}, current, true)
eq("commands: reconcile nothing", none, 0)

-- applied: what a `written` result (ufw stopped) must show in the dump to count as saved
local tcp43119v4 = parseOne({ "### tuple ### allow tcp 43119 0.0.0.0/0 any 0.0.0.0/0 in" }, {})
local deny43119 = parseOne({ "### tuple ### deny tcp 43119 0.0.0.0/0 any 0.0.0.0/0 in" }, { "### tuple ### deny tcp 43119 ::/0 any ::/0 in" })
local addTcp = { id = "a", kind = "add", port = 43119, proto = "tcp" }
eq("commands: applied add with both copies", commands.applied(addTcp, current, true), true)
eq("commands: applied add needs the IPv6 copy", commands.applied(addTcp, { tcp43119v4 }, true), false)
eq("commands: applied add with IPv6 off needs only v4", commands.applied(addTcp, { tcp43119v4 }, false), true)
eq("commands: applied add needs the same protocol", commands.applied({ id = "a", kind = "add", port = 43119, proto = "udp" }, current, true), false)
eq("commands: applied add both is not a tcp rule", commands.applied({ id = "a", kind = "add", port = 43119, proto = "both" }, current, true), false)
eq("commands: applied add both", commands.applied({ id = "a", kind = "add", port = 43119, proto = "both" }, { any43119 }, true), true)
eq("commands: applied add is not a deny", commands.applied(addTcp, { deny43119 }, true), false)
eq("commands: applied add missing", commands.applied({ id = "a", kind = "add", port = 3009, proto = "tcp" }, current, true), false)
eq("commands: applied remove gone", commands.applied({ id = "r", kind = "remove", ruleId = any43119.id }, current, true), true)
eq("commands: applied remove still there", commands.applied({ id = "r", kind = "remove", ruleId = tcp43119.id }, current, true), false)
eq("commands: applied remove with one copy left", commands.applied({ id = "r", kind = "remove", ruleId = tcp43119.id }, { tcp43119v4 }, true), false)
eq("commands: applied nil op", commands.applied(nil, current, true), false)
local limit43119 = parseOne({ "### tuple ### limit tcp 43119 0.0.0.0/0 any 0.0.0.0/0 in" }, { "### tuple ### limit tcp 43119 ::/0 any ::/0 in" })
local logged43119 = parseOne({ "### tuple ### allow_log tcp 43119 0.0.0.0/0 any 0.0.0.0/0 in" }, { "### tuple ### allow_log tcp 43119 ::/0 any ::/0 in" })
eq("commands: applied add is not a limit", commands.applied(addTcp, { limit43119 }, true), false)
eq("commands: applied add is not a logged allow", commands.applied(addTcp, { logged43119 }, true), false)
-- before: the rules the Save started from. A rule that was already on that port and protocol
-- (a deny or limit ufw turns into this allow) means the add replaced it: not counted.
eq("commands: applied add over a deny is not counted", commands.applied(addTcp, current, true, { deny43119 }), false)
eq("commands: applied add over a limit is not counted", commands.applied(addTcp, current, true, { limit43119 }), false)
eq("commands: applied add with an unrelated before", commands.applied(addTcp, current, true, { base[1], any43119 }), true)
eq("commands: applied remove ignores before", commands.applied({ id = "r", kind = "remove", ruleId = any43119.id }, current, true, { any43119 }), true)

-- reconcile uses the same exact test as applied
local addBoth = { id = "b", kind = "add", port = 43119, proto = "tcp" }
local _, keptV4 = commands.reconcile({ addBoth }, { tcp43119v4 }, true)
eq("commands: reconcile keeps an add whose IPv6 copy is missing", keptV4, 0)
local _, droppedV4 = commands.reconcile({ addBoth }, { tcp43119v4 }, false)
eq("commands: reconcile drops it with IPv6 off", droppedV4, 1)
local keptDeny, deniedDropped = commands.reconcile({ addBoth }, { deny43119 }, true)
eq("commands: reconcile keeps an add whose port has a deny rule", deniedDropped .. "/" .. #keptDeny, "0/1")
local _, limitDropped = commands.reconcile({ addBoth }, { limit43119, logged43119 }, true)
eq("commands: reconcile keeps an add whose port has a limit or logged rule", limitDropped, 0)
local notLive = {
  { id = "n1", kind = "add", port = 43119, proto = "tcp", notLive = true },
  { id = "n2", kind = "remove", ruleId = "gone", notLive = true },
}
local _, notLiveDropped = commands.reconcile(notLive, current, true)
eq("commands: reconcile keeps notLive ops", notLiveDropped, 0)

---------------------------------------------------------------------------
-- saveArgv
local byId = {}
for _, r in ipairs(current) do
  byId[r.id] = r
end
local savePending = {
  { id = "a1", kind = "add", port = 8080, proto = "tcp", comment = "api dev server" },
  { id = "r1", kind = "remove", ruleId = tcp43119.id },
  { id = "a2", kind = "add", port = 53, proto = "udp" },
  { id = "r2", kind = "remove", ruleId = base[1].id },
}
local save, order = commands.saveArgv(savePending, byId)
eq("commands: saveArgv pkexec", save[1], "pkexec")
eq("commands: saveArgv sh", save[2], "/bin/sh")
eq("commands: saveArgv -c", save[3], "-c")
check("commands: saveArgv script", save[4] == commands.BATCH_SCRIPT)
eq("commands: saveArgv $0", save[5], "ufw-batch")
eq("commands: saveArgv op count", #save, 9)
eq("commands: saveArgv remove 1 first", save[6], table.concat({ "delete", "allow", "in", "proto", "tcp", "from", "any", "to", "any", "port", "43119" }, US))
eq("commands: saveArgv remove 2 second", save[7], table.concat({ "delete", "allow", "in", "from", "any", "to", "any", "port", "49152" }, US))
eq("commands: saveArgv add 1 third", save[8], table.concat({ "rule", "allow", "8080/tcp", "comment", "api dev server" }, US))
eq("commands: saveArgv add 2 fourth", save[9], table.concat({ "rule", "allow", "53/udp" }, US))
for i = 6, 9 do
  check("commands: saveArgv op " .. (i - 5) .. " is one element with \\31", type(save[i]) == "string" and string.find(save[i], US, 1, true) ~= nil)
end
argvEq("commands: saveArgv op order", order, { "r1", "r2", "a1", "a2" })
local skip, skipOrder, skipDropped = commands.saveArgv({
  { id = "g", kind = "remove", ruleId = "gone" },
  { id = "s", kind = "remove", ruleId = sappRule.id },
  { id = "a", kind = "add", port = 1, proto = "tcp" },
  { id = "bad", kind = "add", port = 0, proto = "tcp" },
  { id = "frac", kind = "add", port = 1.5, proto = "tcp" },
  { id = "c", kind = "add", port = 2, proto = "tcp", comment = "in" },
}, { [sappRule.id] = sappRule })
eq("commands: saveArgv skips a remove with no rule", #skip, 6)
argvEq("commands: saveArgv order skips it too", skipOrder, { "a" })
argvEq("commands: saveArgv reports dropped ops", skipDropped, { "g", "s", "bad", "frac", "c" })
local _, _, noneDropped = commands.saveArgv(savePending, byId)
argvEq("commands: saveArgv nothing dropped", noneDropped, {})
local floaty = commands.saveArgv({ { id = "f", kind = "add", port = 43119.0, proto = "tcp" } }, byId)
eq("commands: saveArgv port without a decimal point", floaty[6], table.concat({ "rule", "allow", "43119/tcp" }, US))
eq("commands: saveArgv drops an invalid add", #commands.saveArgv({ { id = "z", kind = "add", port = 0, proto = "tcp" } }, byId), 5)
eq("commands: saveArgv drops a fractional port", #commands.saveArgv({ { id = "z", kind = "add", port = 80.5, proto = "tcp" } }, byId), 5)
eq("commands: saveArgv drops a huge port", #commands.saveArgv({ { id = "z", kind = "add", port = 1e300, proto = "tcp" } }, byId), 5)
eq("commands: saveArgv empty is a dump", #commands.saveArgv({}, byId), 5)

---------------------------------------------------------------------------
-- parseBatch
local DUMP = "@@file conf\nENABLED=yes\n@@file defaults\nIPV6=yes\n@@file v4\n### END RULES ###\n@@file v6\n### END RULES ###\n@@end\n"
local allOk = commands.parseBatch("@@op 1 ok\n@@op 2 ok\n@@op 3 ok\n" .. DUMP)
eq("commands: parseBatch all ok complete", allOk.complete, true)
eq("commands: parseBatch all ok count", #allOk.results, 3)
check("commands: parseBatch all ok each", allOk.results[1].ok and allOk.results[2].ok and allOk.results[3].ok)
eq("commands: parseBatch dump conf", allOk.dump.conf, "ENABLED=yes\n")
eq("commands: parseBatch dump v6", allOk.dump.v6, "### END RULES ###\n")

local mid = commands.parseBatch("@@op 1 ok\n@@op 2 fail 1\n@@msg ERROR: Bad port\n@@msg second line\n" .. DUMP)
eq("commands: parseBatch failure complete", mid.complete, true)
eq("commands: parseBatch op 1 ok", mid.results[1].ok, true)
eq("commands: parseBatch op 2 failed", mid.results[2].ok, false)
eq("commands: parseBatch op 2 code", mid.results[2].code, 1)
eq("commands: parseBatch op 2 msg", mid.results[2].msg, "ERROR: Bad port\nsecond line")
eq("commands: parseBatch op 3 has no result", mid.results[3], nil)
eq("commands: parseBatch failure dump v4", mid.dump.v4, "### END RULES ###\n")

local cut = commands.parseBatch("@@op 1 ok\n@@file conf\nENABLED=yes\n")
eq("commands: parseBatch missing @@end incomplete", cut.complete, false)
eq("commands: parseBatch missing @@end still has result", cut.results[1].ok, true)
eq("commands: parseBatch empty incomplete", commands.parseBatch("").complete, false)
eq("commands: parseBatch nil incomplete", commands.parseBatch(nil).complete, false)
eq("commands: parseBatch @@end not last is incomplete", commands.parseBatch("@@file conf\n@@end\nmore\n").complete, false)
local fileOp = commands.parseBatch("@@op 1 ok\n@@file conf\n@@op 2 ok\n@@op 1 fail 9\n@@msg x\nENABLED=yes\n@@file defaults\n@@end\n")
eq("commands: parseBatch ignores @@op lines inside files", fileOp.results[2], nil)
eq("commands: parseBatch file lines do not overwrite a result", fileOp.results[1].ok, true)
eq("commands: parseBatch file lines give no msg", fileOp.results[1].msg, nil)
local wr = commands.parseBatch("@@op 1 written 1\n@@msg ERROR: problem running\n@@op 2 ok\n" .. DUMP)
eq("commands: parseBatch written is not ok", wr.results[1].ok, false)
eq("commands: parseBatch written flag", wr.results[1].written, true)
eq("commands: parseBatch written code", wr.results[1].code, 1)
eq("commands: parseBatch written msg", wr.results[1].msg, "ERROR: problem running")
eq("commands: parseBatch op after written", wr.results[2].ok, true)
eq("commands: parseBatch fail has no written flag", mid.results[2].written, nil)
eq("commands: parseBatch zero-exit failure code",commands.parseBatch("@@op 1 fail 0\n@@msg Could not delete non-existent rule\n@@end\n").results[1].code, 0)

---------------------------------------------------------------------------
-- argv
local active = { hasSystemctl = true, unit = { active = "active" } }
local inactive = { hasSystemctl = true, unit = { active = "inactive" } }
local failed = { hasSystemctl = true, unit = { active = "failed" } }
local nosys = { hasSystemctl = false, unit = {} }
argvEq("commands: argv enable unit active", commands.argv("enable", active), { "pkexec", "ufw", "--force", "enable" })
argvEq("commands: argv enable no systemctl", commands.argv("enable", nosys), { "pkexec", "ufw", "--force", "enable" })
argvEq("commands: argv enable unit inactive", commands.argv("enable", inactive), { "pkexec", "/bin/sh", "-c", commands.ENABLE_AND_START })
argvEq("commands: argv enable unit failed", commands.argv("enable", failed), { "pkexec", "/bin/sh", "-c", commands.ENABLE_AND_START })
eq("commands: ENABLE_AND_START", commands.ENABLE_AND_START, "ufw --force enable && systemctl start ufw")
argvEq("commands: argv disable stops the unit", commands.argv("disable", active), { "pkexec", "systemctl", "stop", "ufw" })
argvEq("commands: argv disable without systemctl", commands.argv("disable", nosys), { "pkexec", "ufw", "disable" })
local stoppedSnap = { enabled = true, hasSystemctl = true, unit = { active = "inactive", bootEnabled = true } }
local failedSnap = { enabled = true, hasSystemctl = true, unit = { active = "failed", bootEnabled = true } }
local offSnap = { enabled = false, hasSystemctl = true, unit = { active = "inactive", bootEnabled = true } }
local offActive = { enabled = false, hasSystemctl = true, unit = { active = "active", bootEnabled = true } }
argvEq("commands: argv enable from stopped starts the unit", commands.argv("enable", stoppedSnap), { "pkexec", "systemctl", "start", "ufw" })
argvEq("commands: argv enable from failed restarts", commands.argv("enable", failedSnap), { "pkexec", "systemctl", "restart", "ufw" })
argvEq("commands: argv enable from not_running starts the unit",
  commands.argv("enable", { enabled = true, hasSystemctl = true, unit = { active = "inactive", bootEnabled = false } }),
  { "pkexec", "systemctl", "start", "ufw" })
argvEq("commands: argv enable from ENABLED=no inactive", commands.argv("enable", offSnap), { "pkexec", "/bin/sh", "-c", commands.ENABLE_AND_START })
argvEq("commands: argv enable from ENABLED=no active", commands.argv("enable", offActive), { "pkexec", "ufw", "--force", "enable" })
argvEq("commands: argv start_service", commands.argv("start_service", inactive), { "pkexec", "systemctl", "start", "ufw" })
argvEq("commands: argv start_service failed restarts", commands.argv("start_service", failed), { "pkexec", "systemctl", "restart", "ufw" })
argvEq("commands: argv enable_at_boot", commands.argv("enable_at_boot", active), { "pkexec", "systemctl", "enable", "ufw" })
argvEq("commands: argv load_rules", commands.argv("load_rules", active), { "pkexec", "/bin/sh", "-c", commands.BATCH_SCRIPT, "ufw-batch" })
argvEq("commands: argv enable_polkit_agent", commands.argv("enable_polkit_agent", active), { "noctalia", "msg", "config-set", "shell.polkit_agent", "true" })
eq("commands: argv unknown", commands.argv("reset", active), nil)
eq("commands: argv save is not an action", commands.argv("save", active), nil)

eq("commands: terminal enable", commands.TERMINAL_COMMANDS.enable, "sudo ufw --force enable")
eq("commands: terminal stop_service", commands.TERMINAL_COMMANDS.stop_service, "sudo systemctl stop ufw")
eq("commands: terminal disable_legacy", commands.TERMINAL_COMMANDS.disable_legacy, "sudo ufw disable")
eq("commands: terminal has no raw disable", commands.TERMINAL_COMMANDS.disable, nil)
eq("commands: terminal start_service", commands.TERMINAL_COMMANDS.start_service, "sudo systemctl start ufw")
eq("commands: terminal enable_at_boot", commands.TERMINAL_COMMANDS.enable_at_boot, "sudo systemctl enable ufw")
eq("commands: no terminal save", commands.TERMINAL_COMMANDS.save, nil)

eq("commands: terminalKey disable", commands.terminalKey("disable", active), "stop_service")
eq("commands: terminalKey disable no systemctl", commands.terminalKey("disable", nosys), "disable_legacy")
eq("commands: terminalKey enable from stopped", commands.terminalKey("enable", stoppedSnap), "start_service")
eq("commands: terminalKey enable from failed", commands.terminalKey("enable", failedSnap), "start_service")
eq("commands: terminalKey enable from ENABLED=no inactive", commands.terminalKey("enable", offSnap), "enable_and_start")
eq("commands: terminalKey enable from ENABLED=no active", commands.terminalKey("enable", offActive), "enable")
eq("commands: terminal enable_and_start", commands.TERMINAL_COMMANDS.enable_and_start,
  "sudo sh -c 'ufw --force enable && systemctl start ufw'")
eq("commands: terminal enable_and_start wraps ENABLE_AND_START", commands.TERMINAL_COMMANDS.enable_and_start,
  "sudo sh -c '" .. commands.ENABLE_AND_START .. "'")
eq("commands: terminalKey enable active", commands.terminalKey("enable", active), "enable")
eq("commands: terminalKey enable no systemctl", commands.terminalKey("enable", nosys), "enable")
eq("commands: terminalKey start_service", commands.terminalKey("start_service", inactive), "start_service")
eq("commands: terminalKey enable_at_boot", commands.terminalKey("enable_at_boot", active), "enable_at_boot")
eq("commands: terminalKey load_rules", commands.terminalKey("load_rules", active), nil)
eq("commands: terminalKey save", commands.terminalKey("save", active), nil)
eq("commands: terminalKey raw constant name", commands.terminalKey("stop_service", active), nil)
eq("commands: terminalKey odd", commands.terminalKey("__index", active), nil)
eq("commands: terminalKey nil", commands.terminalKey(nil, active), nil)

-- Turn on: the terminal command is always the same choice as the pkexec argv.
do
  local function argvKind(argv)
    local flat = table.concat(argv or {}, " ")
    if flat == "pkexec ufw --force enable" then return "enable" end
    if flat == "pkexec /bin/sh -c " .. commands.ENABLE_AND_START then return "enable_and_start" end
    if flat == "pkexec systemctl start ufw" or flat == "pkexec systemctl restart ufw" then return "start_service" end
    return "?" .. flat
  end
  local mismatches, cases = {}, 0
  -- NIL stands for an absent value (`x ~= "nil" and x or nil` would turn false into nil too)
  local NIL = {}
  local function value(x)
    if x == NIL then
      return nil
    end
    return x
  end
  local seen = { enabledFalse = 0, bootFalse = 0, enabledNil = 0, bootNil = 0 }
  for _, enabled in ipairs({ true, false, NIL }) do
    for _, sys in ipairs({ true, false }) do
      for _, active in ipairs({ "active", "inactive", "failed", "activating", NIL }) do
        for _, boot in ipairs({ true, false, NIL }) do
          local snapT = {
            enabled = value(enabled),
            hasSystemctl = sys,
            unit = { active = value(active), bootEnabled = value(boot) },
          }
          if snapT.enabled == false then seen.enabledFalse = seen.enabledFalse + 1 end
          if snapT.enabled == nil then seen.enabledNil = seen.enabledNil + 1 end
          if snapT.unit.bootEnabled == false then seen.bootFalse = seen.bootFalse + 1 end
          if snapT.unit.bootEnabled == nil then seen.bootNil = seen.bootNil + 1 end
          cases = cases + 1
          local fromArgv = argvKind(commands.argv("enable", snapT))
          local key = commands.terminalKey("enable", snapT)
          if fromArgv ~= key or commands.TERMINAL_COMMANDS[key] == nil then
            mismatches[#mismatches + 1] = tostring(value(enabled)) .. "/" .. tostring(sys) .. "/" .. tostring(value(active))
              .. "/" .. tostring(value(boot)) .. ": " .. fromArgv .. " vs " .. tostring(key)
          end
        end
      end
    end
  end
  eq("commands: terminalKey mirrors argv for every Turn on state (" .. cases .. " cases)", table.concat(mismatches, "; "), "")
  -- each of enabled / bootEnabled is false in a third of the cases and absent in another third
  eq("commands: Turn on matrix exercises ENABLED=no and boot=false",
    seen.enabledFalse .. "/" .. seen.bootFalse .. "/" .. seen.enabledNil .. "/" .. seen.bootNil, "30/30/30/30")
end

-- Turn off never touches the boot setting: no `systemctl disable` anywhere under ufw/.
do
  local dir = (arg and arg[0] or ""):gsub("tests/run%.lua$", "")
  if dir == "" then dir = "./" end
  -- whitespace and quotes are normalised: `"systemctl","disable"` and `'systemctl', 'disable'` count too
  local function mentionsBootDisable(text)
    local flat = text:gsub("[\"',%s]+", " ")
    return flat:find("systemctl disable", 1, true) ~= nil
  end
  eq("commands: scan catches the spaced form", mentionsBootDisable('x = "systemctl disable ufw"'), true)
  eq("commands: scan catches the argv form", mentionsBootDisable('{ "pkexec", "systemctl", "disable", "ufw" }'), true)
  eq("commands: scan catches the compact form", mentionsBootDisable("{'systemctl','disable'}"), true)
  eq("commands: scan ignores other systemctl calls", mentionsBootDisable('{ "systemctl", "stop", "ufw" }'), false)
  local names = {}
  local ls = io.popen('ls "' .. dir .. '"*.luau 2>/dev/null')
  for line in ls:lines() do names[#names + 1] = line end
  ls:close()
  check("commands: scan lists the modules", #names >= 7)
  local hits = 0
  for _, path in ipairs(names) do
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    check("commands: scanned " .. path, #text > 0)
    if mentionsBootDisable(text) then
      hits = hits + 1
    end
  end
  eq("commands: no systemctl disable anywhere", hits, 0)
end

---------------------------------------------------------------------------
-- classifyPkexec
eq("commands: pkexec ok", commands.classifyPkexec({ exitCode = 0, stdout = "", stderr = "", timedOut = false }), "ok")
eq("commands: pkexec timeout", commands.classifyPkexec({ exitCode = -1, stderr = "", timedOut = true }), "timeout")
eq("commands: pkexec cancelled", commands.classifyPkexec({ exitCode = 126, stderr = "Error executing command as another user: Not authorized", timedOut = false }), "cancelled")
eq("commands: pkexec 127 no agent", commands.classifyPkexec({ exitCode = 127, stderr = "", timedOut = false }), "no_agent")
eq("commands: pkexec agent text no agent", commands.classifyPkexec({ exitCode = 1, stderr = "Error executing command as another user: No Authentication Agent found.", timedOut = false }), "no_agent")
eq("commands: pkexec failed", commands.classifyPkexec({ exitCode = 1, stderr = "ERROR: x", timedOut = false }), "failed")

---------------------------------------------------------------------------
-- systemctl show
argvEq("commands: SYSTEMCTL_SHOW", commands.SYSTEMCTL_SHOW, { "systemctl", "show", "ufw", "--property=LoadState,ActiveState,UnitFileState" })
local sNF = commands.parseSystemctlShow("LoadState=not-found\nActiveState=inactive\nUnitFileState=\n")
eq("commands: show not-found unit is missing", sNF.missing, true)
eq("commands: show loaded unit is not missing", commands.parseSystemctlShow("LoadState=loaded\nActiveState=active\n").missing, false)
eq("commands: show without LoadState is not missing", commands.parseSystemctlShow("ActiveState=active\n").missing, false)
local s1 = commands.parseSystemctlShow("ActiveState=active\nUnitFileState=enabled\n")
eq("commands: show active", s1.active, "active")
eq("commands: show enabled", s1.bootEnabled, true)
local s2 = commands.parseSystemctlShow("UnitFileState=disabled\nActiveState=inactive\n")
eq("commands: show inactive", s2.active, "inactive")
eq("commands: show disabled", s2.bootEnabled, false)
local s3 = commands.parseSystemctlShow("ActiveState=failed\nUnitFileState=enabled\n")
eq("commands: show failed", s3.active, "failed")
local s4 = commands.parseSystemctlShow("")
eq("commands: show empty active", s4.active, nil)
eq("commands: show empty bootEnabled", s4.bootEnabled, nil)
eq("commands: show nil", commands.parseSystemctlShow(nil).active, nil)
local s5 = commands.parseSystemctlShow("ActiveState=inactive\nUnitFileState=\n")
eq("commands: show missing unit file state", s5.bootEnabled, nil)

---------------------------------------------------------------------------
-- BATCH_SCRIPT is constant
local script = commands.BATCH_SCRIPT
check("commands: BATCH_SCRIPT is a string", type(script) == "string" and #script > 100)
check("commands: BATCH_SCRIPT has no %s", string.find(script, "%s", 1, true) == nil)
check("commands: BATCH_SCRIPT has no ..", string.find(script, "..", 1, true) == nil)
check("commands: BATCH_SCRIPT runs ufw --force with \"$@\"", string.find(script, 'ufw --force "$@"', 1, true) ~= nil)
local root = ((arg and arg[0]) or ""):gsub("tests/run%.lua$", "")
if root == ((arg and arg[0]) or "") then
  root = "ufw/"
end
local srcFile = assert(io.open(root .. "commands.luau", "r"))
local src = srcFile:read("*a")
srcFile:close()
check("commands: BATCH_SCRIPT source is a long-string literal", string.find(src, "\nlocal BATCH_SCRIPT = %[=%[\n") ~= nil)
local body = string.match(src, "\nlocal BATCH_SCRIPT = %[=%[\n(.-)%]=%]\n")
check("commands: BATCH_SCRIPT equals its literal", body ~= nil and body == script)
check("commands: BATCH_SCRIPT assigned only from the literal", select(2, string.gsub(src, "BATCH_SCRIPT%s*=[^=]", "")) == 2
  and string.find(src, "\ncommands.BATCH_SCRIPT = BATCH_SCRIPT\n", 1, true) ~= nil)
check("commands: ENABLE_AND_START is a literal", string.find(src, 'local ENABLE_AND_START = "ufw --force enable && systemctl start ufw"\n', 1, true) ~= nil)

-- The README quotes BATCH_SCRIPT for reviewers: it must stay the exact script that runs.
do
  local readme = assert(io.open(root .. "README.md", "r"))
  local text = readme:read("*a")
  readme:close()
  local quoted = string.match(text, "\n```sh\n(PATH=.-\nexit \"%$status\"\n)```\n")
  check("commands: README quotes a BATCH_SCRIPT block", quoted ~= nil)
  check("commands: README's BATCH_SCRIPT equals commands.BATCH_SCRIPT", quoted == script)
  check("commands: README's ENABLE_AND_START equals the constant",
    string.find(text, 'pkexec /bin/sh -c "' .. commands.ENABLE_AND_START .. '"', 1, true) ~= nil)
  -- the stopped-state notice, quoted in both count forms, is the real en.json text
  local enFile = assert(io.open(root .. "translations/en.json", "r"))
  local en = assert(json.decode(enFile:read("*a")))
  enFile:close()
  local flat = string.gsub(text, "%s+", " ")
  for _, form in ipairs({ { "saved_not_live_one", "1" }, { "saved_not_live_other", "2" } }) do
    local wanted = string.gsub(en.notice[form[1]], "{n}", form[2])
    check("commands: README quotes notice." .. form[1] .. " exactly",
      string.find(flat, '"' .. wanted .. '"', 1, true) ~= nil)
  end
end
