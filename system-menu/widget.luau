--!nonstrict

function update()
    noctalia.setUpdateInterval(3600000)
    barWidget.setGlyph("device-desktop")
    barWidget.setText("")
    barWidget.setTooltip("System Menu")
end

function onClick()
    noctalia.togglePanel("ajsem1337/system-menu:menu")
end
