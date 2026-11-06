--!nonstrict
-- panel.luau — the full view: CPU/RAM/GPU cards with history graphs, then a
-- filterable table of apps or processes.
--
--   click a row            → show its action strip (terminate, force kill,
--                            pause/resume, copy PID/name); click again to close
--   right-click the ✕      → the same actions as a menu
--   click a column header  → sort by it (again to reverse)
--   ✕                      → click twice within 4 s to terminate
--
-- Only ui.button receives right-clicks in Noctalia's plugin API, and a button
-- keeps a highlight after it is clicked, so rows use the left-click strip.
--
-- `noctalia msg panel-open yahya637/process-monitor:panel <name>` opens it
-- filtered to <name> with that app expanded (the desktop tile does this).

local S = require("./shared.luau")
local tr = S.tr

local cpuScale = S.cfg("cpu_scale", "machine")
local MAX_ROWS = 60

local isOpen = false
local grouped = S.bool(S.cfg("group_by_app", false), false)
local sortBy = "overall"
local ascending = false
local filter = ""
local filterGen = 0 -- bump to re-seed the (uncontrolled) filter input
local expanded = nil -- key of the row whose action strip is open
local armed = nil -- { key = rowKey .. action, at = os.time() }
local rowsByKey = {}

local COL_W = 104
local VRAM_W = 72
local ACT_W = 28
local ROW_H = 26

local function rowKey(row)
    if grouped then return "app:" .. row[S.NAME] end
    return "pid:" .. tostring(row[S.PID])
end

local function isArmed(k)
    return armed ~= nil and armed.key == k and os.time() - armed.at <= 4
end

-- Two-click confirmation for destructive actions.
local function confirm(k, fn)
    if isArmed(k) then
        armed = nil
        fn()
    else
        armed = { key = k, at = os.time() }
    end
    render()
end

-- ── Totals ───────────────────────────────────────────────────────────────────

local function card(id, value, sub, fraction, series)
    local color = S.COLOR[id]
    return ui.column({
        key = "card-" .. id, flexGrow = 1, gap = S.XS, padding = S.MD,
        radius = S.radius(9), fill = "surface_container",
    }, {
        ui.row({ gap = S.SM, align = "center" }, {
            ui.glyph({ name = S.GLYPH[id], size = S.GLYPH_SIZE, color = color }),
            ui.label({ text = string.upper(id), fontSize = S.F_MINI, color = "on_surface_variant", flexGrow = 1 }),
            ui.label({ text = value, fontSize = S.F_TITLE, fontWeight = "bold", color = color }),
        }),
        ui.graph({ values = series or {}, color = color, height = 32, lineWidth = 1.5, fillOpacity = 0.15 }),
        ui.progress({ progress = math.clamp(fraction or 0, 0, 1), fill = color, height = 3, radius = S.radius(2) }),
        ui.label({ text = sub, fontSize = S.F_MINI, color = "on_surface_variant", maxLines = 1 }),
    })
end

local function totals(snap, hist)
    hist = hist or {}
    local mem = snap.mem or {}
    local gpu = snap.gpu or {}
    local cpuPct = snap.cpu and snap.cpu.pct or 0
    local cards = {
        card("cpu", S.pct(cpuPct),
            tr("ui.cpu_sub", { threads = snap.cpu and snap.cpu.cores or 0, procs = snap.nprocs or 0 }),
            cpuPct / 100, hist.cpu),
        card("ram", S.bytes(mem.used),
            tr("ui.ram_sub", { total = S.bytes(mem.total), swap = S.bytes(mem.swapUsed) }),
            (mem.total or 0) > 0 and mem.used / mem.total or 0, hist.ram),
    }
    if gpu.pct ~= nil then
        table.insert(cards, card("gpu", S.pct(gpu.pct),
            gpu.vramUsed and tr("ui.vram_of", { used = S.bytes(gpu.vramUsed), total = S.bytes(gpu.vramTotal) }) or "",
            gpu.pct / 100, hist.gpu))
    end
    return ui.row({ gap = S.SM }, cards)
