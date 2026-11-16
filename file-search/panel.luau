--!nonstrict
-- file-search — fuzzy search panel, fzf as the matching subsystem.
--
-- Walks the active roots with `find` into a cache file, then runs
-- `fzf --filter=<query>` over it on every keystroke. A click or Enter opens the
-- result with xdg-open; right-click raises a context menu (open, reveal, copy
-- path, copy name). Up/Down move the selection. Tabs: Search (this file) and
-- Space (space.luau); the usage donut comes from usage.luau.
--
-- The roots follow the mode (home / home + folders / system) and the disks
-- toggle, persisted in the plugin data directory and shared with the launcher.
-- Shared state key: "file_search_open" (the bar widget mirrors the open state).

-- Max characters of a result path shown on one row; longer paths lose their middle.
local PATH_MAX_CHARS = 56
local ELLIPSIS = "…"

-- The search core, shared with launcher.luau and the bar widget.
local shared = require("./shared.luau")

-- The usage donut under the results. Panel-only, so it is not in shared.luau:
-- the bar widget and the launcher have no chart to draw.
local usage = require("./usage.luau")

-- The Space tab's body.
local space = require("./space.luau")
space.onSearchHere = function(path) onSearchHere(path) end

-- Which tab is showing: "search" | "space". Reset to search on every open.
local activeTab = "search"

-- The Space tab can be turned off in the settings (nil = on).
local function spaceOn()
    return noctalia.getConfig("space_enabled") ~= false
end

-- Plugin version read from plugin.toml; empty when unreadable.
local pluginVersion = (function()
    local text = noctalia.readFile("plugin.toml")
    if type(text) ~= "string" then
        return ""
    end
    return ("\n" .. text):match('\nversion%s*=%s*"([^"]+)"') or ""
end)()

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
local indexState = "fresh" -- "fresh" | "stale" (usable, out of date) | "missing"
local reloading = false -- a refresh pass is in flight
local reloadQueued = false
local queuedForce = false
local queuedBuild = false
local totals = {}       -- scope → { count, size, mtime }: see readTotal
local showUsage = true  -- the usage donut, toggled from the header
-- Folder the results are restricted to, picked from the chart's legend, or nil.
local usageFilter = nil
-- The "add a folder" row under the query input shows its path input.
local addingRoot = false
local rootRev = 0 -- bumped to reseed that input

-- Keyboard selection: Up/Down move it, Enter opens it.
local sel = 1 -- index into `results`
-- Held arrow keys repeat from the frame tick; the list does not wrap on repeat.
local KEY_STEPS = { up = -1, down = 1 }
local REPEAT_DELAY_MS = 350
local REPEAT_STEP_MS = 60
local heldStep = 0
local repeatInMs = 0

local render
local runSearch
local buildIndex
local applyState

-- Braille spinner in the status footer during a from-scratch index build
-- (only while there are no results to show).
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_STEP_MS = 90
local spinnerIndex = 1
local spinnerAccumMs = 0
local spinnerTicking = false

-- The frame tick has three users: the spinner, a held arrow key and the
-- Space tab's scan engine (space.step).
local function syncFrameTick()
    panel.setNeedsFrameTick(spinnerTicking or heldStep ~= 0 or (spaceOn() and space.needsTick()))
end

local function setSpinnerTicking(on)
    if on == spinnerTicking then
        return
    end
    spinnerTicking = on
    syncFrameTick()
    if not on then
        spinnerAccumMs = 0
        spinnerIndex = 1
    end
end

-- Whether the usage donut is shown, persisted next to the scope.
local function readShowUsage(dir)
    return shared.trim(noctalia.readFile(dir .. "/usage-chart") or "") ~= "0"
end

local function writeShowUsage(dir, value)
    local ok, err = noctalia.writeFile(dir .. "/usage-chart", value and "1" or "0")
    if not ok then
        noctalia.log("file-search: could not persist the usage chart toggle: " .. tostring(err))
    end
end

local function maxResults()
    return math.max(10, math.min(200, tonumber(noctalia.getConfig("max_results")) or 50))
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

-- Shorten an over-long path by dropping its middle, keeping the root and the name:
--   .local/share/flatpak/repo/tmp/cache/summaries/dolphin.idx.sig
--   → .local/share/flatpak/repo/tmp/cache/…dolphin.idx.sig
local function elidePath(rel)
    -- Byte length is never below the code-point count, so a string short in
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
    -- Retreat to the last separator so the head ends on a whole directory.
    local atSeparator = headPart:match("^(.*/)[^/]*$")
    if atSeparator ~= nil and atSeparator ~= "" then
        headPart = atSeparator
    end
    return headPart .. ELLIPSIS .. base
end

-- elidePath results keyed by record; cleared wholesale past ELIDE_CACHE_MAX.
local elideCache = {}
local elideCacheCount = 0
local ELIDE_CACHE_MAX = 4000

local function elidePathCached(rel)
    local cached = elideCache[rel]
    if cached ~= nil then
        return cached
    end
    if elideCacheCount >= ELIDE_CACHE_MAX then
        elideCache = {}
        elideCacheCount = 0
    end
    local shown = elidePath(rel)
    elideCache[rel] = shown
    elideCacheCount = elideCacheCount + 1
    return shown
