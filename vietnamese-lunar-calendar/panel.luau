--!nonstrict
local lunar = require("./lunar.luau")

local WEEKDAYS = { "T2", "T3", "T4", "T5", "T6", "T7", "CN" }
local MONTH_NAMES = {
    "Tháng 1", "Tháng 2", "Tháng 3", "Tháng 4",
    "Tháng 5", "Tháng 6", "Tháng 7", "Tháng 8",
    "Tháng 9", "Tháng 10", "Tháng 11", "Tháng 12",
}

local viewMonth = tonumber(noctalia.formatTime("%m"))
local viewYear = tonumber(noctalia.formatTime("%Y"))
local selectedDay = nil
local selectedMonth = nil
local selectedYear = nil

local function today()
    return tonumber(noctalia.formatTime("%d")),
        tonumber(noctalia.formatTime("%m")),
        tonumber(noctalia.formatTime("%Y"))
end

local function goMonth(delta)
    viewMonth = viewMonth + delta

    if viewMonth < 1 then
        viewMonth = 12
        viewYear = viewYear - 1
    elseif viewMonth > 12 then
        viewMonth = 1
        viewYear = viewYear + 1
    end

    if selectedDay ~= nil then
        selectedDay = math.min(selectedDay, lunar.daysInSolarMonth(viewMonth, viewYear))
        selectedMonth = viewMonth
        selectedYear = viewYear
    end
end

local function lunarText(l)
    if l.day == 1 then
        return string.format("%d/%d%s", l.day, l.month, l.leap and "N" or "")
    end
    return tostring(l.day)
end

local FESTIVAL_LABELS = {
    ["Tết Nguyên Đán"] = "Tết",
    ["Rằm tháng Giêng"] = "Rằm T.Giêng",
    ["Tết Hàn Thực"] = "Hàn Thực",
    ["Giỗ Tổ Hùng Vương"] = "Giỗ Tổ",
    ["Tết Đoan Ngọ"] = "Đoan Ngọ",
    ["Lễ Vu Lan"] = "Vu Lan",
    ["Tết Trung Thu"] = "Trung Thu",
    ["Ông Công Ông Táo"] = "Ông Táo",
}

local function festivalLabel(name)
    return FESTIVAL_LABELS[name] or name
end

