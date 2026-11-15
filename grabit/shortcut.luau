--!nonstrict
-- Grabit Launcher - control-center shortcut.
-- Mirrors the bar widget: left click captures, right click opens menu.

local state = "idle"
local available = false

local function renderPresentation()
    local active = state == "recording" or state == "paused"
    local iconOn = state == "paused" and "player-pause-filled" or "player-record-filled"

    shortcut.setLabel(active and "Stop recording" or "Grabit")
    shortcut.setIcon(iconOn, "screenshot")
    shortcut.setActive(active)
    shortcut.setEnabled(available)
end

local function applyStatus(status)
    if type(status) == "table" then
        state = status.state or "idle"
        available = if status.available then true else false
    end
    renderPresentation()
end

-- No delay_ms here, unlike the menu (menu.luau CAPTURE_DELAY_MS): activating a
-- shortcut does not dismiss the control center, so there is no panel close
-- animation to wait for. The control center does stay on screen, though, so it
-- can appear in captures started from here — the bar widget and menu do not
-- have that problem.
function onClick()
    if not available then return end
    if state ~= "idle" then
        noctalia.state.set("command", { action = "stop" })
    else
        noctalia.state.set("command", { action = "capture", mode = "default" })
    end
end

function onRightClick()
    if not available then return end
    noctalia.state.set("command", { action = "menu" })
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)