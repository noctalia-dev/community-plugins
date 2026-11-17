--!nonstrict
-- Bind gestures here because the host does not apply manifest gesture defaults.

barWidget.setGlyph(noctalia.getConfig("glyph"))
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
  noctalia.togglePanel("prponkshe/umbriel-displays:panel")
end

function onRightClick()
  noctalia.togglePanel("prponkshe/umbriel-displays:arrange")
end
