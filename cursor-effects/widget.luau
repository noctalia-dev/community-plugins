--!nonstrict
barWidget.setGlyph("mouse-pointer")
barWidget.setTooltip("Cursor Effects")
barWidget.render(ui.row({ gap = 6, align = "center" }, {
	ui.label({ text = "Cursor", fontSize = 12, color = "on_surface" }),
}))
