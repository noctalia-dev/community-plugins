--!nonstrict
-- NCS Visualizer - headless service.
--
-- Runs for the whole session and owns the companion renderer, `aurora-ncs`:
--   * finds every orb placed in the desktop-widget editor and where it is,
--   * resolves the colours (theme or custom) and the other settings,
--   * writes them to a JSON config the renderer follows live,
--   * starts the renderer when there is something to draw, and stops it by
--     removing the config when there is not,
--   * keeps a heartbeat file fresh so the renderer exits if Noctalia goes away.
--
-- The desktop widget and the Control Center tile are thin clients: they read
-- the published "status" and send actions on the "command" channel.

noctalia.setUpdateInterval(1000)

local WIDGET_TYPE = "tausif/ncs-visualizer:orb"
local RENDERER = "aurora-ncs"
local DEFAULT_SIZE = 420 -- matches the widget's auto-fit size in orb.luau

local dataDir = noctalia.pluginDataDir()
local CONFIG = `{dataDir}/renderer.json`
local HEARTBEAT = `{dataDir}/heartbeat`
local ENABLED_FILE = `{dataDir}/enabled`

local HEARTBEAT_EVERY = 3 -- seconds
local HEARTBEAT_TIMEOUT = 20 -- renderer gives up after this long without one
local CHECK_EVERY = 3 -- seconds between process checks
local CRASH_WINDOW_MS = 60000
local CRASH_LIMIT = 4 -- launches within CRASH_WINDOW_MS before giving up

local enabled = true
local lastWritten = nil
local ticks = 0
local checking = false
local running = false
local launches = {} -- nowMs() of recent launches
local crashed = false
local lastStatusKey = nil

local theme = { key = nil, colors = nil, pending = false }
local remapToken = 0 -- bumped when Noctalia re-creates an orb's surface

local function log(msg)
    noctalia.log(`ncs-visualizer: {msg}`)
end

-- ── Persistence ─────────────────────────────────────────────────────────

local function loadEnabled()
    local raw = noctalia.readFile(ENABLED_FILE)
    enabled = raw == nil or noctalia.string.trim(raw) ~= "0"
end

local function saveEnabled()
    noctalia.writeFile(ENABLED_FILE, if enabled then "1" else "0")
end

-- ── Dependencies ────────────────────────────────────────────────────────

local function rendererBinary(): string?
    local custom = noctalia.getConfig("renderer_path")
    if type(custom) == "string" and custom ~= "" then
        local path = noctalia.expandPath(custom)
        if noctalia.fileExists(path) then
            return path
        end
        if noctalia.commandExists(custom) then
            return custom
        end
        return nil
    end
    if noctalia.commandExists(RENDERER) then
        return RENDERER
    end
    -- Noctalia is often started without ~/.local/bin on PATH.
    local localBin = noctalia.expandPath(`~/.local/bin/{RENDERER}`)
    if noctalia.fileExists(localBin) then
        return localBin
    end
    return nil
end

-- ── Placement ───────────────────────────────────────────────────────────

local function collectPlacements()
    local list = {}
    local widgets = noctalia.getSetting("desktop_widgets.widget")
    if type(widgets) ~= "table" then
        return list
    end

    -- Only widgets in the layout's order are actually on the desktop.
    local placed = nil
    local order = noctalia.getSetting("desktop_widgets.widget_order")
    if type(order) == "table" and #order > 0 then
        placed = {}
        for _, id in ipairs(order) do
            placed[tostring(id)] = true
        end
    end

    local outputs = {}
    local firstOutput = nil
    for _, o in ipairs(noctalia.outputs() or {}) do
        outputs[o.name] = o
        firstOutput = firstOutput or o
    end

    for id, w in pairs(widgets) do
        if type(w) == "table" and w.type == WIDGET_TYPE and w.enabled ~= false
            and (placed == nil or placed[tostring(id)]) then
            local out = outputs[w.output] or firstOutput
            if out then
                local bw = if (w.box_width or 0) > 0 then w.box_width else DEFAULT_SIZE
                local bh = if (w.box_height or 0) > 0 then w.box_height else DEFAULT_SIZE
                -- Widget coordinates are stored against the output size at the
                -- time of placement; rescale if the output changed since.
                local sx = if (w.placement_width or 0) > 0 then out.width / w.placement_width else 1
                local sy = if (w.placement_height or 0) > 0 then out.height / w.placement_height else 1
                local cx = (w.cx or out.width / 2) * sx
                local cy = (w.cy or out.height / 2) * sy
                table.insert(list, {
                    id = tostring(id),
                    output = out.name,
                    x = math.floor(cx - bw * sx / 2 + 0.5),
                    y = math.floor(cy - bh * sy / 2 + 0.5),
                    width = math.floor(bw * sx + 0.5),
                    height = math.floor(bh * sy + 0.5),
                })
            end
        end
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
end

