-- widget.luau -- Monitor Manager: bar widget

local function update()
    local raw = noctalia.state.get("monitors")
    if not raw or raw == "" then
        barWidget.render(ui.glyph({ name = "device-desktop", size = 16, color = "on_surface" }))
        return
    end

    local list = noctalia.json.decode(raw)
    if not list or #list == 0 then
        barWidget.render(ui.glyph({ name = "device-desktop", size = 16, color = "on_surface" }))
        return
    end

    local countOn = 0
    for _, m in ipairs(list) do
        if m.on then countOn = countOn + 1 end
    end

    local color = "#22c55e"
    if countOn == 0 then color = "#ef4444"
    elseif countOn < #list then color = "#facc15" end

    barWidget.render(ui.glyph({ name = "device-desktop", size = 16, color = "on_surface" }))
end

noctalia.state.watch("monitors", function(_value)
    update()
end)

function onClick()
    noctalia.togglePanel("rael2pac/hdmi-toggle:panel")
end

update()
