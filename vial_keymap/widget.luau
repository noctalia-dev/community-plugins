--!nonstrict
-- Bar icon: the Linux counterpart of vial_helper's menu-bar item.
-- Left click toggles the keymap overlay, right click opens the plugin settings.

local PANEL = "egno/vial_keymap:keymap"

barWidget.setGlyph("keyboard")
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
  noctalia.togglePanel(PANEL)
end

function onRightClick()
  noctalia.openSettings()
end

function onMiddleClick()
  noctalia.openSettings()
end

function onIpc(event)
  if event == "toggle" then noctalia.togglePanel(PANEL) end
end
