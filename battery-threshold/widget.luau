--!nonstrict
local function render_widget()
    local is_available = noctalia.state.get("is_available") == true
    local batteries = noctalia.state.get("batteries") or {}
    local threshold = noctalia.state.get("current_threshold") or 0

    local container = barWidget.isVertical() and ui.column or ui.row

    if not is_available then
        barWidget.render(container({ gap = 4, align = "center" }, {
            ui.glyph({ name = "charging-pile", size = 14, color = "on_surface/0.4" }),
        }))
        barWidget.setTooltip(noctalia.tr("settings.no-battery-device"))
        return
    end

    local label_text = ""
    local tooltip_lines = {}

    if #batteries > 1 then
        local all_same = true
        local first_thresh = batteries[1] and batteries[1].current_threshold or 80
        local thresh_parts = {}

        table.insert(tooltip_lines, noctalia.tr("panel.title") .. ":")

        for _, bat in ipairs(batteries) do
            local b_thresh = bat.current_threshold or 80
            if b_thresh ~= first_thresh then
                all_same = false
            end
            table.insert(thresh_parts, tostring(b_thresh) .. "%")

            local bat_desc = "• " .. bat.name
            if bat.model_name ~= "" then
                bat_desc = bat_desc .. " (" .. bat.model_name .. ")"
            end
            bat_desc = bat_desc .. ": " .. tostring(b_thresh) .. "%"
            if bat.capacity then
                bat_desc = bat_desc .. " [" .. tostring(bat.capacity) .. "%"
                if bat.status and bat.status ~= "" and bat.status ~= "Unknown" then
                    bat_desc = bat_desc .. " · " .. bat.status
                end
                bat_desc = bat_desc .. "]"
            end
            table.insert(tooltip_lines, bat_desc)
        end

        if all_same then
            label_text = tostring(first_thresh) .. "%"
        else
            label_text = table.concat(thresh_parts, " / ")
        end
    else
        label_text = tostring(threshold) .. "%"
        local single_bat = batteries[1]
        local tip = noctalia.tr("panel.title") .. " " .. tostring(threshold) .. "%"
        if single_bat and single_bat.model_name ~= "" then
            tip = tip .. " (" .. single_bat.model_name .. ")"
        end
        table.insert(tooltip_lines, tip)
    end

    barWidget.render(container({ gap = 4, align = "center" }, {
        ui.glyph({ name = "charging-pile", size = 14, color = "primary" }),
        ui.label({ text = label_text, fontWeight = "bold" }),
    }))

    barWidget.setTooltip(table.concat(tooltip_lines, "\n"))
end

noctalia.state.watch("batteries", render_widget)
noctalia.state.watch("current_threshold", render_widget)
noctalia.state.watch("is_available", render_widget)

function onClick()
    noctalia.togglePanel("damian-ds7/battery-threshold:panel")
end

function update()
    render_widget()
end

render_widget()
