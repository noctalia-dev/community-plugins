--!nonstrict
local client = require("./client.luau")
barWidget.setGlyph("window-minimize")
barWidget.setTooltip("Noctalia Minimize · Minimize active window · Right-click for minimized windows")
function onClick() client.minimize() end
function onRightClick()
    if client.enabled() then noctalia.togglePanel("swashx-dev/minimize:windows") end
end
