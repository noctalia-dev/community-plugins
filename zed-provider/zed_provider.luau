--!nonstrict

local cachedProjects = nil

local function getDbPath()
	local configured = noctalia.getConfig("db_path")
	if type(configured) == "string" and configured ~= "" then
		return noctalia.expandPath(configured)
	end
	return noctalia.expandPath("~/.local/share/zed/db/0-stable/db.sqlite")
end

local function getMaxResults()
	local n = noctalia.getConfig("max_results")
	return (type(n) == "number" and n > 0) and math.floor(n) or 20
end

local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

local function projectName(path)
	return path:match("([^/]+)$") or path
end

local function shellQuote(s)
	return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

local FIELD_SEP = "\31"

local function splitFields(line)
	local fields = {}
	local start = 1
	while true do
		local sepStart, sepEnd = line:find(FIELD_SEP, start, true)
		if not sepStart then
			table.insert(fields, line:sub(start))
			break
		end
		table.insert(fields, line:sub(start, sepStart - 1))
		start = sepEnd + 1
	end
	return fields
end

local function loadProjects(onDone)
	local db = getDbPath()
	local limit = getMaxResults()
	local sql = string.format(
		"SELECT DISTINCT w.paths, w.remote_connection_id, rc.kind, rc.host, rc.port, rc.user "
			.. "FROM workspaces w LEFT JOIN remote_connections rc ON w.remote_connection_id = rc.id "
			.. "WHERE w.paths IS NOT NULL AND w.paths != '' ORDER BY w.timestamp DESC LIMIT %d;",
		limit
	)
	local cmd =
		string.format("sqlite3 -separator %s %s %s 2>/dev/null", shellQuote(FIELD_SEP), shellQuote(db), shellQuote(sql))

	noctalia.runAsync(cmd, function(result)
		local projects = {}
		if result.exitCode == 0 and type(result.stdout) == "string" then
			for line in result.stdout:gmatch("[^\n]+") do
				local fields = splitFields(line)
				local path = trim(fields[1] or "")
				if path ~= "" then
					local remoteConnectionId = fields[2]
					local kind = fields[3]
					local host = fields[4]
					local port = fields[5]
					local user = fields[6]
					table.insert(projects, {
						path = path,
						remoteConnectionId = (remoteConnectionId ~= nil and remoteConnectionId ~= "") and remoteConnectionId
							or nil,
						kind = (kind ~= nil and kind ~= "") and kind or nil,
						host = (host ~= nil and host ~= "") and host or nil,
						port = (port ~= nil and port ~= "") and tonumber(port) or nil,
						user = (user ~= nil and user ~= "") and user or nil,
					})
				end
			end
		end
		cachedProjects = projects
		onDone(projects)
	end)
end

local function remoteTarget(project)
	local target = "ssh://"
	if project.user then
		target = target .. project.user .. "@"
	end
	target = target .. project.host
	if project.port then
		target = target .. ":" .. tostring(project.port)
	end
	return target .. project.path
end

local function makeRows(projects, filter)
	local home = noctalia.getenv("HOME") or ""
	local rows = {}
	for _, project in projects do
		local isRemote = project.remoteConnectionId ~= nil
		local supported = not isRemote or project.kind == "ssh"
		if supported then
			local name = projectName(project.path)
			local score = filter == "" and 0 or noctalia.fuzzyScore(filter, name)
			if score == nil then
				score = noctalia.fuzzyScore(filter, project.path)
			end
			if filter == "" or score ~= nil then
				local id, subtitle
				if isRemote then
					id = remoteTarget(project)
					subtitle = (project.user and project.user .. "@" or "") .. project.host .. ":" .. project.path
				else
					id = project.path
					subtitle = (home ~= "" and project.path:sub(1, #home) == home) and "~" .. project.path:sub(#home + 1)
						or project.path
				end
				table.insert(rows, {
					id = id,
					title = name,
					subtitle = subtitle,
					icon = "zed",
					score = filter == "" and nil or score,
				})
			end
		end
	end
	return rows
end

local function showResults(query, projects, filter)
	local rows = makeRows(projects, filter)
	if #rows == 0 then
		launcher.setResults(query, {
			{
				id = "",
				title = noctalia.tr("no-projects-found"),
				subtitle = filter ~= "" and noctalia.tr("filter-empty", { filter = filter }) or noctalia.tr("database-empty"),
				glyph = "folder-x",
			},
		})
	else
		launcher.setResults(query, rows)
	end
end

function onQuery(query)
	local filter = trim(query)

	if filter == "" then
		cachedProjects = nil
	end

	if cachedProjects then
		showResults(query, cachedProjects, filter)
		return
	end

	launcher.setResults(query, {
		{
			id = "",
			title = noctalia.tr("loading"),
			subtitle = noctalia.tr("loading-subtitle"),
			glyph = "loader",
		},
	})

	loadProjects(function(projects)
		showResults(query, projects, filter)
	end)
end

function onActivate(id)
	if id == "" then
		return
	end
	noctalia.runAsync(string.format("nohup zeditor %s &>/dev/null &", shellQuote(id)))
end
