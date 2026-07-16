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

local CACHE_SH = 'CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia/file-search.list"'

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

local function cachePath()
    local base = noctalia.getenv("XDG_CACHE_HOME")
    if base == nil or base == "" then
        base = (noctalia.getenv("HOME") or "/tmp") .. "/.cache"
    end
    return base .. "/noctalia/file-search.list"
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

local function noopRow(titleKey)
    return { id = "noop", title = tr(titleKey), glyph = "info-circle" }
end

local function buildIndex(query)
    if indexing then
        pendingQuery = query
        return
    end
    indexing = true
    pendingQuery = query

    local prune = ""
    local names = {}
    for _, name in ipairs(excludeNames()) do
        table.insert(names, "-name " .. shellQuote(name))
    end
    if #names > 0 then
        prune = "\\( " .. table.concat(names, " -o ") .. " \\) -prune -o "
    end
    local cmd = CACHE_SH
        .. '\nmkdir -p "$(dirname "$CACHE")"\n'
        .. "find " .. shellQuote(searchRoot()) .. " -mindepth 1 " .. prune
        .. "-type d -printf '%P/\\n' -o -printf '%P\\n' > \"$CACHE\" 2>/dev/null\n"
        .. 'wc -l >/dev/null < "$CACHE"'

    launcher.setResults(query, { noopRow("launcher.indexing") })
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        local queued = pendingQuery
        pendingQuery = nil
        if result.exitCode == 0 and not result.timedOut then
            runQuery(queued or query)
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
    searching = true
    local text = trim(query)
    local cmd
    if text == "" then
        cmd = CACHE_SH .. '\nhead -n ' .. MAX_RESULTS .. ' "$CACHE" 2>/dev/null'
    else
        cmd = CACHE_SH .. "\nfzf --filter=" .. shellQuote(text)
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
    if not noctalia.fileExists(cachePath()) then
        buildIndex(query)
        return
    end
    runQuery(query)
end

function onActivate(id)
    if id == "reindex" then
        -- Drop the cache so the next keystroke rebuilds against fresh disk state.
        noctalia.runAsync(CACHE_SH .. '\nrm -f "$CACHE"', function(_result)
            noctalia.notify(tr("title"), tr("launcher.reindex_done"))
        end)
        return
    end
    local rel = id:match("^open:(.+)$")
    if rel == nil then
        return
    end
    local path = searchRoot()
    if path ~= "/" then
        path = path .. "/"
    end
    path = path .. rel:gsub("/+$", "")
    noctalia.runAsync("xdg-open " .. shellQuote(path) .. " >/dev/null 2>&1")
end
