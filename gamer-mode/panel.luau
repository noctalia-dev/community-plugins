--!nonstrict
--
-- Gamer Mode panel. Like the widget it owns no state: it renders what the service
-- publishes and sends commands back through `noctalia.state`.
--
-- Interactive props (onClick/onChange) must be the *names* of global functions -- the
-- ui bridge resolves handlers by name and cannot call a Lua closure.

local MIB_PER_GIB = 1024

-- The panel is wide enough that a control stretched across it reads badly: a select
-- holding the word "balanced" does not want four hundred pixels. The label takes the left,
-- a spacer eats the slack, and the control keeps a fixed, readable width on the right.
local CONTROL_LABEL_WIDTH = 130
local CONTROL_WIDTH = 200

local M = {}

local metrics = noctalia.state.get("metrics") or { available = false }
local gameMode = noctalia.state.get("game_mode") or { enabled = false, busy = false, suspended = {} }
local power = noctalia.state.get("power") or { available = false, profiles = {} }
local cleanup = noctalia.state.get("cleanup") or {}
local nonceCounter = 0

-- The logo is embedded rather than read from the plugin directory because there is no API
-- that reports where that directory is: the materialised path contains the name of the
-- source the plugin was installed from, which differs per machine. The data directory is
-- reported, so the file is written there once and referenced from disk.
--
-- gamer-mode/logo-dark.svg and logo-light.svg hold the same bytes and are the copies to
-- edit; tests/logo.lua fails if any of them drift apart. Two files rather than one that
-- gets rewritten: the shell caches textures by {path, targetSize}, so overwriting a
-- single path would keep serving the previous theme's raster after a theme flip.
local LOGO_SVG_DARK = [==[
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="100%" height="100%">
  <defs>
    <linearGradient id="body" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#B3200E"/>
      <stop offset="0.45" stop-color="#F0630A"/>
      <stop offset="1" stop-color="#FFC02E"/>
    </linearGradient>
    <linearGradient id="core" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#FFB020"/>
      <stop offset="1" stop-color="#FFF3B0"/>
    </linearGradient>
  </defs>
  <path fill="url(#body)" d="M32 4 C 38 18, 50 24, 50 38 A 18 18 0 0 1 14 38 C 14 27, 22 24, 24 14 C 29 19, 30 27, 28 33 C 31 28, 33 16, 32 4 Z"/>
  <path fill="url(#core)" d="M32 30 C 36 36, 40 39, 40 44 A 8 8 0 0 1 24 44 C 24 39, 29 36, 32 30 Z"/>
</svg>
]==]

-- Deeper stops so the mark still has contrast against a light surface. The palette is
-- not readable from a plugin, so this is a fixed pair rather than a derived colour.
local LOGO_SVG_LIGHT = [==[
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="100%" height="100%">
  <defs>
    <linearGradient id="body" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#8C1408"/>
      <stop offset="0.45" stop-color="#D24A05"/>
      <stop offset="1" stop-color="#E89100"/>
    </linearGradient>
    <linearGradient id="core" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#E08A00"/>
      <stop offset="1" stop-color="#FFD867"/>
    </linearGradient>
  </defs>
  <path fill="url(#body)" d="M32 4 C 38 18, 50 24, 50 38 A 18 18 0 0 1 14 38 C 14 27, 22 24, 24 14 C 29 19, 30 27, 28 33 C 31 28, 33 16, 32 4 Z"/>
  <path fill="url(#core)" d="M32 30 C 36 36, 40 39, 40 44 A 8 8 0 0 1 24 44 C 24 39, 29 36, 32 30 Z"/>
</svg>
]==]

-- Distinct filenames per variant, never one path rewritten: the texture cache is keyed by
-- {path, targetSize}, so overwriting one file would keep serving the old theme's raster.
function M.logoVariant(dark)
    return dark and "logo-dark.svg" or "logo-light.svg"
end

local function logoPath()
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    -- There is no theme-change callback, so the variant is resolved on every render. It is
    -- a filename choice and a fileExists in the common case.
    local dark = noctalia.isDarkMode() ~= false
    local path = directory .. "/" .. M.logoVariant(dark)
    if not noctalia.fileExists(path) then
        if not noctalia.writeFile(path, dark and LOGO_SVG_DARK or LOGO_SVG_LIGHT) then
            noctalia.log("gamermode: could not write the panel logo")
            return nil
        end
    end
    return path
