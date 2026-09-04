--!nonstrict
-- file-search — fuzzy search panel, fzf as the matching subsystem.
--
-- On open the active roots are walked once with `find` into a cache file
-- (excluded directory names are pruned, hidden entries too unless enabled);
-- after that every keystroke runs `fzf --filter=<query>` over the cache, so
-- typing stays responsive even on large trees. Results update live; picking
-- one opens it with the system MIME association (xdg-open) — directories
-- open in the file manager. Enter opens the top match. Right-clicking a row
-- raises a native context menu (plugin_api >= 28) with open, reveal in the
-- file manager, copy path and copy name.
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

-- The search core: constants, the state describing what is being searched, and
-- every helper that depends on it — shared with launcher.luau and the bar
-- widget through require() (plugin_api >= 22). See shared.luau for why.
local shared = require("./shared.luau")

-- The usage donut under the results. Panel-only, so it is not in shared.luau:
-- the bar widget and the launcher have no chart to draw.
local usage = require("./usage.luau")

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
-- Kept apart from `query` rather than written into it as '^name/': the input
-- stays the user's own text, and the restriction gets its own removable strip
-- instead of being fzf syntax to recognise and edit out.
local usageFilter = nil

local render
local runSearch
local buildIndex
local applyState

-- Braille spinner shown in the status footer during a from-scratch index
-- build (plugin_api >= 18: panel.setNeedsFrameTick + onFrameTick). Gated on
-- `#results == 0` in updateSpinnerState below, not just `indexing`: a stale
-- index keeps showing its OLD results while a fresh build runs behind it
-- (indexState == "stale"), and re-running render() at spinner speed would
-- re-walk that whole results list (resultRow + elidePathCached) many times a
-- second — the exact CPU-budget trap 0.0.26 was released to fix. An empty
-- results list makes that rebuild cost nothing, so ticking is only ever
-- armed for the genuinely slow case this exists for: a disk scope indexed
-- for the first time, with nothing yet to show.
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_STEP_MS = 90
local spinnerIndex = 1
local spinnerAccumMs = 0
local spinnerTicking = false

local function setSpinnerTicking(on)
    if on == spinnerTicking then
        return
    end
    spinnerTicking = on
    panel.setNeedsFrameTick(on)
    if not on then
        spinnerAccumMs = 0
        spinnerIndex = 1
    end
end

-- Whether the usage donut is shown, persisted next to the scope. A header
-- button and a file rather than a bool setting: no API lets a plugin write its
-- own settings (getSetting, added in 26, only reads), so a setting would only
-- be changeable from the settings window, three clicks from the panel.
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

