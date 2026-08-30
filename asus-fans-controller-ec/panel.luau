--!nonstrict
-- Asus Fans Controller EC — unified control panel.

local COMMAND_KEY = "fan_command"
local STATUS_KEY = "fan_status"

local MODE_AUTO = "auto"
local MODE_MANUAL = "manual"
local MODE_CURVE = "curve"

local opened = false
local render
local sliderPreviews = {}
local curveTempPreview = nil
local curvePercentPreview = nil
local commandNonce = 0

local status = noctalia.state.get(STATUS_KEY) or {
    available = false,
    controlMode = MODE_AUTO,
    synced = true,
    busy = false,
    fanCount = 0,
    fans = {},
    temps = {},
    curve = { points = {}, selectedIndex = 1 },
    error = "",
}

local function sendCommand(payload)
    commandNonce = commandNonce + 1
    payload.nonce = commandNonce
    noctalia.state.set(COMMAND_KEY, payload)
end

local function controlMode()
    local mode = status.controlMode
    if mode == MODE_MANUAL or mode == MODE_CURVE or mode == MODE_AUTO then
        return mode
    end
    return MODE_AUTO
end

local function clearCurvePreviews()
    curveTempPreview = nil
    curvePercentPreview = nil
end

local function clearSliderPreviews()
    sliderPreviews = {}
    clearCurvePreviews()
end

local function sliderShown(key, percent)
    local preview = sliderPreviews[key]
    if preview ~= nil then return preview end
    return tonumber(percent) or 0
end

local function fanSpeedText(fan)
    return tostring(fan.rpm or 0) .. " RPM"
end

local function fanLineText(index, fan)
    local fanIndex = fan.index or index - 1
    local fanNumber = fanIndex + 1
    local sensorTemps = status.temps or {}
    local tempText = nil
    if fanIndex == 0 and sensorTemps.cpu ~= nil then
        tempText = noctalia.tr("panel.temp_cpu", { temp = tostring(sensorTemps.cpu) })
    elseif fanIndex == 1 and sensorTemps.board ~= nil then
        tempText = noctalia.tr("panel.temp_board", { temp = tostring(sensorTemps.board) })
    end
    if tempText then
        return noctalia.tr("panel.fan_speed_temp", {
            fan = tostring(fanNumber),
            rpm = fanSpeedText(fan),
            temp = tempText,
        })
    end
    return noctalia.tr("panel.fan_speed", {
        fan = tostring(fanNumber),
        rpm = fanSpeedText(fan),
    })
end

local function fanSummaryText()
    local parts = {}
    local sensorTemps = status.temps or {}
    if sensorTemps.max ~= nil then
        table.insert(parts, noctalia.tr("panel.max_temp", { temp = tostring(sensorTemps.max) }))
    end
    for index, fan in ipairs(status.fans or {}) do
        table.insert(parts, fanLineText(index, fan))
    end
    return table.concat(parts, " · ")
end

local function modeButton(mode, label)
    local active = controlMode() == mode
    return ui.button({
        key = "mode-" .. mode,
        text = label,
        variant = active and "primary" or "outline",
        flexGrow = 1,
        enabled = status.busy ~= true,
        onClick = function()
            clearSliderPreviews()
            sendCommand({ action = "set_mode", mode = mode })
        end,
    })
end

local function sliderRow(key, label, percent, fanIndex)
    local value = tonumber(percent) or 0
    local shown = sliderShown(key, value)
    local enabled = controlMode() == MODE_MANUAL and status.busy ~= true and status.available == true

    return ui.column({ key = key, gap = 6 }, {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({ key = key .. "-label", text = label, fontWeight = "medium" }),
            ui.label({
                key = key .. "-value",
                text = tostring(shown) .. "%",
                fontWeight = "bold",
                color = "primary",
            }),
        }),
        ui.slider({
            key = key .. "-slider",
            min = 0,
            max = 100,
            step = 1,
            value = shown,
            enabled = enabled,
            onChange = function(nextValue)
                sliderPreviews[key] = tonumber(nextValue) or shown
                render()
            end,
            onDragEnd = function(nextValue)
                local target = sliderPreviews[key] or tonumber(nextValue) or shown
                sliderPreviews[key] = nil
                if fanIndex == nil or status.synced == true then
                    sendCommand({ action = "set_all_percent", percent = target })
                else
                    sendCommand({ action = "set_fan_percent", fan = fanIndex, percent = target })
                end
            end,
        }),
    })