end

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function clamp(value)
    local number = tonumber(value) or 0
    return math.max(0, math.min(1, number))
end

local function percent(fraction)
    return string.format("%d%%", math.floor(clamp(fraction) * 100 + 0.5))
end

local function gibibytes(mib)
    return (tonumber(mib) or 0) / MIB_PER_GIB
end

local function usedOfTotal(usedMib, totalMib)
    return string.format("%.1f / %.1f GiB", gibibytes(usedMib), gibibytes(totalMib))
end

local function withTemp(detail, showTemps, temp)
    if showTemps and tonumber(temp) then
        return detail .. string.format("   %d°C", math.floor(tonumber(temp) + 0.5))
    end
    return detail
end

-- buildRows produces one entry per reading the machine actually reports. Unsupported
-- readings are absent rather than drawn as an empty bar, which would look like a real
-- idle reading.
-- The shell tints a sysmon value from its normal colour towards the highlight colour as
-- the metric climbs, holding flat below the activity threshold and saturating at the
-- critical one, with a jump to kActivityOnset the moment it crosses (sysmon_widget.cpp
-- gradientFactor). Duplicated from monitor.luau rather than shared: plugin entries run in
-- separate sandboxed Luau states with no `require`.
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

-- Every row's `progress` is already the fraction the shell would gradient on, so the bar
-- and the reading cannot disagree.
function M.barFill(row)
    local tint = M.gradientFactor(row.progress, row.activity, row.critical)
    if tint <= 0 then
        return "primary"
    end
    return string.format("error/%.2f", 0.80 + 0.20 * tint)
end

function M.buildRows(m, showTemps)
    local rows = {}
    if type(m) ~= "table" or not m.available then
        return rows
    end

    rows[#rows + 1] = {
        label = "CPU",
        glyph = "cpu-usage",
        progress = clamp(m.cpuPerc),
            activity = 0.50,
            critical = 0.90,
        detail = withTemp(percent(m.cpuPerc), showTemps, m.cpuTemp),
    }
    rows[#rows + 1] = {
        label = "RAM",
        glyph = "memory",
        progress = clamp(m.memPerc),
            activity = 0.60,
            critical = 0.90,
        detail = usedOfTotal(m.memUsedMb, m.memTotalMb),
    }

    -- Swap only when the machine has some. A zero total is not a bar at 0%, it is a
    -- machine with swap turned off, and drawing it would invite a reading that is not
    -- there.
    if m.swapTotalMb and m.swapTotalMb > 0 then
        rows[#rows + 1] = {
            label = "Swap",
            glyph = "storage",
            progress = clamp(m.swapPerc),
            activity = 0.20,
            critical = 0.80,
            detail = usedOfTotal(m.swapUsedMb, m.swapTotalMb),
        }
    end

    if m.gpuAvailable and m.gpuPerc then
        rows[#rows + 1] = {
            label = "GPU",
            glyph = "gpu-usage",
            progress = clamp(m.gpuPerc),
            activity = 0.50,
            critical = 0.95,
            detail = withTemp(percent(m.gpuPerc), showTemps, m.gpuTemp),
        }
    end
    if m.vramUsedMb and m.vramTotalMb then
        rows[#rows + 1] = {
            label = "VRAM",
            glyph = "storage",
            progress = clamp(m.vramPerc),
            activity = 0.50,
            critical = 0.90,
            detail = usedOfTotal(m.vramUsedMb, m.vramTotalMb),
        }
    end
    return rows
end

local function perSecond(bytes)
    local value = tonumber(bytes) or 0
    if value >= 1024 * 1024 then
        return string.format("%.1f MB/s", value / (1024 * 1024))
    elseif value >= 1024 then
        return string.format("%.0f KB/s", value / 1024)
    end
    return string.format("%.0f B/s", value)
end

