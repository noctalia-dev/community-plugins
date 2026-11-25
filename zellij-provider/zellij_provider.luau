--!nonstrict

-- zellij provider: a launcher provider that lists running zellij sessions
-- (and, optionally, layout files) and attaches to them.
--
-- This is a zellij fork of dunarand/tmux-provider; see the README for the
-- command-level differences.

local tinsert = table.insert
local tsort = table.sort
local sformat = string.format

-- Per-query in-flight state: both sessions and layouts must land before we
-- render, since either can be requested for the same query.
local sessionsCache
local layoutsCache
local lastQuery = ""
local pendingQuery: string? = nil
local pendingSessions = false
local pendingLayouts = false

local function zellijInstalled(): boolean
	return noctalia.commandExists("zellij")
end

local function shellQuote(s: string): string
	return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

-- Parses `zellij list-sessions --no-formatting` into a list of { name, exited }.
-- Each line is the session name, its age, and an optional state marker:
--   "work [Created 3s ago] "
--   "scratch pad [Created 2days 1h ago] (EXITED - attach to resurrect)"
-- Session names may contain spaces, so the name is everything before the
-- " [Created " suffix rather than the first whitespace-separated field.
local function parseSessionList(output: string)
	local sessions = {}
	for line in output:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" then
			local name = trimmed:match("^(.-)%s+%[Created ") or trimmed
			if name ~= "" then
				tinsert(sessions, {
					name = name,
					exited = trimmed:find("(EXITED", 1, true) ~= nil,
				})
			end
		end
	end
	return sessions
end

-- `zellij setup --check` prints the directories zellij actually resolved, so a
-- custom ZELLIJ_CONFIG_DIR or XDG_CONFIG_HOME keeps working without
-- reimplementing zellij's path rules here.
local function parseLayoutDir(output: string): string?
	for line in output:gmatch("[^\r\n]+") do
		local dir = line:match('^%[LAYOUT DIR%]:%s*"(.-)"')
		if dir and dir ~= "" then
			return dir
		end
	end
	return nil
end

-- Layout names are the file stems zellij looks up with `--layout <name>`.
local function listLayouts(layoutDir: string)
	local layouts = {}
	local entries = noctalia.listDir(layoutDir)
	if not entries then
		-- No layouts directory is a normal setup, not an error.
		return layouts
	end

	for _, entry in ipairs(entries) do
		local name = entry:match("([^/]+)%.kdl$")
		if name and name ~= "" then
			tinsert(layouts, { name = name })
		end
	end

	tsort(layouts, function(a, b)
		return a.name < b.name
	end)

	return layouts
end

-- Builds the combined result list: running sessions first, then layouts that
-- are not already running as a session of the same name.
local function buildResults(query: string)
	local results = {}
	local showKillActions = noctalia.getConfig("show_kill_actions") == true
	local runningNames = {}

	if sessionsCache then
		for _, session in ipairs(sessionsCache) do
			runningNames[session.name] = true

			local score: number?
			if query == "" then
				score = 0
			else
				score = noctalia.fuzzyScore(query, session.name)
			end

			if score ~= nil then
				tinsert(results, {
					id = "attach:" .. session.name,
					title = session.name,
					subtitle = session.exited and noctalia.tr("session_exited")
						or noctalia.tr("session_running"),
					glyph = "terminal-2",
					score = score,
				})

				if showKillActions then
					-- Same match as the attach row, ranked just below it.
					tinsert(results, {
						id = "kill:" .. session.name,
						title = noctalia.tr("session_kill") .. ": " .. session.name,
						subtitle = session.exited and noctalia.tr("session_delete_subtitle")
							or noctalia.tr("session_kill_subtitle"),
						glyph = "trash",
						score = score - 0.001,
					})
				end
			end
		end
	end

	if layoutsCache then
		for _, layout in ipairs(layoutsCache) do
			if not runningNames[layout.name] then
				local score: number?
				if query == "" then
					score = -1 -- rank below live sessions when query is empty
				else
					score = noctalia.fuzzyScore(query, layout.name)
				end

				if score ~= nil then
					tinsert(results, {
						id = "layout:" .. layout.name,
						title = layout.name,
						subtitle = noctalia.tr("layout_config"),
						glyph = "file-text",
						score = score,
					})
				end
			end
		end
	end

	tsort(results, function(a, b)
		return (a.score or 0) > (b.score or 0)
	end)

	return results
end