end

local function curveGraphValues(points)
    local values = {}
    for _, point in ipairs(points or {}) do
        local percent = math.max(0, tonumber(point.percent) or 0)
        -- Keep a visible baseline when a point is at 0%.
        table.insert(values, math.max(0.03, percent) / 100)
    end
    if #values < 2 then
        table.insert(values, 0.03)
    end
    return values
end

local function renderCurveGraph(points, selectedIndex)
    local tempLabels = {}
    local pointButtons = {}
    for index, point in ipairs(points) do
        local selected = index == selectedIndex
        table.insert(tempLabels, ui.label({
            key = "curve-temp-" .. tostring(index),
            text = tostring(point.temp) .. "°C",
            fontSize = 10,
            color = selected and "primary" or "on_surface_variant",
            textAlign = "center",
            flexGrow = 1,
        }))
        table.insert(pointButtons, ui.button({
            key = "curve-point-" .. tostring(index),
            text = tostring(index),
            variant = selected and "primary" or "outline",
            flexGrow = 1,
            enabled = status.busy ~= true,
            onClick = function()
                clearSliderPreviews()
                sendCommand({ action = "select_curve_point", index = index })
            end,
        }))
    end

    return ui.column({ key = "curve-graph-block", gap = 6 }, {
        ui.box({
            key = "curve-graph-frame",
            fill = "surface_variant/0.35",
            radius = 10,
            padding = 10,
        }, {
            ui.graph({
                key = "curve-graph",
                values = curveGraphValues(points),
                color = "primary",
                lineWidth = 2,
                fillOpacity = 0.22,
                height = 88,
            }),
        }),
        ui.row({ key = "curve-temp-labels", gap = 4, align = "center" }, tempLabels),
        ui.row({ key = "curve-point-buttons", gap = 6, align = "center" }, pointButtons),
    })
end

local function renderManualControls(busy)
    local synced = status.synced == true
    local children = {
        ui.label({
            text = noctalia.tr("panel.mode.manual_help"),
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 2,
        }),
        ui.row({ align = "center", gap = 8 }, {
            ui.toggle({
                checked = synced,
                enabled = not busy and controlMode() == MODE_MANUAL,
                onChange = function(value)
                    clearSliderPreviews()
                    sendCommand({ action = "set_synced", value = value == "true" })
                    render()
                end,
            }),
            ui.label({ text = noctalia.tr("panel.sync_fans"), flexGrow = 1 }),
        }),
    }

    if synced then
        local master = status.fans and status.fans[1] and status.fans[1].percent or 50
        table.insert(children, sliderRow("manual-all", noctalia.tr("panel.all_fans"), master, nil))
    else
        for index, fan in ipairs(status.fans or {}) do
            local fanIndex = fan.index or index - 1
            table.insert(children, sliderRow(
                "manual-fan-" .. tostring(fanIndex),
                noctalia.tr("panel.fan_label", { fan = tostring(fanIndex + 1) }),
                fan.percent or 50,
                fanIndex
            ))
        end
    end

    return ui.column({ key = "manual-controls", gap = 8 }, children)
end

