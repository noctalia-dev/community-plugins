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
-- gamer-mode/logo.svg holds the same bytes and is the copy to edit; tests/logo.lua fails
-- if the two drift apart.
local LOGO_SVG = [==[
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="100%" height="100%">
  <defs>
    <linearGradient id="outerFlame" x1="0%" y1="100%" x2="0%" y2="0%">
      <stop offset="0%" stop-color="#C0392B"/>
      <stop offset="100%" stop-color="#E74C3C"/>
    </linearGradient>
    <linearGradient id="midFlame" x1="0%" y1="100%" x2="0%" y2="0%">
      <stop offset="0%" stop-color="#E67E22"/>
      <stop offset="100%" stop-color="#F39C12"/>
    </linearGradient>
    <linearGradient id="innerFlame" x1="0%" y1="100%" x2="0%" y2="0%">
      <stop offset="0%" stop-color="#F1C40F"/>
      <stop offset="100%" stop-color="#FFEB3B"/>
    </linearGradient>
  </defs>

  <path fill="url(#outerFlame)" d="M 120 280 C 100 220, 110 170, 150 130 C 170 110, 180 70, 170 40 C 210 70, 230 110, 240 150 C 260 100, 290 60, 330 80 C 370 100, 360 150, 390 180 C 410 200, 420 240, 390 290 Z"/>
  <path fill="url(#midFlame)" d="M 140 280 C 130 230, 145 190, 175 160 C 195 140, 210 100, 210 80 C 235 115, 250 150, 265 175 C 285 130, 315 105, 340 120 C 370 140, 355 185, 375 210 C 390 230, 395 260, 375 290 Z"/>
  <path fill="url(#innerFlame)" d="M 170 280 C 160 240, 180 210, 200 185 C 215 165, 225 130, 230 115 C 245 145, 260 175, 275 195 C 290 160, 310 145, 325 155 C 345 170, 335 210, 350 235 C 360 250, 360 270, 345 280 Z"/>

  <rect x="90" y="235" width="16" height="175" rx="4" fill="#7F8C8D"/>
  <rect x="84" y="245" width="6" height="25" rx="2" fill="#95A5A6"/>
  <rect x="84" y="365" width="6" height="25" rx="2" fill="#95A5A6"/>

  <rect x="160" y="395" width="170" height="20" rx="2" fill="#1B2631"/>
  <path fill="#F1C40F" d="M 170 398 h 8 v 12 h -8 z M 183 398 h 8 v 12 h -8 z M 196 398 h 8 v 12 h -8 z M 209 398 h 8 v 12 h -8 z M 222 398 h 8 v 12 h -8 z M 235 398 h 8 v 12 h -8 z M 253 398 h 8 v 12 h -8 z M 266 398 h 8 v 12 h -8 z M 279 398 h 8 v 12 h -8 z M 292 398 h 8 v 12 h -8 z M 305 398 h 8 v 12 h -8 z M 318 398 h 8 v 12 h -8 z"/>

  <rect x="104" y="245" width="290" height="150" rx="14" fill="#2C3E50"/>
  <rect x="114" y="255" width="270" height="130" rx="10" fill="#34495E"/>

  <path stroke="#1ABC9C" stroke-width="4" stroke-linecap="round" fill="none" d="M 125 267 L 373 267"/>
  <path stroke="#1ABC9C" stroke-width="4" stroke-linecap="round" fill="none" d="M 125 373 L 373 373"/>

  <circle cx="185" cy="320" r="48" fill="#1A252F"/>
  <circle cx="185" cy="320" r="42" fill="#2C3E50"/>
  <g fill="#1A252F">
    <path d="M 185 320 L 175 282 A 42 42 0 0 1 195 282 Z"/>
    <path d="M 185 320 L 223 310 A 42 42 0 0 1 223 330 Z"/>
    <path d="M 185 320 L 195 358 A 42 42 0 0 1 175 358 Z"/>
    <path d="M 185 320 L 147 330 A 42 42 0 0 1 147 310 Z"/>
  </g>
  <circle cx="185" cy="320" r="16" fill="#34495E"/>
  <circle cx="185" cy="320" r="8" fill="#7F8C8D"/>

  <circle cx="313" cy="320" r="48" fill="#1A252F"/>
  <circle cx="313" cy="320" r="42" fill="#2C3E50"/>
  <g fill="#1A252F">
    <path d="M 313 320 L 303 282 A 42 42 0 0 1 323 282 Z"/>
    <path d="M 313 320 L 351 310 A 42 42 0 0 1 351 330 Z"/>
    <path d="M 313 320 L 323 358 A 42 42 0 0 1 303 358 Z"/>
    <path d="M 313 320 L 275 330 A 42 42 0 0 1 275 310 Z"/>
  </g>
  <circle cx="313" cy="320" r="16" fill="#34495E"/>
  <circle cx="313" cy="320" r="8" fill="#7F8C8D"/>

  <circle cx="130" cy="110" r="4" fill="#FFEB3B"/>
  <circle cx="380" cy="130" r="5" fill="#F39C12"/>
  <circle cx="280" cy="50" r="3" fill="#FFEB3B"/>
  <circle cx="200" cy="40" r="4" fill="#E74C3C"/>
</svg>
]==]

