-- parse.luau against scrubbed fixtures.
local parse = loadModule("parse.luau")

local function joined(list)
  return table.concat(list, ",")
end

-- show: disconnected
local rows, err = parse.show(fixture("show-disconnected.txt"))
eq("parse: show disconnected no error", err, nil)
eq("parse: show disconnected one row", rows and #rows, 1)
local c = rows[1]
eq("parse: show disconnected id", c.id, 0)
eq("parse: show disconnected status", c.status, "DISCONNECTED")
eq("parse: show disconnected authorized", c.authorized, true)
eq("parse: show disconnected host", c.host, "vpn.example.com")
eq("parse: show disconnected account", c.account, "user@example.com")
eq("parse: show disconnected dns count", #c.dns, 2)
eq("parse: show disconnected dns", joined(c.dns), "198.51.100.2,198.51.100.3")

-- show: multi
rows = parse.show(fixture("show-multi.txt"))
eq("parse: show multi rows", #rows, 3)
eq("parse: show multi status 1", rows[1].status, "CONNECTED")
eq("parse: show multi dns 1", joined(rows[1].dns), "198.51.100.2,198.51.100.3")
eq("parse: show multi status 2", rows[2].status, "DISCONNECTED")
eq("parse: show multi empty dns", #rows[2].dns, 0)
eq("parse: show multi name 2", rows[2].name, "Lab")
eq("parse: show multi host 2", rows[2].host, "vpn2.example.org")
eq("parse: show multi unauthorized", rows[3].authorized, false)
eq("parse: show multi no account", rows[3].account, nil)
eq("parse: show multi ids", rows[1].id + rows[2].id * 10 + rows[3].id * 100, 210)

-- show: other fixtures
eq("parse: connected fixture status", parse.show(fixture("show-connected.txt"))[1].status, "CONNECTED")
eq("parse: authorizing status", parse.show(fixture("show-authorizing.txt"))[1].status, "AUTHORIZING")
eq("parse: offline status", parse.show(fixture("show-offline.txt"))[1].status, "TEMPORARILY_OFFLINE")
eq("parse: unauthorized flag", parse.show(fixture("show-unauthorized.txt"))[1].authorized, false)

-- show: empty and garbage
local empty, emptyErr = parse.show(fixture("show-empty.txt"))
eq("parse: empty output is an empty list", empty and #empty, 0)
eq("parse: empty output no error", emptyErr, nil)
local g, gerr = parse.show(fixture("show-garbage.txt"))
eq("parse: garbage is not empty list (rows)", g, nil)
eq("parse: garbage is not empty list (error)", gerr, "unparsed")
local ws = parse.show("  \n\n ")
eq("parse: whitespace is an empty list", ws and #ws, 0)

-- future fields
rows = parse.show(fixture("show-future-fields.txt"))
eq("parse: future fields ignored count", #rows, 1)
eq("parse: future fields ignored host", rows[1].host, "vpn.example.com")
eq("parse: future fields ignored status", rows[1].status, "DISCONNECTED")

-- uri
local uriCases = {
  { "https://user%40example.com@vpn.example.com:8443/app", "vpn.example.com", "user@example.com" },
  { "https://user@example.com@vpn.example.com:8443/app", "vpn.example.com", "user@example.com" },
  { "https://vpn.example.com/app", "vpn.example.com", nil },
  { "https://vpn.example.com:8443", "vpn.example.com", nil },
  { "https://alice@vpn2.example.org", "vpn2.example.org", "alice" },
  { "https://a%20b@vpn.example.com/x", "vpn.example.com", "a b" },
}
for i, case in ipairs(uriCases) do
  local host, account = parse.uri(case[1])
  eq("parse: uri decode host " .. i, host, case[2])
  eq("parse: uri decode account " .. i, account, case[3])
end
eq("parse: uri garbage", parse.uri("not a uri"), nil)
eq("parse: uri nil", parse.uri(nil), nil)

-- connect outcomes
local o = parse.connectOutcome({ stdout = fixture("connect-ok.txt"), exitCode = 0 })
eq("parse: connect ok", o.ok, true)
eq("parse: connect ok kind", o.kind, "ok")
o = parse.connectOutcome({ stdout = fixture("connect-failed.txt"), exitCode = 0 })
eq("parse: connect failed ok flag", o.ok, false)
eq("parse: connect failed kind", o.kind, "failed")
eq("parse: connect failed strips exception class", o.detail, "No route to host")
o = parse.connectOutcome({ stdout = fixture("connect-failed-wg0.txt"), exitCode = 0 })
eq("parse: connect failed wg0 detail", o.detail, 'Cannot find device "wg0"')
o = parse.connectOutcome({ stdout = fixture("connect-signin.txt"), exitCode = 0 })
eq("parse: connect signin kind", o.kind, "signin")
eq("parse: connect signin ok flag", o.ok, false)
o = parse.connectOutcome({ stdout = "Open the URL below", exitCode = 0 })
eq("parse: connect signin by url line", o.kind, "signin")
o = parse.connectOutcome({ stdout = "", timedOut = true })
eq("parse: connect timeout", o.kind, "timeout")
eq("parse: connect timeout ok flag", o.ok, false)
o = parse.connectOutcome({ stdout = "Connection failed.\n", exitCode = 0 })
eq("parse: connect connection failed kind", o.kind, "failed")
eq("parse: connect connection failed no detail", o.detail, nil)
o = parse.connectOutcome({ stdout = "", stderr = "boom happened\nmore\n", exitCode = 2 })
eq("parse: connect nonzero kind", o.kind, "failed")
eq("parse: connect nonzero detail", o.detail, "boom happened")
o = parse.connectOutcome({ stdout = "Failed to connect. line one\nline two", exitCode = 1 })
eq("parse: connect detail first line only", o.detail, "line one")
o = parse.connectOutcome({ stdout = "Failed to connect. " .. string.rep("x", 300), exitCode = 1 })
eq("parse: connect detail capped", #o.detail, 160)

-- disconnect outcomes
o = parse.disconnectOutcome({ stdout = fixture("disconnect-ok.txt"), exitCode = 0 })
eq("parse: disconnect ok", o.kind, "ok")
eq("parse: disconnect ok flag", o.ok, true)
o = parse.disconnectOutcome({ stdout = "", stderr = fixture("disconnect-not-connected.txt"), exitCode = 0 })
eq("parse: disconnect already (stderr)", o.kind, "already")
eq("parse: disconnect already is ok", o.ok, true)
o = parse.disconnectOutcome({ stdout = fixture("disconnect-not-connected.txt"), exitCode = 0 })
eq("parse: disconnect already (stdout)", o.kind, "already")
o = parse.disconnectOutcome({ stdout = "", timedOut = true })
eq("parse: disconnect timeout", o.kind, "timeout")
o = parse.disconnectOutcome({ stdout = "", stderr = "nope\n", exitCode = 1 })
eq("parse: disconnect failed", o.kind, "failed")
eq("parse: disconnect failed ok flag", o.ok, false)
eq("parse: disconnect failed detail", o.detail, "nope")

-- monitor lines
local function monitorLines(name)
  local list = {}
  for line in fixture(name):gmatch("[^\n]+") do
    list[#list + 1] = line
  end
  return list
end
local mc = monitorLines("monitor-connect.txt")
eq("parse: monitor header line 1", parse.monitorLine(mc[1]), nil)
eq("parse: monitor name owner line", parse.monitorLine(mc[2]).kind, "refresh")
eq("parse: monitor connection updating", parse.monitorLine(mc[3]).kind, "refresh")
eq("parse: monitor connection updated", parse.monitorLine(mc[4]).kind, "refresh")
local ev = parse.monitorLine(mc[5])
eq("parse: monitor connecting kind", ev.kind, "transition")
eq("parse: monitor connecting id", ev.id, 0)
eq("parse: monitor connecting to", ev.to, "connecting")
eq("parse: monitor connected is refresh", parse.monitorLine(mc[6]).kind, "refresh")
local md = monitorLines("monitor-disconnect.txt")
ev = parse.monitorLine(md[3])
eq("parse: monitor disconnecting kind", ev.kind, "transition")
eq("parse: monitor disconnecting to", ev.to, "disconnecting")
eq("parse: monitor disconnected is refresh", parse.monitorLine(md[4]).kind, "refresh")
eq("parse: monitor unrelated line", parse.monitorLine("something else entirely"), nil)
eq("parse: monitor other bus signal", parse.monitorLine("/org/x: org.freedesktop.Foo.Bar ()"), nil)
eq("parse: monitor id parsed", parse.monitorLine("/com/logonbox/vpn/12: com.logonbox.vpn.Connection.Connecting ()").id, 12)

-- name owner
eq("parse: name owner true", parse.nameOwner("(true,)\n"), true)
eq("parse: name owner false", parse.nameOwner("(false,)\n"), false)
eq("parse: name owner garbage", parse.nameOwner("Error: no such thing"), nil)
eq("parse: name owner empty", parse.nameOwner(""), nil)

-- scrubDetail: CLI detail text loses anything that looks like a URL, e-mail, host or IP
eq("parse: scrubDetail keeps plain text", parse.scrubDetail("No route to host"), "No route to host")
eq("parse: scrubDetail keeps device name", parse.scrubDetail('Cannot find device "wg0"'), 'Cannot find device "wg0"')
eq("parse: scrubDetail url", parse.scrubDetail("https://user%40example.com@vpn.example.com:8443/app is not connected."), "… is not connected.")
eq("parse: scrubDetail email", parse.scrubDetail("user@example.com was refused"), "… was refused")
eq("parse: scrubDetail host with ip and port", parse.scrubDetail("Connection refused: vpn.example.com/192.0.2.1:8443"), "Connection refused: …")
eq("parse: scrubDetail bare ipv4", parse.scrubDetail("timeout talking to 198.51.100.7"), "timeout talking to …")
eq("parse: scrubDetail ipv6", parse.scrubDetail("fe80::1 unreachable"), "… unreachable")
eq("parse: scrubDetail host in parens", parse.scrubDetail("Unknown host (vpn2.example.org)."), "Unknown host (…).")
eq("parse: scrubDetail host with trailing dot", parse.scrubDetail("Cannot reach vpn.example.com."), "Cannot reach …")
eq("parse: scrubDetail keeps abbreviation", parse.scrubDetail("e.g. later"), "e.g. later")
eq("parse: scrubDetail keeps a version", parse.scrubDetail("client 3.0.7 failed"), "client 3.0.7 failed")
eq("parse: scrubDetail nothing left is nil", parse.scrubDetail("vpn.example.com"), nil)
eq("parse: scrubDetail nil", parse.scrubDetail(nil), nil)
eq("parse: scrubDetail empty", parse.scrubDetail(""), nil)
-- hosts glued to a prefix (review round 1)
eq("parse: scrubDetail host after =", parse.scrubDetail("host=vpn.example.com refused"), "… refused")
eq("parse: scrubDetail endpoint:host:port", parse.scrubDetail("endpoint:vpn.example.com:51820"), nil)
eq("parse: scrubDetail host:host", parse.scrubDetail("bad host:vpn.example.com"), "bad …")
eq("parse: scrubDetail host after slash", parse.scrubDetail("Cannot connect to /vpn.example.com"), "Cannot connect to …")
eq("parse: scrubDetail percent-encoded at", parse.scrubDetail("failed for user%40corp.io"), "failed for …")
eq("parse: scrubDetail percent-encoded at without a host", parse.scrubDetail("failed for user%40corp"), "failed for …")
eq("parse: scrubDetail keeps a clock time", parse.scrubDetail("retry at 12:30:45"), "retry at 12:30:45")
eq("parse: scrubDetail ipv6 inside a run", parse.scrubDetail("addr=fe80::1 down"), "… down")
eq("parse: scrubDetail keeps device sentence", parse.scrubDetail('Cannot find device "wg0" (exit 1).'), 'Cannot find device "wg0" (exit 1).')
-- scrubbed before the detail is cut to length, so a host is never cut to "vpn.e"
for pad = 140, 165 do
  local text = "Failed to connect. " .. string.rep("a", pad) .. " vpn.example.com tail"
  local d = parse.connectOutcome({ stdout = text, exitCode = 1 }).detail or ""
  check("parse: long detail has no host fragment (pad " .. pad .. ")", d:find("vpn", 1, true) == nil and d:find("example", 1, true) == nil)
  local last = d:byte(#d) or 0
  check("parse: long detail ends on a whole character (pad " .. pad .. ")", last < 128 or d:sub(-3) == "…")
end
local stderrHost = parse.connectOutcome({ stdout = "", stderr = "java.net.UnknownHostException: host=vpn.example.com\n", exitCode = 1 })
eq("parse: stderr detail with only a host is dropped", stderrHost.detail, nil)

-- sign-in text wins over a timeout (the device-code flow waits for input)
o = parse.connectOutcome({ stdout = "Open the URL below\nUser Code: ABCD-EFGH\n", timedOut = true })
eq("parse: signin beats timeout", o.kind, "signin")