-- Cache keyed by the raw record: elidePath is pure, so the same rel never
-- needs recomputing across the many render() calls that leave `results`
-- untouched (toggling the usage chart, resizing, other settings changes all
-- re-render the whole row list). On a flatpak-heavy $HOME almost every
-- visible row is over PATH_MAX_CHARS (runtime trees nest well past 56
-- chars), so the "common case skips this" comment above routinely fails and
-- render() was recomputing the full utf8 walk for up to `max_results` rows
-- on every one of those unrelated re-renders — that is what exceeded a
-- panel callback's CPU budget and got the panel disabled. Cleared wholesale
-- rather than LRU-evicted once it grows past a session's realistic working
-- set — simplicity over a perfect policy, since a full miss just costs one
-- elidePath call again.
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
    local target = shared.scope
    buildMs = nil -- belongs to the index of this scope, if that one recorded it
    local recorded = noctalia.readFile(dir .. "/count-" .. target)
    if recorded ~= nil then
        -- The `or shared.trim(recorded)` is NOT dead: 0.0.22 added the elapsed
        -- millis to this sidecar, and one written before that holds the count
        -- alone. That file is still on disk for any scope not rebuilt since —
        -- count-all here is a bare "1166625" — and without the fallback the
        -- match fails and the footer reports 0 indexed for a perfectly good
        -- index. buildMs stays nil for those, which is exactly right: that
        -- build never recorded one.
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
            if shared.scope == target then
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
    if #shared.roots == 0 then
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
    local key = shared.indexKey()
    -- The format this walk WRITES follows the roots it is about to visit, not
    -- the format of the index being replaced.
    local builtRoots = shared.roots
    local absolute = #builtRoots > 1
    local builtScope = shared.scope

    local cmd = shared.buildCommand(dir, key, absolute)

    render()
    local ok = noctalia.runAsync(cmd, function(result)
        indexing = false
        if result.exitCode == 0 and not result.timedOut then
            totals[builtScope] = nil -- size/mtime moved; recount lazily
            if builtScope ~= shared.scope then
                -- The scope was cycled while the walk ran, so what just landed
                -- on disk is not what the panel is showing: none of it — the
                -- count, the freshness — describes the current scope. Derive
                -- the state again instead of inheriting it.
                applyState()
            else
                -- The file on disk is the one this walk just wrote: read it
                -- the way it was written.
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

-- The fzf term that restricts the results to one direct child of the root.
--
-- '^' is fzf's EXACT prefix operator, not a fuzzy one (verified: '^x.y/' takes
-- 'x.y/g', not 'xxy/g2'), and the trailing '/' keeps '^src/' off a sibling
-- called 'srcold'. Only spaces need escaping — fzf splits terms on them; '!',
-- '$' and '|' are special only at a token boundary this one does not put them
-- at. Works on records relative to a single root (find -printf '%P'), which is
-- the folder scope, the only scope offering the chart.
local function folderToken(name)
    return "^" .. name:gsub(" ", "\\ ") .. "/"
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
        end
        -- The query moved on while this search ran: chase it. The stale
        -- rows rendered below are overwritten as soon as it completes.
        -- Compared on the composed query, so picking a folder from the chart
        -- mid-search is chased exactly like a keystroke would be.
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
-- the file manager does not need to be running. When there is no such handler,
-- or no gdbus at all (execvp failing is a 127 exit like any other), the
-- fallback opens the containing folder through the MIME association, which is
-- the same window minus the selection.
--
-- An argv (plugin_api >= 24) rather than a shell line: the GVariant literal
-- carries a file name straight from the index and nothing parses it. That moves
-- the `||` fallback out of the shell and into the callback.
local function revealEntry(rel)
    local path = shared.absolutePath(rel)
    if path == nil then
        rejectRecord(rel)
        return
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then
        parent = "/"
    end
    local ok = noctalia.runAsync({
        "gdbus",
        "call",
        "--session",
        "--dest",
        "org.freedesktop.FileManager1",
        "--object-path",
        "/org/freedesktop/FileManager1",
        "--method",
        "org.freedesktop.FileManager1.ShowItems",
        '["' .. fileUri(path) .. '"]',
        "",
    }, function(result)
        if result.exitCode ~= 0 or result.timedOut then
            shared.openPath(parent)
        end
    end, 5000)
    if not ok then
        shared.openPath(parent)
    end
end

-- The result row's right-click menu (plugin_api >= 28). Only a ui.button's
-- onRightClick reports the pointer serial openContextMenu needs, so the row
-- itself is what raises it. `onActivate` must NAME a global (openContextMenu is
-- a raw binding, not a UI tree prop, so closures are not registered for it),
-- and the record rides along in `context` — a path, so it comes back verbatim
-- and every action re-validates it through absolutePath.
--
-- The header is the elided path, not the full one: it is the same string the row
-- shows, which is what makes the menu read as belonging to that row.
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
    -- The row carries no tooltip on purpose: one string per row is enough
    -- extra weight, over a list this long, to get the render's callback killed
    -- for exceeding its CPU budget. The row menu's copy entries yield the
    -- full path instead.
    local shown = elidePathCached(rel)
    return ui.button({
        key = "hit-" .. index,
        glyph = isDir and "folder" or "file",
        text = shown,
        variant = "ghost",
        contentAlign = "start",
        onClick = function()
            openEntry(rel) -- always the full record, never the elided label
        end,
        -- Right rather than middle because a ui.button never receives the
        -- middle button: it accepts BTN_LEFT, plus BTN_RIGHT only once an
        -- onRightClick is attached, and no node in the declarative UI exposes
        -- a middle-click callback at all — that one is a bar-widget gesture.
        onRightClick = function()
            openResultMenu(rel)
        end,
    })
