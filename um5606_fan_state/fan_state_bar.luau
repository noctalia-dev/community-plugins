-- ASUS UM5606 Fan State - bar widget (thin presentation client).
--
-- The fan control logic lives in the [[service]] (fan_state_service.luau), which
-- runs for the whole session. This widget only reflects the published "status"
-- and cycles states by writing to the "command" channel.

local showLabel = noctalia.getConfig("show_label")

local STATES = {
    [0] = { label = "Standard",         glyph = "car-fan",   color = "on_surface" },
    [1] = { label = "Quiet",            glyph = "car-fan-1", color = "secondary"  },
    [2] = { label = "High-Performance", glyph = "car-fan-2", color = "tertiary"   },
    [3] = { label = "Full",             glyph = "car-fan-3", color = "primary"    },
}

local fanState = -1
local available = false

local function send(action)
    noctalia.state.set("command", action)
end

local function applyState(state)
    local info = STATES[state]
    if not info then
        barWidget.setGlyph("car-fan")
        if showLabel then
            barWidget.setText("Unknown")
        end
        barWidget.setGlyphColor("on_surface")
        barWidget.setColor("on_surface")
        return
    end

    barWidget.setGlyph(info.glyph)
    if showLabel then
        barWidget.setText(info.label)
    end
    barWidget.setGlyphColor(info.color)
    barWidget.setColor(info.color)
end

local function applyStatus(status)
    if type(status) == "table" then
        fanState = tonumber(status.state) or -1
        available = status.available and true or false
    end

    if not available then
        barWidget.setGlyph("car-fan")
        if showLabel then
            barWidget.setText("Unavailable")
        end
        barWidget.setGlyphColor("on_surface_variant")
        barWidget.setColor("on_surface_variant")
        return
    end

    applyState(fanState)
end

function onClick()
    if not available then return end
    send("cycle")
end

-- Sync the current status on load, then track changes.
applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)
