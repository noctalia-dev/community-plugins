--!nonstrict
-- Typing Stats - optional control-center tile that installs the udev rule.
--
-- The plugin can only count keys when the active session may read the keyboard
-- event nodes. That needs one privileged step (a uaccess udev rule), so this
-- tile is the click-to-install entry point: it stays active until the listener
-- reports READY, then greys out. Nothing else in the plugin needs root.

local function render(access)
    local ok = type(access) == "table" and access.ok == true

    shortcut.setLabel(noctalia.tr(ok and "shortcut.setup.ok" or "shortcut.setup.needed"))
    shortcut.setIcon(ok and "shield-check" or "shield-lock")
    shortcut.setActive(false)
    -- Nothing left to do once the listener can read the keyboards.
    shortcut.setEnabled(not ok)
end

render(noctalia.state.get("access"))
noctalia.state.watch("access", render)

function onClick()
    local access = noctalia.state.get("access")
    if type(access) == "table" and access.ok == true then
        return
    end
    noctalia.state.set("command", { action = "setup", seq = noctalia.nowMs() })
end
