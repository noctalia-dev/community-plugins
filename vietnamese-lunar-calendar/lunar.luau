--!nonstrict
-- Vietnamese lunar calendar conversion for UTC+7.
-- The astronomical calculation follows the standard new-moon / solar-longitude
-- method commonly used for Vietnamese lunisolar calendar conversion.

local M = {}

local PI = math.pi
local SYNODIC_MONTH = 29.530588853
local NEW_MOON_EPOCH = 2415021.076998695

local function int(x)
    return math.floor(x)
end

function M.jdFromDate(dd, mm, yy)
    local a = int((14 - mm) / 12)
    local y = yy + 4800 - a
    local m = mm + 12 * a - 3

    local jd = dd
        + int((153 * m + 2) / 5)
        + 365 * y
        + int(y / 4)
        - int(y / 100)
        + int(y / 400)
        - 32045

    if jd < 2299161 then
        jd = dd
            + int((153 * m + 2) / 5)
            + 365 * y
            + int(y / 4)
            - 32083
    end

    return jd
end

local function newMoon(k)
    local T = k / 1236.85
    local T2 = T * T
    local T3 = T2 * T
    local dr = PI / 180

    local jd1 = 2415020.75933
        + 29.53058868 * k
        + 0.0001178 * T2
        - 0.000000155 * T3

    jd1 = jd1
        + 0.00033 * math.sin((166.56 + 132.87 * T - 0.009173 * T2) * dr)

    local Mv = 359.2242
        + 29.10535608 * k
        - 0.0000333 * T2
        - 0.00000347 * T3

    local Mpr = 306.0253
        + 385.81691806 * k
        + 0.0107306 * T2
        + 0.00001236 * T3

    local F = 21.2964
        + 390.67050646 * k
        - 0.0016528 * T2
        - 0.00000239 * T3

    local C1 = (0.1734 - 0.000393 * T) * math.sin(Mv * dr)
        + 0.0021 * math.sin(2 * Mv * dr)
        - 0.4068 * math.sin(Mpr * dr)
        + 0.0161 * math.sin(2 * Mpr * dr)
        - 0.0004 * math.sin(3 * Mpr * dr)
        + 0.0104 * math.sin(2 * F * dr)
        - 0.0051 * math.sin((Mv + Mpr) * dr)
        - 0.0074 * math.sin((Mv - Mpr) * dr)
        + 0.0004 * math.sin((2 * F + Mv) * dr)
        - 0.0004 * math.sin((2 * F - Mv) * dr)
        - 0.0006 * math.sin((2 * F + Mpr) * dr)
        + 0.0010 * math.sin((2 * F - Mpr) * dr)
        + 0.0005 * math.sin((2 * Mpr + Mv) * dr)

    local deltaT
    if T < -11 then
        deltaT = 0.001
            + 0.000839 * T
            + 0.0002261 * T2
            - 0.00000845 * T3
            - 0.000000081 * T * T3
    else
        deltaT = -0.000278
            + 0.000265 * T
            + 0.000262 * T2
    end

    return jd1 + C1 - deltaT
end

local function sunLongitude(jdn)
    local T = (jdn - 2451545.0) / 36525
    local T2 = T * T
    local dr = PI / 180

    local Mv = 357.52910
        + 35999.05030 * T
        - 0.0001559 * T2
        - 0.00000048 * T * T2

    local L0 = 280.46645
        + 36000.76983 * T
        + 0.0003032 * T2

    local DL = (1.914600 - 0.004817 * T - 0.000014 * T2)
        * math.sin(dr * Mv)

    DL = DL
        + (0.019993 - 0.000101 * T) * math.sin(dr * 2 * Mv)
        + 0.000290 * math.sin(dr * 3 * Mv)

    local L = (L0 + DL) * dr
    L = L - PI * 2 * int(L / (PI * 2))
    return L
end

local function getNewMoonDay(k, timeZone)
    return int(newMoon(k) + 0.5 + timeZone / 24)
end

local function getSunLongitude(dayNumber, timeZone)
    return int(sunLongitude(dayNumber - 0.5 - timeZone / 24) / PI * 6)
end

