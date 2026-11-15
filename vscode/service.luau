--!nonstrict
-- VS Code service - the only entry that reads the editor's files or starts processes.
--
--   noctalia.state.set("vscode.state", snapshot)     bar, panel and launcher render this
--   noctalia.state.watch("vscode.request", handler)  actions from them
--   noctalia msg plugin 3dprogramin/vscode:service all request '<json>'   same, over IPC
--
-- Recents, for the chosen flavor's <config>/User:
--   * head: globalStorage/state.vscdb key history.recentlyOpenedPathsList (sqlite3 -readonly)
--     when it has entries, else the File > Open Recent menu in globalStorage/storage.json.
--     Read at start, on `refresh` (panel or launcher opened), and when either file's mtime
--     changes (checked every 5 s). A failed or unparsable read keeps the previous list.
--     DB_KEY_NOTE below records why the key can be absent.
--   * tail: workspaceStorage/<hash>/workspace.json, scanned at most 40 dirs per update() tick;
--     a rescan re-reads only dirs whose mtime changed. `loading` is true until the first pass.
--   * missing: local paths are checked with fileInfo, at most 40 calls per tick (shared with
--     the scan); an unchecked entry counts as present.
-- Pins and hidden entries live in <pluginDataDir>/data.json ({pins, hidden}, by entry key),
-- written to data.json.tmp and renamed.
--
-- Other files in <pluginDataDir>: clone/ (the clone job: pid, log, status, job.json),
-- picked (the folder picker's output), debug (marker: every publish then writes state.json,
-- holding only entries under /tmp/noctalia-vscode-e2e-, plus counts, and cloneDir when
-- clone_dir is under that prefix), test-config-dir
-- (marker for screenshots and the e2e script: its content replaces the flavor's config dir
-- and every open argv gets --user-data-dir <dir>).
--
-- Privacy: recents name the user's projects. noctalia.log gets counts and error kinds only;
-- lastError never carries a path or URL.
--
-- DB_KEY_NOTE (checked 2026-11-06 on VS Code 1.140.0 while it ran, key names only): the
-- key history.recentlyOpenedPathsList is absent from globalStorage/state.vscdb (315 keys,
-- none containing "recent"), from state.vscdb.backup (the copy VS Code writes when it closes
-- the db, so the key was not written at the last shutdown either) and from storage.json's
-- top level. The File > Open Recent list exists only as storage.json's lastKnownMenubarData.
-- Why is unknown; confirming whether a full quit writes the key needs quitting VS Code,
-- which was not done. So the db is read when it has the key, and the menu is the fallback.

local uris = require("./uris.luau")
local recents = require("./recents.luau")
local flavors = require("./flavors.luau")
local shell = require("./shell.luau")
local gitinfo = require("./gitinfo.luau")

local STATE_KEY = "vscode.state"
local REQUEST_KEY = "vscode.request"
local TICK_FAST_MS = 50 -- while a scan or missing check is running
local TICK_SLOW_MS = 1000
local INFO_BUDGET = 40 -- fileInfo calls per tick
local WATCH_MS = 5000
local READ_TIMEOUT_MS = 3000
local GIT_MAX_AGE_MS = 30000
local GIT_MAX_INFLIGHT = 4
local POLL_MS = 1000
local ALIVE_CHECK_MS = 10000
local HISTORY_PROBE = 50 -- workspaceStorage dirs looked at to tell whether a flavor has history
local NO_PID_MS = 15000 -- a started clone with no pid file by then has failed
local PICK_WINDOW_MS = 10 * 60 * 1000
local DB_CHUNK = 25 -- db items parsed per tick
local DB_MAX = 500 -- VS Code keeps at most 500
local SPLIT_CHUNK = 40 -- entries split per tick
local E2E_PREFIX = "/tmp/noctalia-vscode-e2e-"
local DB_QUERY = "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList'"
-- The `editor` setting names commands; flavors.LIST uses short ids for two of them.
local SETTING_TO_FLAVOR = { ["code-insiders"] = "insiders", ["code-oss"] = "oss" }
local DEFAULTS = {
  editor = "auto", show_git = true, show_remote = true, hide_missing = true, show_hidden = false, clone_dir = "~/Projects",
}
local JOB_FILES = { "pid", "log", "status", "status.tmp", "job.json" }

local decode = noctalia.json.decode
local home = noctalia.getenv("HOME")
local dataDir = noctalia.pluginDataDir()

-- ── state ────────────────────────────────────────────────────────────────────

local settings, settingsSig = {}, nil
local installed = {}
local flavor, flavorIcon, configDir, testConfigDir = nil, nil, nil, nil
-- Set when the Editor setting names an editor that isn't usable, so the panel can say
-- which one it fell back to instead of switching silently: { wanted = name, reason }.
local flavorFallback = nil
local flavorGen = 0 -- bumped when the flavor changes; late callbacks of the old one are dropped
local hasGit, hasPicker, hasSqlite = false, false, false

