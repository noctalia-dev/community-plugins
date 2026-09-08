--!nonstrict
-- Bar tile: left opens the display panel, right goes straight to the
-- arrangement. The right binding lives here rather than in [widget.actions]
-- because Noctalia 5.0.0-beta.8 does not apply manifest-declared gesture
-- defaults.

barWidget.setGlyph(noctalia.getConfig("glyph"))
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
  noctalia.togglePanel("prponkshe/umbriel-displays:panel")
end

function onRightClick()
  noctalia.togglePanel("prponkshe/umbriel-displays:arrange")
end
