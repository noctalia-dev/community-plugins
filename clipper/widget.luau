--!nonstrict

local PANEL_ID = "blackbartblues/clipper:panel"

local function render()
  barWidget.setGlyph("clipboard")
  barWidget.setText("")
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end

render()
