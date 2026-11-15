-- Self-checks for the test harness and the noctalia stub.
eq("json decodes nested", json.decode('{"a":[1,{"b":null}]}').a[2].b, nil)
eq("json decodes bool", json.decode('{"x":false}').x, false)

-- json
eq("json decodes string escapes", json.decode('{"s":"a\\n\\u00e9\\"x"}').s, "a\n\195\169\"x")
eq("json decode reports error", select(2, json.decode("{bad")) ~= nil, true)
eq("json encodes sorted object", json.encode({ b = 1, a = { 1, 2 }, c = "x\n" }), '{"a":[1,2],"b":1,"c":"x\\n"}')
eq("json round trips", json.decode(json.encode({ k = { true, false } })).k[2], false)

-- stubs
local fake = stubs.newNoctalia()
local n = fake.noctalia
fake.queue({ "logonbox-vpn-cli", "show" }, { stdout = "Connected" })
local got
n.runAsync({ "logonbox-vpn-cli", "show", "-v" }, function(r) got = r end, 1000)
eq("queued result matched by prefix", got.stdout, "Connected")
eq("queued exit code defaults to 0", got.exitCode, 0)
eq("call recorded", fake.calls[1].argv[3], "-v")
n.runAsync({ "logonbox-vpn-cli", "show" }, function(r) got = r end)
check("unmatched call gets non-zero result", got.exitCode ~= 0)
eq("unmatched call recorded", #fake.unmatched, 1)

local seen
n.state.watch("k", function(v) seen = v end)
n.state.set("k", 5)
eq("state.watch fires on set", seen, 5)
eq("state.get reads back", n.state.get("k"), 5)
eq("state visible on fake.state", fake.state.k, 5)

local t0 = n.nowMs()
fake.advance(250)
eq("nowMs follows advance", n.nowMs() - t0, 250)

local dir = n.pluginDataDir()
check("writeFile ok", n.writeFile(dir .. "/a.json", "{}"))
check("fileExists after write", n.fileExists(dir .. "/a.json"))
eq("readFile returns contents", n.readFile(dir .. "/a.json"), "{}")
eq("readFile missing gives nil", n.readFile(dir .. "/nope"), nil)
eq("fake.files backs the files", fake.files[dir .. "/a.json"], "{}")

n.log("hello")
n.notifyError("t", "b")
eq("log captured", fake.logs[1], "hello")
eq("notification captured", fake.notifications[1].error, true)
eq("tr returns key", n.tr("a.b"), "a.b")
n.runStream("logonbox monitor listen", function() end)
eq("runStream captured", fake.runStreams[1].cmd, "logonbox monitor listen")

local node = stubs.ui.column({ gap = 2 }, { stubs.ui.text({ text = "x" }) })
eq("ui node type", node.type, "column")
eq("ui child props", node.children[1].props.text, "x")

fake.install()
check("install sets global", noctalia == n)
fake.uninstall()
check("uninstall restores global", noctalia == nil)

-- runAsync must reject shell strings; runStream keeps its string form
local strictFake = stubs.newNoctalia()
local okStr, errStr = pcall(strictFake.noctalia.runAsync, "logonbox show")
check("runAsync with a string raises", okStr == false and tostring(errStr):find("argv table required") ~= nil)
eq("rejected string call not recorded", #strictFake.calls, 0)
check("runStream accepts a string", strictFake.noctalia.runStream("logonbox monitor listen", function() end) == true)

-- deferred results model a command still in flight
local deferFake = stubs.newNoctalia()
deferFake.queue({ "logonbox", "connect" }, { defer = true, stdout = "later" })
local deferred
deferFake.noctalia.runAsync({ "logonbox", "connect" }, function(r) deferred = r end, 1000)
eq("deferred result not delivered yet", deferred, nil)
eq("deferred result held", #deferFake.deferred, 1)
deferFake.flush()
eq("flush delivers deferred result", deferred and deferred.stdout, "later")
eq("flush empties the held list", #deferFake.deferred, 0)
deferFake.noctalia.setUpdateInterval(1000)
eq("setUpdateInterval recorded", deferFake.updateInterval, 1000)

-- processMatches / readFileAsync
local procFake = stubs.newNoctalia()
local pn = procFake.noctalia
local seenMatch
pn.runStream("logonbox monitor listen", function() end)
pn.processMatches(function(m) seenMatch = m end, "logonbox monitor listen")
eq("processMatches sees a started stream", seenMatch, true)
procFake.kill("logonbox monitor listen")
pn.processMatches(function(m) seenMatch = m end, "logonbox monitor listen")
eq("processMatches after kill", seenMatch, false)
local readBack
check("readFileAsync accepted", pn.readFileAsync("/x", function(c) readBack = c or "nil" end) == true)
eq("readFileAsync calls back", readBack, "nil")
procFake.refuseFileReads = true
check("readFileAsync refused", pn.readFileAsync("/x", function() end) == false)
eq("refused read not recorded", #procFake.fileReads, 1)

-- fileInfo / unreadable / commandExists / setFile
local ff = stubs.newNoctalia()
local fn = ff.noctalia
local info, ierr = fn.fileInfo("/etc/logonbox/user.rules")
eq("fileInfo missing gives nil", info, nil)
eq("fileInfo missing error", ierr, "not found")
ff.setFile("/etc/logonbox/user.rules", "abc", 1234)
info = fn.fileInfo("/etc/logonbox/user.rules")
eq("fileInfo size from setFile", info.size, 3)
eq("fileInfo mtime from setFile", info.mtime, 1234)
eq("fileInfo isDir false", info.isDir, false)
eq("setFile fills fake.files", ff.files["/etc/logonbox/user.rules"], "abc")
ff.fileMeta["/etc/logonbox"] = { size = 0, mtime = 1, isDir = true }
eq("fileInfo from fileMeta", fn.fileInfo("/etc/logonbox").isDir, true)
local fcontent, ferr
fn.readFileAsync("/etc/logonbox/user.rules", function(c, e) fcontent, ferr = c, e end)
eq("readFileAsync reads fake.files", fcontent, "abc")
ff.unreadable["/etc/logonbox/user.rules"] = true
fn.readFileAsync("/etc/logonbox/user.rules", function(c, e) fcontent, ferr = c, e end)
eq("unreadable gives nil contents", fcontent, nil)
eq("unreadable gives permission denied", ferr, "permission denied")
eq("commandExists defaults true", fn.commandExists("logonbox"), true)
ff.commands.logonbox = false
eq("commandExists reads fake.commands", fn.commandExists("logonbox"), false)

-- logonbox additions: fileExists / listDir / notifyError / streamLine
local lf = stubs.newNoctalia()
local ln = lf.noctalia
eq("fileExists false by default", ln.fileExists("/sys/x"), false)
lf.exists["/sys/x"] = true
eq("fileExists reads fake.exists", ln.fileExists("/sys/x"), true)
local ents, derr = ln.listDir("/sys/class/net")
eq("listDir missing gives nil", ents, nil)
eq("listDir missing error", derr, "not found")
lf.dirs["/sys/class/net"] = { "lo", "wg0" }
eq("listDir returns fake.dirs", ln.listDir("/sys/class/net")[2], "wg0")
ln.notifyError("t", "b")
eq("notifyError appended", #lf.notifications, 1)
eq("notifyError flagged", lf.notifications[1].error, true)
local lines = {}
ln.runStream("gdbus monitor", function(l) lines[#lines + 1] = l end)
ln.runStream("other", function(l) lines[#lines + 1] = "o:" .. l end)
lf.streamLine(1, "a")
lf.streamLine(2, "b")
eq("streamLine feeds stream 1", lines[1], "a")
eq("streamLine feeds stream 2", lines[2], "o:b")
