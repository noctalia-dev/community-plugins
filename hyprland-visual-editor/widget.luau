--!nonstrict
-- HVE v5 — Bar Widget (abre el panel)

barWidget.setGlyph("adjustments-horizontal")
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
  noctalia.togglePanel("linux-fertxo/hyprland-visual-editor:hve-panel")
end