end

-- ── Toolbar and column headers ───────────────────────────────────────────────

local function setSort(id)
    if sortBy == id then
        ascending = not ascending
    else
        sortBy = id
        ascending = (id == "name")
    end
    render()
end

local function toolbar()
    return ui.row({ gap = S.SM, align = "center" }, {
        ui.input({
            key = "filter-" .. filterGen, value = filter, placeholder = tr("ui.filter_placeholder"),
            controlSize = "sm", flexGrow = 1,
            onChange = function(text) filter = text; render() end,
        }),
        ui.button({
            key = "sort-overall", text = S.metricLabel("overall"), glyph = "activity", controlSize = "sm",
            variant = sortBy == "overall" and "secondary" or "ghost",
            tooltip = tr("ui.overall_tooltip"),
            onClick = function() setSort("overall") end,
        }),
        ui.button({
            key = "mode-apps", text = tr("ui.apps"), glyph = "apps", controlSize = "sm",
            variant = grouped and "secondary" or "ghost",
            onClick = function() grouped = true; expanded = nil; render() end,
        }),
        ui.button({
            key = "mode-procs", text = tr("ui.processes"), glyph = "list", controlSize = "sm",
            variant = grouped and "ghost" or "secondary",
            onClick = function() grouped = false; expanded = nil; render() end,
        }),
    })
end

local function header()
    local function h(id, text, width, justify)
        local active = sortBy == id
        return ui.button({
            -- glyph can't be unset on a retained button, so the key follows the state
            key = "h-" .. id .. (active and "-on" or ""), text = text, fontSize = S.F_MINI, height = 22, width = width,
            glyph = active and (ascending and "sort-ascending" or "sort-descending") or nil, glyphSize = 12,
            variant = "ghost", selected = active, contentAlign = justify or "end",
            flexGrow = width == nil and 1 or nil,
            onClick = function() setSort(id) end,
        })
    end
    return ui.row({ gap = S.SM, paddingH = S.XS, align = "center" }, {
        h("name", grouped and tr("ui.col_app") or tr("ui.col_process"), nil, "start"),
        h("cpu", S.metricLabel("cpu"), COL_W, "start"), h("ram", S.metricLabel("ram"), COL_W, "start"),
        h("gpu", S.metricLabel("gpu"), COL_W, "start"),
        h("vram", S.metricLabel("vram"), VRAM_W),
        ui.row({ width = ACT_W }, {}),
    })
end

-- ── Rows ─────────────────────────────────────────────────────────────────────

local function meter(id, text, fraction, color)
    return ui.row({ key = id, width = COL_W, gap = S.SM, align = "center" }, {
        ui.row({ width = 44, justify = "end" }, { ui.label({ text = text, fontSize = S.F_CAPTION - 1 }) }),
        ui.progress({
            progress = math.clamp(fraction, 0, 1), fill = color, width = COL_W - 44 - S.SM,
            height = 3, radius = S.radius(2),
        }),
    })
end

