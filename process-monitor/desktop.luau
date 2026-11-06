--!nonstrict
-- desktop.luau — desktop tile: totals, a CPU+GPU graph and the top N apps.
--
--   title            click → open the panel
--   sort chips       Overall / CPU / RAM / GPU / VRAM (remembered)
--   row              click → open the panel filtered to that app
--   ✕ on a row       (shown on hover) click twice within 4 s → terminate
--
-- The host scales the content to the box set in the desktop-widgets editor and
-- draws the background, so this only lays out a fixed-width column.

local S = require("./shared.luau")
local tr = S.tr

local cpuScale = S.cfg("cpu_scale", "machine")
local rowsWanted = math.floor(tonumber(S.cfg("desktop_rows", 10)) or 10)
local configuredSort = S.cfg("desktop_sort", "overall")
local grouped = S.bool(S.cfg("desktop_group_by_app", false), false)
local showTotals = S.bool(S.cfg("desktop_show_totals", true), true)
local showGraph = S.bool(S.cfg("desktop_show_graph", true), true)
local showIcons = S.bool(S.cfg("desktop_show_icons", true), true)
local title = S.cfg("desktop_title", "Processes")
local showHeader = title ~= ""

local WIDTH = 420 -- default content width; fitWidth() adapts it to the box
local ROW_H = 24
local CELL_W = 54
local BTN = 22
local SORTS = { "overall", "cpu", "ram", "gpu", "vram" }

local snap = nil
local hovered = nil -- key of the row under the pointer
local armed = nil -- { key, at } for the two-click terminate

-- ── Remembered sort ──────────────────────────────────────────────────────────
-- Plugins cannot write their own settings, so the header button's choice is
-- kept in the data dir. It is dropped when the configured default changes.

local sortBy = configuredSort
local statePath = nil
do
    local dir = noctalia.pluginDataDir()
    if dir then
        statePath = dir .. "/desktop.json"
        local raw = noctalia.readFile(statePath)
        local ok, saved = pcall(function() return raw and noctalia.json.decode(raw) end)
        if ok and type(saved) == "table" and saved.configured == configuredSort and saved.sort then
            sortBy = saved.sort
        end
    end
end

local function saveSort()
    if statePath then
        noctalia.writeFile(statePath, noctalia.json.encode({ sort = sortBy, configured = configuredSort }))
    end
end

-- ── Pieces ───────────────────────────────────────────────────────────────────

-- Same activity/critical thresholds as the built-in sysmon temperature stats.
local function tempColor(c)
    if not c or c < 60 then return "on_surface_variant" end
    if c >= 85 then return "error" end
    return "error/0.7"
end

local function stat(id, value, fraction, sub, tempC, tempGlyph)
    local top = {
        ui.glyph({ name = S.GLYPH[id], size = S.GLYPH_SIZE, color = S.COLOR[id] }),
        ui.label({ text = value, fontSize = S.F_BODY, fontWeight = "bold", color = S.COLOR[id], flexGrow = 1 }),
    }
    if tempC then
        table.insert(top, ui.glyph({ name = tempGlyph, size = 13, color = tempColor(tempC) }))
        table.insert(top, ui.label({ text = string.format("%.0f°C", tempC), fontSize = S.F_CAPTION, color = tempColor(tempC) }))
    end
    return ui.column({ key = "stat-" .. id, flexGrow = 1, gap = S.XS }, {
        ui.row({ gap = S.XS, align = "center" }, top),
        ui.progress({ progress = math.clamp(fraction or 0, 0, 1), fill = S.COLOR[id], height = 3, radius = S.radius(2) }),
        ui.label({ text = sub or "", fontSize = S.F_MINI, color = "on_surface_variant", maxLines = 1 }),
    })
end

local function totals()
    local mem = snap.mem or {}
    local gpu = snap.gpu or {}
    local stats = noctalia.systemStats and noctalia.systemStats() or nil
    local cpuTemp = stats and stats.cpu and stats.cpu.tempC
    local gpuTemp = stats and stats.gpu and stats.gpu.tempC
    local cpuPct = snap.cpu and snap.cpu.pct or 0
    local items = {
        stat("cpu", S.pct(cpuPct), cpuPct / 100, tr("ui.desk_cpu_sub", { procs = snap.nprocs or 0 }),
            cpuTemp, "cpu-temperature"),
        stat("ram", S.bytes(mem.used), (mem.total or 0) > 0 and mem.used / mem.total or 0,
            tr("ui.desk_ram_sub", { total = S.bytes(mem.total) })),
    }
    if gpu.pct ~= nil then
        table.insert(items, stat("gpu", S.pct(gpu.pct), gpu.pct / 100,
            gpu.vramUsed and tr("ui.desk_gpu_sub", { vram = S.bytes(gpu.vramUsed) }) or S.metricLabel("gpu"), gpuTemp, "temperature"))
    end
    return ui.row({ key = "totals", gap = S.MD }, items)