end

-- Count the cache the panel is about to search: from the count-<scope> sidecar
-- (count and build millis), else `wc -l` memoized per scope by size and mtime.
local function readTotal(dir)
    local target = shared.cacheTag()
    buildMs = nil -- belongs to the index of this scope, if that one recorded it
    local recorded = noctalia.readFile(dir .. "/count-" .. target)
    if recorded ~= nil then
        -- A sidecar without the elapsed millis holds the count alone.
        local count, elapsed = shared.trim(recorded):match("^(%d+)%s+(%d+)$")
        total = tonumber(count or shared.trim(recorded)) or 0
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
    local cmd = shared.cacheSh(dir) .. '\nwc -l < "$CACHE" 2>/dev/null'
    noctalia.runAsync(cmd, function(result)
        if result.exitCode == 0 and not result.timedOut then
            local count = tonumber(shared.trim(result.stdout or "")) or 0
            totals[target] = { count = count, size = info.size, mtime = info.mtime }
            if shared.cacheTag() == target then
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
    local dir = shared.dataDir()
    if dir == nil then
        errMsg = shared.tr("err_index")
        render()
        return
    end
    indexing = true
    errMsg = nil
    local key = shared.indexKey()
    local builtRoots = shared.roots
    local absolute = #builtRoots > 1
    local builtScope = shared.cacheTag()

    local cmd = shared.buildCommand(dir, key, absolute)

    render()
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        if result.exitCode == 0 and not result.timedOut then
            totals[builtScope] = nil -- size/mtime moved; recount lazily
            if builtScope ~= shared.cacheTag() then
                -- The scope was cycled while the walk ran: derive the state again.
                applyState()
            else
                -- The file on disk is the one this walk just wrote.
                shared.indexRoots = builtRoots
                shared.absoluteRecords = absolute
                haveIndex = true
                local count, elapsed = shared.trim(result.stdout or ""):match("^(%d+)%s+(%d+)$")
                total = tonumber(count) or 0
                buildMs = tonumber(elapsed)
                if shared.indexKey() == key then
                    indexState = "fresh"
                    runSearch()
                elseif shared.autoIndexAllowed() then
                    -- Roots or exclusions moved during the walk: walk again.
                    buildIndex()
                else
                    -- Disk scope: just mark the index out of date.
                    indexState = "stale"
                    runSearch()
                end
            end
        else
            haveIndex = false
            errMsg = shared.tr("err_index")
        end
        render()
    end, shared.buildTimeout())
    if not ok then
        indexing = false
        errMsg = shared.tr("err_spawn")
        render()
    end
end

-- The fzf term restricting the results to one direct child of the root
-- (exact prefix, e.g. '^src/').
local function folderToken(name)
    -- Extra folders mean absolute records, so the token carries the search folder.
    local full = shared.absoluteRecords and (shared.searchRoot() .. "/" .. name) or name
    return "^" .. full:gsub(" ", "\\ ") .. "/"
end

-- The restriction and what the user typed, ANDed as fzf does for
-- space-separated terms.
local function effectiveQuery()
    if usageFilter == nil then
        return query
    end
    local typed = shared.trim(query)
    if typed == "" then
        return folderToken(usageFilter)
    end
    return folderToken(usageFilter) .. " " .. typed
end

runSearch = function()
    if fzfMissing or indexing or searching or not haveIndex then
        return
    end
    local dir = shared.dataDir()
    if dir == nil then
        return
    end
    searching = true
    local q = effectiveQuery()
    local ok = noctalia.runAsync(shared.searchCommand(dir, q, maxResults()), function(result)
        searching = false
        if not result.timedOut then
            results = {}
            for line in (result.stdout or ""):gmatch("[^\n]+") do
                table.insert(results, line)
            end
            sel = 1
        end
        -- The query moved on while this search ran: search again.
        if effectiveQuery() ~= q then
            runSearch()
        end
        render()
    end, 15000)
    if not ok then
        searching = false
    end
end

local function rejectRecord(rel)
    noctalia.log("file-search: refusing unsafe index record: " .. rel)
    noctalia.notify(shared.tr("title"), shared.tr("err_bad_record"))
end

local function openEntry(rel)
    local path = shared.absolutePath(rel)
    if path == nil then
        rejectRecord(rel)
        return
    end
    shared.openPath(path)
    panel.close()
end

-- Copy leaves the panel up so several rows can be picked off in a row.
local function copyEntry(rel)
    local path = shared.absolutePath(rel)
    if path == nil then
        rejectRecord(rel)
        return
    end
    noctalia.copyToClipboard(path, "text/plain")
    noctalia.notify(shared.tr("title"), shared.tr("copied_entry"))
end

-- Just the last path segment. absolutePath has already dropped a directory
-- record's trailing "/", so the match needs no help.
local function copyName(rel)
    local path = shared.absolutePath(rel)
    if path == nil then
        rejectRecord(rel)
        return
    end
    noctalia.copyToClipboard(path:match("[^/]+$") or path, "text/plain")
    noctalia.notify(shared.tr("title"), shared.tr("copied_name"))
