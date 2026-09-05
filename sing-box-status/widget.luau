--!nonstrict
local running = false

local function render()
    if running then
        barWidget.setGlyph("link-plus")
        barWidget.setGlyphColor("tertiary")
        barWidget.setTooltip("Sing-box is running")
    else
        barWidget.setGlyph("link")
        barWidget.setGlyphColor("on_surface")
        barWidget.setTooltip("Sing-box is not running")
    end
end

noctalia.setUpdateInterval(1000)

local function check()
    noctalia.runAsync("pgrep sing-box >/dev/null 2>&1", function(result)
        running = result.exitCode == 0
        render()
    end)
end

function update()
    check()
end

check()
