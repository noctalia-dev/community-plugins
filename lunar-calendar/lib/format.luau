--!nonstrict
-- Text formatting for calendar values. Pure functions only - no `noctalia.*`
-- access - so the whole module is unit-testable on its own.
--
-- Only the plugin's own chrome is localised: weekday names, the date and month
-- titles, countdowns and the panel's weekday header. The calendar's vocabulary -
-- lunar day and month names, the 24 solar terms, 干支 and the festival names -
-- stays Chinese, because those are the terms of the calendar itself.
--
-- The entries pick the locale from lib/locale.luau; the default is Chinese,
-- which is also what the shipped screenshots show.

local M = {}

local WEEKDAY_ZH = { "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日" }
local WEEKDAY_ZH_SHORT = { "周一", "周二", "周三", "周四", "周五", "周六", "周日" }
local WEEKDAY_ZH_INITIAL = { "一", "二", "三", "四", "五", "六", "日" }
local WEEKDAY_EN = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }
local WEEKDAY_EN_SHORT = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local WEEKDAY_EN_INITIAL = { "M", "T", "W", "T", "F", "S", "S" }

local MONTH_EN_SHORT = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}
local MONTH_EN_FULL = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

local DAY_DIGITS = { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十" }
local MONTH_NAMES = {
    "正月", "二月", "三月", "四月", "五月", "六月",
    "七月", "八月", "九月", "十月", "冬月", "腊月",
}

local locale = "zh"

--- "zh" (the default) or "en".
function M.set_locale(name)
    locale = (name == "en") and "en" or "zh"
end

function M.locale()
    return locale
end

--- Lunar day name: 1 -> 初一, 10 -> 初十, 20 -> 二十, 30 -> 三十.
function M.lunar_day(day)
    if day <= 0 or day > 30 then
        return tostring(day)
    end
    if day <= 10 then
        return "初" .. DAY_DIGITS[day]
    end
    if day < 20 then
        return "十" .. DAY_DIGITS[day - 10]
    end
    if day == 20 then
        return "二十"
    end
    if day < 30 then
        return "廿" .. DAY_DIGITS[day - 20]
    end
    return "三十"
end

--- Lunar month name for a 1..12 month number (sign ignored).
function M.lunar_month(month)
    local index = math.abs(month)
    return MONTH_NAMES[index] or tostring(index)
end

--- Full lunar month+day, e.g. 八月初七 or 闰六月初一.
function M.lunar_month_day(month, day, is_leap)
    local prefix = is_leap and "闰" or ""
    return prefix .. M.lunar_month(month) .. M.lunar_day(day)
end

--- ISO weekday (1 = Monday .. 7 = Sunday) in the active locale.
function M.weekday(iso)
    if locale == "en" then
        return WEEKDAY_EN[iso] or ""
    end
    return WEEKDAY_ZH[iso] or ""
end

function M.weekday_short(iso)
    if locale == "en" then
        return WEEKDAY_EN_SHORT[iso] or ""
    end
    return WEEKDAY_ZH_SHORT[iso] or ""
end

--- One-letter weekday for the month grid header.
function M.weekday_initial(iso)
    if locale == "en" then
        return WEEKDAY_EN_INITIAL[iso] or ""
    end
    return WEEKDAY_ZH_INITIAL[iso] or ""
end

--- 9月16日 / Sep 16
function M.solar_month_day(month, day)
    if locale == "en" then
        return string.format("%s %d", MONTH_EN_SHORT[month] or tostring(month), day)
    end
    return string.format("%d月%d日", month, day)
end

--- 2026年9月16日 / Sep 16, 2026
function M.solar_ymd(year, month, day)
    if locale == "en" then
        return string.format("%s %d, %d", MONTH_EN_SHORT[month] or tostring(month), day, year)
    end
    return string.format("%d年%d月%d日", year, month, day)
end

--- 09-16 style date key used by the holiday data (locale-independent).
function M.date_key(year, month, day)
    return string.format("%04d-%02d-%02d", year, month, day)
end

--- 2026年9月 / September 2026
function M.month_title(year, month)
    if locale == "en" then
        return string.format("%s %d", MONTH_EN_FULL[month] or tostring(month), year)
    end
    return string.format("%d年%d月", year, month)
end

--- Days between two `days_from_civil` values, phrased for a countdown.
function M.days_phrase(days)
    if locale == "en" then
        if days <= 0 then
            return "today"
        elseif days == 1 then
            return "tomorrow"
        end
        return string.format("in %d days", days)
    end
    if days <= 0 then
        return "今天"
    elseif days == 1 then
        return "明天"
    elseif days == 2 then
        return "后天"
    end
    return string.format("%d天后", days)
end

return M
