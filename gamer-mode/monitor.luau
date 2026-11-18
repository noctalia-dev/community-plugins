--!nonstrict
--
-- Bar monitor: a live metrics readout. It owns no state -- it renders whatever the
-- service publishes and never issues a command of its own except the panel toggle.
--
-- The formatting helpers below are duplicated from widget.luau and panel.luau on
-- purpose. Plugin entries run in separate sandboxed Luau states with no `require`, so
-- there is no module for them to share.

local PANEL_ID = "nomadcxx/gamer-mode:main"
local MIB_PER_GIB = 1024
local PLACEHOLDER = "—"
-- No pill is drawn here. The bar draws it: with `capsule = true` on the widget the shell
-- wraps the rendered content in a stadium shell sized content + 2 * capsule_padding on
-- the main axis and capsule_thickness * bar thickness on the cross axis, radius
-- min(w, h) * 0.5, content centred inside it (shell bar.cpp finalizeCapsules). That is
-- the same capsule the built-in sysmon widgets get, and drawing our own could only ever
-- approximate it -- badly, since a plugin cannot see the bar's thickness or scale.

-- The readout is driven by state.watch, so the tick only exists for animation. It cannot
-- be switched off, so idle is slowed from the 250ms default instead.
local IDLE_INTERVAL_MS = 1000
local FLARE_INTERVAL_MS = 33
local FLARE_DURATION_MS = 900
-- Fire catches. Opening at full intensity is the single thing that made the old flare
-- read as a light switch rather than an ignition.
local IGNITE_MS = 150

local FLAME_COLUMNS = 28
-- The shell's capsule is capsule_thickness (0.76 by default) of the bar -- about 26px on
-- a 34px bar -- and the digits take ~17 of that. Six leaves the band room to burn while
-- the readout still fits, which matters because the bar clips its slots.
-- The band's height in pixels. A plugin cannot read the bar's thickness -- barWidget
-- exposes only isVertical and outputName -- so this cannot be derived and has to be a
-- setting. The default fits a 42px bar (33px capsule) and a 34px bar (30px capsule) over
-- ~17px of digits; a thinner bar needs a smaller band or the slot clips.
-- Measured on a 42px bar at the default capsule_thickness of 0.76: the pill's interior is
-- 32px and the readout box takes 22 of them, leaving 10. The band is reserved
-- symmetrically (see buildTree), so it gets half of what is left. Raising the shell's
-- capsule_thickness is what buys a taller flame: at 0.95 the pill is ~40px and 9 fits.
local FLAME_HEIGHT_DEFAULT = 5
local FLAME_HEIGHT_MIN = 2
local FLAME_HEIGHT_MAX = 12
-- Embers stay alive at idle so the band still reads as lit.
local HEAT_FLOOR = 0.12

-- Fixed, not role-derived. Fire is not a theme colour, and a theme whose primary is green
-- should still get fire.
local FLAME_STOPS = {
    { 0.00, 61, 15, 2 },
    { 0.28, 176, 42, 4 },
    { 0.58, 255, 106, 0 },
    { 0.82, 255, 179, 64 },
    { 1.00, 255, 233, 163 },
}

local M = {}

local initialMetrics = noctalia.state.get("metrics")
local initialGameMode = noctalia.state.get("game_mode")
local metrics = type(initialMetrics) == "table" and initialMetrics or { available = false }
local gameMode = type(initialGameMode) == "table" and initialGameMode or { enabled = false, suspended = {} }
local nonceCounter = 0
local flameField = {}
-- Rendered in the band slot when nothing is burning. Without it the live field would
-- freeze mid-flame the moment a flare ended and sit there as a static fire.
local coldField = {}
for i = 1, FLAME_COLUMNS do
    flameField[i] = 0
    coldField[i] = 0
end
local flareStartedMs = nil
local wasEnabled = gameMode.enabled == true

