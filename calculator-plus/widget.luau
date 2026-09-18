-- widget.luau
-- Bar icon that toggles the calculator panel.
local glyph = noctalia.getConfig("glyph")
barWidget.setGlyph(glyph)
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
	noctalia.togglePanel("samuelskovbakke/calculator-plus:panel")
end

function onRightClick()
	noctalia.openSettings()
end
