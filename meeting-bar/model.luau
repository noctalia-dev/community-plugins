--!nonstrict
-- Pure calendar logic. Shared by the shell entries and the offline behaviour tests.
local M = {}

function M.clean(value)
	return (tostring(value or ""):gsub("[%c]", " "):gsub("%s+", " "))
end

function M.shorten(text, count)
	text = M.clean(text)
	local chars = {}
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = char
	end
	if #chars <= count then
		return text
	end
	return table.concat(chars, "", 1, math.max(1, count - 1)) .. "…"
end

function M.url(value)
	if type(value) ~= "string" or #value > 2048 or value:find("[%c%s]") then
		return nil
	end
	local host = value:match("^https?://([^/?#]+)")
	if not host or host:find("@", 1, true) or host:sub(1, 1) == "-" then
		return nil
	end
	return value, host:lower():gsub(":%d+$", "")
end

local services = {
	{ "meet.google.com", "Google Meet", "meet" },
	{ "zoom.us", "Zoom", "zoom" },
	{ "zoom.com", "Zoom", "zoom" },
	{ "teams.microsoft.com", "Teams", "teams" },
	{ "teams.live.com", "Teams", "teams" },
	{ "teams.cloud.microsoft", "Teams", "teams" },
	{ "webex.com", "Webex", "webex" },
	{ "meet.jit.si", "Jitsi", "jitsi" },
	{ "whereby.com", "Whereby", "whereby" },
	{ "meet.goto.com", "GoTo", "goto" },
	{ "gotomeeting.com", "GoTo", "goto" },
	{ "chime.aws", "Chime", "chime" },
	{ "ringcentral.com", "RingCentral", "ringcentral" },
	{ "discord.com", "Discord", "discord" },
	{ "discord.gg", "Discord", "discord" },
	{ "slack.com", "Slack", "slack" },
	{ "meet.zoho.com", "Zoho", "zoho" },
}

function M.service(value)
	local _, host = M.url(value)
	if not host then
		return nil
	end
	for _, item in ipairs(services) do
		if host == item[1] or host:sub(-#item[1] - 1) == "." .. item[1] then
			return item[2], item[3]
		end
	end
	return nil
end

function M.key(event)
	-- Recurring instances may share a provider UID. Include the resolved start.
	return tostring(event.id) .. "|" .. tostring(event.startMs) .. "|" .. tostring(event.calendarName)
end

local function contains(values, value)
	for _, item in ipairs(values or {}) do
		if item == value then
			return true
		end
	end
	return false
end

function M.events(raw, now, options, dayKey)
	local result, seen = {}, {}
	local today = dayKey(now)
	for _, event in ipairs(raw or {}) do
		if
			type(event.startMs) == "number"
			and type(event.endMs) == "number"
			and event.endMs >= event.startMs
			and (#options.calendars == 0 or contains(options.calendars, event.calendarName))
			and (options.allDay or not event.allDay)
			and (not options.meetingsOnly or M.service(event.url))
			and event.startMs < options.untilMs
			and (event.endMs > now or (options.showPast and dayKey(event.endMs) >= today))
		then
			local duplicate = M.clean(event.title):lower()
				.. "|"
				.. event.startMs
				.. "|"
				.. event.endMs
				.. "|"
				.. (event.url or "")
			if not options.dedupe or not seen[duplicate] then
				seen[duplicate] = true
				result[#result + 1] = event
			end
		end
	end
	table.sort(result, function(a, b)
		if a.startMs ~= b.startMs then
			return a.startMs < b.startMs
		end
		if a.endMs ~= b.endMs then
			return a.endMs < b.endMs
		end
		return M.key(a) < M.key(b)
	end)
	return result
end

function M.nextEvent(events, now, preferCurrent, meetingOnly)
	local current, upcoming
	for _, event in ipairs(events) do
		if not event.allDay and event.endMs > now and (not meetingOnly or M.service(event.url)) then
			if event.startMs <= now then
				if not current or event.startMs > current.startMs then
					current = event
				end
			elseif not upcoming or event.startMs < upcoming.startMs then
				upcoming = event
			end
		end
	end
	if preferCurrent then
		return current or upcoming
	end
	return upcoming or current
end

function M.duration(ms)
	local minutes = math.max(1, math.ceil(ms / 60000))
	if minutes < 60 then
		return tostring(minutes) .. "m"
	end
	local hours = math.floor(minutes / 60)
	if hours < 24 then
		return tostring(hours) .. "h" .. (minutes % 60 > 0 and " " .. tostring(minutes % 60) .. "m" or "")
	end
	return tostring(math.floor(hours / 24)) .. "d " .. tostring(hours % 24) .. "h"
end

function M.relative(event, now)
	if event.endMs <= now then
		return "Ended"
	end
	if event.startMs <= now then
		return "Now · " .. M.duration(event.endMs - now) .. " left"
	end
	return "In " .. M.duration(event.startMs - now)
end

return M
