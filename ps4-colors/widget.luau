--!nonstrict
local glyph = noctalia.getConfig("glyph")
local tr = noctalia.tr("ps4_colors")

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(tr)
end

function onClick()
  noctalia.togglePanel("Hy4ri/ps4-colors:panel")
end

render()
