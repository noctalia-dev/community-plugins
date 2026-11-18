--!nonstrict
-- Proton VPN Control Center Shortcut

local STATE_KEY = "protonvpn.status"
local COMMAND_KEY = "protonvpn.cmd"

local connected = false

local function render()
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("shield-check", "shield-lock")
  shortcut.setActive(connected)
  shortcut.setEnabled(true)
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    connected = (value.connected == true)
    render()
  end
end)

function onClick()
  if connected then
    noctalia.state.set(COMMAND_KEY, { op = "disconnect" })
  else
    noctalia.state.set(COMMAND_KEY, { op = "connect", target = "fastest" })
  end
end

render()
