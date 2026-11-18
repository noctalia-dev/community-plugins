--!nonstrict
-- bar_widget.luau — bar readout styled like Noctalia's built-in sysmon widgets:
-- monochrome glyph, a thin vertical gauge and the value, tinted toward the
-- error colour as a value crosses the same activity/critical thresholds the
-- built-ins use. After the totals comes the busiest app. Hover for the top
-- five, click for the panel.

local S = require("./shared.luau")
local tr = S.tr

local display = S.cfg("display", "both")
local metric = S.cfg("metric", "overall")
local grouped = S.bool(S.cfg("group_by_app", false), false)
local cpuScale = S.cfg("cpu_scale", "machine")
local maxName = math.floor(tonumber(S.cfg("max_name_length", 16)) or 16)
local showIcon = S.bool(S.cfg("show_app_icon", false), false)
local showGauges = S.bool(S.cfg("show_gauges", true), true)
local showTemps = S.bool(S.cfg("show_temps", true), true)
local showVram = S.bool(S.cfg("show_vram", true), true)

-- Noctalia's own glyph aliases, so the icons match the built-in widgets.
local GLYPH = {
    cpu = "cpu-usage", cpu_temp = "cpu-temperature", ram = "memory",
    gpu = "gpu-usage", vram = "memory", gpu_temp = "temperature",
}
-- Built-in defaults (src/core/sysmon thresholdProfile): {activity, critical}
local THRESHOLD = {
    cpu = { 50, 90 }, cpu_temp = { 60, 85 }, ram = { 60, 90 },
    gpu = { 50, 95 }, vram = { 50, 90 }, gpu_temp = { 60, 85 },
}

-- ── Colour: on_surface → error, the way the built-ins tint ───────────────────

local function hexToRgb(hex)
    hex = string.gsub(hex or "#ffffff", "#", "")
    return tonumber(string.sub(hex, 1, 2), 16) or 255, tonumber(string.sub(hex, 3, 4), 16) or 255,
        tonumber(string.sub(hex, 5, 6), 16) or 255
end

local function tint(kind, value)
    local t = THRESHOLD[kind]
    if not t or not value or value <= t[1] then return nil end -- nil = bar default colour
    local f = value >= t[2] and 1 or 0.25 + 0.75 * (value - t[1]) / (t[2] - t[1])
    local r1, g1, b1 = hexToRgb(noctalia.getColor("on_surface"))
    local r2, g2, b2 = hexToRgb(noctalia.getColor("error"))
    local function mix(a, b) return math.floor(a + (b - a) * f + 0.5) end
    return string.format("#%02x%02x%02x", mix(r1, r2), mix(g1, g2), mix(b1, b2))
end

-- ── Pieces ───────────────────────────────────────────────────────────────────

-- Vertical gauge size (ui.progress is horizontal only, so item() builds a
-- track column with the fill pinned to its bottom, like the built-in gauge).
local GAUGE_W, GAUGE_H = 4, 12

local function trackColor(color)
    -- a tinted hex value gets its 30% track via the #rrggbbaa form
    if color then return color .. "4d" end
    return "on_surface/0.3"
end

local function item(kind, value, fraction, text, vertical)
    local color = tint(kind, value)
    local children = { ui.glyph({ key = "g", name = GLYPH[kind], color = color }) }
    if showGauges and fraction then
        local h = math.floor(GAUGE_H * math.clamp(fraction, 0, 1) + 0.5)
        table.insert(children, ui.column({
            key = "gauge", width = GAUGE_W, height = GAUGE_H, justify = "end",
            fill = trackColor(color), radius = S.radius(GAUGE_W / 2),
        }, {
            ui.box({ height = math.max(h, 1), fill = color or "on_surface", radius = S.radius(GAUGE_W / 2) }),
        }))
    end
    table.insert(children, ui.label({ key = "v", text = text, color = color }))
    local container = vertical and ui.column or ui.row
    return container({ key = "item-" .. kind .. (color and "-tint" or ""), gap = S.XS, align = "center" }, children)
end

local function gib(bytes)
    return string.format("%.1f GiB", (bytes or 0) / 1024 ^ 3)
end

local function totals(snap, stats, vertical)
    local out = {}
    local mem = snap.mem or {}
    local gpu = snap.gpu or {}
    local cpuPct = snap.cpu and snap.cpu.pct or 0
    local ramPct = (mem.total or 0) > 0 and mem.used * 100 / mem.total or 0

    table.insert(out, item("cpu", cpuPct, cpuPct / 100, S.pct(cpuPct), vertical))
    local cpuTemp = stats and stats.cpu and stats.cpu.tempC
    if showTemps and cpuTemp then
        table.insert(out, item("cpu_temp", cpuTemp, cpuTemp / 100, string.format("%.0f°C", cpuTemp), vertical))
    end
    table.insert(out, item("ram", ramPct, ramPct / 100, gib(mem.used), vertical))
    if gpu.pct ~= nil then
        table.insert(out, item("gpu", gpu.pct, gpu.pct / 100, S.pct(gpu.pct), vertical))
    end
    if showVram and gpu.vramUsed and (gpu.vramTotal or 0) > 0 then
        local v = gpu.vramUsed * 100 / gpu.vramTotal
        table.insert(out, item("vram", v, v / 100, S.pct(v), vertical))
    end
    local gpuTemp = stats and stats.gpu and stats.gpu.tempC
    if showTemps and gpuTemp then
        table.insert(out, item("gpu_temp", gpuTemp, gpuTemp / 100, string.format("%.0f°C", gpuTemp), vertical))
    end
    return out
