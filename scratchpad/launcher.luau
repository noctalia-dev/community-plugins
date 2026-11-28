--!nonstrict
-- Optional bar button: click to open the scratchpad panel.

barWidget.setGlyph("note")
barWidget.setText(noctalia.getConfig("label") or "Notes")
barWidget.setTooltip(noctalia.tr("open_tooltip"))

function onClick()
  noctalia.togglePanel("xinghui/scratchpad:pad")
end
