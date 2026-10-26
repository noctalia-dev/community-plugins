--!nonstrict
-- Bar button for the cursor panel. Optional: the control-centre tile stays the
-- main way in; this only makes the plugin addable from the bar's widget picker.

barWidget.setGlyph("pointer")
barWidget.setTooltip(noctalia.tr("title"))

function onClick()
  noctalia.togglePanel("vn1k/cursor:manager")
end
