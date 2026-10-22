--!nonstrict
local status = noctalia.state.get("super_caffeine_status") or { active = false, busy = false }
local requestId = 0

local function render()
    shortcut.setLabel(if status.active then noctalia.tr("shortcut.active") else noctalia.tr("shortcut.inactive"))
    shortcut.setIcon("coffee", "coffee-off")
    shortcut.setActive(status.active == true)
    shortcut.setEnabled(status.busy ~= true)
end

noctalia.state.watch("super_caffeine_status", function(value)
    if type(value) == "table" then
        status = value
        render()
    end
end)

function onClick()
    if status.busy then return end
    requestId += 1
    noctalia.state.set("super_caffeine_command", { action = "toggle", requestId = `shortcut-{requestId}` })
end

render()
