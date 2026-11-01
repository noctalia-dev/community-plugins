local directory = arg[1] or "phone-connect"
local values, watchers, tree, commands = {}, {}, nil, {}
local reads = {}
local config = { enable_clipboard_action = true }
local function noop() end
local api = {
	state = {
		get = function(k)
			reads[k] = (reads[k] or 0) + 1
			return values[k]
		end,
		set = function(k, v)
			values[k] = v
			if k == "pc.cmd" then
				table.insert(commands, v)
			end
		end,
		watch = function(k, cb)
			watchers[k] = cb
		end,
	},
	nowMs = function()
		return 100000
	end,
	formatTime = function()
		return "Oct 28 · 12:00"
	end,
	getConfig = function(k)
		return config[k]
	end,
	fileExists = function()
		return false
	end,
	copyToClipboard = noop,
	json = {
		decode = function(v)
			return v
		end,
	},
}
local ui = setmetatable({}, {
	__index = function(_, kind)
		return function(props, children)
			for i, v in ipairs(children or {}) do
				assert(type(v) == "table", kind .. " child " .. i)
			end
			return { kind = kind, props = props, children = children or {} }
		end
	end,
})
local renders, needsFrame = 0, false
local env = setmetatable({
	noctalia = api,
	ui = ui,
	panel = {
		render = function(t)
			tree = t
			renders = renders + 1
		end,
		close = noop,
		setNeedsFrameTick = function(value)
			needsFrame = value
		end,
	},
}, { __index = _G })
local modules = {}
env.require = function(path)
	if not modules[path] then
		modules[path] = assert(loadfile(directory .. "/" .. path, "t", env))()
	end
	return modules[path]
end
local Model = env.require("./messaging-model.luau")
local d = Model.device()
d.connected = true
d.capabilities = { messages = true, contacts = true, notifications = true }
d.contacts = { { id = "alex", name = "Alex", numbers = { "123", "456" }, search = "alex 123 456" } }
local m = {
	id = "1",
	thread = "42",
	date = 1000,
	body = "hello 👋",
	addresses = { "123" },
	attachments = 1,
}
Model.reduce(d, { type = "message", message = m })
values["pc.devices"] = {
	a = { id = "a", name = "Phone with a very long name", isPaired = true, isReachable = true },
	b = { id = "b", name = "Phone B", isPaired = true, isReachable = true },
}
values["pc.order"] = { "a", "b" }
values["pc.selected"] = "a"
values["pc.messaging"] = { devices = { a = d }, pending = {}, results = {} }
values["pc.trTable"] = {} -- Translation keys make the callbacks easy to locate.
assert(loadfile(directory .. "/panel.luau", "t", env))()
local function find(predicate, node)
	node = node or tree
	if predicate(node) then
		return node
	end
	for _, child in ipairs(node.children) do
		local result = find(predicate, child)
		if result then
			return result
		end
	end
end
local function text(s)
	return assert(
		find(function(n)
			return n.props.text == s
		end),
		s
	)
end
local function key(s)
	return assert(
		find(function(n)
			return n.props.key == s
		end),
		s
	)
