--!nonstrict
-- shared.luau — helpers used by every entry of yahya637/process-monitor.
--
-- The service publishes the sampler's raw JSON line as state "snapshot" (a
-- string copies across entries cheaply) and the total-usage history as
-- "history". Each entry decodes the snapshot itself with M.decode().

local M = {}

M.PLUGIN = "yahya637/process-monitor"
M.PANEL_ID = M.PLUGIN .. ":panel"
M.DESKTOP_ID = M.PLUGIN .. ":desktop"

M.tr = noctalia.tr

-- Row layout coming from sampler.py
M.PID, M.NAME, M.CPU, M.MEM, M.GPU, M.VRAM, M.COUNT, M.PIDS, M.PAUSED = 1, 2, 3, 4, 5, 6, 7, 8, 9

-- Noctalia's own spacing and type scale (lib/ui/style.h), so the plugin sits
-- next to the built-in widgets without looking roomier than them.
M.XS, M.SM, M.MD, M.LG = 4, 8, 12, 16
M.F_MINI, M.F_CAPTION, M.F_BODY, M.F_TITLE = 11, 13, 14, 16
M.GLYPH_SIZE = 16

-- Corner radius scaled by [shell] corner_radius_scale, like the built-ins.
local radiusScale = nil
function M.radius(base)
    if radiusScale == nil then
        local v = noctalia.getSetting and noctalia.getSetting("shell.corner_radius_scale")
        radiusScale = tonumber(v) or 1
    end
    return base * radiusScale
end

-- Open the panel, optionally filtered to one app (`noctalia msg panel-open`
-- carries the context; togglePanel cannot).
function M.openPanel(filter)
    if filter and filter ~= "" then
        noctalia.runAsync({ "noctalia", "msg", "panel-open", M.PANEL_ID, filter })
    else
        noctalia.togglePanel(M.PANEL_ID)
    end
end

-- Shared row actions, used by the panel's menu/strip and the desktop tile.
function M.isPaused(row)
    return row[M.PAUSED] == true
end

M.METRICS = { "overall", "cpu", "ram", "gpu", "vram", "name" }
function M.metricLabel(id)
    return noctalia.tr("ui.metric." .. id)
end

-- Palette roles per metric, so the bar, panel and desktop agree.
M.COLOR = { cpu = "primary", ram = "secondary", gpu = "tertiary", vram = "tertiary" }
-- Noctalia's own glyph aliases (lib/render/text/glyph_registry.cpp), matching the built-ins.
M.GLYPH = { cpu = "cpu-usage", ram = "memory", gpu = "gpu-usage", vram = "memory", overall = "activity" }

function M.bool(v, default)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    if type(v) == "string" then return v == "true" end
    return default
end

function M.cfg(key, default)
    local v = noctalia.getConfig(key)
    if v == nil then return default end
    return v
end

-- ── Formatting ───────────────────────────────────────────────────────────────

function M.bytes(n)
    n = n or 0
    if n >= 1000 * 1024 ^ 2 then -- keep labels to 4 chars: 1020M reads as 1.0G
        local g = n / 1024 ^ 3
        return string.format(g >= 10 and "%.0fG" or "%.1fG", g)
    elseif n >= 1024 ^ 2 then
        return string.format("%.0fM", n / 1024 ^ 2)
    elseif n >= 1024 then
        return string.format("%.0fK", n / 1024)
    end
    return string.format("%dB", n)
end

function M.pct(p)
    p = p or 0
    if p > 0 and p < 1 then
        return string.format("%.1f%%", p)
    end
    return string.format("%.0f%%", p)
end

function M.truncate(s, n)
    if not n or n <= 0 or #s <= n then return s end
    return string.sub(s, 1, n - 1) .. "…"
end

-- ── Snapshot ─────────────────────────────────────────────────────────────────

-- Returns the decoded snapshot or nil. `cpuScale` is "machine" (share of the
-- whole CPU, all cores = 100%) or "core" (one core = 100%, like top/htop).
function M.decode(raw, cpuScale)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, snap = pcall(noctalia.json.decode, raw)
    if not ok or type(snap) ~= "table" then return nil end
    snap.cpuMul = (cpuScale == "core") and (snap.cpu and snap.cpu.cores or 1) or 1
    return snap
end

function M.memPct(snap, bytes)
    local total = snap and snap.mem and snap.mem.total or 0
    if total <= 0 then return 0 end
    return bytes * 100 / total
end

-- "Overall" impact: whichever resource the process strains most, as a share
-- of the whole machine (CPU of all cores, RAM of all RAM, GPU busy).
function M.score(snap, row)
    local cpu = row[M.CPU] or 0
    local ram = M.memPct(snap, row[M.MEM] or 0)
    local gpu = row[M.GPU] or 0
    return math.max(cpu, ram, gpu)
