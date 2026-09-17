--!nonstrict
-- shared — the search core behind all three entries (bar widget, panel,
-- launcher provider), pulled in via require() (relative same-plugin import,
-- plugin_api >= 22).
--
-- Before 0.0.28 every helper below lived twice, copied by hand between
-- panel.luau and launcher.luau, with a comment in each asking the next reader
-- to keep them in step. They had already drifted: excludeNames() logged a bad
-- entry in one copy and swallowed it in the other, readRanking() validated
-- against a hard-coded pair of words instead of the constant. The fingerprint
-- functions are the reason that mattered — indexKey() and cacheSh() are how one
-- entry recognizes an index the other built, so a divergence there does not
-- fail loudly, it silently makes each entry re-walk the tree the other just
-- walked.
--
-- The module owns the search STATE as well as the functions, because almost
-- every helper reads it: `scope` decides the cache paths, `roots` and
-- `indexRoots` decide how a record resolves, `mounts` decides the roots. The
-- entries read and write those fields directly (shared.scope = ...); each entry
-- is its own Luau host, so each gets its own instance of this module and no
-- state is shared between them behind the entries' backs — the files under
-- pluginDataDir() remain the only channel between the entries, exactly as
-- before.
--
-- What stays out: anything one entry alone has. The panel keeps its row menu,
-- path elision, spinner and footer counts; the launcher keeps its row
-- construction and its query echo.

local shared = {}

-- ── constants ────────────────────────────────────────────────────────────────

-- Bumped whenever the record format or the pruned-name list below changes: it
-- is part of the cache fingerprint, so an index built by an older version of
-- this plugin is rebuilt instead of being read with the wrong rules.
shared.INDEX_FORMAT = "2"

-- Volume metadata that other operating systems leave on removable media, plus
-- the filesystem-level ones. None of it is a user file and some of it is huge
-- (a Time Machine sparsebundle or a Spotlight store is tens of thousands of
-- entries), so it is pruned at every root, not only on external disks — the
-- names are vendor-fixed and never collide with real content. Matched with
-- -iname because Windows has shipped both "$RECYCLE.BIN" and "$Recycle.Bin".
-- Most of the macOS ones start with a dot and are already covered when hidden
-- entries are off; they are listed so that turning hidden entries ON does not
-- flood the index.
shared.VOLUME_NOISE = {
    "lost+found",
    -- Windows / NTFS
    "$RECYCLE.BIN", "RECYCLER", "System Volume Information",
    -- Linux XDG trash on removable media (.Trash-<uid>)
    ".Trash-*",
    -- macOS volume services
    ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
    ".DocumentRevisions-V100", ".PKInstallSandboxManager",
    -- macOS Time Machine
    "Backups.backupdb", "*.sparsebundle", "*.backupbundle",
    -- AppleDouble sidecars and AFP/netatalk leftovers
    "._*", ".DS_Store", ".AppleDouble", ".AppleDB", ".AppleDesktop",
    "Network Trash Folder", "Temporary Items", "TheVolumeSettingsFolder",
}

-- Search scope: which roots the index covers. Persisted as a one-word file in
-- the plugin data directory because a plugin cannot write its own settings —
-- there is no setConfig in the host API — and every entry has to read the same
-- choice.
shared.SCOPE_GLYPHS = { folder = "folder", all = "folders", external = "usb" }
shared.NEXT_SCOPE = { folder = "all", all = "external", external = "folder" }
shared.DEFAULT_SCOPE = "folder"

-- How fzf scores a match, switched by the panel's third header button and
-- persisted next to the scope. "path" is fzf's --scheme=path: it treats / as a
-- strong boundary, so a match that starts a file or folder name beats the same
-- letters buried in a long directory. "default" is fzf's generic scoring, which
-- mostly rewards the shortest path. Path wins on most queries here — "config"
-- finds .ssh/config instead of a Steam directory five levels down — but not on
-- all of them, which is exactly why it is a toggle and not a constant.
shared.RANKING_GLYPHS = { default = "arrows-sort", path = "sitemap" }
shared.NEXT_RANKING = { default = "path", path = "default" }
shared.DEFAULT_RANKING = "path"

-- A walk over a USB spinning disk is seek-bound and can run for tens of
-- minutes on a multi-terabyte drive, where the search folder alone is seconds;
-- the timeout follows the scope. Nothing at that price is ever started on its
-- own — see autoIndexAllowed.
shared.BUILD_TIMEOUT_LOCAL = 180000
shared.BUILD_TIMEOUT_DISKS = 1800000

