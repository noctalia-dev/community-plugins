-- service.luau against the fake noctalia. Each test boots a fresh service.
-- All paths are made up.
local DIR = "/fake/plugin-data"
local HOME = "/home/user"
local CODE = HOME .. "/.config/Code"
local U = CODE .. "/User"
local DB = U .. "/globalStorage/state.vscdb"
local STORAGE = U .. "/globalStorage/storage.json"
local WS = U .. "/workspaceStorage"
local E2E = "/tmp/noctalia-vscode-e2e-"
local SQL = { "sqlite3", "-readonly", DB }

local function dir(f, path, mtime)
  f.fileMeta[path] = { size = 0, mtime = mtime or 1, isDir = true }
end

-- Writes a workspaceStorage dir <hash> holding workspace.json for folder `uri`.
local function wsDir(f, hash, uri, mtime)
  f.dirs[WS] = f.dirs[WS] or {}
  table.insert(f.dirs[WS], hash)
  dir(f, WS .. "/" .. hash, mtime)
  f.setFile(WS .. "/" .. hash .. "/workspace.json", '{"folder":"' .. uri .. '"}', mtime)
end

local function dbList(paths)
  local parts = {}
  for _, p in ipairs(paths) do
    parts[#parts + 1] = '{"folderUri":"file://' .. p .. '"}'
  end
  return '{"entries":[' .. table.concat(parts, ",") .. "]}\n"
end

local current
local ticks
-- boot(setup) boots and settles (the list is built in update() ticks); boot(setup, true) does not tick.
local function boot(setup, noTicks)
  if current then current.uninstall() end
  local fake = stubs.newNoctalia()
  fake.config = { hide_missing = false }
  dir(fake, CODE)
  if setup then setup(fake) end
  fake.install()
  loadFresh("service.luau")
  current = fake
  if not noTicks then ticks(20) end
  return fake
end

local function state(fake)
  return fake.state["vscode.state"] or {}
end

local function send(fake, request)
  fake.noctalia.state.set("vscode.request", request)
  ticks(10)
end

function ticks(n)
  for _ = 1, n or 50 do update() end
end

local function callsMatching(fake, prefix)
  local n = 0
  for _, call in ipairs(fake.calls) do
    local match = true
    for i, part in ipairs(prefix) do
      if call.argv[i] ~= part then match = false end
    end
    if match then n = n + 1 end
  end
  return n
end

local function lastCall(fake)
  return fake.calls[#fake.calls]
end

local function joined(call)
  return call and table.concat(call.argv, " ") or ""
end

local function titles(list)
  local out = {}
  for _, e in ipairs(list or {}) do out[#out + 1] = e.title end
  return table.concat(out, ",")
end

local function countReads(fake, path)
  local n = 0
  for _, p in ipairs(fake.fileReads) do
    if p == path then n = n + 1 end
  end
  return n
end

local function withDb(f, text)
  f.setFile(DB, "sqlite", 100)
  f.queue(SQL, { stdout = text })
end

-- publishes head before scan ends
local fake = boot(function(f)
  withDb(f, fixture("state-vscdb-recents.json") .. "\n")
  for i = 1, 300 do
    wsDir(f, string.format("h%03d", i), "file:///home/user/old/p" .. i, i)
  end
end, true)
local headTick, headLoading, headCount
for t = 1, 10 do
  update()
  if headTick == nil and #(state(fake).recent or {}) > 0 then
    local r = state(fake).recent
    headTick, headLoading, headCount = t, state(fake).loading, titles({ r[1], r[2], r[3], r[4] })
  end
end
check("service: publishes head within a few ticks", headTick ~= nil and headTick <= 4)
eq("service: publishes head before scan ends (loading)", headLoading, true)
eq("service: publishes head before scan ends (head)", headCount, "demo-api,team,api,my app")
eq("service: flavor is code", state(fake).flavor and state(fake).flavor.id, "code")
eq("service: sqlite runs with a 3 s timeout", fake.calls[1].timeoutMs, 3000)
ticks(40)
eq("service: loading false after the scan", state(fake).loading, false)
eq("service: scan adds the tail", #state(fake).recent, 304)
eq("service: tail newest first", state(fake).recent[5].title, "p300")

-- db list wins over menu / menu used when db key absent
fake = boot(function(f)
  withDb(f, fixture("state-vscdb-recents.json") .. "\n")
  f.setFile(STORAGE, fixture("storage-menubar.json"), 100)
end)
eq("service: db list wins over menu", titles(state(fake).recent), "demo-api,team,api,my app")

fake = boot(function(f)
  withDb(f, "")
  f.setFile(STORAGE, fixture("storage-menubar.json"), 100)
end)
eq("service: menu used when db key absent", titles(state(fake).recent), "demo-api,team,api")
eq("service: no lastError on an absent key", state(fake).lastError, nil)

-- a chosen editor that isn't set up: the fallback is reported, not silent
fake = boot(function(f) f.config.editor = "code-insiders" end)
eq("service: unset-up editor falls back", state(fake).flavor and state(fake).flavor.id, "code")
local fb = state(fake).flavorFallback
eq("service: fallback names the wanted editor", fb and fb.wanted, "VS Code Insiders")
eq("service: fallback says it isn't set up", fb and fb.reason, "not_set_up")
fake = boot(function(f) f.config.editor = "code-insiders"; f.commands["code-insiders"] = false end)
fb = state(fake).flavorFallback
eq("service: fallback says it isn't installed", fb and fb.reason, "not_installed")
fake = boot(function(f) f.config.editor = "flatpak" end)
eq("service: flatpak app missing is not_installed", (state(fake).flavorFallback or {}).reason, "not_installed")
fake = boot(function(f) f.config.editor = "flatpak"; f.flatpakApps = { ["com.visualstudio.code"] = true } end)
eq("service: flatpak app present but never run is not_set_up", (state(fake).flavorFallback or {}).reason, "not_set_up")
fake = boot(function(f) f.config.editor = "code" end)
eq("service: no fallback when the choice is used", state(fake).flavorFallback, nil)
fake = boot()
eq("service: no fallback on auto", state(fake).flavorFallback, nil)

-- fresh flavor profile
fake = boot(function(f)
  f.fileMeta[CODE] = nil
  dir(f, HOME .. "/.config/VSCodium")
end)
ticks(10)
fake.advance(5000)
ticks(10)
fake.advance(5000)
ticks(10)
eq("service: fresh flavor profile (flavor)", state(fake).flavor and state(fake).flavor.id, "codium")
eq("service: fresh flavor profile (empty)", #state(fake).recent + #state(fake).pinned, 0)
eq("service: fresh flavor profile (loaded)", state(fake).loading, false)
eq("service: fresh flavor profile (no error)", state(fake).lastError, nil)
eq("service: fresh flavor profile (no sqlite)", callsMatching(fake, { "sqlite3" }), 0)
eq("service: fresh flavor profile (no reads)", #fake.fileReads, 0)

fake = boot(function(f) f.fileMeta[CODE] = nil end)
eq("service: no flavor installed", state(fake).flavor, nil)
eq("service: no flavor lists none", #state(fake).flavorsInstalled, 0)

-- bad storage.json keeps previous list
fake = boot(function(f)
  f.setFile(STORAGE, fixture("storage-menubar.json"), 100)
end)
eq("service: menu read", #state(fake).recent, 3)
fake.setFile(STORAGE, fixture("storage-truncated.json"), 200)
fake.advance(5000)
ticks(5)
eq("service: bad storage.json keeps previous list", #state(fake).recent, 3)
eq("service: bad storage.json read once", countReads(fake, STORAGE), 2)
fake.advance(5000)
ticks(5)
eq("service: bad storage.json not re-read without mtime change", countReads(fake, STORAGE), 2)
fake.setFile(STORAGE, fixture("storage-menubar.json"):gsub("demo%-api", "other-api"), 300)
fake.advance(5000)
ticks(5)
eq("service: storage.json re-read on mtime change", state(fake).recent[1].title, "other-api")

-- scan spreads across ticks
fake = boot(function(f)
  for i = 1, 100 do
    wsDir(f, string.format("h%03d", i), "file:///home/user/old/p" .. i, i)
  end
end, true)
local infoCalls = 0
local realInfo = fake.noctalia.fileInfo
fake.noctalia.fileInfo = function(p)
  infoCalls = infoCalls + 1
  return realInfo(p)
end
local maxPerTick = 0
for _ = 1, 20 do
  infoCalls = 0
  update()
  if infoCalls > maxPerTick then maxPerTick = infoCalls end
end
check("service: scan spreads across ticks (<= 40 fileInfo)", maxPerTick <= 40 and maxPerTick > 0)
eq("service: scan finished", #state(fake).recent, 100)
-- a rescan re-reads only changed dirs
local readsBefore = #fake.fileReads
fake.setFile(WS .. "/h001/workspace.json", '{"folder":"file:///home/user/old/renamed"}', 500)
dir(fake, WS .. "/h001", 500)
send(fake, { action = "refresh", requestId = "r1" })
ticks(20)
eq("service: rescan reads only changed dirs", #fake.fileReads - readsBefore, 1)
eq("service: changed dir now first", state(fake).recent[1].title, "renamed")

-- entries are built once per key (building one costs ~0.2 ms in the host)
local recentsMod = loadModule("recents.luau")
local realEntry = recentsMod.entry
local built = 0
recentsMod.entry = function(...)
  built = built + 1
  return realEntry(...)
end
fake = boot(function(f)
  withDb(f, fixture("state-vscdb-recents.json") .. "\n")
  for i = 1, 50 do
    wsDir(f, string.format("h%03d", i), "file:///home/user/old/p" .. i, i)
  end
end)
fake.queue(SQL, { stdout = fixture("state-vscdb-recents.json") .. "\n" })
send(fake, { action = "refresh", requestId = "e1" })
ticks(20)
recentsMod.entry = realEntry
eq("service: entries built once per key", built, 54)

-- missing check (hide_missing default true)
fake = boot(function(f)
  f.config = {}
  withDb(f, dbList({ "/home/user/a", "/home/user/gone" }))
  dir(f, "/home/user/a")
end)
ticks(5)
eq("service: missing folder hidden", titles(state(fake).recent), "a")

-- open argv detached
fake = boot(function(f) withDb(f, fixture("state-vscdb-recents.json") .. "\n") end)
local demo = state(fake).recent[1]
send(fake, { action = "open", key = demo.key, requestId = "o1" })
eq("service: open argv detached (argv)", joined(lastCall(fake)), "code /home/user/projects/demo-api")
eq("service: open argv detached (no callback)", lastCall(fake).hasCallback, false)
eq("service: requestSeq counts handled requests", state(fake).requestSeq, 1)
check("service: serviceBootId set", type(state(fake).serviceBootId) == "string")
local remote = state(fake).recent[3]
send(fake, { action = "open", key = remote.key, requestId = "o2" })
eq("service: remote opens with --folder-uri", lastCall(fake).argv[2], "--folder-uri")

-- open_path error sets pathError and runs nothing
fake = boot()
local before = #fake.calls
send(fake, { action = "open_path", text = "/home/user/nope", requestId = "p1" })
eq("service: open_path error sets pathError", state(fake).pathError, "path.missing")
eq("service: open_path error runs nothing", #fake.calls, before)

dir(fake, "/home/user/my app")
send(fake, { action = "open_path", text = "'/home/user/my app/'\n", requestId = "p2" })
eq("service: open_path opens a typed path", joined(lastCall(fake)), "code /home/user/my app")
eq("service: open_path clears pathError", state(fake).pathError, nil)

-- pin persists via tmp+rename
fake = boot(function(f) withDb(f, fixture("state-vscdb-recents.json") .. "\n") end)
local renames = {}
local realRename = fake.noctalia.renameFile
fake.noctalia.renameFile = function(a, b)
  renames[#renames + 1] = a .. ">" .. b
  return realRename(a, b)
end
local key = state(fake).recent[2].key
send(fake, { action = "pin", key = key, requestId = "pin1" })
eq("service: pin persists via tmp+rename", renames[1], DIR .. "/data.json.tmp>" .. DIR .. "/data.json")
eq("service: pin stored by key", json.decode(fake.files[DIR .. "/data.json"]).pins[1], key)
eq("service: pinned shown", state(fake).pinned[1] and state(fake).pinned[1].key, key)
eq("service: pinned left out of recent", #state(fake).recent, 3)
local saved = fake.files[DIR .. "/data.json"]
fake = boot(function(f)
  withDb(f, fixture("state-vscdb-recents.json") .. "\n")
  f.setFile(DIR .. "/data.json", saved)
end)
eq("service: pins survive a restart", state(fake).pinned[1] and state(fake).pinned[1].key, key)
send(fake, { action = "unpin", key = key, requestId = "pin2" })
eq("service: unpin", #state(fake).pinned, 0)

-- Flatpak VS Code cannot see the host's /tmp: refuse with a clear error, run nothing
fake = boot(function(f)
  f.config.editor = "flatpak"
  f.flatpakApps = { ["com.visualstudio.code"] = true }
  dir(f, HOME .. "/.var/app/com.visualstudio.code/config/Code")
  dir(f, "/tmp/demo-proj")
end)
eq("service: flatpak chosen", state(fake).flavor and state(fake).flavor.id, "flatpak")
before = #fake.calls
send(fake, { action = "open_path", text = "/tmp/demo-proj", requestId = "fp1" })
eq("service: flatpak /tmp path refused", state(fake).pathError, "path.flatpak_hidden")
eq("service: flatpak /tmp path runs nothing", #fake.calls, before)

-- hide then open unhides
fake = boot(function(f)
  withDb(f, fixture("state-vscdb-recents.json") .. "\n")
  dir(f, "/home/user/projects/demo-api")
end)
key = state(fake).recent[1].key
send(fake, { action = "hide", key = key, requestId = "h1" })
eq("service: hide removes from recent", titles(state(fake).recent), "team,api,my app")
eq("service: hide stored by key", json.decode(fake.files[DIR .. "/data.json"]).hidden[1], key)
-- show_hidden lists hidden projects again, marked, so they can be unhidden
fake.config.show_hidden = true
onConfigChanged()
ticks(20)
local back
for _, e in ipairs(state(fake).recent) do
  if e.key == key then back = e end
end
check("service: show_hidden lists the hidden project", back ~= nil)
eq("service: show_hidden marks it hidden", back and back.hidden, true)
eq("service: other projects are not marked", state(fake).recent[2] and state(fake).recent[2].hidden, false)
send(fake, { action = "unhide", key = key, requestId = "h1u" })
for _, e in ipairs(state(fake).recent) do
  if e.key == key then back = e end
end
eq("service: unhide clears the mark", back and back.hidden, false)
eq("service: unhide saved", #json.decode(fake.files[DIR .. "/data.json"]).hidden, 0)
send(fake, { action = "unhide", key = "file:///nope", requestId = "h1v" })
eq("service: unhide of an unknown key is harmless", #json.decode(fake.files[DIR .. "/data.json"]).hidden, 0)
fake.config.show_hidden = false
onConfigChanged()
ticks(20)
send(fake, { action = "hide", key = key, requestId = "h1w" })
eq("service: hidden again without show_hidden", titles(state(fake).recent), "team,api,my app")
send(fake, { action = "open_path", text = "~/projects/demo-api", requestId = "h2" })
eq("service: hide then open unhides", titles(state(fake).recent), "demo-api,team,api,my app")
eq("service: unhide saved", #json.decode(fake.files[DIR .. "/data.json"]).hidden, 0)

-- hide on a pinned row also unpins it
fake = boot(function(f)
  withDb(f, fixture("state-vscdb-recents.json") .. "\n")
  dir(f, "/home/user/projects/demo-api")
end)
key = state(fake).recent[1].key
send(fake, { action = "pin", key = key, requestId = "hp1" })
eq("service: pinned before hide", #state(fake).pinned, 1)
send(fake, { action = "hide", key = key, requestId = "hp2" })
eq("service: hide unpins", #state(fake).pinned, 0)
eq("service: hidden pinned row not in recent", titles(state(fake).recent), "team,api,my app")
eq("service: unpin saved with hide", #json.decode(fake.files[DIR .. "/data.json"]).pins, 0)

-- copy / terminal / files
fake = boot(function(f) withDb(f, fixture("state-vscdb-recents.json") .. "\n") end)
send(fake, { action = "copy_path", key = state(fake).recent[1].key, requestId = "c1" })
eq("service: copy_path local copies the path", fake.clipboard[1].text, "/home/user/projects/demo-api")
send(fake, { action = "copy_path", key = state(fake).recent[3].key, requestId = "c2" })
eq("service: copy_path remote copies the uri", fake.clipboard[2].text, "vscode-remote://ssh-remote%2Bmybox/home/me/api")
send(fake, { action = "open_terminal", key = state(fake).recent[4].key, requestId = "c3" })
eq("service: open_terminal", fake.terminalCalls[1], "cd -- '/home/user/work/my app' && exec \"${SHELL:-sh}\"")
send(fake, { action = "open_terminal", key = state(fake).recent[3].key, requestId = "c4" })
eq("service: open_terminal local only", #fake.terminalCalls, 1)
send(fake, { action = "open_files", key = state(fake).recent[1].key, requestId = "c5" })
eq("service: open_files", joined(lastCall(fake)), "xdg-open /home/user/projects/demo-api")
eq("service: open_files detached", lastCall(fake).hasCallback, false)

-- git queue max 4 and cache 30s
local SIX = { "/home/user/g1", "/home/user/g2", "/home/user/g3", "/home/user/g4", "/home/user/g5", "/home/user/g6" }
fake = boot(function(f)
  withDb(f, dbList(SIX))
  for i, p in ipairs(SIX) do
    dir(f, p)
    if i == 6 then
      f.queue({ "git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", p }, { defer = true, exitCode = 128, stderr = "not a git repository" })
    else
      f.queue({ "git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", p }, { defer = true, stdout = "# branch.oid abcdef1234\n# branch.head main\n1 .M N... 1 1 1 a b f\n" })
    end
  end
end)
local keys = {}
for _, e in ipairs(state(fake).recent) do keys[#keys + 1] = e.key end
send(fake, { action = "git", keys = keys, requestId = "g1" })
eq("service: git queue max 4", callsMatching(fake, { "git" }), 4)
eq("service: git 3 s timeout", fake.calls[#fake.calls].timeoutMs, 3000)
fake.flush()
eq("service: git queue drains", callsMatching(fake, { "git" }), 6)
fake.flush()
eq("service: git branch published", state(fake).git[keys[1]] and state(fake).git[keys[1]].branch, "main")
eq("service: git dirty published", state(fake).git[keys[1]].dirty, true)
eq("service: git non-zero exit gives no badge", state(fake).git[keys[6]], nil)
send(fake, { action = "git", keys = keys, requestId = "g2" })
eq("service: git cached 30s", callsMatching(fake, { "git" }), 6)
fake.advance(30001)
send(fake, { action = "git", keys = keys, requestId = "g3" })
eq("service: git re-runs after 30s", callsMatching(fake, { "git" }), 12)

-- show_git false runs no git
fake = boot(function(f)
  f.config.show_git = false
  withDb(f, dbList(SIX))
end)
send(fake, { action = "git", keys = { state(fake).recent[1].key }, requestId = "g1" })
eq("service: show_git false runs no git", callsMatching(fake, { "git" }), 0)
fake = boot(function(f)
  f.commands.git = false
  withDb(f, dbList(SIX))
end)
send(fake, { action = "git", keys = { state(fake).recent[1].key }, requestId = "g1" })
eq("service: no git command runs no git", callsMatching(fake, { "git" }), 0)
eq("service: hasGit false", state(fake).hasGit, false)

-- pick flow opens picked path
fake = boot(function(f) f.setFile(DIR .. "/picked", "/old") end)
send(fake, { action = "pick_folder", requestId = "k1" })
eq("service: pick removes a stale picked", fake.files[DIR .. "/picked"], nil)
eq("service: pick runs the picker", lastCall(fake).argv[1] .. " " .. lastCall(fake).argv[6], "setsid " .. DIR)
eq("service: pick title", lastCall(fake).argv[7], "picker.title")
eq("service: pick detached", lastCall(fake).hasCallback, false)
dir(fake, "/home/user/projects/picked one")
fake.setFile(DIR .. "/picked", "/home/user/projects/picked one")
fake.advance(1000)
update()
eq("service: pick flow opens picked path", joined(lastCall(fake)), "code /home/user/projects/picked one")
eq("service: picked deleted", fake.files[DIR .. "/picked"], nil)

-- clone
local URL = "https://example.com/u/repo.git"
local DEST = HOME .. "/Projects/repo"
fake = boot()
send(fake, { action = "clone", url = URL, requestId = "cl1" })
eq("service: clone running", state(fake).clone.state, "running")
eq("service: clone argv", joined(lastCall(fake)), table.concat(loadModule("shell.luau").cloneArgv(URL, DEST, DIR .. "/clone"), " "))
eq("service: clone detached", lastCall(fake).hasCallback, false)
send(fake, { action = "clone", url = URL, requestId = "cl2" })
eq("service: second clone refused", state(fake).lastError and state(fake).lastError.key, "error.busy_clone")
eq("service: second clone runs nothing", callsMatching(fake, { "setsid" }), 1)

fake = boot()
send(fake, { action = "clone", url = "not a url", requestId = "cl1" })
eq("service: clone bad url refused", state(fake).lastError and state(fake).lastError.key, "error.bad_url")
send(fake, { action = "clone", url = "https://example.com/", requestId = "cl2" })
eq("service: clone url without a name refused", state(fake).lastError and state(fake).lastError.key, "error.bad_url")
eq("service: bad url runs nothing", callsMatching(fake, { "setsid" }), 0)

fake = boot(function(f) dir(f, DEST) end)
send(fake, { action = "clone", url = URL, requestId = "cl1" })
eq("service: clone exists offers open", state(fake).clone.state, "exists")
eq("service: clone exists dest", state(fake).clone.dest, DEST)
eq("service: clone exists runs nothing", callsMatching(fake, { "setsid" }), 0)

fake = boot(function(f) f.setFile(DIR .. "/clone/status", "1") end)
send(fake, { action = "clone", url = URL, requestId = "cl1" })
eq("service: clone clears an old status", fake.files[DIR .. "/clone/status"], nil)
fake.setFile(DIR .. "/clone/pid", "1234\n")
fake.setFile(DIR .. "/clone/log", "Cloning into 'repo'...\nReceiving objects:  50% (1/2)\rReceiving objects: 100% (2/2), done.\r\n")
fake.advance(1000)
update()
eq("service: clone progress", state(fake).clone.progress, "Receiving objects: 100% (2/2), done.")
fake.setFile(DIR .. "/clone/status", "0\n")
fake.advance(1000)
update()
eq("service: clone success", state(fake).clone.state, "done")
eq("service: clone success opens", joined(lastCall(fake)), "code " .. DEST)
eq("service: clone success notifies", fake.notifications[1] and fake.notifications[1].body, "notify.cloned")
send(fake, { action = "clear_clone", requestId = "cc1" })
eq("service: clear_clone resets a done clone", state(fake).clone.state, "idle")
local clonedKey = "file://" .. DEST
check("service: clone success marks the project cloned", state(fake).cloned and state(fake).cloned[clonedKey] == true)
local savedCloned = json.decode(fake.files[DIR .. "/data.json"] or "{}").cloned or {}
eq("service: cloned mark is saved by key", savedCloned[1], clonedKey)
local keepData = fake.files[DIR .. "/data.json"]
fake = boot(function(f) f.setFile(DIR .. "/data.json", keepData) end)
check("service: cloned mark survives a restart", state(fake).cloned and state(fake).cloned[clonedKey] == true)

fake = boot()
send(fake, { action = "clone", url = URL, requestId = "cl1" })
fake.setFile(DIR .. "/clone/pid", "1234\n")
fake.setFile(DIR .. "/clone/log", "Cloning into 'repo'...\nfatal: repository 'https://example.com/u/repo.git/' not found\n")
fake.setFile(DIR .. "/clone/status", "128\n")
fake.advance(1000)
update()
eq("service: clone failure", state(fake).clone.state, "failed")
eq("service: clone failure shows fatal line", state(fake).clone.error, "fatal: repository 'https://example.com/u/repo.git/' not found")

fake = boot()
send(fake, { action = "clone", url = URL, requestId = "cl1" })
fake.setFile(DIR .. "/clone/pid", "4321\n")
fake.setFile("/proc/4321/cmdline", "sh\0-c\0script\0vscode-clone\0" .. URL .. "\0")
send(fake, { action = "cancel_clone", requestId = "cl2" })
eq("service: cancel kills process group", joined(lastCall(fake)), "kill -TERM -- -4321")
eq("service: cancel marks cancelled", state(fake).clone.state, "cancelled")

fake = boot(function(f)
  f.setFile(DIR .. "/clone/pid", "999\n")
  f.queue({ "kill", "-0", "999" }, { exitCode = 1 })
end)
eq("service: stale clone job cleaned (failed)", state(fake).clone.state, "failed")
eq("service: stale clone job cleaned (error)", state(fake).clone.error, "error.clone_interrupted")
eq("service: stale clone job cleaned (pid removed)", fake.files[DIR .. "/clone/pid"], nil)

-- a pid that now belongs to another process is never trusted or signalled
local CLONE_CMD = "sh\0-c\0script\0vscode-clone\0" .. URL .. "\0"
fake = boot(function(f)
  f.setFile(DIR .. "/clone/pid", "999\n")
  f.setFile(DIR .. "/clone/job.json", '{"name":"repo","dest":"' .. DEST .. '"}')
  f.setFile("/proc/999/cmdline", "/usr/bin/sleep\0" .. "100\0")
  f.queue({ "kill", "-0", "999" }, { exitCode = 0 })
end)
eq("service: reused pid marks the job failed", state(fake).clone.state, "failed")
eq("service: reused pid error", state(fake).clone.error, "error.clone_interrupted")
send(fake, { action = "cancel_clone", requestId = "rp1" })
eq("service: reused pid never gets kill -TERM", callsMatching(fake, { "kill", "-TERM" }), 0)
send(fake, { action = "clone", url = URL, requestId = "rp2" })
eq("service: clone allowed after a reused pid", state(fake).clone.state, "running")

fake = boot(function(f)
  f.setFile(DIR .. "/clone/pid", "999\n")
  f.setFile(DIR .. "/clone/job.json", '{"name":"repo","dest":"' .. DEST .. '"}')
  f.setFile("/proc/999/cmdline", CLONE_CMD)
  f.queue({ "kill", "-0", "999" }, { exitCode = 0 })
end)
eq("service: live clone job resumed", state(fake).clone.state, "running")
eq("service: resumed job keeps dest", state(fake).clone.dest, DEST)

fake = boot()
send(fake, { action = "clone", url = URL, requestId = "rc1" })
fake.setFile(DIR .. "/clone/pid", "4321\n")
fake.setFile("/proc/4321/cmdline", "bash\0")
send(fake, { action = "cancel_clone", requestId = "rc2" })
eq("service: cancel of a foreign pid sends no kill", callsMatching(fake, { "kill", "-TERM" }), 0)
eq("service: cancel of a foreign pid ends the job", state(fake).clone.state, "failed")

-- a clone whose script never writes a pid fails after ~15 s; a Cancel then still ends it
local function waitSeconds(f, n)
  for _ = 1, n do
    f.advance(1000)
    update()
  end
end
fake = boot()
send(fake, { action = "clone", url = URL, requestId = "np1" })
waitSeconds(fake, 10)
eq("service: no pid yet still running at 10 s", state(fake).clone.state, "running")
waitSeconds(fake, 7)
eq("service: no pid after 15 s fails", state(fake).clone.state, "failed")
eq("service: no pid error", state(fake).clone.error, "error.clone_failed")

fake = boot()
send(fake, { action = "clone", url = URL, requestId = "np2" })
send(fake, { action = "cancel_clone", requestId = "np3" })
waitSeconds(fake, 17)
eq("service: cancel with no pid ends the job", state(fake).clone.state, "cancelled")
eq("service: cancel with no pid sends no kill", callsMatching(fake, { "kill", "-TERM" }), 0)

-- while the startup check of a leftover job runs, a clone is refused and the job kept
fake = boot(function(f)
  f.setFile(DIR .. "/clone/pid", "999\n")
  f.setFile(DIR .. "/clone/job.json", '{"name":"repo","dest":"' .. DEST .. '"}')
  f.setFile("/proc/999/cmdline", CLONE_CMD)
  f.queue({ "kill", "-0", "999" }, { defer = true, exitCode = 0 })
end)
send(fake, { action = "clone", url = "https://example.com/u/other.git", requestId = "sr1" })
eq("service: clone refused while the old job is checked", state(fake).lastError and state(fake).lastError.key, "error.busy_clone")
check("service: old job files kept during the check", fake.files[DIR .. "/clone/pid"] ~= nil)
eq("service: no clone started during the check", callsMatching(fake, { "setsid" }), 0)
fake.flush()
eq("service: old job resumed after the check", state(fake).clone.state, "running")

-- git that cannot start publishes once per pump, not once per key
local TWENTY = {}
for i = 1, 20 do TWENTY[i] = "/home/user/t" .. i end
fake = boot(function(f)
  withDb(f, dbList(TWENTY))
  for _, p in ipairs(TWENTY) do dir(f, p) end
end)
keys = {}
for _, e in ipairs(state(fake).recent) do keys[#keys + 1] = e.key end
local publishes = 0
fake.noctalia.state.watch("vscode.state", function() publishes = publishes + 1 end)
fake.noctalia.state.set("vscode.request", { action = "git", keys = keys, requestId = "gp1" })
eq("service: 20 git keys queued", #keys, 20)
check("service: failing git publishes at most twice (" .. publishes .. ")", publishes <= 2)

-- auto prefers a flavor with history over a newer empty one
fake = boot(function(f)
  dir(f, HOME .. "/.config/VSCodium")
  f.setFile(HOME .. "/.config/VSCodium/User/globalStorage/storage.json", "{}", 200)
  f.setFile(STORAGE, fixture("storage-menubar.json"), 100)
  wsDir(f, "h1", "file:///home/user/projects/demo-api", 50)
end)
eq("service: auto picks the flavor with history", state(fake).flavor and state(fake).flavor.id, "code")

fake = boot(function(f)
  local CODIUM_WS = HOME .. "/.config/VSCodium/User/workspaceStorage"
  dir(f, HOME .. "/.config/VSCodium")
  f.setFile(HOME .. "/.config/VSCodium/User/globalStorage/storage.json", "{}", 200)
  f.dirs[CODIUM_WS] = { "empty-window" }
  dir(f, CODIUM_WS .. "/empty-window")
  f.setFile(STORAGE, fixture("storage-menubar.json"), 100)
  wsDir(f, "h1", "file:///home/user/projects/demo-api", 50)
end)
eq("service: a dir without workspace.json is not history", state(fake).flavor and state(fake).flavor.id, "code")

-- debug state.json has only e2e paths
fake = boot(function(f)
  f.setFile(DIR .. "/debug", "")
  withDb(f, dbList({ "/home/user/secret", E2E .. "x/proj" }))
  dir(f, "/home/user/secret")
  dir(f, E2E .. "x/proj")
  f.queue({ "git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", "/home/user/secret" }, { stdout = "# branch.head main\n" })
  f.queue({ "git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", E2E .. "x/proj" }, { stdout = "# branch.head dev\n" })
end)
keys = {}
for _, e in ipairs(state(fake).recent) do keys[#keys + 1] = e.key end
send(fake, { action = "git", keys = keys, requestId = "d1" })
local dumped = fake.files[DIR .. "/state.json"] or ""
local debugState = json.decode(dumped) or {}
eq("service: debug state.json has only e2e paths", #(debugState.recent or {}), 1)
eq("service: debug keeps the e2e path", debugState.recent and debugState.recent[1].path, E2E .. "x/proj")
eq("service: debug counts", debugState.counts and debugState.counts.recent, 2)
check("service: debug state.json leaks no other path", not dumped:find("secret", 1, true))
local gitKeys = 0
for _ in pairs(debugState.git or {}) do gitKeys = gitKeys + 1 end
eq("service: debug git filtered to e2e", gitKeys, 1)
eq("service: debug omits cloneDir for a real clone folder", debugState.cloneDir, nil)
fake.config.clone_dir = E2E .. "clones/"
send(fake, { action = "refresh", requestId = "d1b" })
eq("service: debug exposes an e2e cloneDir", (json.decode(fake.files[DIR .. "/state.json"] or "") or {}).cloneDir, E2E .. "clones")
fake.config.clone_dir = "/home/user/Projects"
send(fake, { action = "refresh", requestId = "d1c" })
eq("service: debug drops cloneDir again", (json.decode(fake.files[DIR .. "/state.json"] or "") or {}).cloneDir, nil)
fake.files[DIR .. "/debug"] = nil
fake.fileMeta[DIR .. "/debug"] = nil
send(fake, { action = "refresh", requestId = "d2" })
eq("service: state.json removed with the marker", fake.files[DIR .. "/state.json"], nil)

-- test-config-dir adds --user-data-dir
local TCD = E2E .. "cfg"
fake = boot(function(f)
  f.setFile(DIR .. "/test-config-dir", TCD .. "\n")
  f.setFile(TCD .. "/User/globalStorage/storage.json", fixture("storage-menubar.json"), 100)
end)
eq("service: test-config-dir reads its storage.json", #state(fake).recent, 3)
send(fake, { action = "open", key = state(fake).recent[1].key, requestId = "t1" })
eq("service: test-config-dir adds --user-data-dir", joined(lastCall(fake)), "code /home/user/projects/demo-api --user-data-dir " .. TCD)

-- settings take effect without reload
fake = boot(function(f) withDb(f, fixture("state-vscdb-recents.json") .. "\n") end)
fake.config.show_remote = false
ticks(5)
eq("service: show_remote change applies on the next tick", titles(state(fake).recent), "demo-api,team,my app")

-- privacy: logs hold no paths
local logText = table.concat(fake.logs, "\n")
check("service: logs hold no paths", not logText:find("/home/user", 1, true))

-- IPC
fake = boot()
onIpc("request", '{"action":"refresh","requestId":"i1"}')
eq("service: onIpc request handled", state(fake).requestSeq, 1)

if current then current.uninstall() end
