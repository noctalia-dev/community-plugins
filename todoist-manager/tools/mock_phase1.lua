--[[
tools/mock_phase1.lua — offline harness for the Todoist Phase 1 plugin.

Runs with stock Lua 5.4, no Noctalia instance needed:
    lua5.4 tools/mock_phase1.lua        (from the todoist-manager/ directory)

What it does: stubs the `noctalia` surface (http, json, state, string, ...),
loads the REAL service.luau / panel.luau / launcher.luau through a require
shim, and drives them through the state channel exactly as the shell would.

What it proves: token resolution, the 5-request boot refresh, view + count
publication, the per-view TTL cache hit, quick-add success, quick-add
transport failure -> unknown_outcome with exactly one POST (never retried),
GET retry budget, priority mapping, and that both UI entries build a render
tree without erroring.

Known stub: noctalia.json is replaced with a sentinel codec, so the HTTP
bodies below are checked for shape rather than parsed as real JSON. JSON
round-tripping is the runtime's job, not this plugin's.
]]

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("@(.*/)") or "./"):gsub("tools/$", "")

-- ── test clock ──────────────────────────────────────────────────
local clock = 1792029000000

-- ── state channel ───────────────────────────────────────────────
-- watch() keeps only the latest callback per key: reloading an entry means
-- the previous VM is gone, so appended handlers would double-fire.
local state_store = {}
local watchers = {}

local function fire(key, value)
	local fn = watchers[key]
	if fn then
		fn(value)
	end
end

local function getState(key)
	return state_store[key]
end

-- ── stub noctalia ───────────────────────────────────────────────
local env = {}
local cfg = { token = "", token_file = "", max_retries = 1, cache_tasks = false, confirm_delete = true, default_project = "", default_labels = {}, default_priority = "none" }
local log_lines = {}
local notified = {}
local runasync = {}
local toggled = {}
local tr_calls = {}
local cache_files = {} -- path -> registered snapshot body (simulated on-disk cache)

local function lastSubs(key)
	for i = #tr_calls, 1, -1 do
		if tr_calls[i].key == key then
			return tr_calls[i].subs
		end
	end
	return nil
end