end

-- Free space across every mount the current scope would walk (plugin_api >=
-- 16). One noctalia.diskStats(path) call per mount — the same small, stable
-- set `mounts` already holds, never per matched file — because each distinct
-- path queried is retained by the host until the plugin unloads.
--
-- Memoized, because the caller is not what the comment above assumed. This
-- feeds scopeButton()'s tooltip, so it runs from render() — and render() runs
-- at SPINNER_STEP_MS while a first-time disk index builds, which turned "one
-- call per mount" into one call per mount roughly eleven times a second. It is
-- the same CPU-budget trap elidePathCached exists to close, except this one
-- crosses into the host every frame instead of only burning Luau cycles. Free
-- space has no business being sampled at frame rate anyway: it is a tooltip the
-- user reads after hovering, so a few seconds stale is invisible.
--
-- Keyed on scope plus the mount list, so cycling the scope or a disk appearing
-- refreshes it immediately instead of waiting out the TTL.
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
    -- nil is cached too: with no readable mount, retrying every frame is the
    -- worst case, not the safe one.
    freeCacheValue = sampled > 0
        and shared.tr("tip_scope_free", { free = shared.formatBytes(freeBytes), count = sampled })
        or nil
    return freeCacheValue
end

-- ── usage donut ──────────────────────────────────────────────────────────────

local USAGE_SIZE = 108
local USAGE_THICKNESS = 16
local USAGE_LABEL_MAX = 16
-- Pinned, because a Button sizes itself for the bar's chrome: at its natural
-- height a legend row came out at ~50px, and seven of those made the legend
-- three times the height of the donut. `height` sets a Button's min AND max.
local USAGE_ROW_HEIGHT = 20

-- Measure the current search root and redraw when it lands. Never on a disk
-- scope: those roots are removable volumes, du over one is a minutes-long
-- walk, and the panel already refuses to index them unasked.
local function requestUsage(force)
    if not showUsage or shared.scope ~= "folder" then
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

-- Restrict the results to a folder from the chart, or lift the restriction by
-- picking the same one again.
--
-- Spelled out rather than `(usageFilter == name) and nil or name`, the Lua trap
-- that shipped in the first cut: `and nil` yields nil, which is falsy, so `or`
-- takes the other branch and the expression returns `name` in BOTH cases.
local function pickUsageFolder(name)
    if usageFilter == name then
        usageFilter = nil
    else
        usageFilter = name
    end
    render()
    runSearch()
end

-- One legend row: swatch, folder, size and share. The swatch takes the SAME hex
-- the SVG used, which is why the two halves of the chart agree.
--
-- Only the name is a Button, growing into the space between swatch and size, so
-- the hover highlight covers the row while the numbers keep their right-aligned
-- column. Only "folder" slices get one — "other" and the loose files name
-- nothing fzf could be pointed at.
local function usageLegendRow(slice, index)
    -- utf8.len returns nil on an invalid sequence, which headChars would then
    -- split mid-character. Left whole rather than risking a throw in render().
    local label = slice.label
    local labelLen = utf8.len(label)
    if labelLen ~= nil and labelLen > USAGE_LABEL_MAX then
        label = headChars(label, USAGE_LABEL_MAX - 1) .. ELLIPSIS
    end
    local share = usage.total > 0 and (slice.bytes / usage.total * 100) or 0
    local name
    if slice.kind == "folder" then
        local active = usageFilter == slice.label
        -- Keyed apart from the label below: a slice can change kind between
        -- measurements, and the reconciler matches children by type AND key.
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
        -- separate percent column would sit at a different offset per row.
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