-- ── Colours ─────────────────────────────────────────────────────────────

-- Theme palette as { primary = "#..", secondary = "#..", tertiary = "#.." }.
-- Newer Noctalia exposes it directly; older releases (5.0 betas) don't, so the
-- palette is regenerated from the wallpaper with Noctalia's own generator,
-- using the same scheme and mode as the shell.
local function themeColors(outputName: string?)
    if noctalia.getColor then
        return {
            primary = noctalia.getColor("primary"),
            secondary = noctalia.getColor("secondary"),
            tertiary = noctalia.getColor("tertiary"),
        }
    end

    if noctalia.getSetting("theme.source") ~= "wallpaper" then
        return nil
    end
    local wallpaper = noctalia.wallpaperPath(outputName)
    if type(wallpaper) ~= "string" or wallpaper == "" then
        return theme.colors
    end
    local scheme = noctalia.getSetting("theme.wallpaper_scheme") or "m3-content"
    local mode = if noctalia.isDarkMode() then "--dark" else "--light"
    local key = `{wallpaper}|{scheme}|{mode}`

    if key ~= theme.key and not theme.pending then
        theme.pending = true
        noctalia.runAsync({ "noctalia", "theme", wallpaper, "--scheme", scheme, mode }, function(r)
            theme.pending = false
            theme.key = key -- don't retry a failing image every second
            if r.exitCode == 0 and r.stdout then
                local ok, decoded = pcall(noctalia.json.decode, r.stdout)
                if ok and type(decoded) == "table" and decoded.primary then
                    theme.colors = decoded
                    return
                end
            end
            log(`palette generation failed for {wallpaper}`)
        end, 15000)
    end
    return theme.colors
end

local function resolveColors(outputName: string?)
    local palette = themeColors(outputName)
    local function role(name)
        return if palette and type(palette[name]) == "string" then palette[name] else nil
    end

    local custom = noctalia.getConfig("color") or "#ff2e88"
    local color = custom
    if noctalia.getConfig("color_source") == "theme" then
        color = role(noctalia.getConfig("theme_role") or "primary") or custom
    end

    local glowMode = noctalia.getConfig("glow_mode")
    local glow = color
    if glowMode == "theme" then
        glow = role(noctalia.getConfig("glow_theme_role") or "tertiary") or color
    elseif glowMode == "custom" then
        glow = noctalia.getConfig("glow_color") or color
    end
    return color, glow
end

-- ── Config ──────────────────────────────────────────────────────────────

local function buildConfig(placements)
    local color, glow = resolveColors(placements[1] and placements[1].output)
    return {
        instances = placements,
        remap = remapToken,
        heartbeatFile = HEARTBEAT,
        heartbeatTimeout = HEARTBEAT_TIMEOUT,
        color = color,
        glowColor = glow,
        opacity = noctalia.getConfig("opacity") or 1.0,
        dotCount = tonumber(noctalia.getConfig("dot_density")) or 322,
        orbScale = noctalia.getConfig("orb_scale") or 1.0,
        dotScale = noctalia.getConfig("dot_scale") or 1.0,
        glowScale = noctalia.getConfig("glow_scale") or 1.0,
        motionModel = noctalia.getConfig("motion_model") or "original",
        gain = noctalia.getConfig("sensitivity") or 1.0,
        flowSpeed = noctalia.getConfig("flow_speed") or 1.0,
        punch = noctalia.getConfig("punch") or 0.5,
        fps = tonumber(noctalia.getConfig("fps")) or 60,
        hideWhenIdle = noctalia.getConfig("hide_when_idle") == true,
        idleSeconds = noctalia.getConfig("idle_seconds") or 5,
        layer = noctalia.getConfig("layer") or "bottom",
        cava = {
            source = noctalia.getConfig("audio_source") or "",
            noiseReduction = noctalia.getConfig("noise_reduction") or 55,
        },
    }
end

