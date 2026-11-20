--!nonstrict
-- VPN Manager bar widget: shield glyph that reflects connection state. Click
-- opens the panel, or toggles the default VPN when bar_click_toggles is on.

local connected = false
local activeNames = {}
local connections = {}
local defaultUuid = ""

local function render()
  barWidget.setGlyph(connected and "shield-lock-filled" or "shield-lock")
  if connected then
    barWidget.setColor("primary")
  else
    barWidget.setColor("on_surface_variant")
  end
  if connected and #activeNames > 0 then
    barWidget.setTooltip(noctalia.tr("tooltip.connected", { names = table.concat(activeNames, ", ") }))
  else
    barWidget.setTooltip(noctalia.tr("tooltip.disconnected"))
  end
end

noctalia.state.watch("vpn.status", function(status)
  if type(status) == "table" then
    connected = status.anyActive == true
    activeNames = type(status.activeNames) == "table" and status.activeNames or {}
  else
    connected = false
    activeNames = {}
  end
  render()
end)

noctalia.state.watch("vpn.connections", function(rows)
  connections = type(rows) == "table" and rows or {}
end)

noctalia.state.watch("vpn.defaultVpnUuid", function(uuid)
  defaultUuid = type(uuid) == "string" and uuid or ""
end)

local function openPanel()
  noctalia.togglePanel("andrewdems/vpn-manager:panel")
end

local function toggleDefault()
  if defaultUuid == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.no_default"))
    openPanel()
    return
  end
  local active = false
  for _, row in ipairs(connections) do
    if row.uuid == defaultUuid then
      active = row.active == true
    end
  end
  noctalia.state.set("vpn.cmd", { op = active and "disconnect" or "connect", uuid = defaultUuid })
end

function onClick()
  if noctalia.getConfig("bar_click_toggles") == true then
    toggleDefault()
  else
    openPanel()
  end
end

function onRightClick()
  openPanel()
end

render()
