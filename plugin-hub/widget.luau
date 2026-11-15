--!nonstrict
-- Plugin Hub bar widget: the hub's glyph. A click opens the hub's panel.

local PANEL = "omerfuyar/plugin-hub:panel"

function update()
  noctalia.setUpdateInterval(60000)
  barWidget.render(ui.glyph({ name = "apps" }))
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
  noctalia.togglePanel(PANEL)
end
