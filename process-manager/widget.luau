--!nonstrict
-- Process Manager bar widget: a glyph that opens the panel. It shows no figures, since
-- Noctalia's own system monitor shows CPU and memory.

local PANEL = "omerfuyar/process-manager:panel"

function update()
  noctalia.setUpdateInterval(60000)
  barWidget.render(ui.glyph({ name = "list-details" }))
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
  noctalia.togglePanel(PANEL)
end
