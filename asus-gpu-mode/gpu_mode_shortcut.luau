--!nonstrict

local gpuMode = require("./gpu_mode.luau")
local STATE_KEY = "asus_gpu_mode.status"
local PANEL_ID = "baizhu/asus-gpu-mode:gpu-mode-panel"
local QUERY_COMMAND = { "supergfxctl", "--version", "--get", "--supported", "--pend-action", "--pend-mode" }

local available = false
local current = ""
local pending = ""
local action = ""
local supported = {}
local polling = noctalia.getConfig("asus_gpu_polling") == true
local pollingInterval = math.max(1000, math.floor(tonumber(noctalia.getConfig("asus_gpu_polling_interval_ms")) or 3000))
local patchPending = noctalia.getConfig("asus_gpu_patch_pending") ~= false
local debug = noctalia.getConfig("asus_gpu_debug") == true
local refreshing = false

noctalia.setUpdateInterval(polling and pollingInterval or 60000)

local function debugLog(message)
    if debug then
        noctalia.log(message)
    end
end

local function render()
    shortcut.setIcon(gpuMode.icon(current))
    local label = current == "" and "GPU" or gpuMode.label(current)
    if pending ~= "" and pending ~= current then
        label ..= ` → {gpuMode.label(pending)}`
    end
    shortcut.setLabel(label)
    shortcut.setActive(pending ~= "")
    shortcut.setEnabled(available)
end

local function applyStatus(nextStatus)
    if type(nextStatus) ~= "table" then return end
    available = nextStatus.available == true
    current = nextStatus.current or ""
    pending = nextStatus.pending or ""
    action = nextStatus.action or ""
    supported = nextStatus.supported or supported
    render()
end

local function publish()
    noctalia.state.set(STATE_KEY, {
        available = available,
        current = current,
        pending = pending,
        action = action,
        supported = supported,
    })
end

local function refresh()
    if refreshing then return end
    refreshing = true
    debugLog("Refreshing ASUS GPU mode shortcut status")
    local accepted = noctalia.runAsync(QUERY_COMMAND, function(result)
        refreshing = false
        if result.exitCode == 0 then
            local nextStatus = gpuMode.parse(result.stdout or "")
            available = nextStatus.available
            current = nextStatus.current
            pending = nextStatus.pending or ""
            action = nextStatus.action or ""
            supported = nextStatus.supported or {}
            if patchPending and pending ~= "" then
                action = gpuMode.requiredAction(pending, current)
            end
        else
            available = false
            current = ""
            pending = ""
            action = ""
            supported = {}
        end
        publish()
        render()
    end)
    if not accepted then
        refreshing = false
        available = false
        current = ""
        pending = ""
        action = ""
        supported = {}
        publish()
        render()
    end
end

function update()
    if polling then
        refresh()
    end
end

function onClick()
    if available then
        noctalia.togglePanel(PANEL_ID)
    end
end

noctalia.state.watch(STATE_KEY, applyStatus)
render()
refresh()