-- Readings that are not a proportion of anything. Load average needs a core count to
-- become a percentage and the shell does not report one; a network rate has no ceiling to
-- measure against. Both are shown as figures rather than invented into bars.
function M.buildFigures(m)
    local figures = {}
    if type(m) ~= "table" or not m.available then
        return figures
    end
    if m.load1 and m.load5 and m.load15 then
        figures[#figures + 1] = {
            label = tr("panel.load"),
            glyph = "performance",
            detail = string.format("%.2f   %.2f   %.2f", m.load1, m.load5, m.load15),
        }
    end
    if m.netRxPerSec and m.netTxPerSec then
        figures[#figures + 1] = {
            label = tr("panel.network"),
            glyph = "antenna-bars-5",
            detail = perSecond(m.netRxPerSec) .. "   " .. perSecond(m.netTxPerSec),
        }
    end
    return figures
end

function M.suspendedLines(gm)
    local lines = {}
    for _, target in ipairs((type(gm) == "table" and gm.suspended) or {}) do
        -- Frozen and stopped are materially different to a user reading this list: one
        -- resumes exactly where it left off, the other was shut down and restarted.
        local state = target.action == "freeze" and tr("panel.frozen") or tr("panel.stopped")
        lines[#lines + 1] = string.format("%s (%s, %s)", tostring(target.match), tostring(target.kind), state)
    end
    return lines
end

-- M.powerProfileAt resolves the zero-based index the select reports back to a profile
-- name, or nil when the index no longer matches the published list.
function M.powerProfileAt(index)
    local position = (tonumber(index) or -1) + 1
    local profiles = (type(power) == "table" and power.profiles) or {}
    return profiles[position]
end

-- ── suspend profile ──

local SUSPEND_PROFILES = { "light", "heavy" }

function M.suspendProfiles()
    return { SUSPEND_PROFILES[1], SUSPEND_PROFILES[2] }
end

-- The chosen profile travels with the enable command rather than changing the setting,
-- because a plugin reads its own settings and cannot write them. It starts from whatever
-- the setting says and then lives as long as the loaded panel entry, which outlives any
-- one opening of the panel but not a shell restart or a plugin reload.
--
-- The bar's right-click toggle cannot see this: the widget is a separate entry with its
-- own state, so it enables the profile named in the settings. Selecting here and then
-- right-clicking the icon is the one path where the two disagree.
local selectedProfileName = nil

function M.selectedProfile()
    if selectedProfileName then
        return selectedProfileName
    end
    local configured = noctalia.getConfig("profile")
    return configured == "heavy" and "heavy" or "light"
end

function M.selectSuspendProfile(index)
    local name = SUSPEND_PROFILES[(tonumber(index) or -1) + 1]
    if not name then
        noctalia.log("gamermode: ignoring an out-of-range suspend profile selection")
        return false
    end
    selectedProfileName = name
    return true
end

local function selectedSuspendIndex()
    local current = M.selectedProfile()
    for index, name in ipairs(SUSPEND_PROFILES) do
        if name == current then
            return index - 1
        end
    end
    return 0
end

local function selectedPowerIndex()
    for index, profile in ipairs(power.profiles or {}) do
        if profile == power.active then
            return index - 1
        end
    end
    return 0
end

-- ── rendering ──

-- One builder for readings with a bar and readings without. After the hierarchy pass the
-- two differed only by the progress node, and keeping two copies meant every colour
-- decision had to be made twice.
local function readingRow(entry, withBar)
    local line = ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = entry.glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = entry.label, color = "on_surface_variant", width = 48 }),
        -- A spacer pushes the detail right. `align` is not a label prop: setting it left
        -- the text unaligned and the shell logged a warning on every render.
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = entry.detail, color = "on_surface", fontSize = 11 }),
    })
    if not withBar then
        return line
    end
    return ui.column({ gap = 4 }, {
        line,
        ui.progress({
            height = 4,
            progress = entry.progress,
            fill = M.barFill(entry),
            track = "surface_variant",
            radius = 2,
        }),
    })
end

-- How hard the machine is working, 0..1, mirroring monitor.luau's heatOf. Usage leads
-- because that is what a player feels; temperature follows. cpuPerc/gpuPerc are 0..1
-- fractions, matching what the service publishes.
local function heatOf(m)
    if not (type(m) == "table" and m.available) then
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