local function percent(fraction)
    return string.format("%d%%", math.floor((tonumber(fraction) or 0) * 100 + 0.5))
end

local function gibibytes(mib)
    return string.format("%.1fG", (tonumber(mib) or 0) / MIB_PER_GIB)
end

local function degrees(temp)
    return string.format("%d°", math.floor((tonumber(temp) or 0) + 0.5))
end

-- Bar space is scarce, so rates are unit-suffixed rather than spelled "KB/s". The panel
-- has room for the long form and uses it.
local function perSecond(bytes)
    local value = tonumber(bytes) or 0
    if value >= 1024 * 1024 * 1024 then
        return string.format("%.1fG", value / (1024 * 1024 * 1024))
    elseif value >= 1024 * 1024 then
        return string.format("%.1fM", value / (1024 * 1024))
    elseif value >= 1024 then
        return string.format("%.0fK", value / 1024)
    end
    return string.format("%.0fB", value)
end

-- Display order is fixed by the plugin; the settings only decide which rows appear.
-- `value` returns nil when the machine has nothing to report, which drops the segment
-- rather than printing a zero that reads like an idle device.
local SEGMENTS = {
    {
        id = "cpu", setting = "show_cpu", group = "cpu", glyph = "cpu-usage",
        activity = 0.50, critical = 0.90, heat = function(m) return m.cpuPerc end,
        value = function(m) return percent(m.cpuPerc) end,
    },
    {
        id = "cpu_temp", setting = "show_cpu_temp", group = "cpu", glyph = "cpu-temperature",
        activity = 60, critical = 85, heat = function(m) return m.cpuTemp end,
        value = function(m) return m.cpuTemp and degrees(m.cpuTemp) or nil end,
        tip = function(m) return m.cpuTemp and string.format("%d°C", math.floor(m.cpuTemp + 0.5)) or nil end,
    },
    {
        id = "ram", setting = "show_ram", group = "mem", glyph = "memory",
        activity = 0.60, critical = 0.90, heat = function(m) return m.memPerc end,
        value = function(m) return gibibytes(m.memUsedMb) end,
    },
    {
        id = "swap", setting = "show_swap", group = "mem", glyph = "storage",
        activity = 0.20, critical = 0.80, heat = function(m) return m.swapPerc end,
        value = function(m)
            if m.swapTotalMb and m.swapTotalMb > 0 then
                return percent(m.swapPerc)
            end
            return nil
        end,
    },
    {
        id = "gpu", setting = "show_gpu", group = "gpu", glyph = "gpu-usage",
        activity = 0.50, critical = 0.95, heat = function(m) return m.gpuPerc end,
        value = function(m)
            if m.gpuAvailable and m.gpuPerc then
                return percent(m.gpuPerc)
            end
            return nil
        end,
    },
    {
        id = "gpu_temp", setting = "show_gpu_temp", group = "gpu", glyph = "temperature",
        activity = 60, critical = 85, heat = function(m) return m.gpuTemp end,
        value = function(m) return m.gpuTemp and degrees(m.gpuTemp) or nil end,
        tip = function(m) return m.gpuTemp and string.format("%d°C", math.floor(m.gpuTemp + 0.5)) or nil end,
    },
    {
        id = "vram", setting = "show_vram", group = "gpu", glyph = "memory",
        activity = 0.50, critical = 0.90, heat = function(m) return m.vramPerc end,
        value = function(m) return m.vramUsedMb and gibibytes(m.vramUsedMb) or nil end,
    },
    {
        id = "load", setting = "show_load", group = "sys", glyph = "performance",
        value = function(m) return m.load1 and string.format("%.2f", m.load1) or nil end,
    },
    {
        id = "net_rx", setting = "show_net", group = "net", glyph = "download",
        activity = 1, critical = 50,
        heat = function(m) return m.netRxPerSec and m.netRxPerSec / 1000000 or nil end,
        value = function(m) return m.netRxPerSec and perSecond(m.netRxPerSec) or nil end,
    },
    {
        id = "net_tx", setting = "show_net", group = "net", glyph = "upload",
        activity = 1, critical = 50,
        heat = function(m) return m.netTxPerSec and m.netTxPerSec / 1000000 or nil end,
        value = function(m) return m.netTxPerSec and perSecond(m.netTxPerSec) or nil end,
    },
}

