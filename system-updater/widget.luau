--!nonstrict

local state = nil

local function log(msg)
    noctalia.log("[system-updater] " .. msg)
end

local function err(msg)
    noctalia.log("[ERR][system-updater] " .. msg)
end

-- Updates are "pending" only while they are worth interrupting the user for:
-- a dismissed result stays visible in the panel but takes the bar back to its
-- resting colour.
local function pending()
    return state ~= nil
        and state.state == "idle"
        and (state.total or 0) > 0
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph"))

    local phase = state ~= nil and state.state or "idle"
    local error = state ~= nil and state.error or false
    if error then
        barWidget.setGlyphColor("error")
    elseif phase ~= "idle" then
        barWidget.setGlyphColor("secondary")
    elseif pending() then
        barWidget.setGlyphColor("primary")
    else
        barWidget.setGlyphColor("on_surface")
    end

    if pending() and noctalia.getConfig("show_count") == true then
        barWidget.setText(tostring(state.total))
    else
        barWidget.setText("")
    end
end

function update()
    render()
end

function onClick()
    noctalia.togglePanel("tordex/system-updater:panel")
end

-- Live updates from the plugin's background service.
noctalia.state.watch("state", function(value)
    if type(value) == "table" then
        state = value
        render()
    end
end)

noctalia.setUpdateInterval(1000)
state = noctalia.state.get("state")
render()
