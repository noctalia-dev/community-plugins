-- Run from the repository root using Lua 5.4+. No network or personal calendars.
local root = "meeting-bar/"
local now = os.time({ year = 2026, month = 11, day = 11, hour = 12 }) * 1000
local initialNow = now
local config = {
	days = 2,
	include_all_day = true,
	meetings_only = false,
	show_past = false,
	calendars = {},
	deduplicate = true,
	prefer_current = true,
	preview_minutes = 0,
	hide_empty = false,
	show_title = true,
	show_time = false,
	show_countdown = true,
	title_length = 28,
	browser = "",
	service_commands = {},
	new_meeting_url = "https://meet.google.com/new",
	fullscreen_reminders = true,
	reminder_minutes = 5,
	snooze_minutes = 2,
}
local state, watchers, files, serialized, processes = {}, {}, {}, {}, {}
local visible, tree, bar, raw = false, nil, {}, nil
local failWrites, processAccepted, processExitCode = false, true, 0
local expectedErrors, errors = false, {}
local function clone(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = clone(item)
	end
	return result
end
local defaults = clone(config)
local function set(key, value)
	state[key] = clone(value)
	for _, fn in ipairs(watchers[key] or {}) do
		fn(clone(value))
	end
end
local runtime = {
	nowMs = function()
		return now
	end,
	calendarEvents = function()
		return clone(raw)
	end,
	getConfig = function(key)
		assert(config[key] ~= nil, "Undeclared setting: " .. key)
		return config[key]
	end,
	formatTime = function(format, seconds)
		return os.date(format, seconds)
	end,
	timeFormat = function()
		return "%H:%M"
	end,
	pluginDataDir = function()
		return "/state"
	end,
	readFile = function(path)
		return files[path]
	end,
	writeFile = function(path, value)
		if failWrites then
			return false
		end
		files[path] = value
		return true
	end,
	setUpdateInterval = function() end,
	notify = function() end,
	notifyError = function(_, error)
		error = tostring(error)
		errors[#errors + 1] = error
		assert(expectedErrors, error)
	end,
	runAsync = function(argv, callback)
		processes[#processes + 1] = argv
		if processAccepted and callback then
			callback({ exitCode = processExitCode })
		end
		return processAccepted
	end,
	copyToClipboard = function(value)
		state.clipboard = value
	end,
	openSettings = function()
		state.settings = true
	end,
	togglePanel = function(id)
		state.panel = id
	end,
	state = {
		get = function(key)
			return clone(state[key])
		end,
		set = set,
		watch = function(key, fn)
			watchers[key] = watchers[key] or {}
			table.insert(watchers[key], fn)
		end,
	},
	layer = {
		show = function()
			visible = true
		end,
		hide = function()
			visible = false
		end,
	},
	json = {
		encode = function(value)
			local key = tostring(#serialized + 1)
			serialized[#serialized + 1] = clone(value)
			return key
		end,
		decode = function(value)
			return clone(serialized[tonumber(value)])
		end,
	},
}
local function loadEntry(name)
	local env = setmetatable({ noctalia = runtime }, { __index = _G })
	local modules = {}
	env.require = function(path)
		assert(path:match("^%./.+%.luau$"), "Noctalia requires explicit .luau extensions")
		if not modules[path] then
			modules[path] = assert(loadfile(root .. path:sub(3), "t", env))()
		end
		return modules[path]
	end
	env.ui = setmetatable({}, {
		__index = function(_, kind)
			return function(props, children)
				return { kind = kind, props = props, children = children or {} }
			end
		end,
	})
	env.panel = {
		render = function(value)
			tree = value
		end,
		close = function()
			state.closed = true
		end,
		setWantsSecondTicks = function() end,
	}
	env.layer = {
		render = function(value)
			tree = value
		end,
	}
	env.barWidget = setmetatable({}, {
		__index = function(_, key)
			return function(value)
				bar[key] = value
			end
		end,
	})
	assert(loadfile(root .. name .. ".luau", "t", env))()
	return env
end
local env = loadEntry("model")
local model = env.require("./model.luau")
local common = env.require("./common.luau")
local function event(id, startMinutes, endMinutes, extra)
	local value = {
		id = id,
		title = id,
		calendarName = "Work",
		colorHex = "#aabbcc",
		location = "",
		startMs = initialNow + startMinutes * 60000,
		endMs = initialNow + endMinutes * 60000,
		url = "https://meet.google.com/abc-defg-hij",
		allDay = false,
	}
	for key, item in pairs(extra or {}) do
		value[key] = item
	end
	return value
end
local function check(condition, message)
	assert(condition, message)
end
check(model.service("https://zoom.us/j/123") == "Zoom", "Zoom detection")
check(not model.service("https://zoom.us.evil.example/j/123"), "No deceptive suffix")
check(not model.url("https://zoom.us@evil.example/"), "No URL userinfo")
check(not model.url("javascript:alert(1)"), "Web links only")
check(not model.url("https://example.com/\ncommand"), "No control characters")
check(model.shorten("日本語の長い会議名", 5) == "日本語の…", "UTF-8 truncation")
local midnight = os.time({ year = 2026, month = 11, day = 12, hour = 0 }) * 1000
check(common.dayEnd(now) == midnight, "Exact local midnight")
-- TZ=America/New_York exercises the short and long DST days as well.
for _, day in ipairs({ { 2026, 3, 8 }, { 2026, 11, 1 } }) do
	local start = os.time({ year = day[1], month = day[2], day = day[3], hour = 0 }) * 1000
	local finish = os.time({ year = day[1], month = day[2], day = day[3] + 1, hour = 0 }) * 1000
	check(common.dayEnd(start) == finish, "DST day boundary")
end

local service = loadEntry("service")
local widget = loadEntry("widget")
service.update()
widget.update()
check(bar.setText == "Calendar…", "Unknown sync is not an empty calendar")
raw = {}
service.update()
widget.update()
check(bar.setText == "" and bar.setVisible, "Empty calendar still opens agenda")
raw = {
	event("ended", -60, -30),
	event("current", -10, 10),
	event("next", 4, 34),
	event("all-day", -720, 720, { allDay = true }),
	event("duplicate", 4, 34, { title = "next", calendarName = "Personal" }),
	event("repeat", 1440, 1470),
	event("repeat", 2880, 2910),
	event("unsafe", 40, 70, { url = "javascript:bad" }),
}
service.update()
check(common.nextEvent(now).id == "current", "Current meeting preferred")
config.prefer_current = false
check(common.nextEvent(now).id == "next", "Next meeting preference")
config.prefer_current = true
local filtered = common.events(now)
check(#filtered == 5, "Past, duplicates and date horizon filtered")
config.calendars = { "Personal" }
check(#common.events(now) == 1, "Calendar selection")
config.calendars = {}
config.meetings_only = true
check(#common.events(now) == 4, "Unknown/unsafe URLs excluded from meetings-only")
config.meetings_only = false
common.joinNext()
check(processes[#processes][1] == "xdg-open", "Default opener")
config.service_commands = { meet = "/custom/browser" }
common.joinNext()
check(
	processes[#processes][1] == "/custom/browser" and #processes[#processes] == 2,
	"Argument array and per-service override"
)
config.service_commands = {}

-- A due reminder shows once; snooze survives restarting the service after start.
check(visible and state.reminder.id == "next", "Upcoming meeting reminder")
set("reminderAction", { kind = "snooze" })
check(not visible, "Snooze closes overlay")
now = initialNow + 60000
service.update()
check(not visible, "Not before snooze deadline")
now = initialNow + 120000
service.update()
check(visible, "Snooze fires again")
set("reminderAction", { kind = "dismiss" })
service.update()
check(not visible, "Dismiss prevents reappearing")
-- Repeat dismissal after restart must stay dismissed.
watchers = {}
service = loadEntry("service")
service.update()
check(not visible, "Dismissal survives restart")
now = initialNow
raw = { event("snooze-across-start", 1, 30) }
service.update()
set("reminderAction", { kind = "snooze" })
watchers = {}
service = loadEntry("service")
now = initialNow + 180000
service.update()
check(visible, "Snooze still works after event start and restart")
raw[1].title = "Updated meeting"
raw[1].url = "https://meet.google.com/updated"
service.update()
check(
	state.reminder.title == "Updated meeting" and state.reminder.url == raw[1].url,
	"Active reminder follows event edits"
)
raw = {}
service.update()
check(not visible and state.reminder == nil, "Cancelled event removes active overlay")

raw = { event("panel", 10, 40) }
service.update()
local panel = loadEntry("panel")
panel.onOpen()
local function find(node, predicate)
	if predicate(node) then
		return node
	end
	for _, child in ipairs(node.children) do
		local found = find(child, predicate)
		if found then
			return found
		end
	end
end
check(
	find(tree, function(node)
		return node.props.text == "panel"
	end),
	"Agenda contains event"
)
local star = find(tree, function(node)
	return node.props.tooltip == "Save or remove favorite"
end)
star.props.onClick()
check(#common.bookmarks() == 1 and files["/state/bookmarks.json"], "Favorite saved")
local copy = find(tree, function(node)
	return node.props.tooltip == "Copy link"
end)
copy.props.onClick()
check(state.clipboard == raw[1].url, "Link copied")
find(tree, function(node)
	return node.props.text == "Favorites"
end).props.onClick()
check(
	find(tree, function(node)
		return node.props.text == "panel"
	end),
	"Favorite rendered"
)
-- A missing optional color on a bookmark must not break UI construction.
find(tree, function(node)
	return node.props.tooltip == "Save or remove favorite"
end).props.onClick()
check(#common.bookmarks() == 0, "Favorite removed")
local reminder = loadEntry("reminder")
set("reminder", event("overlay", 3, 33))
reminder.update()
check(
	find(tree, function(node)
		return node.props.text == "Join meeting"
	end),
	"Full-screen join control"
)
-- Each regression starts with a fresh host and service, without inherited timers or files.
local function reset(events)
	config = clone(defaults)
	state, watchers, files, serialized, processes = {}, {}, {}, {}, {}
	visible, tree, bar, raw = false, nil, {}, events
	failWrites, processAccepted, processExitCode = false, true, 0
	expectedErrors, errors = false, {}
	now = initialNow
	return loadEntry("service")
end
local function saved(name)
	local value = files["/state/" .. name .. ".json"]
	return value and runtime.json.decode(value) or {}
end

-- A visible reminder must not make another already-due meeting silently expire.
for _, restart in ipairs({ false, true }) do
	service = reset({ event("first", 1, 60), event("queued", 2, 32) })
	service.update()
	check(state.reminder.id == "first", "First reminder displayed")
	now = initialNow + 4 * 60000
	service.update()
	set("reminderAction", { kind = "dismiss" })
	if restart then
		state, watchers = {}, {}
		visible = false
		service = loadEntry("service")
	end
	service.update()
	check(
		visible and state.reminder.id == "queued",
		restart and "Queued meeting survives service restart"
			or "Queued meeting survives its one-minute start grace period"
	)
	set("reminderAction", { kind = "dismiss" })
	service.update()
	check(not visible, "Queued meeting is still dismissed only once")
end

-- Queued meetings respect a shorter lead time selected while another reminder is open.
service = reset({ event("first", 1, 60), event("later", 5, 35) })
service.update()
check(state.reminder.id == "first", "First reminder displayed before lead time change")
config.reminder_minutes = 1
set("reminderAction", { kind = "dismiss" })
service.update()
check(not visible and state.reminder == nil, "Queued meeting waits for the shortened lead time")
now = initialNow + 4 * 60000
service.update()
check(visible and state.reminder.id == "later", "Queued meeting appears at the new lead time")

-- Pending reminders must follow cancellation and expiration, not a stale event copy.
for _, removed in ipairs({ false, true }) do
	service = reset({ event("first", 1, 60), event("queued", 2, removed and 32 or 3) })
	service.update()
	now = initialNow + 4 * 60000
	if removed then
		raw = { raw[1] }
	end
	service.update()
	set("reminderAction", { kind = "dismiss" })
	service.update()
	check(
		not visible and state.reminder == nil,
		removed and "Cancelled queue entry removed" or "Ended queue entry removed"
	)
end
service = reset({ event("discovered-late", -2, 30) })
service.update()
check(not visible, "Newly discovered late meetings remain suppressed")

for _, edit in ipairs({ "url", "allDay" }) do
	service = reset({ event("edited", 1, 30) })
	service.update()
	check(visible, "Reminder visible before eligibility edit")
	raw[1][edit] = edit == "url" and "" or true
	service.update()
	check(not visible and state.reminder == nil, "Removing meeting eligibility closes active reminder: " .. edit)
end
service = reset({ event("ended-short", -0.75, -0.25) })
config.show_past = true
service.update()
check(not visible, "Past agenda entries never produce ended-meeting reminders")

-- Expired and deleted snoozes are removed from disk even with no new reminder to write state.
for _, removed in ipairs({ false, true }) do
	service = reset({ event("snoozed", 1, 2) })
	config.snooze_minutes = 30
	service.update()
	set("reminderAction", { kind = "snooze" })
	check(next(saved("snoozed")) ~= nil, "Snooze initially persisted")
	if removed then
		raw = {}
	else
		now = initialNow + 3 * 60000
	end
	service.update()
	check(
		next(saved("snoozed")) == nil,
		removed and "Deleted snooze persisted as removed" or "Expired snooze persisted as removed"
	)
end
service = reset({ event("temporarily-unavailable", 1, 30) })
service.update()
set("reminderAction", { kind = "snooze" })
local syncedEvents = raw
raw = nil
service.update()
check(next(saved("snoozed")) ~= nil, "Unknown snapshot must not discard snooze")
raw = syncedEvents
now = initialNow + 2 * 60000
service.update()
check(visible and state.reminder.id == "temporarily-unavailable", "Snooze survives a temporary missing snapshot")

-- Calendar choices and filtering must precede cross-calendar duplicate removal.
for _, extraEvent in ipairs({ false, true }) do
	service = reset({
		event("work-copy", 10, 40, { title = "Shared meeting" }),
		event("personal-copy", 10, 40, { title = "Shared meeting", calendarName = "Personal" }),
	})
	if extraEvent then
		raw[#raw + 1] = event("personal-only", 50, 80, { calendarName = "Personal" })
	end
	service.update()
	panel = loadEntry("panel")
	panel.onOpen()
	local selector = find(tree, function(node)
		return node.props.key == "calendar-filter"
	end)
	local personalIndex
	for i, name in ipairs(selector.props.options) do
		if name == "Personal" then
			personalIndex = i - 1
		end
	end
	check(personalIndex ~= nil, "Calendar represented only by duplicate remains selectable")
	selector.props.onChange(tostring(personalIndex))
	check(
		find(tree, function(node)
			return node.props.text == "Shared meeting"
		end),
		"Selecting Personal preserves its duplicate meeting"
	)
	check(
		find(tree, function(node)
			return type(node.props.text) == "string" and node.props.text:find("Personal", 1, true)
		end),
		"Selected calendar's event is rendered"
	)
end

-- Host failures should be reported and failed favorites must not appear saved.
service = reset({})
expectedErrors, failWrites = true, true
common.toggleBookmark(event("unsaved", 10, 40))
check(
	#common.bookmarks() == 0 and files["/state/bookmarks.json"] == nil,
	"Failed favorite write preserves previous state"
)
check(#errors == 1 and errors[1]:find("Could not save", 1, true), "Write failure reported")
failWrites = false
processAccepted = false
check(not common.openLink("https://meet.google.com/valid"), "Opener rejection returned to caller")
check(#errors == 2 and errors[2]:find("Could not start", 1, true), "Opener rejection reported")
processAccepted, processExitCode = true, 1
check(common.openLink("https://meet.google.com/valid"), "Started process remains accepted despite failed completion")
check(#errors == 3 and errors[3]:find("Could not open", 1, true), "Nonzero opener exit reported")
print("Meeting Bar: calendar filtering, reminder lifecycle, persistence, DST, UI and host failures passed")
