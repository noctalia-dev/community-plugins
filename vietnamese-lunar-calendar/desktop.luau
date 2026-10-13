--!nonstrict
-- Desktop widget: monthly calendar with lunar days, today's details and the
-- next events. Position and size are set in Noctalia's desktop-widgets editor.

local lunar = require("./lunar.luau")
local store = require("./store.luau")

local WEEKDAYS = {
    noctalia.tr("weekdays.t2"), noctalia.tr("weekdays.t3"), noctalia.tr("weekdays.t4"),
    noctalia.tr("weekdays.t5"), noctalia.tr("weekdays.t6"), noctalia.tr("weekdays.t7"),
    noctalia.tr("weekdays.cn"),
}
local MONTH_NAMES = {}
for i = 1, 12 do
    MONTH_NAMES[i] = noctalia.tr("months.m" .. i)
end

local viewMonth = tonumber(noctalia.formatTime("%m"))
local viewYear = tonumber(noctalia.formatTime("%Y"))
local data = noctalia.state.get("calendar")

local function fs(size)
    local scale = tonumber(noctalia.getConfig("font_scale")) or 1.0
    return math.floor(size * scale + 0.5)
end

local function today()
    return tonumber(noctalia.formatTime("%d")),
        tonumber(noctalia.formatTime("%m")),
        tonumber(noctalia.formatTime("%Y"))
end

local function lunarText(l)
    if l.day == 1 then
        return string.format("%d/%d%s", l.day, l.month, l.leap and "N" or "")
    end
    return tostring(l.day)
end

local function dots(list, cats)
    local out = {}
    if list == nil then return out end
    local seen = {}
    for _, ev in ipairs(list) do seen[ev.cat] = true end
    for _, cat in ipairs(cats) do
        if seen[cat.id] then
            table.insert(out, ui.box({
                key = "dot-" .. cat.id, width = 6, height = 6, radius = 3,
                fill = cat.color or store.DEFAULT_COLOR,
            }))
            if #out >= 4 then break end
        end
    end
    return out
end

local function header()
    return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
        ui.button({ glyph = "chevron-left", variant = "ghost", onClick = "prevMonth" }),
        ui.label({
            text = MONTH_NAMES[viewMonth] .. "  ·  " .. tostring(viewYear),
            fontSize = fs(20), fontWeight = "bold",
        }),
        ui.row({ gap = 4, align = "center" }, {
            ui.button({ glyph = "calendar-event", variant = "ghost", onClick = "goToday" }),
            ui.button({ glyph = "chevron-right", variant = "ghost", onClick = "nextMonth" }),
        }),
    })
end

local function grid(cats, byDate)
    local td, tm, ty = today()
    local showFestivals = noctalia.getConfig("show_festivals") ~= false
    local accentWeekends = noctalia.getConfig("accent_weekends") ~= false
    local rows = {}

    local names = {}
    for i, name in ipairs(WEEKDAYS) do
        table.insert(names, ui.label({
            key = "wd-" .. i, text = name, fontSize = fs(12), fontWeight = "bold",
            textAlign = "center", flexGrow = 1,
            color = accentWeekends and i >= 6 and "primary" or "on_surface/0.7",
        }))
    end
    table.insert(rows, ui.row({ gap = 4 }, names))

    local first = lunar.weekdayMondayFirst(1, viewMonth, viewYear)
    local days = lunar.daysInSolarMonth(viewMonth, viewYear)
    local cell = 1
    for week = 1, 6 do
        local row = {}
        for weekday = 1, 7 do
            local day = cell - first + 1
            if day < 1 or day > days then
                table.insert(row, ui.column({ key = "b-" .. week .. "-" .. weekday, flexGrow = 1, minHeight = 52 }, {}))
            else
                local l = lunar.solarToLunar(day, viewMonth, viewYear, 7)
                local festival = showFestivals and lunar.festival(l) or nil
                local isToday = day == td and viewMonth == tm and viewYear == ty
                table.insert(row, ui.column({
                    key = "d-" .. day, gap = 1, padding = 3, flexGrow = 1, minHeight = 52, radius = 8,
                    fill = isToday and "primary/0.25" or festival and "surface_variant/0.40" or "surface/0",
                    border = isToday and "primary" or "outline/0", borderWidth = isToday and 1 or 0,
                    align = "center", justify = "center",
                }, {
                    ui.label({
                        text = tostring(day), fontSize = fs(16), textAlign = "center",
                        fontWeight = isToday and "bold" or "medium",
                        color = isToday and "primary" or accentWeekends and weekday >= 6 and "primary/0.85" or "on_surface",
                    }),
                    ui.label({
                        text = lunarText(l), fontSize = fs(11), textAlign = "center",
                        color = festival and "primary" or "on_surface/0.6",
                    }),
                    ui.row({ gap = 3, align = "center", justify = "center", minHeight = 6 },
                        dots(byDate[store.dateKey(viewYear, viewMonth, day)], cats)),
                }))
            end
            cell = cell + 1
        end
        table.insert(rows, ui.row({ gap = 4 }, row))
        if cell - first > days then break end
    end
    return ui.column({ gap = 4 }, rows)
