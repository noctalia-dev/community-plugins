local cachedProjects = nil

local function getMaxResults(): int
	local n = noctalia.getConfig("max_results")
	return (type(n) == "number" and n > 0) and math.floor(n) or 20
end

local function getProjectsDir(): string
	local d = noctalia.getConfig("projects_dir")
	if type(d) == "string" and d ~= "" then
		return noctalia.expandPath(d)
	end
	return noctalia.expandPath("~/Projects")
end

local function getBaseCommand(): string
	local d = noctalia.getConfig("command")
	if type(d) == "string" and d ~= "" then
		return d
	end
	return "nvim"
end

local function getRunInTerminal(): bool
	local d = noctalia.getConfig("run_in_terminal")
	if type(d) == "boolean" then
		return d
	end
	return true
end

local function trim(s: string): string
	return s:match("^%s*(.-)%s*$")
end

local function projectName(path: string): string
	local name = path:match("([^/]+)$")
	if not name or name == "" then
		return path
	end
	return name
end

local function shellQuote(s: string): string
	return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

local function escapeVim(s: string): string
    -- Only return first value from gsub
    local replaced =  s:gsub("[%%#]", "\\%0")
    return replaced
end

local function split(haystack: string, separator: string): {string}
    local t = {}
    local start = 1
    while true do
        local sepstart, stop = string.find(haystack, separator, start, true)
        if sepstart ~= nil then
            table.insert(t, haystack:sub(start, sepstart-1))
            start = stop + 1
        else
            break
        end
    end
    table.insert(t, haystack:sub(start))
    return t
end

local function parseSessionName(fullname: string): {path: string, name: string}
    local pathSep = nil
    local branchSep = nil
    local stripSuffix = false -- Whether to remove ".vim" from the end of the filename

    -- Remember that % is the escape character for lua patterns,
    -- so we need to escape them all here
    if fullname:match("^__") then
        -- neovim_session_manager style session name
        pathSep = "__"
     elseif fullname:match("^%%2F") then
        -- auto-session style session name
        pathSep = "%%2F"
        branchSep = "%%7C"
        stripSuffix = true
     elseif fullname:match("^%%") then
        -- persistence style session name
        pathSep = "%%"
        branchSep = "%%%%"
        stripSuffix = true
    end

    if stripSuffix then
        fullname = fullname:gsub("%.vim$", "")
    end

    local branchName = nil
    if branchSep ~= nil then
        local first, last  = fullname:find(branchSep)
        if first ~= nil then
            branchName = fullname:sub(last+1):gsub(pathSep, "/")
            fullname = fullname:sub(1, first-1)
        end
    end

    local fullpath = if pathSep ~= nil then fullname:gsub(pathSep, "/") else fullname
    local dirname = projectName(fullpath)
    
    local name = if branchName ~= nil then `{dirname} ({branchName})` else dirname
    return name, fullpath
end

local function addProject(projects, count_so_far, name, dir, session_file): int
    if projects[dir] ~= nil then
        return count_so_far
    end

    local info = noctalia.fileInfo(session_file or dir)
    projects[dir] = {
        name = name,
        session_file = session_file,
        dir = dir,
        mtime = if info ~= nil then info.mtime else 0
    }
    return count_so_far + 1
end

local function loadProjects(onDone)
	local limit = getMaxResults()
	local projDir = getProjectsDir()
    local count = 0

    local projects = {}

    local confDir = noctalia.getenv('HOME') .. '/.config/nvim'
    count = addProject(projects, count, projectName(confDir), confDir, nil)

	local persistence_sessions = noctalia.listDir('~/.local/state/nvim/sessions') or {}
    for _, psession in persistence_sessions do
        if count >= limit then break end
        local name, dir = parseSessionName(psession)
        count = addProject(projects, count, name, dir, '~/.local/state/nvim/sessions/' .. psession)
    end

	local other_sessions = noctalia.listDir('~/.local/share/nvim/sessions') or {}
    for _, osession in other_sessions do
        if count >= limit then break end
        local name, dir = parseSessionName(osession)
        count = addProject(projects, count, name, dir, '~/.local/share/nvim/sessions/' .. osession)
    end

	local project_dirs = noctalia.listDir(projDir) or {}
    for _, dir in project_dirs do
        if count >= limit then break end
        count = addProject(projects, count, projectName(dir), projDir .. '/' .. dir, nil)
    end

    cachedProjects = projects
    onDone(projects)
end

local function makeRows(projects, filter)
	local home = noctalia.getenv("HOME") or ""
	local rows = {}
	for path, project in projects do
		local name = project.name
		local score = filter == "" and project.mtime or noctalia.fuzzyScore(filter, name)
		if score == nil then
			score = noctalia.fuzzyScore(filter, path)
		end
		if filter == "" or score ~= nil then
			local display = (home ~= "" and path:sub(1, #home) == home) and "~" .. path:sub(#home + 1) or path
			table.insert(rows, {
				id = path,
				title = name,
				subtitle = display,
				icon = "nvim",
				score = filter == "" and nil or score,
			})
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
				subtitle = filter ~= "" and noctalia.tr("filter-empty", { filter = filter }) or noctalia.tr("no-recent-projects"),
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

function onActivate(id: string)
	if id == "" then
		return
	end
    local project = cachedProjects[id]
    local args = split(getBaseCommand(), ' ')
    if project.session_file ~= nil then
        table.insert(args, "-S")
        table.insert(args, escapeVim(project.session_file))
    else
        table.insert(args, "-c")
        table.insert(args, "cd "..escapeVim(project.dir))
        table.insert(args, "--")
        table.insert(args, project.dir)
    end
	local customTerm = trim(noctalia.getConfig("terminal") or "")
    if getRunInTerminal() then
        if customTerm ~= "" then
            local first = customTerm:match("^%S+") or customTerm
            local bin = first:match("([^/]+)$") or first
            local separator = (bin == "gnome-terminal" or bin == "kgx" or bin == "ptyxis") and "--" or "-e"
            noctalia.runAsync({customTerm, separator, table.unpack(args)})
        else
            local cmd = ""
            for _, arg in args do
                cmd = cmd .. shellQuote(arg)
                cmd = cmd .. " "
            end
            -- This is a bit of a hack, so bear with me
            -- Noctala executes `runInTerminal` by putting `sh -lc` in front of our command
            -- Unfortunately, depending on the implementation of sh, it will interpret the command line differently
            -- Dash (used by Ubuntu, Debian, Void) will only take the next word
            --  as the argument to -c, so you need to quote the whole command if
            --  you want to give an executable with arguments
            -- Bash (used by Arch, Fedora) will take the rest of the line as
            --  the argument to -c, so no quoting is needed. However, if you do
            --  quote it, it will interpret the entire quoted command line as
            --  the name of the executable file to run, and fail
            -- The exception is, if Dash sees a special character (like ; or && or | or >, etc)
            --  then it will execute the whole command instead of just the first word. So we
            --  add a no-op command in front (:), then unconditionally continue on to the real command 
            noctalia.runInTerminal(':; '..cmd)
        end
    else
        noctalia.runAsync(args)
    end
end
