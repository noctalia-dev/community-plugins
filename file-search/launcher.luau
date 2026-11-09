--!nonstrict
-- file-search — launcher provider: the same fuzzy search with the native
-- keyboard flow of the noctalia launcher (type, arrows, Enter).
--
-- `/fs <text>` fuzzy-matches over the index file the panel builds (built here
-- on demand when missing). Activating a result opens it with xdg-open.
-- An empty query offers rows that cycle the scope and rebuild the index.
-- The index, its fingerprint and the helpers live in shared.luau.
--
-- State: searching / indexing flags, forceBuild (set by the rebuild row,
-- consumed by the next onQuery), pendingQuery (latest query typed while a
-- search, index or probe ran), staleIndex (the index no longer matches the disks).

local MAX_RESULTS = 9

local shared = require("./shared.luau")

local searching = false
local indexing = false
local forceBuild = false -- set by the rebuild row, consumed by the next onQuery
local pendingQuery = nil -- latest query typed while a search/index/probe ran
local staleIndex = false -- searching an index that no longer matches the disks

local runQuery

local function noopRow(titleKey)
    return { id = "noop", title = shared.tr(titleKey), glyph = "info-circle" }
end

-- Row that cycles the scope, offered on an empty query and when there is nothing to search.
local function scopeRow()
    return {
        id = "scope",
        title = shared.tr(shared.scope == "all" and "opt_disks_on" or "opt_disks_off"),
        subtitle = shared.tr(shared.scope == "all" and "tip_disks_off" or "tip_disks_on"),
        glyph = shared.SCOPE_GLYPHS[shared.scope],
    }
end

-- Row that authorises a walk; offered on an empty query and when the disk index is missing or stale.
local function reindexRow()
    return {
        id = "reindex",
        title = shared.tr("launcher.reindex_title"),
        subtitle = #shared.roots > 0 and table.concat(shared.roots, "  ·  ") or shared.tr("scope." .. shared.scope),
        glyph = "refresh",
    }
end

local function buildIndex(query)
    if indexing then
        pendingQuery = query
        return
    end
    local dir = shared.dataDir()
    if dir == nil then
        launcher.setResults(query, { noopRow("err_index") })
        return
    end
    indexing = true
    pendingQuery = query

    local key = shared.indexKey()
    local builtRoots = shared.roots
    local absolute = #builtRoots > 1
    local builtScope = shared.cacheTag()
    local cmd = shared.buildCommand(dir, key, absolute)

    launcher.setResults(query, { noopRow("launcher.indexing") })
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        local queued = pendingQuery
        pendingQuery = nil
        if result.exitCode == 0 and not result.timedOut then
            if builtScope ~= shared.cacheTag() then
                -- The scope changed during the walk: start the query over.
                onQuery(queued or query)
            else
                shared.indexRoots = builtRoots
                shared.absoluteRecords = absolute
                if shared.indexKey() == key then
                    staleIndex = false
                    runQuery(queued or query)
                elseif shared.autoIndexAllowed() then
                    buildIndex(queued or query)
                else
                    staleIndex = true
                    runQuery(queued or query)
                end
            end
        else
            launcher.setResults(queued or query, { noopRow("err_index") })
        end
    end, shared.buildTimeout())
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
    local dir = shared.dataDir()
    if dir == nil then
        launcher.setResults(query, { noopRow("err_index") })
        return
    end
    local text = shared.trim(query)
    searching = true
    local ok = noctalia.runAsync(shared.searchCommand(dir, text, MAX_RESULTS), function(result)
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
            table.insert(rows, 1, scopeRow())
            table.insert(rows, 2, reindexRow())
        elseif staleIndex then
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

-- Refresh the mount list if needed, then call done() with the latest query; a query arriving mid-scan is parked.
local function withMounts(query, done)
    if shared.probeBusy() then
        pendingQuery = query
        return
    end
    -- A synchronous callback must not read pendingQuery.
    local immediate = true
    shared.probeMounts(false, function()
        if immediate then
            done(query)
            return
        end
        local queued = pendingQuery
        pendingQuery = nil
        done(queued or query)
    end)
    immediate = false
end

function onQuery(query)
    if not noctalia.commandExists("fzf") then
        launcher.setResults(query, { noopRow("err_no_fzf") })
        return
    end
    local dir = shared.dataDir()
    if dir == nil then
        launcher.setResults(query, { noopRow("err_index") })
        return
    end
    -- Re-read the persisted settings on every query.
    shared.scope = shared.readScope(dir)
    shared.whole = shared.readWhole(dir)
    shared.folders = shared.readFolders(dir)
    shared.ranking = shared.readRanking(dir)
    withMounts(query, function(current)
        shared.roots = shared.computeRoots()
        -- How to read the index currently on disk.
        shared.indexRoots = shared.indexRootsOf(dir) or shared.roots
        shared.absoluteRecords = #shared.indexRoots > 1
        if shared.cacheFresh(dir) and not forceBuild then
            staleIndex = false
            runQuery(current)
            return
        end
        -- A missing or stale index is rebuilt for the search folder or when the rebuild row asked for it.
        if forceBuild or shared.autoIndexAllowed() then
            forceBuild = false
            staleIndex = false
            buildIndex(current)
            return
        end
        staleIndex = true
        if noctalia.fileExists(dir .. "/list-" .. shared.cacheTag()) then
            runQuery(current)
        else
            launcher.setResults(current, { noopRow("launcher.index_missing"), reindexRow(), scopeRow() })
        end
    end)
end

function onActivate(id)
    if id == "scope" then
        local dir = shared.dataDir()
        if dir == nil then
            return
        end
        shared.scope = shared.NEXT_SCOPE[shared.scope] or shared.DEFAULT_SCOPE
        shared.writeScope(dir, shared.scope)
        shared.mountsAt = 0
        launcher.setQuery("")
        return
    end
    if id == "reindex" then
        forceBuild = true
        shared.mountsAt = 0
        launcher.setQuery("")
        onQuery("")
        return
    end
    local rel = id:match("^open:(.+)$")
    if rel == nil then
        return
    end
    local path = shared.absolutePath(rel)
    if path == nil then
        noctalia.log("file-search: refusing unsafe index record: " .. rel)
        noctalia.notify(shared.tr("title"), shared.tr("err_bad_record"))
        return
    end
    shared.openPath(path)
end

shared.probeFzfScheme()
