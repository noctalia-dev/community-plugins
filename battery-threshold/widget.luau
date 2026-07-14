--!nonstrict
local function render_widget()
    local is_available = noctalia.state.get("is_available") == true
    local threshold = noctalia.state.get("current_threshold") or 0

    local container = barWidget.isVertical() and ui.column or ui.row

    if is_available then
        barWidget.render(container({ gap = 4, align = "center" }, {
            ui.glyph({ name = "charging-pile", size = 14 }),
            ui.label({ text = tostring(threshold) .. "%", fontWeight = "bold" }),
        }))
        barWidget.setTooltip(
            noctalia.tr("panel.title") .. " " .. tostring(threshold) .. "%"
        )
    else
        barWidget.render(container({ gap = 4, align = "center" }, {
            ui.glyph({ name = "charging-pile", size = 14, color = "on_surface/0.4" }),
        }))
        barWidget.setTooltip(noctalia.tr("settings.no-battery-device"))
    end
end

noctalia.state.watch("current_threshold", render_widget)
noctalia.state.watch("is_available", render_widget)

function onClick() noctalia.togglePanel("damian-ds7/battery-threshold:panel") end

function update() render_widget() end

noctalia.setUpdateInterval(10000)
render_widget()