end

-- Which resource dominates a row, for the "overall" metric (all as a share
-- of the whole machine).
local function dominant(snap, row)
    local cpu = row[S.CPU]
    local ram = S.memPct(snap, row[S.MEM])
    local gpu = row[S.GPU]
    if gpu >= cpu and gpu >= ram then return "gpu" end
    if ram >= cpu then return "ram" end
    return "cpu"
end

local function valueOf(snap, row, m)
    if m == "cpu" then return S.pct(row[S.CPU] * snap.cpuMul) end
    if m == "ram" then return S.bytes(row[S.MEM]) end
    if m == "gpu" then return S.pct(row[S.GPU]) end
    if m == "vram" then return S.bytes(row[S.VRAM]) end
    return ""
end

local function topItem(snap, top, vertical)
    local m = metric == "overall" and dominant(snap, top) or metric
    local children = {}
    if showIcon then
        table.insert(children, S.avatar(top[S.NAME], 16))
    else
        table.insert(children, ui.glyph({ key = "g", name = "activity" }))
    end
    if not vertical then
        local name = S.truncate(top[S.NAME], maxName)
        table.insert(children, ui.label({ key = "n", text = name }))
    end
    table.insert(children, ui.label({
        key = "v", text = valueOf(snap, top, m), color = "on_surface_variant",
    }))
    local container = vertical and ui.column or ui.row
    return container({ key = "top", gap = S.XS, align = "center" }, children)
end

-- Tooltip values are kept short: Noctalia caps the tooltip width and cuts
-- longer values off. Per app: CPU · RAM, plus GPU when it uses the GPU.
local function rowSummary(snap, row)
    local v = S.pct(row[S.CPU] * snap.cpuMul) .. " · " .. S.bytes(row[S.MEM])
    if row[S.GPU] > 0 then v ..= " · " .. S.pct(row[S.GPU]) end
    return v
end

-- ── Render ───────────────────────────────────────────────────────────────────

local function render(raw)
    S.beginRender()
    S.wantGpuStats(showTemps)
    local snap = S.decode(raw, cpuScale)
    local vertical = barWidget.isVertical()
    local container = vertical and ui.column or ui.row
    if not snap then
        barWidget.render(container({ gap = S.XS, align = "center" }, { ui.glyph({ name = "activity" }) }))
        barWidget.setTooltip(tr("plugin_name") .. ": " .. tostring(noctalia.state.get("status") or "starting"))
        return
    end
    local stats = (showTemps and noctalia.systemStats) and noctalia.systemStats() or nil

    local sortBy = metric == "name" and "overall" or metric
    local rows = S.rows(snap, grouped, sortBy)
    local top = rows[1]

    local children = {}
    if display ~= "top" then
        for _, n in ipairs(totals(snap, stats, vertical)) do table.insert(children, n) end
    end
    if top and display ~= "totals" then
        if #children > 0 then
            table.insert(children, ui.box({
                key = "div", width = vertical and 14 or 1, height = vertical and 1 or 14, fill = "on_surface/0.25",
            }))
        end
        table.insert(children, topItem(snap, top, vertical))
    end
    -- spaceSm between items: tighter than separate widgets, which also get capsule padding
    barWidget.render(container({ gap = S.SM, align = "center" }, children))

    -- Tooltip: totals, then the top five by the configured metric.
    local tip = {}
    local mem = snap.mem or {}
    local gpu = snap.gpu or {}
    local cpuLine = S.pct(snap.cpu and snap.cpu.pct or 0)
    if stats and stats.cpu and stats.cpu.tempC then cpuLine ..= string.format(" · %.0f°C", stats.cpu.tempC) end
    table.insert(tip, { S.metricLabel("cpu"), cpuLine })
    table.insert(tip, { S.metricLabel("ram"), string.format("%.1f / %.1f GiB", (mem.used or 0) / 1024 ^ 3, (mem.total or 0) / 1024 ^ 3) })
    if gpu.pct ~= nil then
        local v = S.pct(gpu.pct)
        if stats and stats.gpu and stats.gpu.tempC then v ..= string.format(" · %.0f°C", stats.gpu.tempC) end
        table.insert(tip, { S.metricLabel("gpu"), v })
        if gpu.vramUsed then
            table.insert(tip, { S.metricLabel("vram"), S.bytes(gpu.vramUsed) .. " / " .. S.bytes(gpu.vramTotal) })
        end
    end
    table.insert(tip, { "", "" })
    table.insert(tip, { grouped and tr("ui.top_apps") or tr("ui.top_processes"), tr("ui.top_columns") })
    for i = 1, math.min(5, #rows) do
        local r = rows[i]
        local name = S.truncate(r[S.NAME], 16)
        table.insert(tip, { name, rowSummary(snap, r) })
    end
    barWidget.setTooltip(tip)
    S.endRender()
end

noctalia.state.watch("snapshot", render)
render(noctalia.state.get("snapshot"))

function onClick()
    noctalia.togglePanel(S.PANEL_ID)
end
