--!nonstrict
local glyph = noctalia.getConfig("glyph")
local tr = noctalia.tr("ps4_colors")

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(tr)
end

-- Left click: apply the saved color directly (no panel needed).
function onClick()
  local saved = noctalia.state.get("lastColor") or "990000"
  noctalia.runAsync("noctalia msg plugin Hy4ri/ps4-colors:service all apply '" .. saved .. "'", function() end)
end

-- Right click: open the panel to pick / save a new color.
function onRightClick()
  noctalia.togglePanel("Hy4ri/ps4-colors:panel")
end

render()
