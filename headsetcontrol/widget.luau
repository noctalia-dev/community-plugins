--!nonstrict
-- Bar widget: battery glyph (and optional percentage) for the primary
-- headset. Pure renderer of the service's "snapshot" state.

local STATE_KEY = "snapshot"
local REQUEST_KEY = "refresh_request"
local PANEL_ID = "vavadik/headsetcontrol:panel"

local snapshot = noctalia.state.get(STATE_KEY)

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function request()
    local prev = noctalia.state.get(REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set(REQUEST_KEY, { nonce = nonce })
end

-- First device with a known battery level, otherwise the first device.
local function primaryDevice(snap)
    local devices = snap ~= nil and snap.devices or nil
    if type(devices) ~= "table" or #devices == 0 then
        return nil
    end
    for _, device in ipairs(devices) do
        if device.battery ~= nil and device.battery.level ~= nil then
            return device
        end
    end
    return devices[1]
end

local function batteryGlyph(device)
    local battery = device.battery
    if battery ~= nil and battery.status == "charging" then
        return "battery-charging", "primary"
    end
    -- A "partial" device can still report a valid level; only the level matters here.
    if battery == nil or battery.level == nil
        or battery.status == "unavailable" or battery.status == "unknown" then
        return "battery-exclamation", "on_surface_variant"
    end
    local level = battery.level
    if level < 10 then
        return "battery-0", "error"
    elseif level < 30 then
        return "battery-1", "warning"
    elseif level < 55 then
        return "battery-2", "on_surface"
    elseif level < 80 then
        return "battery-3", "on_surface"
    end
    return "battery-4", "on_surface"
end

local function batteryText(battery)
    local status = tr(`battery.status.{battery.status}`)
    if battery.level == nil then
        return status
    end
    return `{tr("battery.level", { level = battery.level })} · {status}`
end

local function hintsRow()
    return { key = "", value = tr("widget.tooltip.hints") }
end

-- The error hint promises cached data, so use the plain one when there is none.
local function stateHintKey(state)
    if state == "error" and (snapshot.devices == nil or #snapshot.devices == 0) then
        return "state.error.hint_no_data"
    end
    return `state.{state}.hint`
end

local function stateTooltip(state)
    local rows = { { key = tr(`state.{state}.title`), value = tr(stateHintKey(state)) } }
    if state == "error" and snapshot.error ~= nil then
        table.insert(rows, { key = tr("widget.tooltip.last_refresh_failed"), value = tostring(snapshot.error) })
    end
    table.insert(rows, hintsRow())
    return rows
end

local function render()
    local state = snapshot ~= nil and snapshot.state or nil
    local device = primaryDevice(snapshot)
    local showPercentage = noctalia.getConfig("show_percentage") == true
    local hideWhenUnavailable = noctalia.getConfig("hide_when_unavailable") == true

    if state == nil then
        -- Service has not published yet.
        barWidget.setGlyph("headphones")
        barWidget.setGlyphColor("on_surface_variant")
        barWidget.setText("")
        barWidget.setTooltip({ hintsRow() })
        barWidget.setVisible(not hideWhenUnavailable)
        return
    end

    if state == "missing_dependency" or state == "no_devices" or device == nil then
        local shownState = state == "missing_dependency" and state or (state == "error" and "error" or "no_devices")
        if shownState == "error" then
            barWidget.setGlyph("alert-triangle")
            barWidget.setGlyphColor("error")
        else
            barWidget.setGlyph("headphones-off")
            barWidget.setGlyphColor(shownState == "missing_dependency" and "error" or "on_surface_variant")
        end
        barWidget.setText("")
        barWidget.setTooltip(stateTooltip(shownState))
        barWidget.setVisible(not (hideWhenUnavailable and shownState == "no_devices"))
        return
    end

    local glyph, color = batteryGlyph(device)
    barWidget.setGlyph(glyph)
    barWidget.setGlyphColor(color)

    local battery = device.battery
    local level = battery ~= nil and battery.level or nil
    if showPercentage and level ~= nil then
        barWidget.setText(tr("battery.level", { level = level }))
    else
        barWidget.setText("")
    end

    local rows = { { key = tr("widget.tooltip.device"), value = device.name } }
    if battery ~= nil then
        table.insert(rows, { key = tr("widget.tooltip.battery"), value = batteryText(battery) })
    end
    if device.chatmix ~= nil then
        table.insert(rows, { key = tr("widget.tooltip.chatmix"), value = tostring(device.chatmix) })
    end
    if state == "error" then
        table.insert(rows, { key = tr("widget.tooltip.last_refresh_failed"), value = tostring(snapshot.error or "") })
    end
    if snapshot.updatedAt ~= nil then
        table.insert(rows, { key = tr("widget.tooltip.updated"), value = os.date("%H:%M:%S", snapshot.updatedAt) })
    end
    table.insert(rows, hintsRow())
    barWidget.setTooltip(rows)

    local unavailable = battery == nil or battery.status == "unavailable" or level == nil
    barWidget.setVisible(not (hideWhenUnavailable and state ~= "error" and unavailable))
end

noctalia.state.watch(STATE_KEY, function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

-- Periodic re-render keeps text/visibility in sync with widget-setting edits,
-- which do not change the snapshot.
function update()
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
    request()
end

function onRightClick()
    request()
end

noctalia.setUpdateInterval(1000)
render()
