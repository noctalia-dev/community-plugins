-- ASUS UM5606 Fan State - control-center quick tile.
--
-- This tile holds no fan control logic of its own. It mirrors the bar widget
-- through the plugin's shared state:
--   reads  noctalia.state "status"  -> { state = ..., available = ... }
--   writes noctalia.state "command" -> "cycle"

local STATES = {
    [0] = { label = "Standard",         glyph = "car-fan"   },
    [1] = { label = "Quiet",            glyph = "car-fan-1" },
    [2] = { label = "High-Performance", glyph = "car-fan-2" },
    [3] = { label = "Full",             glyph = "car-fan-3" },
}

local available = false

local function applyStatus(status)
    local state = type(status) == "table" and tonumber(status.state) or nil
    available = type(status) == "table" and status.available and true or false

    local info = STATES[state]
    if info then
        shortcut.setLabel(info.label)
        shortcut.setIcon(info.glyph, "car-fan")
        shortcut.setActive(state ~= 0)
    else
        shortcut.setLabel(available and "Unknown" or "Unavailable")
        shortcut.setIcon("car-fan", "car-fan")
        shortcut.setActive(false)
    end

    shortcut.setEnabled(available)
end

-- Reflect whatever the service last published, then track live changes.
applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)

function onClick()
    if not available then return end
    noctalia.state.set("command", "cycle")
end
