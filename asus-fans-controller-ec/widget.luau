--!nonstrict
-- Asus Fans Controller EC — bar widget.

local PANEL_ID = "cleboost/asus-fans-controller-ec:panel"
local COMMAND_KEY = "fan_command"
local STATUS_KEY = "fan_status"

local MODE_AUTO = "auto"
local MODE_MANUAL = "manual"
local MODE_CURVE = "curve"

local showLabel = noctalia.getConfig("show_label") == true
local commandNonce = 0

local status = noctalia.state.get(STATUS_KEY) or {
    available = false,
    controlMode = MODE_AUTO,
    synced = true,
    busy = false,
    fanCount = 0,
    fans = {},
    temps = {},
    error = "",
}

local function sendCommand(payload)
    commandNonce = commandNonce + 1
    payload.nonce = commandNonce
    noctalia.state.set(COMMAND_KEY, payload)
end

local function controlMode()
    local mode = status.controlMode
    if mode == MODE_MANUAL or mode == MODE_CURVE or mode == MODE_AUTO then
        return mode
    end
    return MODE_AUTO
end

local function totalRpm()
    local sum = 0
    for _, fan in ipairs(status.fans or {}) do
        sum = sum + (fan.rpm or 0)
    end
    return sum
end

local function tempSuffix()
    local maxTemp = status.temps and status.temps.max
    return maxTemp ~= nil and (" · " .. maxTemp .. "°C max") or ""
end

local function render()
    if status.available ~= true then
        barWidget.setGlyph("car-fan")
        barWidget.setGlyphColor("on_surface_variant")
        barWidget.setText(showLabel and noctalia.tr("widget.unavailable") or "")
        barWidget.setTooltip(status.error ~= "" and status.error or noctalia.tr("tooltip.unavailable"))
        return
    end

    if status.busy == true then
        barWidget.setGlyph("loader-2")
        barWidget.setGlyphColor("primary")
        barWidget.setText("")
        barWidget.setTooltip(noctalia.tr("tooltip.busy"))
        return
    end

    local mode = controlMode()
    local rpm = tostring(totalRpm())
    local temp = tempSuffix()

    if mode == MODE_MANUAL then
        barWidget.setGlyph("car-fan-2")
        barWidget.setGlyphColor("tertiary")
        if showLabel then
            local percent = status.fans and status.fans[1] and status.fans[1].percent
            barWidget.setText(percent and (tostring(percent) .. "%") or noctalia.tr("widget.manual"))
        else
            barWidget.setText("")
        end
        barWidget.setTooltip(noctalia.tr("tooltip.manual", {
            rpm = rpm,
            percent = tostring(status.fans and status.fans[1] and status.fans[1].percent or "?"),
            temp = temp,
        }))
    elseif mode == MODE_CURVE then
        barWidget.setGlyph("chart-line")
        barWidget.setGlyphColor("primary")
        barWidget.setText(showLabel and noctalia.tr("widget.curve") or "")
        barWidget.setTooltip(noctalia.tr("tooltip.curve", { rpm = rpm, temp = temp }))
    else
        barWidget.setGlyph("car-fan")
        barWidget.setGlyphColor("secondary")
        barWidget.setText(showLabel and noctalia.tr("widget.auto") or "")
        barWidget.setTooltip(noctalia.tr("tooltip.auto", { rpm = rpm, temp = temp }))
    end
end

noctalia.state.watch(STATUS_KEY, function(value)
    if type(value) ~= "table" then
        return
    end
    status = value
    render()
end)

render()

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    sendCommand({ action = "refresh", detail = true })
end

function onConfigChanged()
    showLabel = noctalia.getConfig("show_label") == true
    render()
end
