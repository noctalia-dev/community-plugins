--!nonstrict
-- file-search — fuzzy search panel, fzf as the matching subsystem.
--
-- On open the active roots are walked once with `find` into a cache file
-- (excluded directory names are pruned, hidden entries too unless enabled);
-- after that every keystroke runs `fzf --filter=<query>` over the cache, so
-- typing stays responsive even on large trees. Results update live; picking
-- one opens it with the system MIME association (xdg-open) — directories
-- open in the file manager. Enter opens the top match.
--
-- The roots come from the search scope, cycled with the panel's disk button
-- and persisted in the plugin data directory so the launcher entry follows the
-- same choice: the search folder alone (default), the search folder plus every
-- mounted USB/removable volume, or those volumes alone. Mounts are detected
-- with `lsblk` (see probeMounts), only when the scope needs them.
--
-- The index is rebuilt when the panel opens with changed settings, a different
-- scope or a different set of disks, and on demand via the refresh button. The
-- bar widget mirrors the panel's open state through the shared
-- "file_search_open" state key.

-- How many characters of a result path fit on one row, from the panel's 520
-- width in plugin.toml: 520 − 2 × Style::panelPadding (14) − the scrollbar
-- gutter (scrollbarWidth 6 + scrollbarGap 8) = 478 usable, less the row
-- Button's 2 × Style::spaceMd (12) horizontal padding, its 14px glyph and the
-- 4px gap between them → 436px of text. Measured against a rendered row, a
-- lowercase path averages 7.2px per character at Style::fontSizeBody, so 61
-- characters is the limit; 56 leaves headroom, because the font is
-- proportional and capitals or digits measure wider than that average.
--
-- A Button cannot do this itself: it has no maxLines, so constraining its
-- width makes the label WRAP rather than ellipsize, and a plain flexGrow never
-- shrinks it below the full text — which is why a long path used to run under
-- the scrollbar and get clipped.
local PATH_MAX_CHARS = 56
local ELLIPSIS = "…"

-- Bumped whenever the record format or the pruned-name list below changes: it
-- is part of the cache fingerprint, so an index built by an older version of
-- this plugin is rebuilt instead of being read with the wrong rules.
local INDEX_FORMAT = "2"

-- Volume metadata that other operating systems leave on removable media, plus
-- the filesystem-level ones. None of it is a user file and some of it is huge
-- (a Time Machine sparsebundle or a Spotlight store is tens of thousands of
-- entries), so it is pruned at every root, not only on external disks — the
-- names are vendor-fixed and never collide with real content. Matched with
-- -iname because Windows has shipped both "$RECYCLE.BIN" and "$Recycle.Bin".
-- Most of the macOS ones start with a dot and are already covered when hidden
-- entries are off; they are listed so that turning hidden entries ON does not
-- flood the index.
local VOLUME_NOISE = {
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
-- there is no setConfig in the host API — and the launcher entry has to read
-- the same choice.
local SCOPE_GLYPHS = { folder = "folder", all = "folders", external = "usb" }
local NEXT_SCOPE = { folder = "all", all = "external", external = "folder" }
local DEFAULT_SCOPE = "folder"

-- What a right click on a result does, switched by the second header button
-- and persisted next to the scope. Two actions, one gesture: a panel row can
-- only ever receive left and right — the declarative UI wires BTN_LEFT, plus
-- BTN_RIGHT once an onRightClick is attached, and nothing else. Middle click
-- exists for bar widgets only (onMiddleClick), never inside a panel, so the
-- second action lives on a toggle instead of a third button.
local ROW_ACTION_GLYPHS = { copy = "copy", reveal = "folder-open" }
local NEXT_ROW_ACTION = { copy = "reveal", reveal = "copy" }
local DEFAULT_ROW_ACTION = "copy"

-- How fzf scores a match, switched by the third header button and persisted
-- like the others. "path" is fzf's --scheme=path: it treats / as a strong
-- boundary, so a match that starts a file or folder name beats the same letters
-- buried in a long directory. "default" is fzf's generic scoring, which mostly
-- rewards the shortest path. Path wins on most queries here — "config" finds
-- .ssh/config instead of a Steam directory five levels down — but not on all of
-- them, which is exactly why it is a toggle and not a constant.
local RANKING_GLYPHS = { default = "arrows-sort", path = "sitemap" }
local NEXT_RANKING = { default = "path", path = "default" }
local DEFAULT_RANKING = "path"

-- A walk over a USB spinning disk is seek-bound and can run for tens of
-- minutes on a multi-terabyte drive, where the search folder alone is seconds;
-- the timeout follows the scope. Nothing at that price is ever started on its
-- own — see autoIndexAllowed.
local BUILD_TIMEOUT_LOCAL = 180000
local BUILD_TIMEOUT_DISKS = 1800000

-- Seconds a mount scan stays good for, so that mashing the scope button spawns
-- one lsblk instead of one per press.
local MOUNT_TTL = 30

-- Read out of the plugin's own manifest (readFile resolves a relative path
-- against the plugin directory), so the header cannot drift from the version
-- the store shows. Empty when unreadable — a missing version is not worth an
-- error line in the panel.
local pluginVersion = (function()
    local text = noctalia.readFile("plugin.toml")
    if type(text) ~= "string" then
        return ""
    end
    return ("\n" .. text):match('\nversion%s*=%s*"([^"]+)"') or ""
end)()

-- Whether the installed fzf understands --scheme, decided once per script load
-- (see probeFzfScheme). False until it answers, and on any fzf too old for it.
local schemeSupported = false

