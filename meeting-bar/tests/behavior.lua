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
		files[path] = value
		return true
	end,
	setUpdateInterval = function() end,
	notify = function() end,
	notifyError = function(_, error)
		error = tostring(error)
		assert(false, error)
	end,
	runAsync = function(argv)
		processes[#processes + 1] = argv
		return true
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
print("Meeting Bar: filtering, recurrence, DST, URLs, actions, persistence, snooze and UI callbacks passed")
