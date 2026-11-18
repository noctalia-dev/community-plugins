local glyph = noctalia.getConfig("glyph")

local function render()
  barWidget.setGlyph(glyph)
end

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

function onClick()
  noctalia.togglePanel("profidev/hypr-screen-mirror:panel")
end