end

local function cell(id, text, fraction, color)
    return ui.column({ key = id, width = CELL_W, gap = 2, align = "end" }, {
        ui.label({ text = text, fontSize = S.F_MINI }),
        ui.progress({ progress = math.clamp(fraction, 0, 1), fill = color, width = CELL_W, height = 2, radius = S.radius(1) }),
    })
end

local function rowKey(r)
    return grouped and ("a:" .. r[S.NAME]) or ("p:" .. tostring(r[S.PID]))
end

local function row(r)
    local key = rowKey(r)
    local paused = S.isPaused(r)
    local isHover = hovered == key
    local isArmed = armed ~= nil and armed.key == key and os.time() - armed.at <= 4
    local cpu = r[S.CPU] * snap.cpuMul

    local name = r[S.NAME]
    if paused then name = name .. " · paused" end

    local lead = {}
    if showIcons then table.insert(lead, S.avatar(r[S.NAME], 18)) end
    table.insert(lead, ui.label({
        text = name, fontSize = S.F_CAPTION, maxLines = 1, flexGrow = 1,
        color = paused and "on_surface_variant" or "on_surface",
    }))

    -- Buttons stay in the layout and only fade, so rows never shift sideways.
    -- Hidden until hovered (or while armed / paused), so idle rows stay clean.
    local btnOpacity = (isHover or isArmed) and 1 or 0

    return ui.row({
        key = key, gap = S.SM, align = "center", minHeight = ROW_H, paddingH = S.XS,
        radius = S.radius(6), fill = isHover and "on_surface/0.06" or S.NO_FILL,
        onClick = function() S.openPanel(r[S.NAME]) end,
        onHover = function(state)
            if state == "true" then hovered = key elseif hovered == key then hovered = nil end
            render()
        end,
    }, {
        ui.row({ gap = S.SM, align = "center", flexGrow = 1 }, lead),
        cell("c", S.pct(cpu), cpu / (100 * snap.cpuMul), S.COLOR.cpu),
        cell("r", S.bytes(r[S.MEM]), S.memPct(snap, r[S.MEM]) / 100, S.COLOR.ram),
        sortBy == "vram"
            and cell("g", r[S.VRAM] > 0 and S.bytes(r[S.VRAM]) or "–",
                r[S.VRAM] / math.max(1, snap.gpu and snap.gpu.vramTotal or 1), S.COLOR.vram)
            or cell("g", r[S.GPU] > 0 and S.pct(r[S.GPU]) or "–", r[S.GPU] / 100, S.COLOR.gpu),
        ui.row({ key = "act", gap = 0, align = "center", opacity = btnOpacity }, {
            ui.button({
                key = "end", glyph = isArmed and "alert-triangle" or "x", glyphSize = 12,
                width = BTN, height = BTN, variant = isArmed and "destructive" or "ghost",
                onClick = function()
                    if armed and armed.key == key and os.time() - armed.at <= 4 then
                        armed = nil
                        S.signal(r, "TERM")
                    else
                        armed = { key = key, at = os.time() }
                    end
                    render()
                end,
            }),
        }),
    })
end

