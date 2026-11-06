--!nonstrict
-- Internal Keyboard - control center tile.
--
-- Thin client, like the bar widget: mirror "status", write "command".
-- Highlighted tile means the keyboard is currently disabled.

local function render(status)
    local known = type(status) == "table"
    local off = known and status.state == "off"

    shortcut.setLabel(noctalia.tr(off and "shortcut.state.off" or "shortcut.state.on"))
    shortcut.setIcon("keyboard-off", "keyboard")
    shortcut.setActive(off)
    shortcut.setEnabled(known and status.available == true)
end

render(noctalia.state.get("status"))
noctalia.state.watch("status", render)

function onClick()
    noctalia.state.set("command", { action = "toggle", seq = noctalia.nowMs() })
end

-- Re-read the backend, e.g. after switching from a TTY or after a resume.
function onRightClick()
    noctalia.state.set("command", { action = "refresh", seq = noctalia.nowMs() })
end
