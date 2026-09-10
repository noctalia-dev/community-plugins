--!nonstrict

local PANEL_ID = "elijaharch/wl-screen-mirror:controls"

local status = noctalia.state.get("mirror_status") or {
	phase = "stopped",
	running = false,
}
local requestSerial = 0

local function tr(key, values)
	return noctalia.tr(key, values)
end

local function render()
	local phase = status.phase or "stopped"
	local active = phase == "running" or phase == "starting"

	shortcut.setLabel(active and tr("shortcut.active") or tr("shortcut.inactive"))
	shortcut.setIcon("screen-share")
	shortcut.setActive(active)
	shortcut.setEnabled(status.available ~= false and phase ~= "stopping")
end

noctalia.state.watch("mirror_status", function(value)
	if type(value) == "table" then
		status = value
		render()
	end
end)

function onClick()
	local phase = status.phase or "stopped"

	if phase == "running" or phase == "starting" then
		requestSerial += 1
		noctalia.state.set("mirror_request", {
			action = "stop",
			serial = requestSerial,
		})
		return
	end

	noctalia.togglePanel(PANEL_ID)
end

render()