local function writeConfig(cfg)
    local text = noctalia.json.encode(cfg, true)
    if text ~= lastWritten then
        noctalia.mkdirAll(dataDir)
        -- Write then rename, so the renderer never reads half a file.
        local tmp = `{CONFIG}.tmp`
        if noctalia.writeFile(tmp, text) and noctalia.renameFile(tmp, CONFIG) then
            lastWritten = text
        end
    end
end

local function removeConfig()
    if lastWritten ~= nil or noctalia.fileExists(CONFIG) then
        noctalia.removeFile(CONFIG)
        lastWritten = nil
    end
end

-- ── Status ──────────────────────────────────────────────────────────────

local function publish(count: number, binary: string?, hasCava: boolean)
    local problem = nil
    if not binary then
        problem = "missing_renderer"
    elseif not hasCava then
        problem = "missing_cava"
    elseif crashed then
        problem = "crashed"
    elseif not enabled then
        problem = "disabled"
    end
    local status = {
        enabled = enabled,
        running = running,
        count = count,
        problem = problem,
        config = CONFIG,
    }
    local key = `{enabled}|{running}|{count}|{problem}`
    if key ~= lastStatusKey then
        lastStatusKey = key
        noctalia.state.set("status", status)
    end
end

-- ── Process management ──────────────────────────────────────────────────

local function recentLaunches(): number
    local now = noctalia.nowMs()
    local kept = {}
    for _, t in ipairs(launches) do
        if now - t < CRASH_WINDOW_MS then
            table.insert(kept, t)
        end
    end
    launches = kept
    return #kept
end

local function ensureRunning(binary: string)
    if checking then
        return
    end
    checking = true
    noctalia.processMatches(function(matched)
        checking = false
        running = matched
        if matched or not enabled or crashed or lastWritten == nil then
            return
        end
        if recentLaunches() >= CRASH_LIMIT then
            crashed = true
            log(`renderer exited {CRASH_LIMIT} times in a minute; not restarting until settings change`)
            return
        end
        table.insert(launches, noctalia.nowMs())
        log(`starting {binary}`)
        noctalia.runAsync({ binary, "--config", CONFIG })
    end, RENDERER, "--config", CONFIG)
end

local function heartbeat()
    noctalia.writeFile(HEARTBEAT, tostring(noctalia.nowMs()))
end

local function sync()
    local binary = rendererBinary()
    local hasCava = noctalia.commandExists("cava")
    local placements = collectPlacements()

    if enabled and binary and hasCava and #placements > 0 then
        writeConfig(buildConfig(placements))
        if ticks % HEARTBEAT_EVERY == 0 then
            heartbeat()
        end
        if ticks % CHECK_EVERY == 0 then
            ensureRunning(binary)
        end
    else
        -- The renderer exits by itself within a second of the config going away.
        removeConfig()
        running = false
    end
    publish(#placements, binary, hasCava)
end

-- ── Actions ─────────────────────────────────────────────────────────────

local function setEnabled(on: boolean)
    enabled = on
    crashed = false
    launches = {}
    saveEnabled()
    if on and #collectPlacements() == 0 then
        noctalia.notify(noctalia.tr("shortcut.label"), noctalia.tr("notify.no_orb"))
    end
    ticks = 0 -- check the process straight away
    sync()
end

local function handleAction(action: string)
    if action == "toggle" then
        setEnabled(not enabled)
    elseif action == "on" then
        setEnabled(true)
    elseif action == "off" then
        setEnabled(false)
    elseif action == "settings" then
        noctalia.openSettings()
    end
end

noctalia.state.watch("surface", function(value)
    if type(value) == "number" and value ~= remapToken then
        remapToken = value
        sync()
    end
end)

noctalia.state.watch("command", function(value)
    if type(value) == "table" and type(value.action) == "string" then
        handleAction(value.action)
    end
end)

-- `noctalia msg plugin tausif/ncs-visualizer:service all toggle` (or on / off),
-- for compositor keybinds.
function onIpc(event, payload)
    if event == "request" and type(payload) == "string" and payload ~= "" then
        local ok, decoded = pcall(noctalia.json.decode, payload)
        if ok and type(decoded) == "table" and type(decoded.action) == "string" then
            handleAction(decoded.action)
        end
        return
    end
    handleAction(event)
end

function onConfigChanged()
    -- New settings deserve a fresh try after a crash loop.
    crashed = false
    launches = {}
    sync()
end

function onExit()
    removeConfig()
end

function update()
    ticks += 1
    sync()
end

loadEnabled()
sync()