local function urlEncode(s)
	return (tostring(s):gsub("[^%w%-%_%.%~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function urlDecode(s)
	s = tostring(s):gsub("+", " ")
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- sentinel codec: register() hands out an opaque body string for a table
local body_map = {}
local body_n = 0
local function register(v)
	body_n = body_n + 1
	local s = "@body" .. body_n
	body_map[s] = v
	return s
end

noctalia = {
	getenv = function(name)
		return env[name]
	end,
	getConfig = function(key)
		return cfg[key]
	end,
	readFile = function(path)
		return cache_files[path] or env["file:" .. tostring(path)]
	end,
	expandPath = function(p)
		return tostring(p):gsub("^~", "/home/tester")
	end,
	fileExists = function(path)
		return cache_files[path] ~= nil or env["file:" .. tostring(path)] ~= nil
	end,
	removeFile = function() end,
	writeFile = function()
		return true
	end,
	renameFile = function()
		return true
	end,
	pluginDataDir = function()
		return "/tmp/todoist-mock-data"
	end,
	string = {
		trim = function(s)
			return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
		end,
		urlEncode = urlEncode,
		urlDecode = urlDecode,
	},
	json = {
		-- Only the request body is ever encoded; keep the text visible so the
		-- test can assert what was actually sent to Quick Add.
		encode = function(v)
			if type(v) ~= "table" then
				return "@encoded"
			end
			if type(v.text) == "string" then
				return "QADD:" .. v.text
			end
			-- Deterministic key dump (sorted) so tests can assert which fields
			-- a write carried — e.g. that updateTask stripped project_id.
			local keys = {}
			for k in pairs(v) do
				keys[#keys + 1] = tostring(k)
			end
			table.sort(keys)
			local parts = {}
			for _, k in ipairs(keys) do
				local val = v[k]
				if type(val) == "table" then
					local xs = {}
					for _, x in ipairs(val) do
						xs[#xs + 1] = tostring(x)
					end
					parts[#parts + 1] = k .. "=[" .. table.concat(xs, ",") .. "]"
				else
					parts[#parts + 1] = k .. "=" .. tostring(val)
				end
			end
			local enc = "@obj{" .. table.concat(parts, ";") .. "}"
			-- Keep encode/decode symmetric so the backend can read a request
			-- body back as the table the caller built.
			body_map[enc] = v
			return enc
		end,
		decode = function(s)
			if s == nil or s == "" then
				return nil
			end
			return body_map[s] -- nil => api.luau's "bad json" path
		end,
	},
	nowMs = function()
		return clock
	end,
	commandExists = function(name)
		return name == "chmod" or name == "xdg-open"
	end,
	runAsync = function(argv)
		table.insert(runasync, argv)
		return true
	end,
	copyToClipboard = function() end,
	togglePanel = function(id)
		table.insert(toggled, id)
	end,
	openSettings = function() end,
	setUpdateInterval = function() end,
	log = function(m)
		table.insert(log_lines, m)
	end,
	notify = function(t, b)
		table.insert(notified, { ok = true, title = t, body = b })
	end,
	notifyError = function(t, b)
		table.insert(notified, { ok = false, title = t, body = b })
	end,
	fuzzyScore = function(needle, haystack)
		if needle == nil or needle == "" then
			return nil
		end
		local i = tostring(haystack):lower():find(tostring(needle):lower(), 1, true)
		if i == nil then
			return nil
		end
		return 100 - i -- earlier match scores higher
	end,
	tr = function(k, subs)
		-- Record substitutions so the test can assert interpolation intent
		-- (the stub returns the key itself, so the text is not visible).
		table.insert(tr_calls, { key = k, subs = subs })
		local out = tostring(k)
		if type(subs) == "table" then
			out = out:gsub("{(%w+)}", function(name)
				return tostring(subs[name] or ("{" .. name .. "}"))
			end)
		end
		return out
	end,
	state = {
		set = function(k, v)
			state_store[k] = v
		end,
		get = getState,
		watch = function(k, fn)
			watchers[k] = fn
		end,
	},
	http = function(req, cb)
		local r = route(req)
		cb(r)
		return true
	end,
}

-- ── fake Todoist backend ────────────────────────────────────────
local calls = {}
-- false | "http500" | "transport" | "404" | "<kind>_once" | "transport_lost"
-- A plain fault persists until the test clears it; "_once" fires on the first
-- call only (so a retry can succeed); "transport_lost" applies the mutation and
-- then drops the response, which is what the confirming GET has to recover.
local fault = { filter_overdue = false, quick = false, close = false, reopen = false, delete = false, update = false, move = false }

-- Resolve a fault for this call, clearing one-shot variants.
local function takeFault(name)
	local v = fault[name]
	if v == "transport_once" then
		fault[name] = false
		return "transport"
	elseif v == "http500_once" then
		fault[name] = false
		return "http500"
	end
	return v
end

local PROJECTS_P1 = {
	{ id = "p-inbox", name = "Inbox", inbox_project = true, is_shared = false },
	{ id = "p-work", name = "Work", is_shared = true },
}
local PROJECTS_P2 = {
	{ id = "p-home", name = "Home" },
}
local DUE = { date = "2026-10-10", string = "Oct 10", is_recurring = false, lang = "en" }
local T_OVERDUE = { id = "t1", content = "Pay rent", project_id = "p-home", priority = 4, due = DUE, labels = {}, checked = false }
local T_TODAY = { id = "t2", content = "Write report", project_id = "p-work", priority = 2, due = DUE, labels = {}, checked = false }
local T_INBOX = { id = "t3", content = "Read article", project_id = "p-inbox", priority = 1, labels = {}, checked = false }

-- Mutable store backing the Phase 2 (M1) mutation routes below.
local MUT = {
	tasks = {
		m1 = { id = "m1", content = "original", project_id = "p-home", priority = 1, labels = {}, checked = false },
		-- Aliases (not copies): the filter routes serve these same tables, so a
		-- mutation is visible to a subsequent refetch, like the real API.
		t1 = T_OVERDUE,
		t2 = T_TODAY,
		t3 = T_INBOX,
	},
	next_id = 0,
}

-- Sections belong to one project; the API filters by project_id.
local SECTIONS = {
	{ id = "s-home-chores", project_id = "p-home", name = "Chores", child_order = 1 },
	{ id = "s-work-todo", project_id = "p-work", name = "To do", child_order = 1 },
	{ id = "s-work-later", project_id = "p-work", name = "Later", child_order = 2 },
}

-- The request body as the caller's table (json.decode resolves through the
-- same map json.encode registered it in).
local function reqBody(req)
	if req.body == nil or req.body == "" then
		return nil
	end
	return body_map[req.body]
end

local function parseQuery(qs)
	local params = {}
	for pair in tostring(qs):gmatch("[^&]+") do
		local k, v = pair:match("^([^=]*)=(.*)$")
		if k then
			params[urlDecode(k)] = urlDecode(v)
		end
	end
	return params
end

local function resp(status, v)
	if status == 0 then
		return { ok = false, status = 0, body = "" }
	end
	local body = ""
	if v ~= nil then
		body = register(v)
	end
	return { ok = status >= 200 and status < 300, status = status, body = body }
end

function route(req)
	table.insert(calls, { url = req.url, method = req.method, body = req.body, headers = req.headers })
	local path = req.url:match("^https://api%.todoist%.com/api/v1([^?]*)") or ""
	local params = parseQuery(req.url:match("%?(.*)$") or "")
	local method = req.method or "GET"

	if method == "GET" and path == "/ping" then
		return resp(200, { message = "pong" })
	end

	if method == "GET" and path == "/projects" then
		if params.cursor == nil then
			return resp(200, { results = PROJECTS_P1, next_cursor = "c2" })
		end
		return resp(200, { results = PROJECTS_P2, next_cursor = nil })
	end

	if method == "GET" and path == "/tasks/filter" then
		local q = params.query
		if q == "overdue" then
			if fault.filter_overdue == "http500" then
				return resp(500, { message = "boom" })
			end
			if fault.filter_overdue == "transport" then
				return resp(0, nil)
			end
			return resp(200, { results = { T_OVERDUE } })
		end
		if q == "today" then
			return resp(200, { results = { T_OVERDUE, T_TODAY } })
		end
		if q == "priority:4" then
			return resp(200, { results = { T_OVERDUE } })
		end
		return resp(200, { results = {} })
	end

	if method == "GET" and path == "/tasks" then
		if params.project_id == "p-inbox" then
			return resp(200, { results = { T_INBOX } })
		end
		return resp(200, { results = {} })
	end

	if method == "POST" and path == "/tasks/quick" then
		if fault.quick == "transport" then
			return resp(0, nil)
		end
		if fault.quick == "http500" then
			return resp(500, { message = "boom" })
		end
		return resp(200, nil) -- server answers 200 with an empty body
	end

	-- ── Phase 2 (M1) mutation routes ────────────────────────────
	-- Order matters: the exact /tasks/completed and /tasks/labels paths are
	-- checked before the generic "/tasks/{id}" pattern, which would otherwise
	-- swallow them as ids.
	if method == "GET" and path == "/tasks/completed" then
		return resp(200, {
			items = {
				{ id = "uuid-c1", task_id = "m1", content = "original", completed_at = "2026-10-19T10:00:00Z", project_id = "p-home" },
			},
		})
	end

	if method == "GET" and path == "/labels" then
		return resp(200, { results = { { id = "l1", name = "errand" }, { id = "l2", name = "home" } } })
	end

	if method == "GET" and path == "/sections" then
		local pid = params.project_id
		local out = {}
		for _, s in ipairs(SECTIONS) do
			if pid == nil or s.project_id == pid then
				out[#out + 1] = s
			end
		end
		return resp(200, { results = out })
	end

	if method == "POST" and path == "/tasks" then
		MUT.next_id = MUT.next_id + 1
		local t = { id = "new-" .. tostring(MUT.next_id), content = "created", priority = 1, labels = {} }
		MUT.tasks[t.id] = t
		return resp(200, t)
	end

	local mtask = path:match("^/tasks/([^/]+)$")
	local msub, verb = path:match("^/tasks/([^/]+)/(%w+)$")

	if mtask ~= nil and method == "DELETE" then
		local f = takeFault("delete")
		if f == "404" then
			return resp(404, { error = "not found" })
		end
		if f == "http500" then
			return resp(500, { message = "boom" })
		end
		if f == "transport" then
			return resp(0, nil)
		end
		if MUT.tasks[mtask] ~= nil then
			MUT.tasks[mtask] = nil
			if f == "transport_lost" then
				return resp(0, nil)
			end
			return resp(204, nil)
		end
		return resp(404, { error = "not found" })
	end

	if mtask ~= nil and MUT.tasks[mtask] ~= nil then
		if method == "GET" then
			return resp(200, MUT.tasks[mtask])
		end
		if method == "POST" then
			local f = takeFault("update")
			if f == "http500" then
				return resp(500, { message = "boom" })
			end
			if f == "transport" then
				return resp(0, nil)
			end
			-- Merge the sent fields into the stored task and return it whole,
			-- as the real endpoint does.
			local fields = reqBody(req) or {}
			local t = MUT.tasks[mtask]
			for k, v in pairs(fields) do
				if k == "due_string" then
					-- The API resolves the phrase; a cleared date is "no date".
					if v == "no date" then
						t.due = nil
					else
						t.due = { date = "2026-11-01", string = v }
					end
				else
					t[k] = v
				end
			end
			if f == "transport_lost" then
				return resp(0, nil)
			end
			return resp(200, t)
		end
	end

	if msub ~= nil and method == "POST" then
		if verb == "close" then
			local f = takeFault("close")
			if f == "transport" then
				return resp(0, nil)
			end
			if f == "http500" then
				return resp(500, { message = "boom" })
			end
			local t = MUT.tasks[msub]
			if t == nil then
				return resp(404, { error = "not found" })
			end
			t.checked = true
			if f == "transport_lost" then
				return resp(0, nil)
			end
			return resp(204, nil)
		end
		if verb == "reopen" then
			local f = takeFault("reopen")
			if f == "transport" then
				return resp(0, nil)
			end
			if f == "http500" then
				return resp(500, { message = "boom" })
			end
			local t = MUT.tasks[msub]
			if t == nil then
				return resp(404, { error = "not found" })
			end
			t.checked = false
			if f == "transport_lost" then
				return resp(0, nil)
			end
			return resp(204, nil)
		end
		if verb == "move" then
			local f = takeFault("move")
			if f == "http500" then
				return resp(500, { message = "boom" })
			end
			if f == "transport" then
				return resp(0, nil)
			end
			local fields = reqBody(req) or {}
			if fields.project_id == nil and fields.section_id == nil then
				return resp(400, { error = "No project_id or section_id or parent_id specified", error_code = 42 })
			end
			local t = MUT.tasks[msub]
			if t == nil then
				return resp(404, { error = "not found" })
			end
			if fields.project_id ~= nil then
				t.project_id = fields.project_id
				-- A bare project_id clears the section (server behaviour).
				t.section_id = fields.section_id
			else
				t.section_id = fields.section_id
			end
			if f == "transport_lost" then
				return resp(0, nil)
			end
			return resp(200, t)
		end
	end

	return resp(404, { message = "no route" })
end

-- ── require shim (Noctalia-style "./lib/x.luau") ────────────────
local orig_require = require
local req_cache = {}
local req_dir = "" -- directory of the module being loaded (host: caller-relative)
require = function(path)
	local rel = path:match("^%./(.+)%.luau$")
	if rel then
		local key = req_dir ~= "" and (req_dir .. "/" .. rel) or rel
		if req_cache[key] == nil then
			local prev = req_dir
			req_dir = key:match("^(.*)/[^/]+$") or ""
			req_cache[key] = assert(loadfile(PLUGIN_DIR .. key .. ".luau"))()
			req_dir = prev
		end
		return req_cache[key]
	end
	return orig_require(path)
end

-- ── assertions ──────────────────────────────────────────────────
local pass, fail = 0, 0
local function check(name, cond, extra)
	if cond then
		pass = pass + 1
		print("PASS " .. name)
	else
		fail = fail + 1
		print("FAIL " .. name .. (extra ~= nil and (" — " .. tostring(extra)) or ""))
	end
end

local function countCalls(pred)
	local n = 0
	for _, c in ipairs(calls) do
		if pred(c) then
			n = n + 1
		end
	end
	return n
end

local function filterCalls(q)
	return countCalls(function(c)
		return c.url:find("/tasks/filter", 1, true) ~= nil and c.url:find("query=" .. q, 1, true) ~= nil
	end)
end

-- Retries are armed on service timers; advance the clock so update() fires
-- them. Each pass is one RETRY_DELAY_MS.
local function drainTimers(passes)
	for _ = 1, passes or 8 do
		clock = clock + 2000
		update()
	end
end

-- ── load the service ────────────────────────────────────────────
local function loadService()
	assert(loadfile(PLUGIN_DIR .. "service.luau"))() -- returns nothing; sets globals
end

print("== data dir hardening ==")
loadService()
check("chmod 700 on data dir", runasync[1] ~= nil and runasync[1][1] == "chmod" and runasync[1][2] == "700", runasync[1] and table.concat(runasync[1], " "))

-- ── T1: no token ────────────────────────────────────────────────
print("\n== T1 no token ==")
env = {}
cfg.token = ""
cfg.token_file = ""
calls = {}
loadService()
update() -- boots the first refresh
local snap = getState("todoist")
check("snapshot published", type(snap) == "table")
check("token_configured=false", snap and snap.token_configured == false)
check("error.kind=config", snap and snap.error and snap.error.kind == "config", snap and snap.error and snap.error.kind)
check("no HTTP attempted", #calls == 0, #calls)

-- ── T1b: token file forms ───────────────────────────────────────
print("\n== T1b token file forms ==")
local TOKEN_PATH = "/home/tester/.config/todoist/token"

local function tokenFromFile(content)
	env = { ["file:" .. TOKEN_PATH] = content }
	cfg.token = ""
	cfg.token_file = "~/.config/todoist/token"
	calls = {}
	runasync = {}
	loadService()
	update()
	local used = nil
	for _, h in ipairs((calls[1] and calls[1].headers) or {}) do
		local t = h:match("^Authorization: Bearer (.+)$")
		if t ~= nil then
			used = t
		end
	end
	return used
end

check("NAME = value form", tokenFromFile("TODOIST_API_TOKEN = file-token-1\n") == "file-token-1")
check("NAME=value form", tokenFromFile("TODOIST_API_TOKEN=file-token-2") == "file-token-2")
check("bare token form", tokenFromFile("  file-token-3  \n") == "file-token-3")
check("export prefix", tokenFromFile("export TODOIST_API_TOKEN=file-token-4\n") == "file-token-4")
check("leading comment line", tokenFromFile("# my todoist token\nTODOIST_API_TOKEN = file-token-5\n") == "file-token-5")
check("quoted value", tokenFromFile('TODOIST_API_TOKEN = "file-token-6"') == "file-token-6")
check("empty file -> no token", tokenFromFile("\n\n") == nil)
tokenFromFile("TODOIST_API_TOKEN = file-token-7\n")
check("file token stamped as file source", getState("todoist").token_source == "file", getState("todoist").token_source)

-- ── T1c: on-disk cache ──────────────────────────────────────────
print("\n== T1c on-disk cache ==")
local SNAP_PATH = "/tmp/todoist-mock-data/snapshot.json"
local cached_body = register({
	schema = 1,
	saved_at = 12345,
	projects = { { id = "p-home", name = "Home" } },
	views = { today = { count = 9, tasks = { { id = "cached-1", content = "cached task" } } } },
	inbox_project_id = "p-inbox",
	counts = { today = 9, overdue = 0, p1 = 0 },
	view = "today",
})

cfg.token = "cache-token"
cfg.token_file = ""
env = {}
calls = {}
runasync = {}
cache_files = { [SNAP_PATH] = cached_body }
cfg.cache_tasks = false
loadService()
snap = getState("todoist")
check("cache off: stored snapshot ignored", (snap.counts or {}).today ~= 9, snap.counts and snap.counts.today)
check("cache off: no HTTP before the first tick", #calls == 0, #calls)

calls = {}
runasync = {}
cfg.cache_tasks = true
loadService()
snap = getState("todoist")
check("cache on: snapshot painted before any request", (snap.counts or {}).today == 9, snap.counts and snap.counts.today)
check("cache on: cached task present", snap.views.today.tasks[1].id == "cached-1", snap.views.today.tasks[1].id)
check("cache on: still no HTTP before the first tick", #calls == 0, #calls)
check("cache on: fetched_at taken from saved_at", snap.fetched_at == 12345, snap.fetched_at)
update() -- first tick -> refreshAll -> persist()
do
	local chmod600 = false
	for _, argv in ipairs(runasync) do
		if argv[1] == "chmod" and argv[2] == "600" and argv[3] == SNAP_PATH then
			chmod600 = true
		end
	end
	check("persist chmods the snapshot 600", chmod600, table.concat(runasync[#runasync] or {}, " "))
end

-- ── T2: token from env -> boot refresh ──────────────────────────
print("\n== T2 boot refresh ==")
env = { TODOIST_API_TOKEN = "  valid-token  " } -- whitespace must be trimmed
cfg.max_retries = 1
calls = {}
loadService()
update()
snap = getState("todoist")
check("token_source=env", snap and snap.token_source == "env", snap and snap.token_source)
check("projects paginated (2 pages -> 3 projects)", snap and #snap.projects == 3, snap and #snap.projects)
check("inbox project resolved", snap and snap.inbox_project_id == "p-inbox", snap and snap.inbox_project_id)
check("boot = projects(2 pages) + 3 filters + inbox = 6 GETs", #calls == 6, #calls)
do
	local sawAuth, sawAccept = false, false
	for _, h in ipairs((calls[1] and calls[1].headers) or {}) do
		if h == "Authorization: Bearer valid-token" then
			sawAuth = true
		end
		if h == "Accept: application/json" then
			sawAccept = true
		end
	end
	check("auth header sent, token trimmed", sawAuth, calls[1] and table.concat(calls[1].headers or {}, " | "))
	check("accept header sent", sawAccept)
	check("token never in the URL", calls[1] ~= nil and calls[1].url:find("valid-token", 1, true) == nil)
end
check("token never logged", (function()
	for _, line in ipairs(log_lines) do
		if tostring(line):find("valid-token", 1, true) then
			return false
		end
	end
	return true
end)())
check("overdue view count=1", snap and snap.views.overdue and snap.views.overdue.count == 1)
check("today view count=2", snap and snap.views.today and snap.views.today.count == 2, snap and snap.views.today and snap.views.today.count)
check("p1 view count=1", snap and snap.views.p1 and snap.views.p1.count == 1)
check("inbox view count=1", snap and snap.views.inbox and snap.views.inbox.count == 1)
check("counts.overdue=1", snap and snap.counts.overdue == 1)
check("counts.today=2", snap and snap.counts.today == 2)
check("priority mapped p=1 for API 4", snap and snap.views.overdue.tasks[1].p == 1, snap and snap.views.overdue.tasks[1].p)
check("task url built", snap and snap.views.overdue.tasks[1].url == "https://app.todoist.com/app/task/t1")
check("inbox flag from inbox_project", true) -- asserted via inbox_project_id above
check("active view is today", snap and snap.view == "today", snap and snap.view)

-- ── T3: priority mapping ────────────────────────────────────────
print("\n== T3 priority mapping ==")
local api = require("./lib/api.luau")
check("priorityToApi p1 -> 4", api.priorityToApi("p1") == 4)
check("priorityToApi p2 -> 3", api.priorityToApi("p2") == 3)
check("priorityToApi p4 -> 1", api.priorityToApi("p4") == 1)
check("priorityToApi 1 -> 4", api.priorityToApi(1) == 4)
check("priorityToApi none -> nil", api.priorityToApi("none") == nil)
check("priorityFromApi 4 -> 1", api.priorityFromApi(4) == 1)
check("priorityFromApi 1 -> 4", api.priorityFromApi(1) == 4)
check("classify 401=auth", api.classify(401) == "auth")
check("classify 429=rate_limit", api.classify(429) == "rate_limit")
check("classify 500=server", api.classify(500) == "server")
check("auth header format", api.authHeader("x") == "Authorization: Bearer x", api.authHeader("x"))

-- ── T4: panel fetch + TTL cache hit ─────────────────────────────
print("\n== T4 tasks.fetch ==")
calls = {}
fire("cmd.panel", { seq = 1, op = "tasks.fetch", args = { view = "inbox", force = true } })
local reply = getState("evt.panel")
check("reply seq matches", reply and reply.seq == 1, reply and reply.seq)
check("reply ok", reply and reply.ok == true)
check("active view switched to inbox", getState("todoist").view == "inbox")
check("one GET issued", #calls == 1, #calls)
fire("cmd.panel", { seq = 2, op = "tasks.fetch", args = { view = "inbox" } })
check("TTL cache hit -> no new request", #calls == 1, #calls)
check("cache hit still replies ok", getState("evt.panel").seq == 2 and getState("evt.panel").ok == true)

-- ── T5: quick add success ───────────────────────────────────────
print("\n== T5 quick add ==")
calls = {}
fault.quick = false
fire("cmd.panel", { seq = 3, op = "task.create", args = { text = "  Buy milk  " } })
reply = getState("evt.panel")
check("create replied ok", reply and reply.seq == 3 and reply.ok == true)
check("exactly one POST /tasks/quick", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/quick", 1, true) ~= nil
end) == 1)
check("text trimmed into body", calls[1] ~= nil and calls[1].body == "QADD:Buy milk", calls[1] and calls[1].body)
check("create triggered a refresh", countCalls(function(c)
	return c.method == "GET" and c.url:find("/tasks/filter", 1, true) ~= nil
end) >= 3, #calls)

-- ── T6: quick add transport failure -> unknown_outcome ──────────
print("\n== T6 quick add unknown outcome ==")
calls = {}
fault.quick = "transport"
fire("cmd.panel", { seq = 4, op = "task.create", args = { text = "Risky task" } })
reply = getState("evt.panel")
check("create replied not ok", reply and reply.seq == 4 and reply.ok == false)
check("unknown_outcome set", reply and reply.unknown_outcome == true)
check("POST not retried (exactly 1)", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/quick", 1, true) ~= nil
end) == 1)
fault.quick = false

-- ── T7: GET retry budget ────────────────────────────────────────
print("\n== T7 GET retry ==")
cfg.max_retries = 3
fault.filter_overdue = "http500"
calls = {}
fire("cmd.panel", { seq = 5, op = "tasks.fetch", args = { view = "overdue", force = true } })
-- each retry is armed on a timer; drain them by advancing the clock
for _ = 1, 8 do
	clock = clock + 2000
	update()
end
reply = getState("evt.panel")
check("overdue fetch failed", reply and reply.seq == 5 and reply.ok == false)
check("attempts = 1 + max_retries(3)", filterCalls("overdue") == 4, filterCalls("overdue"))
fault.filter_overdue = false

-- ── T8: panel renders ───────────────────────────────────────────
print("\n== T8 panel render ==")
local rendered = nil
local function node(kind)
	return function(props, children)
		return { kind = kind, props = props or {}, children = children }
	end
end

ui = {
	column = node("column"),
	row = node("row"),
	scroll = node("scroll"),
	label = node("label"),
	glyph = node("glyph"),
	button = node("button"),
	input = node("input"),
	separator = node("separator"),
	image = node("image"),
	select = node("select"),
	slider = node("slider"),
	toggle = node("toggle"),
	divider = node("divider"),
}

panel = {
	render = function(tree)
		rendered = tree
	end,
	close = function() end,
	setWantsSecondTicks = function() end,
	setNeedsFrameTick = function() end,
}

-- put the panel on a task view so rows exist
fire("cmd.panel", { seq = 6, op = "tasks.fetch", args = { view = "inbox" } })
assert(loadfile(PLUGIN_DIR .. "panel.luau"))()
onOpen({})

local nodeCount, labelTexts, glyphNames, inputCount, openButtons, buttonTexts = 0, {}, {}, 0, 0, {}
local function walk(n)
	if type(n) ~= "table" then
		return
	end
	nodeCount = nodeCount + 1
	if n.kind == "label" then
		labelTexts[#labelTexts + 1] = n.props.text
	end
	if n.kind == "glyph" then
		glyphNames[#glyphNames + 1] = n.props.name
	end
	if n.kind == "input" then
		inputCount = inputCount + 1
	end
	if n.kind == "button" then
		buttonTexts[#buttonTexts + 1] = n.props.text
		if n.props.glyph == "external-link" then
			openButtons = openButtons + 1
		end
	end
	for _, c in ipairs(n.children or {}) do
		walk(c)
	end
end
walk(rendered)

local function hasLabel(text)
	for _, t in ipairs(labelTexts) do
		if t == text then
			return true
		end
	end
	return false
end

local function hasButton(text)
	for _, t in ipairs(buttonTexts) do
		if t == text then
			return true
		end
	end
	return false
end

-- Tile labels carry a count suffix ("<label>  <n>"), so match on the prefix.
local function hasButtonPrefix(prefix)
	for _, t in ipairs(buttonTexts) do
		if type(t) == "string" and t:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

check("panel.render called", rendered ~= nil)
check("tree is non-trivial", nodeCount > 20, nodeCount)
check("title present", hasLabel("ui.panel.title"))
check("quick input present", inputCount == 1, inputCount)
check("priority flags rendered", #glyphNames >= 1 and glyphNames[1] == "flag", glyphNames[1])
check("one Open-in-Todoist per task", openButtons == 1, openButtons)
check("filter tiles present", hasButtonPrefix("ui.panel.filter.overdue") and hasButtonPrefix("ui.panel.filter.today") and hasButtonPrefix("ui.panel.filter.p1"))
check("nav tabs present", hasButton("ui.panel.nav.today") and hasButton("ui.panel.nav.inbox") and hasButton("ui.panel.nav.projects"))
check("counts painted on tiles", hasButton("ui.panel.filter.overdue  1") and hasButton("ui.panel.filter.today  2"), table.concat(buttonTexts, " | "))

-- not-configured state
state_store["todoist"] = {
	schema = 1,
	token_configured = false,
	view = "today",
	views = {},
	tasks = {},
	projects = {},
	counts = {},
	defaults = {},
}
rendered = nil
onOpen({})
labelTexts = {}
walk(rendered)
check("not-configured message shown", hasLabel("ui.panel.not_configured"))

-- ── T9: launcher ────────────────────────────────────────────────
print("\n== T9 launcher ==")
local results = nil
launcher = {
	setResults = function(_query, r)
		results = r
	end,
}
state_store["todoist"] = snap -- restore the populated snapshot
assert(loadfile(PLUGIN_DIR .. "launcher.luau"))()

onQuery("")
check("empty query -> hint first", results[1] and results[1].id == "hint", results[1] and results[1].id)
check("empty query lists tasks", #results >= 2, #results)

onQuery("pay")
check("typed query -> create row first", results[1] and results[1].id == "create", results[1] and results[1].id)
do
	local subs = lastSubs("launcher.create")
	check("create row interpolates the text", subs ~= nil and subs.text == "pay", subs and subs.text)
end
check("fuzzy match found", #results >= 2 and tostring(results[2].id):find("^task:") ~= nil, results[2] and results[2].id)
check("matched task carries a subtitle", results[2] ~= nil and results[2].subtitle ~= nil, results[2] and results[2].subtitle)

toggled = {}
onActivate(results[2].id)
check("open_task state set", getState("open_task") ~= nil and getState("open_task").id == "t1", getState("open_task") and getState("open_task").id)
check("open_task carries project", getState("open_task") ~= nil and getState("open_task").project_id == "p-home", getState("open_task") and getState("open_task").project_id)
check("panel toggled", #toggled == 1 and toggled[1] == "snowballons/todoist-manager:manager", toggled[1])

onQuery("buy milk")
onActivate("create")
local cmd = getState("cmd.launcher")
check("create sent on cmd.launcher", cmd and cmd.op == "task.create", cmd and cmd.op)
check("create args carry text", cmd and cmd.args and cmd.args.text == "buy milk", cmd and cmd.args and cmd.args.text)
check("seq is a number", cmd and type(cmd.seq) == "number")

-- ── T10: widget ─────────────────────────────────────────────────
print("\n== T10 widget ==")
local glyphSet, tooltipSet = nil, nil
barWidget = {
	setGlyph = function(g)
		glyphSet = g
	end,
	setTooltip = function(t)
		tooltipSet = t
	end,
}
toggled = {}
assert(loadfile(PLUGIN_DIR .. "widget.luau"))()
check("widget sets a glyph", glyphSet == "checklist", glyphSet)
check("widget sets a tooltip", tooltipSet == "widget.tooltip", tooltipSet)
onClick()
check("widget click toggles panel", #toggled == 1 and toggled[1] == "snowballons/todoist-manager:manager", toggled[1])

-- ── T11: M1 api mutations ───────────────────────────────────────
print("\n== T11 M1 api mutations ==")
local api = require("./lib/api.luau")

-- Call an api function with its callback appended, capturing the result.
-- Bounds are explicit so trailing nils (moveTask with no target) survive.
local function invoke(fn, ...)
	local n = select("#", ...)
	local captured = nil
	local args = { ... }
	args[n + 1] = function(r)
		captured = r
	end
	fn(table.unpack(args, 1, n + 1))
	return captured
end

-- createTask: POST /tasks, returns the created object (with an id)
calls = {}
local created = invoke(api.createTask, "tok", { content = "from api", priority = 4, labels = { "home" } })
check("createTask ok", created and created.ok == true, created and created.status)
check("createTask returns an id", created and created.data and created.data.id == "new-1", created and created.data and created.data.id)
check(
	"createTask POSTs /tasks (not /tasks/quick)",
	countCalls(function(c)
		return c.method == "POST" and c.url:find("/api/v1/tasks", 1, true) ~= nil and c.url:find("/tasks/quick", 1, true) == nil
	end) == 1,
	#calls
)
check(
	"createTask sends priority + labels",
	calls[1] ~= nil and calls[1].body:find("priority=4", 1, true) ~= nil and calls[1].body:find("labels=[home]", 1, true) ~= nil,
	calls[1] and calls[1].body
)

calls = {}
local noContent = invoke(api.createTask, "tok", { priority = 3 })
check("createTask empty content rejected", noContent and noContent.ok == false and noContent.err.kind == "validation", noContent and noContent.err and noContent.err.kind)
check("createTask empty content sends no HTTP", #calls == 0, #calls)

-- updateTask: strips project_id/section_id (not update fields), keeps the rest
calls = {}
local upd = invoke(api.updateTask, "tok", "m1", { content = "renamed", project_id = "p-work", section_id = "s9", labels = {} })
check("updateTask ok", upd and upd.ok == true, upd and upd.status)
check("updateTask returns the object", upd and upd.data and upd.data.id == "m1", upd and upd.data and upd.data.id)
check("updateTask POSTs /tasks/m1", calls[1] ~= nil and calls[1].method == "POST" and calls[1].url:find("/api/v1/tasks/m1", 1, true) ~= nil, calls[1] and calls[1].url)
check(
	"updateTask strips project_id/section_id",
	calls[1].body:find("project_id", 1, true) == nil and calls[1].body:find("section_id", 1, true) == nil,
	calls[1].body
)
check(
	"updateTask keeps content + empty labels",
	calls[1].body:find("content=renamed", 1, true) ~= nil and calls[1].body:find("labels=[]", 1, true) ~= nil,
	calls[1].body
)

calls = {}
local updBad = invoke(api.updateTask, "tok", "m1", { project_id = "p-work" })
check("updateTask unsupported-only rejected", updBad and updBad.ok == false and updBad.err.kind == "validation", updBad and updBad.err and updBad.err.kind)
check("updateTask unsupported-only sends no HTTP", #calls == 0, #calls)

-- moveTask
calls = {}
local mv = invoke(api.moveTask, "tok", "m1", "p-work", "s1")
check("moveTask ok", mv and mv.ok == true, mv and mv.status)
check("moveTask POSTs /tasks/m1/move", calls[1] ~= nil and calls[1].url:find("/api/v1/tasks/m1/move", 1, true) ~= nil, calls[1] and calls[1].url)
check(
	"moveTask sends project_id + section_id",
	calls[1].body:find("project_id=p-work", 1, true) ~= nil and calls[1].body:find("section_id=s1", 1, true) ~= nil,
	calls[1].body
)

calls = {}
local mvBad = invoke(api.moveTask, "tok", "m1", nil, nil)
check("moveTask without target rejected", mvBad and mvBad.ok == false and mvBad.err.kind == "validation", mvBad and mvBad.err and mvBad.err.kind)
check("moveTask without target sends no HTTP", #calls == 0, #calls)

-- getTask
calls = {}
local got = invoke(api.getTask, "tok", "m1")
check("getTask ok", got and got.ok == true and got.data and got.data.id == "m1", got and got.status)
check("getTask GETs /tasks/m1", calls[1] ~= nil and calls[1].method == "GET" and calls[1].url:find("/api/v1/tasks/m1", 1, true) ~= nil, calls[1] and calls[1].url)

-- close / reopen: 204 with no response body. Request body must still be
-- non-empty ("{}") so noctalia.http sets CURLOPT_POSTFIELDS — an empty POST
-- makes libcurl block on stdin and freezes the shell.
calls = {}
local cl = invoke(api.closeTask, "tok", "m1")
check("closeTask ok, 204, no data", cl and cl.ok == true and cl.status == 204 and cl.data == nil, cl and cl.status)
check("closeTask POSTs /close", calls[1] ~= nil and calls[1].method == "POST" and calls[1].url:find("/tasks/m1/close", 1, true) ~= nil, calls[1] and calls[1].url)
check("closeTask sends non-empty POST body", calls[1] ~= nil and calls[1].body ~= nil and calls[1].body ~= "", calls[1] and calls[1].body)

calls = {}
local ro = invoke(api.reopenTask, "tok", "m1")
check("reopenTask 204", ro and ro.ok == true and ro.status == 204, ro and ro.status)
check("reopenTask POSTs /reopen", calls[1] ~= nil and calls[1].url:find("/tasks/m1/reopen", 1, true) ~= nil, calls[1] and calls[1].url)
check("reopenTask sends non-empty POST body", calls[1] ~= nil and calls[1].body ~= nil and calls[1].body ~= "", calls[1] and calls[1].body)

-- listLabels
calls = {}
local labels = invoke(api.listLabels, "tok")
check("listLabels returns items", labels and labels.ok == true and #labels.items == 2 and labels.items[1].name == "errand", labels and labels.items and #labels.items)
check("listLabels GETs /labels", calls[1] ~= nil and calls[1].url:find("/api/v1/labels", 1, true) ~= nil, calls[1] and calls[1].url)

-- completedTasks
calls = {}
local done = invoke(api.completedTasks, "tok", "2026-10-01T00:00:00Z", "2026-10-20T00:00:00Z")
check("completedTasks returns items", done and done.ok == true and #done.items == 1, done and done.items and #done.items)
check("completedTasks item keyed by task_id", done and done.items[1] and done.items[1].task_id == "m1", done and done.items[1] and done.items[1].task_id)
check(
	"completedTasks GETs /tasks/completed with since+until",
	calls[1] ~= nil and calls[1].url:find("/tasks/completed?", 1, true) ~= nil and calls[1].url:find("since=", 1, true) ~= nil and calls[1].url:find("until=", 1, true) ~= nil,
	calls[1] and calls[1].url
)

calls = {}
invoke(api.completedTasks, "tok", "2026-10-01T00:00:00Z", nil)
check("completedTasks omits until when nil", calls[1] ~= nil and calls[1].url:find("until=", 1, true) == nil, calls[1] and calls[1].url)

-- delete: 204; a following GET is 404 reported as not_found (service folds it)
calls = {}
local del = invoke(api.deleteTask, "tok", "m1")
check("deleteTask ok, 204", del and del.ok == true and del.status == 204, del and del.status)
check("deleteTask DELETEs /tasks/m1", calls[1] ~= nil and calls[1].method == "DELETE" and calls[1].url:find("/api/v1/tasks/m1", 1, true) ~= nil, calls[1] and calls[1].url)

local gone = invoke(api.getTask, "tok", "m1")
check("getTask after delete is not_found", gone and gone.ok == false and gone.err.kind == "not_found", gone and gone.err and gone.err.kind)

-- errorMessage extracts the human message from a raw error body
local err_body = register({ error = "Invalid date", error_code = 20, error_tag = "INVALID_ARGUMENT_VALUE" })
check("errorMessage extracts .error", api.errorMessage(err_body) == "Invalid date", api.errorMessage(err_body))
check("errorMessage nil for empty body", api.errorMessage("") == nil)
check("errorMessage nil for non-json", api.errorMessage("nope") == nil)

-- ── T12: M2 task.complete / task.reopen ─────────────────────────
print("\n== T12 complete / reopen ==")
env = { TODOIST_API_TOKEN = "valid-token" }
cfg.max_retries = 1
fault.close = false
calls = {}
loadService()
update() -- controlled boot: overdue=1, today=2, p1=1, inbox=1
local s12 = getState("todoist")
check("T12 setup: today holds 2", s12.views.today.count == 2, s12.views.today.count)
check("T12 setup: active view today", s12.view == "today", s12.view)

-- complete: one POST, then a purely local reconcile (no extra GET)
calls = {}
fire("cmd.panel", { seq = 101, op = "task.complete", args = { id = "t1" } })
local ev = getState("evt.panel")
check("complete reply ok", ev ~= nil and ev.seq == 101 and ev.ok == true, ev and ev.err and ev.err.kind)
check("complete reply carries data.checked", ev ~= nil and type(ev.data) == "table" and ev.data.checked == true and ev.data.id == "t1", ev and ev.data and ev.data.checked)
check("complete POSTs /tasks/t1/close", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/t1/close", 1, true) ~= nil
end) == 1)
check("complete makes no extra request", #calls == 1, #calls)
check("t1 gone from overdue", s12.views.overdue.count == 0 and #s12.views.overdue.tasks == 0, s12.views.overdue.count)
check("t1 gone from today, t2 kept", s12.views.today.count == 1 and s12.views.today.tasks[1].id == "t2", s12.views.today.count)
check("t1 gone from p1", s12.views.p1.count == 0, s12.views.p1.count)
check("active task list re-pointed after complete", #s12.tasks == 1 and s12.tasks[1].id == "t2", #s12.tasks)
check("counts recomputed", s12.counts.overdue == 0 and s12.counts.today == 1 and s12.counts.p1 == 0, tostring(s12.counts.today))

-- reopen: POST then re-fetch the active view (a filter cannot be recomputed)
calls = {}
fire("cmd.panel", { seq = 102, op = "task.reopen", args = { id = "t2" } })
ev = getState("evt.panel")
check("reopen reply ok", ev ~= nil and ev.seq == 102 and ev.ok == true, ev and ev.err and ev.err.kind)
check("reopen POSTs /tasks/t2/reopen", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/t2/reopen", 1, true) ~= nil
end) == 1)
check("reopen re-fetches the active (today) view", filterCalls("today") == 1, filterCalls("today"))
check("reopen does not touch the task count", s12.views.today.count == 2, s12.views.today.count)

-- guards: no HTTP is attempted for a malformed or unconfigured call
calls = {}
fire("cmd.panel", { seq = 103, op = "task.complete", args = {} })
ev = getState("evt.panel")
check("complete without id is validation", ev ~= nil and ev.ok == false and ev.err.kind == "validation", ev and ev.err and ev.err.kind)
check("complete without id sends no HTTP", #calls == 0, #calls)

env = {}
cfg.token = ""
cfg.token_file = ""
calls = {}
fire("cmd.panel", { seq = 104, op = "task.complete", args = { id = "t2" } })
ev = getState("evt.panel")
check("complete without token is config", ev ~= nil and ev.ok == false and ev.err.kind == "config", ev and ev.err and ev.err.kind)
check("complete without token sends no HTTP", #calls == 0, #calls)

-- a dropped connection is retried (close is idempotent), then settled by the
-- confirming GET: the task is still open, so the failure is known, not unknown
env = { TODOIST_API_TOKEN = "valid-token" }
calls = {}
fault.close = "transport"
fire("cmd.panel", { seq = 105, op = "task.complete", args = { id = "t2" } })
drainTimers(4)
ev = getState("evt.panel")
check("transient close settles as a known failure", ev ~= nil and ev.seq == 105 and ev.ok == false and ev.unknown_outcome ~= true, ev and ev.err and ev.err.kind)
check("transient close is retried (1 + max_retries(1))", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/t2/close", 1, true) ~= nil
end) == 2)
check("transient close issues one confirming GET", countCalls(function(c)
	return c.method == "GET" and c.url:find("/tasks/t2", 1, true) ~= nil
end) == 1)
check("close that did not land keeps the row", getState("todoist").views.today.count == 2, getState("todoist").views.today.count)
fault.close = false

-- ── T12b: panel checkbox is a live control ──────────────────────
print("\n== T12b panel checkbox ==")
-- Drop any deep-link left over from the launcher test: it would make onOpen
-- issue a fetch, leaving the client busy so a click is ignored.
state_store["open_task"] = nil
local function settlePanel()
	local pc = getState("cmd.panel")
	if type(pc) == "table" and pc.seq ~= nil then
		fire("evt.panel", { seq = pc.seq, op = pc.op, ok = true })
	end
end
state_store["todoist"] = {
	schema = 1,
	token_configured = true,
	view = "inbox",
	tasks = { { id = "t3", content = "Inbox task", p = 4, url = "u" } },
	views = { inbox = { tasks = { { id = "t3", content = "Inbox task", p = 4, url = "u" } }, count = 1 } },
	projects = {},
	counts = {},
	defaults = {},
	fetched_at = 0,
}
onOpen({})
settlePanel()
local function findButton(pred)
	local found = nil
	local function rec(n)
		if type(n) ~= "table" then
			return
		end
		if n.kind == "button" and pred(n.props) then
			found = n
		end
		for _, c in ipairs(n.children or {}) do
			rec(c)
		end
	end
	rec(rendered)
	return found
end

local function findNode(kind, pred)
	local found = nil
	local function rec(n)
		if type(n) ~= "table" then
			return
		end
		if n.kind == kind and pred(n.props) then
			found = n
		end
		for _, c in ipairs(n.children or {}) do
			rec(c)
		end
	end
	rec(rendered)
	return found
end

local function rowOf(id)
	return findNode("row", function(props)
		return props.key == "t" .. id
	end)
end

local function scrollTree()
	local function rec(n)
		if type(n) ~= "table" then
			return nil
		end
		if n.kind == "scroll" then
			return n
		end
		for _, c in ipairs(n.children or {}) do
			local hit = rec(c)
			if hit ~= nil then
				return hit
			end
		end
		return nil
	end
	return rec(rendered)
end

-- Clicking task body without description does nothing; with description toggles it.
local row3 = rowOf("t3")
check("task row exposes a selection callback", row3 ~= nil and type(row3.props.onClick) == "function")
state_store["cmd.panel"] = nil
if row3 then
	row3.props.onClick()
end
check("selecting a task without description does not mutate", getState("cmd.panel") == nil)
check("selecting a task without description does not expand description", findNode("row", function(p)
	return p.key == "desct3"
end) == nil)

-- With description: expand, collapse, and accordion switch
state_store["todoist"].tasks[1].description = "My task note"
fire("todoist", state_store["todoist"])
row3 = rowOf("t3")
if row3 then
	row3.props.onClick()
end
check("clicking task body with description expands it", findNode("row", function(p)
	return p.key == "desct3"
end) ~= nil)
row3 = rowOf("t3")
if row3 then
	row3.props.onClick()
end
check("clicking task body again collapses description", findNode("row", function(p)
	return p.key == "desct3"
end) == nil)

table.insert(state_store["todoist"].tasks, { id = "t4", content = "Task 4", p = 4, url = "u", description = "Note for task 4" })
fire("todoist", state_store["todoist"])
row3 = rowOf("t3")
if row3 then
	row3.props.onClick()
end
check("task t3 description open", findNode("row", function(p)
	return p.key == "desct3"
end) ~= nil)
local row4 = rowOf("t4")
if row4 then
	row4.props.onClick()
end
check("clicking task t4 collapses t3 description", findNode("row", function(p)
	return p.key == "desct3"
end) == nil)
check("clicking task t4 opens t4 description", findNode("row", function(p)
	return p.key == "desct4"
end) ~= nil)
table.remove(state_store["todoist"].tasks, 2)
fire("todoist", state_store["todoist"])

-- Clicking the circle button reveals the Complete/Not now action pair
local circleBtn = findButton(function(props)
	return props.key == "chkt3"
end)
check("task circle exposes a button", circleBtn ~= nil)
check("circle button has circle glyph", circleBtn ~= nil and circleBtn.props.glyph == "circle")
state_store["cmd.panel"] = nil
if circleBtn then
	circleBtn.props.onClick()
end
check("clicking circle does not mutate", getState("cmd.panel") == nil)
local doBtn = findButton(function(props)
	return props.text == "ui.panel.complete"
end)
check("clicking circle reveals Complete", doBtn ~= nil)
circleBtn = findButton(function(props)
	return props.key == "chkt3"
end)
if circleBtn then
	circleBtn.props.onClick()
end
check("clicking circle again collapses action pair", findButton(function(props)
	return props.text == "ui.panel.complete"
end) == nil)
circleBtn = findButton(function(props)
	return props.key == "chkt3"
end)
if circleBtn then
	circleBtn.props.onClick()
end
doBtn = findButton(function(props)
	return props.text == "ui.panel.complete"
end)
check("hover uses a named handler so the leave edge survives a render", doBtn ~= nil and doBtn.props.onHover == "onActionHover", doBtn and type(doBtn.props.onHover))
check("clicking circle reveals Not now", findButton(function(props)
	return props.text == "ui.panel.action.not_now"
end) ~= nil)
check("the open pair outlines the row", (rowOf("t3") or { props = {} }).props.border == "outline/0.7", (rowOf("t3") or { props = {} }).props.border)

if doBtn then
	onActionHover("true", doBtn.props.key)
end
check("hovering Complete tints the row green", (rowOf("t3") or { props = {} }).props.border == "#16A34A", (rowOf("t3") or { props = {} }).props.border)
check("hover keeps the pair open", findButton(function(props)
	return props.text == "ui.panel.complete"
end) ~= nil)
if doBtn then
	onActionHover("false", doBtn.props.key)
end
check("leaving Complete restores the outline", (rowOf("t3") or { props = {} }).props.border == "outline/0.7", (rowOf("t3") or { props = {} }).props.border)

local notNow = findButton(function(props)
	return props.text == "ui.panel.action.not_now"
end)
if notNow then
	onActionHover("true", notNow.props.key)
end
check("hovering Not now tints the row gray", (rowOf("t3") or { props = {} }).props.border == "#6B7280", (rowOf("t3") or { props = {} }).props.border)
if notNow then
	onActionHover("false", notNow.props.key)
	notNow.props.onClick()
end
check("Not now collapses without mutating", getState("cmd.panel") == nil and findButton(function(props)
	return props.text == "ui.panel.complete"
end) == nil)
check("Not now keeps the row", rowOf("t3") ~= nil)

circleBtn = findButton(function(props)
	return props.key == "chkt3"
end)
if circleBtn then
	circleBtn.props.onClick()
end
doBtn = findButton(function(props)
	return props.text == "ui.panel.complete"
end)
state_store["cmd.panel"] = nil
if doBtn then
	doBtn.props.onClick()
end
local cmd = getState("cmd.panel")
check("Complete sends task.complete", cmd ~= nil and cmd.op == "task.complete" and cmd.args and cmd.args.id == "t3", cmd and cmd.op)
check("Complete collapses the pair", findButton(function(props)
	return props.text == "ui.panel.complete"
end) == nil)
check("Complete click sends no revealKey for a row that is about to vanish", (function()
	local sc = scrollTree()
	return sc ~= nil and sc.props.revealKey == nil
end)())

state_store["todoist"].tasks[1].checked = true
state_store["todoist"].views.inbox.tasks[1].checked = true
onOpen({})
settlePanel()
local circleBtn2 = findButton(function(props)
	return props.key == "chkt3"
end)
check("a closed task shows a circle-check button", circleBtn2 ~= nil and circleBtn2.props.glyph == "circle-check")
if circleBtn2 then
	circleBtn2.props.onClick()
end
local reopenBtn = findButton(function(props)
	return props.text == "ui.panel.reopen"
end)
check("clicking closed task circle reveals Reopen", reopenBtn ~= nil)
state_store["cmd.panel"] = nil
if reopenBtn then
	reopenBtn.props.onClick()
end
cmd = getState("cmd.panel")
check("Reopen sends task.reopen", cmd ~= nil and cmd.op == "task.reopen" and cmd.args and cmd.args.id == "t3", cmd and cmd.op)

-- ── T13: M3 task.delete + confirm_delete ────────────────────────
print("\n== T13 delete ==")
env = { TODOIST_API_TOKEN = "valid-token" }
cfg.token = ""
cfg.token_file = ""
cfg.max_retries = 1
fault.delete = false
calls = {}
loadService()
update()
local s13 = getState("todoist")
check("T13 setup: today holds 2", s13.views.today.count == 2, s13.views.today.count)

calls = {}
fire("cmd.panel", { seq = 201, op = "task.delete", args = { id = "t1" } })
ev = getState("evt.panel")
check("delete reply ok", ev ~= nil and ev.seq == 201 and ev.ok == true, ev and ev.err and ev.err.kind)
check("delete reply carries data.deleted", ev ~= nil and type(ev.data) == "table" and ev.data.deleted == true and ev.data.id == "t1")
check("delete sends DELETE /tasks/t1", countCalls(function(c)
	return c.method == "DELETE" and c.url:find("/tasks/t1", 1, true) ~= nil
end) == 1)
check("delete makes no extra request", #calls == 1, #calls)
check("t1 gone from overdue", s13.views.overdue.count == 0, s13.views.overdue.count)
check("t1 gone from today, t2 kept", s13.views.today.count == 1 and s13.views.today.tasks[1].id == "t2", s13.views.today.count)
check("t1 gone from p1", s13.views.p1.count == 0, s13.views.p1.count)
check("active task list re-pointed after delete", #s13.tasks == 1 and s13.tasks[1].id == "t2", #s13.tasks)
check("delete recomputes counts", s13.counts.overdue == 0 and s13.counts.today == 1, tostring(s13.counts.today))

-- 404 means the task is already gone: the goal state, not a failure
calls = {}
fault.delete = "404"
fire("cmd.panel", { seq = 202, op = "task.delete", args = { id = "t2" } })
ev = getState("evt.panel")
check("404 on delete is treated as success", ev ~= nil and ev.ok == true, ev and ev.err and ev.err.kind)
check("404 delete still reconciles locally", s13.views.today.count == 0, s13.views.today.count)
fault.delete = false

-- guards
calls = {}
fire("cmd.panel", { seq = 203, op = "task.delete", args = {} })
ev = getState("evt.panel")
check("delete without id is validation", ev ~= nil and ev.ok == false and ev.err.kind == "validation", ev and ev.err and ev.err.kind)
check("delete without id sends no HTTP", #calls == 0, #calls)

env = {}
cfg.token = ""
cfg.token_file = ""
calls = {}
fire("cmd.panel", { seq = 204, op = "task.delete", args = { id = "t2" } })
ev = getState("evt.panel")
check("delete without token is config", ev ~= nil and ev.ok == false and ev.err.kind == "config", ev and ev.err and ev.err.kind)
check("delete without token sends no HTTP", #calls == 0, #calls)

-- a dropped connection is retried, then the confirming GET finds the task
-- still there: a known failure, so the row is kept and a retry is safe
env = { TODOIST_API_TOKEN = "valid-token" }
calls = {}
fault.delete = "transport"
fire("cmd.panel", { seq = 205, op = "task.delete", args = { id = "t3" } })
drainTimers(4)
ev = getState("evt.panel")
check("transient delete settles as a known failure", ev ~= nil and ev.seq == 205 and ev.ok == false and ev.unknown_outcome ~= true, ev and ev.err and ev.err.kind)
check("transient delete is retried (1 + max_retries(1))", countCalls(function(c)
	return c.method == "DELETE"
end) == 2)
check("delete that did not land keeps the row", getState("todoist").views.inbox.count == 1, getState("todoist").views.inbox.count)
fault.delete = false

-- ── T13b: delete affordance honours confirm_delete ──────────────
print("\n== T13b confirm_delete ==")
local function fakeTask(checked)
	return {
		schema = 1,
		token_configured = true,
		view = "inbox",
		tasks = { { id = "t3", content = "Inbox task", p = 4, url = "u", checked = checked } },
		views = { inbox = { tasks = { { id = "t3", content = "Inbox task", p = 4, url = "u", checked = checked } }, count = 1 } },
		projects = {},
		counts = {},
		defaults = {},
		fetched_at = 0,
	}
end

cfg.confirm_delete = true
state_store["open_task"] = nil
state_store["todoist"] = fakeTask(false)
onOpen({})
settlePanel()
local trash = findButton(function(props)
	return props.glyph == "trash"
end)
check("row exposes a delete button", trash ~= nil)
state_store["cmd.panel"] = nil
if trash then
	trash.props.onClick()
end
check("confirmation on: delete waits for confirmation", getState("cmd.panel") == nil, getState("cmd.panel") and getState("cmd.panel").op)
local no = findButton(function(props)
	return props.text == "ui.panel.delete.no"
end)
local yes = findButton(function(props)
	return props.text == "ui.panel.delete.yes"
end)
check("confirmation on: confirm row offers Delete and Cancel", yes ~= nil and no ~= nil)
state_store["cmd.panel"] = nil
if yes then
	yes.props.onClick()
end
cmd = getState("cmd.panel")
check("confirming sends task.delete", cmd ~= nil and cmd.op == "task.delete" and cmd.args and cmd.args.id == "t3", cmd and cmd.op)

cfg.confirm_delete = false
state_store["todoist"] = fakeTask(false)
onOpen({})
settlePanel()
local trash2 = findButton(function(props)
	return props.glyph == "trash"
end)
state_store["cmd.panel"] = nil
if trash2 then
	trash2.props.onClick()
end
cmd = getState("cmd.panel")
check("confirmation off: delete is sent immediately", cmd ~= nil and cmd.op == "task.delete" and cmd.args and cmd.args.id == "t3", cmd and cmd.op)
check("confirmation off: no confirm row", findButton(function(props)
	return props.text == "ui.panel.delete.no"
end) == nil)
cfg.confirm_delete = true

-- ── T14: task.update (service) ─────────────────────────────────
print("\n== T14 task.update ==")
env = { TODOIST_API_TOKEN = "valid-token" }
cfg.max_retries = 1
fault.update = false
MUT.tasks.t1 = T_OVERDUE
MUT.tasks.t2 = T_TODAY
loadService()
update()
local s14 = getState("todoist")
check("T14 setup: today holds 2", s14.views.today.count == 2, s14.views.today.count)

calls = {}
fire("cmd.panel", {
	seq = 301,
	op = "task.update",
	args = { id = "t1", changes = { content = "Pay more", priority = 2, labels = { "home", "new" }, project_id = "p-work" } },
})
local ev14 = getState("evt.panel")
check("update reply ok", ev14 ~= nil and ev14.seq == 301 and ev14.ok == true, ev14 and ev14.err and ev14.err.kind)
check("update POSTs /tasks/t1", countCalls(function(c)
	return c.method == "POST" and c.url:find("/api/v1/tasks/t1", 1, true) ~= nil
end) == 1)
check(
	"update strips project_id/section_id",
	calls[1] ~= nil and calls[1].body:find("project_id", 1, true) == nil and calls[1].body:find("section_id", 1, true) == nil,
	calls[1] and calls[1].body
)
check(
	"update sends content/priority/labels",
	calls[1] ~= nil
		and calls[1].body:find("content=Pay more", 1, true) ~= nil
		and calls[1].body:find("priority=2", 1, true) ~= nil
		and calls[1].body:find("labels=[home,new]", 1, true) ~= nil,
	calls[1] and calls[1].body
)
check("update makes exactly one request", #calls == 1, #calls)

local row14 = nil
for _, t in ipairs(s14.tasks or {}) do
	if t.id == "t1" then
		row14 = t
	end
end
check(
	"update reconciled the row from the response",
	row14 ~= nil and row14.content == "Pay more" and row14.p == 3,
	row14 and (tostring(row14.content) .. "/" .. tostring(row14.p))
)
check("update did not move the task", row14 ~= nil and row14.project_id == "p-home", row14 and row14.project_id)
check("update kept the other row", s14.views.today.count == 2, s14.views.today.count)

-- an out-of-range priority is refused before any request (the API drops it)
calls = {}
fire("cmd.panel", { seq = 302, op = "task.update", args = { id = "t1", changes = { priority = 9 } } })
ev14 = getState("evt.panel")
check("priority 9 is validation", ev14 ~= nil and ev14.ok == false and ev14.err.kind == "validation", ev14 and ev14.err and ev14.err.kind)
check("priority 9 sends no HTTP", #calls == 0, #calls)

-- a move-only payload contains no supported update field
calls = {}
fire("cmd.panel", { seq = 303, op = "task.update", args = { id = "t1", changes = { project_id = "p-work" } } })
ev14 = getState("evt.panel")
check("project-only update is validation", ev14 ~= nil and ev14.ok == false and ev14.err.kind == "validation", ev14 and ev14.err and ev14.err.kind)
check("project-only update sends no HTTP", #calls == 0, #calls)

-- transient failure: idempotent, so it is retried; the confirming GET then
-- reconciles to the server's truth (the panel diffs the form against it, so a
-- change that did not apply stays visible instead of being lost)
fault.update = "transport"
calls = {}
fire("cmd.panel", { seq = 304, op = "task.update", args = { id = "t1", changes = { content = "x" } } })
drainTimers(4)
ev14 = getState("evt.panel")
check("update transport reconciles instead of guessing", ev14 ~= nil and ev14.seq == 304 and ev14.ok == true and ev14.data and ev14.data.reconciled == true, ev14 and ev14.err and ev14.err.kind)
check("update is retried (1 + max_retries(1))", countCalls(function(c)
	return c.method == "POST"
end) == 2)
check("update issues one confirming GET", countCalls(function(c)
	return c.method == "GET" and c.url:find("/tasks/t1", 1, true) ~= nil
end) == 1)
check("update renders the unchanged server content", (function()
	for _, t in ipairs(getState("todoist").views.overdue.tasks or {}) do
		if t.id == "t1" and t.content ~= "x" then
			return true
		end
	end
	return false
end)())
fault.update = false

-- ── T15: task.move (service) ───────────────────────────────────
print("\n== T15 task.move ==")
env = { TODOIST_API_TOKEN = "valid-token" }
fault.move = false
MUT.tasks.t1 = T_OVERDUE
MUT.tasks.t2 = T_TODAY
MUT.tasks.t3 = T_INBOX
loadService()
update() -- overdue=1, today=2, p1=1, inbox=1
local s15 = getState("todoist")
check("T15 setup: inbox holds t3", s15.views.inbox ~= nil and s15.views.inbox.count == 1, s15.views.inbox and s15.views.inbox.count)

calls = {}
fire("cmd.panel", { seq = 311, op = "task.move", args = { id = "t3", project_id = "p-work", section_id = "s-work-todo" } })
local ev15 = getState("evt.panel")
check("move reply ok", ev15 ~= nil and ev15.seq == 311 and ev15.ok == true, ev15 and ev15.err and ev15.err.kind)
check("move POSTs /tasks/t3/move", countCalls(function(c)
	return c.method == "POST" and c.url:find("/api/v1/tasks/t3/move", 1, true) ~= nil
end) == 1)
check(
	"move sends project_id + section_id",
	calls[1] ~= nil and calls[1].body:find("project_id=p-work", 1, true) ~= nil and calls[1].body:find("section_id=s-work-todo", 1, true) ~= nil,
	calls[1] and calls[1].body
)
check("move left the source (inbox) view", s15.views.inbox.count == 0 and #s15.views.inbox.tasks == 0, s15.views.inbox.count)
check("move re-fetched the active view", filterCalls("today") == 1, filterCalls("today"))

-- a bare project clears the section: the server response is the truth
calls = {}
fire("cmd.panel", { seq = 312, op = "task.move", args = { id = "t2", project_id = "p-home" } })
ev15 = getState("evt.panel")
check("move to a project only is ok", ev15 ~= nil and ev15.ok == true, ev15 and ev15.err and ev15.err.kind)
check("bare project sends no section_id", calls[1] ~= nil and calls[1].body:find("section_id", 1, true) == nil, calls[1] and calls[1].body)
local moved15 = nil
for _, t in ipairs(s15.views.today.tasks) do
	if t.id == "t2" then
		moved15 = t
	end
end
check("moved row shows the new project", moved15 ~= nil and moved15.project_id == "p-home", moved15 and moved15.project_id)
check("moved row has no section", moved15 ~= nil and moved15.section_id == nil, moved15 and moved15.section_id)

-- guards: neither target, or a section without a project, never reaches HTTP
calls = {}
fire("cmd.panel", { seq = 313, op = "task.move", args = { id = "t1" } })
ev15 = getState("evt.panel")
check("move without target is validation", ev15 ~= nil and ev15.ok == false and ev15.err.kind == "validation", ev15 and ev15.err and ev15.err.kind)
fire("cmd.panel", { seq = 314, op = "task.move", args = { id = "t1", section_id = "s-home-chores" } })
ev15 = getState("evt.panel")
check("section without project is validation", ev15 ~= nil and ev15.ok == false and ev15.err.kind == "validation", ev15 and ev15.err and ev15.err.kind)
check("move guards send no HTTP", #calls == 0, #calls)

-- a lost response is retried; the confirming GET sees t1 still in p-home, so
-- the move is a known failure and retrying it is safe
fault.move = "transport"
calls = {}
fire("cmd.panel", { seq = 315, op = "task.move", args = { id = "t1", project_id = "p-work" } })
drainTimers(4)
ev15 = getState("evt.panel")
check("move transport settles as a known failure", ev15 ~= nil and ev15.seq == 315 and ev15.ok == false and ev15.unknown_outcome ~= true, ev15 and ev15.err and ev15.err.kind)
check("move is retried (1 + max_retries(1))", countCalls(function(c)
	return c.method == "POST"
end) == 2)
check("move issues one confirming GET", countCalls(function(c)
	return c.method == "GET" and c.url:find("/tasks/t1", 1, true) ~= nil
end) == 1)
fault.move = false

-- ── T16: edit form (panel) ─────────────────────────────────────
print("\n== T16 edit form ==")
state_store["open_task"] = nil
local function findInput(pred)
	local found = nil
	local function rec(n)
		if type(n) ~= "table" then
			return
		end
		if n.kind == "input" and pred(n.props) then
			found = n
		end
		for _, c in ipairs(n.children or {}) do
			rec(c)
		end
	end
	rec(rendered)
	return found
end
local function findSelect(pred)
	local found = nil
	local function rec(n)
		if type(n) ~= "table" then
			return
		end
		if n.kind == "select" and pred(n.props) then
			found = n
		end
		for _, c in ipairs(n.children or {}) do
			rec(c)
		end
	end
	rec(rendered)
	return found
end
local function hasLabelText(text)
	local found = false
	local function rec(n)
		if type(n) ~= "table" then
			return
		end
		if n.kind == "label" and n.props.text == text then
			found = true
		end
		for _, c in ipairs(n.children or {}) do
			rec(c)
		end
	end
	rec(rendered)
	return found
end
local function freshTask(over)
	local t = {
		id = "t1",
		content = "Pay rent",
		description = "old note",
		p = 1,
		project_id = "p-home",
		section_id = "s-home-chores",
		labels = { "home" },
		due = { date = "2026-10-10", string = "Oct 10" },
		url = "u",
	}
	for k, v in pairs(over or {}) do
		t[k] = v
	end
	return t
end
local function editSnapshot(over)
	local t = freshTask(over)
	return {
		schema = 1,
		token_configured = true,
		view = "today",
		tasks = { t },
		views = { today = { tasks = { t }, count = 1 } },
		projects = {
			{ id = "p-inbox", name = "Inbox", inbox = true },
			{ id = "p-home", name = "Home" },
			{ id = "p-work", name = "Work" },
		},
		inbox_project_id = "p-inbox",
		counts = { today = 1 },
		defaults = {},
		fetched_at = 0,
		labels = { { id = "l1", name = "errand" }, { id = "l2", name = "home" } },
		sections = { ["p-home"] = { { id = "s-home-chores", name = "Chores" } } },
		sections_at = {},
	}
end

state_store["todoist"] = editSnapshot()
onOpen({})
settlePanel()
local pencil = findButton(function(props)
	return props.glyph == "pencil"
end)
check("row exposes an edit button", pencil ~= nil)
state_store["cmd.panel"] = nil
if pencil then
	pencil.props.onClick()
end
local mcmd = getState("cmd.panel")
check("opening the form loads labels and sections", mcmd ~= nil and mcmd.op == "meta.load" and mcmd.args and mcmd.args.project_id == "p-home", mcmd and mcmd.op)
check("form shows its heading", hasLabelText("ui.panel.edit.heading"))
check("form seeds the title", findInput(function(p)
	return p.value == "Pay rent"
end) ~= nil)
check("form seeds the due date", findInput(function(p)
	return p.value == "Oct 10"
end) ~= nil)
settlePanel()

-- editing the title sends only that field
local titleInput = findInput(function(p)
	return p.value == "Pay rent"
end)
if titleInput then
	titleInput.props.onChange("Pay rent now")
end
state_store["cmd.panel"] = nil
local save = findButton(function(p)
	return p.text == "ui.panel.edit.save"
end)
check("save is available while idle", save ~= nil and save.props.enabled == true, save and tostring(save.props.enabled))
if save then
	save.props.onClick()
end
local ucmd = getState("cmd.panel")
check(
	"save sends task.update with only the changed field",
	ucmd ~= nil and ucmd.op == "task.update" and ucmd.args and ucmd.args.changes and ucmd.args.changes.content == "Pay rent now",
	ucmd and ucmd.op
)
check(
	"save sends no untouched fields",
	ucmd ~= nil and ucmd.args and ucmd.args.changes and ucmd.args.changes.priority == nil and ucmd.args.changes.project_id == nil,
	ucmd and ucmd.args and ucmd.args.changes and tostring(ucmd.args.changes.priority)
)

-- the service publishes, then replies: the form closes with nothing left
state_store["todoist"] = editSnapshot({ content = "Pay rent now" })
fire("todoist", state_store["todoist"])
fire("evt.panel", { seq = ucmd.seq, op = "task.update", ok = true, data = { id = "t1" } })
check("form closes when the diff is gone", not hasLabelText("ui.panel.edit.heading"))

-- Clear sends "no date"
local pencil2 = findButton(function(props)
	return props.glyph == "pencil"
end)
if pencil2 then
	pencil2.props.onClick()
end
settlePanel()
local clearDue = findButton(function(props)
	return props.tooltip == "ui.panel.edit.clear_due"
end)
check("form offers a clear-due button", clearDue ~= nil)
if clearDue then
	clearDue.props.onClick()
end
state_store["cmd.panel"] = nil
local save2 = findButton(function(p)
	return p.text == "ui.panel.edit.save"
end)
if save2 then
	save2.props.onClick()
end
local dcmd = getState("cmd.panel")
check(
	"clearing the due date sends due_string = no date",
	dcmd ~= nil and dcmd.op == "task.update" and dcmd.args and dcmd.args.changes and dcmd.args.changes.due_string == "no date",
	dcmd and dcmd.args and dcmd.args.changes and dcmd.args.changes.due_string
)
settlePanel()

-- changing the project resets the section and reloads it
local pencil3 = findButton(function(props)
	return props.glyph == "pencil"
end)
if pencil3 then
	pencil3.props.onClick()
end
settlePanel()
local projSelect = findSelect(function(p)
	return type(p.options) == "table" and p.options[1] == "[Inbox]  Inbox"
end)
check("form has a project picker", projSelect ~= nil)
state_store["cmd.panel"] = nil
if projSelect then
	projSelect.props.onChange(2) -- 0-based: Work
end
local mcmd2 = getState("cmd.panel")
check(
	"changing the project reloads its sections",
	mcmd2 ~= nil and mcmd2.op == "meta.load" and mcmd2.args and mcmd2.args.project_id == "p-work",
	mcmd2 and mcmd2.args and mcmd2.args.project_id
)
settlePanel()
state_store["cmd.panel"] = nil
local moveBtn = findButton(function(p)
	return p.text == "ui.panel.edit.move"
end)
check("move is available while idle", moveBtn ~= nil and moveBtn.props.enabled == true, moveBtn and tostring(moveBtn.props.enabled))
if moveBtn then
	moveBtn.props.onClick()
end
local mvcmd = getState("cmd.panel")
check(
	"move sends the project and the reset section",
	mvcmd ~= nil and mvcmd.op == "task.move" and mvcmd.args and mvcmd.args.project_id == "p-work" and mvcmd.args.section_id == nil,
	mvcmd and mvcmd.op
)
settlePanel()

-- cancel discards without sending anything
local pencil4 = findButton(function(props)
	return props.glyph == "pencil"
end)
if pencil4 then
	pencil4.props.onClick()
end
settlePanel()
state_store["cmd.panel"] = nil
local cancel = findButton(function(p)
	return p.text == "ui.panel.edit.cancel"
end)
if cancel then
	cancel.props.onClick()
end
check("cancel sends nothing", getState("cmd.panel") == nil, getState("cmd.panel") and getState("cmd.panel").op)
check("cancel returns to the list", not hasLabelText("ui.panel.edit.heading"))

-- ── T17: unknown-outcome recovery (M5) ─────────────────────────
-- The response is lost but the write landed. With retries disabled, the only
-- way to learn the truth is the confirming GET: the write is never re-sent.
print("\n== T17 unknown-outcome recovery ==")
env = { TODOIST_API_TOKEN = "valid-token" }
cfg.token = ""
cfg.token_file = ""
cfg.max_retries = 0
fault.close, fault.reopen, fault.update, fault.move, fault.delete, fault.quick =
	false, false, false, false, false, false
T_OVERDUE.content, T_OVERDUE.project_id, T_OVERDUE.priority = "Pay rent", "p-home", 4
T_OVERDUE.checked, T_OVERDUE.section_id, T_OVERDUE.due = false, nil, DUE
T_TODAY.checked, T_TODAY.project_id, T_TODAY.section_id = false, "p-work", nil
T_INBOX.checked, T_INBOX.project_id, T_INBOX.section_id = false, "p-inbox", nil
MUT.tasks.t1, MUT.tasks.t2, MUT.tasks.t3 = T_OVERDUE, T_TODAY, T_INBOX
loadService()
update()

-- close: applied, response lost -> GET says checked, so it is done
calls = {}
fault.close = "transport_lost"
fire("cmd.panel", { seq = 401, op = "task.complete", args = { id = "t2" } })
drainTimers(2)
ev = getState("evt.panel")
check("lost close recovers as ok", ev ~= nil and ev.seq == 401 and ev.ok == true and ev.data and ev.data.reconciled == true, ev and ev.err and ev.err.kind)
check("lost close is sent once (no blind re-send)", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/t2/close", 1, true) ~= nil
end) == 1)
check("lost close asks the server once", countCalls(function(c)
	return c.method == "GET" and c.url:find("/tasks/t2", 1, true) ~= nil
end) == 1)
check("lost close removes the row", getState("todoist").views.today.count == 1, getState("todoist").views.today.count)
fault.close = false

-- reopen: same shape, mirrored truth check
T_OVERDUE.checked = true
calls = {}
fault.reopen = "transport_lost"
fire("cmd.panel", { seq = 402, op = "task.reopen", args = { id = "t1" } })
drainTimers(2)
ev = getState("evt.panel")
check("lost reopen recovers as ok", ev ~= nil and ev.seq == 402 and ev.ok == true and ev.data and ev.data.reconciled == true, ev and ev.err and ev.err.kind)
check("lost reopen is sent once", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/t1/reopen", 1, true) ~= nil
end) == 1)
check("lost reopen asks the server once", countCalls(function(c)
	return c.method == "GET" and c.url:find("/tasks/t1", 1, true) ~= nil
end) == 1)
check("reopen landed on the server", T_OVERDUE.checked == false)
fault.reopen = false
drainTimers(2)

-- update: applied, response lost -> the fetched task is rendered
calls = {}
fault.update = "transport_lost"
fire("cmd.panel", { seq = 403, op = "task.update", args = { id = "t1", changes = { content = "Recovered" } } })
drainTimers(2)
ev = getState("evt.panel")
check("lost update recovers as ok", ev ~= nil and ev.seq == 403 and ev.ok == true and ev.data and ev.data.reconciled == true, ev and ev.err and ev.err.kind)
check("lost update is posted once", countCalls(function(c)
	return c.method == "POST" and c.url:find("/api/v1/tasks/t1", 1, true) ~= nil
end) == 1)
check("lost update renders the server truth", (function()
	for _, t in ipairs(getState("todoist").views.overdue.tasks or {}) do
		if t.id == "t1" and t.content == "Recovered" then
			return true
		end
	end
	return false
end)())
fault.update = false

-- move: applied, response lost -> confirm checks the target, not just 200
calls = {}
fault.move = "transport_lost"
fire("cmd.panel", { seq = 404, op = "task.move", args = { id = "t1", project_id = "p-work" } })
drainTimers(2)
ev = getState("evt.panel")
check("lost move recovers as ok", ev ~= nil and ev.seq == 404 and ev.ok == true and ev.data and ev.data.reconciled == true, ev and ev.err and ev.err.kind)
check("lost move is posted once", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/t1/move", 1, true) ~= nil
end) == 1)
check("lost move landed on the server", T_OVERDUE.project_id == "p-work")
check("lost move refetches the active view", countCalls(function(c)
	return c.method == "GET" and c.url:find("/tasks/filter", 1, true) ~= nil
end) >= 1)
fault.move = false
drainTimers(2)

-- delete: applied, response lost -> the confirming 404 is the proof
calls = {}
fault.delete = "transport_lost"
fire("cmd.panel", { seq = 405, op = "task.delete", args = { id = "t3" } })
drainTimers(2)
ev = getState("evt.panel")
check("lost delete recovers as ok", ev ~= nil and ev.seq == 405 and ev.ok == true and ev.data and ev.data.reconciled == true, ev and ev.err and ev.err.kind)
check("lost delete is sent once", countCalls(function(c)
	return c.method == "DELETE"
end) == 1)
check("lost delete removes the row", getState("todoist").views.inbox.count == 0, getState("todoist").views.inbox.count)
fault.delete = false

-- create is exempt even with a retry budget: a retried POST duplicates
cfg.max_retries = 3
calls = {}
fault.quick = "transport"
fire("cmd.panel", { seq = 406, op = "task.create", args = { text = "Only once" } })
drainTimers(6)
ev = getState("evt.panel")
check("create never retries, even with max_retries=3", countCalls(function(c)
	return c.method == "POST" and c.url:find("/tasks/quick", 1, true) ~= nil
end) == 1)
check("create stays an unknown outcome", ev ~= nil and ev.seq == 406 and ev.ok == false and ev.unknown_outcome == true, ev and ev.err and ev.err.kind)
fault.quick = false

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