end
env.onOpen()
assert(#commands == 0, "Opening populated conversations must not trigger another full sync")
local deviceSelector = find(function(node)
	return node.kind == "select"
end)
assert(deviceSelector.props.selectedIndex == 0, "Device selector must reflect the selected phone")
key("thread:a:42").props.onClick()
assert(commands[#commands].op == "history" and commands[#commands].start == 0)
local composer = key("composer-row:a:sms:42")
assert(composer.props.height == 40, "Empty composer must use one compact row")
local input = key("a:sms:42:input:0")
input.props.onChange("Keep this draft\nSecond line")
assert(key("composer-row:a:sms:42").props.height == 58, "Multiline draft must grow")
assert(text("panel.sms_send").props.enabled)
text("panel.sms_send").props.onClick()
assert(commands[#commands].text == "Keep this draft\nSecond line")
assert(
	values["pc.drafts"]["a:sms:42"].text == "Keep this draft\nSecond line",
	"UI must not clear an unacknowledged send"
)
values["pc.messaging"].pending["a:sms:42"] = {}
env.render()
assert(not text("panel.sms_send").props.enabled)
values["pc.messaging"].pending = {}
text("chat.tab_contacts").props.onClick()
assert(not find(function(n)
	return n.props.text == "456"
end), "Numbers should start collapsed")
before = #commands
key("contact-toggle:a:alex").props.onClick()
assert(#commands == before, "Expanding a contact must not send a phone command")
assert(text("123") and text("456"))
key("contact-toggle:a:alex").props.onClick()
assert(not find(function(n)
	return n.props.text == "456"
end), "Contact should collapse again")
key("contact-toggle:a:alex").props.onClick()
text("chat.message").props.onClick()
assert(key("composer-row:a:sms:new:123"), "Expanded number should open the right recipient")
text("chat.tab_contacts").props.onClick()
key("contacts-search:a").props.onChange("unknown")
assert(text("chat.no_results"))
text("chat.tab_device").props.onClick()
local before = #commands
assert(find(function(n)
	return n.props.tooltip == "action.unpair"
end)).props.onClick()
assert(#commands == before, "Unpair first click must only ask for confirmation")
text("chat.cancel").props.onClick()
env.onClose()
env.onOpen()
assert(values["pc.drafts"]["a:sms:42"].text == "Keep this draft\nSecond line")
-- Switching a device must not seed another device's composer with this draft.
local select = find(function(n)
	return n.kind == "select"
end)
select.props.onChange("1")
assert(commands[#commands].device == "b")
-- Preview cannot dispatch any phone operation, including destructive controls.
env.onIpc("preview", {
	devices = values["pc.devices"],
	order = { "a" },
	selected = "a",
	thread = "42",
	messaging = values["pc.messaging"],
})
before = #commands
text("panel.sms_send").props.onClick()
env.onIpc("view", { tab = "device" })
assert(find(function(n)
	return n.props.tooltip == "action.unpair"
end)).props.onClick()
text("action.unpair").props.onClick()
assert(#commands == before, "Preview must not send commands")
env.onClose()
-- A real address book must not create an unbounded native tree or repeatedly
-- decode shared snapshots. This caused native callback timeouts.
for i = 2, 1000 do
	table.insert(d.contacts, {
		id = tostring(i),
		name = "Person " .. i,
		numbers = { tostring(i) },
		search = "person " .. i,
	})
end
env.onOpen()
env.onIpc("view", { tab = "contacts" })
key("contacts-search:a").props.onChange("")
reads["pc.trTable"] = 0
env.render()
assert(reads["pc.trTable"] == 0, "Translations must reuse the watched snapshot")
assert(text("1 / 40"))
assert(not find(function(n)
	return n.props.key == "contact:a:26"
end))
text("chat.next").props.onClick()
assert(key("contact:a:26") and text("2 / 40"))
text("chat.previous").props.onClick()
assert(text("1 / 40"))
key("contacts-search:a").props.onChange("person 1000")
assert(key("contact:a:1000"), "Search must cover contacts outside the current page")
assert(not find(function(n)
	return n.props.text == "chat.next"
end))
-- Keep long histories bounded while allowing both directions through loaded pages.
for i = 2, 121 do
	Model.reduce(d, {
		type = "message",
		message = {
			id = tostring(i),
			thread = "42",
			date = i * 1000,
			body = "Loaded message " .. i,
			addresses = { "123" },
			attachments = 0,
		},
	})
end
env.onIpc("view", { tab = "messages", compact = false })
key("thread:a:42").props.onClick()
assert(key("message:a:42:121"))
assert(not find(function(n)
	return n.props.key == "message:a:42:96"
end))
before = #commands
text("chat.load_older").props.onClick()
assert(#commands == before, "Paging cached history must not refetch it")
assert(key("message:a:42:96"))
assert(not find(function(n)
	return n.props.key == "message:a:42:121"
end))
text("chat.newer_messages").props.onClick()
assert(key("message:a:42:121"))
-- Opening always follows the setting, including after visiting another tab.
for _, tab in ipairs({ "device", "contacts", "notifications", "messages", "invalid" }) do
	config.default_page = tab
	env.onClose()
	env.onOpen()
	local expected = tab == "invalid" and "messages" or tab
	assert(
		text("chat.tab_" .. expected).props.selected,
		"Default page must be honored on every open"
	)
end
-- A populated phone must not deserialize shared history on each keystroke.
-- Watch callbacks receive replacement snapshots (unlike the mutable mock above).
local populated = Model.device()
populated.connected = true
populated.capabilities = { messages = true }
populated.contacts = { { name = "Searchable person", numbers = { "555" } } }
for i = 1, 2000 do
	Model.reduce(populated, {
		type = "message",
		message = {
			id = tostring(i),
			thread = tostring(i),
			date = i,
			body = "Conversation " .. i,
			addresses = { "555" },
		},
	})
end
local replacement = { devices = { a = populated }, pending = {}, results = {} }
values["pc.messaging"] = replacement
local beforeRenders = renders
watchers["pc.messaging"](replacement)
watchers["pc.devices"](values["pc.devices"])
watchers["pc.trTable"]({ ["chat.search_scope"] = "Replacement translations" })
assert(
	renders == beforeRenders and needsFrame,
	"A burst of state updates should schedule a single paint"
)
env.onFrameTick()
assert(
	renders == beforeRenders + 1 and not needsFrame,
	"Paint must consume the latest snapshots and stop frame ticks"
)
env.onIpc("view", { tab = "messages", compact = false })
text("Replacement translations")
reads["pc.messaging"] = 0
reads["pc.trTable"] = 0
for _, query in ipairs({ "searchable", "missing", "Conversation 1999", "555", "" }) do
	key("thread-search:a").props.onChange(query)
	if query == "missing" then
		text("chat.no_results")
	end
	if query == "Conversation 1999" then
		key("thread:a:1999")
	end
end
assert(
	reads["pc.messaging"] == 0 and reads["pc.trTable"] == 0,
	"Typing must not reread shared message or translation state"
)
key("thread:a:2000").props.onClick()
local matched, originalMatches = 0, Model.matches
Model.matches = function(...)
	matched = matched + 1
	return originalMatches(...)
end
env.onIpc("view", { compact = true })
assert(matched == 0, "A compact thread must not search or build its hidden conversation list")
Model.matches = originalMatches
env.onIpc("view", { compact = false })
-- Changes while closed should be ready for the next open without scheduling frames.
env.onClose()
beforeRenders = renders
replacement.devices = {}
watchers["pc.messaging"](replacement)
assert(not needsFrame and renders == beforeRenders)
env.onOpen()
text("chat.no_threads")
assert(
	commands[#commands].op == "sync",
	"An empty conversation cache must still request synchronization"
)
-- Local helper failure must not show misleading empty/offline phone guidance.
local helperFailure = {
	devices = {},
	pending = {},
	results = {},
	bridgeStatus = "unavailable",
	error = "Install Python 3 and PyGObject (python-gobject or python3-gi).",
}
watchers["pc.messaging"](helperFailure)
for _, tab in ipairs({ "messages", "contacts", "notifications" }) do
	env.onIpc("view", { tab = tab })
	text("chat.helper_unavailable")
	text(helperFailure.error)
	assert(not find(function(node)
		return node.props.text == "chat.offline" or node.props.text == "chat.no_notifications"
	end), "Missing local dependencies must not be presented as phone status")
end
text("chat.open_device").props.onClick()
assert(text("chat.find_phone").props.enabled, "Device controls must remain usable")
before = #commands
text("chat.find_phone").props.onClick()
assert(#commands == before + 1 and commands[#commands].op == "ring")
print("Panel interaction regressions passed")
