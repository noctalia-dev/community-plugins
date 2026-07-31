--!nonstrict
-- file-search — launcher provider: the same fuzzy search with the native
-- keyboard flow of the noctalia launcher (type, arrows, Enter).
--
-- `/fs <text>` fuzzy-matches over the index file the panel builds; when the
-- index is missing it is built here on demand. Activating a result opens it
-- with the system MIME association (xdg-open) — directories open in the
-- file manager. Late async results map back through the query echo of
-- launcher.setResults, so fzf can answer out of band.
--
-- The search scope (search folder / + removable disks / disks only) is the one
-- the panel persists in the plugin data directory; an empty `/fs` query offers
-- a row that cycles it here too, and each scope keeps its own index, so
-- switching back and forth never re-walks a tree twice.
--
-- Every helper below the tr() line down to computeRoots() is a copy of the
-- panel's: entries are separate scripts with no module system, so the two must
-- be kept in step by hand — in particular indexKey(), which is the fingerprint
-- that lets one entry reuse an index the other built.

local MAX_RESULTS = 9
local INDEX_FORMAT = "2"
-- Seconds a mount scan stays good for. Long enough that a burst of keystrokes
-- costs one lsblk at most, short enough that a disk plugged in mid-session
-- shows up without a manual refresh.
local MOUNT_TTL = 30

local VOLUME_NOISE = {
    "lost+found",
    "$RECYCLE.BIN", "RECYCLER", "System Volume Information",
    ".Trash-*",
    ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
    ".DocumentRevisions-V100", ".PKInstallSandboxManager",
    "Backups.backupdb", "*.sparsebundle", "*.backupbundle",
    "._*", ".DS_Store", ".AppleDouble", ".AppleDB", ".AppleDesktop",
    "Network Trash Folder", "Temporary Items", "TheVolumeSettingsFolder",
}

local SCOPE_GLYPHS = { folder = "folder", all = "folders", external = "usb" }
local NEXT_SCOPE = { folder = "all", all = "external", external = "folder" }
local DEFAULT_SCOPE = "folder"

local BUILD_TIMEOUT_LOCAL = 180000
local BUILD_TIMEOUT_DISKS = 1800000

local searching = false
local indexing = false
local probing = false
local forceBuild = false -- set by the rebuild row, consumed by the next onQuery
local pendingQuery = nil -- latest query typed while a search/index/probe ran
local scope = DEFAULT_SCOPE
local mounts = {}
local mountsAt = 0       -- unix seconds of the last mount scan (0 = never)
local roots = {}
local indexRoots = {}    -- what the index ON DISK was built with (indexRootsOf)
local absoluteRecords = false
local staleIndex = false -- searching an index that no longer matches the disks
local ranking = "path"   -- scoring scheme, as persisted by the panel's toggle
local schemeSupported = false -- whether this fzf understands --scheme at all

local runQuery

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

-- Same version gate as the panel: fzf learned --scheme in 0.36 and an older one
-- would exit on an unknown option, leaving the launcher with an empty list.
local function probeFzfScheme()
    noctalia.runAsync("fzf --version 2>/dev/null", function(result)
        local major, minor = (result.stdout or ""):match("(%d+)%.(%d+)")
        major, minor = tonumber(major), tonumber(minor)
        schemeSupported = major ~= nil and minor ~= nil and (major > 0 or minor >= 36)
    end, 5000)
end

local function rankingFlag()
    return (ranking == "path" and schemeSupported) and " --scheme=path" or ""
end

-- The panel owns the toggle; the launcher just follows what it wrote, re-read
-- per query like the scope so the two never rank the same index differently.
local function readRanking(dir)
    local raw = noctalia.readFile(dir .. "/ranking")
    if type(raw) == "string" then
        local value = trim(raw)
        if value == "path" or value == "default" then
            return value
        end
    end
    return "path"
end

-- Mirrors the panel: the search folder may be re-walked whenever its
-- fingerprint goes stale, an external disk never is. A 5 TB mechanical drive
-- takes minutes per walk, and a keystroke is not a mandate to spend them — the
-- rebuild row below is.
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

-- Shell header shared by every cache command. One cache pair per scope; the
-- .meta sidecar holds the settings fingerprint the cache was built with, so the
-- panel and the launcher can both tell a stale index apart.
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


