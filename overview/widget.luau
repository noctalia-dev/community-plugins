--!nonstrict
-- Overview bar widget: a grid glyph that opens the overview.

local PANEL = "omerfuyar/overview:panel"

function update()
  noctalia.setUpdateInterval(60000)
  barWidget.render(ui.glyph({ name = "layout-grid" }))
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
  noctalia.togglePanel(PANEL)
end
