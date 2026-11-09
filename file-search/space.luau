--!nonstrict
-- file-search — the Space tab of the panel: a disk-usage browser.
--
-- Role: a module required by panel.luau (never an entry of its own). The panel
-- calls onOpen(redraw) when the Space tab is shown, onClose() with the panel,
-- and embeds whatever render() returns under the tab bar. This file owns the
-- scan engine, its state and the tab UI (path line, donut, legend, sorted
-- list). The panel calls space.step() on its frame tick while
-- space.needsTick() is true: scans and index loads only advance there. Any
-- visible change calls redraw, never while the panel is closed.
--
-- UI state (file-locals): path (node stack from space.index down to the
-- current folder; re-walked by name when a new index lands), sortKey
-- ("size" | "name" | "path"; path in Types mode only), sortDesc,
-- mode ("folders" | "types"), typeFilter (a category number in Types mode,
-- nil = none; cleared by entering a folder, going up or switching mode).
-- space.typeFilter is a test-only mirror of it. With a category, the folder all
-- listed files share (idx.commonDir) is shown once above the list.
--
-- State (module fields, read by the panel):
--   space.state     "idle" | "scanning" | "ready" | "error". A stale index
--                   stays "ready" while its rescan runs (see space.scanning).
--   space.scanning  a scan of space.root is in flight (probes, run or load)
--   space.loading   an index is being decoded, a slice per step()
--   space.errText   last failure, one of:
--                     "ncdu"      ncdu not found, or its --version unreadable
--                     "ncdu_old"  ncdu older than 2.0
--                     "jq"        jq not found
--                     "datadir"   no plugin data directory
--                     "spawn"     the host refused to start a process
--                     "timeout"   version probe timed out, or no result
--                                 within SCAN_DEADLINE_MS
--                     "empty"     ncdu wrote no scan file
--                     "reduce"    jq or the final mv failed
--                     "index"     the new index file does not decode
--                     "index_big" the index is over INDEX_MAX_BYTES, or the
--                                 heap passed HEAP_SOFT_BYTES during its load
--   space.root      the home path (the start) or "/"
--   space.index     decoded index tree (see space_index.luau), nil = none
--   space.scannedAt unix seconds of the index file (its mtime)
--   space.phase     "scan" (ncdu) | "reduce" (jq) while the run is in flight
--   space.elapsedMs time since the run started, nil without a run
--   space.progress  ESTIMATE 0..0.95: elapsedMs over the duration of the last
--                   complete scan of this root and settings tag; nil without one.
--
-- Pipeline:
--   1. `ncdu --version` with a callback, once per load (ncdu >= 2.0).
--   2. shared.probeMounts, so removable disks can be excluded; skipped while
--      space_skip_external is off.
--   3. One DETACHED `/bin/sh -c SCAN_SCRIPT` (runAsync without callback): ncdu,
--      then jq into a temp file, `mv -f` onto the index, scan file removed, a
--      one-word marker file written. The script text is a constant; every path,
--      exclude and the jq program are positional parameters. Binaries are
--      absolute (TOOL_DIRS).
--   4. step() polls the marker and the phase file about once a second, then
--      loads the index.
--
-- The index is JSON Lines (see idx.jqProgram) decoded a few lines per step(),
-- within SLICE_MS. space.index keeps the previous tree until the new one is
-- complete. Heap guard: an index over INDEX_MAX_BYTES, or a load that passes
-- HEAP_SOFT_BYTES (gcinfo()), is refused and not read again until a new scan.
--
-- The index file name carries space.settingsTag(): a changed exclusion
-- setting points at another file, and space.onConfigChanged drops the index
-- in memory. A completed scan removes the same root's files of other tags.
--
-- A scan is a job table; setRoot() or a newer scan replaces it, and anything
-- belonging to an older job (probe answer, marker) is ignored. Leftovers of
-- dropped runs are swept when the next run starts, and on open when no job is
-- active.

local shared = require("./shared.luau")
local usage = require("./usage.luau")
local idx = require("./space_index.luau")

local space = {}

space.VERSION_TIMEOUT_MS = 5000
space.POLL_MS = 1000
space.SLICE_MS = 8
space.SCAN_DEADLINE_MS = 1800000
-- Longest wait for the mount probe before launching anyway.
space.PROBE_WAIT_MS = 15000
space.INDEX_MAX_BYTES = 9 * 1048576
space.HEAP_SOFT_BYTES = 72 * 1048576

-- Values recorded with their measurements in the header of space_index.luau.
local DEPTH, TOP_N, MIN_BYTES, REL_MIN = 6, 10, 1048576, 0.0005
space.TOP_N = TOP_N -- read by tests/space_ui_test.lua

local TOOL_DIRS = { "/usr/bin", "/usr/local/bin", "/bin", "~/.local/bin" }