-- Seconds a mount scan stays good for. Long enough that a burst of keystrokes
-- (or mashing the panel's scope button) costs one lsblk at most, short enough
-- that a disk plugged in mid-session shows up without a manual refresh.
shared.MOUNT_TTL = 30

-- ── state ────────────────────────────────────────────────────────────────────

shared.scope = shared.DEFAULT_SCOPE
shared.ranking = shared.DEFAULT_RANKING
-- Whether the installed fzf understands --scheme, decided once per script load
-- (see probeFzfScheme). False until it answers, and on any fzf too old for it.
shared.schemeSupported = false
shared.mounts = {}          -- mount points of the detected removable volumes
shared.mountsAt = 0         -- unix seconds of the last mount scan (0 = never)
shared.roots = {}           -- what an index built now would cover, ancestors first
shared.indexRoots = {}      -- what the index ON DISK was built with (indexRootsOf)
shared.absoluteRecords = false -- records are absolute (set when #indexRoots > 1)

local probing = false
local pendingProbeDone = nil

-- ── small helpers ────────────────────────────────────────────────────────────

function shared.tr(key, args)
    return noctalia.tr(key, args)
end

function shared.trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function shared.shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

function shared.startsWith(value, prefix)
    return value:sub(1, #prefix) == prefix
end

-- plugin_api >= 16: a direct wall-clock read, no string formatting/parsing (and
-- no dependency on "%s" staying a Unix-epoch format) for a value only ever
-- diffed against itself.
function shared.now()
    return noctalia.nowMs() / 1000
end

-- Byte counts as a person reads them. One implementation, because there were
-- two and they disagreed: the panel's rounded to one decimal above KB and the
-- chart's dropped the decimal at three digits, so the same measurement showed
-- as "110.4 GB" in the free-space tooltip and "110 GB" in the donut. Three
-- significant figures throughout is the rule kept — a tenth of a gigabyte is
-- precision this plugin does not have and nobody asked for.
function shared.formatBytes(n)
    local units = { "B", "KB", "MB", "GB", "TB" }
    local index, value = 1, n + 0.0
    while value >= 1024 and index < #units do
        value /= 1024
        index += 1
    end
    if value >= 100 or index == 1 then
        return string.format("%.0f %s", value, units[index])
    end
    return string.format("%.1f %s", value, units[index])
end

-- Open a path with the system MIME association. An argv (plugin_api >= 24) is
-- exec'd directly, so nothing parses the path and it needs no quoting; the host
-- points a detached child's stdio at /dev/null itself.
function shared.openPath(path)
    noctalia.runAsync({ "xdg-open", path })
end

-- ── fzf capability + scoring ─────────────────────────────────────────────────

-- --scheme=path arrived in fzf 0.36; an older build exits with "unknown option"
-- and the entry would show an empty list forever. So the flag is only ever used
-- after the installed version says it is understood — one spawn per script
-- load, generic ranking until it answers.
function shared.probeFzfScheme()
    noctalia.runAsync("fzf --version 2>/dev/null", function(result)
        local major, minor = (result.stdout or ""):match("(%d+)%.(%d+)")
        major, minor = tonumber(major), tonumber(minor)
        shared.schemeSupported = major ~= nil and minor ~= nil and (major > 0 or minor >= 36)
    end, 5000)
end

-- The scoring flag for the next search: what the toggle asks for, if fzf can.
function shared.rankingFlag()
    return (shared.ranking == "path" and shared.schemeSupported) and " --scheme=path" or ""
end

-- Whether the plugin may walk the tree by itself. It may for the search folder,
-- which is local and takes seconds; it may NOT once an external disk is in
-- scope. A 5 TB mechanical USB drive takes minutes per walk and would otherwise
-- be re-walked on every scope change, settings change, disk plug and panel
-- open — the panel's refresh button (and the launcher's rebuild row) is the
-- only way.
function shared.autoIndexAllowed()
    return shared.scope == "folder"
end

-- ── plugin data directory ────────────────────────────────────────────────────

-- Private per-plugin storage (XDG state); the host creates the directory on
-- every call. nil (with a log line) when no state directory resolves.
function shared.dataDir()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("file-search: pluginDataDir failed: " .. tostring(err))
        return nil
    end
    return dir
end

-- Shell header shared by every cache command. One cache pair per scope, so
-- switching to the disks and back does not re-walk the search folder; the
-- .meta sidecar holds the settings fingerprint the cache was built with, so
-- every entry can tell a stale index apart. The scope is a word from
-- SCOPE_GLYPHS, never free text, so it is safe inside the path.
function shared.cacheSh(dir)
    return "CACHE_DIR=" .. shared.shellQuote(dir)
        .. '\nCACHE="$CACHE_DIR/list-' .. shared.scope .. '"'
        .. '\nMETA="$CACHE_DIR/meta-' .. shared.scope .. '"'
        .. '\nCOUNTF="$CACHE_DIR/count-' .. shared.scope .. '"'
end

function shared.readScope(dir)
    local raw = noctalia.readFile(dir .. "/scope")
    if type(raw) == "string" then
        local value = shared.trim(raw)
        if shared.SCOPE_GLYPHS[value] ~= nil then
            return value
        end
    end
    return shared.DEFAULT_SCOPE
end

function shared.writeScope(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/scope", value)
    if not ok then
        noctalia.log("file-search: could not persist the scope: " .. tostring(err))
    end
end

function shared.readRanking(dir)
    local raw = noctalia.readFile(dir .. "/ranking")
    if type(raw) == "string" then
        local value = shared.trim(raw)
        if shared.RANKING_GLYPHS[value] ~= nil then
            return value
        end
    end
    return shared.DEFAULT_RANKING
end

function shared.writeRanking(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/ranking", value)
    if not ok then
        noctalia.log("file-search: could not persist the ranking: " .. tostring(err))
    end
end

-- ── settings ─────────────────────────────────────────────────────────────────

function shared.searchRoot()
    local dir = noctalia.getConfig("search_folder")
    if dir == nil or dir == "" then
        dir = noctalia.getenv("HOME") or "/tmp"
    else
        dir = noctalia.expandPath(dir)
    end
    dir = dir:gsub("/+$", "")
    if dir == "" then
        dir = "/"
    end
    return dir
end

-- Excluded directory names from the setting, split on ',' or ';'. Matching
-- is by basename (find -name), so entries containing '/' are skipped and
-- logged. Hidden entries are folded in as an extra '.*' pattern.
function shared.excludeNames()
    local raw = noctalia.getConfig("exclude_dirs")
    if type(raw) ~= "string" then
        raw = ""
    end
    local names = {}
    for entry in raw:gmatch("[^,;]+") do
        local name = shared.trim(entry)
        if name:find("/") then
            noctalia.log("file-search: ignoring exclude entry with '/': '" .. name .. "'")
        elseif name ~= "" then
            table.insert(names, name)
        end
    end
    if noctalia.getConfig("show_hidden") ~= true then
        table.insert(names, ".*")
    end
    return names
end

-- ── removable volume detection ───────────────────────────────────────────────

-- A mount point worth indexing: absolute, not the system root, no control
-- character (it becomes a shell word and a cache record), and not the boot
-- partition, which is a mount of firmware files even when it sits on a stick.
function shared.usableMount(path)
    if path == nil or path == "" or path:sub(1, 1) ~= "/" then
        return false
    end
    if path == "/" or path:find("%c") ~= nil then
        return false
    end
    return path ~= "/boot" and not shared.startsWith(path, "/boot/")
end

-- lsblk --pairs quotes every value; depending on the util-linux version a
-- space or a quote inside one can come back as a \xNN escape. nil for an
-- escaped control byte: the whole mount point is then dropped by the caller,
-- rather than kept with a literal "\x0a" in it that no path would match.
function shared.unescapeHex(value)
    local rejected = false
    local out = value:gsub("\\x(%x%x)", function(hex)
        local code = tonumber(hex, 16)
        if code == nil or code < 32 or code == 127 then
            rejected = true
            return ""
        end
        return string.char(code)
    end)
    if rejected then
        return nil
    end
    return out
end

function shared.pairValue(line, key)
    return (" " .. line):match(" " .. key .. '="(.-)"')
end

-- Mount points of the volumes that came from a USB port or report themselves
-- removable (sticks, SD cards, optical media).
--
-- The interesting attribute lives on the DISK, not on the partition that is
-- actually mounted: a USB partition row reports TRAN="" and, for a bus-powered
-- SSD, RM="0" as well — only its parent disk says TRAN="usb". So the PKNAME
-- chain is walked upwards (one more level for an encrypted stick: crypt →
-- part → disk). HOTPLUG is deliberately not part of the test: some NVMe and
-- hot-swap SATA controllers report HOTPLUG="1" for internal drives.
function shared.parseLsblk(out)
    local rows, byName = {}, {}
    for line in out:gmatch("[^\n]+") do
        local name = shared.pairValue(line, "NAME")
        if name ~= nil and name ~= "" then
            local row = {
                parent = shared.pairValue(line, "PKNAME") or "",
                removable = shared.pairValue(line, "RM") == "1",
                transport = shared.pairValue(line, "TRAN") or "",
                mount = shared.unescapeHex(shared.pairValue(line, "MOUNTPOINT") or ""),
            }
            byName[name] = row
            table.insert(rows, row)
        end
    end
    local found = {}
    for _, row in ipairs(rows) do
        if shared.usableMount(row.mount) then
            local node, depth = row, 0
            -- Capped: PKNAME comes from outside and a cycle would hang here.
            while node ~= nil and depth < 4 do
                if node.transport == "usb" or node.removable then
                    table.insert(found, row.mount)
                    break
                end
                node = (node.parent ~= "") and byName[node.parent] or nil
                depth += 1
            end
        end
    end
    return found
end

-- Fallback for a system without util-linux: the mount table still exposes the
-- udisks2 convention every mainstream desktop mounts removable media with
-- (/run/media/<user>/<label>), plus the older /media/<user>|<label> layout of
-- udisks1 and pmount. Paths in /proc/mounts spell space and tab as an octal
-- escape. Internal disks mounted by hand under /mnt are NOT picked up here —
-- same as with lsblk, where they are neither USB nor removable.
function shared.fallbackMounts()
    local text = noctalia.readFile("/proc/mounts")
    if type(text) ~= "string" then
        return {}
    end
    local found = {}
    for line in text:gmatch("[^\n]+") do
        local raw = line:match("^%S+%s+(%S+)%s")
        if raw ~= nil then
            local rejected = false
            local path = raw:gsub("\\(%d%d%d)", function(octal)
                local code = tonumber(octal, 8)
                if code == nil or code < 32 or code == 127 then
                    rejected = true
                    return ""
                end
                return string.char(code)
            end)
            if rejected then
                path = ""
            end
            local rest = path:match("^/run/media/[^/]+/(.+)$") or path:match("^/media/(.+)$")
            if rest ~= nil and rest ~= "" and shared.usableMount(path) then
                table.insert(found, path)
            end
        end
    end
    return found
end

-- Whether a mount scan is in flight. The launcher checks it to park the query
-- it would otherwise have handed to a probe that is already running.
function shared.probeBusy()
    return probing
end

-- Refresh `shared.mounts`, then continue. Async because lsblk is a process:
-- every caller has to be written as a continuation. Skipped entirely — no spawn
-- at all — while the scope is the search folder, so the default costs nothing,
-- and a scan younger than MOUNT_TTL is reused unless `force` says otherwise
-- (the panel's refresh button forces one, since noticing a disk is the point of
-- it).
--
-- A caller arriving while a scan is in flight does NOT get a second scan and
-- does not get called back immediately with the list that is about to be
-- replaced: its continuation takes the place of any other one waiting, and runs
-- when the scan lands. Latest-wins, because both callers are "show what is
-- current now" and the later one knows more. In practice neither entry gets
-- there — the panel serialises through requestReload and the launcher parks the
-- query itself (probeBusy above).
function shared.probeMounts(force, done)
    if shared.scope == "folder" then
        shared.mounts = {}
        done()
        return
    end
    if not force and shared.mountsAt > 0 and (shared.now() - shared.mountsAt) < shared.MOUNT_TTL then
        done()
        return
    end
    if probing then
        pendingProbeDone = done
        return
    end
    local function finish()
        shared.mountsAt = shared.now()
        probing = false
        local queued = pendingProbeDone
        pendingProbeDone = nil
        done()
        if queued ~= nil then
            queued()
        end
    end
    if not noctalia.commandExists("lsblk") then
        shared.mounts = shared.fallbackMounts()
        finish()
        return
    end
    probing = true
    local ok = noctalia.runAsync("lsblk -P -o NAME,PKNAME,RM,TRAN,MOUNTPOINT 2>/dev/null", function(result)
        if result.exitCode == 0 and not result.timedOut then
            shared.mounts = shared.parseLsblk(result.stdout or "")
        else
            shared.mounts = shared.fallbackMounts()
        end
        finish()
    end, 10000)
    if not ok then
        shared.mounts = shared.fallbackMounts()
        finish()
    end
end

-- ── index identity ───────────────────────────────────────────────────────────

-- The roots the index covers, ancestors first and without overlaps: a volume
-- mounted inside the search folder (or inside another volume) would otherwise
-- be walked twice and produce duplicate rows. Sorting puts a parent before its
-- children, so one pass is enough to drop the nested ones.
function shared.computeRoots()
    local list = {}
    if shared.scope ~= "external" then
        table.insert(list, shared.searchRoot())
    end
    if shared.scope ~= "folder" then
        for _, mount in ipairs(shared.mounts) do
            table.insert(list, (mount:gsub("/+$", "")))
        end
    end
    table.sort(list)
    local kept = {}
    for _, path in ipairs(list) do
        local nested = false
        for _, parent in ipairs(kept) do
            if path == parent or shared.startsWith(path, parent == "/" and "/" or parent .. "/") then
                nested = true
                break
            end
        end
        if path ~= "" and not nested then
            table.insert(kept, path)
        end
    end
    return kept
end

-- Everything that decides how the cache was built. Its two lists are joined
-- with a separator no root and no exclusion name can contain, so a name can
-- never be read back as a root. This string is the contract between the
-- entries: whichever one built the index, the others recognize it by this.
function shared.indexKey()
    return shared.INDEX_FORMAT .. "\n" .. shared.scope
        .. "\n--\n" .. table.concat(shared.roots, "\n")
        .. "\n--\n" .. table.concat(shared.excludeNames(), "\n")
end

-- The cache on disk is current when its fingerprint matches, whichever entry
-- built it.
function shared.cacheFresh(dir)
    return noctalia.readFile(dir .. "/meta-" .. shared.scope) == shared.indexKey()
end

-- The roots the index on disk was built with, read back out of its fingerprint,
-- or nil when there is no index. Records must be read the way they were
-- WRITTEN, not the way a fresh walk would write them now: unplug one of two
-- disks and the file still holds absolute records, so deciding the format from
-- the current mount list would make every row unopenable — including the rows
-- of the disk still attached — until the next rebuild.
function shared.indexRootsOf(dir)
    local meta = noctalia.readFile(dir .. "/meta-" .. shared.scope)
    if type(meta) ~= "string" then
        return nil
    end
    local section = meta:match("\n%-%-\n(.-)\n%-%-\n")
    if section == nil then
        return nil
    end
    local list = {}
    for line in section:gmatch("[^\n]+") do
        table.insert(list, line)
    end
    return #list > 0 and list or nil
end

-- An index record turned into a path, or nil when it could resolve outside the
-- roots it was supposed to come from. The cache is a plain user-editable file,
-- so records are untrusted. Only ever called from a callback that acts on a row
-- — never from a render: it walks every path component, and paying that per row
-- per frame is what gets a script callback killed for exceeding its CPU budget.
function shared.absolutePath(record)
    if record == "" or record:find("%c") ~= nil then
        return nil
    end
    -- A directory keeps its trailing "/" in the index but not in a path meant
    -- for xdg-open or for pasting into a shell.
    local path = record:gsub("/+$", "")
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            return nil
        end
    end
    -- Validated against the roots of the index the record came from, so a
    -- record can still never escape a root, but one written for a disk that has
    -- since been unplugged stays openable (xdg-open just fails if it is gone).
    local from = #shared.indexRoots > 0 and shared.indexRoots or shared.roots
    if shared.absoluteRecords then
        for _, root in ipairs(from) do
            if shared.startsWith(path, root == "/" and "/" or root .. "/") then
                return path
            end
        end
        return nil
    end
    local root = from[1]
    if root == nil or path == "" or path:sub(1, 1) == "/" then
        return nil
    end
    if root == "/" then
        return root .. path
    end
    return root .. "/" .. path
end

-- ── the two commands ─────────────────────────────────────────────────────────

-- Seconds a walk of the current scope is allowed to take.
function shared.buildTimeout()
    return (shared.scope == "folder") and shared.BUILD_TIMEOUT_LOCAL or shared.BUILD_TIMEOUT_DISKS
end

-- The tree walk, written for `key` as the fingerprint it will leave behind.
-- Returns the shell script; the caller decides the timeout and what to do with
-- the result.
--
-- find's own exit status is ignored, so permission errors inside the tree don't
-- fail the build. Cache and fingerprint are written to mktemp-created private
-- files and renamed into place: rename replaces a planted symlink at the
-- destination instead of following it. The host guarantees $CACHE_DIR exists
-- (created by pluginDataDir above). The two cleanup lines drop the pre-0.0.20
-- single-scope cache and any temp file a killed build left behind — only ones
-- older than 90 minutes, comfortably past the 30-minute build ceiling, so a
-- walk running in another entry is never touched.
--
-- On success it prints "<count> <elapsed_ms>" and leaves the same pair in the
-- count sidecar, so the panel's footer can report both without re-reading an
-- index that may be 100 MB. The launcher ignores the output and reads nothing.
function shared.buildCommand(dir, key, absolute)
    -- Names containing a newline would each forge extra one-per-fragment
    -- records (a crafted name can smuggle '..' lines into the index), so
    -- they are pruned unconditionally, before the volume noise and the user's
    -- own exclusions.
    local names = { "-name " .. shared.shellQuote("*\n*") }
    for _, pattern in ipairs(shared.VOLUME_NOISE) do
        table.insert(names, "-iname " .. shared.shellQuote(pattern))
    end
    for _, name in ipairs(shared.excludeNames()) do
        table.insert(names, "-name " .. shared.shellQuote(name))
    end
    local prune = "\\( " .. table.concat(names, " -o ") .. " \\) -prune -o "
    local args = {}
    for _, root in ipairs(shared.roots) do
        table.insert(args, shared.shellQuote(root))
    end
    -- %P prints paths relative to the root, %p the whole path. Relative is
    -- what a single root gets: it keeps the rows short and, more to the point,
    -- keeps the common "/home/<user>/" prefix out of every line, where it
    -- would be fuzzy-matched like any other text. With several roots a
    -- relative record would be ambiguous, so those are absolute.
    local printSpec = absolute
        and "-type d -printf '%p/\\n' -o -printf '%p\\n'"
        or "-type d -printf '%P/\\n' -o -printf '%P\\n'"
    local walk = "find " .. table.concat(args, " ") .. " -mindepth 1 " .. prune
        .. printSpec .. ' > "$TMP" 2>/dev/null'

    return shared.cacheSh(dir)
        .. '\nrm -f "$CACHE_DIR/index.list" "$CACHE_DIR/index.meta"\n'
        .. 'find "$CACHE_DIR" -maxdepth 1 \\( -name \'list-*.*\' -o -name \'meta-*.*\''
        .. " -o -name 'count-*.*' \\) -mmin +90 -delete 2>/dev/null\n"
        -- Timed here rather than around runAsync: this is the walk itself,
        -- without the queueing and callback hops the shell knows nothing about.
        .. 'START=$(date +%s%3N)\n'
        .. 'TMP=$(mktemp "$CACHE_DIR/list-' .. shared.scope .. '.XXXXXX") || exit 1\n'
        .. walk .. "\n"
        .. 'mv -f "$TMP" "$CACHE" || exit 1\n'
        .. 'TMPM=$(mktemp "$CACHE_DIR/meta-' .. shared.scope .. '.XXXXXX") || exit 1\n'
        .. "printf '%s' " .. shared.shellQuote(key) .. ' > "$TMPM"\n'
        .. 'mv -f "$TMPM" "$META" || exit 1\n'
        -- The count is taken here, while the file is already hot, and left in a
        -- sidecar together with the elapsed milliseconds: every later open
        -- reads a dozen bytes instead of the whole index.
        .. 'COUNT=$(wc -l < "$CACHE") || exit 1\n'
        .. 'ELAPSED=$(( $(date +%s%3N) - START ))\n'
        .. 'TMPN=$(mktemp "$CACHE_DIR/count-' .. shared.scope .. '.XXXXXX") || exit 1\n'
        .. 'printf "%s %s" "$COUNT" "$ELAPSED" > "$TMPN"\n'
        .. 'mv -f "$TMPN" "$COUNTF" || exit 1\n'
        .. 'printf "%s %s" "$COUNT" "$ELAPSED"'
end

-- One search over the cache, capped at `limit` rows. An empty query is the
-- head of the index rather than an fzf run over everything. head closes the
-- pipe early; the pipeline status stays head's (0).
function shared.searchCommand(dir, text, limit)
    if shared.trim(text) == "" then
        return shared.cacheSh(dir) .. '\nhead -n ' .. limit .. ' "$CACHE" 2>/dev/null'
    end
    return shared.cacheSh(dir) .. "\nfzf" .. shared.rankingFlag()
        .. " --filter=" .. shared.shellQuote(text)
        .. ' < "$CACHE" 2>/dev/null | head -n ' .. limit
end

return shared