end

-- Show the entry in the system file manager (see shared.revealPath).
local function revealEntry(rel)
    local path = shared.absolutePath(rel)
    if path == nil then
        rejectRecord(rel)
        return
    end
    shared.revealPath(path)
end

-- The result row's right-click menu (plugin_api >= 28). `context` carries the
-- record; every action re-validates it through absolutePath.
local function openResultMenu(rel)
    panel.openContextMenu({
        onActivate = "onResultMenu",
        context = rel,
        items = {
            { kind = "header", label = elidePathCached(rel) },
            { id = "open", label = shared.tr("menu.open") },
            { id = "reveal", label = shared.tr("menu.reveal") },
            { kind = "separator" },
            { id = "copy_path", label = shared.tr("menu.copy_path") },
            { id = "copy_name", label = shared.tr("menu.copy_name") },
        },
    })
end

local function resultRow(rel, index)
    local isDir = rel:sub(-1) == "/"
    local shown = elidePathCached(rel)
    return ui.button({
        key = "hit-" .. index,
        glyph = isDir and "folder" or "file",
        text = shown,
        variant = "ghost",
        contentAlign = "start",
        selected = index == sel,
        onClick = function()
            openEntry(rel) -- always the full record, never the elided label
        end,
        onRightClick = function()
            openResultMenu(rel)
        end,
    })
end

-- Free-space summary across the mounts of the current scope, memoized for
-- FREE_TTL_MS and keyed on scope plus mount list.
local FREE_TTL_MS = 5000
local freeCacheKey = nil
local freeCacheValue = nil
local freeCacheAtMs = 0

local function diskFreeSummary()
    if shared.scope == "folder" or #shared.mounts == 0 then
        return nil
    end
    local key = shared.scope .. "\0" .. table.concat(shared.mounts, "\0")
    local nowMs = noctalia.nowMs()
    if key == freeCacheKey and nowMs - freeCacheAtMs < FREE_TTL_MS then
        return freeCacheValue
    end
    local freeBytes = 0
    local sampled = 0
    for _, mount in ipairs(shared.mounts) do
        local stats = noctalia.diskStats(mount)
        if stats ~= nil then
            freeBytes += stats.freeBytes
            sampled += 1
        end
    end
    freeCacheKey = key
    freeCacheAtMs = nowMs
    freeCacheValue = sampled > 0
        and shared.tr("tip_scope_free", { free = shared.formatBytes(freeBytes), count = sampled })
        or nil
    return freeCacheValue
end

-- ── usage donut ──────────────────────────────────────────────────────────────

-- The chart measures the search folder only: not available on a whole-system index.
local function usageAvailable()
    return not shared.whole
end

local USAGE_COLUMN_WIDTH = 270
local USAGE_SIZE = 108
local USAGE_THICKNESS = 16
local USAGE_LABEL_MAX = 16
local USAGE_ROW_HEIGHT = 20

-- Measure the current search root and redraw when it lands. Never on a disk scope.
local function requestUsage(force)
    if not showUsage or not usageAvailable() then
        return
    end
    local root = shared.searchRoot()
    local dataDir = shared.dataDir()
    usage.scan(root, dataDir, force, function()
        if usage.state == "ready" then
            usage.writeSvg(
                dataDir, USAGE_SIZE, USAGE_THICKNESS,
                shared.formatBytes(usage.total),
                shared.tr("usage_center")
            )
        end
        render()
    end)
end

-- Restrict the results to a folder from the chart, or lift it by picking it again.
local function pickUsageFolder(name)
    if usageFilter == name then
        usageFilter = nil
    else
        usageFilter = name
    end
    render()
    runSearch()
end

-- One legend row: swatch, folder, size and share. Only "folder" slices are clickable.
local function usageLegendRow(slice, index)
    -- Left whole when utf8.len is nil (invalid UTF-8).
    local label = slice.label
    local labelLen = utf8.len(label)
    if labelLen ~= nil and labelLen > USAGE_LABEL_MAX then
        label = headChars(label, USAGE_LABEL_MAX - 1) .. ELLIPSIS
    end
    local share = usage.total > 0 and (slice.bytes / usage.total * 100) or 0
    local name
    if slice.kind == "folder" then
        local active = usageFilter == slice.label
        name = ui.button({
            key = "name-folder",
            text = label,
            fontSize = 11,
            variant = "ghost",
            contentAlign = "start",
            selected = active,
            flexGrow = 1,
            height = USAGE_ROW_HEIGHT,
            tooltip = shared.tr(active and "tip_usage_folder_clear" or "tip_usage_folder", {
                folder = slice.label,
            }),
            onClick = function()
                pickUsageFolder(slice.label)
            end,
        })
    else
        name = ui.label({ key = "name-plain", text = label, fontSize = 11, color = "on_surface_variant", flexGrow = 1 })
    end
    return ui.row({ key = "ulegend-" .. index, gap = 6, align = "center", height = USAGE_ROW_HEIGHT }, {
        ui.box({ key = "swatch", fill = slice.color, radius = 2, width = 9, height = 9 }),
        name,
        -- One label, not two: a label honours maxWidth but not width, so a
        ui.label({
            key = "size",
            text = shared.tr("usage_amount", {
                size = shared.formatBytes(slice.bytes),
                share = string.format("%.0f", share),
            }),
            fontSize = 11,
            color = "on_surface_variant",
        }),
    })
