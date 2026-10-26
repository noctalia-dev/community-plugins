-- Pure timestamp policy. All epoch values and `now` arguments are Unix SECONDS,
-- including fractional seconds; noctalia.nowMs() must be divided by 1000.
local M = {}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function leap(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function leapCount(year)
    return math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400)
end

local monthDays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- Hub ISO timestamps require an explicit timezone. Never interpret a naive
-- timestamp using either the current local zone or an assumed UTC offset.
function M.parse(value)
    if type(value) ~= "string" then return nil end
    local y, mo, d, h, mi, s, tail = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    local year, month, day = tonumber(y), tonumber(mo), tonumber(d)
    local hour, minute, second = tonumber(h), tonumber(mi), tonumber(s)
    if year < 1 or month < 1 or month > 12 or day < 1
        or hour > 23 or minute > 59 or second > 59 then return nil end
    local maxDay = monthDays[month] + (month == 2 and leap(year) and 1 or 0)
    if day > maxDay then return nil end

    local fraction = 0
    if tail:sub(1, 1) == "." then
        local digits, remainder = tail:match("^%.(%d+)(.*)$")
        if not digits then return nil end
        fraction, tail = tonumber("0." .. digits), remainder
    end
    local offset = 0
    if tail ~= "Z" and tail ~= "z" then
        local sign, oh, om = tail:match("^([+-])(%d%d):(%d%d)$")
        if not sign then sign, oh, om = tail:match("^([+-])(%d%d)(%d%d)$") end
        if not sign then return nil end
        local offsetHour, offsetMinute = tonumber(oh), tonumber(om)
        if offsetHour > 23 or offsetMinute > 59 then return nil end
        offset = (offsetHour * 60 + offsetMinute) * 60 * (sign == "+" and 1 or -1)
    end
    local days = 365 * (year - 1970) + leapCount(year - 1) - leapCount(1969) + day - 1
    for index = 1, month - 1 do
        days = days + monthDays[index] + (index == 2 and leap(year) and 1 or 0)
    end
    return days * 86400 + hour * 3600 + minute * 60 + second + fraction - offset
end

local function label(key, values)
    return { key = "time." .. key, values = values or {} }
end

function M.age(value, now)
    local epoch = M.parse(value)
    if not epoch or not finite(now) then return label("unknown") end
    local elapsed = now - epoch
    if elapsed < 0 then return label("future") end
    if elapsed < 60 then return label("just_now") end
    local minutes = math.floor(elapsed / 60)
    if minutes < 60 then return label("minutes_ago", { count = minutes }) end
    local hours = math.floor(minutes / 60)
    if hours < 24 then return label("hours_ago", { hours = hours, minutes = minutes % 60 }) end
    return label("days_ago", { days = math.floor(hours / 24), hours = hours % 24 })
end

function M.countdown(value, now)
    local epoch = M.parse(value)
    if not epoch or not finite(now) then return label("unknown") end
    local remaining = epoch - now
    -- Reaching the advertised reset time cannot prove the provider refilled it.
    if remaining <= 0 then return label("reset_due") end
    if remaining < 60 then return label("less_than_minute") end
    -- Round up so a still-pending reset is never displayed as zero minutes.
    local minutes = math.ceil(remaining / 60)
    if minutes < 60 then return label("resets_minutes", { count = minutes }) end
    local hours = math.floor(minutes / 60)
    if hours < 24 then return label("resets_hours", { hours = hours, minutes = minutes % 60 }) end
    return label("resets_days", { days = math.floor(hours / 24), hours = hours % 24 })
end

return M
