-- widget.luau
-- Bar icon that toggles the calculator panel.

barWidget.setGlyph("calculator")
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
	noctalia.togglePanel("samuelskovbakke/calculator-plus:calculator")
end