local dbList, menuList = nil, nil -- nil until read
local dbJob = nil -- { items, i, out }: the db list being parsed
local dbSeen, storageSeen = nil, nil -- mtime of the last read, or "absent"
local nextWatchMs = 0

local wsCache = {} -- dir name -> { mtime, item = recents.parseWorkspaceJson() or nil }
local scan = nil -- { dir, names, i, seen, gen }
local pendingReads = 0
local loading = true

local entryCache = {} -- key .. "|" .. kind -> Entry
local entries, pinned, recent, lookup = {}, {}, {}, {} -- lookup: key -> Entry
local dirty, build = true, nil -- build: the rebuild in progress (see startBuild)
local missingForce = false -- the next build re-checks every path
local missing = {} -- key -> true (gone) / false (present); nil = unchecked
local missingQueue, missingPos, missingQueued, missingChanged = {}, 1, {}, false

local pins, hidden = {}, {}
local cloned = {} -- key -> true: projects this plugin cloned (shown with a Cloned chip)

local gitCache = {} -- key -> { at, value = gitinfo.parse() or false }
local gitQueue, gitQueued, gitInflight = {}, {}, 0

local clone = { state = "idle" }
local cloneNextMs, cloneAliveMs, cloneCancel = 0, 0, false
local clonePidDeadlineMs = math.huge
local jobChecking = false -- the startup kill -0 of a leftover job is in flight
local pickUntilMs, pickNextMs = nil, 0
local pathError, lastError = nil, nil
local seq, requestSeq = 0, 0
local serviceBootId = tostring(noctalia.nowMs()) .. "-" .. tostring(math.random(0, 16777215))
  .. "-" .. (tostring({}):gsub("[^%w]", ""))
local budget = INFO_BUDGET
local tickMs = nil
local debugWritten = true -- so a state.json left by an earlier run goes once the marker is gone

-- ── helpers ──────────────────────────────────────────────────────────────────

local function file(name)
  return dataDir and (dataDir .. "/" .. name) or nil
end

local function log(message)
  noctalia.log("vscode: " .. message)
end

local function trim(text)
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

local function readText(path)
  if path == nil or noctalia.fileExists(path) ~= true then
    return nil
  end
  local text = noctalia.readFile(path)
  return text
end

local function info(path)
  budget = budget - 1
  local st = noctalia.fileInfo(path)
  return st
end

local function isDir(path)
  local st = info(path)
  return st ~= nil and st.isDir == true
end

local function mtimeOf(path)
  local st = info(path)
  return st and st.mtime or "absent"
end

-- runAsync returns false and never calls back when the process cannot start.
local function run(argv, timeoutMs, onResult)
  if noctalia.runAsync(argv, onResult, timeoutMs) == false then
    onResult({ exitCode = 127, stdout = "", stderr = "", timedOut = false })
  end
end

local function detached(argv)
  if noctalia.runAsync(argv) == false then
    lastError = { key = "error.command_failed" }
    log("could not start " .. tostring(argv[1]))
    return false
  end
  return true
end

local function isLocal(e)
  return e.remote == nil and (e.uri == nil or e.uri:sub(1, 7) == "file://")
end

-- Terminal and file manager open a workspace's folder, not the .code-workspace file.
local function folderOf(e)
  if e.kind == "workspace" then
    return e.path:match("^(.*)/[^/]*$") or e.path
  end
  return e.path
end

local function readSettings()
  local s = {}
  for k, d in pairs(DEFAULTS) do
    local v = noctalia.getConfig(k)
    if type(v) ~= type(d) or v == "" then
      v = d
    end
    s[k] = v
  end
  return s
end

local function sigOf(s)
  return table.concat({ s.editor, tostring(s.show_git), tostring(s.show_remote), tostring(s.hide_missing), tostring(s.show_hidden), s.clone_dir }, "|")
end

-- ── publish ──────────────────────────────────────────────────────────────────

local function gitMap(keep)
  local out = {}
  if not settings.show_git then
    return out
  end
  for key, c in pairs(gitCache) do
    if c.value and (keep == nil or keep(key)) then
      out[key] = c.value
    end
  end
  return out
end

