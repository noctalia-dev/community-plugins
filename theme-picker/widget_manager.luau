--!nonstrict
-- Bar widget: opens the theme manager panel.

local function render()
  barWidget.setGlyph("settings")
  barWidget.setTooltip(noctalia.tr("manager.title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("SirQuacksALot/theme-picker:manager")
end

render()
