--!nonstrict

local PANEL_ID = "nomadcxx/gslapper:picker"

local function render()
  barWidget.setGlyph(noctalia.getConfig("glyph") or "wallpaper-selector")
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end

render()