function M.readConfig()
    local function bool(key, default)
        local value = noctalia.getConfig(key)
        if value == nil then
            return default
        end
        return value ~= false
    end
    return {
        show_cpu = bool("show_cpu", true),
        show_cpu_temp = bool("show_cpu_temp", true),
        show_ram = bool("show_ram", true),
        show_swap = bool("show_swap", false),
        show_gpu = bool("show_gpu", true),
        show_gpu_temp = bool("show_gpu_temp", true),
        show_vram = bool("show_vram", false),
        show_load = bool("show_load", false),
        show_net = bool("show_net", true),
        show_glyphs = bool("show_glyphs", true),
        highlight_gamer_mode = bool("highlight_gamer_mode", true),
        flame = noctalia.getConfig("flame") or "flare",
        flame_style = noctalia.getConfig("flame_style") or "graph",
        -- Same key and same default as the shell's sysmon widget: zero, meaning the
        -- value hugs its text. Reserving width for the widest value a metric can reach
        -- is what made this readout permanently as wide as a saturated network link.
        label_min_width = math.max(0, tonumber(noctalia.getConfig("label_min_width")) or 0),
        flame_height = (function()
            local value = tonumber(noctalia.getConfig("flame_height")) or FLAME_HEIGHT_DEFAULT
            return math.max(FLAME_HEIGHT_MIN, math.min(FLAME_HEIGHT_MAX, math.floor(value)))
        end)(),
    }
end

-- The shell tints a sysmon value from its normal colour towards the highlight colour as
-- the metric climbs, holding flat below the activity threshold and saturating at the
-- critical one, with a jump to kActivityOnset the moment it crosses (sysmon_widget.cpp
-- gradientFactor). Same curve here so a grouped plugin readout warms in step with the
-- built-in widgets beside it.
local ACTIVITY_ONSET = 0.25

function M.gradientFactor(value, activity, critical)
    if value == nil or activity == nil or critical == nil then
        return 0
    end
    local v = math.max(value, 0)
    local top = math.max(critical, 0)
    if top <= 0 or v <= 0 then
        return 0
    end
    local floor = math.max(0, math.min(activity, top))
    if v <= floor then
        return 0
    end
    if v >= top then
        return 1
    end
    return ACTIVITY_ONSET + (1 - ACTIVITY_ONSET) * (v - floor) / (top - floor)
end

function M.formatSegments(m, config)
    m = m or {}
    local loading = not m.available
    local out = {}
    for _, segment in ipairs(SEGMENTS) do
        if config[segment.setting] then
            -- Before the first sample there is nothing to ask the machine about, so every
            -- enabled segment reserves its width with a placeholder. Once a sample lands,
            -- a nil value means the hardware is genuinely absent and the segment goes.
            local text = loading and PLACEHOLDER or segment.value(m)
            if text then
                out[#out + 1] = {
                    id = segment.id,
                    group = segment.group,
                    glyph = segment.glyph,
                    text = text,
                    -- Nothing has been sampled yet while loading, so nothing is hot.
                    tint = (not loading) and segment.heat
                        and M.gradientFactor(segment.heat(m), segment.activity, segment.critical)
                        or 0,
                    -- Marked so the renderer can dim them: a dash in the value colour
                    -- reads as data.
                    placeholder = loading,
                }
            end
        end
    end
    return out
end