-- Same exclusion set as the panel: names from the setting plus hidden
-- entries unless enabled.
local function excludeNames()
    local raw = noctalia.getConfig("exclude_dirs")
    if type(raw) ~= "string" then
        raw = ""
    end
    local names = {}
    for entry in raw:gmatch("[^,;]+") do
        local name = trim(entry)
        if name ~= "" and not name:find("/") then
            table.insert(names, name)
        end
    end
    if noctalia.getConfig("show_hidden") ~= true then
        table.insert(names, ".*")
    end
    return names
end

-- ── removable volume detection (mirrors panel.luau) ──────────────────────────

local function usableMount(path)
    if path == nil or path == "" or path:sub(1, 1) ~= "/" then
        return false
    end
    if path == "/" or path:find("%c") ~= nil then
        return false
    end
    return path ~= "/boot" and not startsWith(path, "/boot/")
end

-- nil for an escaped control byte, so the caller drops that mount point
-- entirely (see panel.luau).
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

-- USB/removable mount points. The transport lives on the disk, not on the
-- mounted partition, so the PKNAME chain is walked upwards; see the long
-- comment in panel.luau.
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

-- Fallback for a system without util-linux: the udisks2 mount convention.
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

-- Must build the same string as the panel's indexKey(): the fingerprint in
-- the .meta sidecar is how the two entries recognize each other's index.
local function indexKey()
    return INDEX_FORMAT .. "\n" .. scope
        .. "\n--\n" .. table.concat(roots, "\n")
        .. "\n--\n" .. table.concat(excludeNames(), "\n")
end

-- The cache on disk is current when its fingerprint matches the settings,
-- whether the panel or the launcher built it.
local function cacheFresh(dir)
    return noctalia.readFile(dir .. "/meta-" .. scope) == indexKey()
end

-- The roots the index on disk was built with, read back out of its fingerprint
-- (see panel.luau): records must be read the way they were written, or unplug
-- one of two disks and every row stops resolving until the next rebuild.
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

-- One cache record, about to be turned into a path. The cache is a plain
-- user-editable file, so records are untrusted: reject anything that could
-- resolve outside the roots it claims to come from.
local function absolutePath(record)
    if record == "" or record:find("%c") ~= nil then
        return nil
    end
    local path = record:gsub("/+$", "")
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            return nil
        end
    end
    -- Against the roots of the index the record came from, not of a walk that
    -- would happen now: a record can still never escape a root.
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

local function noopRow(titleKey)
    return { id = "noop", title = tr(titleKey), glyph = "info-circle" }
end

-- Row that cycles the scope, offered whenever the query is empty (and whenever
-- there is nothing to search), so the launcher is never a dead end when the
-- scope points at disks that are not plugged in.
local function scopeRow()
    return {
        id = "scope",
        title = tr("launcher.scope_title", { current = tr("scope." .. scope) }),
        subtitle = tr("launcher.scope_next", { next = tr("scope." .. NEXT_SCOPE[scope]) }),
        glyph = SCOPE_GLYPHS[scope],
    }
end

-- Activating this is what authorises a walk. It is always offered on an empty
-- query, and pushed to the top when the index for a disk scope is missing or
-- out of date, since nothing else will rebuild it.
local function reindexRow()
    return {
        id = "reindex",
        title = tr("launcher.reindex_title"),
        subtitle = #roots > 0 and table.concat(roots, "  ·  ") or tr("scope." .. scope),
        glyph = "refresh",
    }
end