local function renderCurveControls(busy, available)
    local curve = status.curve or {}
    local points = curve.points or {}
    local selectedIndex = tonumber(curve.selectedIndex) or 1
    local selected = points[selectedIndex]
    if selected == nil then
        return ui.label({ text = noctalia.tr("panel.curve.empty"), color = "on_surface_variant" })
    end

    local tempShown = curveTempPreview or tonumber(selected.temp) or 0
    local percentShown = curvePercentPreview or tonumber(selected.percent) or 0
    local graphPoints = {}
    for index, point in ipairs(points) do
        graphPoints[index] = { percent = point.percent, temp = point.temp }
        if index == selectedIndex then
            graphPoints[index].percent = percentShown
            graphPoints[index].temp = tempShown
        end
    end

    local editingEnabled = available and not busy

    return ui.column({ key = "curve-controls", gap = 8 }, {
        ui.label({
            text = noctalia.tr("panel.mode.curve_help"),
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 2,
        }),
        renderCurveGraph(graphPoints, selectedIndex),
        ui.label({
            text = noctalia.tr("panel.curve.selected", {
                index = tostring(selectedIndex),
                temp = tostring(tempShown),
                percent = tostring(percentShown),
            }),
            fontSize = 12,
        }),
        ui.column({ gap = 6 }, {
            ui.row({ align = "center", justify = "space_between" }, {
                ui.label({ text = noctalia.tr("panel.curve.temperature"), fontWeight = "medium" }),
                ui.label({ text = tostring(tempShown) .. "°C", color = "primary", fontWeight = "bold" }),
            }),
            ui.slider({
                key = "curve-temp",
                min = 0, max = 105, step = 1,
                value = tempShown,
                enabled = editingEnabled,
                onChange = function(value)
                    curveTempPreview = tonumber(value) or tempShown
                    render()
                end,
                onDragEnd = function(value)
                    local target = curveTempPreview or tonumber(value) or tempShown
                    clearCurvePreviews()
                    sendCommand({ action = "set_curve_temp", temp = target })
                end,
            }),
        }),
        ui.column({ gap = 6 }, {
            ui.row({ align = "center", justify = "space_between" }, {
                ui.label({ text = noctalia.tr("panel.curve.speed"), fontWeight = "medium" }),
                ui.label({ text = tostring(percentShown) .. "%", color = "primary", fontWeight = "bold" }),
            }),
            ui.slider({
                key = "curve-percent",
                min = 0, max = 100, step = 1,
                value = percentShown,
                enabled = editingEnabled,
                onChange = function(value)
                    curvePercentPreview = tonumber(value) or percentShown
                    render()
                end,
                onDragEnd = function(value)
                    local target = curvePercentPreview or tonumber(value) or percentShown
                    clearCurvePreviews()
                    sendCommand({ action = "set_curve_percent", percent = target })
                end,
            }),
        }),
        ui.row({ gap = 8 }, {
            ui.button({
                text = noctalia.tr("panel.curve.add_point"),
                glyph = "plus",
                variant = "outline",
                enabled = editingEnabled and #points < 8,
                onClick = function()
                    clearSliderPreviews()
                    sendCommand({ action = "add_curve_point" })
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.curve.remove_point"),
                glyph = "minus",
                variant = "outline",
                enabled = editingEnabled and #points > 2,
                onClick = function()
                    clearSliderPreviews()
                    sendCommand({ action = "remove_curve_point" })
                end,
            }),
        }),
    })
end

local function modeStatus()
    local mode = controlMode()
    if not status.available then
        return noctalia.tr("panel.status.unavailable_title"),
            status.error ~= "" and status.error or noctalia.tr("panel.status.unavailable_message"),
            "error", "alert-circle"
    end
    if status.busy == true then
        return noctalia.tr("panel.status.busy_title"),
            noctalia.tr("panel.status.busy_message"),
            "on_surface_variant", "loader-2"
    end
    if mode == MODE_MANUAL then
        return noctalia.tr("panel.status.manual_title"),
            noctalia.tr("panel.status.manual_message"),
            "tertiary", "car-fan-2"
    end
    if mode == MODE_CURVE then
        return noctalia.tr("panel.status.curve_title"),
            noctalia.tr("panel.status.curve_message"),
            "primary", "chart-line"
    end
    return noctalia.tr("panel.status.auto_title"),
        noctalia.tr("panel.status.auto_message"),
        "secondary", "car-fan"
end

