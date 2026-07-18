--!nonstrict
local glyph = noctalia.getConfig("glyph")
local tr = noctalia.tr("ds4_color")

local function render()
  barWidget.setGlyph(glyph)
  barWidget.setTooltip(tr)
end

-- Left click: apply the saved color directly (no panel needed).
function onClick()
  local saved = noctalia.state.get("lastColor") or "990000"
  noctalia.runAsync("noctalia msg plugin hy4ri/ds4-color:service all apply '" .. saved .. "'", function() end)
end

-- Right click: open the panel to pick / save a new color.
function onRightClick()
  noctalia.togglePanel("hy4ri/ds4-color:panel")
end

render()
