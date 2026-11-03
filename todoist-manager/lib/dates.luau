--!nonstrict
-- lib/dates.luau (Phase 1)
-- Due-date helpers. Todoist sends a `due` object:
--   { date, is_recurring, lang, string, timezone? }
-- `date` is either "YYYY-MM-DD" (all-day) or "YYYY-MM-DDTHH:MM:SS" (timed,
-- possibly with a Z / offset and a `timezone`). `string` is Todoist's own
-- human label in the user's language - prefer it verbatim, never re-render it.
--
-- No silent UTC conversion: an all-day date has no timezone semantics, and a
-- timed date is shown as Todoist sent it (its `string` already localizes it).
local M = {}

local MONTHS = {
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

function M.today()
	return os.date("%Y-%m-%d")
end

function M.isDate(s)
	return type(s) == "string" and s:match("^%d%d%d%d%-%d%d%-%d%d") ~= nil
end

-- Date part of a due.date ("YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SS").
function M.datePart(date)
	if type(date) ~= "string" then
		return nil
	end
	return date:match("^(%d%d%d%d%-%d%d%-%d%d)")
end

-- Time part "HH:MM" when the value is a timed date; nil for all-day.
function M.timePart(date)
	if type(date) ~= "string" then
		return nil
	end
	return date:match("T(%d%d:%d%d)")
end

-- Whole-day difference from today (negative = past). Uses a noon anchor so
-- DST transitions cannot round a day off.
function M.dayDiff(dateStr)
	local y, mo, d = (dateStr or ""):match("^(%d+)-(%d+)-(%d+)")
	if not y then
		return nil
	end
	local t = os.time({ year = y + 0, month = mo + 0, day = d + 0, hour = 12 })
	local now = os.date("*t")
	local today = os.time({ year = now.year, month = now.month, day = now.day, hour = 12 })
	return math.floor((t - today) / 86400 + 0.5)
end

-- Short absolute label, e.g. "21 Sep" or "21 Sep 2025" for another year.
function M.dateLabel(dateStr)
	local y, mo, d = (dateStr or ""):match("^(%d+)-(%d+)-(%d+)")
	if not y then
		return tostring(dateStr or "")
	end
	local mn = MONTHS[tonumber(mo)] or mo
	if tonumber(y) ~= os.date("*t").year then
		return string.format("%d %s %s", tonumber(d), mn, y)
	end
	return string.format("%d %s", tonumber(d), mn)
end

-- Relative day label: Today / Tomorrow / Yesterday / weekday / date.
function M.dayLabel(dateStr)
	local diff = M.dayDiff(dateStr)
	if diff == nil then
		return tostring(dateStr or "?")
	end
	if diff == 0 then
		return noctalia.tr("due.today")
	elseif diff == 1 then
		return noctalia.tr("due.tomorrow")
	elseif diff == -1 then
		return noctalia.tr("due.yesterday")
	elseif diff > 1 and diff < 7 then
		local y, mo, d = dateStr:match("^(%d+)-(%d+)-(%d+)$")
		local t = os.time({ year = y + 0, month = mo + 0, day = d + 0, hour = 12 })
		return os.date("%A", t)
	end
	return M.dateLabel(dateStr)
end

-- due -> { text, overdue, today, recurring, has_date }
function M.formatDue(due)
	if type(due) ~= "table" then
		return nil
	end
	local dateStr = M.datePart(due.date)
	if dateStr == nil then
		return nil
	end
	local diff = M.dayDiff(dateStr)
	local text
	if type(due.string) == "string" and due.string ~= "" then
		text = due.string
	else
		text = M.dayLabel(dateStr)
		local tm = M.timePart(due.date)
		if tm then
			text = text .. " " .. tm
		end
	end
	return {
		text = text,
		overdue = diff ~= nil and diff < 0,
		today = diff == 0,
		recurring = due.is_recurring == true,
		has_date = true,
		date = dateStr,
	}
end

-- deadline is { date, lang }; there is no human string.
function M.formatDeadline(deadline)
	if type(deadline) ~= "table" then
		return nil
	end
	local dateStr = M.datePart(deadline.date)
	if dateStr == nil then
		return nil
	end
	return M.dayLabel(dateStr)
end

-- Sort key: dated tasks first (by date, then time), undated last.
function M.dueSortKey(due)
	if type(due) ~= "table" then
		return "9"
	end
	local dateStr = M.datePart(due.date)
	if dateStr == nil then
		return "9"
	end
	local tm = M.timePart(due.date) or "99:99"
	return "0" .. dateStr .. "T" .. tm
end

return M
