function update()
  noctalia.setUpdateInterval(1000)
  barWidget.setGlyph("battery")
end

function onClick()
  noctalia.togglePanel("FraI3mega/battery-graph:battery-panel")
end
