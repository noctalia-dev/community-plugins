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
-- The index itself, the fingerprint that identifies it and every helper around
-- both live in shared.luau, required below (plugin_api >= 22) and shared with
-- panel.luau: whichever entry built the index, the other recognizes it.

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

-- Row that cycles the scope, offered whenever the query is empty (and whenever
-- there is nothing to search), so the launcher is never a dead end when the
-- scope points at disks that are not plugged in.
local function scopeRow()
    return {
        id = "scope",
        title = shared.tr("launcher.scope_title", { current = shared.tr("scope." .. shared.scope) }),
        subtitle = shared.tr("launcher.scope_next", { next = shared.tr("scope." .. shared.NEXT_SCOPE[shared.scope]) }),
        glyph = shared.SCOPE_GLYPHS[shared.scope],
    }
end

-- Activating this is what authorises a walk. It is always offered on an empty
-- query, and pushed to the top when the index for a disk scope is missing or
-- out of date, since nothing else will rebuild it.
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
    if #shared.roots == 0 then
        -- Scope "external" with nothing plugged in: nothing to walk, and no
        -- cache to write either. Say so, and keep the row that switches back.
        launcher.setResults(query, { noopRow("no_external"), scopeRow() })
        return
    end
    indexing = true
    pendingQuery = query

    local key = shared.indexKey()
    -- The format this walk writes follows the roots it is about to visit.
    local builtRoots = shared.roots
    local absolute = #builtRoots > 1
    local builtScope = shared.scope
    -- The same walk the panel runs, from the same builder: the index and the
    -- count sidecar it leaves behind are readable by either entry. Its stdout
    -- (count and elapsed milliseconds) is only of use to the panel's footer,
    -- so it is ignored here.
    local cmd = shared.buildCommand(dir, key, absolute)

    launcher.setResults(query, { noopRow("launcher.indexing") })
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        local queued = pendingQuery
        pendingQuery = nil
        if result.exitCode == 0 and not result.timedOut then
            if builtScope ~= shared.scope then
                -- The scope row was activated while the walk ran: this index
                -- is not the one the launcher is showing. Start the query over
                -- so roots, records and freshness are derived for the scope
                -- that is actually current.
                onQuery(queued or query)
            else
                -- The file on disk is the one this walk just wrote: read it
                -- the way it was written.
                shared.indexRoots = builtRoots
                shared.absoluteRecords = absolute
                if shared.indexKey() == key then
                    staleIndex = false
                    runQuery(queued or query)
                elseif shared.autoIndexAllowed() then
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
    if #shared.roots == 0 then
        -- Scope "external" with nothing plugged in: say so, and keep the row
        -- that switches back within reach.
        launcher.setResults(query, { noopRow("no_external"), scopeRow() })
        return
    end
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
--
-- The scan itself is shared.probeMounts; what stays here is the query echo the
-- launcher runs on. A keystroke arriving while a scan is in flight parks its
-- query instead of starting a second scan, and the continuation below picks up
-- whichever query is the latest by the time lsblk answers.
local function withMounts(query, done)
    if shared.probeBusy() then
        pendingQuery = query
        return
    end
    -- shared.probeMounts calls back synchronously when it has nothing to scan
    -- (the search-folder scope, or a scan still inside MOUNT_TTL). Nothing can
    -- have been parked in between, so `pendingQuery` is not this call's to
    -- read: it may belong to a build or a search still in flight, and taking it
    -- here would hand that older text back and lose the one just typed.
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
    -- Re-read on every query: the panel may have cycled the scope or the
    -- ranking since the last keystroke, and both files are a single word.
    shared.scope = shared.readScope(dir)
    shared.ranking = shared.readRanking(dir)
    withMounts(query, function(current)
        shared.roots = shared.computeRoots()
        -- How to read what is on disk right now; a walk below overwrites both.
        shared.indexRoots = shared.indexRootsOf(dir) or shared.roots
        shared.absoluteRecords = #shared.indexRoots > 1
        if shared.cacheFresh(dir) then
            staleIndex = false
            runQuery(current)
            return
        end
        -- A missing or stale index (no meta, or built with a different scope,
        -- root set or exclusions) is rebuilt before searching — but only for
        -- the search folder, or when the rebuild row asked for it. Records of
        -- a vanished root are not joined to a new one either way: they are
        -- validated against the current roots when activated.
        if forceBuild or shared.autoIndexAllowed() then
            forceBuild = false
            staleIndex = false
            buildIndex(current)
            return
        end
        staleIndex = true
        if noctalia.fileExists(dir .. "/list-" .. shared.scope) then
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
        shared.mountsAt = 0 -- the new scope may need a mount list this one never took
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
        shared.mountsAt = 0 -- rescan: a disk may have been plugged in since
        launcher.setQuery("")
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
