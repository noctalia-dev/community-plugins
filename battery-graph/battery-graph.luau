function update()
  noctalia.setUpdateInterval(1000)
  barWidget.setGlyph("battery")
end

function onClick()
  noctalia.togglePanel("frai3mega/battery-graph:battery-panel")
end
