--!nonstrict
-- lib/api.luau (Phase 1)
-- Thin wrapper around noctalia.http for the Todoist API v1.
-- Base URL: https://api.todoist.com/api/v1
-- Auth: "Authorization: Bearer <token>" (docs show uppercase Bearer).
-- Response handling decides by HTTP status, NOT by res.ok alone: the runtime
-- only documents { ok, status, body } and does not define ok for non-2xx.
local M = {}

M.BASE = "https://api.todoist.com/api/v1"

-- Server maximum per page for the paginated endpoints.
M.LIMIT = 200
-- Hard stop after this many pages so a cursor loop cannot spin forever.
M.MAX_PAGES = 25

-- ── priority mapping ────────────────────────────────────────────
-- The API numbers priority 1..4 where 4 is "very urgent" (= client p1)
-- and 1 is natural (client p4). The UI works in client terms (p1..p4).
-- Accepts the setting form ("p1".."p4", "none") and the client number (1..4).
function M.priorityToApi(p)
	if type(p) == "string" then
		p = p:match("^p([1-4])$") or p
	end
	p = tonumber(p)
	if p == 1 then
		return 4
	elseif p == 2 then
		return 3
	elseif p == 3 then
		return 2
	elseif p == 4 then
		return 1
	end
	return nil
end

function M.priorityFromApi(n)
	n = tonumber(n)
	if n == 4 then
		return 1
	elseif n == 3 then
		return 2
	elseif n == 2 then
		return 3
	elseif n == 1 then
		return 4
	end
	return nil
end

-- ── error classification (plan §1.3) ────────────────────────────
function M.classify(status)
	if status == 401 then
		return "auth"
	elseif status == 403 then
		return "forbidden"
	elseif status == 404 then
		return "not_found"
	elseif status == 429 then
		return "rate_limit"
	elseif status == 400 or status == 422 then
		return "validation"
	elseif status >= 500 and status < 600 then
		return "server"
	end
	return "server"
end

-- Transient kinds are the only ones safe to retry, and only for reads.
function M.isTransient(kind)
	return kind == "network" or kind == "server" or kind == "timeout"
		or kind == "rate_limit"
end

-- Build the Authorization header value. Split out for unit tests.
-- Scheme casing is significant: Bearer -> 200, bearer -> 403 (verified live).
function M.authHeader(token)
	return "Authorization: Bearer " .. token
end

