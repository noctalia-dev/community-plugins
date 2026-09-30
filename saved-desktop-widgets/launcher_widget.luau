--!nonstrict
-- launcher_widget.luau: Bar widget launcher for Saved Desktop Widgets settings

function update()
  barWidget.setGlyph("settings")
  barWidget.setText(noctalia.tr("launcher.text"))
  noctalia.setUpdateInterval(10000)
end

function onClick()
  -- Toggles the panel using the exact namespace:id from your manifest
  noctalia.togglePanel("hakanct/saved-desktop-widgets:settings")
end