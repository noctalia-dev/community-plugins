--!nonstrict
-- Bar widget that opens the palettes panel.

local function render()
  barWidget.setGlyph("palette")
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
  noctalia.togglePanel("soul/palettes:panel") -- must match [plugin].id AND [[panel]].id
end

render()