local function showResults(query: string)
	if not zellijInstalled() then
		launcher.setResults(query, {
			{
				id = "",
				title = noctalia.tr("zellij_not_found"),
				subtitle = noctalia.tr("zellij_not_found_subtitle"),
				glyph = "alert-triangle",
			},
		})
		return
	end

	local results = buildResults(query)

	if #results == 0 and query ~= "" then
		-- zellij creates a session on attach when one does not exist, so an
		-- unmatched query can double as a "start this session" entry.
		tinsert(results, {
			id = "create:" .. query,
			title = noctalia.tr("session_create") .. ": " .. query,
			subtitle = noctalia.tr("session_create_subtitle"),
			glyph = "plus",
			score = -3,
		})
	end

	if #results > 0 then
		launcher.setResults(query, results)
		return
	end

	launcher.setResults(query, {
		{
			id = "",
			title = noctalia.tr("no_sessions_found"),
			subtitle = noctalia.tr("no_sessions_subtitle"),
			glyph = "loader",
		},
	})
end

-- Renders once every in-flight fetch for this query has landed.
local function maybeShowResults(query: string)
	if pendingQuery ~= query then
		return -- a newer query superseded this one
	end
	if pendingSessions or pendingLayouts then
		return -- still waiting on one of the sources
	end
	showResults(query)
end

local function refreshSessions(query: string)
	lastQuery = query
	pendingQuery = query

	if zellijInstalled() then
		pendingSessions = true
		noctalia.runAsync("zellij list-sessions --no-formatting", function(result)
			if result.exitCode == 0 then
				sessionsCache = parseSessionList(result.stdout)
			else
				-- zellij exits non-zero ("No active zellij sessions found.", on
				-- stderr) when no session server is running. That is the normal
				-- empty state, so any non-zero exit is treated as "no sessions"
				-- and only unexpected stderr is logged for diagnostics.
				local stderr = result.stderr or ""
				if
					stderr ~= ""
					and not stderr:find("No active zellij sessions found", 1, true)
				then
					noctalia.log("zellij-provider: zellij list-sessions: " .. stderr)
				end
				sessionsCache = {}
			end
			pendingSessions = false
			maybeShowResults(query)
		end)
	else
		sessionsCache = {}
		pendingSessions = false
	end

	local useLayouts: boolean = noctalia.getConfig("use_layouts") or false
	if useLayouts and zellijInstalled() then
		pendingLayouts = true
		noctalia.runAsync("zellij setup --check", function(result)
			local layoutDir = result.exitCode == 0 and parseLayoutDir(result.stdout) or nil
			if layoutDir then
				layoutsCache = listLayouts(layoutDir)
			else
				noctalia.log("zellij-provider: could not resolve the zellij layout directory")
				layoutsCache = {}
			end
			pendingLayouts = false
			maybeShowResults(query)
		end)
	else
		layoutsCache = {}
		pendingLayouts = false
	end

	-- In case both sources were skipped synchronously
	maybeShowResults(query)
end

-- `kill-session` only stops running sessions; exited ones are removed with
-- `delete-session`. Trying the cheap one first avoids depending on the cached
-- state, which can be stale by the time the entry is activated.
local function removeSession(name: string)
	noctalia.runAsync(sformat("zellij kill-session %s", shellQuote(name)), function(result)
		if result.exitCode == 0 then
			refreshSessions(lastQuery)
			return
		end

		noctalia.runAsync(sformat("zellij delete-session %s", shellQuote(name)), function(second)
			if second.exitCode ~= 0 then
				noctalia.log(
					"zellij-provider: could not remove session "
						.. name
						.. ": "
						.. tostring(second.stderr or result.stderr)
				)
			end
			refreshSessions(lastQuery)
		end)
	end)
end

function onQuery(query: string)
	query = noctalia.string.trim(query)
	refreshSessions(query)
end

function onActivate(id: string)
	if id == "" then
		return
	end

	local kind, name = id:match("^(%a+):(.+)$")
	if not kind or not name then
		noctalia.log("zellij-provider: onActivate received malformed id: " .. tostring(id))
		return
	end

	if kind == "attach" then
		noctalia.runInTerminal(sformat("zellij attach %s", shellQuote(name)))
	elseif kind == "create" then
		noctalia.runInTerminal(sformat("zellij attach -c %s", shellQuote(name)))
	elseif kind == "layout" then
		-- `zellij --layout <name>` starts a new session from the layout and lets
		-- zellij name it; `--session` with `--layout` does not create a session
		-- in 0.45.1.
		noctalia.runInTerminal(sformat("zellij --layout %s", shellQuote(name)))
	elseif kind == "kill" then
		removeSession(name)
	end
end