end

-- Adds a folder to the search. The path is typed: a panel has no folder
-- picker. Accepted only if it is an existing absolute directory.
function onAddRoot(value)
    local path = noctalia.expandPath(shared.trim(value or "")):gsub("/+$", "")
    if not shared.validRoot(path) then
        noctalia.notifyError(shared.tr("title"), shared.tr("root_invalid"))
        return
    end
    if not noctalia.fileExists(path) then
        noctalia.notifyError(shared.tr("title"), shared.tr("root_missing", { path = path }))
        return
    end
    local list = shared.extraRoots()
    for _, root in ipairs(list) do
        if root == path then
            addingRoot = false
            render()
            return
        end
    end
    table.insert(list, path)
    shared.writeExtraRoots(list)
    addingRoot = false
    rootRev += 1
    -- The index covers a new set of roots: walk it now, the user asked.
    requestReload(false, true)
    requestUsage(false)
end

local function removeRoot(path)
    local list = {}
    for _, root in ipairs(shared.extraRoots()) do
        if root ~= path then
            table.insert(list, root)
        end
    end
    shared.writeExtraRoots(list)
    requestReload(false, true)
    requestUsage(false)
end

-- Folders searched next to the search folder, under the query input: one row
-- per added folder (✕ drops it) and the "add" row. Only in the "home +
-- folders" mode, the one where the list has an effect.
local function extrasSection()
    if activeTab ~= "search" or shared.whole or not shared.folders then
        return nil
    end
    local rows = {}
    for _, root in ipairs(shared.extraRoots()) do
        table.insert(rows, ui.row({ key = "extra-" .. root, gap = 4, align = "center" }, {
            ui.glyph({ key = "extra-glyph", name = "folder", size = 12, color = "primary" }),
            ui.label({ key = "extra-text", text = root, fontSize = 11, color = "on_surface", flexGrow = 1 }),
            ui.button({ key = "extra-x", glyph = "close", variant = "ghost", height = 20,
                tooltip = shared.tr("tip_root_remove", { folder = root }),
                onClick = function() removeRoot(root) end }),
        }))
    end
    if addingRoot then
        table.insert(rows, ui.input({ key = "root-input-" .. rootRev, value = "", focus = true,
            placeholder = shared.tr("root_placeholder"), onSubmit = "onAddRoot" }))
    end
    if #rows == 0 then
        return nil
    end
    return ui.column({ key = "extras", gap = 2, align = "stretch" }, rows)
end

-- The query input with its two buttons: Search re-runs the search, and "add
-- search path" opens the path input below. That one stays on screen but is
-- disabled outside the "home + folders" mode, the only one the list applies to.
local function queryRow()
    local canAdd = shared.folders and not shared.whole
    return ui.row({ key = "query-row", gap = 6, align = "center" }, {
        ui.input({
            key = "query-" .. inputRev,
            value = query,
            focus = true,
            placeholder = shared.tr("search_placeholder"),
            onChange = "onQueryChanged",
            onSubmit = "onOpenSelected",
            flexGrow = 1,
        }),
        ui.button({ key = "search-go", glyph = "search", text = shared.tr("opt_search"),
            variant = "secondary", controlSize = "sm",
            tooltip = shared.tr("tip_search"),
            onClick = function() runSearch() end }),
        ui.button({ key = "root-add", glyph = "plus", text = shared.tr("root_add"),
            variant = addingRoot and "secondary" or "ghost", controlSize = "sm", enabled = canAdd,
            tooltip = shared.tr(canAdd and "tip_root_add" or "tip_root_add_off"),
            onClick = function() addingRoot = not addingRoot render() end }),
    })
end

-- The usage strip, or nil when it is off.
local function usageSection()
    if not showUsage or not usageAvailable() then
        return nil
    end

    local children = {}
    if usage.state == "ready" and usage.imagePath ~= nil then
        local legend = {}
        for index, slice in ipairs(usage.slices) do
            table.insert(legend, usageLegendRow(slice, index))
        end
        -- Hint that legend rows are clickable; dropped while a restriction is on.
        if usageFilter == nil then
            table.insert(legend, ui.label({
                key = "ulegend-hint",
                text = shared.tr("usage_hint"),
                fontSize = 10,
                color = "on_surface_variant",
            }))
        end
        -- Mount points are absent from the total (du -x); name them.
        if #usage.skipped > 0 then
            table.insert(legend, ui.label({
                key = "ulegend-skipped",
                text = shared.tr("usage_skipped", { names = table.concat(usage.skipped, ", ") }),
                fontSize = 10,
                color = "on_surface_variant",
            }))
        end
        table.insert(children, ui.image({
            key = "usage-img",
            path = usage.imagePath,
            width = USAGE_SIZE,
            height = USAGE_SIZE,
        }))
        table.insert(children, ui.column({ key = "usage-legend", gap = 1, flexGrow = 1 }, legend))
    else
        local text
        if usage.state == "scanning" then
            text = shared.tr("usage_scanning")
        elseif usage.state == "error" then
            text = shared.tr("usage_error", { reason = usage.errText or "?" })
        else
            text = shared.tr("usage_idle")
        end
        table.insert(children, ui.label({
            key = "usage-msg",
            text = text,
            fontSize = 11,
            color = usage.state == "error" and "error" or "on_surface_variant",
            flexGrow = 1,
        }))
    end

    return ui.column({ key = "usage", gap = 10, width = USAGE_COLUMN_WIDTH, align = "stretch" }, children)
