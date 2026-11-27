--!nonstrict

local vertical = barWidget.isVertical()

local function drawDevice(kind, device)
    local level = device.level
    local value = if level ~= nil then tostring(level) .. "%" else "—"
    local glyph = if kind == "mouse" then "mouse" else "keyboard"
    local color = if device.charging then "secondary" else nil
    local content = ui.row({ gap = 3, align = "center" }, {
        ui.glyph({ name = glyph, color = color }),
        ui.label({ text = value, color = color }),
    })
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
    return content, { key = device.name or noctalia.tr("device." .. kind), value = detail }
end

local function render(data)
    local mouse, mouseTip = drawDevice("mouse", data.mouse or {})
    local keyboard, keyboardTip = drawDevice("keyboard", data.keyboard or {})
    local layout = if vertical then ui.column else ui.row
    barWidget.render(layout({ gap = 7, align = "center" }, { mouse, keyboard }))
    if data.error then
        barWidget.setTooltip({
            { key = "ROG Omni Battery", value = noctalia.tr("error." .. data.error) },
        })
    else
        barWidget.setTooltip({ mouseTip, keyboardTip })
    end
end

local function refresh()
    local count = noctalia.state.get("refresh") or 0
    noctalia.state.set("refresh", count + 1)
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
