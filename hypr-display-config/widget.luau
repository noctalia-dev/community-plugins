--!nonstrict

local PANEL_ID = "maddingo/hypr-display-config:panel"

local function render()
  barWidget.setGlyph("layout-grid")
  barWidget.setText("Displays")
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

render()