local query = ""
local results = {}      -- index records: relative to the root, or absolute
local total = nil       -- entries in the index, shown in the footer
local buildMs = nil     -- how long the walk behind that index took
local indexing = false
local searching = false
local errMsg = nil
local fzfMissing = false
local inputRev = 0      -- bumped to reseed the query input on open
local haveIndex = false -- the cache on disk matches the current settings
local scope = DEFAULT_SCOPE
local rowAction = DEFAULT_ROW_ACTION
local ranking = DEFAULT_RANKING
local mounts = {}       -- mount points of the detected removable volumes
local mountsAt = 0      -- unix seconds of the last mount scan (0 = never)
local probing = false
local roots = {}        -- what an index built now would cover, ancestors first
local indexRoots = {}   -- what the index ON DISK was built with (see indexRootsOf)
local absoluteRecords = false -- records are absolute (set when #indexRoots > 1)
local indexState = "fresh" -- "fresh" | "stale" (usable, out of date) | "missing"
local reloading = false -- a refresh pass is in flight
local reloadQueued = false
local queuedForce = false
local queuedBuild = false
local totals = {}       -- scope → { count, size, mtime }: see readTotal

local render
local runSearch
local buildIndex
local applyState

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function startsWith(value, prefix)
    return value:sub(1, #prefix) == prefix
end

local function now()
    return tonumber(noctalia.formatTime("%s")) or 0
end

-- --scheme=path arrived in fzf 0.36; an older build exits with "unknown option"
-- and the panel would show an empty list forever. So the flag is only ever used
-- after the installed version says it is understood — one spawn per script
-- load, generic ranking until it answers.
local function probeFzfScheme()
    noctalia.runAsync("fzf --version 2>/dev/null", function(result)
        local major, minor = (result.stdout or ""):match("(%d+)%.(%d+)")
        major, minor = tonumber(major), tonumber(minor)
        schemeSupported = major ~= nil and minor ~= nil and (major > 0 or minor >= 36)
    end, 5000)
end

-- The scoring flag for the next search: what the toggle asks for, if fzf can.
local function rankingFlag()
    return (ranking == "path" and schemeSupported) and " --scheme=path" or ""
end

-- Whether the plugin may walk the tree by itself. It may for the search folder,
-- which is local and takes seconds; it may NOT once an external disk is in
-- scope. A 5 TB mechanical USB drive takes minutes per walk and would otherwise
-- be re-walked on every scope change, settings change, disk plug and panel
-- open — the refresh button (and the launcher's rebuild row) is the only way.
local function autoIndexAllowed()
    return scope == "folder"
end

-- Private per-plugin storage (XDG state); the host creates the directory on
-- every call. nil (with a log line) when no state directory resolves.
local function dataDir()
    local dir, err = noctalia.pluginDataDir()
    if dir == nil then
        noctalia.log("file-search: pluginDataDir failed: " .. tostring(err))
        return nil
    end
    return dir
end

-- Shell header shared by every cache command. One cache pair per scope, so
-- switching to the disks and back does not re-walk the search folder; the
-- .meta sidecar holds the settings fingerprint the cache was built with, so the
-- panel and the launcher can both tell a stale index apart. The scope is a
-- word from SCOPE_GLYPHS, never free text, so it is safe inside the path.
local function cacheSh(dir)
    return "CACHE_DIR=" .. shellQuote(dir)
        .. '\nCACHE="$CACHE_DIR/list-' .. scope .. '"'
        .. '\nMETA="$CACHE_DIR/meta-' .. scope .. '"'
        .. '\nCOUNTF="$CACHE_DIR/count-' .. scope .. '"'
end

local function readScope(dir)
    local raw = noctalia.readFile(dir .. "/scope")
    if type(raw) == "string" then
        local value = trim(raw)
        if SCOPE_GLYPHS[value] ~= nil then
            return value
        end
    end
    return DEFAULT_SCOPE
end

local function writeScope(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/scope", value)
    if not ok then
        noctalia.log("file-search: could not persist the scope: " .. tostring(err))
    end
end

local function readRowAction(dir)
    local raw = noctalia.readFile(dir .. "/row-action")
    if type(raw) == "string" then
        local value = trim(raw)
        if ROW_ACTION_GLYPHS[value] ~= nil then
            return value
        end
    end
    return DEFAULT_ROW_ACTION
end

local function writeRowAction(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/row-action", value)
    if not ok then
        noctalia.log("file-search: could not persist the row action: " .. tostring(err))
    end
end

local function readRanking(dir)
    local raw = noctalia.readFile(dir .. "/ranking")
    if type(raw) == "string" then
        local value = trim(raw)
        if RANKING_GLYPHS[value] ~= nil then
            return value
        end
    end
    return DEFAULT_RANKING
end

local function writeRanking(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/ranking", value)
    if not ok then
        noctalia.log("file-search: could not persist the ranking: " .. tostring(err))
    end
end

local function searchRoot()
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

local function maxResults()
    return math.max(10, math.min(200, tonumber(noctalia.getConfig("max_results")) or 50))
end

-- Excluded directory names from the setting, split on ',' or ';'. Matching
-- is by basename (find -name), so entries containing '/' are skipped and
-- logged. Hidden entries are folded in as an extra '.*' pattern.
local function excludeNames()
    local raw = noctalia.getConfig("exclude_dirs")
    if type(raw) ~= "string" then
        raw = ""
    end
    local names = {}
    for entry in raw:gmatch("[^,;]+") do
        local name = trim(entry)
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
local function usableMount(path)
    if path == nil or path == "" or path:sub(1, 1) ~= "/" then
        return false
    end
    if path == "/" or path:find("%c") ~= nil then
        return false
    end
    return path ~= "/boot" and not startsWith(path, "/boot/")
end

-- lsblk --pairs quotes every value; depending on the util-linux version a
-- space or a quote inside one can come back as a \xNN escape. nil for an
-- escaped control byte: the whole mount point is then dropped by the caller,
-- rather than kept with a literal "\x0a" in it that no path would match.
local function unescapeHex(value)
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

local function pairValue(line, key)
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
local function parseLsblk(out)
    local rows, byName = {}, {}
    for line in out:gmatch("[^\n]+") do
        local name = pairValue(line, "NAME")
        if name ~= nil and name ~= "" then
            local row = {
                parent = pairValue(line, "PKNAME") or "",
                removable = pairValue(line, "RM") == "1",
                transport = pairValue(line, "TRAN") or "",
                mount = unescapeHex(pairValue(line, "MOUNTPOINT") or ""),
            }
            byName[name] = row
            table.insert(rows, row)
        end
    end
    local found = {}
    for _, row in ipairs(rows) do
        if usableMount(row.mount) then
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
local function fallbackMounts()
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
            if rest ~= nil and rest ~= "" and usableMount(path) then
                table.insert(found, path)
            end
        end
    end
    return found
end

-- Refresh `mounts`, then continue. Async because lsblk is a process: every
-- caller has to be written as a continuation. Skipped entirely — no spawn at
-- all — while the scope is the search folder, so the default costs nothing,
-- and a scan younger than MOUNT_TTL is reused unless `force` says otherwise
-- (the refresh button forces one, since noticing a disk is the point of it).
-- Callers must not call this concurrently: requestReload is the single caller
-- that serialises them.
local function probeMounts(force, done)
    if scope == "folder" then
        mounts = {}
        done()
        return
    end
    if not force and mountsAt > 0 and (now() - mountsAt) < MOUNT_TTL then
        done()
        return
    end
    local function finish()
        mountsAt = now()
        probing = false
        done()
    end
    if probing then
        -- requestReload serialises callers, so this is defensive only: never
        -- start a second scan, and keep the list we already have rather than
        -- replacing it with a narrower one.
        done()
        return
    end
    if not noctalia.commandExists("lsblk") then
        mounts = fallbackMounts()
        finish()
        return
    end
    probing = true
    local ok = noctalia.runAsync("lsblk -P -o NAME,PKNAME,RM,TRAN,MOUNTPOINT 2>/dev/null", function(result)
        if result.exitCode == 0 and not result.timedOut then
            mounts = parseLsblk(result.stdout or "")
        else
            mounts = fallbackMounts()
        end
        finish()
    end, 10000)
    if not ok then
        mounts = fallbackMounts()
        finish()
    end
end

-- The roots the index covers, ancestors first and without overlaps: a volume
-- mounted inside the search folder (or inside another volume) would otherwise
-- be walked twice and produce duplicate rows. Sorting puts a parent before its
-- children, so one pass is enough to drop the nested ones.
local function computeRoots()
    local list = {}
    if scope ~= "external" then
        table.insert(list, searchRoot())
    end
    if scope ~= "folder" then
        for _, mount in ipairs(mounts) do
            table.insert(list, (mount:gsub("/+$", "")))
        end
    end
    table.sort(list)
    local kept = {}
    for _, path in ipairs(list) do
        local nested = false
        for _, parent in ipairs(kept) do
            if path == parent or startsWith(path, parent == "/" and "/" or parent .. "/") then
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
-- never be read back as a root.
local function indexKey()
    return INDEX_FORMAT .. "\n" .. scope
        .. "\n--\n" .. table.concat(roots, "\n")
        .. "\n--\n" .. table.concat(excludeNames(), "\n")
end

-- The cache on disk is current when its fingerprint matches, whether the panel
-- or the launcher built it.
local function cacheFresh(dir)
    return noctalia.readFile(dir .. "/meta-" .. scope) == indexKey()
end

-- The roots the index on disk was built with, read back out of its fingerprint,
-- or nil when there is no index. Records must be read the way they were
-- WRITTEN, not the way a fresh walk would write them now: unplug one of two
-- disks and the file still holds absolute records, so deciding the format from
-- the current mount list would make every row unopenable — including the rows
-- of the disk still attached — until the next rebuild.
local function indexRootsOf(dir)
    local meta = noctalia.readFile(dir .. "/meta-" .. scope)
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

-- Code-point slices. Byte offsets would split a multi-byte character and
-- produce invalid UTF-8, which the text renderer then refuses to measure.
local function headChars(value, count)
    local byte = utf8.offset(value, count + 1)
    return byte ~= nil and value:sub(1, byte - 1) or value
end

local function tailChars(value, count)
    local length = utf8.len(value)
    if length == nil or count >= length then
        return value
    end
    local byte = utf8.offset(value, length - count + 1)
    return byte ~= nil and value:sub(byte) or value
end

-- Shorten an over-long path by dropping its MIDDLE, keeping both the root it
-- starts from and the name it ends with:
--   .local/share/flatpak/repo/tmp/cache/summaries/dolphin.idx.sig
--   → .local/share/flatpak/repo/tmp/cache/…dolphin.idx.sig
-- End-truncation would cut away the file name, which is the very thing the
-- query matched, so the trailing component is kept whole whenever it fits and
-- the head takes what is left of the budget. utf8.len returns nil on invalid
-- UTF-8 (it never throws, unlike utf8.codes), and such a name is left alone
-- rather than sliced at a guessed offset.
local function elidePath(rel)
    -- Byte length is never below the code-point count, so a string short in
    -- bytes is short in characters — and the common case skips the O(n)
    -- utf8.len entirely. This runs for every visible row on every render.
    if #rel <= PATH_MAX_CHARS then
        return rel
    end
    local length = utf8.len(rel)
    if length == nil or length <= PATH_MAX_CHARS then
        return rel
    end
    local budget = PATH_MAX_CHARS - 1 -- the ellipsis occupies one column
    -- Trailing component, with a directory's own "/" kept as part of it.
    local base = rel:match("[^/]+/?$") or ""
    local baseLen = utf8.len(base) or 0
    if baseLen >= budget then
        -- A single component longer than the whole row: no head to show.
        return ELLIPSIS .. tailChars(rel, budget)
    end
    local headPart = headChars(rel, budget - baseLen)
    -- Retreat to the last separator so the head ends on a whole directory:
    -- ".../tmp/cache/…name" reads as a path, ".../tmp/cache/summ…name" reads
    -- as a glitch. Costs a few characters; kept raw when there is no
    -- separator to retreat to.
    local atSeparator = headPart:match("^(.*/)[^/]*$")
    if atSeparator ~= nil and atSeparator ~= "" then
        headPart = atSeparator
    end
    return headPart .. ELLIPSIS .. base
end

-- Count the cache the panel is about to search. buildIndex records the total
-- as a side effect of building, but a panel opening on a cache that is already
-- fresh -- the common case, and the one the launcher leaves behind -- never
-- runs it, so the footer used to report "0 indexed" for a perfectly good
-- index. Counted with wc rather than readFile: the list can hold hundreds of
-- thousands of paths and none of them are needed here, only how many.
--
-- A build records its own count in a `count-<scope>` sidecar, so the usual path
-- is a 7-byte read and no process at all. The rest is the fallback for an index
-- built before that existed: memoized per scope against the file's size and
-- mtime, because wc has to read the whole thing — an index of a large disk is
-- >100 MB, and paying that read on every scope change is what made the button
-- feel like it wedged the shell.
local function readTotal(dir)
    local target = scope
    buildMs = nil -- belongs to the index of this scope, if that one recorded it
    local recorded = noctalia.readFile(dir .. "/count-" .. target)
    if recorded ~= nil then
        local count, elapsed = trim(recorded):match("^(%d+)%s+(%d+)$")
        total = tonumber(count or trim(recorded)) or 0
        buildMs = tonumber(elapsed)
        return
    end
    local info = noctalia.fileInfo(dir .. "/list-" .. target)
    if info == nil then
        total = 0
        return
    end
    local memo = totals[target]
    if memo ~= nil and memo.size == info.size and memo.mtime == info.mtime then
        total = memo.count
        return
    end
    local cmd = cacheSh(dir) .. '\nwc -l < "$CACHE" 2>/dev/null'
    noctalia.runAsync(cmd, function(result)
        if result.exitCode == 0 and not result.timedOut then
            local count = tonumber(trim(result.stdout or "")) or 0
            totals[target] = { count = count, size = info.size, mtime = info.mtime }
            if scope == target then
                total = count
                render()
            end
        end
    end, 15000)
end

buildIndex = function()
    if fzfMissing or indexing then
        return
    end
    local dir = dataDir()
    if dir == nil then
        errMsg = tr("err_index")
        render()
        return
    end
    if #roots == 0 then
        -- Scope "external" with nothing plugged in. Nothing to walk, and no
        -- cache to write either: render() says so, and the next call is one
        -- cheap early return rather than a spawn per keystroke.
        haveIndex = false
        results = {}
        total = 0
        render()
        return
    end
    indexing = true
    errMsg = nil
    local key = indexKey()
    -- The format this walk WRITES follows the roots it is about to visit, not
    -- the format of the index being replaced.
    local builtRoots = roots
    local absolute = #builtRoots > 1
    local builtScope = scope

    -- Names containing a newline would each forge extra one-per-fragment
    -- records (a crafted name can smuggle '..' lines into the index), so
    -- they are pruned unconditionally, before the volume noise and the user's
    -- own exclusions.
    local names = { "-name " .. shellQuote("*\n*") }
    for _, pattern in ipairs(VOLUME_NOISE) do
        table.insert(names, "-iname " .. shellQuote(pattern))
    end
    for _, name in ipairs(excludeNames()) do
        table.insert(names, "-name " .. shellQuote(name))
    end
    local prune = "\\( " .. table.concat(names, " -o ") .. " \\) -prune -o "
    local args = {}
    for _, root in ipairs(roots) do
        table.insert(args, shellQuote(root))
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
    -- find's own exit status is ignored, so permission errors inside the tree
    -- don't fail the build. Cache and fingerprint are written to
    -- mktemp-created private files and renamed into place: rename replaces
    -- a planted symlink at the destination instead of following it. The
    -- host guarantees $CACHE_DIR exists (created by pluginDataDir above).
    -- The two cleanup lines drop the pre-0.0.20 single-scope cache and any
    -- temp file a killed build left behind — only ones older than 90 minutes,
    -- comfortably past the 30-minute build ceiling, so a walk running in the
    -- other entry is never touched.
    local cmd = cacheSh(dir)
        .. '\nrm -f "$CACHE_DIR/index.list" "$CACHE_DIR/index.meta"\n'
        .. 'find "$CACHE_DIR" -maxdepth 1 \\( -name \'list-*.*\' -o -name \'meta-*.*\''
        .. " -o -name 'count-*.*' \\) -mmin +90 -delete 2>/dev/null\n"
        -- Timed here rather than around runAsync: this is the walk itself,
        -- without the queueing and callback hops the shell knows nothing about.
        .. 'START=$(date +%s%3N)\n'
        .. 'TMP=$(mktemp "$CACHE_DIR/list-' .. scope .. '.XXXXXX") || exit 1\n'
        .. walk .. "\n"
        .. 'mv -f "$TMP" "$CACHE" || exit 1\n'
        .. 'TMPM=$(mktemp "$CACHE_DIR/meta-' .. scope .. '.XXXXXX") || exit 1\n'
        .. "printf '%s' " .. shellQuote(key) .. ' > "$TMPM"\n'
        .. 'mv -f "$TMPM" "$META" || exit 1\n'
        -- The count is taken here, while the file is already hot, and left in a
        -- sidecar together with the elapsed milliseconds: every later open
        -- reads a dozen bytes instead of the whole index, and the footer can
        -- still say how long the walk behind it took.
        .. 'COUNT=$(wc -l < "$CACHE") || exit 1\n'
        .. 'ELAPSED=$(( $(date +%s%3N) - START ))\n'
        .. 'TMPN=$(mktemp "$CACHE_DIR/count-' .. scope .. '.XXXXXX") || exit 1\n'
        .. 'printf "%s %s" "$COUNT" "$ELAPSED" > "$TMPN"\n'
        .. 'mv -f "$TMPN" "$COUNTF" || exit 1\n'
        .. 'printf "%s %s" "$COUNT" "$ELAPSED"'

    render()
    local timeout = (scope == "folder") and BUILD_TIMEOUT_LOCAL or BUILD_TIMEOUT_DISKS
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        if result.exitCode == 0 and not result.timedOut then
            totals[builtScope] = nil -- size/mtime moved; recount lazily
            if builtScope ~= scope then
                -- The scope was cycled while the walk ran, so what just landed
                -- on disk is not what the panel is showing: none of it — the
                -- count, the freshness — describes the current scope. Derive
                -- the state again instead of inheriting it.
                applyState()
            else
                -- The file on disk is the one this walk just wrote: read it
                -- the way it was written.
                indexRoots = builtRoots
                absoluteRecords = absolute
                haveIndex = true
                local count, elapsed = trim(result.stdout or ""):match("^(%d+)%s+(%d+)$")
                total = tonumber(count) or 0
                buildMs = tonumber(elapsed)
                if indexKey() == key then
                    indexState = "fresh"
                    runSearch()
                elseif autoIndexAllowed() then
                    -- Roots or exclusions moved during the walk (a disk came or
                    -- went). Chasing that is fine for the search folder.
                    buildIndex()
                else
                    -- For a disk it would be a second multi-minute walk nobody
                    -- asked for, so the index is just marked out of date.
                    indexState = "stale"
                    runSearch()
                end
            end
        else
            haveIndex = false
            errMsg = tr("err_index")
        end
        render()
    end, timeout)
    if not ok then
        indexing = false
        errMsg = tr("err_spawn")
        render()
    end
end

runSearch = function()
    if fzfMissing or indexing or searching or not haveIndex then
        return
    end
    local dir = dataDir()
    if dir == nil then
        return
    end
    searching = true
    local q = query
    local limit = maxResults()
    local cmd
    if trim(q) == "" then
        cmd = cacheSh(dir) .. '\nhead -n ' .. limit .. ' "$CACHE" 2>/dev/null'
    else
        -- head closes the pipe early; the pipeline status stays head's (0).
        cmd = cacheSh(dir) .. "\nfzf" .. rankingFlag() .. " --filter=" .. shellQuote(q)
            .. ' < "$CACHE" 2>/dev/null | head -n ' .. limit
    end
    local ok = noctalia.runAsync(cmd, function(result)
        searching = false
        if not result.timedOut then
            results = {}
            for line in (result.stdout or ""):gmatch("[^\n]+") do
                table.insert(results, line)
            end
        end
        -- The query moved on while this search ran: chase it. The stale
        -- rows rendered below are overwritten as soon as it completes.
        if query ~= q then
            runSearch()
        end
        render()
    end, 15000)
    if not ok then
        searching = false
    end
end

-- An index record turned into a path, or nil when it could resolve outside the
-- roots it was supposed to come from. The cache is a plain user-editable file,
-- so records are untrusted. Only ever called from the two callbacks that act
-- on a row — never from render: it walks every path component, and paying that
-- per row per frame is what gets a script callback killed for exceeding its
-- CPU budget.
local function absolutePath(record)
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
    local from = #indexRoots > 0 and indexRoots or roots
    if absoluteRecords then
        for _, root in ipairs(from) do
            if startsWith(path, root == "/" and "/" or root .. "/") then
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

local function rejectRecord(rel)
    noctalia.log("file-search: refusing unsafe index record: " .. rel)
    noctalia.notify(tr("title"), tr("err_bad_record"))
end

local function openEntry(rel)
    local path = absolutePath(rel)
    if path == nil then
        rejectRecord(rel)
        return
    end
    noctalia.runAsync("xdg-open " .. shellQuote(path) .. " >/dev/null 2>&1")
    panel.close()
end

-- Copy leaves the panel up so several rows can be picked off in a row.
local function copyEntry(rel)
    local path = absolutePath(rel)
    if path == nil then
        rejectRecord(rel)
        return
    end
    noctalia.copyToClipboard(path, "text/plain")
    noctalia.notify(tr("title"), tr("copied_entry"))
end

-- file:// URI for a local path. Every byte outside the unreserved set is
-- percent-encoded one byte at a time, which is also the correct encoding for
-- the UTF-8 sequences of a non-ASCII name — and it leaves the result free of
-- quotes and spaces, so it can be dropped into a GVariant literal as-is.
local function fileUri(path)
    return "file://" .. (path:gsub("[^%w%-%._~/]", function(byte)
        return string.format("%%%02X", string.byte(byte))
    end))
end

-- Show the entry in the system file manager: its containing folder opens with
-- the entry itself selected, for a directory too (its parent opens, with the
-- directory highlighted) — left click is what enters a directory.
--
-- ShowItems on the org.freedesktop.FileManager1 interface is the portable way
-- to say "reveal this": Thunar, Nautilus, Dolphin, Nemo, Caja and PCManFM-Qt
-- all implement it, and the session bus activates the handler on demand, so
-- the file manager does not need to be running. When there is no such handler
-- (or no gdbus at all: the `||` also catches a 127 from the shell), the
-- fallback opens the containing folder through the MIME association, which is
-- the same window minus the selection.
local function revealEntry(rel)
    local path = absolutePath(rel)
    if path == nil then
        rejectRecord(rel)
        return
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then
        parent = "/"
    end
    local cmd = "gdbus call --session --dest org.freedesktop.FileManager1"
        .. " --object-path /org/freedesktop/FileManager1"
        .. " --method org.freedesktop.FileManager1.ShowItems "
        .. shellQuote('["' .. fileUri(path) .. '"]') .. " ''"
        .. " >/dev/null 2>&1 || xdg-open " .. shellQuote(parent) .. " >/dev/null 2>&1"
    noctalia.runAsync(cmd)
end

local function resultRow(rel, index)
    local isDir = rel:sub(-1) == "/"
    -- The row carries no tooltip on purpose: one string per row is enough
    -- extra weight, over a list this long, to get the render's callback killed
    -- for exceeding its CPU budget. Right click yields the full path instead.
    local shown = elidePath(rel)
    return ui.button({
        key = "hit-" .. index,
        glyph = isDir and "folder" or "file",
        text = shown,
        variant = "ghost",
        contentAlign = "start",
        onClick = function()
            openEntry(rel) -- always the full record, never the elided label
        end,
        -- The secondary action, whichever the header toggle currently names.
        -- Right rather than middle because a ui.button never receives the
        -- middle button: it accepts BTN_LEFT, plus BTN_RIGHT only once an
        -- onRightClick is attached, and no node in the declarative UI exposes
        -- a middle-click callback at all — that one is a bar-widget gesture.
        -- Read at click time, not captured, so flipping the toggle changes
        -- what the rows already on screen do.
        onRightClick = function()
            if rowAction == "reveal" then
                revealEntry(rel)
            else
                copyEntry(rel)
            end
        end,
    })
end

-- Milliseconds as something a person reads at a glance: "820 ms", "12.4 s",
-- "7m 41s". A disk walk is minutes, a warm home folder is under a second, and
-- the same string has to serve both.
local function formatDuration(ms)
    if ms < 1000 then
        return string.format("%d ms", ms)
    end
    local seconds = ms / 1000
    if seconds < 60 then
        return string.format("%.1f s", seconds)
    end
    return string.format("%dm %02ds", math.floor(seconds / 60), math.floor(seconds % 60))
end

-- One dim line of fzf's extended-search operators, between the results and the
-- status bar. They are the difference between "many matches" and "the one", and
-- nothing else in the panel hints that the query field understands more than
-- letters. One label, not a row of chips: the cheapest node count for something
-- that renders on every keystroke.
-- Two labels rather than one string: the caption says what the row is, dimmed
-- so it reads as a label and not as part of the syntax, and the operators
-- themselves stay in the brighter colour because they are the content.
local function syntaxLegend()
    return ui.row({ key = "legend", gap = 6, align = "center" }, {
        ui.label({
            key = "legend-caption",
            text = tr("syntax_hint_label"),
            fontSize = 10,
            color = "on_surface_variant",
        }),
        ui.label({ key = "legend-ops", text = tr("syntax_hint"), fontSize = 10, color = "on_surface" }),
    })
end

-- Counts on the left, how long the walk behind this index took on the right.
-- The duration is the one recorded in the count sidecar, so it survives a
-- restart and follows the scope: switching to the disks shows the disks' own
-- walk, not the last one that happened to run. It stays on screen during a
-- rebuild too — "the last one took 7m 41s" is exactly what you want to know
-- while waiting for this one.
local function statusFooter()
    local left, tone
    if indexing then
        -- One root gets named; several would wrap the footer onto a second
        -- line, so they are counted instead.
        left = #roots > 1
            and tr("status_indexing_multi", { count = #roots })
            or tr("status_indexing", { path = roots[1] or searchRoot() })
        tone = "secondary"
    else
        left = tr("counts", { shown = #results, total = total or 0 })
        if scope ~= "folder" then
            left = left .. tr("counts_disks", { disks = #mounts })
        end
        if indexState == "stale" then
            -- Searchable, but built for a different scope or disk set. Saying
            -- so is the honest alternative to silently re-walking a 5 TB drive.
            left = left .. tr("counts_stale")
            tone = "secondary"
        else
            tone = "on_surface_variant"
        end
    end
    local children = {
        ui.label({ key = "counts", text = left, fontSize = 11, color = tone, flexGrow = 1 }),
    }
    if buildMs ~= nil then
        table.insert(children, ui.label({
            key = "elapsed",
            text = tr("build_time", { duration = formatDuration(buildMs) }),
            fontSize = 11,
            color = "on_surface_variant",
        }))
    end
    return ui.row({ key = "footer", gap = 8, align = "center" }, children)
end

-- The scope button cycles folder → folder+disks → disks only. A cycling button
-- rather than a ui.select: the panel is 480px tall and the header row is the
-- only space that costs nothing, and the tooltip names both the current scope
-- and the next one, which a select's collapsed state would not.
-- Names what a right click does, and switches it. Its glyph is the answer to
-- "what happens if I right-click a result", which is the question a user of a
-- two-gesture list actually asks.
local function rowActionButton()
    return ui.button({
        key = "rowaction-" .. rowAction,
        glyph = ROW_ACTION_GLYPHS[rowAction],
        variant = "ghost",
        tooltip = tr("tip_row_action", {
            current = tr("row_action." .. rowAction),
            next = tr("row_action." .. NEXT_ROW_ACTION[rowAction]),
        }),
        onClick = "onCycleRowAction",
    })
end

-- Names the scoring scheme and switches it. The tooltip has to carry the whole
-- explanation: the difference only shows up in the order of the rows, and there
-- is nowhere else to say what changed. When fzf is too old for --scheme the
-- button stays on the generic scheme and says why, rather than disappearing.
local function rankingButton()
    local tip = schemeSupported
        and tr("tip_ranking", {
            current = tr("ranking." .. ranking),
            next = tr("ranking." .. NEXT_RANKING[ranking]),
        })
        or tr("tip_ranking_unsupported")
    return ui.button({
        key = "ranking-" .. ranking,
        glyph = RANKING_GLYPHS[schemeSupported and ranking or "default"],
        variant = "ghost",
        tooltip = tip,
        onClick = "onCycleRanking",
    })
end

local function scopeButton()
    return ui.button({
        key = "scope-" .. scope,
        glyph = SCOPE_GLYPHS[scope],
        variant = "ghost",
        tooltip = tr("tip_scope", {
            current = tr("scope." .. scope),
            next = tr("scope." .. NEXT_SCOPE[scope]),
        }),
        onClick = "onCycleScope",
    })
end

render = function()
    -- Every child of the panel and of the header carries a stable key, so the
    -- reconciler matches roles instead of guessing by position and type.
    local children = {
        ui.row({ key = "header", gap = 6, align = "center" }, {
            ui.label({
                key = "title",
                text = tr("title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
            }),
            -- Version off the manifest, small and dimmed: it answers "which
            -- build am I running" without competing with the title. The spacer
            -- rather than a flexGrow title keeps the two together on the left.
            ui.label({ key = "version", text = pluginVersion, fontSize = 10, color = "on_surface_variant" }),
            ui.spacer({ key = "gap", flexGrow = 1 }),
            rankingButton(),
            rowActionButton(),
            scopeButton(),
            ui.button({ key = "refresh", glyph = "refresh", variant = "ghost", tooltip = tr("tip_refresh"), onClick = "onRefreshIndex" }),
            ui.button({ key = "settings", glyph = "settings", variant = "ghost", tooltip = tr("tip_settings"), onClick = "onOpenSettings" }),
            ui.button({ key = "close", glyph = "close", variant = "ghost", tooltip = tr("tip_close"), onClick = "onClosePanel" }),
        }),
        ui.input({
            key = "query-" .. inputRev,
            value = query,
            focus = true,
            placeholder = tr("search_placeholder"),
            onChange = "onQueryChanged",
            onSubmit = "onOpenFirst",
        }),
    }

    -- Whatever the state, the body is ONE keyed column that grows: the results
    -- list and every message live inside it. Swapping node types at the top
    -- level is what left the panel short of its own height, with dead space
    -- under the status bar: the reconciler matches children by (type, key), so
    -- a changed sequence detaches them all and re-matches — unkeyed labels get
    -- handed to whichever role asks for a label first, and a prop the new role
    -- does not set (flexGrow among them) is never reset, it just carries over
    -- from the previous tenant. A constant shape has nothing to re-match.
    local body
    if fzfMissing then
        body = ui.label({ key = "body-msg", text = tr("err_no_fzf"), color = "error", flexGrow = 1 })
    elseif errMsg ~= nil then
        body = ui.label({ key = "body-msg", text = errMsg, color = "error", flexGrow = 1 })
    elseif #roots == 0 and not indexing then
        -- Only reachable with scope "external": nothing to search, and
        -- "no matches" would blame the query for it.
        body = ui.label({ key = "body-msg", text = tr("no_external"), color = "on_surface_variant", flexGrow = 1 })
    elseif indexState == "missing" and not indexing then
        -- A disk scope that has never been indexed. Walking it is a
        -- minutes-long operation on a large drive, so it is offered rather
        -- than performed.
        body = ui.label({ key = "body-msg", text = tr("index_missing"), color = "on_surface_variant", flexGrow = 1 })
    elseif #results == 0 and not indexing and trim(query) ~= "" then
        body = ui.label({
            key = "body-msg",
            text = tr("no_results", { query = query }),
            color = "on_surface_variant",
            flexGrow = 1,
        })
    else
        local rows = {}
        for index, rel in ipairs(results) do
            table.insert(rows, resultRow(rel, index))
        end
        body = ui.scroll({ key = "hits", flexGrow = 1, gap = 2 }, rows)
    end
    table.insert(children, ui.column({ key = "body", flexGrow = 1, align = "stretch" }, { body }))
    table.insert(children, syntaxLegend())
    table.insert(children, statusFooter())

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

-- Recompute the roots from the current scope and mounts, then search the cache
-- that belongs to them. A stale fingerprint only triggers a walk when
-- autoIndexAllowed() says so; otherwise the existing index is searched as-is
-- and flagged, or the panel asks for a rebuild when there is none at all.
applyState = function()
    roots = computeRoots()
    local dir = dataDir()
    if dir == nil then
        errMsg = tr("err_index")
        render()
        return
    end
    -- How to read what is on disk; a walk started below overwrites both.
    indexRoots = indexRootsOf(dir) or roots
    absoluteRecords = #indexRoots > 1
    if cacheFresh(dir) then
        haveIndex = true
        indexState = "fresh"
        -- buildIndex would have set the total; reusing a cache has to go and
        -- count it (memoized).
        readTotal(dir)
        runSearch()
    elseif autoIndexAllowed() then
        results = {}
        total = nil
        buildIndex()
    else
        -- Out of date, and not ours to fix on our own: an index built for
        -- another disk set still answers most queries, so it is searched and
        -- labelled rather than thrown away.
        haveIndex = noctalia.fileExists(dir .. "/list-" .. scope)
        indexState = haveIndex and "stale" or "missing"
        if haveIndex then
            readTotal(dir)
            runSearch()
        else
            results = {}
            total = 0
        end
    end
    render()
end

-- The one way to refresh what the panel shows. Mashing the scope button must
-- not stack work: while a pass is in flight the next one is a single flag, and
-- it then runs once against whatever the state has become. Without this, every
-- press queued its own mount scan, its own count and its own search.
--
-- force: rescan the disks even if the last scan is still young.
-- build: walk the tree when the probe comes back, whatever the fingerprint
-- says. Only the refresh button passes it — it is the explicit command that
-- autoIndexAllowed() defers to.
local function requestReload(force, build)
    if reloading then
        reloadQueued = true
        queuedForce = queuedForce or force
        queuedBuild = queuedBuild or build
        return
    end
    reloading = true
    probeMounts(force, function()
        reloading = false
        if build then
            roots = computeRoots()
            -- The index being replaced stays readable until the walk lands, so
            -- a row clicked meanwhile still resolves.
            local dir = dataDir()
            if dir ~= nil then
                indexRoots = indexRootsOf(dir) or roots
                absoluteRecords = #indexRoots > 1
            end
            results = {}
            total = nil
            errMsg = nil
            haveIndex = false
            buildIndex()
            render()
        else
            applyState()
        end
        if reloadQueued then
            reloadQueued = false
            local againForce, againBuild = queuedForce, queuedBuild
            queuedForce, queuedBuild = false, false
            requestReload(againForce, againBuild)
        end
    end)
end

function onOpen(_context)
    fzfMissing = not noctalia.commandExists("fzf")
    query = ""
    results = {}
    errMsg = nil
    -- Not trusted across opens: the scope may have moved under us (the
    -- launcher can cycle it), so nothing is searched until reload() has
    -- checked the fingerprint of the cache this scope actually uses.
    haveIndex = false
    inputRev += 1
    noctalia.state.set("file_search_open", true)
    local dir = dataDir()
    if dir ~= nil then
        -- Re-read on every open: the launcher may have cycled the scope, and
        -- a script reload drops both of these from memory.
        scope = readScope(dir)
        rowAction = readRowAction(dir)
        ranking = readRanking(dir)
    end
    if fzfMissing then
        render()
        return
    end
    render() -- the panel is up while lsblk answers
    requestReload(false, false)
end

function onClose()
    noctalia.state.set("file_search_open", false)
end

function onConfigChanged()
    if fzfMissing or indexing then
        return
    end
    -- Scope and mounts are re-read rather than reused: this fires while the
    -- panel is closed too, when the launcher may have cycled the scope and the
    -- in-memory mount list can predate it. Rebuilding a disk index from a stale
    -- (empty) list would throw away a good index and take minutes to redo.
    local dir = dataDir()
    if dir ~= nil then
        scope = readScope(dir)
    end
    requestReload(false, false)
end

function onQueryChanged(value)
    query = value
    runSearch()
end

function onOpenFirst(value)
    query = value
    if results[1] ~= nil then
        openEntry(results[1])
    end
end

-- The explicit command. This is the ONLY thing that walks an external disk:
-- opening the panel, changing the scope, changing a setting or plugging a disk
-- in all leave the existing index alone and just mark it out of date.
function onRefreshIndex()
    if indexing then
        return
    end
    -- A refresh is also how a disk plugged in after the panel opened gets
    -- noticed, so the mount scan is forced rather than reused.
    requestReload(true, true)
end

-- Allowed mid-build on purpose: a walk over a slow disk can run for minutes and
-- there is no way to cancel it, so blocking the button would trap the user in
-- the scope they are trying to leave. The in-flight build finishes against the
-- cache of the scope it started in and never starts another one by itself.
--
-- The press itself is deliberately cheap — a 6-byte write and a render. Every
-- process it might need (mount scan, count, search) goes through
-- requestReload, which collapses a burst of presses into one pass.
-- The index is untouched; only the order of the rows changes, so the current
-- query is simply run again through the other scheme.
function onCycleRanking()
    if not schemeSupported then
        return
    end
    ranking = NEXT_RANKING[ranking] or DEFAULT_RANKING
    local dir = dataDir()
    if dir ~= nil then
        writeRanking(dir, ranking)
    end
    render()
    runSearch()
end

-- Nothing to reload: this only changes what a right click will do next.
function onCycleRowAction()
    rowAction = NEXT_ROW_ACTION[rowAction] or DEFAULT_ROW_ACTION
    local dir = dataDir()
    if dir ~= nil then
        writeRowAction(dir, rowAction)
    end
    render()
end

function onCycleScope()
    scope = NEXT_SCOPE[scope] or DEFAULT_SCOPE
    local dir = dataDir()
    if dir ~= nil then
        writeScope(dir, scope)
    end
    results = {}
    total = nil
    errMsg = nil
    render()
    requestReload(false, false)
end

-- Opens the settings window on this plugin's own page (the host supplies the
-- plugin id, so a plugin can only ever open its own). The panel closes on the
-- way; the index survives it, since it lives in the plugin data directory.
function onOpenSettings()
    noctalia.openSettings()
end

function onClosePanel()
    panel.close()
end

probeFzfScheme()
