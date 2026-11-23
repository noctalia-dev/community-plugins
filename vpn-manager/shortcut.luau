--!nonstrict
-- VPN Manager control-center shortcut: toggles the default VPN connection.

local connected = false

local function render()
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("shield-lock-filled", "shield-lock")
  shortcut.setActive(connected)
  shortcut.setEnabled(true)
end

local function applyStatus(status)
  connected = type(status) == "table" and status.anyActive == true
  render()
end

noctalia.state.watch("vpn.status", applyStatus)

-- state.watch only fires on later changes, never with the current value, and
-- the service publishes vpn.defaultVpnUuid once at startup. Read it at click
-- time so a shortcut created after that still sees the starred VPN.
function onClick()
  local stored = noctalia.state.get("vpn.defaultVpnUuid")
  local defaultUuid = type(stored) == "string" and stored or ""
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

applyStatus(noctalia.state.get("vpn.status"))