local function buildIndex(query)
    if indexing then
        pendingQuery = query
        return
    end
    local dir = dataDir()
    if dir == nil then
        launcher.setResults(query, { noopRow("err_index") })
        return
    end
    if #roots == 0 then
        -- Scope "external" with nothing plugged in: nothing to walk, and no
        -- cache to write either. Say so, and keep the row that switches back.
        launcher.setResults(query, { noopRow("no_external"), scopeRow() })
        return
    end
    indexing = true
    pendingQuery = query

    local key = indexKey()
    -- The format this walk writes follows the roots it is about to visit.
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
    -- Relative records for a single root (short rows, and no common prefix for
    -- fzf to match on), absolute when several roots share one index.
    local printSpec = absolute
        and "-type d -printf '%p/\\n' -o -printf '%p\\n'"
        or "-type d -printf '%P/\\n' -o -printf '%P\\n'"
    local walk = "find " .. table.concat(args, " ") .. " -mindepth 1 " .. prune
        .. printSpec .. ' > "$TMP" 2>/dev/null'
    -- find's own exit status is ignored, so permission errors inside the
    -- tree don't fail the build. Cache and fingerprint are written to
    -- mktemp-created private files and renamed into place: rename replaces
    -- a planted symlink at the destination instead of following it. The
    -- host guarantees $CACHE_DIR exists (created by pluginDataDir above).
    local cmd = cacheSh(dir)
        .. '\nrm -f "$CACHE_DIR/index.list" "$CACHE_DIR/index.meta"\n'
        .. 'find "$CACHE_DIR" -maxdepth 1 \\( -name \'list-*.*\' -o -name \'meta-*.*\''
        .. " -o -name 'count-*.*' \\) -mmin +90 -delete 2>/dev/null\n"
        .. 'START=$(date +%s%3N)\n'
        .. 'TMP=$(mktemp "$CACHE_DIR/list-' .. scope .. '.XXXXXX") || exit 1\n'
        .. walk .. "\n"
        .. 'mv -f "$TMP" "$CACHE" || exit 1\n'
        .. 'TMPM=$(mktemp "$CACHE_DIR/meta-' .. scope .. '.XXXXXX") || exit 1\n'
        .. "printf '%s' " .. shellQuote(key) .. ' > "$TMPM"\n'
        .. 'mv -f "$TMPM" "$META" || exit 1\n'
        -- Same count sidecar the panel's footer reads — count and elapsed
        -- milliseconds — written while the file is hot so nobody has to re-read
        -- 100 MB to show a number.
        .. 'COUNT=$(wc -l < "$CACHE") || exit 1\n'
        .. 'ELAPSED=$(( $(date +%s%3N) - START ))\n'
        .. 'TMPN=$(mktemp "$CACHE_DIR/count-' .. scope .. '.XXXXXX") || exit 1\n'
        .. 'printf "%s %s" "$COUNT" "$ELAPSED" > "$TMPN"\n'
        .. 'mv -f "$TMPN" "$COUNTF" || exit 1'

    launcher.setResults(query, { noopRow("launcher.indexing") })
    local timeout = (scope == "folder") and BUILD_TIMEOUT_LOCAL or BUILD_TIMEOUT_DISKS
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        local queued = pendingQuery
        pendingQuery = nil
        if result.exitCode == 0 and not result.timedOut then
            if builtScope ~= scope then
                -- The scope row was activated while the walk ran: this index
                -- is not the one the launcher is showing. Start the query over
                -- so roots, records and freshness are derived for the scope
                -- that is actually current.
                onQuery(queued or query)
            else
                -- The file on disk is the one this walk just wrote: read it
                -- the way it was written.
                indexRoots = builtRoots
                absoluteRecords = absolute
                if indexKey() == key then
                    staleIndex = false
                    runQuery(queued or query)
                elseif autoIndexAllowed() then
                    -- Roots or exclusions moved during the walk; chasing that
                    -- is fine for the search folder.
                    buildIndex(queued or query)
                else
                    -- For a disk it would be a second unasked-for walk, which
                    -- is exactly what this plugin must not do.
                    staleIndex = true
                    runQuery(queued or query)
                end
            end
        else
            launcher.setResults(queued or query, { noopRow("err_index") })
        end
    end, timeout)
    if not ok then
        indexing = false
        launcher.setResults(query, { noopRow("err_spawn") })
    end
end

runQuery = function(query)
    if indexing then
        pendingQuery = query
        return
    end
    if searching then
        pendingQuery = query
        return
    end
    local dir = dataDir()
    if dir == nil then
        launcher.setResults(query, { noopRow("err_index") })
        return
    end
    local text = trim(query)
    if #roots == 0 then
        -- Scope "external" with nothing plugged in: say so, and keep the row
        -- that switches back within reach.
        launcher.setResults(query, { noopRow("no_external"), scopeRow() })
        return
    end
    searching = true
    local cmd
    if text == "" then
        cmd = cacheSh(dir) .. '\nhead -n ' .. MAX_RESULTS .. ' "$CACHE" 2>/dev/null'
    else
        cmd = cacheSh(dir) .. "\nfzf" .. rankingFlag() .. " --filter=" .. shellQuote(text)
            .. ' < "$CACHE" 2>/dev/null | head -n ' .. MAX_RESULTS
    end
    local ok = noctalia.runAsync(cmd, function(result)
        searching = false
        local rows = {}
        if not result.timedOut then
            for line in (result.stdout or ""):gmatch("[^\n]+") do
                local isDir = line:sub(-1) == "/"
                local rel = line:gsub("/+$", "")
                table.insert(rows, {
                    id = "open:" .. line,
                    title = rel:match("[^/]+$") or rel,
                    subtitle = line,
                    glyph = isDir and "folder" or "file",
                })
            end
        end
        if #rows == 0 and text ~= "" then
            table.insert(rows, noopRow("launcher.no_results"))
        end
        if text == "" then
            table.insert(rows, scopeRow())
            table.insert(rows, reindexRow())
        elseif staleIndex then
            -- Results came from an index that no longer matches the disks;
            -- the way to fix that travels with them.
            table.insert(rows, reindexRow())
        end
        launcher.setResults(query, rows)
        if pendingQuery ~= nil and pendingQuery ~= query then
            local nextQuery = pendingQuery
            pendingQuery = nil
            runQuery(nextQuery)
        end
    end, 15000)
    if not ok then
        searching = false
    end
