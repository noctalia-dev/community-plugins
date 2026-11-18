--!nonstrict

local M = {}


local function timeToMinutes(value)
    if not value then
        return nil
    end

    local hour, minute =
        value:match("^(%d%d?):(%d%d)$")

    if not hour then
        return nil
    end

    hour = tonumber(hour)
    minute = tonumber(minute)

    if hour < 0 or hour > 23
        or minute < 0 or minute > 59
    then
        return nil
    end

    return hour * 60 + minute
end


local function containsDay(days, day)
    if not days or #days == 0 then
        return true
    end

    for _, candidate in ipairs(days) do
        if candidate == day then
            return true
        end
    end

    return false
end


local function previousDay(day)
    day = day - 1

    if day < 1 then
        return 7
    end

    return day
end


function M.matchesNow(profile)
    local schedule =
        profile.schedule

    if not schedule then
        return false
    end

    local from =
        timeToMinutes(schedule.from)

    local untilTime =
        timeToMinutes(schedule["until"])

    if not from or not untilTime then
        return false
    end

    local hour =
        tonumber(noctalia.formatTime("%H"))

    local minute =
        tonumber(noctalia.formatTime("%M"))

    local day =
        tonumber(noctalia.formatTime("%u"))

    local now =
        hour * 60 + minute

    if from < untilTime then
        return containsDay(schedule.days, day)
            and now >= from
            and now < untilTime
    end

    if from > untilTime then
        if now >= from then
            return containsDay(
                schedule.days,
                day
            )
        end

        if now < untilTime then
            return containsDay(
                schedule.days,
                previousDay(day)
            )
        end
    end

    return false
end


function M.startsNow(profile)
    local schedule =
        profile.schedule

    if not schedule
        or not schedule.from
    then
        return false
    end

    if noctalia.formatTime("%H:%M")
        ~= schedule.from
    then
        return false
    end

    return containsDay(
        schedule.days,
        tonumber(noctalia.formatTime("%u"))
    )
end


function M.findCurrent(allProfiles)
    for _, profile in ipairs(allProfiles) do
        if M.matchesNow(profile) then
            return profile
        end
    end

    return nil
end


return M
