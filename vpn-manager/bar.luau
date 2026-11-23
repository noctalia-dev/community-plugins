--!nonstrict
-- VPN Manager bar widget: shield glyph that reflects connection state. Click
-- opens the panel, or toggles the default VPN when bar_click_toggles is on.

local connected = false
local activeNames = {}

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

local function applyStatus(status)
  if type(status) == "table" then
    connected = status.anyActive == true
    activeNames = type(status.activeNames) == "table" and status.activeNames or {}
  else
    connected = false
    activeNames = {}
  end
  render()
end

noctalia.state.watch("vpn.status", applyStatus)

local function openPanel()
  noctalia.togglePanel("andrewdems/vpn-manager:panel")
end

-- state.watch only fires on later changes, never with the current value, and
-- the service publishes vpn.defaultVpnUuid once at startup. Read it at click
-- time so a widget created after that still sees the starred VPN.
local function toggleDefault()
  local stored = noctalia.state.get("vpn.defaultVpnUuid")
  local defaultUuid = type(stored) == "string" and stored or ""
  if defaultUuid == "" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notifications.no_default"))
    openPanel()
    return
  end
  local rows = noctalia.state.get("vpn.connections")
  local active = false
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
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

applyStatus(noctalia.state.get("vpn.status"))
