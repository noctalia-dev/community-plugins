--!nonstrict

local PANEL_ID = "blackbartblues/clipper:panel"

local function render()
  shortcut.setLabel(noctalia.tr("shortcut.label"))
  shortcut.setIcon("clipboard")
  shortcut.setActive(false)
  shortcut.setEnabled(true)
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end

render()