local haloPhase = 0

-- A ring, not a bloom. Nothing can be drawn behind the mark -- the tree is pure flexbox
-- with no stack or z-index -- so the halo is ui.image's own border, animated per frame.
-- Hex rather than a role token because fire is not a theme colour.
function M.haloSpec(phase, heat)
    local hot = math.max(0, math.min(1, tonumber(heat) or 0))
    local pulse = 0.5 + 0.5 * math.sin(tonumber(phase) or 0)
    local intensity = 0.25 + 0.75 * hot
    local alpha = math.floor((0.20 + 0.55 * intensity * pulse) * 255 + 0.5)
    local green = math.floor(90 + 110 * hot + 0.5)
    local blue = math.floor(20 + 40 * hot * pulse + 0.5)
    return {
        border = string.format("#%02x%02x%02x%02x", 255, green, blue, alpha),
        borderWidth = 1 + 2 * intensity * pulse,
    }
end

-- A soft bar under the header that breathes. ui.box's softness is what keeps it from
-- reading as a second separator; a hard 2px rule there just looks like a mistake.
function M.emberSpec(phase, heat)
    local hot = math.max(0, math.min(1, tonumber(heat) or 0))
    local pulse = 0.5 + 0.5 * math.sin(tonumber(phase) or 0)
    local opacity = 0.18 + 0.42 * (0.3 + 0.7 * hot) * pulse
    return {
        fill = string.format("#ff%02x1e", math.floor(90 + 110 * hot + 0.5)),
        opacity = math.max(0, math.min(1, opacity)),
        softness = 2 + 2 * hot,
    }
end

-- Vsync ticks are coalesced and stop dead while the panel is closed, but they are still a
-- cost, so they are only asked for while there is something to animate.
local function syncFrameTick()
    if panel.setNeedsFrameTick then
        panel.setNeedsFrameTick(gameMode.enabled == true)
    end
end

local function toggleButton()
    if gameMode.busy then
        return ui.button({ text = tr("panel.working"), enabled = false, variant = "ghost" })
    end
    return ui.button({
        text = gameMode.enabled and tr("panel.disable") or tr("panel.enable"),
        glyph = gameMode.enabled and "player-stop-filled" or "player-play-filled",
        selected = gameMode.enabled,
        onClick = "onToggleGameMode",
    })
end

local function header()
    local logo = logoPath()
    local mark
    if logo then
        -- radius is set unconditionally: putting it inside the branch would pop the mark
        -- between square and circular every time the mode is toggled.
        local props = { path = logo, width = 42, height = 42, fit = "contain", radius = 21 }
        if gameMode.enabled then
            local halo = M.haloSpec(haloPhase, heatOf(metrics))
            props.border = halo.border
            props.borderWidth = halo.borderWidth
        end
        mark = ui.image(props)
    else
        -- The glyph is the fallback for the one case that can fail: no plugin data
        -- directory to write the logo into.
        mark = ui.glyph({ name = "device-gamepad-2", size = 22, color = "primary" })
    end

    return ui.row({ align = "center", gap = 10 }, {
        mark,
        ui.column({ gap = 0, flexGrow = 1 }, {
            ui.label({ text = tr("panel.title"), fontSize = 17, fontWeight = "bold" }),
            ui.label({
                text = gameMode.enabled and tr("panel.state_on") or tr("panel.state_off"),
                fontSize = 11,
                color = gameMode.enabled and "primary" or "on_surface_variant",
            }),
        }),
        toggleButton(),
        -- The panel also dismisses on an outside click, but a visible control is the one
        -- people look for, and every other panel in the shell has one.
        ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.close"), onClick = "onCloseClicked" }),
    })
end

-- ── maintenance ──

-- Deleting the shader caches is the one action here that destroys something, so the button
-- asks first and names the size it is about to remove.
local shadersArmed = false

