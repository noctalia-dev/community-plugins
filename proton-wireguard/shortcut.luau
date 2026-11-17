--!nonstrict
-- Control-center shortcut: toggles Proton VPN, or cancels a connection attempt.

local STATE_KEY = "pw.state"
local CMD_KEY = "pw.cmd"

local s = noctalia.state.get(STATE_KEY) or {}

local function render()
	local p = s.proton or {}
	local label = noctalia.tr("proton.title")
	if p.up and (p.server or "") ~= "" then
		label = p.server
	end
	shortcut.setLabel(label)
	shortcut.setIcon("shield-check", "shield")
	shortcut.setActive(p.up == true)
	local cancellable = p.action == "connecting" and p.canCancel == true
	shortcut.setEnabled(p.installed == true and p.signedIn == true and (not p.busy or cancellable))
end

noctalia.state.watch(STATE_KEY, function(value)
	if type(value) == "table" then
		s = value
		render()
	end
end)

function onClick()
	noctalia.state.set(CMD_KEY, { op = "toggle_proton", n = noctalia.nowMs() })
end

render()
