--!nonstrict
-- Bar widget: opens the categorized wallpaper picker panel.

local function render()
  barWidget.setGlyph("photo")
  barWidget.setTooltip(noctalia.tr("wallpapers.title"))
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel("SirQuacksALot/theme-picker:wallpapers")
end

render()