-- The whole strip, or nil when it is off — which leaves the panel exactly the
-- shape it had before the chart existed.
local function usageSection()
    if not showUsage or shared.scope ~= "folder" then
        return nil
    end

    local children = {}
    if usage.state == "ready" and usage.imagePath ~= nil then
        local legend = {}
        for index, slice in ipairs(usage.slices) do
            table.insert(legend, usageLegendRow(slice, index))
        end
        -- Nothing else in the panel is a list of buttons that look like text,
        -- so the rows being clickable is said once, in words. Dropped once a
        -- restriction is on: the strip above the results is then what to read.
        if usageFilter == nil then
            table.insert(legend, ui.label({
                key = "ulegend-hint",
                text = shared.tr("usage_hint"),
                fontSize = 10,
                color = "on_surface_variant",
            }))
        end
        -- Mount points are absent from the total, since `du -x` never crosses a
        -- filesystem boundary. Naming them is the difference between a number
        -- that is incomplete and one that is wrong.
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

    return ui.row({ key = "usage", gap = 12, align = "center" }, children)
end

-- The active restriction as its own strip under the query input, or nil. In
-- words with one way out, rather than as '^winboat/' inside the input, where it
-- would be indistinguishable from what the user typed.
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

-- One dim line of fzf's extended-search operators, directly under the query
-- input — next to the field they describe, rather than at the far end of the
-- panel where the usage chart had pushed them out of sight of it. They are the
-- difference between "many matches" and "the one", and nothing else here hints
-- that the field understands more than letters. One label, not a row of chips:
-- the cheapest node count for something that renders on every keystroke.
-- Two labels rather than one string: the caption says what the row is, dimmed
-- so it reads as a label and not as part of the syntax, and the operators
-- themselves stay in the brighter colour because they are the content.
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
            -- Searchable, but built for a different scope or disk set. Saying
            -- so is the honest alternative to silently re-walking a 5 TB drive.
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

-- Names the scoring scheme and switches it. The tooltip has to carry the whole
-- explanation: the difference only shows up in the order of the rows, and there
-- is nowhere else to say what changed. When fzf is too old for --scheme the
-- button stays on the generic scheme and says why, rather than disappearing.
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
        variant = "ghost",
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
        variant = showUsage and "secondary" or "ghost",
        enabled = shared.scope == "folder",
        tooltip = shared.scope == "folder"
            and shared.tr(showUsage and "tip_usage_hide" or "tip_usage_show")
            or shared.tr("tip_usage_folder_only"),
        onClick = "onToggleUsage",
    })
end

-- The scope button cycles folder → folder+disks → disks only. A cycling button
-- rather than a ui.select: the panel is 480px tall and the header row is the
-- only space that costs nothing, and the tooltip names both the current scope
-- and the next one, which a select's collapsed state would not.
local function scopeButton()
    local tooltip = shared.tr("tip_scope", {
        current = shared.tr("scope." .. shared.scope),
        next = shared.tr("scope." .. shared.NEXT_SCOPE[shared.scope]),
    })
    local free = diskFreeSummary()
    if free ~= nil then
        tooltip = tooltip .. "\n" .. free
    end
    return ui.button({
        key = "scope-" .. shared.scope,
        glyph = shared.SCOPE_GLYPHS[shared.scope],
        variant = "ghost",
        tooltip = tooltip,
        onClick = "onCycleScope",
    })
end

