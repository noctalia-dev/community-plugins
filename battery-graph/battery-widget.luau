function update()
  noctalia.setUpdateInterval(1000)
  barWidget.setGlyph("puzzle")
  barWidget.setText("Hello")
end

function onClick()
  noctalia.notify("Hello", "you clicked me")
end