local function isE2E(path)
  return type(path) == "string" and path:sub(1, #E2E_PREFIX) == E2E_PREFIX
end

local function e2eOnly(list)
  local out = {}
  for _, e in ipairs(list) do
    if isLocal(e) and isE2E(e.path) then
      out[#out + 1] = e
    end
  end
  return out
end

local function writeDebug(snap)
  local marker, path = file("debug"), file("state.json")
  if marker == nil then
    return
  end
  if noctalia.fileExists(marker) ~= true then
    if debugWritten then
      debugWritten = false
      if noctalia.fileExists(path) then
        noctalia.removeFile(path)
      end
    end
    return
  end
  local copy = {}
  for k, v in pairs(snap) do
    copy[k] = v
  end
  copy.counts = { pinned = #snap.pinned, recent = #snap.recent }
  -- The effective clone folder, only when it is an e2e one (the live script checks it before cloning).
  local cloneBase = (noctalia.expandPath(settings.clone_dir):gsub("/+$", ""))
  if isE2E(cloneBase .. "/") then
    copy.cloneDir = cloneBase
  end
  local clonedE2E = {}
  for k in pairs(snap.cloned or {}) do
    if k:sub(1, 7 + #E2E_PREFIX) == "file://" .. E2E_PREFIX then
      clonedE2E[k] = true
    end
  end
  copy.cloned = clonedE2E
  copy.pinned = e2eOnly(snap.pinned)
  copy.recent = e2eOnly(snap.recent)
  copy.git = gitMap(function(key)
    return key:sub(1, 7 + #E2E_PREFIX) == "file://" .. E2E_PREFIX
  end)
  if not isE2E(snap.clone.dest) then
    copy.clone = { state = snap.clone.state }
  end
  local encoded = noctalia.json.encode(copy, true)
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
    debugWritten = true
  end
end

local function publish()
  seq = seq + 1
  local ids = {}
  for i, f in ipairs(installed) do
    ids[i] = f.id
  end
  local snap = {
    seq = seq,
    requestSeq = requestSeq,
    serviceBootId = serviceBootId,
    flavor = flavor and { id = flavor.id, name = flavor.name, iconPath = flavorIcon } or nil,
    flavorsInstalled = ids,
    loading = loading,
    pinned = pinned,
    recent = recent,
    git = gitMap(),
    hasGit = hasGit,
    hasPicker = hasPicker,
    clone = clone,
    cloned = cloned,
    flavorFallback = flavorFallback,
    pathError = pathError,
    lastError = lastError,
  }
  noctalia.state.set(STATE_KEY, snap)
  writeDebug(snap)
end

-- ── pins and hidden ──────────────────────────────────────────────────────────

local function loadData()
  local text = readText(file("data.json"))
  local ok, value = pcall(decode, text or "")
  pins, hidden, cloned = {}, {}, {}
  if not ok or type(value) ~= "table" then
    return
  end
  for _, k in ipairs(type(value.cloned) == "table" and value.cloned or {}) do
    if type(k) == "string" then
      cloned[k] = true
    end
  end
  for _, k in ipairs(type(value.pins) == "table" and value.pins or {}) do
    if type(k) == "string" then
      pins[#pins + 1] = k
    end
  end
  for _, k in ipairs(type(value.hidden) == "table" and value.hidden or {}) do
    if type(k) == "string" then
      hidden[k] = true
    end
  end
end

local function saveData()
  local path = file("data.json")
  if path == nil then
    return
  end
  local list = {}
  for k in pairs(hidden) do
    list[#list + 1] = k
  end
  table.sort(list)
  local clonedList = {}
  for k in pairs(cloned) do
    clonedList[#clonedList + 1] = k
  end
  table.sort(clonedList)
  local text = noctalia.json.encode({ pins = pins, hidden = list, cloned = clonedList })
  if text == nil or not noctalia.writeFile(path .. ".tmp", text) or not noctalia.renameFile(path .. ".tmp", path) then
    lastError = { key = "error.save_failed" }
    log("saving data.json failed")
  end
end

-- ── entries ──────────────────────────────────────────────────────────────────
--
-- The host's Luau is slow: building one Entry (title, subtitle) costs ~0.2 ms and a
-- uris.parse ~0.1 ms, against a 25 ms budget per callback. So entries are cached by
-- key, the db list is parsed DB_CHUNK items per tick, callbacks only mark the list
-- dirty, and update() rebuilds it: one merge, then recents.split SPLIT_CHUNK entries
-- per tick, publishing when done.

local function isMissing(e)
  return missing[e.key] == true
end

-- recents.merge's opts.make: an Entry per key and kind, built once.
local function makeCached(uri, kind, mtime, h)
  local ck = uri.key .. "|" .. kind
  local e = entryCache[ck]
  if e == nil then
    e = recents.entry(uri, kind, mtime, h)
    entryCache[ck] = e
  end
  e.mtime = mtime
  return e
end

local function prewarm(list)
  for _, it in ipairs(list) do
    makeCached(it.uri, it.kind, it.mtime, home)
  end
end

local function headList()
  if dbList and #dbList > 0 then
    return dbList
  end
  return menuList or {}
end

local function wsList()
  local names = {}
  for name in pairs(wsCache) do
    names[#names + 1] = name
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local c = wsCache[name]
    if c.item then
      out[#out + 1] = { uri = c.item.uri, kind = c.item.kind, mtime = c.mtime }
    end
  end
  return out
end

local function enqueueMissing(key, path, force)
  if key:sub(1, 7) == "file://" and path:sub(1, 1) == "/" and not missingQueued[key] and (force or missing[key] == nil) then
    missingQueued[key] = true
    missingQueue[#missingQueue + 1] = { key = key, path = path }
  end
end

local function startBuild()
  local merged = recents.merge(headList(), wsList(), {
    -- show_hidden lists hidden projects again (marked e.hidden) so they can be unhidden.
    home = home, hidden = settings.show_hidden and {} or hidden, showRemote = settings.show_remote, make = makeCached,
  })
  local byKey, pinSet, found = {}, {}, {}
  for _, key in ipairs(pins) do
    pinSet[key] = true
    local u = uris.parse(key)
    if u and u.scheme == "file" then
      enqueueMissing(key, u.path, missingForce)
    end
  end
  for _, e in ipairs(merged) do
    byKey[e.key] = e
    if pinSet[e.key] then
      found[#found + 1] = e
    end
  end
  build = {
    list = merged, byKey = byKey, pinSet = pinSet, pos = 1, recent = {}, force = missingForce,
    pinned = (recents.split(found, pins, isMissing, settings.hide_missing, home)),
  }
  missingForce = false
end

local function stepBuild()
  local b = build
  local last = math.min(b.pos + SPLIT_CHUNK - 1, #b.list)
  local chunk = {}
  for i = b.pos, last do
    local e = b.list[i]
    if e.remote == nil then
      enqueueMissing(e.key, e.path, b.force)
    end
    if not b.pinSet[e.key] then
      chunk[#chunk + 1] = e
    end
  end
  b.pos = last + 1
  local _, part = recents.split(chunk, nil, isMissing, settings.hide_missing)
  for _, e in ipairs(part) do
    e.hidden = hidden[e.key] == true
    b.recent[#b.recent + 1] = e
  end
  if b.pos > #b.list then
    build = nil
    entries, lookup, pinned, recent = b.list, b.byKey, b.pinned, b.recent
    for _, e in ipairs(pinned) do
      lookup[e.key] = lookup[e.key] or e
    end
    publish()
  end
end

-- One heavy step per tick: the merge, or one split chunk. True after a merge.
local function runBuild()
  if build ~= nil then
    stepBuild()
  elseif dirty then
    dirty = false
    startBuild()
    return true
  end
  return false
end

local function runMissing()
  while budget > 0 and missingPos <= #missingQueue do
    local item = missingQueue[missingPos]
    missingPos = missingPos + 1
    missingQueued[item.key] = nil
    local gone = info(item.path) == nil
    -- Unchecked counts as present, so only a change against that shows.
    if (missing[item.key] == true) ~= gone then
      missingChanged = true
    end
    missing[item.key] = gone
  end
  if missingPos > #missingQueue then
    missingQueue, missingPos = {}, 1
    if missingChanged then
      missingChanged = false
      dirty = true
    end
  end
end

-- ── reading ──────────────────────────────────────────────────────────────────

local function userPath(rel)
  return configDir .. "/User/" .. rel
end

-- Each returns true when it started a read.
local function readDb(force)
  if not hasSqlite or configDir == nil then
    return false
  end
  local path = userPath("globalStorage/state.vscdb")
  local m = mtimeOf(path)
  if m == "absent" or (not force and m == dbSeen) then
    dbSeen = m
    return false
  end
  dbSeen = m
  local gen = flavorGen
  run({ "sqlite3", "-readonly", path, DB_QUERY }, READ_TIMEOUT_MS, function(r)
    if gen ~= flavorGen then
      return
    end
    if r.exitCode ~= 0 or r.timedOut then
      log("recents db read failed (exit " .. tostring(r.exitCode) .. ")")
      return
    end
    local text = trim(r.stdout)
    if text == "" then
      dbList, dbJob, dirty = {}, nil, true -- the key is absent: the menu is the head
      return
    end
    local ok, root = pcall(decode, text)
    if not ok or type(root) ~= "table" or type(root.entries) ~= "table" then
      log("recents db value unreadable")
      return
    end
    dbJob = { items = root.entries, i = 1, out = {} }
  end)
  return true
end

-- recents.parseDb DB_CHUNK raw items at a time; its decoder hands it the slice.
local function runDbJob()
  local job = dbJob
  if job == nil then
    return
  end
  local slice = {}
  for i = job.i, math.min(job.i + DB_CHUNK - 1, #job.items, DB_MAX) do
    slice[#slice + 1] = job.items[i]
  end
  job.i = job.i + DB_CHUNK
  local list = recents.parseDb("", function()
    return { entries = slice }
  end) or {}
  prewarm(list)
  for _, it in ipairs(list) do
    job.out[#job.out + 1] = it
  end
  if job.i > #job.items or job.i > DB_MAX then
    dbList, dbJob, dirty = job.out, nil, true
  end
end

local function readStorage(force)
  if configDir == nil then
    return false
  end
  local path = userPath("globalStorage/storage.json")
  local m = mtimeOf(path)
  if m == "absent" or (not force and m == storageSeen) then
    storageSeen = m
    return false
  end
  storageSeen = m
  local gen = flavorGen
  local accepted = noctalia.readFileAsync(path, function(text)
    if gen ~= flavorGen then
      return
    end
    -- The menu holds about ten items, so it fits in one callback.
    local list = text and recents.parseMenu(text, decode) or nil
    if list == nil then
      log("storage.json unreadable; keeping the previous list")
      return
    end
    prewarm(list)
    menuList, dirty = list, true
  end)
  if accepted ~= true then
    storageSeen = nil -- the host refused the read: try again on the next watch
  end
  return true
end

local function finishScanIfDone()
  local s = scan
  if s == nil or s.i <= #s.names or pendingReads > 0 then
    return
  end
  scan = nil
  local n = 0
  for name in pairs(wsCache) do
    if s.seen[name] then
      n = n + 1
    else
      wsCache[name] = nil
    end
  end
  loading, dirty, missingForce = false, true, true
  log(string.format("recents: %d head entries, %d history dirs", #headList(), n))
end

local function startScan()
  if configDir == nil then
    scan, loading, dirty = nil, false, true
    return
  end
  local dir = userPath("workspaceStorage")
  local names = noctalia.listDir(dir)
  scan = { dir = dir, names = names or {}, i = 1, seen = {}, gen = flavorGen }
end

local function runScan()
  local s = scan
  if s == nil then
    return
  end
  while budget > 0 and s.i <= #s.names do
    local name = s.names[s.i]
    local path = s.dir .. "/" .. name
    local st = info(path)
    if st and st.isDir then
      s.seen[name] = true
      local c = wsCache[name]
      if not (c and c.mtime == st.mtime) then
        pendingReads = pendingReads + 1
        local accepted = noctalia.readFileAsync(path .. "/workspace.json", function(text)
          pendingReads = pendingReads - 1
          if s.gen ~= flavorGen then
            return
          end
          local item = text and recents.parseWorkspaceJson(text, decode) or nil
          if item then
            makeCached(item.uri, item.kind, st.mtime, home)
          end
          wsCache[name] = { mtime = st.mtime, item = item }
          finishScanIfDone()
        end)
        if accepted ~= true then
          pendingReads = pendingReads - 1
          break -- the host caps reads in flight: retry this dir next tick
        end
      end
    end
    s.i = s.i + 1
  end
  finishScanIfDone()
end

-- ── flavor ───────────────────────────────────────────────────────────────────

-- Returns true when the flavor or its config dir changed.
local function chooseFlavor()
  installed = flavors.installed(noctalia.commandExists, function(d)
    return isDir(noctalia.expandPath(d))
  end)
  -- Both predicates look at the real config dirs; test-config-dir applies after the choice.
  local chosen = flavors.choose(SETTING_TO_FLAVOR[settings.editor] or settings.editor, installed, function(f)
    local st = info(noctalia.expandPath(f.configDir) .. "/User/globalStorage/storage.json")
    return st and st.mtime or nil
  end, function(f)
    -- History = a workspaceStorage dir with a workspace.json (an empty window leaves a dir
    -- without one). The first HISTORY_PROBE dirs are enough to tell.
    local dir = noctalia.expandPath(f.configDir) .. "/User/workspaceStorage"
    for i, name in ipairs(noctalia.listDir(dir) or {}) do
      if i > HISTORY_PROBE then
        break
      end
      if noctalia.fileExists(dir .. "/" .. name .. "/workspace.json") then
        return true
      end
    end
    return false
  end)
  flavorFallback = nil
  local wantedId = SETTING_TO_FLAVOR[settings.editor] or settings.editor
  if wantedId ~= nil and wantedId ~= "auto" and (chosen == nil or chosen.id ~= wantedId) then
    for _, f in ipairs(flavors.LIST) do
      if f.id == wantedId then
        local present
        if f.id == "flatpak" then
          present = noctalia.commandExists("flatpak") and noctalia.flatpakAppInstalled(f.cmd[3]) == true
        else
          present = noctalia.commandExists(f.cmd[1])
        end
        flavorFallback = { wanted = f.name, reason = present and "not_set_up" or "not_installed" }
      end
    end
  end
  local tcd = readText(file("test-config-dir"))
  tcd = tcd and trim(tcd) or nil
  if tcd == "" then
    tcd = nil
  end
  local dir = chosen and (tcd or noctalia.expandPath(chosen.configDir)) or nil
  local changed = (chosen and chosen.id) ~= (flavor and flavor.id) or dir ~= configDir
  flavor, configDir, testConfigDir = chosen, dir, chosen and tcd or nil
  flavorIcon = nil
  for _, id in ipairs(chosen and chosen.iconIds or {}) do
    flavorIcon = flavorIcon or noctalia.appIconPath(id)
  end
  if changed then
    flavorGen = flavorGen + 1
    dbList, dbJob, menuList, dbSeen, storageSeen = nil, nil, nil, nil, nil
    wsCache, entryCache, scan, loading, build, dirty = {}, {}, nil, true, nil, true
    missing, missingQueue, missingPos, missingQueued = {}, {}, 1, {}
    log("flavor " .. tostring(chosen and chosen.id))
  end
  return changed
end

local function reread()
  readDb(true)
  readStorage(true)
  startScan()
  dirty = true
end

-- ── opening ──────────────────────────────────────────────────────────────────

local function entryFor(key)
  if type(key) ~= "string" then
    return nil
  end
  if lookup[key] then
    return lookup[key]
  end
  local u = uris.parse(key)
  if u == nil then
    return nil
  end
  local kind = u.path:match("%.code%-workspace$") and "workspace" or "folder"
  return { key = u.key, uri = u.raw, kind = kind, remote = u.remote, host = u.host, path = u.path }
end

local function launch(e)
  if flavor == nil then
    lastError = { key = "error.no_flavor" }
    return
  end
  local argv = flavors.openArgv(flavor, e)
  if testConfigDir then
    argv[#argv + 1] = "--user-data-dir"
    argv[#argv + 1] = testConfigDir
  end
  if detached(argv) and hidden[e.key] then
    hidden[e.key] = nil
    saveData()
    dirty = true
  end
end

local function openPath(text)
  local r = flavors.parsePathInput(text, home, function(p)
    local st = noctalia.fileInfo(p)
    return st
  end)
  if not r.ok then
    pathError = r.err
    return
  end
  if flavors.sandboxHides(flavor, r.path) then
    pathError = "path.flatpak_hidden"
    return
  end
  pathError = nil
  local u = uris.fromPath(r.path)
  launch({ key = u.key, uri = u.raw, kind = r.kind, path = r.path })
end

local function unhide(key)
  if type(key) == "string" and hidden[key] then
    hidden[key] = nil
    saveData()
    dirty = true
  end
end

local function setMark(action, key)
  local e = entryFor(key)
  if e == nil then
    lastError = { key = "error.not_found" }
    return
  end
  local at
  for i, k in ipairs(pins) do
    if k == e.key then
      at = i
    end
  end
  if action == "pin" then
    if at == nil then
      pins[#pins + 1] = e.key
    end
  elseif action == "unpin" then
    if at ~= nil then
      table.remove(pins, at)
    end
  else
    hidden[e.key] = true
    if at ~= nil then
      table.remove(pins, at)
    end
  end
  saveData()
  dirty = true
end

-- ── git ──────────────────────────────────────────────────────────────────────

-- A result that arrives inside the loop (git could not start: run() calls back at
-- once) only marks gitChanged; each pump publishes at most once, after its loop.
local gitPumping, gitChanged = false, false

local function pumpGit()
  if gitPumping then
    return
  end
  gitPumping = true
  while gitInflight < GIT_MAX_INFLIGHT and #gitQueue > 0 do
    local job = table.remove(gitQueue, 1)
    gitInflight = gitInflight + 1
    run(gitinfo.argv(job.path), READ_TIMEOUT_MS, function(r)
      gitInflight = gitInflight - 1
      gitQueued[job.key] = nil
      local value = false
      if r.exitCode == 0 and not r.timedOut then
        value = gitinfo.parse(r.stdout)
      end
      gitCache[job.key] = { at = noctalia.nowMs(), value = value }
      gitChanged = true
      pumpGit()
    end)
  end
  gitPumping = false
  if gitChanged then
    gitChanged = false
    publish()
  end
end

local function requestGit(keys)
  if not settings.show_git or not hasGit or type(keys) ~= "table" then
    return
  end
  local now = noctalia.nowMs()
  for _, key in ipairs(keys) do
    local e = entryFor(key)
    if e and isLocal(e) and not missing[e.key] and not gitQueued[e.key] then
      local c = gitCache[e.key]
      if c == nil or now - c.at >= GIT_MAX_AGE_MS then
        gitQueued[e.key] = true
        gitQueue[#gitQueue + 1] = { key = e.key, path = folderOf(e) }
      end
    end
  end
  pumpGit()
end

-- ── folder picker ────────────────────────────────────────────────────────────

local function pickFolder()
  if not hasPicker or dataDir == nil then
    lastError = { key = "error.no_picker" }
    return
  end
  local picked = file("picked")
  if noctalia.fileExists(picked) then
    noctalia.removeFile(picked)
  end
  if detached(shell.pickArgv(dataDir, noctalia.tr("picker.title"))) then
    local now = noctalia.nowMs()
    pickUntilMs, pickNextMs = now + PICK_WINDOW_MS, now + POLL_MS
  end
end

local function pollPick(now)
  if pickUntilMs == nil or now < pickNextMs then
    return
  end
  pickNextMs = now + POLL_MS
  local text = readText(file("picked"))
  if text ~= nil then
    noctalia.removeFile(file("picked"))
    pickUntilMs = nil
    openPath(text)
    publish()
  elseif now > pickUntilMs then
    pickUntilMs = nil
  end
end

-- ── clone ────────────────────────────────────────────────────────────────────

local function jobFile(name)
  return file("clone/" .. name)
end

local function clearJob()
  for _, name in ipairs(JOB_FILES) do
    local path = jobFile(name)
    if path and noctalia.fileExists(path) then
      noctalia.removeFile(path)
    end
  end
end

local function readJob()
  local statusText = readText(jobFile("status"))
  local job = shell.parseJob(readText(jobFile("pid")), statusText)
  if job.pid ~= nil and job.pid <= 1 then
    job.pid = nil
  end
  if statusText ~= nil and job.exit == nil then
    job.exit = -1 -- a status file we cannot read is a failure, not a running job
  end
  return job
end

-- The pid file survives reboots, so its number may now belong to another process:
-- only a process whose command line names the clone script is ours.
local function ownsPid(pid)
  local cmdline = noctalia.readFile("/proc/" .. tostring(pid) .. "/cmdline")
  return type(cmdline) == "string" and cmdline:find("vscode-clone", 1, true) ~= nil
end

local function interrupted()
  clone = { state = "failed", name = clone.name, dest = clone.dest, error = noctalia.tr("error.clone_interrupted") }
  cloneCancel = false
  clearJob()
  publish()
end

local function cancelNow(pid)
  if not ownsPid(pid) then
    interrupted() -- never signal a process group that isn't the clone's
    return
  end
  noctalia.runAsync(shell.cancelArgv(pid))
  clone = { state = "cancelled", name = clone.name, dest = clone.dest }
  cloneCancel = false
  clearJob()
end

local function startClone(url)
  -- jobChecking: a leftover job is being checked at start; its files must stay.
  if clone.state == "running" or jobChecking then
    lastError = { key = "error.busy_clone" }
    return
  end
  if not hasGit or dataDir == nil then
    lastError = { key = "error.no_git" }
    return
  end
  url = trim(url)
  local name = uris.isGitUrl(url) and uris.cloneName(url) or nil
  if name == nil then
    lastError = { key = "error.bad_url" }
    return
  end
  local base = (noctalia.expandPath(settings.clone_dir):gsub("/+$", ""))
  local dest = base .. "/" .. name
  if noctalia.fileInfo(dest) ~= nil then
    clone = { state = "exists", name = name, dest = dest }
    return
  end
  local jobDir = file("clone")
  if not noctalia.mkdirAll(base) or not noctalia.mkdirAll(jobDir) then
    lastError = { key = "error.clone_dir" }
    return
  end
  clearJob()
  noctalia.writeFile(jobFile("job.json"), noctalia.json.encode({ name = name, dest = dest }))
  if detached(shell.cloneArgv(url, dest, jobDir)) then
    local now = noctalia.nowMs()
    clone = { state = "running", name = name, dest = dest }
    cloneNextMs, cloneAliveMs, cloneCancel = now + POLL_MS, now + ALIVE_CHECK_MS, false
    clonePidDeadlineMs = now + NO_PID_MS
  end
end

local function cancelClone()
  if clone.state ~= "running" then
    return
  end
  local job = readJob()
  if job.pid then
    cancelNow(job.pid)
  else
    cloneCancel = true -- the script has not written its pid yet; the poll kills it
  end
end

-- The job's process is gone without a status (killed, or Noctalia restarted mid-clone).
local function checkAlive(pid, onAlive)
  run({ "kill", "-0", tostring(pid) }, READ_TIMEOUT_MS, function(r)
    jobChecking = false
    if r.exitCode == 0 and not r.timedOut and ownsPid(pid) then
      onAlive()
    elseif readText(jobFile("status")) == nil then
      interrupted()
    end
  end)
end

local function pollClone(now)
  if clone.state ~= "running" or now < cloneNextMs then
    return
  end
  cloneNextMs = now + POLL_MS
  local job = readJob()
  if cloneCancel and job.pid then
    cancelNow(job.pid)
    publish()
    return
  end
  if job.pid == nil and job.exit == nil and now >= clonePidDeadlineMs then
    -- The script never started (or never wrote its pid): end the job.
    if cloneCancel then
      clone = { state = "cancelled", name = clone.name, dest = clone.dest }
    else
      clone = { state = "failed", name = clone.name, dest = clone.dest, error = noctalia.tr("error.clone_failed") }
    end
    cloneCancel = false
    clearJob()
    publish()
    return
  end
  local text = readText(jobFile("log")) or ""
  if job.exit == nil then
    local progress = shell.cloneProgress(text)
    if progress ~= clone.progress then
      clone = { state = "running", name = clone.name, dest = clone.dest, progress = progress }
      publish()
    end
    if job.pid and now >= cloneAliveMs then
      cloneAliveMs = now + ALIVE_CHECK_MS
      checkAlive(job.pid, function() end)
    end
    return
  end
  if job.exit == 0 then
    clone = { state = "done", name = clone.name, dest = clone.dest }
    local u = uris.fromPath(clone.dest)
    cloned[u.key] = true
    saveData()
    launch({ key = u.key, uri = u.raw, kind = "folder", path = clone.dest })
    noctalia.notify(noctalia.tr("plugin.name"), noctalia.tr("notify.cloned", { name = clone.name }))
  else
    clone = { state = "failed", name = clone.name, dest = clone.dest, error = shell.cloneError(text) or noctalia.tr("error.clone_failed") }
  end
  clearJob()
  publish()
end

-- On start: a job with a pid and no status is resumed if its process still runs, else failed.
local function checkStaleJob()
  local job = readJob()
  if job.pid == nil or job.exit ~= nil then
    clearJob()
    return
  end
  local ok, meta = pcall(decode, readText(jobFile("job.json")) or "")
  if not ok or type(meta) ~= "table" or type(meta.name) ~= "string" or type(meta.dest) ~= "string" then
    meta = {}
  end
  clone = { state = "idle", name = meta.name, dest = meta.dest }
  jobChecking = true
  checkAlive(job.pid, function()
    if meta.dest then
      local now = noctalia.nowMs()
      clone = { state = "running", name = meta.name, dest = meta.dest }
      cloneNextMs, cloneAliveMs, clonePidDeadlineMs = now, now + ALIVE_CHECK_MS, now + NO_PID_MS
      publish()
    end
  end)
end

-- ── requests ─────────────────────────────────────────────────────────────────

local function setTick()
  local busy = scan ~= nil or dbJob ~= nil or dirty or build ~= nil or missingPos <= #missingQueue
  local want = busy and TICK_FAST_MS or TICK_SLOW_MS
  if want ~= tickMs then
    tickMs = want
    noctalia.setUpdateInterval(want)
  end
end

local function refresh()
  pathError = nil
  chooseFlavor()
  reread()
end

local PASSIVE = { refresh = true, git = true, dismiss_error = true }

local function handleRequest(req)
  if type(req) ~= "table" or type(req.action) ~= "string" then
    return
  end
  local a = req.action
  if not PASSIVE[a] then
    lastError = nil
  end
  if a == "refresh" then
    refresh()
  elseif a == "open" then
    local e = entryFor(req.key)
    if e then
      launch(e)
    else
      lastError = { key = "error.not_found" }
    end
  elseif a == "open_path" then
    openPath(req.text)
  elseif a == "pin" or a == "unpin" or a == "hide" then
    setMark(a, req.key)
  elseif a == "unhide" then
    unhide(req.key)
  elseif a == "copy_path" then
    local e = entryFor(req.key)
    if e then
      noctalia.copyToClipboard(isLocal(e) and e.path or e.uri, "text/plain")
    end
  elseif a == "open_terminal" then
    local e = entryFor(req.key)
    if e and isLocal(e) and noctalia.runInTerminal(shell.terminalCommand(folderOf(e))) == false then
      lastError = { key = "error.terminal_failed" }
    end
  elseif a == "open_files" then
    local e = entryFor(req.key)
    if e and isLocal(e) then
      detached({ "xdg-open", folderOf(e) })
    end
  elseif a == "pick_folder" then
    pickFolder()
  elseif a == "git" then
    requestGit(req.keys)
  elseif a == "clone" then
    startClone(req.url)
  elseif a == "cancel_clone" then
    cancelClone()
  elseif a == "clear_clone" then
    -- The panel reopened after a clone ended well: drop the status line only.
    if clone.state == "done" or clone.state == "cancelled" then
      clone = { state = "idle" }
    end
  elseif a == "dismiss_error" then
    -- Clears the error and path error, and a finished clone's status line.
    lastError, pathError = nil, nil
    if clone.state ~= "running" then
      clone = { state = "idle" }
    end
  end
  requestSeq = requestSeq + 1
  publish()
  setTick()
end

noctalia.state.watch(REQUEST_KEY, handleRequest)

function onIpc(event, payload)
  if event ~= "request" or type(payload) ~= "string" then
    return
  end
  local ok, value = pcall(decode, payload)
  if ok and type(value) == "table" then
    handleRequest(value)
  end
end

local function applySettings()
  local s = readSettings()
  local sig = sigOf(s)
  if sig == settingsSig then
    return
  end
  local editorChanged = settings.editor ~= s.editor
  settings, settingsSig = s, sig
  if editorChanged and chooseFlavor() then
    reread()
  end
  dirty = true
end

function onConfigChanged()
  applySettings()
  setTick()
end

function update()
  budget = INFO_BUDGET
  local now = noctalia.nowMs()
  applySettings()
  if now >= nextWatchMs then
    nextWatchMs = now + WATCH_MS
    local a = readDb(false)
    local b = readStorage(false)
    if a or b then
      startScan() -- VS Code opened something: its workspaceStorage may have a new dir
    end
  end
  local heavy = dbJob ~= nil
  if heavy then
    runDbJob()
  else
    heavy = runBuild()
  end
  if not heavy then
    runScan() -- the merge or a db slice already used most of this tick's budget
  end
  runMissing()
  pollPick(now)
  pollClone(now)
  setTick()
end

-- ── start ────────────────────────────────────────────────────────────────────

settings = readSettings()
settingsSig = sigOf(settings)
hasGit = noctalia.commandExists("git")
hasPicker = noctalia.commandExists("zenity") and noctalia.commandExists("setsid")
hasSqlite = noctalia.commandExists("sqlite3")
loadData()
chooseFlavor()
log("service started")
nextWatchMs = noctalia.nowMs() + WATCH_MS
reread()
publish()
checkStaleJob()
setTick()
