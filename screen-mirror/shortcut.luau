--!nonstrict
-- Screen Mirror - control-center quick-toggle tile.
--
-- Holds no logic of its own: it mirrors the service through the plugin's shared
-- state (reads "status", writes "command"), so the tile keeps working even when
-- no bar widget is placed.

local function applyStatus(st)
    local known = type(st) == "table"
    local on = known and st.enabled == true
    local installed = known and st.installed == true

    shortcut.setLabel(on and noctalia.tr("shortcut.label-on") or noctalia.tr("shortcut.label-off"))
    shortcut.setIcon("screen-share", "screen-share-off")
    shortcut.setActive(on)
    -- Stay clickable as long as the CLI is installed: a click on a stopped
    -- daemon starts it again through `ensure`.
    shortcut.setEnabled(installed)
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)

function onClick()
    noctalia.state.set("command", { action = "toggle", seq = noctalia.nowMs() })
end
