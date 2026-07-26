-- widget.luau -- Audio Switcher: bar widget

local streamCount = 0
local loaded = false

local function tr(key, fallback)
    local v = noctalia.tr(key)
    if v == nil or v == key then return fallback or key end
    return v
end

local function render()
    if not loaded then
        barWidget.setVisible(true)
        barWidget.render(ui.row({ gap = 5, align = "center" }, {
            ui.glyph({ name = "speakerphone", size = 16, color = "on_surface" }),
        }))
        return
    end

    barWidget.setVisible(true)

    barWidget.render(ui.row({ gap = 5, align = "center" }, {
        ui.glyph({ name = "speakerphone", size = 16, color = "on_surface" }),
    }))

    barWidget.setTooltip(tr("widget.tooltip", "Roteamento de audio"))
end

noctalia.state.watch("audio", function(value)
    if value and value ~= "" then
        local ok, d = pcall(noctalia.json.decode, value)
        if ok and d and d.streams then
            streamCount = #d.streams
        else
            streamCount = 0
        end
    else
        streamCount = 0
    end
    loaded = true
    render()
end)

function onClick()
    noctalia.togglePanel("rael2pac/audio-switcher:panel")
end

render()