end

-- The active folder restriction as its own strip under the query input, or nil.
local function usageFilterStrip()
    if usageFilter == nil then
        return nil
    end
    return ui.row({ key = "filter", gap = 6, align = "center" }, {
        ui.glyph({ key = "filter-glyph", name = "folder", size = 12, color = "primary" }),
        ui.label({
            key = "filter-text",
            text = shared.tr("usage_filter", { folder = usageFilter }),
            fontSize = 11,
            color = "primary",
            flexGrow = 1,
        }),
        ui.button({
            key = "filter-clear",
            glyph = "close",
            variant = "ghost",
            tooltip = shared.tr("tip_usage_filter_clear"),
            onClick = "onClearUsageFilter",
        }),
    })
end

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

-- One dim line of fzf's extended-search operators under the query input.
local function syntaxLegend()
    return ui.row({ key = "legend", gap = 6, align = "center" }, {
        ui.label({
            key = "legend-caption",
            text = shared.tr("syntax_hint_label"),
            fontSize = 10,
            color = "on_surface_variant",
        }),
        ui.label({ key = "legend-ops", text = shared.tr("syntax_hint"), fontSize = 10, color = "on_surface" }),
    })
end

-- Counts on the left, the recorded build duration of this scope's index on the right.
local function statusFooter()
    local left, tone
    if indexing then
        left = #shared.roots > 1
            and shared.tr("status_indexing_multi", { count = #shared.roots })
            or shared.tr("status_indexing", { path = shared.roots[1] or shared.searchRoot() })
        if spinnerTicking then
            left = SPINNER_FRAMES[spinnerIndex] .. "  " .. left
        end
        tone = "secondary"
    else
        left = shared.tr("counts", { shown = #results, total = total or 0 })
        if shared.scope ~= "folder" then
            left = left .. shared.tr("counts_disks", { disks = #shared.mounts })
        end
        if indexState == "stale" then
            -- Searchable, but built for a different scope or disk set.
            left = left .. shared.tr("counts_stale")
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
            text = shared.tr("build_time", { duration = formatDuration(buildMs) }),
            fontSize = 11,
            color = "on_surface_variant",
        }))
    end
    return ui.row({ key = "footer", gap = 8, align = "center" }, children)
end

-- Names the scoring scheme and switches it; generic scheme when fzf lacks --scheme.
local function rankingButton()
    local tip = shared.schemeSupported
        and shared.tr("tip_ranking", {
            current = shared.tr("ranking." .. shared.ranking),
            next = shared.tr("ranking." .. shared.NEXT_RANKING[shared.ranking]),
        })
        or shared.tr("tip_ranking_unsupported")
    return ui.button({
        key = "ranking-" .. shared.ranking,
        glyph = shared.RANKING_GLYPHS[shared.schemeSupported and shared.ranking or "default"],
        text = shared.tr("opt_ranking." .. (shared.schemeSupported and shared.ranking or "default")),
        variant = "ghost", controlSize = "sm", flexGrow = 1,
        tooltip = tip,
        onClick = "onCycleRanking",
    })
end

-- Shows and hides the usage donut. Disabled outside the folder scope, where
-- there is nothing it could measure without walking a removable disk.
local function usageButton()
    return ui.button({
        key = "usage-toggle",
        glyph = "chart-donut",
        text = shared.tr(showUsage and "opt_usage_on" or "opt_usage_off"),
        variant = showUsage and "secondary" or "ghost", controlSize = "sm", flexGrow = 1,
        enabled = usageAvailable(),
        tooltip = usageAvailable()
            and shared.tr(showUsage and "tip_usage_hide" or "tip_usage_show")
            or shared.tr("tip_usage_folder_only"),
        onClick = "onToggleUsage",
    })
end

-- The three exclusive source modes, as one row of text buttons under the input.
-- home = the search folder, folders = search folder + the added folders,
-- system = "/". The mapping to state lives in currentMode()/setMode().
local MODES = { "home", "folders", "system" }
local MODE_GLYPH = { home = "home", folders = "folders", system = "world" }

local function currentMode()
    if shared.whole then
        return "system"
    end
    return shared.folders and "folders" or "home"
end

local function setMode(mode)
    shared.whole = mode == "system"
    shared.folders = mode == "folders"
    local dir = shared.dataDir()
    if dir ~= nil then
        shared.writeWhole(dir, shared.whole)
        shared.writeFolders(dir, shared.folders)
    end
    shared.mountsAt = 0 -- the folder scope never took a mount list
    addingRoot = false
    results = {}
    total = nil
    errMsg = nil
    usageFilter = nil
    render()
    requestReload(false, false)
    requestUsage(false)
end

local function modeRow()
    local buttons = {}
    for _, mode in ipairs(MODES) do
        table.insert(buttons, ui.button({
            key = "mode-" .. mode,
            glyph = MODE_GLYPH[mode],
            text = shared.tr("opt_mode." .. mode),
            variant = currentMode() == mode and "secondary" or "ghost",
            controlSize = "sm", flexGrow = 1,
            tooltip = shared.tr("tip_mode." .. mode),
            onClick = function() setMode(mode) end,
        }))
    end
    table.insert(buttons, ui.button({
        key = "refresh",
        glyph = "refresh",
        text = shared.tr("opt_reindex"),
        variant = "ghost", controlSize = "sm", flexGrow = 1,
        tooltip = shared.tr("tip_refresh"),
        onClick = "onRefreshIndex",
    }))
    return ui.row({ key = "modes", gap = 6, align = "center" }, buttons)
end

-- Removable (USB) disks join whichever mode is on. The tooltip carries the
-- free-space summary of the mounted ones.
local function disksButton()
    local on = shared.scope == "all"
    local tooltip = shared.tr(on and "tip_disks_off" or "tip_disks_on")
    local free = diskFreeSummary()
    if free ~= nil then
        tooltip = tooltip .. "\n" .. free
    end
    return ui.button({
        key = "disks-toggle",
        glyph = "usb",
        text = shared.tr(on and "opt_disks_on" or "opt_disks_off"),
        variant = on and "secondary" or "ghost", controlSize = "sm", flexGrow = 1,
        tooltip = tooltip,
        onClick = "onToggleDisks",
    })
end

-- Move the selection by `step` rows. A fresh press wraps around the ends; a
-- repeat does not. Returns whether it moved.
local function moveSelection(step, wrap)
    local count = #results
    if count == 0 then
        return false
    end
    local target = sel + step
    if target < 1 or target > count then
        if not wrap then
            return false
        end
        target = target < 1 and count or 1
    end
    if target == sel then
        return false
    end
    sel = target
    return true
end

local function stopKeyRepeat()
    heldStep = 0
    syncFrameTick()
end

-- Tab bar under the header: Search and Space. The ids double as node keys.
local TABS = { "search", "space" }
local TAB_GLYPH = { search = "search", space = "chart-pie" }

local function setActiveTab(id)
    if id == activeTab or (id == "space" and not spaceOn()) then
        return
    end
    activeTab = id
    stopKeyRepeat()
    if id == "space" then
        space.onOpen(render)
    elseif spaceOn() then
        space.onClose() -- its scan events stop re-rendering this tab
    end
    render()
end

local function tabSelector()
    local buttons = {}
    for _, id in ipairs(TABS) do
        table.insert(buttons, ui.button({
            key = "tab-" .. id,
            glyph = TAB_GLYPH[id],
            text = shared.tr("tab_" .. id),
            variant = "ghost", controlSize = "sm", flexGrow = 1,
            selected = (activeTab == id),
            onClick = function() setActiveTab(id) end,
        }))
    end
    return ui.row({ key = "tabs", gap = 4, align = "center" }, buttons)
end

render = function()
    setSpinnerTicking(indexing and #results == 0)
    syncFrameTick() -- also follows space.needsTick(), which changes outside this file
    -- Clamp the selection to the results.
    sel = math.max(1, math.min(sel, #results))

    local headerItems = {
        ui.label({
            key = "title",
            text = shared.tr("title"),
            fontSize = 16,
            fontWeight = "bold",
            color = "on_surface",
        }),
        -- Plugin version off the manifest.
        ui.label({ key = "version", text = pluginVersion, fontSize = 10, color = "on_surface_variant" }),
        ui.spacer({ key = "gap", flexGrow = 1 }),
    }
    table.insert(headerItems, ui.button({ key = "settings", glyph = "settings", variant = "ghost", tooltip = shared.tr("tip_settings"), onClick = "onOpenSettings" }))
    table.insert(headerItems, ui.button({ key = "close", glyph = "close", variant = "ghost", tooltip = shared.tr("tip_close"), onClick = "onClosePanel" }))
    local header = ui.row({ key = "header", gap = 6, align = "center" }, headerItems)

    if activeTab == "space" and spaceOn() then
        panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
            header, tabSelector(), space.render(),
        }))
        return
    end

    local children = {
        header,
        queryRow(),
        syntaxLegend(),
        modeRow(),
        ui.row({ key = "options", gap = 6, align = "center" }, {
            usageButton(), rankingButton(), disksButton(),
        }),
    }
    local extras = extrasSection()
    if extras ~= nil then
        table.insert(children, 4, extras) -- under the syntax line (children: header, input, syntax, modes)
    end
    if spaceOn() then
        table.insert(children, 2, tabSelector())
    end

    local strip = usageFilterStrip()
    if strip ~= nil then
        table.insert(children, strip)
    end

    -- The body is one keyed column that grows; results and messages live inside it.
    local body
    if fzfMissing then
        body = ui.label({ key = "body-msg", text = shared.tr("err_no_fzf"), color = "error", flexGrow = 1 })
    elseif errMsg ~= nil then
        body = ui.label({ key = "body-msg", text = errMsg, color = "error", flexGrow = 1 })
    elseif indexState == "missing" and not indexing then
        body = ui.label({ key = "body-msg", text = shared.tr("index_missing"), color = "on_surface_variant", flexGrow = 1 })
    elseif #results == 0 and not indexing and shared.trim(query) ~= "" then
        body = ui.label({
            key = "body-msg",
            text = shared.tr("no_results", { query = query }),
            color = "on_surface_variant",
            flexGrow = 1,
        })
    else
        local rows = {}
        for index, rel in ipairs(results) do
            table.insert(rows, resultRow(rel, index))
        end
        body = ui.scroll({ key = "hits", flexGrow = 1, gap = 2, revealKey = "hit-" .. sel }, rows)
    end
    -- The chart sits to the left of the results.
    local main = { ui.column({ key = "body", flexGrow = 1, align = "stretch" }, { body }) }
    local chart = usageSection()
    if chart ~= nil then
        table.insert(main, 1, chart)
    end
    table.insert(children, ui.row({ key = "main", flexGrow = 1, gap = 16, align = "stretch" }, main))
    table.insert(children, statusFooter())

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

-- Recompute the roots from the scope and mounts, then search the cache that
-- belongs to them; walk only when autoIndexAllowed() says so.
applyState = function()
    shared.roots = shared.computeRoots()
    local dir = shared.dataDir()
    if dir == nil then
        errMsg = shared.tr("err_index")
        render()
        return
    end
    -- How to read what is on disk; a walk started below overwrites both.
    shared.indexRoots = shared.indexRootsOf(dir) or shared.roots
    shared.absoluteRecords = #shared.indexRoots > 1
    if shared.cacheFresh(dir) then
        haveIndex = true
        indexState = "fresh"
        readTotal(dir)
        runSearch()
    elseif shared.autoIndexAllowed() then
        results = {}
        total = nil
        buildIndex()
    else
        -- Out of date: search the existing index and label it.
        haveIndex = noctalia.fileExists(dir .. "/list-" .. shared.cacheTag())
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

-- The one way to refresh what the panel shows; presses during a pass collapse
-- into one queued pass.
--
-- force: rescan the disks even if the last scan is young.
-- build: walk the tree when the probe comes back (refresh button only).
requestReload = function(force, build)
    if reloading then
        reloadQueued = true
        queuedForce = queuedForce or force
        queuedBuild = queuedBuild or build
        return
    end
    reloading = true
    shared.probeMounts(force, function()
        reloading = false
        if build then
            shared.roots = shared.computeRoots()
            local dir = shared.dataDir()
            if dir ~= nil then
                shared.indexRoots = shared.indexRootsOf(dir) or shared.roots
                shared.absoluteRecords = #shared.indexRoots > 1
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
    activeTab = "search"
    query = ""
    results = {}
    errMsg = nil
    usageFilter = nil
    addingRoot = false
    -- Nothing is searched until requestReload has checked the cache fingerprint.
    haveIndex = false
    sel = 1
    inputRev += 1
    noctalia.state.set("file_search_open", true)
    local dir = shared.dataDir()
    if dir ~= nil then
        shared.scope = shared.readScope(dir)
        shared.whole = shared.readWhole(dir)
        shared.folders = shared.readFolders(dir)
        shared.ranking = shared.readRanking(dir)
        showUsage = readShowUsage(dir)
        -- Load the last usage measurement.
        if usage.load(dir) then
            usage.writeSvg(
                dir, USAGE_SIZE, USAGE_THICKNESS,
                shared.formatBytes(usage.total),
                shared.tr("usage_center")
            )
        end
    end
    if fzfMissing then
        render()
        return
    end
    render()
    requestReload(false, false)
    requestUsage(false)
end

function onClose()
    -- Stop the frame tick, even mid-build.
    setSpinnerTicking(false)
    stopKeyRepeat()
    noctalia.state.set("file_search_open", false)
    if spaceOn() then
        space.onClose()
    end
    panel.setNeedsFrameTick(false)
end

-- plugin_api >= 18. Drives the spinner, the key repeat and the Space scan.
function onFrameTick(deltaMs)
    if spaceOn() and space.needsTick() then
        space.step()
        syncFrameTick()
    end
    if heldStep ~= 0 then
        repeatInMs -= deltaMs
        if repeatInMs <= 0 then
            repeatInMs = REPEAT_STEP_MS
            if moveSelection(heldStep, false) then
                render()
            else
                stopKeyRepeat()
            end
        end
    end
    if not spinnerTicking then
        return
    end
    spinnerAccumMs += deltaMs
    if spinnerAccumMs < SPINNER_STEP_MS then
        return
    end
    spinnerAccumMs = 0
    spinnerIndex = (spinnerIndex % #SPINNER_FRAMES) + 1
    render()
end

function onConfigChanged()
    if spaceOn() then
        space.onConfigChanged()
    elseif activeTab == "space" then
        activeTab = "search"
        space.onClose()
        space.onDisabled()
        stopKeyRepeat()
        render()
    else
        space.onDisabled() -- a scan left running by a closed panel
    end
    if fzfMissing or indexing then
        return
    end
    -- Re-read scope and mounts from disk; this also fires with the panel closed.
    local dir = shared.dataDir()
    if dir ~= nil then
        shared.scope = shared.readScope(dir)
        shared.whole = shared.readWhole(dir)
        shared.folders = shared.readFolders(dir)
    end
    -- Expire the usage measurement (a changed exclusion list does not invalidate it).
    usage.scannedAt = 0
    requestReload(false, false)
end

function onQueryChanged(value)
    query = value
    runSearch()
end

-- Enter in the query input: opens the selected row, which is the top match
-- until an arrow key has moved it.
function onOpenSelected(value)
    query = value
    if results[sel] ~= nil then
        openEntry(results[sel])
    end
end

-- The chords listed under capture_keys in plugin.toml. They arrive here even
-- while the query input has focus; typing still goes to the input.
function onKey(chord, pressed)
    local step = KEY_STEPS[chord]
    if step == nil or (activeTab == "space" and spaceOn()) then
        return
    end
    if not pressed then
        if heldStep == step then
            stopKeyRepeat()
        end
        return
    end
    heldStep = step
    repeatInMs = REPEAT_DELAY_MS
    syncFrameTick()
    if moveSelection(step, true) then
        render()
    end
end

-- The explicit command: the only thing that walks an external disk.
function onRefreshIndex()
    if indexing then
        return
    end
    requestReload(true, true)
    requestUsage(true)
end

-- The Space tab's "search here" button: restricts the results to a folder below
-- the search root. Anything else, or a path with a control character, is a notice.
function onSearchHere(path)
    if not spaceOn() then
        return
    end
    local root = shared.roots[1]
    if shared.scope ~= "folder" or shared.whole or #shared.roots ~= 1 or root == nil or path:find("%c") then
        noctalia.notify(shared.tr("title"), shared.tr("space_search_unavailable"))
        return
    end
    local prefix = root == "/" and "/" or root .. "/"
    local rel = nil
    if path == root then
        rel = ""
    elseif shared.startsWith(path, prefix) then
        rel = path:sub(#prefix + 1)
    end
    if rel == nil then
        noctalia.notify(shared.tr("title"), shared.tr("space_search_outside"))
        return
    end
    usageFilter = rel ~= "" and rel or nil
    setActiveTab("search")
    render()
    runSearch()
end

-- The strip's ✕: lifts the folder restriction.
function onClearUsageFilter()
    if usageFilter == nil then
        return
    end
    usageFilter = nil
    render()
    runSearch()
end

function onToggleUsage()
    if not usageAvailable() then
        return
    end
    showUsage = not showUsage
    local dir = shared.dataDir()
    if dir ~= nil then
        writeShowUsage(dir, showUsage)
    end
    render()
    requestUsage(false)
end

-- Re-run the current query through the other scoring scheme.
function onCycleRanking()
    if not shared.schemeSupported then
        return
    end
    shared.ranking = shared.NEXT_RANKING[shared.ranking] or shared.DEFAULT_RANKING
    local dir = shared.dataDir()
    if dir ~= nil then
        shared.writeRanking(dir, shared.ranking)
    end
    render()
    runSearch()
end

-- Allowed mid-build: the in-flight build finishes against the cache of its own
-- scope. Process work goes through requestReload.
function onToggleDisks()
    shared.scope = shared.NEXT_SCOPE[shared.scope] or shared.DEFAULT_SCOPE
    local dir = shared.dataDir()
    if dir ~= nil then
        shared.writeScope(dir, shared.scope)
    end
    results = {}
    total = nil
    errMsg = nil
    usageFilter = nil
    render()
    requestReload(false, false)
    requestUsage(false)
end

-- Dispatch for a result row's context menu. `action` is the id of the entry
-- picked, `context` the index record the menu was opened on.
function onResultMenu(action, context)
    if type(context) ~= "string" or context == "" then
        return
    end
    if action == "open" then
        openEntry(context)
    elseif action == "reveal" then
        revealEntry(context)
    elseif action == "copy_path" then
        copyEntry(context)
    elseif action == "copy_name" then
        copyName(context)
    end
end

-- Global because openContextMenu names its handler; the logic lives in space.luau.
function onSpaceMenu(action, context)
    if not spaceOn() then
        return
    end
    space.menuAction(action, context)
end

-- Opens the settings window on this plugin's own page.
function onOpenSettings()
    noctalia.openSettings()
end

function onClosePanel()
    panel.close()
end

shared.probeFzfScheme()

-- Hand usage.luau the two slice labels it does not read off the filesystem.
usage.looseLabel = shared.tr("usage_loose")
usage.otherLabel = shared.tr("usage_other")
