--!nonstrict

local gpuMode = require("./gpu_mode.luau")
local STATE_KEY = "asus_gpu_mode.status"
local TITLE = "ASUS GPU Mode Switcher"
local QUERY_COMMAND = { "supergfxctl", "--version", "--get", "--supported", "--pend-action", "--pend-mode" }
local PANEL_MODES = { "Integrated", "Hybrid", "AsusMuxDgpu", "Vfio", "AsusEgpu" }

local status = { available = false, current = "", pending = "", action = "", supported = {} }
local busy = false
local patchPending = noctalia.getConfig("asus_gpu_patch_pending") ~= false
local debug = noctalia.getConfig("asus_gpu_debug") == true
local pendingOverride = nil
local render

local function debugLog(message)
    if debug then
        noctalia.log(message)
    end
end

local function publish()
    noctalia.state.set(STATE_KEY, status)
end

local function applyPatchedPending(nextStatus)
    if not patchPending then return end
    if pendingOverride ~= nil then
        nextStatus.pending = pendingOverride
    end
    if nextStatus.pending ~= nil and nextStatus.pending ~= "" then
        nextStatus.action = gpuMode.requiredAction(nextStatus.pending, nextStatus.current)
    end
end

local function applyStatus(value)
    if type(value) == "table" then
        status = value
        status.supported = type(status.supported) == "table" and status.supported or {}
        applyPatchedPending(status)
    end
    render()
end

local function refresh()
    if busy then return end
    busy = true
    render()
    debugLog("Refreshing ASUS GPU mode status")
    local accepted = noctalia.runAsync(QUERY_COMMAND, function(result)
        if result.exitCode == 0 then
            local nextStatus = gpuMode.parse(result.stdout or "")
            applyPatchedPending(nextStatus)
            status = nextStatus
        else
            status = { available = false, current = "", pending = "", action = "", supported = {} }
        end
        busy = false
        publish()
        render()
    end)
    if not accepted then
        busy = false
        status = { available = false, current = "", pending = "", action = "", supported = {} }
        publish()
        render()
    end
end

local function openSessionPanel()
    local accepted = noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "session" })
    if not accepted then
        noctalia.notifyError(TITLE, "Could not open the session panel.")
    end
end

local function setMode(mode)
    local cancelling = status.current == mode and status.pending ~= nil and status.pending ~= ""
    if busy or not status.available or (status.current == mode and not cancelling) then
        return
    end

    busy = true
    pendingOverride = cancelling and "" or mode
    status.pending = pendingOverride
    status.action = (patchPending and pendingOverride ~= "")
        and gpuMode.requiredAction(pendingOverride, status.current)
        or ""
    publish()
    render()
    debugLog(`Requesting ASUS GPU mode: {mode}`)

    local accepted = noctalia.runAsync({ "supergfxctl", "--mode", mode }, function(result)
        if result.exitCode ~= 0 then
            pendingOverride = nil
            local message = noctalia.string.trim(result.stderr or "")
            noctalia.notifyError(TITLE, message ~= "" and message or "supergfxctl could not change the GPU mode.")
        end
        busy = false
        refresh()
    end)
    if not accepted then
        busy = false
        pendingOverride = nil
        noctalia.notifyError(TITLE, "Could not start supergfxctl.")
        refresh()
    end
end

render = function()
    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = gpuMode.icon(status.current), size = 22, color = "primary" }),
            ui.label({ text = TITLE, fontSize = 17, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ glyph = "refresh", enabled = not busy, onClick = refresh }),
            ui.button({ glyph = "x", onClick = "onClose" }),
        }),
        ui.label({
            text = status.available and `Current: {gpuMode.label(status.current)}` or "supergfxctl is unavailable",
            color = status.available and "on_surface" or "error",
        }),
    }

    local action = gpuMode.actionLabel(status.action)
    if action ~= "" then
        local needsIntegrated = gpuMode.actionNeedsIntegrated(action)
        local needsSession = gpuMode.actionNeedsSession(action)
        table.insert(children, ui.button({
            glyph = gpuMode.actionGlyph(action),
            text = needsIntegrated and "Switch to Integrated" or action,
            variant = "secondary",
            enabled = not busy and (needsIntegrated or needsSession),
            onClick = needsIntegrated and function() setMode("Integrated") end
                or (needsSession and openSessionPanel or function() end),
        }))
    end

    local modeButtons = {}
    for _, mode in ipairs(PANEL_MODES) do
        if status.supported[mode] == true then
            local isCurrent = status.current == mode and (status.pending == nil or status.pending == "")
            local isPending = status.pending == mode
            table.insert(modeButtons, ui.button({
                key = `asus-gpu-mode-{mode}`,
                glyph = gpuMode.icon(mode),
                text = gpuMode.label(mode),
                variant = isCurrent and "primary" or (isPending and "secondary" or "outline"),
                enabled = status.available and not busy and not isCurrent and not isPending,
                onClick = function() setMode(mode) end,
            }))
        end
    end
    if #modeButtons == 0 then
        table.insert(modeButtons, ui.label({
            text = "No supported ASUS GPU modes were reported.",
            color = "on_surface_variant",
        }))
    end
    table.insert(children, ui.scroll({
        flexGrow = 1,
        gap = 8,
        align = "stretch",
        fill = "surface_variant/0.25",
        radius = 8,
        padding = 8,
    }, modeButtons))

    if busy then
        table.insert(children, ui.label({ text = "Working…", color = "tertiary" }))
    elseif status.pending ~= nil and status.pending ~= "" then
        table.insert(children, ui.label({
            text = `Pending: {gpuMode.label(status.pending)}`,
            color = "tertiary",
        }))
    end

    panel.render(ui.column({ gap = 12, flexGrow = 1, align = "stretch" }, children))
end

function onOpen(_context)
    refresh()
end

function onClose()
    panel.close()
end

noctalia.state.watch(STATE_KEY, applyStatus)
render()
refresh()