local function maintenanceSection(children)
    children[#children + 1] = ui.separator({})
    children[#children + 1] = ui.label({
        text = tr("cleanup.title"),
        color = "on_surface_variant",
        fontSize = 12,
        fontWeight = "bold",
    })

    local working = cleanup.running ~= nil
    children[#children + 1] = ui.row({ gap = 8 }, {
        ui.button({
            -- The size arrives from the service, which measured it when the button armed.
            text = shadersArmed and tr("cleanup.shaders_confirm", { size = cleanup.shaderSize or "?" })
                or tr("cleanup.shaders"),
            glyph = shadersArmed and "alert-triangle" or "storage",
            variant = shadersArmed and "primary" or "ghost",
            selected = shadersArmed,
            enabled = not working,
            flexGrow = 1,
            onClick = "onClearShaders",
        }),
    })
    children[#children + 1] = ui.row({ gap = 8 }, {
        ui.button({
            text = tr("cleanup.pagecache"),
            glyph = "memory",
            variant = "ghost",
            enabled = not working,
            flexGrow = 1,
            onClick = "onDropPageCache",
        }),
        ui.button({
            text = tr("cleanup.swap"),
            glyph = "performance",
            variant = "ghost",
            enabled = not working,
            flexGrow = 1,
            onClick = "onReclaimSwap",
        }),
    })

    if type(cleanup.message) == "string" and cleanup.message ~= "" then
        children[#children + 1] = ui.label({
            text = cleanup.message,
            fontSize = 11,
            color = cleanup.ok == false and "error" or "on_surface_variant",
        })
    end
end

local function powerRow()
    if not power.available then
        return ui.label({ text = tr("panel.power_unavailable"), color = "on_surface_variant", fontSize = 11 })
    end
    return ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.power_profile"), color = "on_surface_variant", width = CONTROL_LABEL_WIDTH }),
        ui.spacer({ flexGrow = 1 }),
        ui.select({
            options = power.profiles,
            selectedIndex = selectedPowerIndex(),
            width = CONTROL_WIDTH,
            onChange = "onPowerProfileChanged",
        }),
    })
end

-- While gamer mode runs, the profile in force is whatever the session recorded, so the
-- selector gives way to a plain label. Picking a different profile means disabling first.
local function modeProfileRow()
    if gameMode.enabled then
        return ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("panel.mode_profile"), color = "on_surface_variant", width = CONTROL_LABEL_WIDTH }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = tr("panel.profiles." .. tostring(gameMode.profile or "light")), width = CONTROL_WIDTH }),
        })
    end
    local options = {}
    for index, name in ipairs(M.suspendProfiles()) do
        options[index] = tr("panel.profiles." .. name)
    end
    return ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.mode_profile"), color = "on_surface_variant", width = CONTROL_LABEL_WIDTH }),
        ui.spacer({ flexGrow = 1 }),
        ui.select({
            options = options,
            selectedIndex = selectedSuspendIndex(),
            width = CONTROL_WIDTH,
            onChange = "onSuspendProfileChanged",
        }),
    })
end

local function sectionLabel(key, count)
    local text = tr(key)
    if count then
        text = text .. "  (" .. tostring(count) .. ")"
    end
    return ui.label({ text = text, color = "on_surface_variant", fontSize = 12, fontWeight = "bold" })
end

