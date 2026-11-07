--!nonstrict
-- Internal Keyboard - control center tile.
--
-- Thin client, like the bar widget: mirror "status", write "command".
-- Highlighted tile means the keyboard is currently disabled.

local function render(status)
    local known = type(status) == "table"
    local off = known and status.state == "off"
    local ready = known and status.available == true

    shortcut.setEnabled(true)
    if not ready then
        -- Not set up yet (or the rule went missing): clicking installs it.
        shortcut.setLabel(noctalia.tr("shortcut.setup"))
        shortcut.setIcon("shield-lock")
        shortcut.setActive(false)
        return
    end

    shortcut.setLabel(noctalia.tr(off and "shortcut.state.off" or "shortcut.state.on"))
    shortcut.setIcon("keyboard-off", "keyboard")
    shortcut.setActive(off)
end

render(noctalia.state.get("status"))
noctalia.state.watch("status", render)

function onClick()
    local status = noctalia.state.get("status")
    if type(status) ~= "table" or status.available ~= true then
        noctalia.state.set("command", { action = "setup", seq = noctalia.nowMs() })
        return
    end
    noctalia.state.set("command", { action = "toggle", seq = noctalia.nowMs() })
end

-- Re-read the backend, e.g. after switching from a TTY or after a resume.
function onRightClick()
    noctalia.state.set("command", { action = "refresh", seq = noctalia.nowMs() })
end
