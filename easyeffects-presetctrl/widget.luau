local label = noctalia.getConfig("label")
local glyph = noctalia.getConfig("glyph")
local showGlyph = noctalia.getConfig("show_glyph")
local showLabel = noctalia.getConfig("show_label")


local function render()
  if showGlyph then
    barWidget.setGlyph(glyph)
  end
  if showLabel then
    barWidget.setText(label)
  end
end

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

function onClick()
  noctalia.togglePanel("nuddel69/easyeffects-presetctrl:picker")
  render()
end
