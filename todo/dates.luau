--!nonstrict
-- dates — pure date math for the To Do plugin, shared by panel.luau (picker,
-- row glyphs) and todo.luau (bar overdue blink) via require(). No host
-- globals, so tests/todo/ can run it under a bare luau.
--
-- A task's `due` is unix seconds in local time. `allDay` tasks store the local
-- midnight of the chosen day and are overdue only once that whole day is over.
-- `dates.isOverdue` is the single overdue rule.
--
-- shortcut: an all-day deadline is `due + 86400`, so on a DST change day it is
-- off by an hour; upgrade to os.time{day+1} only if that ever matters.

local MAX_DUE = 253402300799 -- 9999-12-31; anything beyond is junk, not a date

local dates = {}

local function isLeap(y)
    return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

function dates.daysInMonth(y, m)
    if m == 2 and isLeap(y) then
        return 29
    end
    return DAYS[m]
end

-- Sakamoto's formula (0 = Sunday), mapped to 1 = Monday ... 7 = Sunday.
local OFFSETS = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
function dates.firstWeekday(y, m)
    local yy = m < 3 and y - 1 or y
    local sunday0 = (yy + yy // 4 - yy // 100 + yy // 400 + OFFSETS[m] + 1) % 7
    return sunday0 == 0 and 7 or sunday0
end

-- 6 rows x 7 columns, Monday first; 0 marks an empty cell.
function dates.monthGrid(y, m)
    local grid = {}
    local day = 1 - (dates.firstWeekday(y, m) - 1)
    local last = dates.daysInMonth(y, m)
    for r = 1, 6 do
        local row = {}
        for c = 1, 7 do
            row[c] = (day >= 1 and day <= last) and day or 0
            day += 1
        end
        grid[r] = row
    end
    return grid
end

function dates.shiftMonth(y, m, delta)
    local index = y * 12 + (m - 1) + delta
    return index // 12, index % 12 + 1
end

-- Reads due (floored) and allDay off a decoded JSON entry; nil, false when due
-- is not a finite number in (0, MAX_DUE].
function dates.normalizeDue(entry)
    local due = entry.due
    if type(due) ~= "number" or due ~= due or due <= 0 or due > MAX_DUE then
        return nil, false
    end
    return math.floor(due), entry.allDay == true
end

-- makeDue takes local fields. os.time{...} reads them as UTC, so the result is
-- shifted by the local UTC offset, measured at the guess and again at the result
-- to honour a DST change between them.
local function utcOffset(t)
    return os.time(os.date("*t", t)) - t
end

function dates.makeDue(y, m, d, hour, min, allDay)
    if allDay then
        hour, min = 0, 0
    end
    local asUtc = os.time({ year = y, month = m, day = d, hour = hour, min = min, sec = 0 })
    return asUtc - utcOffset(asUtc - utcOffset(asUtc))
end

local function deadline(item)
    if item.due == nil then
        return nil
    end
    return item.allDay and item.due + 86400 or item.due
end

function dates.isOverdue(item, now)
    if item.done == true then
        return false
    end
    local limit = deadline(item)
    return limit ~= nil and now >= limit
end

return dates
