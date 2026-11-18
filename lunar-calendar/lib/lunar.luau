--!nonstrict
-- Chinese lunisolar calendar maths: solar <-> lunar conversion, the 24 solar
-- terms, and traditional festivals.
--
-- Pure module: it never touches `noctalia.*`, so it is unit-testable on its own.
--
-- Data comes from lib/data.luau, generated from the ShouXing astronomical
-- algorithms and verified day-by-day for 1900-2100 (the generator ships in
-- tools/ next to the plugin so the numbers can be reproduced).

local data = require("./data.luau")

local M = {}

M.MIN_YEAR = data.min_year
M.MAX_YEAR = data.max_year

-- Solar terms in calendar order; index 1 = 小寒 (early January) and every pair
-- belongs to one Gregorian month, so 小寒 and 大寒 are 1 and 2 (January).
local TERM_NAMES = {
    "小寒", "大寒", "立春", "雨水", "惊蛰", "春分",
    "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
    "小暑", "大暑", "立秋", "处暑", "白露", "秋分",
    "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
}
M.TERM_NAMES = TERM_NAMES

local GAN = { "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸" }
local ZHI = { "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥" }
local ZODIAC = { "鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪" }

-- ---------------------------------------------------------------------------
-- Calendar arithmetic (proleptic Gregorian, no timezone involved)
-- ---------------------------------------------------------------------------

