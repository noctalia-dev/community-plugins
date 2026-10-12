--!nonstrict
-- Pure helpers shared by service.luau, panel.luau and upcoming.luau.
-- Nothing in here touches the filesystem or noctalia.state.

local M = {}

-- Click-to-pick palette (no free-form colour picker).
M.PALETTE = {
    "#4C9AFF", -- blue
    "#2DC8C8", -- teal
    "#6FCF97", -- green
    "#F2C94C", -- yellow
    "#F2994A", -- orange
    "#EB5757", -- red
    "#F178B6", -- pink
    "#BB6BD9", -- purple
    "#8D6E63", -- brown
    "#9AA0A6", -- grey
}

M.DEFAULT_COLOR = "#9AA0A6"

function M.defaultData()
    return {
        version = 1,
        categories = {
            { id = "study", name = "Study", color = M.PALETTE[1], visible = true },
            { id = "work", name = "Work", color = M.PALETTE[5], visible = true },
            { id = "personal", name = "Personal", color = M.PALETTE[3], visible = true },
            { id = "health", name = "Health", color = M.PALETTE[7], visible = true },
            { id = "deadline", name = "Deadline", color = M.PALETTE[6], visible = true },
        },
        events = {},
    }
end

function M.dateKey(year, month, day)
    return string.format("%04d-%02d-%02d", year, month, day)
end

-- "9:30" / "09:30" -> minutes since midnight, or nil when invalid.
function M.parseTime(text)
    local h, m = string.match(tostring(text or ""), "^%s*(%d%d?):(%d%d)%s*$")
    h, m = tonumber(h), tonumber(m)
    if h == nil or m == nil or h > 23 or m > 59 then
        return nil
    end
    return h * 60 + m
end

function M.fmtTime(minutes)
    minutes = math.floor(tonumber(minutes) or 0) % 1440
    return string.format("%02d:%02d", minutes // 60, minutes % 60)
end

function M.trim(text)
    return (string.gsub(tostring(text or ""), "^%s*(.-)%s*$", "%1"))
end

function M.categoryMap(data)
    local map = {}
    if type(data) == "table" and type(data.categories) == "table" then
        for _, cat in ipairs(data.categories) do
            map[cat.id] = cat
        end
    end
    return map
end

-- All-day first, then by start time, then by title.
function M.compareEvents(a, b)
    local aAll = a.allDay == true
    local bAll = b.allDay == true
    if aAll ~= bAll then
        return aAll
    end
    local aStart = tonumber(a.start) or 0
    local bStart = tonumber(b.start) or 0
    if aStart ~= bStart then
        return aStart < bStart
    end
    return tostring(a.title) < tostring(b.title)
end

-- { ["2026-10-12"] = { event, ... } } with hidden categories filtered out.
function M.eventsByDate(data)
    local byDate = {}
    if type(data) ~= "table" or type(data.events) ~= "table" then
        return byDate
    end
    local cats = M.categoryMap(data)
    for _, ev in ipairs(data.events) do
        local cat = cats[ev.cat]
        if cat ~= nil and cat.visible ~= false then
            local list = byDate[ev.date]
            if list == nil then
                list = {}
                byDate[ev.date] = list
            end
            table.insert(list, ev)
        end
    end
    for _, list in pairs(byDate) do
        table.sort(list, M.compareEvents)
    end
    return byDate
end

-- Next events from "now" on (ongoing events included), visible categories only.
-- today is "YYYY-MM-DD", nowMinutes is minutes since midnight.
function M.upcoming(data, limit, today, nowMinutes)
    local out = {}
    if type(data) ~= "table" or type(data.events) ~= "table" then
        return out
    end
    local cats = M.categoryMap(data)
    for _, ev in ipairs(data.events) do
        local cat = cats[ev.cat]
        if cat ~= nil and cat.visible ~= false and type(ev.date) == "string" then
            local keep = ev.date > today
            if ev.date == today then
                keep = ev.allDay == true
                    or (tonumber(ev.start) or 0) + (tonumber(ev.duration) or 0) > nowMinutes
            end
            if keep then
                table.insert(out, {
                    id = ev.id,
                    title = ev.title,
                    date = ev.date,
                    start = ev.start,
                    duration = ev.duration,
                    allDay = ev.allDay == true,
                    color = cat.color or M.DEFAULT_COLOR,
                    category = cat.name,
                })
            end
        end
    end
    table.sort(out, function(a, b)
        if a.date ~= b.date then
            return a.date < b.date
        end
        return M.compareEvents(a, b)
    end)
    while #out > limit do
        table.remove(out)
    end
    return out
end

return M