local function suspendedSection(children)
    if not gameMode.enabled then
        return
    end
    children[#children + 1] = ui.separator({})
    local lines = M.suspendedLines(gameMode)
    children[#children + 1] = sectionLabel("panel.suspended", #lines > 0 and #lines or nil)
    if #lines == 0 then
        children[#children + 1] = ui.label({ text = tr("panel.nothing_suspended"), fontSize = 11 })
        return
    end
    for _, line in ipairs(lines) do
        children[#children + 1] = ui.label({ text = line, fontSize = 11, color = "on_surface_variant" })
    end
end

local function body()
    local showTemps = noctalia.getConfig("show_temps") ~= false
    local children = {}

    if gameMode.enabled then
        local ember = M.emberSpec(haloPhase, heatOf(metrics))
        children[#children + 1] = ui.box({
            height = 2,
            radius = 1,
            fill = ember.fill,
            opacity = ember.opacity,
            softness = ember.softness,
        })
    end

    local rows = M.buildRows(metrics, showTemps)
    if #rows == 0 then
        children[#children + 1] = ui.label({
            text = tr("panel.metrics_unavailable"),
            color = "on_surface_variant",
            fontSize = 11,
        })
    else
        children[#children + 1] = sectionLabel("panel.performance")
        for _, row in ipairs(rows) do
            children[#children + 1] = readingRow(row, true)
        end
        for _, figure in ipairs(M.buildFigures(metrics)) do
            children[#children + 1] = readingRow(figure, false)
        end
        if not metrics.gpuAvailable then
            children[#children + 1] = ui.label({
                text = tr("panel.gpu_unsupported"),
                color = "on_surface_variant",
                fontSize = 11,
            })
        end
    end

    children[#children + 1] = ui.separator({})
    children[#children + 1] = powerRow()
    children[#children + 1] = modeProfileRow()
    suspendedSection(children)
    maintenanceSection(children)

    return ui.column({ gap = 12, flexGrow = 1 }, children)
end

local function footer()
    return ui.row({ align = "center", gap = 8 }, {
        ui.spacer({ flexGrow = 1 }),
        ui.button({ text = tr("panel.settings"), glyph = "plugin", variant = "ghost", onClick = "onOpenSettings" }),
    })
end

local function render()
    panel.render(ui.column({ padding = 20, gap = 14, flexGrow = 1 }, {
        header(),
        ui.scroll({ flexGrow = 1, gap = 12 }, { body() }),
        footer(),
    }))
end

local function sendCommand(action, extra)
    nonceCounter = nonceCounter + 1
    local command = { nonce = noctalia.nowMs() * 1000 + nonceCounter, action = action }
    for key, value in pairs(extra or {}) do
        command[key] = value
    end
    noctalia.state.set("command", command)
end

-- ── shell entry points (must be globals) ──

function onOpen()
    metrics = noctalia.state.get("metrics") or metrics
    gameMode = noctalia.state.get("game_mode") or gameMode
    power = noctalia.state.get("power") or power
    render()
    -- Watchers fire on change, so opening the panel while gamer mode is already on would
    -- otherwise leave the halo frozen until the next toggle.
    syncFrameTick()
end

-- Called at vsync while the panel is open and something is animating. Advancing a phase
-- and re-rendering is the whole of it; the halo and the ember are pure functions of it.
function onFrameTick(deltaMs)
    if not gameMode.enabled then
        return
    end
    haloPhase = (haloPhase + (tonumber(deltaMs) or 16) * 0.0025) % (math.pi * 2)
    render()
end

-- The command carries the chosen profile so one button both picks and applies. Disabling
-- ignores it: the session already records which profile was in force.
function onToggleGameMode()
    sendCommand("toggle", { profile = M.selectedProfile() })
end

function onSuspendProfileChanged(index)
    if M.selectSuspendProfile(index) then
        render()
    end
end

function onPowerProfileChanged(index)
    local profile = M.powerProfileAt(index)
    if not profile then
        noctalia.log("gamermode: ignoring an out-of-range power profile selection")
        return
    end
    sendCommand("set-power-profile", { profile = profile })
end

function onOpenSettings()
    noctalia.openSettings()
end

-- The first click measures and arms; the second deletes. Anything else the user does in
-- the panel is a chance to have changed their mind, so the arming does not persist past a
-- different cleanup being started.
function onClearShaders()
    if shadersArmed then
        shadersArmed = false
        sendCommand("cleanup", { job = "shaders" })
    else
        shadersArmed = true
        sendCommand("cleanup", { job = "shaders-measure" })
    end
    render()
end

function onDropPageCache()
    shadersArmed = false
    sendCommand("cleanup", { job = "pagecache" })
    render()
end

function onReclaimSwap()
    shadersArmed = false
    sendCommand("cleanup", { job = "swap" })
    render()
end

function onCloseClicked()
    panel.close()
end

noctalia.state.watch("metrics", function(value)
    metrics = type(value) == "table" and value or { available = false }
    render()
end)

noctalia.state.watch("game_mode", function(value)
    gameMode = type(value) == "table" and value or { enabled = false, busy = false, suspended = {} }
    syncFrameTick()
    render()
end)

noctalia.state.watch("power", function(value)
    power = type(value) == "table" and value or { available = false, profiles = {} }
    render()
end)

noctalia.state.watch("cleanup", function(value)
    cleanup = type(value) == "table" and value or {}
    render()
end)

return M
