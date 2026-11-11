--!nonstrict
-- Pomodoro Heatmap - pure analytics over the session log.
--
-- A session record is { s = startSec, e = endSec, d = focusedSec, c = completed }.
-- Everything is bucketed by the *local* calendar day of the session start.

local M = {}

M.HEATMAP_WEEKS = 26
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local DAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

-- Local-midnight-safe day arithmetic: anchor on noon so DST shifts never
-- push a date across a day boundary.
local function noonOf(sec)
    local t = os.date("*t", sec)
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })
end

function M.dayKey(sec)
    return os.date("%Y-%m-%d", sec)
end

function M.shiftDays(sec, days)
    local t = os.date("*t", noonOf(sec))
    return os.time({ year = t.year, month = t.month, day = t.day + days, hour = 12 })
end

-- Monday = 1 ... Sunday = 7
function M.weekdayMon(sec)
    local wday = tonumber(os.date("%w", sec)) or 0 -- 0 = Sunday
    return wday == 0 and 7 or wday
end

-- Locale-independent labels (os.date's %a/%b follow LC_TIME).
function M.dayLabel(sec, withYear)
    local t = os.date("*t", sec)
    local s = string.format("%s %d %s", DAYS[M.weekdayMon(sec)], t.day, MONTHS[t.month])
    if withYear then s ..= " " .. t.year end
    return s
end

-- Calendar days as integers (days since 1970-01-01), so walking the calendar is
-- plain arithmetic instead of thousands of os.date/os.time calls.
local floor = math.floor

local function daysFromCivil(y, m, d)
    if m <= 2 then y -= 1 end
    local era = floor(y / 400)
    local yoe = y - era * 400
    local doy = floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function civilFromDays(z)
    z += 719468
    local era = floor(z / 146097)
    local doe = z - era * 146097
    local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
    local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
    local mp = floor((5 * doy + 2) / 153)
    local d = doy - floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end

local function dayOf(sec)
    local t = os.date("*t", sec)
    return daysFromCivil(t.year, t.month, t.day), t
end

local function keyOf(n)
    local y, m, d = civilFromDays(n)
    return string.format("%04d-%02d-%02d", y, m, d)
end

local function weekdayOf(n) -- Monday = 1 ... Sunday = 7 (day 0 was a Thursday)
    return (n + 3) % 7 + 1
end

local function labelOf(n, withYear)
    local y, m, d = civilFromDays(n)
    local s = string.format("%s %d %s", DAYS[weekdayOf(n)], d, MONTHS[m])
    if withYear then s ..= " " .. y end
    return s
end

local function levelFor(minutes, goal, peak)
    if minutes <= 0 then return 0 end
    local ref = goal > 0 and goal or peak
    if ref <= 0 then return 1 end
    local ratio = minutes / ref
    if ratio >= 1 then return 4 end
    if ratio >= 0.66 then return 3 end
    if ratio >= 0.33 then return 2 end
    return 1
end

-- Session records never change once logged, so their calendar lookups are cached.
local memo = setmetatable({}, { __mode = "k" })

function M.compute(sessions, nowSec, goalMin)
    goalMin = goalMin or 0
    local byDay = {} -- day number -> { sec, count }
    local hours = table.create(24, 0)
    local weekdays = table.create(7, 0)
    local totalSec, totalCount, partialCount = 0, 0, 0

    for _, r in ipairs(sessions) do
        local d = tonumber(r.d) or 0
        if d > 0 and r.s then
            local info = memo[r]
            if not info or info.s ~= r.s then
                local n, t = dayOf(r.s)
                info = { s = r.s, n = n, hour = t.hour, into = t.min * 60 + t.sec }
                memo[r] = info
            end
            local n = info.n
            local day = byDay[n]
            if not day then
                day = { sec = 0, count = 0 }
                byDay[n] = day
            end
            day.sec += d
            totalSec += d
            if r.c then
                day.count += 1
                totalCount += 1
            else
                partialCount += 1
            end
            -- Spread the minutes over the clock hours they actually covered.
            local hour, intoHour, remaining = info.hour, info.into, d
            while remaining > 0 do
                local chunk = math.min(remaining, 3600 - intoHour)
                hours[hour + 1] += chunk / 60
                remaining -= chunk
                hour, intoHour = (hour + 1) % 24, 0
            end
            weekdays[weekdayOf(n)] += d / 60
        end
    end

    local function minutesOn(n)
        local day = byDay[n]
        return day and day.sec / 60 or 0, day and day.count or 0
    end

    local today = dayOf(nowSec)
    local todayMin, todayCount = minutesOn(today)

    -- Rolling 7-day windows.
    local weekMin, prevWeekMin, weekCount = 0, 0, 0
    for i = 0, 6 do
        local m, c = minutesOn(today - i)
        weekMin += m
        weekCount += c
        prevWeekMin += (minutesOn(today - i - 7))
    end

    -- Streaks (a day counts when any focus time was logged).
    local streak = 0
    local cursor = todayMin > 0 and today or today - 1 -- today isn't over yet
    while (minutesOn(cursor)) > 0 do
        streak += 1
        cursor -= 1
    end

    local days = {}
    for n in pairs(byDay) do table.insert(days, n) end
    table.sort(days)
    local best, run, prev = 0, 0, nil
    local bestDay, bestDayMin = nil, 0
    for _, n in ipairs(days) do
        run = (prev and n == prev + 1) and run + 1 or 1
        prev = n
        if run > best then best = run end
        local m = byDay[n].sec / 60
        if m > bestDayMin then bestDay, bestDayMin = n, m end
    end

    -- Heatmap: weeks as columns (Mon..Sun rows), ending with the current week.
    local weeks = M.HEATMAP_WEEKS
    local gridStart = today - (weekdayOf(today) - 1) - (weeks - 1) * 7
    local peak = 0
    for n = gridStart, gridStart + weeks * 7 - 1 do
        local m = minutesOn(n)
        if m > peak then peak = m end
    end
    local columns, monthLabels = {}, {}
    local lastMonth = nil
    local activeDays, rangeMin = 0, 0
    for w = 1, weeks do
        local cells = {}
        for wd = 1, 7 do
            local n = gridStart + (w - 1) * 7 + wd - 1
            local m, c = minutesOn(n)
            local future = n > today
            if not future and m > 0 then
                activeDays += 1
                rangeMin += m
            end
            cells[wd] = {
                date = keyOf(n),
                label = labelOf(n, true),
                min = floor(m + 0.5),
                count = c,
                level = future and -1 or levelFor(m, goalMin, peak),
                today = n == today,
            }
        end
        columns[w] = cells
        -- Month label on the first column that contains the 1st..7th of a month.
        local _, month = civilFromDays(gridStart + (w - 1) * 7)
        if month ~= lastMonth then
            monthLabels[w] = MONTHS[month]
            lastMonth = month
        else
            monthLabels[w] = ""
        end
    end

    -- Last 14 days for the bar chart.
    local recent = {}
    for n = today - 13, today do
        local m, c = minutesOn(n)
        table.insert(recent, {
            date = keyOf(n),
            short = DAYS[weekdayOf(n)]:sub(1, 1),
            label = labelOf(n, false),
            min = floor(m + 0.5),
            count = c,
        })
    end

    for i = 1, 24 do hours[i] = floor(hours[i] + 0.5) end
    for i = 1, 7 do weekdays[i] = floor(weekdays[i] + 0.5) end

    local peakHour, peakHourMin = nil, 0
    for i = 1, 24 do
        if hours[i] > peakHourMin then peakHour, peakHourMin = i - 1, hours[i] end
    end

    return {
        today = { min = floor(todayMin + 0.5), count = todayCount },
        goal = goalMin,
        week = { min = floor(weekMin + 0.5), prevMin = floor(prevWeekMin + 0.5), count = weekCount },
        streak = streak,
        bestStreak = best,
        total = { min = floor(totalSec / 60 + 0.5), count = totalCount, partial = partialCount, days = #days },
        completion = (totalCount + partialCount) > 0 and totalCount / (totalCount + partialCount) or nil,
        bestDay = bestDay and { date = keyOf(bestDay), min = floor(bestDayMin + 0.5) } or nil,
        peakHour = peakHour,
        heatmap = {
            weeks = weeks,
            columns = columns,
            months = monthLabels,
            activeDays = activeDays,
            rangeMin = floor(rangeMin + 0.5),
            useGoal = goalMin > 0,
        },
        recent = recent,
        hours = hours,
        weekdays = weekdays,
        computedAt = nowSec,
    }
end

return M