render = function()
    if not opened then return end

    local busy = status.busy == true
    local available = status.available == true
    local mode = controlMode()
    local title, message, color, glyph = modeStatus()

    local scrollChildren = {}

    if available then
        if mode == MODE_AUTO then
            table.insert(scrollChildren, ui.row({
                align = "center", gap = 10,
                fill = "surface_variant/0.45", radius = 10, padding = 10,
            }, {
                ui.glyph({ name = glyph, size = 16, color = color }),
                ui.column({ gap = 2, flexGrow = 1 }, {
                    ui.label({ text = title, fontWeight = "medium", color = color, fontSize = 13 }),
                    ui.label({ text = message, color = "on_surface_variant", maxLines = 2, fontSize = 11 }),
                }),
            }))
        end

        local summary = fanSummaryText()
        if summary ~= "" then
            table.insert(scrollChildren, ui.label({
                text = summary,
                fontSize = 11,
                color = "on_surface_variant",
                maxLines = 3,
            }))
        end

        table.insert(scrollChildren, ui.separator({ thickness = 1, color = "outline/0.3", spacing = 4 }))

        if mode == MODE_MANUAL then
            table.insert(scrollChildren, renderManualControls(busy))
        elseif mode == MODE_CURVE then
            table.insert(scrollChildren, renderCurveControls(busy, available))
        else
            table.insert(scrollChildren, ui.label({
                text = noctalia.tr("panel.mode.auto_help"),
                fontSize = 11,
                color = "on_surface_variant",
                maxLines = 3,
            }))
        end

        if mode ~= MODE_AUTO then
            table.insert(scrollChildren, ui.button({
                text = noctalia.tr("panel.release_bios"),
                glyph = "cpu",
                variant = "outline",
                enabled = not busy,
                onClick = "onReleaseBios",
            }))
        end
    else
        table.insert(scrollChildren, ui.row({
            align = "center", gap = 10,
            fill = "surface_variant/0.45", radius = 10, padding = 10,
        }, {
            ui.glyph({ name = glyph, size = 16, color = color }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = title, fontWeight = "medium", color = color, fontSize = 13 }),
                ui.label({
                    text = status.error ~= "" and status.error or message,
                    color = "on_surface_variant",
                    maxLines = 3,
                    fontSize = 11,
                }),
            }),
        }))
    end

    local rootChildren = {
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.row({ align = "center", gap = 9, flexGrow = 1 }, {
                ui.glyph({ name = "car-fan", size = 18, color = "primary" }),
                ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold" }),
            }),
            ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.refresh"), enabled = not busy, onClick = "onRefresh" }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onCloseClicked" }),
        }),
    }

    if available then
        table.insert(rootChildren, ui.row({ key = "mode-buttons", gap = 8 }, {
            modeButton(MODE_AUTO, noctalia.tr("panel.mode.auto")),
            modeButton(MODE_MANUAL, noctalia.tr("panel.mode.manual")),
            modeButton(MODE_CURVE, noctalia.tr("panel.mode.curve")),
        }))
    end

    table.insert(rootChildren, ui.scroll({
        key = "panel-body",
        flexGrow = 1,
        gap = 8,
        align = "stretch",
    }, scrollChildren))

    panel.render(ui.column({
        key = "panel-root",
        flexGrow = 1,
        gap = 8,
        padding = 12,
        align = "stretch",
    }, rootChildren))
end

noctalia.state.watch(STATUS_KEY, function(value)
    if type(value) ~= "table" then return end
    status = value
    if opened then render() end
end)

function onOpen(_context)
    opened = true
    clearSliderPreviews()
    status = noctalia.state.get(STATUS_KEY) or status
    sendCommand({ action = "panel_open" })
    render()
end

function onClose()
    opened = false
    sendCommand({ action = "panel_close" })
end

function onCloseClicked()
    panel.close()
end

function onRefresh()
    sendCommand({ action = "refresh", detail = true })
end

function onReleaseBios()
    sendCommand({ action = "set_mode", mode = MODE_AUTO })
end
