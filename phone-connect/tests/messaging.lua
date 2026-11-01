local directory = arg[1] or "phone-connect"
local Model = assert(loadfile(directory .. "/messaging-model.luau"))()
local d = Model.device()
Model.reduce(d, {
	type = "capabilities",
	connected = true,
	capabilities = { messages = true, contacts = true, notifications = true },
})
local function message(id, date, text)
	return {
		id = id,
		thread = "42",
		date = date,
		body = text,
		addresses = { "+15550100" },
		outgoing = false,
	}
end
Model.reduce(
	d,
	{ type = "contacts", items = { { id = "c", name = "Alex", numbers = { "+1 (555) 0100" } } } }
)
Model.reduce(d, { type = "message", message = message("2", 200, "newer") })
Model.reduce(d, { type = "message", message = message("1", 100, "older 🐈") })
Model.reduce(d, { type = "message", message = message("2", 200, "updated") })
assert(#Model.sorted(d.messages["42"]) == 2, "Duplicate messages must merge")
assert(d.threads["42"].body == "updated", "Older history cannot replace the latest preview")
assert(Model.sorted(d.messages["42"], true)[1].id == "1")
assert(Model.title(d, d.threads["42"]) == "Alex")
assert(Model.matches(d, d.threads["42"], "older 🐈"), "Search includes fetched messages")
assert(Model.matches(d, d.threads["42"], "alex"))
Model.reduce(d, { type = "threads", items = {} })
assert(d.threads["42"], "A late empty snapshot must not erase a new message")
table.insert(d.contacts, { name = "Different person", numbers = { "+15550100" } })
assert(
	Model.name(d.contacts, "+15550100") == "+15550100",
	"Ambiguous contacts must retain the number"
)
Model.reduce(d, { type = "notification", notification = { id = "1", title = "hello" } })
Model.reduce(d, { type = "notification_removed", id = "1" })
assert(next(d.notifications) == nil)
Model.reduce(d, { type = "connection", connected = false })
assert(not d.connected and d.messages["42"], "Offline retains session history")
Model.reduce(d, { type = "thread_removed", thread = "42" })
assert(d.messages["42"] == nil and d.threads["42"] == nil)

-- Exercise the service with queued callbacks, including a switch/reconnect while a send is pending.
local state, callbacks, streams, tokens = {}, {}, {}, {}
local publications = 0
local clock = 100
local api = {
	state = {
		get = function(k)
			return state[k]
		end,
		set = function(k, v)
			state[k] = v
			if k == "pc.messaging" then
				publications = publications + 1
			end
		end,
	},
	pluginDir = function()
		return directory
	end,
	nowMs = function()
		return clock * 1000
	end,
	json = {
		encode = function(v)
			local key = tostring(#tokens + 1)
			tokens[#tokens + 1] = v
			return key
		end,
		decode = function(v)
			return tokens[tonumber(v)]
		end,
	},
	runAsync = function(argv, cb)
		table.insert(callbacks, { argv = argv, cb = cb })
		return true
	end,
	runStream = function(_, cb)
		table.insert(streams, cb)
		return true
	end,
	processMatches = function(cb)
		cb(false)
	end,
}
local env = setmetatable({
	os = {
		time = function()
			return clock
		end,
	},
	require = function()
		return Model
	end,
}, { __index = _G })
local service = assert(loadfile(directory .. "/messaging-service.luau", "t", env))().start(api)
local function complete(ok, events)
	local item = table.remove(callbacks, 1)
	item.cb({
		exitCode = ok and 0 or 1,
		stdout = api.json.encode({
			ok = ok,
			events = events or {},
			message = ok and nil or "Test failure",
		}),
	})
	return item
end
complete(true)
local function emit(e)
	streams[1](api.json.encode(e))
	service.tick()
end
service.command({ op = "history", device = "a", thread = "42" })
assert(#callbacks == 0, "History must wait until the watcher subscribes")
emit({ type = "ready" })
assert(#callbacks == 1, "Ready must release deferred history requests")
complete(true)
emit({ type = "capabilities", device = "a", connected = true, capabilities = { messages = true } })
local before = publications
for i = 1, 700 do
	local m = message(tostring(i), i, "Sync preview")
	m.thread = tostring(i)
	streams[1](api.json.encode({ type = "message", device = "a", message = m }))
end
assert(publications == before, "A sync burst must not publish the full history for each message")
service.tick()
assert(
	publications == before + 1 and state["pc.messaging"].devices.a.threads["700"],
	"One tick must publish all messages in the burst"
)
local framed = message("framed", 701, "Large snapshot")
framed.thread = "framed"
local token = api.json.encode({ type = "threads", device = "a", items = { framed } })
streams[1](api.json.encode({ type = "chunk", index = 1, count = 2, data = token:sub(1, 1) }))
service.tick()
assert(
	not state["pc.messaging"].devices.a.threads.framed,
	"Incomplete frames must not publish a partial snapshot"
)
streams[1](api.json.encode({ type = "chunk", index = 2, count = 2, data = token:sub(2) }))
service.tick()
assert(
	state["pc.messaging"].devices.a.threads.framed,
	"Complete frames must reconstruct and apply the snapshot"
)
state["pc.drafts"] = { ["a:sms:42"] = { text = "Keep this", rev = 0 } }
local command =
	{ op = "sms_send", device = "a", thread = "42", text = "Keep this", target = "a:sms:42" }
service.command(command)
service.command(command)
assert(#callbacks == 1, "Duplicate send must be blocked")
assert(callbacks[1].argv[1] == "python3" and type(callbacks[1].argv) == "table")
complete(false)
assert(state["pc.drafts"]["a:sms:42"].text == "Keep this", "Failed send must retain text")
assert(not state["pc.messaging"].results["a:sms:42"].ok)
emit({ type = "notification", device = "a", notification = { id = "n", title = "temporary" } })
service.command({ op = "sync", device = "a" })
emit({ type = "notification_removed", device = "a", id = "n" })
complete(
	true,
	{ { type = "notifications", device = "a", items = { { id = "n", title = "stale" } } } }
)
assert(
	not state["pc.messaging"].devices.a.notifications.n,
	"A late snapshot cannot resurrect a dismissed notification"
)
service.command(command)
emit({ type = "capabilities", device = "b", connected = true, capabilities = { messages = true } })
complete(true)
assert(state["pc.drafts"]["a:sms:42"].text == "", "Result belongs to original device")
assert(state["pc.drafts"]["a:sms:42"].rev == 1, "Success must re-key the uncontrolled input")
state["pc.drafts"]["a:sms:42"].text = "Keep this"
service.command(command)
emit({ type = "connection", device = "a", connected = false })
complete(true)
assert(state["pc.drafts"]["a:sms:42"].text == "Keep this", "Stale result must not clear draft")
assert(not state["pc.messaging"].results["a:sms:42"].ok)
emit({ type = "reset" })
assert(not state["pc.messaging"].devices.b.connected)
clock = clock + 40
service.tick()
assert(#callbacks == 1, "Dead stream should be restarted")

-- Dependency failures are published separately from phone connection state.
state, callbacks, streams = {}, {}, {}
service = assert(loadfile(directory .. "/messaging-service.luau", "t", env))().start(api)
complete(false)
assert(state["pc.messaging"].bridgeStatus == "unavailable")
assert(state["pc.messaging"].error == "Test failure")
assert(#streams == 0, "A failed dependency probe must not start a watcher")
state["pc.drafts"] = { ["a:sms:42"] = { text = "Keep this", rev = 0 } }
service.command(command)
assert(#callbacks == 0, "Unavailable helper must reject commands without spawning")
assert(not state["pc.messaging"].results["a:sms:42"].ok)
assert(state["pc.drafts"]["a:sms:42"].text == "Keep this")
clock = clock + 40
service.tick()
complete(true)
emit({ type = "ready" })
assert(state["pc.messaging"].bridgeStatus == "ready", "Installing dependencies must recover")
assert(state["pc.messaging"].error == "")

api.runAsync = function()
	return false
end
service = assert(loadfile(directory .. "/messaging-service.luau", "t", env))().start(api)
assert(state["pc.messaging"].bridgeStatus == "unavailable", "Missing Python must be visible")
assert(state["pc.messaging"].error:find("Python 3", 1, true))
print("Messaging model and service regressions passed")
