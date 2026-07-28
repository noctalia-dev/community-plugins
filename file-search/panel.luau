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

local query = ""
local results = {}      -- relative paths; directories keep a trailing "/"
local total = nil       -- entries in the index, shown in the footer
local indexing = false
local searching = false
local errMsg = nil
local fzfMissing = false
local inputRev = 0      -- bumped to reseed the query input on open
local haveIndex = false -- the cache on disk matches the current settings

local render
local runSearch
local buildIndex

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

-- The cache on disk is current when its fingerprint matches the settings,
-- whether the panel or the launcher built it.
local function cacheFresh(dir)
    return noctalia.readFile(dir .. "/index.meta") == indexKey()
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

-- Count the cache the panel is about to search. buildIndex records the total
-- as a side effect of building, but a panel opening on a cache that is already
-- fresh -- the common case, and the one the launcher leaves behind -- never
-- runs it, so the footer used to report "0 indexed" for a perfectly good
-- index. Counted with wc rather than readFile: the list can hold hundreds of
-- thousands of paths and none of them are needed here, only how many.
local function readTotal(dir)
    local cmd = cacheSh(dir) .. '\nwc -l < "$CACHE" 2>/dev/null'
    noctalia.runAsync(cmd, function(result)
        if result.exitCode == 0 and not result.timedOut then
            total = tonumber(trim(result.stdout or "")) or 0
            render()
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
    indexing = true
    errMsg = nil
    local key = indexKey()

    -- Names containing a newline would each forge extra one-per-fragment
    -- records (a crafted name can smuggle '..' lines into the index), so
    -- they are pruned unconditionally, before the user's exclusions.
    local names = { "-name " .. shellQuote("*\n*") }
    for _, name in ipairs(excludeNames()) do
        table.insert(names, "-name " .. shellQuote(name))
    end
    local prune = "\\( " .. table.concat(names, " -o ") .. " \\) -prune -o "
    -- %P prints paths relative to the root; the trailing '/' marks
    -- directories so rows get the right glyph. find's own exit status is
    -- ignored, so permission errors inside the tree don't fail the build.
    -- Cache and fingerprint are written to mktemp-created private files and
    -- renamed into place: rename replaces a planted symlink at the
    -- destination instead of following it. The host guarantees $CACHE_DIR
    -- exists (created by pluginDataDir above).
    local cmd = cacheSh(dir)
        .. '\nTMP=$(mktemp "$CACHE_DIR/index.list.XXXXXX") || exit 1\n'
        .. "find " .. shellQuote(searchRoot()) .. " -mindepth 1 " .. prune
        .. "-type d -printf '%P/\\n' -o -printf '%P\\n' > \"$TMP\" 2>/dev/null\n"
        .. 'mv -f "$TMP" "$CACHE" || exit 1\n'
        .. 'TMPM=$(mktemp "$CACHE_DIR/index.meta.XXXXXX") || exit 1\n'
        .. "printf '%s' " .. shellQuote(key) .. ' > "$TMPM"\n'
        .. 'mv -f "$TMPM" "$META" || exit 1\n'
        .. 'wc -l < "$CACHE"'

    render()
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        if result.exitCode == 0 and not result.timedOut then
            haveIndex = true
            total = tonumber(trim(result.stdout or "")) or 0
            if indexKey() ~= key then
                buildIndex() -- settings changed while the walk was running
            else
                runSearch()
            end
        else
            haveIndex = false
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
        cmd = cacheSh(dir) .. "\nfzf --filter=" .. shellQuote(q)
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

-- An index record joined to the search root, or nil when the record could
-- resolve outside it. Only ever called from the two callbacks that act on a
-- row — never from render: searchRoot() costs a getConfig plus an expandPath
-- and safeRel walks every path component, and paying that per row per frame is
-- what gets a script callback killed for exceeding its CPU budget.
local function absolutePath(rel)
    if not safeRel(rel) then
        return nil
    end
    local root = searchRoot()
    -- A directory keeps its trailing "/" in the index but not in a path meant
    -- for xdg-open or for pasting into a shell.
    local trimmed = rel:gsub("/+$", "")
    if root == "/" then
        return root .. trimmed
    end
    return root .. "/" .. trimmed
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

-- Right click copies the absolute path instead of opening it, and leaves the
-- panel up so several rows can be picked off in a row. Right rather than
-- middle because a ui.button never receives the middle button: it accepts
-- BTN_LEFT, plus BTN_RIGHT only once an onRightClick is attached, and no node
-- in the declarative UI exposes a middle-click callback at all.
local function copyEntry(rel)
    local path = absolutePath(rel)
    if path == nil then
        rejectRecord(rel)
        return
    end
    noctalia.copyToClipboard(path, "text/plain")
    noctalia.notify(tr("title"), tr("copied_entry"))
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
        onRightClick = function()
            copyEntry(rel)
        end,
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
            ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("tip_settings"), onClick = "onOpenSettings" }),
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
        local dir = dataDir()
        if dir == nil then
            errMsg = tr("err_index")
        else
            haveIndex = cacheFresh(dir)
            if not haveIndex then
                buildIndex()
            else
                -- buildIndex would have set the total; reusing a cache has to
                -- go and count it.
                readTotal(dir)
                runSearch()
            end
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
    local dir = dataDir()
    if dir == nil then
        return
    end
    haveIndex = cacheFresh(dir)
    if not haveIndex then
        buildIndex()
    else
        readTotal(dir)
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
    haveIndex = false
    buildIndex()
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
