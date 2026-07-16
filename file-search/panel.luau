--!nonstrict
-- file-search — fuzzy search panel, fzf as the matching subsystem.
--
-- On open the search folder is walked once with `find` into a cache file
-- (excluded directory names are pruned, hidden entries too unless enabled);
-- after that every keystroke runs `fzf --filter=<query>` over the cache, so
-- typing stays responsive even on large trees. Results update live; picking
-- one opens it with the system MIME association (xdg-open) — directories
-- open in the file manager. Enter opens the top match.
--
-- The index is rebuilt when the panel opens with changed settings, or on
-- demand via the refresh button. The bar widget mirrors the panel's open
-- state through the shared "file_search_open" state key.

local CACHE_SH = 'CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia/file-search.list"'

local query = ""
local results = {}      -- relative paths; directories keep a trailing "/"
local total = nil       -- entries in the index, shown in the footer
local indexing = false
local searching = false
local errMsg = nil
local fzfMissing = false
local inputRev = 0      -- bumped to reseed the query input on open
local indexedKey = nil  -- settings fingerprint of the cache on disk

local render
local runSearch
local buildIndex

-- Per-row callbacks need distinct global names; the reconciler dispatches
-- callbacks by name only. getfenv() is the script environment lua_getglobal
-- reads from, so assigning into it defines the callback the host will find.
local env = getfenv()
local function rowCallback(prefix, index, fn)
    local name = prefix .. "_" .. index
    env[name] = fn
    return name
end

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

local function indexKey()
    return searchRoot() .. "\n" .. table.concat(excludeNames(), "\n")
end

buildIndex = function()
    if fzfMissing or indexing then
        return
    end
    indexing = true
    errMsg = nil
    local key = indexKey()

    local prune = ""
    local names = {}
    for _, name in ipairs(excludeNames()) do
        table.insert(names, "-name " .. shellQuote(name))
    end
    if #names > 0 then
        prune = "\\( " .. table.concat(names, " -o ") .. " \\) -prune -o "
    end
    -- %P prints paths relative to the root; the trailing '/' marks
    -- directories so rows get the right glyph. Exit status is wc's, so
    -- permission errors inside the tree don't fail the build.
    local cmd = CACHE_SH
        .. '\nmkdir -p "$(dirname "$CACHE")"\n'
        .. "find " .. shellQuote(searchRoot()) .. " -mindepth 1 " .. prune
        .. "-type d -printf '%P/\\n' -o -printf '%P\\n' > \"$CACHE\" 2>/dev/null\n"
        .. 'wc -l < "$CACHE"'

    render()
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        if result.exitCode == 0 and not result.timedOut then
            indexedKey = key
            total = tonumber(trim(result.stdout or "")) or 0
            if indexKey() ~= key then
                buildIndex() -- settings changed while the walk was running
            else
                runSearch()
            end
        else
            indexedKey = nil
            errMsg = tr("err_index")
        end
        render()
    end, 180000)
    if not ok then
        indexing = false
        errMsg = tr("err_spawn")
        render()
    end
end

runSearch = function()
    if fzfMissing or indexing or searching or indexedKey == nil then
        return
    end
    searching = true
    local q = query
    local limit = maxResults()
    local cmd
    if trim(q) == "" then
        cmd = CACHE_SH .. '\nhead -n ' .. limit .. ' "$CACHE" 2>/dev/null'
    else
        -- head closes the pipe early; the pipeline status stays head's (0).
        cmd = CACHE_SH .. "\nfzf --filter=" .. shellQuote(q)
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

local function openEntry(rel)
    local path = searchRoot()
    if path ~= "/" then
        path = path .. "/"
    end
    path = path .. rel:gsub("/+$", "")
    noctalia.runAsync("xdg-open " .. shellQuote(path) .. " >/dev/null 2>&1")
    panel.close()
end

local function resultRow(rel, index)
    local isDir = rel:sub(-1) == "/"
    return ui.button({
        key = "hit-" .. index,
        glyph = isDir and "folder" or "file",
        text = rel,
        variant = "ghost",
        contentAlign = "start",
        onClick = rowCallback("openHit", index, function()
            openEntry(rel)
        end),
    })
end

local function statusFooter()
    if indexing then
        return ui.label({ text = tr("status_indexing", { path = searchRoot() }), fontSize = 11, color = "secondary" })
    end
    local shown = #results
    return ui.label({
        text = tr("counts", { shown = shown, total = total or 0 }),
        fontSize = 11,
        color = "on_surface_variant",
    })
end

render = function()
    local children = {
        ui.row({ gap = 6, align = "center" }, {
            ui.label({
                text = tr("title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("tip_refresh"), onClick = "onRefreshIndex" }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = tr("tip_close"), onClick = "onClosePanel" }),
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

    if fzfMissing then
        table.insert(children, ui.label({ text = tr("err_no_fzf"), color = "error" }))
    elseif errMsg ~= nil then
        table.insert(children, ui.label({ text = errMsg, color = "error" }))
    else
        if #results == 0 and not indexing and trim(query) ~= "" then
            table.insert(children, ui.label({
                text = tr("no_results", { query = query }),
                color = "on_surface_variant",
                flexGrow = 1,
            }))
        else
            local rows = {}
            for index, rel in ipairs(results) do
                table.insert(rows, resultRow(rel, index))
            end
            table.insert(children, ui.scroll({ flexGrow = 1, gap = 2 }, rows))
        end
        table.insert(children, statusFooter())
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

function onOpen(_context)
    fzfMissing = not noctalia.commandExists("fzf")
    query = ""
    results = {}
    inputRev += 1
    noctalia.state.set("file_search_open", true)
    if not fzfMissing then
        if indexedKey ~= indexKey() then
            buildIndex()
        else
            runSearch()
        end
    end
    render()
end

function onClose()
    noctalia.state.set("file_search_open", false)
end

function onConfigChanged()
    if fzfMissing or indexing then
        return
    end
    if indexedKey ~= indexKey() then
        buildIndex()
    else
        runSearch()
    end
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

function onRefreshIndex()
    indexedKey = nil
    buildIndex()
end

function onClosePanel()
    panel.close()
end
