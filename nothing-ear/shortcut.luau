--!nonstrict
-- Shortcut: force a fresh connect+read even if background bar polling is
-- off. This is the "on demand" path for someone who keeps show_in_bar
-- disabled and only wants to check in occasionally.

local COMMAND_KEY = "nothing_ear_command"
local STATUS_KEY = "nothing_ear_status"

local status = noctalia.state.get(STATUS_KEY) or {}

local function render()
	shortcut.setLabel(noctalia.tr("shortcut.refresh"))
	shortcut.setIcon("headphones")
end

noctalia.state.watch(STATUS_KEY, function(value)
	if type(value) == "table" then
		status = value
	end
end)

render()

function onClick()
	noctalia.state.set(COMMAND_KEY, { action = "refresh", nonce = tostring(noctalia.nowMs()) })
end