-- The bar and the tooltip are complements: a segment the user put on the bar is left out
-- of the tooltip, so hovering always adds something.
function M.tooltipRows(m, gm, config)
    m = type(m) == "table" and m or {}
    local rows = {}
    if m.available then
        for _, segment in ipairs(SEGMENTS) do
            if not config[segment.setting] then
                local text = (segment.tip or segment.value)(m)
                if text then
                    rows[#rows + 1] = { key = noctalia.tr("widget." .. segment.id), value = text }
                end
            end
        end
    else
        rows[#rows + 1] = { key = noctalia.tr("widget.tooltip_loading"), value = PLACEHOLDER }
    end

    local validGm = type(gm) == "table" and gm or {}
    local suspended = type(validGm.suspended) == "table" and validGm.suspended or {}
    rows[#rows + 1] = {
        key = noctalia.tr("widget.gamer_mode"),
        value = validGm.enabled == true
            and noctalia.trp("widget.gamer_mode_on", #suspended)
            or noctalia.tr("widget.gamer_mode_off"),
    }
    return rows
end

-- How hard the machine is working, 0..1 -- the thing the flame reports. Usage leads,
-- because that is what a player feels; temperature follows, so a hot card at moderate
-- load still earns a hot flame.
function M.heatOf(m)
    if not (m and m.available) then
        return 0
    end
    local gpuUsage = 0
    if m.gpuAvailable and tonumber(m.gpuPerc) then
        gpuUsage = tonumber(m.gpuPerc)
    end
    local usage = math.max(tonumber(m.cpuPerc) or 0, gpuUsage)
    local hottest = math.max(tonumber(m.cpuTemp) or 0, tonumber(m.gpuTemp) or 0)
    local tempHeat = 0
    if hottest > 0 then
        tempHeat = math.max(0, math.min(1, (hottest - 50) / 40))
    end
    return math.max(0, math.min(1, usage * 0.7 + tempHeat * 0.3))
end

-- Scratch buffer for one step, reused so a 30fps loop allocates nothing.
local flameScratch = {}
for i = 1, FLAME_COLUMNS do
    flameScratch[i] = 0
end

-- Tongues are objects with a life, not one-frame spikes. A spark that is blurred away the
-- frame after it lands can never read as a flame; one that keeps injecting while it drifts
-- does. The pool is fixed and preallocated for the same reason as the scratch buffer.
local FLAME_SEEDS = 6
local flameSeeds = {}
for i = 1, FLAME_SEEDS do
    flameSeeds[i] = { pos = 0, life = 0, power = 0 }
end
local flameWind = 0
local flameWindPhase = 0

-- Lets a test start from a known field. Nothing in the widget calls this.
function M.resetFlame()
    flameWind = 0
    flameWindPhase = 0
    for i = 1, FLAME_SEEDS do
        local seed = flameSeeds[i]
        seed.pos, seed.life, seed.power = 0, 0, 0
    end
end

-- Reads outside the band as cold. Cyclic wraparound was why heat used to teleport from
-- one end to the other.
local function sampleField(index)
    if index < 1 or index > FLAME_COLUMNS then
        return 0
    end
    return flameScratch[index]
end

-- One step of a 1-D fire. Two sums of slowly moving sines give a wind that wanders
-- without ever repeating on a period short enough to notice; the field is advected along
-- it, blurred with a kernel that leans the same way, then sharpened to put back the peaks
-- the blur flattens. Sharpening is what turns a ridge into tongues.
function M.stepFlame(field, heat, dtMs)
    local dt = dtMs or 33
    local decay = math.min(1, dt * 0.0042)

    flameWindPhase = flameWindPhase + dt * 0.0009
    flameWind = math.sin(flameWindPhase) * 0.8 + math.sin(flameWindPhase * 2.3) * 0.35

    for i = 1, FLAME_COLUMNS do
        flameScratch[i] = field[i] or 0
    end

    local lean = math.max(-1, math.min(1, flameWind))
    local weightLeft = 0.16 + lean * 0.06
    local weightRight = 0.16 - lean * 0.06

    for i = 1, FLAME_COLUMNS do
        -- Fractional read from upwind: this is the advection.
        local source = i - flameWind
        local base = math.floor(source)
        local frac = source - base
        local shifted = sampleField(base) * (1 - frac) + sampleField(base + 1) * frac
        local blended = shifted * 0.66
            + sampleField(i - 1) * weightLeft
            + sampleField(i + 1) * weightRight
        local value = blended - decay * (0.5 + math.random() * 0.7)
        if value <= 0 then
            field[i] = 0
        else
            -- Gamma above 1 pushes midtones down and leaves peaks alone, so the tops
            -- separate from the body instead of melting into it.
            field[i] = math.min(1, value ^ 1.3)
        end
    end

    if heat <= 0 then
        return
    end

    for i = 1, FLAME_SEEDS do
        local seed = flameSeeds[i]
        if seed.life > 0 then
            seed.life = seed.life - dt
            seed.pos = seed.pos + flameWind * 0.35
            local index = math.floor(seed.pos + 0.5)
            if index >= 1 and index <= FLAME_COLUMNS then
                field[index] = math.min(1, field[index] + seed.power * dt * 0.02)
            end
        elseif math.random() < heat * 0.35 then
            seed.pos = math.random(1, FLAME_COLUMNS)
            seed.life = 120 + math.random() * 260
            seed.power = 0.45 + math.random() * 0.55 * heat
        end
    end
end

local function heatColor(value)
    local t = math.max(0, math.min(1, value))
    for i = 2, #FLAME_STOPS do
        local stop = FLAME_STOPS[i]
        if t <= stop[1] then
            local previous = FLAME_STOPS[i - 1]
            local k = (t - previous[1]) / (stop[1] - previous[1])
            return string.format(
                "#%02x%02x%02x",
                math.floor(previous[2] + (stop[2] - previous[2]) * k),
                math.floor(previous[3] + (stop[3] - previous[3]) * k),
                math.floor(previous[4] + (stop[4] - previous[4]) * k)
            )
        end
    end
    return "#ffe9a3"
end

-- graph is one node whatever the width. bars draws a box per column, which looks crisper
-- close up and costs 28 times as much to reconcile.
function M.flameBand(field, style, height)
    local band = height or FLAME_HEIGHT_DEFAULT
    if style ~= "bars" then
        local outer, inner = {}, {}
        for i = 1, FLAME_COLUMNS do
            outer[i] = field[i]
            inner[i] = field[i] * 0.55
        end
        return ui.graph({
            values = outer,
            values2 = inner,
            color = "#ff6a00",
            color2 = "#ffd27a",
            fillOpacity = 1.0,
            height = band,
        })
    end

    local bars = {}
    for i = 1, FLAME_COLUMNS do
        bars[i] = ui.box({
            flexGrow = 1,
            height = math.max(1, field[i] * band),
            fill = heatColor(field[i]),
            radius = 1,
        })
    end
    -- align = "end" puts them on a baseline so they grow upward.
    return ui.row({ align = "end", gap = 1, height = band }, bars)
end

-- The shell warms a sysmon value from its normal colour towards the highlight colour
-- (`error` by default) as the metric climbs. It lerps in HSV; a plugin can only name
-- colours, so the ramp runs through the role's alpha instead -- the same direction over
-- the same thresholds, on a coarser road.
local function valueColor(segment)
    if segment.placeholder then
        -- A placeholder in the value colour reads as data; dim it so loading reads as
        -- loading.
        return "on_surface_variant"
    end
    if segment.tint <= 0 then
        return "on_surface"
    end
    -- The floor is high on purpose. Alpha is the only ramp available, and a low floor
    -- makes the value *dimmer* the moment it crosses its activity threshold -- the
    -- opposite of what the threshold is for.
    return string.format("error/%.2f", 0.80 + 0.20 * segment.tint)
end

-- Glyph and value share the colour, as they do in the shell: syncValueColor tints both
-- from one currentValueColor unless an explicit icon_color overrides it.
local function segmentNode(segment, config)
    local children = {}
    if config.show_glyphs then
        children[#children + 1] = ui.glyph({ name = segment.glyph, size = 13, color = valueColor(segment) })
    end
    local label = ui.label({ text = segment.text, color = valueColor(segment) })
    if config.label_min_width > 0 then
        -- ui.label takes width (a hard clamp) and maxWidth but no minWidth, so the
        -- reservation goes on a wrapper flex, which has one. justify = "end" keeps the
        -- digits against the right of the reserved space, so they grow leftwards instead
        -- of shoving their neighbour.
        label = ui.row({ minWidth = config.label_min_width, justify = "end" }, { label })
    end
    children[#children + 1] = label
    return ui.row({ align = "center", gap = 3 }, children)
end

-- Segments of the same group sit close together and groups sit further apart, which is
-- what makes three clusters read as three clusters rather than one run of numbers.
--
-- Nothing here paints a background. The shell's sysmon widget draws no pill either: with
-- `capsule = true` the bar wraps the widget in one, and drawing our own only fought it.
-- The flame band is the whole of what this widget adds on top of a sysmon readout.
function M.buildTree(m, gm, config, vertical, burning)
    local segments = M.formatSegments(m, config)

    if vertical then
        -- A vertical bar is ~26px wide, so a horizontal readout would clip. Segments
        -- stack glyph over value, centred.
        local rows = {}
        for _, segment in ipairs(segments) do
            local cell = {}
            if config.show_glyphs then
                cell[#cell + 1] = ui.glyph({ name = segment.glyph, size = 13, color = valueColor(segment) })
            end
            cell[#cell + 1] = ui.label({
                text = segment.text,
                textAlign = "center",
                color = valueColor(segment),
            })
            rows[#rows + 1] = ui.column({ align = "center", gap = 0 }, cell)
        end
        return ui.column({ align = "center", gap = 2 }, rows)
    end

    local groups = {}
    local currentId = nil
    local current = nil
    for _, segment in ipairs(segments) do
        if segment.group ~= currentId then
            current = {}
            groups[#groups + 1] = current
            currentId = segment.group
        end
        current[#current + 1] = segmentNode(segment, config)
    end

    local children = {}
    for _, group in ipairs(groups) do
        children[#children + 1] = ui.row({ align = "center", gap = 6 }, group)
    end
    local readout = ui.row({ align = "center", gap = 12 }, children)

    -- The band's slot is reserved whenever the flame could appear, not only while it
    -- burns, so toggling gamer mode never moves a digit. It is reserved *symmetrically* --
    -- an empty spacer above matching the band below -- because a band on one side only
    -- pushes the readout off the pill's centre by half its height, and on a 42px bar that
    -- put the digits against the top edge with the flame hanging outside the pill.
    --
    -- The cost is that the band can only be half of whatever the pill has spare, which is
    -- why the default is small. The shell's capsule_thickness is the lever: it decides the
    -- pill's height, and a taller pill affords a taller flame.
    if not (config.highlight_gamer_mode and config.flame ~= "off") then
        return readout
    end

    local lit = gm and gm.enabled and burning ~= nil
    return ui.column({ gap = 0 }, {
        ui.spacer({ height = config.flame_height }),
        readout,
        M.flameBand(lit and flameField or coldField, config.flame_style, config.flame_height),
    })
end

-- The flare's shape over its 900ms life: ease-in to the peak, then ease-out cubic to
-- nothing. The cubic is what gives the long ember tail -- its slope is steepest right
-- after the peak and almost flat by the end, so the last third of the time covers only a
-- few percent of the intensity.
function M.flareIntensity(elapsedMs, peak)
    local t = tonumber(elapsedMs) or 0
    local top = math.max(0, tonumber(peak) or 0)
    if t < 0 or t >= FLARE_DURATION_MS or top <= 0 then
        return 0
    end
    if t < IGNITE_MS then
        local k = t / IGNITE_MS
        return top * k * k
    end
    local k = (t - IGNITE_MS) / (FLARE_DURATION_MS - IGNITE_MS)
    local inv = 1 - k
    return top * inv * inv * inv
end

local function burningLevel(config)
    if barWidget.isVertical() or config.flame == "off" then
        return nil
    end
    if not (config.highlight_gamer_mode and gameMode.enabled) then
        return nil
    end
    local heat = HEAT_FLOOR + M.heatOf(metrics) * (1 - HEAT_FLOOR)
    if config.flame == "always" then
        return heat
    end
    if flareStartedMs == nil then
        return nil
    end
    local elapsed = noctalia.nowMs() - flareStartedMs
    if elapsed >= FLARE_DURATION_MS then
        return nil
    end
    -- The flare opens hot whatever the load, then follows the envelope down.
    return M.flareIntensity(elapsed, math.max(heat, 0.75))
end

local function render()
    local config = M.readConfig()
    local burning = burningLevel(config)
    if burning ~= nil then
        M.stepFlame(flameField, burning, FLARE_INTERVAL_MS)
    end
    barWidget.render(M.buildTree(metrics, gameMode, config, barWidget.isVertical(), burning))
    barWidget.setTooltip(M.tooltipRows(metrics, gameMode, config))
end

noctalia.state.watch("metrics", function(value)
    metrics = type(value) == "table" and value or { available = false }
    render()
end)

noctalia.state.watch("game_mode", function(value)
    gameMode = type(value) == "table" and value or { enabled = false, suspended = {} }
    local config = M.readConfig()
    local enabled = gameMode.enabled == true
    local horizontal = not barWidget.isVertical()

    if enabled and not wasEnabled and config.highlight_gamer_mode and horizontal then
        if config.flame == "flare" then
            flareStartedMs = noctalia.nowMs()
            noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
        elseif config.flame == "always" then
            noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
        end
    elseif not enabled and wasEnabled then
        flareStartedMs = nil
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
    end

    wasEnabled = enabled
    render()
end)

-- ── shell entry points (must be globals) ──

function onClick()
    if (noctalia.getConfig("click_action") or "open_panel") == "toggle" then
        nonceCounter = nonceCounter + 1
        noctalia.state.set("command", { nonce = noctalia.nowMs() * 1000 + nonceCounter, action = "toggle" })
    else
        noctalia.togglePanel(PANEL_ID)
    end
end

function onRightClick()
    nonceCounter = nonceCounter + 1
    noctalia.state.set("command", { nonce = noctalia.nowMs() * 1000 + nonceCounter, action = "toggle" })
end

-- Called by the shell on its timer. It does nothing at all unless something is burning,
-- which is what keeps the idle cost to one no-op call a second.
function update()
    local config = M.readConfig()
    if barWidget.isVertical() then
        flareStartedMs = nil
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
        return
    end
    if config.flame == "always" and gameMode.enabled and config.highlight_gamer_mode then
        render()
        return
    end
    if flareStartedMs == nil then
        return
    end
    if noctalia.nowMs() - flareStartedMs >= FLARE_DURATION_MS then
        flareStartedMs = nil
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
    end
    render()
end

function onConfigChanged()
    local config = M.readConfig()
    if barWidget.isVertical() or config.flame == "off" or not (gameMode.enabled and config.highlight_gamer_mode) then
        flareStartedMs = nil
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
    elseif config.flame == "always" then
        noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
    elseif flareStartedMs == nil then
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
    end
    render()
end

noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
-- `always` is a free-running loop, not an edge: gamer mode may already be on when the
-- widget loads, and no transition will fire to start it.
local bootConfig = M.readConfig()
if not barWidget.isVertical()
        and bootConfig.flame == "always"
        and gameMode.enabled
        and bootConfig.highlight_gamer_mode then
    noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
end
render()

return M
