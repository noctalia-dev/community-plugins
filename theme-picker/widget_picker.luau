--!nonstrict
-- Bar widget: opens the theme picker panel.

local function render()
  barWidget.setGlyph("palette")
  barWidget.setTooltip(noctalia.tr("picker.title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("SirQuacksALot/theme-picker:picker")
end

render()
