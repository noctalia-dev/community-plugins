--!nonstrict

local vertical = barWidget.isVertical()

local function drawDevice(kind, device, showDetail)
    local level = device.level
    local value = if level ~= nil then tostring(level) .. "%" else "—"
    local glyph = if kind == "mouse" then "mouse" else "keyboard"
    local color = if device.charging then "secondary" else nil
    local props = { key = kind, gap = 3, align = "center" }
    if showDetail then
        local detail
        if device.cached then
            detail = noctalia.tr("status.cached", { value = value })
        elseif level ~= nil then
            local key = if device.charging then "status.charging" else "status.not_charging"
            detail = noctalia.tr(key, { value = value })
        elseif device.name then
            detail = noctalia.tr("status.asleep")
        else
            detail = noctalia.tr("status.not_recognized")
        end
        local name = device.name or noctalia.tr("device." .. kind)
        props.tooltip = name .. "\n" .. detail
    end
    return ui.row(props, {
        ui.glyph({ name = glyph, color = color }),
        ui.label({ text = value, color = color }),
    })
end

local function render(data)
    local layout = if vertical then ui.column else ui.row
    local showDetail = not data.error
    barWidget.render(layout({ gap = 7, align = "center" }, {
        drawDevice("mouse", data.mouse or {}, showDetail),
        drawDevice("keyboard", data.keyboard or {}, showDetail),
    }))
    barWidget.setTooltip(if data.error then noctalia.tr("error." .. data.error) else nil)
end

local function refresh()
    local count = noctalia.state.get("refresh") or 0
    noctalia.state.set("refresh", count + 1)
end

function onClick()
    refresh()
end

function onRightClick()
    refresh()
end

function onIpc(event)
    if event == "refresh" then
        refresh()
    end
end

noctalia.state.watch("battery", render)
render(noctalia.state.get("battery") or { error = "loading" })
