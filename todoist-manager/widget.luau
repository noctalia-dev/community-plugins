--!nonstrict
-- widget.luau (Phase 1)
-- Bar glyph that opens the manager panel. The bar never takes keyboard focus,
-- so this only toggles the panel.
barWidget.setGlyph("checklist")
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
	noctalia.togglePanel("snowballons/todoist-manager:manager")
end