local function openMenu(row, key)
    local count = (row[S.PIDS] and #row[S.PIDS]) or 1
    local what = count > 1 and tr("ui.menu_header_group", { name = row[S.NAME], count = count })
        or tr("ui.menu_header_pid", { name = row[S.NAME], pid = row[S.PID] })
    local paused = S.isPaused(row)
    panel.openContextMenu({
        items = {
            { kind = "header", label = what },
            { id = "TERM", label = tr("ui.terminate") },
            { id = "KILL", label = tr("ui.force_kill") },
            { kind = "separator" },
            paused and { id = "CONT", label = tr("ui.resume") } or { id = "STOP", label = tr("ui.pause") },
            { kind = "separator" },
            { id = "copy-pid", label = count > 1 and tr("ui.copy_pids") or tr("ui.copy_pid") },
            { id = "copy-name", label = tr("ui.copy_name") },
        },
        onActivate = "onRowMenu",
        context = key,
    })
end

local function copyPids(row)
    local pids = row[S.PIDS]
    local text = (type(pids) == "table" and #pids > 0) and table.concat(pids, " ") or tostring(row[S.PID])
    noctalia.copyToClipboard(text, "text/plain")
end

local function actionStrip(row, key)
    local paused = S.isPaused(row)
    local pids = row[S.PIDS] or { row[S.PID] }
    local info
    if #pids > 1 then
        local shown = {}
        for i = 1, math.min(6, #pids) do shown[i] = tostring(pids[i]) end
        info = tr("ui.strip_group", { count = #pids, pids = table.concat(shown, " ") .. (#pids > 6 and " …" or "") })
    else
        info = tr("ui.strip_pid", { pid = row[S.PID] })
    end
    local function btn(id, text, glyph, variant, onClick)
        return ui.button({
            key = "a-" .. id, text = text, glyph = glyph, glyphSize = 12, fontSize = S.F_MINI,
            height = 24, variant = variant or "ghost", onClick = onClick,
        })
    end
    local killKey = key .. "|KILL"
    return ui.row({ key = "strip", gap = S.XS, align = "center", paddingH = S.XS }, {
        ui.label({ text = info, fontSize = S.F_MINI, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
        btn("term", tr("ui.terminate"), "x", "outline", function() S.signal(row, "TERM"); expanded = nil; render() end),
        btn("kill", isArmed(killKey) and tr("ui.click_to_confirm") or tr("ui.force_kill"), "skull",
            isArmed(killKey) and "destructive" or "outline",
            function() confirm(killKey, function() S.signal(row, "KILL"); expanded = nil end) end),
        btn("pause", paused and tr("ui.resume") or tr("ui.pause"), paused and "player-play" or "player-pause", "outline",
            function() S.signal(row, paused and "CONT" or "STOP") end),
        btn("pid", tr("ui.pid"), "copy", nil, function() copyPids(row) end),
        btn("name", S.metricLabel("name"), "copy", nil, function() noctalia.copyToClipboard(row[S.NAME], "text/plain") end),
    })
end

local function processRow(snap, row, index)
    local key = rowKey(row)
    rowsByKey[key] = row
    local isExpanded = expanded == key
    local paused = S.isPaused(row)
    local cpu = row[S.CPU] * snap.cpuMul
    local gpuTotalVram = snap.gpu and snap.gpu.vramTotal or 0

    local name = row[S.NAME]
    if not grouped then name = name .. "  ·  " .. row[S.PID] end
    if paused then name = name .. "  ·  " .. tr("ui.paused") end

    local toggle = function()
        -- not `isExpanded and nil or key`: that always yields key
        if isExpanded then expanded = nil else expanded = key end
        render()
    end
    local endKey = key .. "|TERM"

    local main = ui.row({ key = "main", gap = S.SM, align = "center", minHeight = ROW_H, onClick = toggle }, {
        S.avatar(row[S.NAME], 20),
        -- A plain label: as a button it kept Noctalia's pressed/focus colour
        -- after a click. The row itself takes the click.
        ui.label({ key = "name", text = name, fontSize = S.F_CAPTION, maxLines = 1, flexGrow = 1 }),
        meter("c", S.pct(cpu), cpu / (100 * snap.cpuMul), S.COLOR.cpu),
        meter("r", S.bytes(row[S.MEM]), S.memPct(snap, row[S.MEM]) / 100, S.COLOR.ram),
        meter("g", row[S.GPU] > 0 and S.pct(row[S.GPU]) or "–", row[S.GPU] / 100, S.COLOR.gpu),
        ui.row({ width = VRAM_W, justify = "end" }, {
            ui.label({
                text = row[S.VRAM] > 0 and S.bytes(row[S.VRAM]) or "–", fontSize = S.F_CAPTION - 1,
                color = (gpuTotalVram > 0 and row[S.VRAM] / gpuTotalVram > 0.25) and S.COLOR.vram or "on_surface",
            }),
        }),
        ui.button({
            key = "kill", glyph = isArmed(endKey) and "alert-triangle" or "x", glyphSize = 12,
            width = ACT_W, height = 24, variant = isArmed(endKey) and "destructive" or "ghost",
            tooltip = isArmed(endKey) and tr("ui.click_again_terminate") or tr("ui.terminate"),
            onClick = function() confirm(endKey, function() S.signal(row, "TERM") end) end,
            onRightClick = function() openMenu(row, key) end,
        }),
    })

    local children = { main }
    if isExpanded then table.insert(children, actionStrip(row, key)) end

    local fill = S.NO_FILL
    if isExpanded then
        fill = "surface_container_high"
    elseif index % 2 == 0 then
        fill = "surface_container/0.5"
    end
    return ui.column({
        key = key, gap = S.XS, paddingH = S.XS, paddingV = 2, radius = S.radius(6), fill = fill,
        opacity = paused and 0.7 or 1,
    }, children)
end

-- ── Render ───────────────────────────────────────────────────────────────────

function render()
    if not isOpen then return end
    S.beginRender()
    local snap = S.decode(noctalia.state.get("snapshot"), cpuScale)
    local close = ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = function() panel.close() end })

    if not snap then
        local status = noctalia.state.get("status") or "starting"
        panel.render(ui.column({ gap = S.MD }, {
            ui.row({ align = "center" }, {
                ui.label({ text = tr("plugin_name"), fontSize = S.F_TITLE, fontWeight = "bold", flexGrow = 1 }),
                close,
            }),
            ui.label({ text = tr("ui.waiting_panel", { status = tostring(status) }), color = "on_surface_variant" }),
        }))
        return
    end

    rowsByKey = {}
    local rows = S.rows(snap, grouped, sortBy, filter, ascending)
    local list = {}
    for i = 1, math.min(MAX_ROWS, #rows) do
        table.insert(list, processRow(snap, rows[i], i))
    end
    if #list == 0 then
        table.insert(list, ui.row({ padding = S.MD }, {
            ui.label({ text = tr("ui.no_matches"), color = "on_surface_variant" }),
        }))
    end

    panel.render(ui.column({ gap = S.SM, flexGrow = 1 }, {
        ui.row({ align = "center", gap = S.SM }, {
            ui.glyph({ name = "device-desktop-analytics", size = S.GLYPH_SIZE, color = "primary" }),
            ui.label({ text = tr("plugin_name"), fontSize = S.F_TITLE, fontWeight = "bold", flexGrow = 1 }),
            ui.label({
                text = tr("ui.updated", { time = noctalia.formatTime("{:%H:%M:%S}", (snap.t or 0) // 1000) }),
                fontSize = S.F_MINI, color = "on_surface_variant",
            }),
            close,
        }),
        totals(snap, noctalia.state.get("history")),
        toolbar(),
        header(),
        ui.scroll({ key = "list", flexGrow = 1, gap = 2, revealKey = expanded }, list),
    }))
    S.endRender()
end

function onRowMenu(action, key)
    local row = rowsByKey[key]
    if not row then return end
    if action == "copy-pid" then
        copyPids(row)
    elseif action == "copy-name" then
        noctalia.copyToClipboard(row[S.NAME], "text/plain")
    else
        S.signal(row, action)
    end
end

function onOpen(context)
    isOpen = true
    armed = nil
    if type(context) == "string" and context ~= "" then
        -- opened from the desktop tile: show that app with its actions open
        grouped = true
        filter = context
        filterGen += 1
        expanded = "app:" .. context
    end
    render()
end

function onClose()
    isOpen = false
end

noctalia.state.watch("snapshot", function()
    render()
end)