-- $1 ncdu  $2 jq  $3 jq program  $4 scan file  $5 temp  $6 index  $7 marker
-- $8 nice ("" = none), then the ncdu arguments. "$d.phase" says "reduce" while
-- jq runs.
local SCAN_SCRIPT = table.concat({
    'echo 1000 2>/dev/null > /proc/self/oom_score_adj',
    'n=$1 j=$2 p=$3 s=$4 t=$5 i=$6 d=$7 c=$8',
    'shift 8',
    'run() { if [ -n "$c" ]; then "$c" -n 19 "$@"; else "$@"; fi; }',
    'run "$n" -0 -o "$s" "$@" >/dev/null 2>&1',
    'echo reduce > "$d.phase"',
    'if [ ! -s "$s" ]; then r=empty',
    'elif run "$j" -c "$p" "$s" > "$t" 2>/dev/null && mv -f "$t" "$i"; then r=ok',
    'else r=reduce; fi',
    'rm -f "$s" "$t" "$d.phase"',
    'echo "$r" > "$d"',
}, "\n")
space.SCAN_SCRIPT = SCAN_SCRIPT -- read by tests/space_script_test.sh

space.state = "idle"
space.scanning = false
space.loading = false
space.errText = nil
local function homeRoot()
    local home = noctalia.expandPath("~")
    return type(home) == "string" and home ~= "" and home or "/"
end

space.root = homeRoot()
space.index = nil
space.scannedAt = 0
space.progress = nil
space.phase = nil
space.elapsedMs = nil

local scanCount = 0
local ncduOld = nil -- nil = not probed yet
local job = nil     -- { dir, done, probeUntil?, marker?, deadline, nextPoll, loading? }
local loader = nil  -- { text, pos, nodes, tree, at, path, size }
local tripped = nil -- { path, size } of the index that tripped the heap guard
local deferred = nil -- done() of a scan waiting for the current load to end
local generation = 0 -- bumped per loaded index, keys the chart cache
local seenTag = nil -- settings tag of the index, load or scan in hand (nil = none yet)

-- Panel side (see the panel hooks below).
local isOpen = false
local redraw = nil

local function changed()
    if isOpen and redraw ~= nil then
        redraw()
    end
end

-- ── files and tools ──────────────────────────────────────────────────────────

local function rootTag(root)
    return root == "/" and "root" or "home"
end

-- One index file per root and settings tag (see space.settingsTag), and the
-- duration of the scan that wrote it (`ext` "time").
local function indexPath(dir, root, tag, ext)
    return dir .. "/space-" .. rootTag(root) .. "-" .. tag .. "." .. (ext or "json")
end

-- Removes the scan, temp, marker and phase files of runs.
local function sweep(dir)
    for _, name in ipairs(noctalia.listDir(dir) or {}) do
        if name:match("^space%-.+%.scan$") or name:match("^space%-.+%.tmp$") or name:match("^space%-.+%.done$")
            or name:match("^space%-.+%.phase$") then
            noctalia.removeFile(dir .. "/" .. name)
        end
    end
end

-- After a scan of `tag` completed: the index and duration files of the same
-- root built with other settings, and the untagged name.
local function dropOldIndexes(dir, root, tag)
    local rt = rootTag(root)
    local stem = "space-" .. rt .. "-" .. tag
    for _, name in ipairs(noctalia.listDir(dir) or {}) do
        if name ~= stem .. ".json" and name ~= stem .. ".time" and (name == "space-" .. rt .. ".json"
            or name:match("^space%-" .. rt .. "%-%x+%.json$") or name:match("^space%-" .. rt .. "%-%x+%.time$")) then
            noctalia.removeFile(dir .. "/" .. name)
        end
    end
end

local function findTool(name)
    for _, dir in ipairs(TOOL_DIRS) do
        local path = noctalia.expandPath(dir) .. "/" .. name
        if noctalia.fileExists(path) then
            return path
        end
    end
    return nil
end

-- ── settings ─────────────────────────────────────────────────────────────────

-- space_skip_network, space_skip_external; nil (not set yet) reads as true.
local function skips()
    return noctalia.getConfig("space_skip_network") ~= false, noctalia.getConfig("space_skip_external") ~= false
end

-- 8 hex chars (djb2) over every setting that shapes the scan and the index
-- tuning (depth, top files, fold sizes); part of the index file name.
function space.settingsTag()
    local net, ext = skips()
    local dirs = noctalia.getConfig("usage_exclude_dirs")
    local key = string.format("net=%d;ext=%d;dirs=%s;build=%d/%d/%d/%g", net and 1 or 0, ext and 1 or 0,
        type(dirs) == "string" and dirs or "", DEPTH, TOP_N, MIN_BYTES, REL_MIN)
    local h = 5381
    for i = 1, #key do
        h = (h * 33 + string.byte(key, i)) % 4294967296
    end
    return string.format("%08x", h)
end

function space.excludeArgs()
    local args = { "--exclude-kernfs" }
    local skipNet, skipExt = skips()
    for _, path in ipairs(shared.prunePaths({ network = skipNet, external = skipExt })) do
        table.insert(args, "--exclude")
        -- fnmatch metacharacters are backslash-escaped
        table.insert(args, (path:gsub("[%*%?%[%]\\]", "\\%0")))
    end
    for _, pattern in ipairs(usage.excludes()) do
        table.insert(args, "--exclude")
        table.insert(args, pattern)
    end
    return args
end

function space.checkTools()
    if findTool("ncdu") == nil then
        return "ncdu"
    end
    if ncduOld then
        return "ncdu_old"
    end
    if findTool("jq") == nil then
        return "jq"
    end
    return nil
end

