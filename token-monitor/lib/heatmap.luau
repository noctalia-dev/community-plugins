-- Calendar-only daily buckets. No timezone conversion or inferred activity.
local M = {}
local daysInMonth = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function leap(year) return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) end
local function monthLength(year, month) return daysInMonth[month] + (month == 2 and leap(year) and 1 or 0) end
local function yearStart(year)
    local y = year - 1
    return 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400)
end
function M.parseDate(value)
    if type(value) ~= "string" then return nil end
    local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    local year, month, day = tonumber(y), tonumber(m), tonumber(d)
    if year < 1 or month < 1 or month > 12 or day < 1 or day > monthLength(year, month) then return nil end
    local ordinal = yearStart(year) + day - 1
    for index = 1, month - 1 do ordinal += monthLength(year, index) end
    return { year = year, month = month, day = day, ordinal = ordinal, weekday = ordinal % 7 + 1 }
end
function M.dateFromOrdinal(ordinal)
    if type(ordinal) ~= "number" or ordinal % 1 ~= 0 or ordinal < 0 or ordinal >= yearStart(10000) then return nil end
    local low, high = 1, 9999
    while low < high do
        local mid = math.ceil((low + high) / 2)
        if yearStart(mid) <= ordinal then low = mid else high = mid - 1 end
    end
    local year, month, day = low, 1, ordinal - yearStart(low) + 1
    while day > monthLength(year, month) do day -= monthLength(year, month); month += 1 end
    return string.format("%04d-%02d-%02d", year, month, day), month, day
end
local function nonnegative(value)
    return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

function M.build(dailyRows, ctx)
    ctx = ctx or {}
    local today = M.parseDate(ctx.today)
    local weeks = ctx.heatmapWeeks == 13 and 13 or 26
    local metric = (ctx.heatmapMetric == "cost" or ctx.heatmapMetric == "messages") and ctx.heatmapMetric or "tokens"
    local result = { valid = today ~= nil, weeks = weeks, metric = metric, columns = {}, peak = 0,
        recordedCount = 0, knownCount = 0, today = ctx.today }
    if not today then return result end
    local first = today.ordinal - today.weekday + 1 - (weeks - 1) * 7
    local last = first + weeks * 7 - 1
    local byDate = {}
    if type(dailyRows) == "table" then
        for _, row in ipairs(dailyRows) do
            if type(row) == "table" then
                local date = M.parseDate(row.date)
                if date and date.ordinal >= first and date.ordinal <= today.ordinal then
                    -- Last duplicate wins; summing duplicate buckets would invent totals.
                    byDate[row.date] = { value = nonnegative(row[metric]) and row[metric] or nil }
                end
            end
        end
    end
    for date, row in pairs(byDate) do
        result.recordedCount += 1
        if not result.latestRecordedDate or date > result.latestRecordedDate then result.latestRecordedDate = date end
        if row.value ~= nil then result.knownCount += 1; result.peak = math.max(result.peak, row.value) end
    end
    for week = 1, weeks do
        local column = { cells = {} }
        for weekday = 1, 7 do
            local ordinal = first + (week - 1) * 7 + weekday - 1
            local date, month, day = M.dateFromOrdinal(ordinal)
            local row = date and byDate[date]
            local state = not date and "outside" or ordinal > today.ordinal and "future"
                or not row and "missing" or row.value == nil and "unknown" or row.value == 0 and "zero" or "value"
            local value = row and row.value
            column.cells[weekday] = { date = date, month = month, day = day, weekday = weekday,
                state = state, value = value, recorded = row ~= nil,
                selected = row ~= nil and ctx.selectedDay == date,
                level = state == "value" and math.max(1, math.min(4, math.ceil(value / result.peak * 4))) or 0 }
        end
        result.columns[week] = column
    end
    result.firstDate = M.dateFromOrdinal(first)
    result.lastDate = M.dateFromOrdinal(last)
    return result
end
return M