render = function()
    setSpinnerTicking(indexing and #results == 0)

    -- Every child of the panel and of the header carries a stable key, so the
    -- reconciler matches roles instead of guessing by position and type.
    local children = {
        ui.row({ key = "header", gap = 6, align = "center" }, {
            ui.label({
                key = "title",
                text = shared.tr("title"),
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
            usageButton(),
            scopeButton(),
            ui.button({ key = "refresh", glyph = "refresh", variant = "ghost", tooltip = shared.tr("tip_refresh"), onClick = "onRefreshIndex" }),
            ui.button({ key = "settings", glyph = "settings", variant = "ghost", tooltip = shared.tr("tip_settings"), onClick = "onOpenSettings" }),
            ui.button({ key = "close", glyph = "close", variant = "ghost", tooltip = shared.tr("tip_close"), onClick = "onClosePanel" }),
        }),
        ui.input({
            key = "query-" .. inputRev,
            value = query,
            focus = true,
            placeholder = shared.tr("search_placeholder"),
            onChange = "onQueryChanged",
            onSubmit = "onOpenFirst",
        }),
        syntaxLegend(),
    }

    local strip = usageFilterStrip()
    if strip ~= nil then
        table.insert(children, strip)
    end

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
        body = ui.label({ key = "body-msg", text = shared.tr("err_no_fzf"), color = "error", flexGrow = 1 })
    elseif errMsg ~= nil then
        body = ui.label({ key = "body-msg", text = errMsg, color = "error", flexGrow = 1 })
    elseif #shared.roots == 0 and not indexing then
        -- Only reachable with scope "external": nothing to search, and
        -- "no matches" would blame the query for it.
        body = ui.label({ key = "body-msg", text = shared.tr("no_external"), color = "on_surface_variant", flexGrow = 1 })
    elseif indexState == "missing" and not indexing then
        -- A disk scope that has never been indexed. Walking it is a
        -- minutes-long operation on a large drive, so it is offered rather
        -- than performed.
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
        body = ui.scroll({ key = "hits", flexGrow = 1, gap = 2 }, rows)
    end
    table.insert(children, ui.column({ key = "body", flexGrow = 1, align = "stretch" }, { body }))
    -- Below the results: the chart describes the folder, not the query.
    local chart = usageSection()
    if chart ~= nil then
        table.insert(children, ui.separator({ key = "usage-rule" }))
        table.insert(children, chart)
    end
    table.insert(children, statusFooter())

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

-- Recompute the roots from the current scope and mounts, then search the cache
-- that belongs to them. A stale fingerprint only triggers a walk when
-- autoIndexAllowed() says so; otherwise the existing index is searched as-is
-- and flagged, or the panel asks for a rebuild when there is none at all.
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
        -- buildIndex would have set the total; reusing a cache has to go and
        -- count it (memoized).
        readTotal(dir)
        runSearch()
    elseif shared.autoIndexAllowed() then
        results = {}
        total = nil
        buildIndex()
    else
        -- Out of date, and not ours to fix on our own: an index built for
        -- another disk set still answers most queries, so it is searched and
        -- labelled rather than thrown away.
        haveIndex = noctalia.fileExists(dir .. "/list-" .. shared.scope)
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
    shared.probeMounts(force, function()
        reloading = false
        if build then
            shared.roots = shared.computeRoots()
            -- The index being replaced stays readable until the walk lands, so
            -- a row clicked meanwhile still resolves.
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
    query = ""
    results = {}
    errMsg = nil
    -- Not carried across opens: a restriction whose origin is off screen
    -- ("why does this find nothing?") is worse than re-picking it.
    usageFilter = nil
    -- Not trusted across opens: the scope may have moved under us (the
    -- launcher can cycle it), so nothing is searched until reload() has
    -- checked the fingerprint of the cache this scope actually uses.
    haveIndex = false
    inputRev += 1
    noctalia.state.set("file_search_open", true)
    local dir = shared.dataDir()
    if dir ~= nil then
        -- Re-read on every open: the launcher may have cycled the scope, and
        -- a script reload drops both of these from memory.
        shared.scope = shared.readScope(dir)
        shared.ranking = shared.readRanking(dir)
        showUsage = readShowUsage(dir)
        -- An earlier session's measurement, so the chart is up with the panel
        -- and du only runs when it is actually out of date.
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
    render() -- the panel is up while lsblk answers
    requestReload(false, false)
    -- Independent of the index: one being stale says nothing about the other.
    -- Cheap on a repeat open — usage.scan honours its own TTL.
    requestUsage(false)
end

function onClose()
    -- Stop the frame tick even mid-build; the next onOpen re-arms it if the
    -- build is somehow still running (buildIndex survives the panel closing).
    setSpinnerTicking(false)
    noctalia.state.set("file_search_open", false)
end

-- plugin_api >= 18. Throttled to SPINNER_STEP_MS regardless of the host's
-- actual tick rate; render() itself flips setNeedsFrameTick off once indexing
-- ends or results stop being empty, so this never spins forever unattended.
function onFrameTick(deltaMs)
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
    if fzfMissing or indexing then
        return
    end
    -- Scope and mounts are re-read rather than reused: this fires while the
    -- panel is closed too, when the launcher may have cycled the scope and the
    -- in-memory mount list can predate it. Rebuilding a disk index from a stale
    -- (empty) list would throw away a good index and take minutes to redo.
    local dir = shared.dataDir()
    if dir ~= nil then
        shared.scope = shared.readScope(dir)
    end
    -- Expired, not redone: this also fires with the panel closed. A changed
    -- search_folder invalidates itself (usage.fresh compares the root); a
    -- changed exclusion list does not, which is what this covers.
    usage.scannedAt = 0
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
    -- TTL ignored: "refresh" has to mean everything the panel shows.
    requestUsage(true)
end

-- The strip's ✕. Same effect as re-clicking the highlighted legend row, offered
-- where the restriction is shown: the chart can be switched off while it is on.
function onClearUsageFilter()
    if usageFilter == nil then
        return
    end
    usageFilter = nil
    render()
    runSearch()
end

-- Hiding does not discard the measurement, so showing it again is instant.
function onToggleUsage()
    if shared.scope ~= "folder" then
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

-- The index is untouched; only the order of the rows changes, so the current
-- query is simply run again through the other scheme.
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

-- Allowed mid-build on purpose: a walk over a slow disk can run for minutes and
-- there is no way to cancel it, so blocking the button would trap the user in
-- the scope they are trying to leave. The in-flight build finishes against the
-- cache of the scope it started in and never starts another one by itself.
--
-- The press itself is deliberately cheap — a 6-byte write and a render. Every
-- process it might need (mount scan, count, search) goes through
-- requestReload, which collapses a burst of presses into one pass.
function onCycleScope()
    shared.scope = shared.NEXT_SCOPE[shared.scope] or shared.DEFAULT_SCOPE
    local dir = shared.dataDir()
    if dir ~= nil then
        shared.writeScope(dir, shared.scope)
    end
    results = {}
    total = nil
    errMsg = nil
    -- The token is a relative-path prefix; a disk scope stores absolute
    -- records, where it would silently match nothing.
    usageFilter = nil
    render()
    requestReload(false, false)
    -- A no-op on a disk scope, so this is safe on every leg.
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

-- Opens the settings window on this plugin's own page (the host supplies the
-- plugin id, so a plugin can only ever open its own). The panel closes on the
-- way; the index survives it, since it lives in the plugin data directory.
function onOpenSettings()
    noctalia.openSettings()
end

function onClosePanel()
    panel.close()
end

shared.probeFzfScheme()

-- usage.luau builds the slice labels, so the two it invents rather than reads
-- off the filesystem are handed to it from here — every user-visible string
-- still comes out of translations/en.json.
usage.looseLabel = shared.tr("usage_loose")
usage.otherLabel = shared.tr("usage_other")
