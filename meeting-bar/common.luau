--!nonstrict
local model = require("./model.luau")
local M = { model = model, id = "yuta/meeting-bar" }

function M.options()
	return {
		days = noctalia.getConfig("days"),
		allDay = noctalia.getConfig("include_all_day"),
		meetingsOnly = noctalia.getConfig("meetings_only"),
		showPast = noctalia.getConfig("show_past"),
		calendars = noctalia.getConfig("calendars"),
		dedupe = noctalia.getConfig("deduplicate"),
		preferCurrent = noctalia.getConfig("prefer_current"),
	}
end

function M.dayKey(ms)
	return noctalia.formatTime("%Y-%m-%d", math.floor(ms / 1000))
end

function M.time(ms)
	return noctalia.formatTime(noctalia.timeFormat(), math.floor(ms / 1000))
end

function M.dayLabel(ms, now)
	if M.dayKey(ms) == M.dayKey(now) then
		return "Today"
	end
	-- Noon of the next local day is safe across DST transitions.
	local tomorrow = M.dayKey(M.dayEnd(now) + 12 * 3600000)
	if M.dayKey(ms) == tomorrow then
		return "Tomorrow"
	end
	return noctalia.formatTime("%a, %b %e", math.floor(ms / 1000))
end

function M.dayEnd(now)
	-- Find the next local date boundary without assuming that a day is 24 hours.
	local day, low, high = M.dayKey(now), math.floor(now / 1000), math.floor(now / 1000) + 27 * 3600
	while high - low > 1 do
		local mid = math.floor((low + high) / 2)
		if M.dayKey(mid * 1000) == day then
			low = mid
		else
			high = mid
		end
	end
	return high * 1000
end

function M.events(now, calendar, deduplicate)
	local snapshot = noctalia.state.get("snapshot")
	if not snapshot or not snapshot.ready then
		return nil
	end
	local opts = M.options()
	if calendar and calendar ~= "" then
		-- Apply the panel selection before collapsing cross-calendar duplicates.
		if #opts.calendars > 0 then
			local allowed = false
			for _, name in ipairs(opts.calendars) do
				allowed = allowed or name == calendar
			end
			if not allowed then
				return {}
			end
		end
		opts.calendars = { calendar }
	end
	if deduplicate ~= nil then
		opts.dedupe = deduplicate
	end
	local limit = M.dayEnd(now)
	for _ = 2, opts.days do
		limit = M.dayEnd(limit + 1000)
	end
	opts.untilMs = limit
	return model.events(snapshot.events, now, opts, M.dayKey)
end

function M.nextEvent(now, meetingOnly)
	return model.nextEvent(M.events(now) or {}, now, noctalia.getConfig("prefer_current"), meetingOnly)
end

function M.openLink(value)
	local url = model.url(value)
	if not url then
		noctalia.notifyError("Meeting Bar", "No usable web link for this event.")
		return false
	end
	local _, service = model.service(url)
	local overrides = noctalia.getConfig("service_commands")
	local executable = (service and overrides[service]) or noctalia.getConfig("browser")
	local argv = { executable ~= "" and executable or "xdg-open", url }
	local accepted = noctalia.runAsync(argv, function(result)
		if result.exitCode ~= 0 then
			noctalia.notifyError(
				"Meeting Bar",
				"Could not open the link. Check the configured browser or service command."
			)
		end
	end)
	if not accepted then
		noctalia.notifyError("Meeting Bar", "Could not start the link opener.")
	end
	return accepted
end

function M.joinNext()
	-- Re-evaluate on click; never join an event captured by an old render.
	local event = M.nextEvent(noctalia.nowMs(), true)
	if not event then
		noctalia.notify("Meeting Bar", "No current or upcoming recognized meeting.")
		return
	end
	M.openLink(event.url)
end

function M.copyLink(event)
	local url = model.url(event.url)
	if url then
		noctalia.copyToClipboard(url)
	end
end

function M.calendar()
	noctalia.runAsync({ "noctalia", "msg", "panel-open", "control-center", "calendar" })
end

function M.createMeeting()
	M.openLink(noctalia.getConfig("new_meeting_url"))
end

function M.bookmarks()
	return noctalia.state.get("bookmarks") or {}
end

function M.bookmarked(event)
	for _, bookmark in ipairs(M.bookmarks()) do
		if bookmark.url == event.url then
			return true
		end
	end
	return false
end

function M.toggleBookmark(event)
	noctalia.state.set(
		"bookmarkRequest",
		{ title = model.clean(event.title), url = event.url, nonce = noctalia.nowMs() }
	)
end

return M
