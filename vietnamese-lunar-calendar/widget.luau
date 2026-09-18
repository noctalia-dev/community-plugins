--!nonstrict
local lunar = require("./lunar.luau")

local MONTH_ABBR = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

local function today()
    local d = tonumber(noctalia.formatTime("%d"))
    local m = tonumber(noctalia.formatTime("%m"))
    local y = tonumber(noctalia.formatTime("%Y"))
    return d, m, y
end

function update()
    noctalia.setUpdateInterval(60000)

    local d, m, _ = today()

    barWidget.setGlyph("calendar")
    barWidget.setText(string.format("%d %s", d, MONTH_ABBR[m]))
end

function onClick()
    noctalia.togglePanel("notoxus/vietnamese-lunar-calendar:calendar")
end
