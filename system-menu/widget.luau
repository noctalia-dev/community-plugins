--!nonstrict

local distroIcon = require("./distro_icon.luau")

function update()
    noctalia.setUpdateInterval(3600000)
    local icon = distroIcon.path(24)
    if icon then
        barWidget.setImage(icon, true, 24, 24)
    else
        barWidget.setGlyph("device-desktop")
    end
    barWidget.setText("")
    barWidget.setTooltip("System Menu")
end

function onClick()
    noctalia.togglePanel("ajsem1337/system-menu:menu")
end