local function header()
    return ui.row({
        key = "title", gap = S.SM, align = "center",
        onClick = function() S.openPanel() end,
    }, {
        ui.glyph({ name = "device-desktop-analytics", size = S.GLYPH_SIZE, color = "primary" }),
        ui.label({ text = title, fontSize = S.F_TITLE, fontWeight = "bold", flexGrow = 1 }),
        ui.label({ text = grouped and tr("ui.count_apps", { count = #(snap.apps or {}) }) or tr("ui.count_processes", { count = snap.nprocs or 0 }),
            fontSize = S.F_MINI, color = "on_surface_variant" }),
    })
end

-- Sort selector: one chip per order, the active one filled.
local function sortChips()
    local chips = {
        ui.glyph({ name = "sort-descending", size = 13, color = "on_surface_variant" }),
    }
    for _, id in ipairs(SORTS) do
        local active = sortBy == id
        table.insert(chips, ui.button({
            key = "sort-" .. id, text = S.metricLabel(id), fontSize = S.F_MINI, height = BTN,
            variant = active and "secondary" or "ghost", selected = active,
            onClick = function()
                sortBy = id
                saveSort()
                render()
            end,
        }))
    end
    return ui.row({ key = "sort", gap = S.XS, align = "center" }, chips)
end

-- ── Filling the box ──────────────────────────────────────────────────────────
-- The host scales the content uniformly to fit the tile's box, so a content
-- shape that differs from the box leaves empty bands. Scripts are not told
-- their box, so read it from the config: tiles of this type with the same
-- title (average shape if several), then pick the content width whose shape
-- matches. Heights are Noctalia's metrics for the parts drawn below.

local TYPE_ID = S.DESKTOP_ID
local ROW_PITCH = ROW_H + 2

local function contentHeight()
    local h = S.MD * 2 -- padding
    -- title row; without it, the first part below has no gap above it
    if showHeader then h += 22 else h -= S.SM end
    if showTotals then h += S.SM + 46 end
    if showGraph then h += S.SM + 40 end
    h += S.SM + BTN -- sort chips
    h += S.SM + 15 -- column headings
    h += S.SM + rowsWanted * ROW_PITCH - 2
    -- labels lay out a little shorter than their font size; measured on screen
    return h * 0.89
end

local function boxAspect()
    local ok, widgets = pcall(noctalia.getSetting, "desktop_widgets.widget")
    if not ok or type(widgets) ~= "table" then return nil end
    local sum, n = 0, 0
    for _, w in pairs(widgets) do
        if type(w) == "table" and w.type == TYPE_ID and (w.box_width or 0) > 0 and (w.box_height or 0) > 0 then
            local t = (type(w.settings) == "table" and w.settings.desktop_title) or "Processes"
            if t == title then
                sum += w.box_width / w.box_height
                n += 1
            end
        end
    end
    return n > 0 and sum / n or nil
end

local lastAspect = nil
local function fitWidth()
    local aspect = boxAspect()
    if aspect then lastAspect = aspect end
    if not lastAspect then return WIDTH end
    return math.clamp(math.floor(contentHeight() * lastAspect), 340, 1200)
end

-- ── Render ───────────────────────────────────────────────────────────────────

function render()
    S.beginRender()
    -- The GPU temperature is drawn only inside the GPU stat, which needs the
    -- sampler's machine-wide GPU busy value.
    S.wantGpuStats(showTotals and snap ~= nil and snap.gpu ~= nil and snap.gpu.pct ~= nil)
    if not snap then
        desktopWidget.render(ui.column({ width = fitWidth(), gap = S.SM, padding = S.MD }, {
            ui.label({ text = showHeader and title or tr("plugin_name"), fontSize = S.F_TITLE, fontWeight = "bold" }),
            ui.label({
                text = tr("ui.waiting_desktop"),
                fontSize = S.F_CAPTION, color = "on_surface_variant",
            }),
        }))
        return
    end

    local children = {}
    if showHeader then table.insert(children, header()) end
    if showTotals then table.insert(children, totals()) end
    if showGraph then
        local hist = noctalia.state.get("history") or {}
        table.insert(children, ui.graph({
            key = "graph", values = hist.cpu or {}, values2 = hist.gpu or {},
            color = S.COLOR.cpu, color2 = S.COLOR.gpu, height = 40, lineWidth = 1.5, fillOpacity = 0.15,
        }))
    end

    table.insert(children, sortChips())

    local function colHead(id, width)
        local text = S.metricLabel(id)
        local active = id == sortBy
        return ui.row({ width = width, justify = "end" }, {
            ui.label({
                text = active and (text .. " ↓") or text, fontSize = S.F_MINI,
                color = active and "primary" or "on_surface_variant", fontWeight = active and "bold" or "normal",
            }),
        })
    end
    table.insert(children, ui.row({ key = "head", gap = S.SM, paddingH = S.XS }, {
        ui.label({ text = grouped and tr("ui.col_app") or tr("ui.col_process"), fontSize = S.F_MINI, color = "on_surface_variant", flexGrow = 1 }),
        colHead("cpu", CELL_W), colHead("ram", CELL_W), colHead(sortBy == "vram" and "vram" or "gpu", CELL_W),
        ui.row({ width = BTN }, {}),
    }))

    local rows = S.rows(snap, grouped, sortBy)
    local list = {}
    for i = 1, rowsWanted do
        if rows[i] then
            table.insert(list, row(rows[i]))
        else
            -- keep a constant height so the host's content scale stays put
            table.insert(list, ui.row({ key = "pad" .. i, minHeight = ROW_H }, {}))
        end
    end
    table.insert(children, ui.column({ key = "rows", gap = 2 }, list))

    desktopWidget.render(ui.column({ width = fitWidth(), gap = S.SM, padding = S.MD }, children))
    S.endRender()
end

noctalia.state.watch("snapshot", function(raw)
    snap = S.decode(raw, cpuScale)
    render()
end)
snap = S.decode(noctalia.state.get("snapshot"), cpuScale)
render()