end

-- Refresh the mount list if the scope needs it and the last scan has aged out,
-- then continue with whatever query is current by then. With the default scope
-- no process is spawned at all.
local function withMounts(query, done)
    if scope == "folder" then
        mounts = {}
        done(query)
        return
    end
    if mountsAt > 0 and (now() - mountsAt) < MOUNT_TTL then
        done(query)
        return
    end
    if probing then
        pendingQuery = query
        return
    end
    probing = true
    local function finish()
        probing = false
        mountsAt = now()
        local queued = pendingQuery
        pendingQuery = nil
        done(queued or query)
    end
    if not noctalia.commandExists("lsblk") then
        mounts = fallbackMounts()
        finish()
        return
    end
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

function onQuery(query)
    if not noctalia.commandExists("fzf") then
        launcher.setResults(query, { noopRow("err_no_fzf") })
        return
    end
    local dir = dataDir()
    if dir == nil then
        launcher.setResults(query, { noopRow("err_index") })
        return
    end
    -- Re-read on every query: the panel may have cycled the scope or the
    -- ranking since the last keystroke, and both files are a single word.
    scope = readScope(dir)
    ranking = readRanking(dir)
    withMounts(query, function(current)
        roots = computeRoots()
        -- How to read what is on disk right now; a walk below overwrites both.
        indexRoots = indexRootsOf(dir) or roots
        absoluteRecords = #indexRoots > 1
        if cacheFresh(dir) then
            staleIndex = false
            runQuery(current)
            return
        end
        -- A missing or stale index (no meta, or built with a different scope,
        -- root set or exclusions) is rebuilt before searching — but only for
        -- the search folder, or when the rebuild row asked for it. Records of
        -- a vanished root are not joined to a new one either way: they are
        -- validated against the current roots when activated.
        if forceBuild or autoIndexAllowed() then
            forceBuild = false
            staleIndex = false
            buildIndex(current)
            return
        end
        staleIndex = true
        if noctalia.fileExists(dir .. "/list-" .. scope) then
            runQuery(current)
        else
            launcher.setResults(current, { noopRow("launcher.index_missing"), reindexRow(), scopeRow() })
        end
    end)
end

function onActivate(id)
    if id == "scope" then
        local dir = dataDir()
        if dir == nil then
            return
        end
        scope = NEXT_SCOPE[scope] or DEFAULT_SCOPE
        writeScope(dir, scope)
        mountsAt = 0 -- the new scope may need a mount list this one never took
        -- Rewriting the query keeps the launcher open (the host only closes on
        -- an activation that does not call setQuery) and re-enters onQuery with
        -- an empty text, so the list comes back with the new scope applied.
        launcher.setQuery("")
        return
    end
    if id == "reindex" then
        -- The explicit command to walk the tree. Rewriting the query keeps the
        -- launcher open and re-enters onQuery, which consumes the flag and
        -- starts the build with "Indexing files…" on screen. It does not drop
        -- the current index first: if the walk fails or is aborted, the old one
        -- is still there to search.
        forceBuild = true
        mountsAt = 0 -- rescan: a disk may have been plugged in since
        launcher.setQuery("")
        return
    end
    local rel = id:match("^open:(.+)$")
    if rel == nil then
        return
    end
    local path = absolutePath(rel)
    if path == nil then
        noctalia.log("file-search: refusing unsafe index record: " .. rel)
        noctalia.notify(tr("title"), tr("err_bad_record"))
        return
    end
    noctalia.runAsync("xdg-open " .. shellQuote(path) .. " >/dev/null 2>&1")
end

probeFzfScheme()
