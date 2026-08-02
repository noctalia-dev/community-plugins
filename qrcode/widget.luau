function update()
  barWidget.setGlyph(noctalia.getConfig("glyph"))
end

function onClick()
    noctalia.togglePanel("yocraft/qrcode:panel")
end
