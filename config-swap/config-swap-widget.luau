function update()
  noctalia.setUpdateInterval(1000)
  barWidget.setGlyph("file")
end

function onClick()
  noctalia.togglePanel("tadomika_ari/config-swap:panel")
end