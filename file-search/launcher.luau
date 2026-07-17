--!nonstrict
-- file-search — launcher provider: the same fuzzy search with the native
-- keyboard flow of the noctalia launcher (type, arrows, Enter).
--
-- `/fs <text>` fuzzy-matches over the index file the panel builds; when the
-- index is missing it is built here on demand. Activating a result opens it
-- with the system MIME association (xdg-open) — directories open in the
-- file manager. Late async results map back through the query echo of
-- launcher.setResults, so fzf can answer out of band.

local MAX_RESULTS = 9

local searching = false
local indexing = false
local pendingQuery = nil -- latest query typed while a search/index ran

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

-- Shell header shared by every cache command. The .meta sidecar holds the
-- settings fingerprint the cache was built with, so the panel and the
-- launcher can both tell a stale index apart.
local function cacheSh(dir)
    return "CACHE_DIR=" .. shellQuote(dir)
        .. '\nCACHE="$CACHE_DIR/index.list"\nMETA="$CACHE_DIR/index.meta"'
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

-- Must build the same string as the panel's indexKey(): the fingerprint in
-- the .meta sidecar is how the two entries recognize each other's index.
local function indexKey()
    return searchRoot() .. "\n" .. table.concat(excludeNames(), "\n")
end

-- The cache on disk is current when its fingerprint matches the settings,
-- whether the panel or the launcher built it.
local function cacheFresh(dir)
    return noctalia.readFile(dir .. "/index.meta") == indexKey()
end

-- One cache record, about to be joined to the search root. The cache is a
-- plain user-editable file, so records are untrusted: reject anything that
-- could resolve outside the root.
local function safeRel(rel)
    if rel == "" or rel:sub(1, 1) == "/" or rel:find("\n", 1, true) then
        return false
    end
    for part in rel:gmatch("[^/]+") do
        if part == ".." then
            return false
        end
    end
    return true
end

local function noopRow(titleKey)
    return { id = "noop", title = tr(titleKey), glyph = "info-circle" }
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
    indexing = true
    pendingQuery = query

    local key = indexKey()
    -- Names containing a newline would each forge extra one-per-fragment
    -- records (a crafted name can smuggle '..' lines into the index), so
    -- they are pruned unconditionally, before the user's exclusions.
    local names = { "-name " .. shellQuote("*\n*") }
    for _, name in ipairs(excludeNames()) do
        table.insert(names, "-name " .. shellQuote(name))
    end
    local prune = "\\( " .. table.concat(names, " -o ") .. " \\) -prune -o "
    -- find's own exit status is ignored, so permission errors inside the
    -- tree don't fail the build. Cache and fingerprint are written to
    -- mktemp-created private files and renamed into place: rename replaces
    -- a planted symlink at the destination instead of following it. The
    -- host guarantees $CACHE_DIR exists (created by pluginDataDir above).
    local cmd = cacheSh(dir)
        .. '\nTMP=$(mktemp "$CACHE_DIR/index.list.XXXXXX") || exit 1\n'
        .. "find " .. shellQuote(searchRoot()) .. " -mindepth 1 " .. prune
        .. "-type d -printf '%P/\\n' -o -printf '%P\\n' > \"$TMP\" 2>/dev/null\n"
        .. 'mv -f "$TMP" "$CACHE" || exit 1\n'
        .. 'TMPM=$(mktemp "$CACHE_DIR/index.meta.XXXXXX") || exit 1\n'
        .. "printf '%s' " .. shellQuote(key) .. ' > "$TMPM"\n'
        .. 'mv -f "$TMPM" "$META" || exit 1'

    launcher.setResults(query, { noopRow("launcher.indexing") })
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        local queued = pendingQuery
        pendingQuery = nil
        if result.exitCode == 0 and not result.timedOut then
            if indexKey() ~= key then
                -- Settings changed while the walk was running: the cache
                -- holds paths relative to the old root, and activation
                -- would join them to the new one. Rebuild instead of
                -- searching stale records (mirrors the panel).
                buildIndex(queued or query)
            else
                runQuery(queued or query)
            end
        else
            launcher.setResults(queued or query, { noopRow("err_index") })
        end
    end, 180000)
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
    searching = true
    local text = trim(query)
    local cmd
    if text == "" then
        cmd = cacheSh(dir) .. '\nhead -n ' .. MAX_RESULTS .. ' "$CACHE" 2>/dev/null'
    else
        cmd = cacheSh(dir) .. "\nfzf --filter=" .. shellQuote(text)
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
            table.insert(rows, {
                id = "reindex",
                title = tr("launcher.reindex_title"),
                subtitle = searchRoot(),
                glyph = "refresh",
            })
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
    -- A missing or stale index (no meta, or built with a different root or
    -- exclusion set) is rebuilt before searching: stale relative paths
    -- joined to a new root could resolve to unrelated files.
    if not cacheFresh(dir) then
        buildIndex(query)
        return
    end
    runQuery(query)
end

function onActivate(id)
    if id == "reindex" then
        local dir = dataDir()
        if dir == nil then
            return
        end
        -- Drop cache and fingerprint so the next keystroke rebuilds against
        -- fresh disk state (a surviving .meta would read as a fresh index).
        noctalia.runAsync(cacheSh(dir) .. '\nrm -f "$CACHE" "$META"', function(_result)
            noctalia.notify(tr("title"), tr("launcher.reindex_done"))
        end)
        return
    end
    local rel = id:match("^open:(.+)$")
    if rel == nil then
        return
    end
    if not safeRel(rel) then
        noctalia.log("file-search: refusing unsafe index record: " .. rel)
        noctalia.notify(tr("title"), tr("err_bad_record"))
        return
    end
    local path = searchRoot()
    if path ~= "/" then
        path = path .. "/"
    end
    path = path .. rel:gsub("/+$", "")
    noctalia.runAsync("xdg-open " .. shellQuote(path) .. " >/dev/null 2>&1")
end
