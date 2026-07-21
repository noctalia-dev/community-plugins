local glyph = noctalia.getConfig("glyph")

function update()
  noctalia.setUpdateInterval(60000)
  barWidget.setGlyph(glyph)
  barWidget.setTooltip("Game Launcher — click to browse")
end

function onClick()
  noctalia.togglePanel("alexander/game-launcher:browser")
end
