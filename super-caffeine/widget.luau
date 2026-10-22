--!nonstrict
local status = noctalia.state.get("super_caffeine_status") or { active = false, busy = false }
local requestId = 0

local function render()
    if status.busy then
        barWidget.setGlyph("loader-2")
        barWidget.setGlyphColor("primary")
        barWidget.setTooltip("Super Caffeine: switching…")
    elseif status.active then
        barWidget.setGlyph("coffee")
        barWidget.setGlyphColor("tertiary")
        barWidget.setTooltip("Super Caffeine ON: no idle lock, lid close won't suspend")
    else
        barWidget.setGlyph("coffee-off")
        barWidget.setGlyphColor("on_surface_variant")
        barWidget.setTooltip("Super Caffeine OFF")
    end
end

noctalia.state.watch("super_caffeine_status", function(value)
    if type(value) == "table" then
        status = value
        render()
    end
end)

function onClick()
    if status.busy then return end
    requestId += 1
    noctalia.state.set("super_caffeine_command", { action = "toggle", requestId = `widget-{requestId}` })
end

render()
