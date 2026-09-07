--!nonstrict
-- WiFi Enterprise control-center shortcut: opens the panel. There is nothing
-- to toggle (Noctalia's own Wi-Fi widget already shows connection status);
-- this exists only so the panel is reachable without a bar widget.

local function render()
  shortcut.setLabel(noctalia.tr("title"))
  shortcut.setIcon("shield-lock", "shield-lock")
  shortcut.setActive(false)
  shortcut.setEnabled(true)
end

function onClick()
  noctalia.togglePanel("andrewdems/wifi-enterprise:panel")
end

render()
