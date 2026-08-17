--!nonstrict
local is_open = false

local function render_panel()
    if not is_open then
        return
    end

    local is_available = noctalia.state.get("is_available") == true
    local is_writable = noctalia.state.get("is_writable") == true
    local batteries = noctalia.state.get("batteries") or {}
    local threshold = noctalia.state.get("current_threshold") or 0
    local model_name = noctalia.state.get("battery_model_name") or ""

    local title_text = noctalia.tr("panel.title")
    local sub_text = ""
    if not is_available then
        sub_text = noctalia.tr("panel.not-available")
    elseif #batteries > 1 then
        sub_text = noctalia.tr("panel.multiple-batteries", { count = #batteries })
    else
        sub_text = model_name
    end

    local children = {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.glyph({ name = "battery-eco", size = 20, color = "primary" }),
                ui.column({ gap = 2 }, {
                    ui.label({
                        text = title_text,
                        fontSize = 15,
                        fontWeight = "bold",
                        color = "primary",
                    }),
                    ui.label({
                        text = sub_text,
                        fontSize = 11,
                        color = "on_surface_variant",
                        maxLines = 1,
                    }),
                }),
            }),
            ui.button({
                glyph = "close",
                variant = "ghost",
                controlSize = "sm",
                onClick = "onCloseClicked",
            }),
        }),
    }

    if is_available then
        table.insert(
            children,
            ui.separator({ thickness = 1, color = "outline/0.3", spacing = 4 })
        )

        -- If any battery is not writable, show permission setup banner
        local has_unwritable = not is_writable
        if #batteries > 0 then
            for _, b in ipairs(batteries) do
                if b.is_writable == false then
                    has_unwritable = true
                    break
                end
            end
        end

        if has_unwritable then
            table.insert(
                children,
                ui.column({
                    gap = 6,
                    padding = 8,
                    radius = 8,
                    fill = "error/0.1",
                    border = "error/0.3",
                    borderWidth = 1,
                    align = "center",
                }, {
                    ui.label({
                        text = noctalia.tr("panel.read-only"),
                        fontSize = 11,
                        color = "error",
                        textAlign = "center",
                        maxLines = 2,
                    }),
                    ui.button({
                        text = noctalia.tr("panel.button"),
                        glyph = "shield-lock",
                        variant = "primary",
                        controlSize = "sm",
                        onClick = "onRunSetup",
                    }),
                })
            )
        end

        if #batteries > 1 then
            -- Multi-battery display in scrollable list
            local battery_cards = {}

            for _, bat in ipairs(batteries) do
                local bat_name = bat.name
                local bat_model = bat.model_name ~= "" and bat.model_name or ""
                local bat_status = bat.status ~= "" and bat.status or ""
                local bat_cap = bat.capacity or 0
                local bat_thresh = bat.current_threshold or 80
                local bat_writable = bat.is_writable == true

                local status_desc = tostring(bat_cap) .. "%"
                if bat_status ~= "" and bat_status ~= "Unknown" then
                    status_desc = status_desc .. " · " .. bat_status
                end

                local card = ui.column({
                    gap = 5,
                    padding = 8,
                    radius = 8,
                    fill = "surface_variant/0.35",
                    border = "outline/0.25",
                    borderWidth = 1,
                    align = "stretch",
                }, {
                    ui.row({ align = "center", justify = "space_between" }, {
                        ui.row({ align = "center", gap = 6 }, {
                            ui.label({
                                text = bat_name,
                                fontSize = 13,
                                fontWeight = "bold",
                                color = "primary",
                            }),
                            ui.label({
                                text = bat_model ~= "" and ("(" .. bat_model .. ")") or "",
                                fontSize = 11,
                                color = "on_surface_variant",
                                maxLines = 1,
                            }),
                        }),
                        ui.label({
                            text = tostring(bat_thresh) .. "%",
                            fontSize = 14,
                            fontWeight = "bold",
                            color = "primary",
                        }),
                    }),
                    ui.row({ align = "center", justify = "space_between" }, {
                        ui.label({
                            text = status_desc,
                            fontSize = 10,
                            color = "on_surface_variant",
                        }),
                        ui.label({
                            text = if bat_writable
                                then noctalia.tr("panel.adjust-limit")
                                else noctalia.tr("panel.read-only"),
                            fontSize = 10,
                            color = if bat_writable then "on_surface_variant" else "error",
                        }),
                    }),
                    ui.row({ align = "center", gap = 8 }, {
                        ui.label({
                            text = "40%",
                            fontSize = 10,
                            color = "on_surface_variant",
                        }),
                        ui.slider({
                            min = 40,
                            max = 100,
                            step = 5,
                            value = bat_thresh,
                            enabled = bat_writable,
                            flexGrow = 1,
                            onChange = function(val)
                                local num = tonumber(val)
                                if num then
                                    bat.current_threshold = num
                                    noctalia.state.set("set_battery_threshold_request", {
                                        name = bat_name,
                                        value = num,
                                    })
                                    render_panel()
                                end
                            end,
                        }),
                        ui.label({
                            text = "100%",
                            fontSize = 10,
                            color = "on_surface_variant",
                        }),
                    }),
                })

                table.insert(battery_cards, card)
            end

            table.insert(
                children,
                ui.scroll({
                    flexGrow = 1,
                    gap = 8,
                    align = "stretch",
                }, {
                    ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, battery_cards),
                })
            )

            -- Quick action button to sync all batteries
            table.insert(
                children,
                ui.row({ justify = "space_between", align = "center" }, {
                    ui.button({
                        text = noctalia.tr("panel.sync-all"),
                        glyph = "refresh",
                        variant = "outline",
                        controlSize = "sm",
                        onClick = "onSyncAll80",
                    }),
                    ui.button({
                        text = "100% (" .. noctalia.tr("panel.max") .. ")",
                        glyph = "bolt",
                        variant = "ghost",
                        controlSize = "sm",
                        onClick = "onSyncAll100",
                    }),
                })
            )
        else
            -- Single battery display
            local single_bat = batteries[1]
            local cur_thresh = if single_bat
                then single_bat.current_threshold
                else threshold
            local writable = if single_bat then single_bat.is_writable else is_writable

            if writable then
                table.insert(
                    children,
                    ui.column({ gap = 8, flexGrow = 1, align = "stretch" }, {
                        ui.row({ align = "center", justify = "space_between" }, {
                            ui.label({
                                text = title_text,
                                fontSize = 14,
                                color = "on_surface",
                            }),
                            ui.label({
                                text = tostring(cur_thresh) .. "%",
                                fontSize = 16,
                                fontWeight = "bold",
                                color = "primary",
                            }),
                        }),
                        ui.row({ align = "center", gap = 8 }, {
                            ui.label({
                                text = "40%",
                                fontSize = 11,
                                color = "on_surface_variant",
                            }),
                            ui.slider({
                                min = 40,
                                max = 100,
                                step = 5,
                                value = cur_thresh,
                                enabled = writable,
                                flexGrow = 1,
                                onChange = "onSliderChange",
                            }),
                            ui.label({
                                text = "100%",
                                fontSize = 11,
                                color = "on_surface_variant",
                            }),
                        }),
                        ui.label({
                            text = noctalia.tr("panel.adjust-limit"),
                            fontSize = 11,
                            color = "on_surface_variant",
                            textAlign = "center",
                        }),
                    })
                )
            end
        end
    end

    panel.render(ui.column({
        flexGrow = 1,
        gap = 8,
        padding = 12,
        align = "stretch",
    }, children))
end

function onOpen(context: string?)
    is_open = true
    render_panel()
end

function onClose()
    is_open = false
end

function onSliderChange(value: string)
    local num = tonumber(value)
    if num then
        noctalia.state.set("set_threshold_request", num)
        noctalia.state.set("current_threshold", num)
        render_panel()
    end
end

function onSyncAll80()
    noctalia.state.set("set_threshold_request", 80)
    noctalia.state.set("current_threshold", 80)
    render_panel()
end

function onSyncAll100()
    noctalia.state.set("set_threshold_request", 100)
    noctalia.state.set("current_threshold", 100)
    render_panel()
end

function onCloseClicked()
    panel.close()
end

function onRunSetup()
    noctalia.state.set("run_setup_request", true)
end

noctalia.state.watch("batteries", function()
    if is_open then
        render_panel()
    end
end)

noctalia.state.watch("current_threshold", function()
    if is_open then
        render_panel()
    end
end)

noctalia.state.watch("is_writable", function()
    if is_open then
        render_panel()
    end
end)

noctalia.state.watch("is_available", function()
    if is_open then
        render_panel()
    end
end)
