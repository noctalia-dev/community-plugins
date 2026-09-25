--!nonstrict
local lunar = require("./lunar.luau")

local function today()
    local d = tonumber(noctalia.formatTime("%d"))
    local m = tonumber(noctalia.formatTime("%m"))
    local y = tonumber(noctalia.formatTime("%Y"))
    return d, m, y
end

function update()
    noctalia.setUpdateInterval(60000)

    local dateText = noctalia.formatTime("%d %b")

    barWidget.setGlyph("calendar")
    barWidget.setText(dateText)
end

function onClick()
    noctalia.togglePanel("notoxus/vietnamese-lunar-calendar:calendar")
end