end

local function todayInfo()
    local td, tm, ty = today()
    local l = lunar.solarToLunar(td, tm, ty, 7)
    local text = string.format("%02d/%02d%s %s", l.day, l.month,
        l.leap and " " .. noctalia.tr("ui.leap") or "", noctalia.tr("ui.lunar_date_suffix"))
    if noctalia.getConfig("show_can_chi") ~= false then
        text = text .. " · " .. noctalia.tr("ui.year") .. " " .. lunar.yearCanChi(l.year)
    end
    local festival = noctalia.getConfig("show_festivals") ~= false and lunar.festival(l) or nil
    if festival then text = text .. " · " .. festival end

    return ui.column({ gap = 2 }, {
        ui.label({ text = string.format("%02d tháng %02d, %d", td, tm, ty), fontSize = fs(15), fontWeight = "bold" }),
        ui.label({ text = text, fontSize = fs(13), color = "on_surface/0.7" }),
    })
end

local function upcomingList()
    local maxItems = math.max(1, math.floor(tonumber(noctalia.getConfig("max_events")) or 4))
    local nowMinutes = store.parseTime(noctalia.formatTime("%H:%M")) or 0
    local list = store.upcoming(data, maxItems, noctalia.formatTime("%Y-%m-%d"), nowMinutes)
    local nodes = {}
    for i, ev in ipairs(list) do
        local when = ev.allDay and noctalia.tr("upcoming.all_day") or store.fmtTime(ev.start)
        table.insert(nodes, ui.row({ key = "ev-" .. i, gap = 8, align = "center" }, {
            ui.box({ width = 8, height = 8, radius = 4, fill = ev.color }),
            ui.label({
                text = string.sub(ev.date, 9, 10) .. "/" .. string.sub(ev.date, 6, 7) .. " " .. when,
                fontSize = fs(12), color = "on_surface/0.7",
            }),
            ui.label({ text = ev.title, fontSize = fs(13), maxLines = 1, flexGrow = 1 }),
        }))
    end
    if #nodes == 0 then
        table.insert(nodes, ui.label({ text = noctalia.tr("upcoming.no_events"), fontSize = fs(12), color = "on_surface/0.55" }))
    end
    return ui.column({ gap = 6 }, nodes)
end

local function render()
    local cats = (type(data) == "table" and type(data.categories) == "table") and data.categories or {}
    local byDate = store.eventsByDate(data)
    desktopWidget.render(ui.column({ gap = 10, padding = 16, radius = 16, fill = "surface/0.85" }, {
        header(),
        grid(cats, byDate),
        ui.separator({ spacing = 2 }),
        todayInfo(),
        upcomingList(),
    }))
end

function prevMonth()
    viewMonth = viewMonth - 1
    if viewMonth < 1 then viewMonth = 12; viewYear = viewYear - 1 end
    render()
end

function nextMonth()
    viewMonth = viewMonth + 1
    if viewMonth > 12 then viewMonth = 1; viewYear = viewYear + 1 end
    render()
end

function goToday()
    local _, m, y = today()
    viewMonth, viewYear = m, y
    render()
end

noctalia.state.watch("calendar", function(value)
    data = value
    render()
end)

function update()
    noctalia.setUpdateInterval(60000) -- also rolls the highlight over at midnight
    render()
end