-- ── scan end ─────────────────────────────────────────────────────────────────

-- Settles the state, then calls done(). A failure keeps an index already on
-- screen ("ready" + errText).
local function endScan(errText)
    local done = job and job.done
    job = nil
    space.scanning = false
    space.progress, space.phase, space.elapsedMs = nil, nil, nil
    if errText ~= nil then
        space.errText = errText
        if space.index == nil then
            space.state = "error"
        end
    end
    if done then
        done()
    end
    changed()
end

-- ── index load ───────────────────────────────────────────────────────────────

-- An index the heap guard refuses: remembered so it is not read again. A scan
-- load reports it through endScan; a cache load sets the notice here.
local function tooBig(path, size)
    tripped = { path = path, size = size }
    if not (job ~= nil and job.loading) then
        space.errText = "index_big"
        if space.index == nil then
            space.state = "error"
        end
        changed()
    end
    return false, "index_big"
end

-- Reads the index of space.root and checks its header; the records are
-- decoded by step(). False (nothing loading) for a missing, corrupted or
-- other-version file. False, "index_big" for a file the heap guard refuses
-- (see tooBig). `tag` defaults to the current settings.
function space.startLoad(dir, tag)
    loader = nil
    space.loading = false
    tag = tag or space.settingsTag()
    seenTag = tag
    if dir == nil then
        return false
    end
    local path = indexPath(dir, space.root, tag)
    local info = noctalia.fileInfo(path)
    local size = info and info.size
    if size ~= nil and (size > space.INDEX_MAX_BYTES or (tripped and tripped.path == path and tripped.size == size)) then
        return tooBig(path, size)
    end
    local text = noctalia.readFile(path)
    if type(text) == "string" and #text > space.INDEX_MAX_BYTES then
        return tooBig(path, size or #text)
    end
    local nl = type(text) == "string" and text:find("\n", 1, true)
    if not nl then
        return false
    end
    local ok, head = pcall(noctalia.json.decode, text:sub(1, nl - 1))
    if not ok or type(head) ~= "table" or head.v ~= 4 then
        return false
    end
    loader = { text = text, pos = nl + 1, nodes = {}, tree = nil, at = info and info.mtime or 0, path = path, size = size or #text }
    space.loading = true
    return true
end

-- One record into the tree being built; false = the index is unusable.
local function addRecord(l, line)
    local ok, r = pcall(noctalia.json.decode, line)
    if not ok or type(r) ~= "table" or type(r.id) ~= "string" or l.nodes[r.id] ~= nil
        or type(r.n) ~= "string" or type(r.s) ~= "number" or type(r.c) ~= "table" or type(r.t) ~= "table" then
        return false
    end
    local node = { n = r.n, s = r.s, f = r.f or 0, u = type(r.u) == "number" and r.u or 0,
        nf = type(r.nf) == "number" and r.nf or 0, c = r.c, t = r.t, d = {}, leaf = r.leaf }
    local parentId = r.id:match("^(.+)/%d+$")
    if parentId ~= nil then
        local parent = l.nodes[parentId]
        if parent == nil then
            return false
        end
        table.insert(parent.d, node)
    elseif r.id == "0" then
        l.tree = node
    else
        return false
    end
    l.nodes[r.id] = node
    return true
end

-- `why` names the failure of a nil tree for endScan ("index" when omitted).
local function endLoad(tree, at, why)
    loader = nil
    space.loading = false
    local scanLoad = job ~= nil and job.loading
    if tree == nil then
        if scanLoad then
            endScan(why or "index")
        end
        return
    end
    space.index = tree
    generation += 1
    space.scannedAt = at
    space.state = "ready"
    space.errText = nil
    if scanLoad then
        dropOldIndexes(job.dir, space.root, job.tag)
        endScan(nil)
    else
        changed()
    end
end

-- At least one line per call, then lines until SLICE_MS is spent.
local function sliceLoad(started)
    local l = loader
    if gcinfo() * 1024 > space.HEAP_SOFT_BYTES then
        local _, why = tooBig(l.path, l.size)
        endLoad(nil, nil, why)
        return
    end
    repeat
        local text = l.text
        local nl = text:find("\n", l.pos, true)
        local stop = nl and nl - 1 or #text
        local line = text:sub(l.pos, stop)
        l.pos = stop + 2
        if line ~= "" and not addRecord(l, line) then
            endLoad(nil)
            return
        end
        if l.pos > #text then
            endLoad(l.tree, l.at)
            return
        end
    until noctalia.nowMs() - started >= space.SLICE_MS
end

-- ── scan ─────────────────────────────────────────────────────────────────────

function space.fresh()
    return space.state == "ready" and space.index ~= nil
        and (shared.now() - space.scannedAt) < usage.TTL_SECONDS
end

-- Drops the current index and any scan or load in progress.
local function reset()
    job = nil
    loader = nil
    deferred = nil
    space.index = nil
    space.scannedAt = 0
    space.scanning = false
    space.loading = false
    space.progress, space.phase, space.elapsedMs = nil, nil, nil
    space.state = "idle"
    space.errText = nil
end

-- Drops the current root's state and starts loading the new root's index.
function space.setRoot(root)
    if root == space.root then
        return
    end
    reset()
    space.root = root
    space.startLoad(shared.dataDir())
end

local function start(current)
    current.probeUntil = nil
    -- Checked again after the async probes.
    local missing = space.checkTools()
    if missing ~= nil then
        endScan(missing)
        return
    end
    local root = space.root
    local dir = current.dir
    current.tag = space.settingsTag()
    seenTag = current.tag
    scanCount += 1
    local stem = string.format("%s/space-%s-%d-%d", dir, rootTag(root), noctalia.nowMs(), scanCount)
    sweep(dir)
    local argv = {
        "/bin/sh", "-c", SCAN_SCRIPT, "sh",
        findTool("ncdu"), findTool("jq"), idx.jqProgram(DEPTH, TOP_N, MIN_BYTES, REL_MIN),
        stem .. ".scan", stem .. ".tmp", indexPath(dir, root, current.tag), stem .. ".done",
        findTool("nice") or "",
    }
    for _, arg in ipairs(space.excludeArgs()) do
        table.insert(argv, arg)
    end
    table.insert(argv, "--")
    table.insert(argv, root)
    if not noctalia.runAsync(argv) then
        endScan("spawn")
        return
    end
    local now = noctalia.nowMs()
    current.marker = stem .. ".done"
    current.deadline = now + space.SCAN_DEADLINE_MS
    current.nextPoll = now + space.POLL_MS
    current.started = now
    current.timeFile = indexPath(dir, root, current.tag, "time")
    local last = tonumber((noctalia.readFile(current.timeFile) or ""):match("^%d+$"))
    current.lastMs = last ~= nil and last > 0 and last or nil
    space.phase, space.elapsedMs = "scan", 0
    space.progress = current.lastMs and 0 or nil
    current.shown = space.progressText()
    changed()
end

-- Progress of the run in hand; a redraw only when its label changes (a whole
-- percent, the phase, or an elapsed second without an estimate).
local function track(now)
    if space.phase == "scan" then
        local text = noctalia.readFile(job.marker .. ".phase")
        if type(text) == "string" and text:match("^reduce") then
            space.phase = "reduce"
        end
    end
    space.elapsedMs = now - job.started
    space.progress = job.lastMs and math.min(0.95, space.elapsedMs / job.lastMs) or nil
    local shown = space.progressText()
    if shown ~= job.shown then
        job.shown = shown
        changed()
    end
end

-- Starts the run, after the mount probe when removable disks are skipped; step()
-- starts it anyway after PROBE_WAIT_MS.
local function launch(current)
    local _, skipExt = skips()
    if not skipExt then
        start(current)
        return
    end
    current.probeUntil = noctalia.nowMs() + space.PROBE_WAIT_MS
    shared.probeMounts(false, function()
        if job == current and current.probeUntil ~= nil then
            start(current)
        end
    end, true)
end

local function poll(now)
    if now < job.nextPoll then
        return
    end
    job.nextPoll = now + space.POLL_MS
    track(now)
    local text = noctalia.readFile(job.marker)
    local code = type(text) == "string" and text:match("^(%a+)") or nil
    if code == nil then
        if now > job.deadline then
            endScan("timeout")
        end
        return
    end
    noctalia.removeFile(job.marker)
    job.marker = nil
    if code ~= "ok" then
        endScan(code == "empty" and "empty" or "reduce")
        return
    end
    noctalia.writeFile(job.timeFile, tostring(now - job.started))
    job.loading = true
    tripped = nil
    local ok, why = space.startLoad(job.dir, job.tag)
    if not ok then
        endScan(why or "index")
    end
end

-- Scan `root` (switching to it first), then call done() unless the scan was
-- dropped by setRoot. `force` skips the TTL; a scan of the current root
-- already in flight is never doubled. While an index loads the TTL check
-- waits for it.
function space.scan(root, force, done)
    space.setRoot(root)
    if space.scanning then
        return
    end
    if space.loading and not force then
        deferred = done
        return
    end
    if not force and (space.fresh() or space.errText == "index_big") then
        done()
        return
    end
    job = { done = done }
    space.scanning = true
    if space.index == nil then
        space.state = "scanning"
    end
    local missing = space.checkTools()
    if missing ~= nil then
        endScan(missing)
        return
    end
    job.dir = shared.dataDir()
    if job.dir == nil then
        endScan("datadir")
        return
    end
    if ncduOld ~= nil then
        launch(job)
        return
    end
    local current = job
    local started = noctalia.runAsync({ findTool("ncdu"), "--version" }, function(result)
        local major = tonumber((result.stdout or ""):match("ncdu (%d+)%."))
        if major ~= nil then
            ncduOld = major < 2
        end
        if job ~= current then
            return
        end
        if result.timedOut then
            endScan("timeout")
        elseif major == nil then
            endScan("ncdu")
        elseif ncduOld then
            endScan("ncdu_old")
        else
            launch(current)
        end
    end, space.VERSION_TIMEOUT_MS)
    if not started then
        endScan("spawn")
    end
end

-- Advances a running scan (marker poll) and an index load (one slice).
-- True while anything is left to wait for.
function space.step()
    local now = noctalia.nowMs()
    if job ~= nil and job.probeUntil ~= nil and now > job.probeUntil then
        start(job)
    end
    if job ~= nil and job.marker ~= nil then
        poll(now)
    end
    if loader ~= nil then
        sliceLoad(now)
    end
    if deferred ~= nil and not space.loading and job == nil then
        local done = deferred
        deferred = nil
        space.scan(space.root, false, done)
        changed()
    end
    return space.needsTick()
end

function space.needsTick()
    return space.scanning or space.loading
end

-- ── navigation ───────────────────────────────────────────────────────────────

local LEFT_WIDTH = 340
local DONUT_SIZE = 200
local DONUT_THICKNESS = 28
local LABEL_MAX = 34     -- legend
local ROW_LABEL_MAX = 52 -- list rows
local ROW_LABEL_MAX_FILES = 44 -- list rows with a file count
local FILES_WIDTH = 64
local ROW_HEIGHT = 22
local MAX_ROWS = 200
local SVG_NAMES = { "space-a.svg", "space-b.svg" }
local GREY = { dark = { other = "#5b6180", loose = "#3d4256" }, light = { other = "#9aa2b8", loose = "#c3c8d6" } }

local path = {}       -- nodes from space.index down to the current folder
local sortKey = "size"
local sortDesc = true
local mode = "folders"
local typeFilter = nil -- category number, Types mode only
local svg = { slot = 0, path = nil, key = nil } -- written image and what it shows

-- The current folder; a new index is walked again by name.
local function current()
    local tree = space.index
    if tree == nil then
        path = {}
        return nil
    end
    if path[1] ~= tree then
        local fresh = { tree }
        for i = 2, #path do
            local child = idx.child(fresh[#fresh], path[i].n)
            if child == nil then
                break
            end
            table.insert(fresh, child)
        end
        path = fresh
    end
    return path[#path]
end

-- Absolute path of the current folder (+ `rel`), built from space.root.
local function absolute(rel)
    local parts = { space.root == "/" and "" or space.root }
    for i = 2, #path do
        table.insert(parts, path[i].n)
    end
    if rel ~= nil then
        table.insert(parts, rel)
    end
    local out = table.concat(parts, "/")
    return out == "" and "/" or out
end

-- Control characters become spaces, and long names are cut to `max`
-- characters with "…" (unless the UTF-8 is invalid). keepEnd keeps the tail,
-- from a "/" when the tail has one.
local function display(name, max, keepEnd)
    local text = name:gsub("%c", " ")
    local len = utf8.len(text)
    if len == nil or len <= max then
        return text
    end
    if not keepEnd then
        return text:sub(1, utf8.offset(text, max) - 1) .. "…"
    end
    local tail = text:sub(utf8.offset(text, len - max + 2))
    return "…" .. (tail:match("^[^/]*(/.+)$") or tail)
end

function space.up()
    if #path > 1 then
        table.remove(path)
        typeFilter, space.typeFilter = nil, nil
        changed()
    end
end

function space.top()
    if #path > 1 then
        path = { path[1] }
        typeFilter, space.typeFilter = nil, nil
        changed()
    end
end

function space.enter(name)
    local node = current()
    local child = node and idx.child(node, name)
    if child ~= nil and not child.leaf then
        table.insert(path, child)
        typeFilter, space.typeFilter = nil, nil
        changed()
    end
end

function space.setSort(key)
    if key == sortKey then
        sortDesc = not sortDesc
    else
        sortKey = key
        sortDesc = key == "size" -- name and path start ascending
    end
    changed()
end

function space.setMode(value)
    mode = value
    if mode == "folders" and sortKey == "path" then
        sortKey = "name"
    end
    typeFilter, space.typeFilter = nil, nil
    changed()
end

function space.setTypeFilter(category)
    typeFilter = category
    space.typeFilter = category -- read-only mirror for tests
    changed()
end

local function noop() end

-- Switches between home and "/"; refused while a scan runs.
function space.toggleRoot()
    if space.scanning then
        return
    end
    path = {}
    typeFilter, space.typeFilter = nil, nil
    space.scan(space.root == "/" and homeRoot() or "/", false, noop)
    changed()
end

function space.refresh()
    space.scan(space.root, true, noop)
    changed()
end

-- Reveals a top file of the current folder (Types mode); a missing file is a notice.
local function revealFile(rel)
    local full = absolute(rel)
    if not noctalia.fileExists(full) then
        noctalia.notify(shared.tr("title"), shared.tr("space_gone", { path = full }))
        return
    end
    shared.revealPath(full)
end

-- The right-click menu of a list row (same items as the Search tab's, see
-- panel.luau openResultMenu). The path rides as the context string; the panel's
-- global onSpaceMenu hands the pick back to menuAction.
function space.openMenu(entry)
    panel.openContextMenu({
        onActivate = "onSpaceMenu",
        context = absolute(entry.name),
        items = {
            { kind = "header", label = display(entry.name, ROW_LABEL_MAX, entry.kind == "file") },
            { id = "open", label = shared.tr("menu.open") },
            { id = "reveal", label = shared.tr("menu.reveal") },
            { kind = "separator" },
            { id = "copy_path", label = shared.tr("menu.copy_path") },
            { id = "copy_name", label = shared.tr("menu.copy_name") },
        },
    })
end

function space.menuAction(action, path)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
        return
    end
    if action == "copy_path" or action == "copy_name" then
        noctalia.copyToClipboard(action == "copy_path" and path or path:match("[^/]+$") or path, "text/plain")
        noctalia.notify(shared.tr("title"), shared.tr(action == "copy_path" and "copied_entry" or "copied_name"))
    elseif action == "open" or action == "reveal" then
        if not noctalia.fileExists(path) then
            noctalia.notify(shared.tr("title"), shared.tr("space_gone", { path = path }))
        elseif action == "reveal" then
            shared.revealPath(path)
        else
            shared.openPath(path)
            panel.close()
        end
    end
end

-- ── donut ────────────────────────────────────────────────────────────────────

local function paint(slices)
    local dark = noctalia.isDarkMode()
    local palette = dark and idx.COLORS_DARK or idx.COLORS_LIGHT
    local grey = dark and GREY.dark or GREY.light
    for _, slice in ipairs(slices) do
        slice.color = slice.index and palette[(slice.index - 1) % #palette + 1] or grey[slice.kind] or grey.other
    end
    return slices
end

-- Rewritten only when what it shows changes; two alternating file names.
local function writeSvg(node, slices)
    local dir = shared.dataDir()
    if dir == nil then
        return nil
    end
    local key = generation .. "/" .. #path .. "/" .. tostring(node) .. mode .. tostring(noctalia.isDarkMode())
    if key == svg.key and svg.path ~= nil then
        return svg.path
    end
    local name = #path > 1 and node.n or space.root
    local text = usage.svg(slices, node.s, DONUT_SIZE, DONUT_THICKNESS,
        shared.formatBytes(node.s), display(name, 14))
    svg.slot = svg.slot % #SVG_NAMES + 1
    local previous = svg.path or (dir .. "/" .. SVG_NAMES[svg.slot % #SVG_NAMES + 1])
    local file = dir .. "/" .. SVG_NAMES[svg.slot]
    local ok, err = noctalia.writeFile(file, text)
    if not ok then
        noctalia.log("file-search: could not write the space chart: " .. tostring(err))
        return svg.path
    end
    if previous ~= file then
        noctalia.removeFile(previous)
    end
    svg.path, svg.key = file, key
    return file
end

-- ── panel hooks ──────────────────────────────────────────────────────────────

-- `onChange` re-renders the panel. Loads the current root's index, then
-- rescans a missing or stale one. Safe to call on every tab switch.
function space.onOpen(onChange)
    isOpen = true
    redraw = onChange
    -- Leftovers of a scan killed with the host; a live job's are kept.
    local dir = shared.dataDir()
    if job == nil and dir ~= nil then
        sweep(dir)
    end
    if space.index == nil and not space.loading and not space.scanning then
        space.startLoad(shared.dataDir())
    end
    space.scan(space.root, false, noop)
end

-- From the panel's onConfigChanged. A changed settings tag drops the index; the
-- new tag's index is loaded or scanned at once when the tab is shown.
function space.onConfigChanged()
    local tag = space.settingsTag()
    if seenTag == nil or tag == seenTag then
        return
    end
    reset()
    seenTag = tag
    changed()
    if isOpen then
        space.onOpen(redraw)
    end
end

-- The tab was turned off in the settings: the running scan or load is dropped. No-op when idle.
function space.onDisabled()
    if job == nil and loader == nil and deferred == nil then
        return
    end
    reset()
end

-- Also called when the panel leaves the Space tab; scans and loads keep going.
function space.onClose()
    isOpen = false
end

function space.formatElapsed(ms)
    local s = ms // 1000
    return string.format("%d:%02d", s // 60, s % 60)
end

-- "Scanning… 42% (estimate)", or the elapsed time without an estimate.
function space.progressText()
    local phase = space.phase == "reduce" and "reduce" or "scan"
    if space.progress ~= nil then
        return shared.tr("space_progress_" .. phase, { percent = math.floor(space.progress * 100) })
    end
    return shared.tr("space_elapsed_" .. phase, { time = space.formatElapsed(space.elapsedMs or 0) })
end

-- 987, 1.2k, 3k, 1.2M (no locale, one decimal, ".0" dropped).
function space.formatCount(n)
    if n < 1000 then
        return string.format("%d", n)
    end
    local unit, tenths = "k", math.floor(n / 100 + 0.5)
    if tenths >= 10000 then
        unit, tenths = "M", math.floor(n / 100000 + 0.5)
    end
    if tenths % 10 == 0 then
        return string.format("%d%s", tenths // 10, unit)
    end
    return string.format("%d.%d%s", tenths // 10, tenths % 10, unit)
end

local function label(key, text, color)
    return ui.label({ key = key, text = text, fontSize = 12, color = color or "on_surface_variant" })
end

-- `name` is entry.name without the folder shown above the list (Types mode).
local function entryLabel(entry, name)
    if entry.kind == "loose" then
        return shared.tr("space_loose")
    end
    return display(name, entry.files and ROW_LABEL_MAX_FILES or ROW_LABEL_MAX, entry.kind == "file")
end

-- The category with most bytes in a folder; nil for an empty one.
local function categoryOfNode(node)
    local best, cat = 0, nil
    for k, b in ipairs(node and node.c or {}) do
        if b > best then best, cat = b, k end
    end
    return cat
end

-- One list row: swatch, name (a button only when a click does something),
-- size and share of the current folder. `strip` leading bytes of the name
-- (the common folder) are not shown.
local function listRow(entry, i, node, colors, palette, strip)
    local onClick = nil
    local menu = entry.kind ~= "loose" and function() space.openMenu(entry) end or nil
    if entry.kind == "dir" and not entry.node.leaf then
        onClick = function() space.enter(entry.name) end
    elseif entry.kind == "file" then
        onClick = function() revealFile(entry.name) end
    end
    local shown = entry.name:sub(strip + 1)
    local text = entryLabel(entry, shown)
    local full = entry.name:gsub("%c", " ")
    local cut = text ~= shown:gsub("%c", " ")
    local name = menu
        and ui.button({ key = "name-btn", text = text, fontSize = 12, variant = "ghost", contentAlign = "start",
            flexGrow = 1, height = ROW_HEIGHT, tooltip = cut and full or nil, onClick = onClick, onRightClick = menu })
        or ui.label({ key = "name-plain", text = text, fontSize = 12, color = "on_surface", flexGrow = 1 })
    local share = node.s > 0 and entry.bytes / node.s * 100 or 0
    local bar
    if palette then -- Types mode: a bar in the colour of the row's category (a folder: its biggest)
        local cat = entry.category or categoryOfNode(entry.node)
        bar = ui.box({ key = "typebar", fill = cat and palette[cat] or colors.loose, radius = 2, width = 4, height = 14 })
    else
        bar = ui.box({ key = "swatch", fill = colors[entry.node or entry.kind] or colors.other, radius = 2, width = 9, height = 9 })
    end
    local cells = { bar, name }
    if entry.files then
        table.insert(cells, ui.label({ key = "files", text = shared.tr(entry.files == 1 and "space_file_one" or "space_files",
            { count = space.formatCount(entry.files) }), fontSize = 11, color = "on_surface_variant",
            width = FILES_WIDTH, textAlign = "end" }))
    end
    table.insert(cells, label("size", shared.tr("usage_amount", {
        size = shared.formatBytes(entry.bytes), share = string.format("%.0f", share),
    })))
    return ui.row({ key = "space-row-" .. i, gap = 6, align = "center", height = ROW_HEIGHT }, cells)
end

local function legendRow(slice, i, node)
    local text = slice.kind == "loose" and shared.tr("space_loose")
        or slice.kind == "other" and shared.tr("usage_other")
        or display(slice.label, LABEL_MAX)
    local child = slice.kind == "dir" and idx.child(node, slice.label)
    local name
    if slice.kind == "category" then
        local cat = slice.index
        name = ui.button({ key = "name-btn", text = shared.tr("cat_" .. slice.label), fontSize = 11, variant = "ghost",
            contentAlign = "start", selected = typeFilter == cat, flexGrow = 1, height = 20,
            onClick = function() space.setTypeFilter(typeFilter ~= cat and cat or nil) end })
    elseif child and not child.leaf then
        name = ui.button({ key = "name-btn", text = text, fontSize = 11, variant = "ghost", contentAlign = "start",
            flexGrow = 1, height = 20, onClick = function() space.enter(slice.label) end })
    else
        name = ui.label({ key = "name-plain", text = text, fontSize = 11, color = "on_surface_variant", flexGrow = 1 })
    end
    local share = node.s > 0 and slice.bytes / node.s * 100 or 0
    return ui.row({ key = "space-legend-" .. i, gap = 6, align = "center", height = 20 }, {
        ui.box({ key = "swatch", fill = slice.color, radius = 2, width = 9, height = 9 }),
        name,
        ui.label({ key = "size", fontSize = 11, color = "on_surface_variant", text = shared.tr("usage_amount", {
            size = shared.formatBytes(slice.bytes), share = string.format("%.0f", share),
        }) }),
    })
end

local function sortButton(key)
    local active = sortKey == key
    return ui.button({
        key = "space-sort-" .. key .. (active and (sortDesc and "-d" or "-a") or ""),
        text = shared.tr("space_sort_" .. key),
        glyph = active and (sortDesc and "arrow-down" or "arrow-up") or nil,
        variant = "ghost", controlSize = "sm", selected = active,
        onClick = function() space.setSort(key) end,
    })
end

-- The text in place of the chart and list, or nil when an index is shown.
local function statusText()
    if space.index ~= nil then
        return nil
    end
    if space.state == "error" then
        return shared.tr("space_err." .. (space.errText or "spawn")), "error"
    end
    return shared.tr("space_loading")
end

function space.render()
    local node = current()
    local atHome = space.root ~= "/"
    local controls = ui.row({ key = "space-buttons", gap = 4, align = "center" }, {
        ui.button({ key = "space-up", glyph = "arrow-up", variant = "ghost", enabled = #path > 1,
            tooltip = shared.tr("space_tip_up"), onClick = space.up }),
        ui.button({ key = "space-top", glyph = "arrow-bar-to-up", variant = "ghost",
            enabled = atHome and #path > 1, tooltip = shared.tr("space_tip_top"), onClick = space.top }),
        ui.button({ key = "space-root", glyph = atHome and "device-desktop" or "home", variant = "ghost",
            text = atHome and "/" or "~", tooltip = shared.tr(atHome and "space_tip_root" or "space_tip_home"),
            enabled = not space.scanning, onClick = space.toggleRoot }),
        ui.spacer({ key = "gap", flexGrow = 1 }),
        ui.button({ key = "space-search-here", glyph = "search", variant = "ghost",
            tooltip = shared.tr("space_tip_search_here"),
            onClick = function() if space.onSearchHere then space.onSearchHere(absolute()) end end }),
        ui.button({ key = "space-refresh", glyph = "refresh", variant = "ghost", enabled = not space.scanning,
            tooltip = shared.tr("space_tip_refresh"), onClick = space.refresh }),
    })
    local modeRow = ui.row({ key = "space-buttons-mode", gap = 4, align = "center" }, {
        ui.row({ key = "space-mode", gap = 2 }, {
            ui.button({ key = "folders", text = shared.tr("space_mode_folders"), variant = "ghost",
                controlSize = "sm", selected = mode == "folders", onClick = function() space.setMode("folders") end }),
            ui.button({ key = "types", text = shared.tr("space_mode_types"), variant = "ghost",
                controlSize = "sm", selected = mode == "types", onClick = function() space.setMode("types") end }),
        }),
    })
    local right = {}
    local left = {}
    if space.scanning then
        if space.progress ~= nil then
            table.insert(left, ui.progress({ key = "space-progress", progress = space.progress,
                fill = "primary", track = "on_surface/0.14", radius = 4, height = 8 }))
        end
        table.insert(left, label("space-progress-text", space.progressText()))
        if space.index ~= nil then
            table.insert(left, label("space-msg", shared.tr("space_rescanning")))
        end
    else
        local text, color = statusText()
        if text == nil and space.errText ~= nil then
            text, color = shared.tr("space_err." .. space.errText), "error"
        end
        if text ~= nil then
            table.insert(left, label("space-msg", text, color))
        end
    end
    local slices = node ~= nil and paint(idx.slices(node, mode, usage.MAX_SLICES)) or nil
    if node ~= nil then
        local image = writeSvg(node, slices)
        if image ~= nil then
            table.insert(left, ui.image({ key = "space-img", path = image, width = DONUT_SIZE, height = DONUT_SIZE }))
        end
    end
    table.insert(left, ui.label({ key = "space-path", text = display(absolute(), ROW_LABEL_MAX + 6, true), fontSize = 13,
        fontWeight = "bold", color = "on_surface" }))
    table.insert(left, controls)
    table.insert(left, modeRow)
    if node ~= nil then
        if (node.u or 0) > 0 then
            table.insert(left, label("space-unreadable", shared.tr("space_unreadable", { count = node.u })))
        end
        local dirs, folded = 0, false
        local legend = {}
        for i, slice in ipairs(slices) do
            dirs = dirs + (slice.kind == "dir" and 1 or 0)
            folded = folded or slice.kind == "other" or slice.kind == "loose"
            table.insert(legend, legendRow(slice, i, node))
        end
        table.insert(left, label("space-legend-title", mode == "types" and shared.tr("space_legend_types")
            or folded and shared.tr("space_legend_folders_top", { count = dirs }) or shared.tr("space_legend_folders_all")))
        table.insert(left, ui.column({ key = "space-legend", gap = 1 }, legend))

        -- Swatch colours: a shown folder takes its slice's colour; the rest stay grey.
        local dark = noctalia.isDarkMode()
        local colors = table.clone(dark and GREY.dark or GREY.light)
        for _, slice in ipairs(slices) do
            if slice.node then
                colors[slice.node] = slice.color
            end
        end
        local rows = {}
        local entries = idx.sort(idx.entries(node, mode, typeFilter), sortKey, sortDesc)
        local count = math.min(#entries, MAX_ROWS)
        -- Files of a type: the folder all rows share is shown once, above the list.
        local common = mode == "types" and typeFilter and idx.commonDir(entries, count) or ""
        for i = 1, count do
            table.insert(rows, listRow(entries[i], i, node, colors,
                mode == "types" and (dark and idx.COLORS_DARK or idx.COLORS_LIGHT) or nil, #common))
        end
        if #entries > MAX_ROWS then
            table.insert(rows, label("space-more", shared.tr("space_more_rows", { count = #entries - MAX_ROWS })))
        end
        table.insert(right, ui.row({ key = "space-sort", gap = 4, align = "center" }, {
            sortButton("size"), sortButton("name"), mode == "types" and sortButton("path") or nil,
        }))
        if mode == "types" and typeFilter and #entries >= TOP_N then
            table.insert(right, label("space-capped", shared.tr("space_capped", { count = #entries })))
        end
        if common ~= "" then
            table.insert(right, label("space-common", shared.tr("space_common_path", {
                path = display(absolute(common:sub(1, -2)), ROW_LABEL_MAX + 6, true),
            })))
        end
        table.insert(right, ui.scroll({ key = "space-list", flexGrow = 1, gap = 2 }, rows))
    end
    return ui.row({ key = "space", flexGrow = 1, gap = 16 }, {
        ui.column({ key = "space-left", width = LEFT_WIDTH, gap = 8 }, left),
        ui.column({ key = "space-right", flexGrow = 1, gap = 4 }, right),
    })
end

return space
