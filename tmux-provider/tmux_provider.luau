local tinsert = table.insert
local tsort = table.sort
local sformat = string.format

-- Per-query in-flight state: both tmux and tmuxp results must land before
-- we render, since either can be requested for the same query.
local sessionsCache
local tmuxpCache
local pendingQuery: string? = nil
local pendingTmux = false
local pendingTmuxp = false

local function tmuxInstalled(): boolean
	return noctalia.commandExists("tmux")
end

local function tmuxpInstalled(): boolean
	return noctalia.commandExists("tmuxp")
end

local function shellQuote(s: string): string
	return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

-- Parses `tmux ls` output into a list of { name, attached }
-- Format per line: "name: N windows (created ...) [(attached)]"
local function parseTmuxLs(output: string)
	local sessions = {}
	for line in output:gmatch("[^\r\n]+") do
		local name = line:match("^([^:]+):")
		if name then
			local attached = line:find("%(attached%)") ~= nil
			tinsert(sessions, { name = name, attached = attached })
		end
	end
	return sessions
end

-- Parses `tmuxp ls --json` output into a list of { name, session_name }
local function parseTmuxpLs(output: string)
	local configs = {}

	local data, err = noctalia.json.decode(output)
	if not data or not data.workspaces then
		if err then
			noctalia.log("tmux-provider: failed to parse tmuxp ls --json output: " .. tostring(err))
		end
		return configs
	end

	for _, workspace in ipairs(data.workspaces) do
		if workspace.name then
			tinsert(configs, {
				name = workspace.name,
				session_name = workspace.session_name or workspace.name,
			})
		end
	end

	return configs
end

-- Builds the combined result list: running tmux sessions first, then tmuxp
-- configs that aren't already running as a live session.
local function buildResults(query: string)
	local results = {}
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
					subtitle = session.attached and noctalia.tr("session_attached")
						or noctalia.tr("session_detached"),
					glyph = "terminal-2",
					score = score,
				})
			end
		end
	end

	if tmuxpCache then
		for _, config in ipairs(tmuxpCache) do
			if not runningNames[config.session_name] then
				local score: number?
				if query == "" then
					score = -1 -- rank below live sessions when query is empty
				else
					score = noctalia.fuzzyScore(query, config.name)
				end

				if score ~= nil then
					tinsert(results, {
						id = "tmuxp:" .. config.session_name,
						title = config.name,
						subtitle = noctalia.tr("tmuxp_config"),
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
	local results = buildResults(query)

	if #results > 0 then
		launcher.setResults(query, results)
		return
	end

	if not tmuxInstalled() then
		launcher.setResults(query, {
			{
				id = "",
				title = noctalia.tr("tmux_not_found"),
				subtitle = noctalia.tr("tmux_not_found_subtitle"),
				glyph = "alert-triangle",
			},
		})
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
	if pendingTmux or pendingTmuxp then
		return -- still waiting on one of the two sources
	end
	showResults(query)
end

local function refreshSessions(query: string)
	pendingQuery = query

	if tmuxInstalled() then
		pendingTmux = true
		noctalia.runAsync("tmux ls", function(result)
			if result.exitCode == 0 then
				sessionsCache = parseTmuxLs(result.stdout)
			else
				-- tmux exits non-zero both on "no server running" (expected,
				-- empty list) and on real errors. We can't reliably match the
				-- "no server" message across tmux versions/locales, so we just
				-- treat any non-zero exit as "no sessions" and log it at low
				-- severity for diagnostics rather than surfacing it as an error.
				if result.stderr and result.stderr ~= "" then
					noctalia.log("tmux-provider: tmux ls: " .. result.stderr)
				end
				sessionsCache = {}
			end
			pendingTmux = false
			maybeShowResults(query)
		end)
	else
		sessionsCache = {}
		pendingTmux = false
	end

	local use_tmuxp: boolean = noctalia.getConfig("use_tmuxp") or false
	if use_tmuxp and tmuxpInstalled() then
		pendingTmuxp = true
		noctalia.runAsync("tmuxp ls --json", function(result)
			if result.exitCode == 0 then
				tmuxpCache = parseTmuxpLs(result.stdout)
			else
				noctalia.log(
					"tmux-provider: tmuxp ls --json failed: "
						.. tostring(result.stderr or result.stdout)
				)
				tmuxpCache = {}
			end
			pendingTmuxp = false
			maybeShowResults(query)
		end)
	else
		tmuxpCache = {}
		pendingTmuxp = false
	end

	-- In case both sources were skipped synchronously (e.g. neither installed)
	maybeShowResults(query)
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
		noctalia.log("tmux-provider: onActivate received malformed id: " .. tostring(id))
		return
	end

	if kind == "attach" then
		noctalia.runInTerminal(sformat("tmux attach -t %s", shellQuote(name)))
	elseif kind == "tmuxp" then
		noctalia.runInTerminal(sformat("tmuxp load %s", shellQuote(name)))
	end
end
