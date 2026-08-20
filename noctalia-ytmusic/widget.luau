local STATE = "noctalia_ytmusic.state"

local function render(s)
    local glyph = "brand-youtube-filled"
    local tooltip = "Noctalia YT Music"

    if barWidget then
        if barWidget.setGlyph then barWidget.setGlyph(glyph) end
        if barWidget.setText then barWidget.setText("") end
        if barWidget.setTooltip then barWidget.setTooltip(tooltip) end
    end
end

function onClick()
    noctalia.togglePanel("aabidk20/noctalia-ytmusic:panel")
end

if noctalia.state and noctalia.state.watch then
    noctalia.state.watch(STATE, function(s) render(s) end)
    local curr = noctalia.state.get(STATE)
    if curr then render(curr) end
else
    render(nil)
end