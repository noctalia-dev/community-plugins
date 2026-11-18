--!nonstrict
-- NCS Visualizer - Control Center tile.
-- Click: show / hide the orb. Right-click: open the plugin settings.
-- Holds no logic of its own: mirrors the service's "status" and sends actions
-- on the "command" channel.

local function apply(status)
    local s = if type(status) == "table" then status else {}
    shortcut.setLabel(noctalia.tr("shortcut.label"))
    shortcut.setIcon("wave-sine")
    shortcut.setActive(s.enabled == true and s.problem == nil)
    shortcut.setEnabled(s.problem ~= "missing_renderer" and s.problem ~= "missing_cava")
end

apply(noctalia.state.get("status"))
noctalia.state.watch("status", apply)

function onClick()
    noctalia.state.set("command", { action = "toggle", at = noctalia.nowMs() })
end

function onRightClick()
    noctalia.openSettings()
end