end

local function key(snap, row, metric)
    if metric == "cpu" then return row[M.CPU] or 0 end
    if metric == "ram" then return row[M.MEM] or 0 end
    if metric == "gpu" then return row[M.GPU] or 0 end
    if metric == "vram" then return row[M.VRAM] or 0 end
    return M.score(snap, row)
end

-- Sorted copy of the process or app list. `filter` matches name or pid.
function M.rows(snap, grouped, metric, filter, ascending)
    if not snap then return {} end
    local src = (grouped and snap.apps or snap.procs) or {}
    local out = {}
    local needle = filter and string.lower(filter) or ""
    for _, r in ipairs(src) do
        if needle == ""
            or string.find(string.lower(r[M.NAME] or ""), needle, 1, true)
            or tostring(r[M.PID]) == needle then
            table.insert(out, r)
        end
    end
    if metric == "name" then
        table.sort(out, function(a, b)
            local x, y = string.lower(a[M.NAME] or ""), string.lower(b[M.NAME] or "")
            if ascending then return x < y end
            return x > y
        end)
    else
        table.sort(out, function(a, b)
            local x, y = key(snap, a, metric), key(snap, b, metric)
            if x == y then return (a[M.PID] or 0) < (b[M.PID] or 0) end
            if ascending then return x < y end
            return x > y
        end)
    end
    return out
end

-- ── App icons ────────────────────────────────────────────────────────────────

-- appIconPath() scans the icon theme on a miss, which is far too slow to do
-- for a whole table inside one callback. So lookups are rationed per render
-- (M.beginRender), results are shared between entries through state "icons"
-- ("" = no icon), and unresolved rows fill in on later refreshes.
local ICON_LOOKUPS_PER_RENDER = 2
local iconCache = {}
local lookupsLeft = ICON_LOOKUPS_PER_RENDER
local cacheDirty = false

local function iconKey(name)
    local k = string.lower(name)
    k = string.gsub(k, "%.exe$", "")
    k = string.gsub(k, "%-bin$", "")
    return k
end

function M.beginRender()
    lookupsLeft = ICON_LOOKUPS_PER_RENDER
    local shared = noctalia.state.get("icons")
    if type(shared) == "table" then
        for k, v in pairs(shared) do
            if iconCache[k] == nil then iconCache[k] = v end
        end
    end
end

function M.endRender()
    if cacheDirty then
        cacheDirty = false
        noctalia.state.set("icons", iconCache)
    end
end

-- Themed icon path for a process name, or nil (also nil while not looked up yet).
function M.icon(name)
    local k = iconKey(name)
    local hit = iconCache[k]
    if hit ~= nil then return hit ~= "" and hit or nil end
    if lookupsLeft <= 0 then return nil end
    lookupsLeft -= 1
    local path = noctalia.appIconPath(name, 32)
    if not path and k ~= name then
        path = noctalia.appIconPath(k, 32)
    end
    iconCache[k] = path or ""
    cacheDirty = true
    return path
end

-- App icon, or a rounded badge with the name's first letter when the app has
-- no icon (or it hasn't been looked up yet). The badge colour is picked from
-- the name, so an app keeps the same colour between refreshes.
local BADGE = {
    { "primary_container", "on_primary_container" },
    { "secondary_container", "on_secondary_container" },
    { "tertiary_container", "on_tertiary_container" },
}

function M.avatar(name, size)
    local icon = M.icon(name)
    if icon then
        return ui.image({ path = icon, width = size, height = size })
    end
    local letter = string.match(name, "%w") or "?"
    local h = 0
    for i = 1, #name do h = (h * 31 + string.byte(name, i)) % 997 end
    local c = BADGE[h % #BADGE + 1]
    return ui.row({
        width = size, height = size, radius = math.floor(size / 4), fill = c[1],
        align = "center", justify = "center",
    }, {
        ui.label({ text = string.upper(letter), fontSize = math.floor(size * 0.55), fontWeight = "bold", color = c[2] }),
    })
end

-- ── Process control ──────────────────────────────────────────────────────────

function M.signal(row, sig)
    local pids = row[M.PIDS]
    if type(pids) ~= "table" or #pids == 0 then
        pids = { row[M.PID] }
    end
    local argv = { "kill", "-" .. sig }
    for _, p in ipairs(pids) do
        table.insert(argv, tostring(p))
    end
    noctalia.runAsync(argv, function(res)
        if res.exitCode ~= 0 then
            noctalia.notifyError(noctalia.tr("plugin_name"),
                noctalia.tr("ui.kill_failed", { signal = sig, error = res.stderr or "" }))
        end
    end)
end

return M
