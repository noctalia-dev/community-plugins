--!nonstrict
-- Bar button for the icons panel. Optional: the control-centre tile is the
-- other way in; this makes the plugin addable from the bar's widget picker.

barWidget.setGlyph("icons")
barWidget.setTooltip(noctalia.tr("title"))

function onClick()
  noctalia.togglePanel("vn1k/icons:manager")
end
