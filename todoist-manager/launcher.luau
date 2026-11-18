--!nonstrict
-- launcher.luau (Phase 1)
-- "/td" provider: your cached tasks (fuzzy search) plus a Quick Add row that
-- sends the raw text to Todoist. Never touches the network on a keystroke -
-- search runs over the snapshot the service already published.
local dates = require("./lib/dates.luau")

local MAX_MATCHES = 6

-- state.watch() only fires on later changes, so seed from the latest published
-- snapshot: the provider is usually loaded long after the service's last
-- publish, and without this the first search would see no tasks at all.
local snap = noctalia.state.get("todoist") or {}
if type(snap) ~= "table" then
	snap = {}
end
local byId = {} -- result id -> task, so onActivate does not need a lookup
local lastQuery = ""

local function sendCmd(op, args)
	-- svc_seq.launcher is the service's high-water mark: reading it back and
	-- adding one keeps the seq strictly increasing across senders.
	local svcs = noctalia.state.get("svc_seq")
	local next_ = 1
	if type(svcs) == "table" and type(svcs.launcher) == "number" then
		next_ = svcs.launcher + 1
	end
	noctalia.state.set("cmd.launcher", { seq = next_, op = op, args = args })
end

local function errText(err)
	local kind = (type(err) == "table" and err.kind) or "server"
	local key = "err." .. tostring(kind)
	local s = noctalia.tr(key)
	if s == key then
		return noctalia.tr("err.server")
	end
	return s
end

local function projectName(id)
	for _, p in ipairs(snap.projects or {}) do
		if p.id == id then
			return p.name
		end
	end
	return nil
end

-- Every task the service has cached, de-duplicated across views.
local function candidates()
	local seen = {}
	local out = {}
	for _, v in pairs(snap.views or {}) do
		for _, t in ipairs(v.tasks or {}) do
			if not seen[t.id] then
				seen[t.id] = true
				out[#out + 1] = t
			end
		end
	end
	return out
end

local function subtitleFor(t)
	local parts = {}
	local pname = projectName(t.project_id)
	if pname then
		parts[#parts + 1] = pname
	end
	local due = dates.formatDue(t.due)
	if due then
		parts[#parts + 1] = due.text
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "  ·  ")
end

function onQuery(text)
	text = text or ""
	byId = {}
	lastQuery = text
	local query = noctalia.string.trim(text)
	local results = {}

	if query == "" then
		results[#results + 1] = {
			id = "hint",
			title = noctalia.tr("launcher.hint"),
			glyph = "checklist",
			score = 100,
		}
		local list = candidates()
		for i = 1, math.min(#list, MAX_MATCHES) do
			local t = list[i]
			local rid = "task:" .. tostring(t.id)
			byId[rid] = t
			results[#results + 1] = {
				id = rid,
				title = t.content,
				subtitle = subtitleFor(t),
				glyph = "circle",
				score = 50 - i,
			}
		end
		launcher.setResults(text, results)
		return
	end

	results[#results + 1] = {
		id = "create",
		title = noctalia.tr("launcher.create", { text = query }),
		glyph = "plus",
		score = 1000,
	}

	local scored = {}
	for _, t in ipairs(candidates()) do
		local score = noctalia.fuzzyScore(query, t.content)
		if score ~= nil then
			scored[#scored + 1] = { t = t, score = score }
		end
	end
	table.sort(scored, function(a, b)
		return a.score > b.score
	end)
	for i = 1, math.min(#scored, MAX_MATCHES) do
		local t = scored[i].t
		local rid = "task:" .. tostring(t.id)
		byId[rid] = t
		results[#results + 1] = {
			id = rid,
			title = t.content,
			subtitle = subtitleFor(t),
			glyph = "circle",
			score = scored[i].score,
		}
	end

	launcher.setResults(text, results)
end

function onActivate(id)
	if id == "create" then
		-- The text to create is the current launcher input; onQuery stored it.
		local text = lastQuery
		if type(text) ~= "string" or noctalia.string.trim(text) == "" then
			return
		end
		sendCmd("task.create", { text = noctalia.string.trim(text) })
		return
	end
	local t = byId[id]
	if t then
		noctalia.state.set("open_task", { id = t.id, project_id = t.project_id })
		noctalia.togglePanel("snowballons/todoist-manager:manager")
	end
end

noctalia.state.watch("todoist", function(msg)
	if type(msg) == "table" then
		snap = msg
	end
end)

noctalia.state.watch("evt.launcher", function(msg)
	if type(msg) ~= "table" or msg.op ~= "task.create" then
		return
	end
	if msg.ok then
		noctalia.notify(noctalia.tr("notify.created"))
	elseif msg.unknown_outcome then
		noctalia.notifyError(noctalia.tr("notify.unknown"), noctalia.tr("err.unknown_outcome"))
	else
		noctalia.notifyError(noctalia.tr("notify.failed"), errText(msg.err))
	end
end)
