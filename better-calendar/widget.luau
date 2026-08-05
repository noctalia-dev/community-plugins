--!nonstrict
-- Apple-inspired desktop calendar widget.

local MONTHS = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
}

local DAYS_MON = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }
local DAYS_SUN = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }

local function daysInMonth(year, month)
    local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then
        return 29
    end
    return days[month]
end

local function firstDayOffset(year, month, weekStart)
    local t = os.time({ year = year, month = month, day = 1 })
    local wday = os.date("*t", t).wday
    if weekStart == "monday" then
        return (wday + 5) % 7
    else
        return (wday + 6) % 7
    end
end

function update()
    noctalia.setUpdateInterval(60000)

    local weekStart = noctalia.getConfig("week_start") or "monday"
    local dayNames = weekStart == "sunday" and DAYS_SUN or DAYS_MON

    local now = os.date("*t")
    local year = now.year
    local month = now.month
    local today = now.day

    local totalDays = daysInMonth(year, month)
    local offset = firstDayOffset(year, month, weekStart)

    local children = {}

    -- Header: month + year
    table.insert(children, ui.row({
        justify = "space_between",
        align = "center",
    }, {
        ui.label({
            text = MONTHS[month],
            fontSize = 16,
            fontWeight = "semibold",
            color = "primary",
        }),
        ui.label({
            text = tostring(year),
            fontSize = 14,
            color = "on_surface_variant",
        }),
    }))

    -- Day names
    local dayRow = {}
    for _, d in ipairs(dayNames) do
        table.insert(dayRow, ui.label({
            text = d,
            fontSize = 11,
            fontWeight = "medium",
            color = "on_surface_variant",
            textAlign = "center",
            width = 32,
        }))
    end
    table.insert(children, ui.row({ justify = "space_between" }, dayRow))

    -- Calendar grid
    local row = {}
    local col = 0

    for _ = 1, offset do
        table.insert(row, ui.label({ text = "", width = 32, textAlign = "center" }))
        col = col + 1
    end

    for day = 1, totalDays do
        local isToday = day == today
        table.insert(row, ui.row({
            width = 32,
            height = 28,
            radius = 8,
            fill = isToday and "primary/0.20" or nil,
            align = "center",
            justify = "center",
        }, {
            ui.label({
                text = tostring(day),
                fontSize = 12,
                fontWeight = isToday and "bold" or "regular",
                color = isToday and "primary" or "on_surface",
                textAlign = "center",
            }),
        }))
        col = col + 1

        if col == 7 then
            table.insert(children, ui.row({ justify = "space_between" }, row))
            row = {}
            col = 0
        end
    end

    if col > 0 then
        while col < 7 do
            table.insert(row, ui.label({ text = "", width = 32 }))
            col = col + 1
        end
        table.insert(children, ui.row({ justify = "space_between" }, row))
    end

    desktopWidget.render(ui.column({
        paddingH = 14,
        paddingV = 14,
        gap = 8,
    }, children))
end
