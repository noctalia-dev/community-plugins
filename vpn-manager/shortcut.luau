--!nonstrict
-- VPN Manager control-center shortcut: toggles the default VPN connection.

local connected = false
local defaultUuid = ""

local function render()
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("shield-lock-filled", "shield-lock")
  shortcut.setActive(connected)
  shortcut.setEnabled(true)
end

noctalia.state.watch("vpn.status", function(status)
  connected = type(status) == "table" and status.anyActive == true
  render()
end)

noctalia.state.watch("vpn.defaultVpnUuid", function(uuid)
  defaultUuid = type(uuid) == "string" and uuid or ""
end)

function onClick()
  if defaultUuid == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.no_default"))
    noctalia.togglePanel("andrewdems/vpn-manager:panel")
    return
  end
  if connected then
    noctalia.state.set("vpn.cmd", { op = "disconnect", uuid = defaultUuid })
  else
    noctalia.state.set("vpn.cmd", { op = "connect", uuid = defaultUuid })
  end
end

render()