local function getLunarMonth11(yy, timeZone)
    local off = M.jdFromDate(31, 12, yy) - 2415021
    local k = int(off / SYNODIC_MONTH)
    local nm = getNewMoonDay(k, timeZone)
    local sunLong = getSunLongitude(nm, timeZone)

    if sunLong >= 9 then
        nm = getNewMoonDay(k - 1, timeZone)
    end

    return nm
end

local function getLeapMonthOffset(a11, timeZone)
    local k = int(0.5 + (a11 - NEW_MOON_EPOCH) / SYNODIC_MONTH)
    local last = 0
    local i = 1
    local arc = getSunLongitude(getNewMoonDay(k + i, timeZone), timeZone)

    repeat
        last = arc
        i = i + 1
        arc = getSunLongitude(getNewMoonDay(k + i, timeZone), timeZone)
    until arc == last or i >= 14

    return i - 1
end

function M.solarToLunar(dd, mm, yy, timeZone)
    timeZone = timeZone or 7

    local dayNumber = M.jdFromDate(dd, mm, yy)
    local k = int((dayNumber - NEW_MOON_EPOCH) / SYNODIC_MONTH)

    local monthStart = getNewMoonDay(k + 1, timeZone)
    if monthStart > dayNumber then
        monthStart = getNewMoonDay(k, timeZone)
    end

    local a11 = getLunarMonth11(yy, timeZone)
    local b11 = a11
    local lunarYear

    if a11 >= monthStart then
        lunarYear = yy
        a11 = getLunarMonth11(yy - 1, timeZone)
    else
        lunarYear = yy + 1
        b11 = getLunarMonth11(yy + 1, timeZone)
    end

    local lunarDay = dayNumber - monthStart + 1
    local diff = int((monthStart - a11) / 29)
    local lunarLeap = 0
    local lunarMonth = diff + 11

    if b11 - a11 > 365 then
        local leapMonthDiff = getLeapMonthOffset(a11, timeZone)
        if diff >= leapMonthDiff then
            lunarMonth = diff + 10

            if diff == leapMonthDiff then
                lunarLeap = 1
            end
        end
    end

    if lunarMonth > 12 then
        lunarMonth = lunarMonth - 12
    end

    if lunarMonth >= 11 and diff < 4 then
        lunarYear = lunarYear - 1
    end

    return {
        day = lunarDay,
        month = lunarMonth,
        year = lunarYear,
        leap = lunarLeap == 1,
    }
end

local CAN = {
    "Giáp", "Ất", "Bính", "Đinh", "Mậu",
    "Kỷ", "Canh", "Tân", "Nhâm", "Quý",
}

local CHI = {
    "Tý", "Sửu", "Dần", "Mão", "Thìn", "Tỵ",
    "Ngọ", "Mùi", "Thân", "Dậu", "Tuất", "Hợi",
}

function M.yearCanChi(year)
    local can = CAN[((year + 6) % 10) + 1]
    local chi = CHI[((year + 8) % 12) + 1]
    return can .. " " .. chi
end

local FESTIVALS = {
    ["1/1"] = "Tết Nguyên Đán",
    ["15/1"] = "Rằm tháng Giêng",
    ["3/3"] = "Tết Hàn Thực",
    ["10/3"] = "Giỗ Tổ Hùng Vương",
    ["15/4"] = "Phật Đản",
    ["5/5"] = "Tết Đoan Ngọ",
    ["15/7"] = "Lễ Vu Lan",
    ["15/8"] = "Tết Trung Thu",
    ["23/12"] = "Ông Công Ông Táo",
}

function M.festival(lunar)
    if lunar.leap then
        return nil
    end

    return FESTIVALS[tostring(lunar.day) .. "/" .. tostring(lunar.month)]
end

function M.daysInSolarMonth(month, year)
    if month == 2 then
        local leap = (year % 400 == 0) or (year % 4 == 0 and year % 100 ~= 0)
        return leap and 29 or 28
    end

    if month == 4 or month == 6 or month == 9 or month == 11 then
        return 30
    end

    return 31
end

-- Monday = 1 ... Sunday = 7
function M.weekdayMondayFirst(dd, mm, yy)
    local jd = M.jdFromDate(dd, mm, yy)
    return ((jd % 7) + 1)
end

return M