local function logoPath()
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    local path = directory .. "/logo.svg"
    if not noctalia.fileExists(path) then
        if not noctalia.writeFile(path, LOGO_SVG) then
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
function M.buildRows(m, showTemps)
    local rows = {}
    if type(m) ~= "table" or not m.available then
        return rows
    end

    rows[#rows + 1] = {
        label = "CPU",
        glyph = "cpu-usage",
        progress = clamp(m.cpuPerc),
        detail = withTemp(percent(m.cpuPerc), showTemps, m.cpuTemp),
    }
    rows[#rows + 1] = {
        label = "RAM",
        glyph = "memory",
        progress = clamp(m.memPerc),
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
            detail = usedOfTotal(m.swapUsedMb, m.swapTotalMb),
        }
    end

    if m.gpuAvailable and m.gpuPerc then
        rows[#rows + 1] = {
            label = "GPU",
            glyph = "gpu-usage",
            progress = clamp(m.gpuPerc),
            detail = withTemp(percent(m.gpuPerc), showTemps, m.gpuTemp),
        }
    end
    if m.vramUsedMb and m.vramTotalMb then
        rows[#rows + 1] = {
            label = "VRAM",
            glyph = "storage",
            progress = clamp(m.vramPerc),
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

local function metricRow(row)
    return ui.column({ gap = 4 }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = row.glyph, size = 14, color = "on_surface_variant" }),
            ui.label({ text = row.label, color = "on_surface_variant", width = 48 }),
            -- A spacer pushes the detail right. `align` is not a label prop: setting it
            -- left the text unaligned and the shell logged a warning on every render.
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = row.detail, color = "on_surface_variant", fontSize = 11 }),
        }),
        ui.progress({
            height = 4,
            progress = row.progress,
            fill = "primary",
            track = "surface_variant",
            radius = 2,
        }),
    })
end

local function figureRow(figure)
    return ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = figure.glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = figure.label, color = "on_surface_variant", width = 48 }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = figure.detail, color = "on_surface_variant", fontSize = 11 }),
    })
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
    local mark = logo
            and ui.image({ path = logo, width = 42, height = 42, fit = "contain" })
        -- The glyph is the fallback for the one case that can fail: no plugin data
        -- directory to write the logo into.
        or ui.glyph({ name = "device-gamepad-2", size = 22, color = "primary" })

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
            children[#children + 1] = metricRow(row)
        end
        for _, figure in ipairs(M.buildFigures(metrics)) do
            children[#children + 1] = figureRow(figure)
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
