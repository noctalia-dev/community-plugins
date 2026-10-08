--!nonstrict
local common = require("./common.luau")

local is_open = false

local function render_panel()
    if not is_open then
        return
    end

    local is_available = noctalia.state.get(common.STATE.IS_AVAILABLE) == true
    local is_writable = noctalia.state.get(common.STATE.IS_WRITABLE) == true
    local threshold = noctalia.state.get(common.STATE.CURRENT_THRESHOLD) or 0
    local model_name = noctalia.state.get(common.STATE.BATTERY_MODEL_NAME) or ""

    local title_text = noctalia.tr("panel.title")
    local sub_text = ""
    if not is_available then
        sub_text = noctalia.tr("panel.not-available")
    else
        sub_text = model_name
    end

    local hint_text = ""
    local hint_color = "on_surface_variant"
    if not is_writable then
        hint_text = noctalia.tr("panel.read-only")
        hint_color = "error"
    else
        hint_text = noctalia.tr("panel.adjust-limit")
    end

    local children = {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({
                    text = title_text,
                    fontSize = 16,
                    fontWeight = "bold",
                    color = "primary",
                }),
                ui.label({
                    text = sub_text,
                    fontSize = 12,
                    color = "on_surface_variant",
                }),
            }),
            ui.button({
                glyph = "close",
                variant = "ghost",
                onClick = "onCloseClicked",
            }),
        }),
    }

    if is_available then
        table.insert(children, ui.separator({ thickness = 1, color = "outline/0.3", spacing = 8 }))

        if is_writable then
            table.insert(
                children,
                ui.column({ gap = 8 }, {
                    ui.row({ align = "center", justify = "space_between" }, {
                        ui.label({
                            text = title_text,
                            fontSize = 14,
                            color = "on_surface",
                        }),
                        ui.label({
                            text = tostring(threshold) .. "%",
                            fontSize = 16,
                            fontWeight = "bold",
                            color = "primary",
                        }),
                    }),
                    ui.row({ align = "center", gap = 8 }, {
                        ui.label({
                            text = tostring(common.MIN_THRESHOLD) .. "%",
                            fontSize = 11,
                            color = "on_surface_variant",
                        }),
                        ui.slider({
                            min = common.MIN_THRESHOLD,
                            max = common.MAX_THRESHOLD,
                            step = 5,
                            value = threshold,
                            enabled = is_writable,
                            flexGrow = 1,
                            onChange = "onSliderChange",
                        }),
                        ui.label({
                            text = tostring(common.MAX_THRESHOLD) .. "%",
                            fontSize = 11,
                            color = "on_surface_variant",
                        }),
                    }),
                    ui.label({
                        text = hint_text,
                        fontSize = 11,
                        color = hint_color,
                        textAlign = "center",
                    }),
                })
            )
        else
            table.insert(
                children,
                ui.column({ gap = 12, align = "center" }, {
                    ui.label({
                        text = hint_text,
                        fontSize = 12,
                        color = "error",
                        textAlign = "center",
                        maxLines = 2,
                    }),
                    ui.button({
                        text = noctalia.tr("panel.button"),
                        glyph = "shield-lock",
                        variant = "primary",
                        onClick = "onRunSetup",
                    }),
                })
            )
        end
    end

    panel.render(ui.column({ gap = 12, padding = 12 }, children))
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
        common.requestThreshold(num)
        render_panel()
    end
end

function onCloseClicked()
    panel.close()
end

function onRunSetup()
    noctalia.state.set(common.STATE.RUN_SETUP_REQUEST, true)
end

noctalia.state.watch(common.STATE.CURRENT_THRESHOLD, function()
    if is_open then
        render_panel()
    end
end)

noctalia.state.watch(common.STATE.BATTERY_MODEL_NAME, function()
    if is_open then
        render_panel()
    end
end)

noctalia.state.watch(common.STATE.IS_WRITABLE, function()
    if is_open then
        render_panel()
    end
end)

noctalia.state.watch(common.STATE.IS_AVAILABLE, function()
    if is_open then
        render_panel()
    end
end)