--- Days since 1970-01-01 for a Gregorian date (Howard Hinnant's algorithm).
function M.days_from_civil(y, m, d)
    y = y - ((m <= 2) and 1 or 0)
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- Inverse of days_from_civil: returns year, month, day.
function M.civil_from_days(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp + ((mp < 10) and 3 or -9)
    return y + ((m <= 2) and 1 or 0), m, d
end

--- ISO weekday for a day number: 1 = Monday .. 7 = Sunday.
function M.weekday_from_days(z)
    return ((z + 3) % 7) + 1
end

function M.days_in_month(y, m)
    local lengths = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if m == 2 and M.is_leap_year(y) then
        return 29
    end
    return lengths[m] or 0
end

function M.is_leap_year(y)
    return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

-- ---------------------------------------------------------------------------
-- Lunar year tables
-- ---------------------------------------------------------------------------

--- One row of lib/data.luau per lunar year: { year, leap, m1 .. m12, leap_days }.
local function year_row(year)
    return data.lunar_years[year - M.MIN_YEAR + 1]
end

--- Length (29 or 30) of lunar month `m` (1..12) in lunar year `year`.
local function month_len(year, m)
    local row = year_row(year)
    return row and row[2 + m] or 29
end

--- Leap month number of a lunar year, or 0 when the year has none.
function M.leap_month(year)
    local row = year_row(year)
    return row and row[2] or 0
end

--- Length of a lunar year's leap month; only meaningful when it has one.
local function leap_len(year)
    local row = year_row(year)
    return row and row[15] or 0
end

function M.lunar_year_days(year)
    local total = 0
    for m = 1, 12 do
        total = total + month_len(year, m)
    end
    if M.leap_month(year) > 0 then
        total = total + leap_len(year)
    end
    return total
end

-- Day number of 农历 year 年正月初一, for MIN_YEAR .. MAX_YEAR + 1.
local new_year_day = {}
do
    local day = M.days_from_civil(1900, 1, 31)
    for year = M.MIN_YEAR, M.MAX_YEAR + 1 do
        new_year_day[year] = day
        if year <= M.MAX_YEAR then
            day = day + M.lunar_year_days(year)
        end
    end
end

--- Day number on which a lunar year starts (正月初一).
function M.lunar_new_year_day(year)
    return new_year_day[year]
end

function M.in_range(year)
    return year >= M.MIN_YEAR and year <= M.MAX_YEAR
end

-- ---------------------------------------------------------------------------
-- Conversion
-- ---------------------------------------------------------------------------

--- Gregorian date -> lunar date, or nil outside the supported range.
--- The returned table has:
---   year, month (negative for a leap month), day, is_leap, month_len,
---   leap_month, day_number, weekday, ganzhi_year, zodiac
function M.solar_to_lunar(gy, gm, gd)
    if not M.in_range(gy) then
        return nil
    end
    local day = M.days_from_civil(gy, gm, gd)
    local year = gy
    if day < new_year_day[gy] then
        year = gy - 1
    end
    if year < M.MIN_YEAR then
        return nil
    end

    local leap = M.leap_month(year)
    local offset = day - new_year_day[year]
    local month, length
    for m = 1, 12 do
        length = month_len(year, m)
        if offset < length then
            month = m
            break
        end
        offset = offset - length
        if leap == m then
            length = leap_len(year)
            if offset < length then
                month = -m
                break
            end
            offset = offset - length
        end
    end
    if not month then
        return nil
    end

    return {
        year = year,
        month = month,
        day = offset + 1,
        is_leap = month < 0,
        month_len = length,
        leap_month = leap,
        day_number = day,
        weekday = M.weekday_from_days(day),
        ganzhi_year = M.ganzhi_year(year),
        zodiac = M.zodiac(year),
    }
end

--- Lunar date -> Gregorian { year, month, day }, or nil when out of range.
--- `month` may be negative to address a leap month.
function M.lunar_to_solar(year, month, day)
    if not M.in_range(year) or month == 0 or day < 1 or day > 30 then
        return nil
    end
    local leap = M.leap_month(year)
    local is_leap = month < 0
    local index = math.abs(month)
    if is_leap and leap ~= index then
        return nil
    end
    local offset = 0
    for m = 1, 12 do
        if m == index then
            if is_leap then
                offset = offset + month_len(year, m)
            end
            break
        end
        offset = offset + month_len(year, m)
        if leap == m then
            offset = offset + leap_len(year)
        end
    end
    local length = is_leap and leap_len(year) or month_len(year, index)
    if day > length then
        return nil
    end
    local gy, gm, gd = M.civil_from_days(new_year_day[year] + offset + day - 1)
    return { year = gy, month = gm, day = gd }
end

-- ---------------------------------------------------------------------------
-- Solar terms
-- ---------------------------------------------------------------------------

--- Day of month of term `index` (1..24) in Gregorian year `gy`.
function M.term_day(gy, index)
    if not M.in_range(gy) or index < 1 or index > 24 then
        return nil
    end
    local row = data.terms[gy - M.MIN_YEAR + 1]
    return row and row[1 + index] or nil
end

function M.term_name(index)
    return TERM_NAMES[index]
end

function M.term_month(index)
    return math.floor((index - 1) / 2) + 1
end

--- The solar term falling on a Gregorian date: name, index. 清明 doubles as a
--- festival and is reported as 清明节 by festivals().
function M.solar_term(gy, gm, gd)
    local first = (gm - 1) * 2 + 1
    if M.term_day(gy, first) == gd then
        return TERM_NAMES[first], first
    end
    if M.term_day(gy, first + 1) == gd then
        return TERM_NAMES[first + 1], first + 1
    end
    return nil
end

--- The next solar term strictly after the given date.
function M.next_solar_term(gy, gm, gd)
    if not M.in_range(gy) then
        return nil
    end
    local day = M.days_from_civil(gy, gm, gd)
    local start_index = (gm - 1) * 2 + 1
    for pass = 0, 1 do
        local year = gy + pass
        if M.in_range(year) then
            local from = pass == 0 and start_index or 1
            for i = from, 24 do
                local term_day = M.term_day(year, i)
                local term_number = M.days_from_civil(year, M.term_month(i), term_day)
                if term_number > day then
                    return {
                        name = TERM_NAMES[i],
                        index = i,
                        year = year,
                        month = M.term_month(i),
                        day = term_day,
                        in_days = term_number - day,
                    }
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Sexagenary cycle and zodiac
-- ---------------------------------------------------------------------------

--- 干支 for a lunar year (e.g. 丙午). Year 4 CE is 甲子.
function M.ganzhi_year(year)
    local index = (year - 4) % 60
    return GAN[index % 10 + 1] .. ZHI[index % 12 + 1]
end

--- 干支 for a day number (days since 1970-01-01).
function M.ganzhi_day(day_number)
    local index = (day_number - data.ganzhi_ref_day) % 60
    return GAN[index % 10 + 1] .. ZHI[index % 12 + 1]
end

function M.zodiac(year)
    return ZODIAC[(year - 4) % 12 + 1]
end

-- ---------------------------------------------------------------------------
-- Festivals
-- ---------------------------------------------------------------------------

-- Traditional festivals keyed by lunar month (absolute value) then day.
local LUNAR_FESTIVALS = {
    [1] = { [1] = "春节", [15] = "元宵节" },
    [2] = { [2] = "龙抬头" },
    [5] = { [5] = "端午节" },
    [7] = { [7] = "七夕", [15] = "中元节" },
    [8] = { [15] = "中秋节" },
    [9] = { [9] = "重阳节" },
    [12] = { [8] = "腊八节", [23] = "小年", [24] = "小年" },
}

local SOLAR_FESTIVALS = {
    ["1-1"] = "元旦",
    ["2-14"] = "情人节",
    ["3-8"] = "妇女节",
    ["3-12"] = "植树节",
    ["5-1"] = "劳动节",
    ["5-4"] = "青年节",
    ["6-1"] = "儿童节",
    ["7-1"] = "建党节",
    ["8-1"] = "建军节",
    ["9-10"] = "教师节",
    ["10-1"] = "国庆节",
    ["10-31"] = "万圣节",
    ["12-24"] = "平安夜",
    ["12-25"] = "圣诞节",
}

--- Traditional festival of a lunar date, or nil. Includes 除夕 (the last day of
--- the lunar year) and 小年.
function M.lunar_festival(lunar)
    if not lunar then
        return nil
    end
    local index = math.abs(lunar.month)
    local table_for_month = LUNAR_FESTIVALS[index]
    -- 除夕: the day before the next lunar new year.
    if not lunar.is_leap and lunar.day_number == new_year_day[lunar.year + 1] - 1 then
        return "除夕"
    end
    if table_for_month and table_for_month[lunar.day] then
        return table_for_month[lunar.day]
    end
    return nil
end

--- nth weekday of a Gregorian month; `weekday` is ISO (1 = Monday).
function M.nth_weekday(gy, gm, weekday, nth)
    local first = M.weekday_from_days(M.days_from_civil(gy, gm, 1))
    local delta = (weekday - first) % 7
    return 1 + delta + (nth - 1) * 7
end

--- Gregorian (fixed-date and weekday-based) festival, or nil.
function M.solar_festival(gy, gm, gd)
    local fixed = SOLAR_FESTIVALS[gm .. "-" .. gd]
    if fixed then
        return fixed
    end
    if gm == 5 and gd == M.nth_weekday(gy, 5, 7, 2) then
        return "母亲节"
    end
    if gm == 6 and gd == M.nth_weekday(gy, 6, 7, 3) then
        return "父亲节"
    end
    if gm == 11 and gd == M.nth_weekday(gy, 11, 4, 4) then
        return "感恩节"
    end
    return nil
end

--- The day's festivals with the plain solar terms removed, because a UI shows
--- the term in a row of its own. 清明节 stays: it is a festival as well.
function M.festival_list(gy, gm, gd)
    local out = {}
    for _, festival in ipairs(M.festivals(gy, gm, gd)) do
        if festival.kind ~= "term" or festival.name == "清明节" then
            out[#out + 1] = festival
        end
    end
    return out
end

--- All festivals on a Gregorian date, in display priority order (holidays from
--- the online data are merged in by the caller).
--- Each entry: { name, kind } with kind = "lunar" | "term" | "solar".
function M.festivals(gy, gm, gd)
    local out = {}
    local lunar = M.solar_to_lunar(gy, gm, gd)
    local lunar_festival = M.lunar_festival(lunar)
    if lunar_festival then
        out[#out + 1] = { name = lunar_festival, kind = "lunar" }
    end
    local term = M.solar_term(gy, gm, gd)
    if term then
        if term == "清明" then
            out[#out + 1] = { name = "清明节", kind = "term" }
        else
            out[#out + 1] = { name = term, kind = "term" }
        end
    end
    local solar_festival = M.solar_festival(gy, gm, gd)
    if solar_festival and solar_festival ~= lunar_festival then
        out[#out + 1] = { name = solar_festival, kind = "solar" }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Month grid (used by the panel)
-- ---------------------------------------------------------------------------

--- Cells for a Gregorian month, laid out for a calendar grid.
--- `week_start` is ISO (1 = Monday .. 7 = Sunday). Each cell carries the
--- Gregorian day plus everything the UI needs to label it:
---   { y, m, d, day_number, weekday, in_month, lunar, term, festivals }
function M.month_grid(gy, gm, week_start)
    if not M.in_range(gy) or gm < 1 or gm > 12 then
        return {}
    end
    week_start = week_start or 1
    local first_number = M.days_from_civil(gy, gm, 1)
    local offset = (M.weekday_from_days(first_number) - week_start) % 7
    local total = M.days_in_month(gy, gm)
    -- Always six week rows, like every other calendar UI: the grid then has a
    -- fixed height, so the panel does not change size between months. The spare
    -- cells fall in the neighbouring months.
    local rows = 6
    local cells = {}
    for i = 0, rows * 7 - 1 do
        local number = first_number - offset + i
        local y, m, d = M.civil_from_days(number)
        local lunar = M.solar_to_lunar(y, m, d)
        cells[#cells + 1] = {
            y = y,
            m = m,
            d = d,
            day_number = number,
            weekday = M.weekday_from_days(number),
            in_month = (m == gm and y == gy),
            lunar = lunar,
            term = M.solar_term(y, m, d),
            festivals = M.festivals(y, m, d),
        }
    end
    return cells, rows
end

return M
