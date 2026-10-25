local Heatmap = require("./heatmap.luau")
local M = {}
local intensities = { "primary/0.25", "primary/0.45", "primary/0.7", "primary" }
local function tr(key, values) return noctalia.tr("heatmap." .. key, values) end
local function label(text, width, size, color, align)
    return ui.label({ text = text, width = width, maxWidth = width, maxLines = 1,
        fontSize = size or 10, color = color or "on_surface_variant", textAlign = align or "start", baseline = "textFixedHeight" })
end
local function exact(value, metric)
    local number = value % 1 == 0 and string.format("%.0f", value) or tostring(value)
    return metric == "cost" and "$" .. number or number
end
local function style(cell)
    if cell.state == "value" then return intensities[cell.level], "primary/0.12" end
    if cell.state == "zero" then return "on_surface/0.16", "on_surface/0.18" end
    if cell.state == "unknown" then return "secondary/0.1", "secondary/0.65" end
    if cell.state == "missing" then return "surface/0.2", "on_surface/0.14" end
    return "on_surface/0.025", "on_surface/0.04"
end
local function tooltip(cell, metric)
    if not cell.date then return nil end
    local value = cell.value ~= nil and exact(cell.value, metric) or tr(cell.state)
    return cell.date .. " · " .. tr(metric) .. ": " .. value
end
local function monthRow(data, size, gap, width)
    local stride, markers = size + gap, {}
    for index, column in ipairs(data.columns) do
        for _, cell in ipairs(column.cells) do
            if cell.month and (index == 1 and cell.weekday == 1 or cell.day == 1) then
                if #markers == 0 or markers[#markers].week ~= index then
                    markers[#markers + 1] = { week = index, month = cell.month }
                else markers[#markers].month = cell.month end
            end
        end
    end
    local children, cursor = {}, 1
    for index, marker in ipairs(markers) do
        local nextWeek = markers[index + 1] and markers[index + 1].week or data.weeks + 1
        if marker.week > cursor then children[#children + 1] = ui.box({ width = (marker.week - cursor) * stride, height = 14 }) end
        local span = (nextWeek - marker.week) * stride - (nextWeek == data.weeks + 1 and gap or 0)
        children[#children + 1] = ui.column({ width = span }, {
            label(span >= 25 and tr("month_" .. tostring(marker.month)) or "", span, 9),
        })
        cursor = nextWeek
    end
    return ui.row({ width = width, height = 14, gap = 0, align = "center" }, children)
end
local function legendItem(state, text)
    local fill, border = style({ state = state })
    return ui.row({ gap = 4, align = "center", tooltip = tr(state .. "_help") }, {
        ui.box({ width = 8, height = 8, radius = 2, fill = fill, border = border, borderWidth = 1 }),
        label(text, nil, 9),
    })
end
function M.render(dailyRows, ctx)
    ctx = ctx or {}
    local data = Heatmap.build(dailyRows, ctx)
    local width = ctx.width or 480
    local children = { ui.row({ align = "center", gap = 10 }, {
        ui.label({ text = tr("title"), fontSize = 13, fontWeight = "semibold", flexGrow = 1,
            color = "on_surface", maxLines = 1, baseline = "textFixedHeight" }),
        label(tr(data.metric), nil, 10, "primary"),
    }) }
    if not data.valid then children[#children + 1] = label(tr("calendar_unavailable"), width - 32)
    else
        local gap = data.weeks == 13 and 4 or 3
        local size = math.min(data.weeks == 13 and 24 or 18, math.floor((width - 64 - (data.weeks - 1) * gap) / data.weeks))
        size = math.max(4, size)
        local gridWidth, gridHeight = data.weeks * size + (data.weeks - 1) * gap, 7 * size + 6 * gap
        children[#children + 1] = label(tr("range", { first = data.firstDate or "", last = data.today, weeks = data.weeks }), width - 32, 10)
        local weekdays = {}
        for day = 1, 7 do
            weekdays[#weekdays + 1] = ui.column({ width = 24, height = size, justify = "center" }, {
                label((day == 1 or day == 3 or day == 5 or day == 7) and tr("weekday_" .. tostring(day)) or "", 24, 9, nil, "end"),
            })
        end
        local columns = {}
        for index, column in ipairs(data.columns) do
            local cells = {}
            for _, cell in ipairs(column.cells) do
                local fill, border = style(cell)
                local props = { key = "heatmap-day-" .. (cell.date or tostring(index) .. "-" .. tostring(cell.weekday)),
                    width = size, height = size, radius = size > 18 and 4 or 3,
                    fill = fill, border = cell.selected and "on_surface" or border, borderWidth = cell.selected and 2 or 1,
                    tooltip = tooltip(cell, data.metric) }
                if cell.recorded and ctx.onSelectDay then
                    local date = cell.date
                    props.onClick = function() ctx.onSelectDay(date) end
                end
                cells[#cells + 1] = ui.box(props)
            end
            columns[#columns + 1] = ui.column({ key = "heatmap-week-" .. tostring(index), width = size, gap = gap }, cells)
        end
        children[#children + 1] = ui.row({ width = width - 32, justify = "center", align = "start", gap = 8 }, {
            ui.column({ width = 24, gap = 6 }, { ui.box({ height = 14, fill = "on_surface/0" }), ui.column({ gap = gap, height = gridHeight }, weekdays) }),
            ui.column({ width = gridWidth, gap = 6 }, { monthRow(data, size, gap, gridWidth),
                ui.row({ width = gridWidth, height = gridHeight, gap = gap, align = "start" }, columns) }),
        })
        local scale = { label(tr("low"), nil, 9) }
        for _, color in ipairs(intensities) do scale[#scale + 1] = ui.box({ width = 8, height = 8, radius = 2, fill = color }) end
        scale[#scale + 1] = label(tr("high"), nil, 9)
        children[#children + 1] = ui.row({ width = width - 32, align = "center", gap = 10 }, {
            legendItem("missing", tr("missing")), legendItem("zero", tr("zero")), legendItem("unknown", tr("unknown_short")),
            ui.spacer({ flexGrow = 1 }),
            ui.row({ gap = 3, align = "center", tooltip = tr("scale_help", { peak = exact(data.peak, data.metric) }) }, scale),
        })
    end
    return ui.column({ key = "activity-heatmap", width = width, padding = 16, gap = 10,
        radius = 12, fill = "surface_variant/0.25", border = "on_surface/0.06", borderWidth = 1 }, children)
end
return M
