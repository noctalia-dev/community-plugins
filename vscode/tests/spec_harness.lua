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
fake.queue({ "ufw", "status" }, { stdout = "Connected" })
local got
n.runAsync({ "ufw", "status", "-v" }, function(r) got = r end, 1000)
eq("queued result matched by prefix", got.stdout, "Connected")
eq("queued exit code defaults to 0", got.exitCode, 0)
eq("call recorded", fake.calls[1].argv[3], "-v")
n.runAsync({ "ufw", "status" }, function(r) got = r end)
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
n.runStream("ufw status listen", function() end)
eq("runStream captured", fake.runStreams[1].cmd, "ufw status listen")

local node = stubs.ui.column({ gap = 2 }, { stubs.ui.text({ text = "x" }) })
eq("ui node type", node.type, "column")
eq("ui child props", node.children[1].props.text, "x")

fake.install()
check("install sets global", noctalia == n)
fake.uninstall()
check("uninstall restores global", noctalia == nil)

-- runAsync must reject shell strings; runStream keeps its string form
local strictFake = stubs.newNoctalia()
local okStr, errStr = pcall(strictFake.noctalia.runAsync, "ufw status")
check("runAsync with a string raises", okStr == false and tostring(errStr):find("argv table required") ~= nil)
eq("rejected string call not recorded", #strictFake.calls, 0)
check("runStream accepts a string", strictFake.noctalia.runStream("ufw status listen", function() end) == true)

-- deferred results model a command still in flight
local deferFake = stubs.newNoctalia()
deferFake.queue({ "ufw", "connect" }, { defer = true, stdout = "later" })
local deferred
deferFake.noctalia.runAsync({ "ufw", "connect" }, function(r) deferred = r end, 1000)
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
pn.runStream("ufw status listen", function() end)
pn.processMatches(function(m) seenMatch = m end, "ufw status listen")
eq("processMatches sees a started stream", seenMatch, true)
procFake.kill("ufw status listen")
pn.processMatches(function(m) seenMatch = m end, "ufw status listen")
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
local info, ierr = fn.fileInfo("/etc/ufw/user.rules")
eq("fileInfo missing gives nil", info, nil)
eq("fileInfo missing error", ierr, "not found")
ff.setFile("/etc/ufw/user.rules", "abc", 1234)
info = fn.fileInfo("/etc/ufw/user.rules")
eq("fileInfo size from setFile", info.size, 3)
eq("fileInfo mtime from setFile", info.mtime, 1234)
eq("fileInfo isDir false", info.isDir, false)
eq("setFile fills fake.files", ff.files["/etc/ufw/user.rules"], "abc")
ff.fileMeta["/etc/ufw"] = { size = 0, mtime = 1, isDir = true }
eq("fileInfo from fileMeta", fn.fileInfo("/etc/ufw").isDir, true)
local fcontent, ferr
fn.readFileAsync("/etc/ufw/user.rules", function(c, e) fcontent, ferr = c, e end)
eq("readFileAsync reads fake.files", fcontent, "abc")
ff.unreadable["/etc/ufw/user.rules"] = true
fn.readFileAsync("/etc/ufw/user.rules", function(c, e) fcontent, ferr = c, e end)
eq("unreadable gives nil contents", fcontent, nil)
eq("unreadable gives permission denied", ferr, "permission denied")
eq("commandExists defaults true", fn.commandExists("ufw"), true)
ff.commands.ufw = false
eq("commandExists reads fake.commands", fn.commandExists("ufw"), false)

-- listDir / appIconPath / clipboard / terminal / file ops / getenv
local vf = stubs.newNoctalia()
local vn = vf.noctalia
local names, derr = vn.listDir("/nope")
eq("listDir missing gives nil", names, nil)
eq("listDir missing error", derr, "not found")
vf.dirs["/d"] = { "a", "b" }
eq("listDir reads fake.dirs", #vn.listDir("/d"), 2)
eq("listDir first name", vn.listDir("/d")[1], "a")
eq("appIconPath unknown gives nil", vn.appIconPath("code"), nil)
vf.icons.code = "/icons/code.png"
eq("appIconPath reads fake.icons", vn.appIconPath("code"), "/icons/code.png")
eq("copyToClipboard returns true", vn.copyToClipboard("hi", "text/plain"), true)
eq("copyToClipboard records text", vf.clipboard[1].text, "hi")
eq("copyToClipboard records mime", vf.clipboard[1].mime, "text/plain")
eq("runInTerminal returns true", vn.runInTerminal("ls"), true)
eq("runInTerminal records", vf.terminalCalls[1], "ls")
eq("getenv HOME default", vn.getenv("HOME"), "/home/user")
eq("getenv unset gives nil", vn.getenv("NOPE"), nil)
vf.env.NOPE = "x"
eq("getenv reads fake.env", vn.getenv("NOPE"), "x")
local okm = vn.mkdirAll("/m/n")
eq("mkdirAll ok", okm, true)
eq("mkdirAll marks dir", vn.fileInfo("/m/n").isDir, true)
vn.writeFile("/m/n/a.txt", "abc")
eq("writeFile sets fileInfo size", vn.fileInfo("/m/n/a.txt").size, 3)
local okr = vn.renameFile("/m/n/a.txt", "/m/n/b.txt")
eq("renameFile ok", okr, true)
eq("renameFile moves contents", vf.files["/m/n/b.txt"], "abc")
eq("renameFile removes source", vf.files["/m/n/a.txt"], nil)
eq("renameFile moves meta", vn.fileInfo("/m/n/b.txt").size, 3)
eq("renameFile missing source fails", (vn.renameFile("/zzz", "/yyy")), false)
eq("removeFile ok", vn.removeFile("/m/n/b.txt"), true)
eq("removeFile clears meta", vn.fileInfo("/m/n/b.txt"), nil)
eq("expandPath expands ~", vn.expandPath("~/Projects"), "/home/user/Projects")
eq("expandPath keeps absolute", vn.expandPath("/srv/x"), "/srv/x")