-- ── query string ────────────────────────────────────────────────
-- params: key -> value (string/number/bool). nil/"false-ish" values are
-- skipped so callers can pass optional filters unconditionally.
function M.buildQuery(params, cursor)
	local parts = {}
	if type(params) == "table" then
		for k, v in pairs(params) do
			if v ~= nil and v ~= "" then
				parts[#parts + 1] = noctalia.string.urlEncode(tostring(k))
					.. "="
					.. noctalia.string.urlEncode(tostring(v))
			end
		end
	end
	parts[#parts + 1] = "limit=" .. tostring(M.LIMIT)
	if cursor ~= nil and cursor ~= "" then
		parts[#parts + 1] = "cursor=" .. noctalia.string.urlEncode(tostring(cursor))
	end
	return "?" .. table.concat(parts, "&")
end

-- ── single request ──────────────────────────────────────────────
-- cb({ ok, status, data, err = { kind, status, message } })
-- body may be nil (GET / DELETE without payload).
--
-- POST with an empty body is special: noctalia.http's curl path sets
-- CURLOPT_POST but only sets CURLOPT_POSTFIELDS when the body is non-empty.
-- Without POSTFIELDS, libcurl reads the request body from stdin and blocks
-- the shell's main thread — the Complete/Reopen freeze. Body-less POSTs
-- (close/reopen) therefore send "{}"; Todoist accepts it (live-verified).
function M.request(token, method, path, body, cb)
	local headers = {
		M.authHeader(token),
		"Accept: application/json",
	}
	local payload = ""
	if body ~= nil then
		local encoded, err = noctalia.json.encode(body)
		if not encoded then
			cb({ ok = false, status = 0, err = { kind = "validation", status = 0, message = tostring(err) } })
			return
		end
		payload = encoded
		table.insert(headers, "Content-Type: application/json")
	elseif method == "POST" then
		payload = "{}"
		table.insert(headers, "Content-Type: application/json")
	end

	-- The runtime may both return false and still invoke the callback, so a
	-- single guard keeps cb from firing twice for one request.
	local settled = false
	local function finish(result)
		if settled then
			return
		end
		settled = true
		cb(result)
	end

	local accepted = noctalia.http({
		url = M.BASE .. path,
		method = method,
		body = payload,
		headers = headers,
		follow_redirects = false,
	}, function(res)
		local status = (res and res.status) or 0
		if status >= 200 and status < 300 then
			local data = nil
			if status ~= 204 and res.body ~= nil and res.body ~= "" then
				local decoded = noctalia.json.decode(res.body)
				if decoded == nil then
					finish({ ok = false, status = status, err = { kind = "server", status = status, message = "bad json" } })
					return
				end
				data = decoded
			end
			finish({ ok = true, status = status, data = data })
		elseif status == 0 then
			-- noctalia.http returns status 0 when the transfer never happened,
			-- but for a POST that is an unknown outcome, not a clean failure.
			finish({ ok = false, status = 0, err = { kind = "network", status = 0, message = "transport" } })
		else
			finish({ ok = false, status = status, err = { kind = M.classify(status), status = status, message = res.body } })
		end
	end)

	if not accepted then
		finish({ ok = false, status = 0, err = { kind = "network", status = 0, message = "request not accepted" } })
	end
end

-- ── paginated read ──────────────────────────────────────────────
-- Follows next_cursor until exhausted. cb({ ok, items, pages, warning, err }).
-- On a mid-stream failure the caller still receives the pages already read
-- (ok=false) so the UI can show partial data.
local function getAll(token, path, params, cb)
	local items = {}
	local seen = {}
	local pages = 0

	local function step(cursor)
		pages = pages + 1
		if pages > M.MAX_PAGES then
			cb({ ok = true, items = items, pages = pages, warning = "pagination limit reached" })
			return
		end
		M.request(token, "GET", path .. M.buildQuery(params, cursor), nil, function(r)
			if not r.ok then
				cb({ ok = false, items = items, pages = pages, err = r.err })
				return
			end
			local data = r.data or {}
			-- list endpoints use "results"; completed views use "items".
			local page = data.results or data.items
			if type(page) ~= "table" then
				page = {}
			end
			for _, it in ipairs(page) do
				items[#items + 1] = it
			end
			local nextc = data.next_cursor
			if type(nextc) == "string" and nextc ~= "" and not seen[nextc] then
				seen[nextc] = true
				step(nextc)
			else
				cb({ ok = true, items = items, pages = pages })
			end
		end)
	end

	step(nil)
end

M.getAll = getAll

-- ── endpoints used in Phase 1 ───────────────────────────────────
function M.listProjects(token, cb)
	getAll(token, "/projects", {}, cb)
end

function M.listSections(token, projectId, cb)
	local params = {}
	if projectId ~= nil and projectId ~= "" then
		params.project_id = projectId
	end
	getAll(token, "/sections", params, cb)
end

-- params: project_id, section_id, parent_id, label, ids
function M.listTasks(token, params, cb)
	getAll(token, "/tasks", params or {}, cb)
end

-- Todoist filter syntax, e.g. "overdue", "today", "priority:4".
function M.filterTasks(token, query, cb)
	getAll(token, "/tasks/filter", { query = query }, cb)
end

-- Quick Add: natural-language capture parsed by Todoist itself.
-- The server answers 200 with an empty body, so success carries no task id.
function M.quickAdd(token, text, note, cb)
	local body = { text = text }
	if note ~= nil and note ~= "" then
		body.note = note
	end
	M.request(token, "POST", "/tasks/quick", body, cb)
end

-- Lightweight credential probe: one page of projects.
function M.ping(token, cb)
	M.request(token, "GET", "/projects" .. M.buildQuery({}, nil), nil, cb)
end

-- ── Phase 2: mutations (contract verified live 2026-10-19) ──────
-- update / move / close / reopen / delete are idempotent server-side:
-- repeating the exact call is safe, so the service may retry them once
-- after a transport failure. Only the two create endpoints are not.
--
-- POST /tasks/{id} accepts content, description, priority, due_string,
-- due_date, due_datetime and labels — NOT project_id or section_id. Sending
-- either yields 400 error_code 42 "At least one of supported fields should
-- be set and non-empty" (verified live); moving is its own endpoint. Strip
-- them here so a caller mistake cannot reach the API.
local UPDATE_FIELDS = {
	content = true,
	description = true,
	priority = true,
	due_string = true,
	due_date = true,
	due_datetime = true,
	labels = true,
}

-- Keep only allow-listed keys that are PRESENT in `changes`. Presence, not
-- truthiness: `labels = {}` clears labels and `due_string = "no date"` clears
-- a due date, so an empty/false-ish value must still survive the filter.
local function pick(changes, allow)
	local out = {}
	local n = 0
	if type(changes) == "table" then
		for k in pairs(allow) do
			if changes[k] ~= nil then
				out[k] = changes[k]
				n = n + 1
			end
		end
	end
	return out, n
end

local function invalid(message)
	return { ok = false, status = 0, err = { kind = "validation", status = 0, message = message } }
end

-- Structured create. Unlike quickAdd this returns the new task (with its id).
-- fields: content (required), project_id, section_id, priority, description,
-- due_string, labels.
function M.createTask(token, fields, cb)
	local body, n = pick(fields, {
		content = true,
		project_id = true,
		section_id = true,
		priority = true,
		description = true,
		due_string = true,
		labels = true,
	})
	if n == 0 or type(body.content) ~= "string" or body.content == "" then
		cb(invalid("createTask requires a non-empty content"))
		return
	end
	M.request(token, "POST", "/tasks", body, cb)
end

function M.getTask(token, id, cb)
	M.request(token, "GET", "/tasks/" .. tostring(id), nil, cb)
end

-- Partial update; returns the full updated task object (200, not 204).
function M.updateTask(token, id, changes, cb)
	local body, n = pick(changes, UPDATE_FIELDS)
	if n == 0 then
		cb(invalid("updateTask: no supported fields (content, description, priority, due_string, due_date, due_datetime, labels)"))
		return
	end
	M.request(token, "POST", "/tasks/" .. tostring(id), body, cb)
end

-- Move to a project and/or section; at least one is required ({} is a 400).
-- A bare project_id CLEARS the current section (server behaviour) — pass both
-- to land inside a section. section_id = nil is not a valid way to clear it.
function M.moveTask(token, id, projectId, sectionId, cb)
	local body = {}
	if projectId ~= nil and projectId ~= "" then
		body.project_id = projectId
	end
	if sectionId ~= nil and sectionId ~= "" then
		body.section_id = sectionId
	end
	if body.project_id == nil and body.section_id == nil then
		cb(invalid("moveTask requires a project_id or section_id"))
		return
	end
	M.request(token, "POST", "/tasks/" .. tostring(id) .. "/move", body, cb)
end

-- Close / reopen answer 204 with no body. A closed task stays readable:
-- GET /tasks/{id} returns it with checked=true and completed_at set.
function M.closeTask(token, id, cb)
	M.request(token, "POST", "/tasks/" .. tostring(id) .. "/close", nil, cb)
end

function M.reopenTask(token, id, cb)
	M.request(token, "POST", "/tasks/" .. tostring(id) .. "/reopen", nil, cb)
end

-- Delete answers 204; a later GET /tasks/{id} is 404. This wrapper does NOT
-- fold 404 into success — the service decides that, because for delete a 404
-- means the task is already gone (success for the user's intent).
function M.deleteTask(token, id, cb)
	M.request(token, "DELETE", "/tasks/" .. tostring(id), nil, cb)
end

-- ── Phase 2: extra reads ────────────────────────────────────────
function M.listLabels(token, cb)
	getAll(token, "/labels", {}, cb)
end

-- Completed tasks in [sinceTs, untilTs). Match results on task_id — the item's
-- own "id" is an unrelated UUID. Single request: pagination shape here is
-- unverified, so only since/until are sent (as in the live probe).
-- ("until" is a Lua keyword, hence sinceTs/untilTs.)
function M.completedTasks(token, sinceTs, untilTs, cb)
	local q = "?since=" .. noctalia.string.urlEncode(tostring(sinceTs))
	if untilTs ~= nil and untilTs ~= "" then
		q = q .. "&until=" .. noctalia.string.urlEncode(tostring(untilTs))
	end
	M.request(token, "GET", "/tasks/completed" .. q, nil, function(r)
		if not r.ok then
			cb(r)
			return
		end
		local items = r.data and r.data.items
		if type(items) ~= "table" then
			items = {}
		end
		cb({ ok = true, status = r.status, items = items })
	end)
end

-- Pull the human-readable message out of an error body. `body` is the raw
-- string api.request puts in err.message. Returns nil when there is none.
function M.errorMessage(body)
	if type(body) ~= "string" or body == "" then
		return nil
	end
	local decoded = noctalia.json.decode(body)
	if type(decoded) == "table" and type(decoded.error) == "string" and decoded.error ~= "" then
		return decoded.error
	end
	return nil
end

return M