local function render()
    local todayDay, todayMonth, todayYear = today()
    if selectedDay == nil then
        selectedDay = todayDay
        selectedMonth = todayMonth
        selectedYear = todayYear
    end
    local showFestivals = noctalia.getConfig("show_festivals") ~= false
    local showCanChi = noctalia.getConfig("show_can_chi") ~= false
    local accentWeekends = noctalia.getConfig("accent_weekends") ~= false
    local showTimezone = noctalia.getConfig("show_timezone") ~= false

    local children = {}

    table.insert(children, ui.row({
        align = "center",
        justify = "space_between",
    }, {
        ui.button({
            glyph = "chevron-left",
            variant = "ghost",
            tooltip = "Tháng trước",
            onClick = function()
                goMonth(-1)
                render()
            end,
        }),
        ui.column({ align = "center", gap = 2 }, {
            ui.label({
                text = MONTH_NAMES[viewMonth] .. "  ·  " .. tostring(viewYear),
                fontSize = 19,
                fontWeight = "bold",
            }),
            ui.label({
                text = showTimezone and "Âm lịch Việt Nam · UTC+7" or "Âm lịch Việt Nam",
                fontSize = 12,
                color = "on_surface/0.6",
            }),
        }),
        ui.button({
            glyph = "chevron-right",
            variant = "ghost",
            tooltip = "Tháng sau",
            onClick = function()
                goMonth(1)
                render()
            end,
        }),
    }))

    local weekdayNodes = {}
    for i, name in ipairs(WEEKDAYS) do
        table.insert(weekdayNodes, ui.label({
            key = "weekday-" .. tostring(i),
            text = name,
            fontSize = 12,
            fontWeight = "bold",
            textAlign = "center",
            flexGrow = 1,
            color = accentWeekends and i >= 6 and "primary" or "on_surface/0.7",
        }))
    end
    table.insert(children, ui.row({ gap = 4 }, weekdayNodes))

    local firstWeekday = lunar.weekdayMondayFirst(1, viewMonth, viewYear)
    local days = lunar.daysInSolarMonth(viewMonth, viewYear)

    local cell = 1
    for week = 1, 6 do
        local row = {}

        for weekday = 1, 7 do
            local day = cell - firstWeekday + 1

            if day < 1 or day > days then
                table.insert(row, ui.column({
                    key = "blank-" .. tostring(week) .. "-" .. tostring(weekday),
                    minHeight = 56,
                    flexGrow = 1,
                }, {}))
            else
                local l = lunar.solarToLunar(day, viewMonth, viewYear, 7)
                local festival = showFestivals and lunar.festival(l) or nil
                local isToday =
                    day == todayDay
                    and viewMonth == todayMonth
                    and viewYear == todayYear
                local isSelected =
                    day == selectedDay
                    and viewMonth == selectedMonth
                    and viewYear == selectedYear

                local dayChildren = {
                    ui.label({
                        text = tostring(day),
                        fontSize = 16,
                        fontWeight = (isToday or isSelected) and "bold" or "medium",
                        textAlign = "center",
                        color = (isToday or isSelected) and "primary"
                            or accentWeekends and weekday >= 6 and "primary/0.85"
                            or "on_surface",
                    }),
                    ui.label({
                        text = lunarText(l),
                        fontSize = 11,
                        textAlign = "center",
                        color = festival and "primary" or "on_surface/0.55",
                    }),
                }

                if festival then
                    table.insert(dayChildren, ui.label({
                        text = festivalLabel(festival),
                        fontSize = 8,
                        maxLines = 1,
                        textAlign = "center",
                        color = "primary",
                    }))
                end

                table.insert(row, ui.column({
                    key = "day-" .. tostring(day),
                    gap = 1,
                    padding = 4,
                    minHeight = 56,
                    flexGrow = 1,
                    radius = 8,
                    fill = isSelected and "primary/0.18"
                        or isToday and "surface/0"
                        or festival and "surface_variant/0.40"
                        or "surface/0",
                    border = (isSelected or isToday) and "primary" or "outline/0",
                    borderWidth = (isSelected or isToday) and 1 or 0,
                    align = "center",
                    justify = "center",
                    onClick = function()
                        selectedDay = day
                        selectedMonth = viewMonth
                        selectedYear = viewYear
                        render()
                    end,
                }, dayChildren))
            end

            cell = cell + 1
        end

        table.insert(children, ui.row({ gap = 4 }, row))

        if cell - firstWeekday > days then
            break
        end
    end

    local selectedLunar = lunar.solarToLunar(selectedDay, selectedMonth, selectedYear, 7)
    local festival = showFestivals and lunar.festival(selectedLunar) or nil
    local lunarDetails = string.format(
        "%02d/%02d%s âm lịch",
        selectedLunar.day,
        selectedLunar.month,
        selectedLunar.leap and " nhuận" or ""
    )
    if showCanChi then
        lunarDetails = lunarDetails .. " · Năm " .. lunar.yearCanChi(selectedLunar.year)
    end
    if festival then
        lunarDetails = lunarDetails .. " · " .. festival
    end

    table.insert(children, ui.separator({ spacing = 4 }))

    table.insert(children, ui.row({
        align = "center",
        justify = "space_between",
        gap = 8,
    }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({
                text = string.format(
                    "%02d tháng %02d, %d",
                    selectedDay,
                    selectedMonth,
                    selectedYear
                ),
                fontSize = 13,
                fontWeight = "medium",
            }),
            ui.label({
                text = lunarDetails,
                fontSize = 12,
                color = "on_surface/0.65",
            }),
        }),
        ui.button({
            text = "Hôm nay",
            glyph = "calendar-event",
            variant = "secondary",
            controlSize = "sm",
            onClick = function()
                viewMonth = todayMonth
                viewYear = todayYear
                selectedDay = todayDay
                selectedMonth = todayMonth
                selectedYear = todayYear
                render()
            end,
        }),
    }))

    panel.render(ui.column({
        gap = 8,
        padding = 16,
    }, children))
end

function onOpen(context)
    local todayDay, todayMonth, todayYear = today()
    viewMonth = todayMonth
    viewYear = todayYear
    selectedDay = todayDay
    selectedMonth = todayMonth
    selectedYear = todayYear
    render()
end

function update()
    render()
end
