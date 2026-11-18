--!nonstrict

local cachedProjects = nil
local productIcons = {}

local PRODUCTS = {
	IntelliJIdea = { cmd = "idea", slug = "intellij-idea" },
	AndroidStudio = { cmd = "studio", slug = "android-studio" },
	WebStorm = { cmd = "webstorm", slug = "webstorm" },
	CLion = { cmd = "clion", slug = "clion" },
	GoLand = { cmd = "goland", slug = "goland" },
	RustRover = { cmd = "rustrover", slug = "rustrover" },
	PyCharm = { cmd = "pycharm", slug = "pycharm" },
	PhpStorm = { cmd = "phpstorm", slug = "phpstorm" },
	RubyMine = { cmd = "rubymine", slug = "rubymine" },
	DataGrip = { cmd = "datagrip", slug = "datagrip" },
	Rider = { cmd = "rider", slug = "rider" },
}

local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

local function shellQuote(s)
	return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

local function getConfigDir()
	local configured = noctalia.getConfig("config_dir")
	if type(configured) == "string" and configured ~= "" then
		return noctalia.expandPath(configured)
	end
	return noctalia.expandPath("~/.config/JetBrains")
end

local function getToolboxDir()
	local configured = noctalia.getConfig("toolbox_dir")
	if type(configured) == "string" and configured ~= "" then
		return noctalia.expandPath(configured)
	end
	return noctalia.expandPath("~/.local/share/JetBrains/Toolbox/apps")
end

local function getMaxResults()
	local n = noctalia.getConfig("max_results")
	return (type(n) == "number" and n > 0) and math.floor(n) or 20
end

local function ignoredIdes()
	local raw = noctalia.getConfig("ignored_ides")
	if type(raw) ~= "table" then
		return {}
	end
	local list = {}
	for _, entry in ipairs(raw) do
		local name = trim(tostring(entry))
		if name ~= "" then
			table.insert(list, name)
		end
	end
	return list
end

local function projectName(path)
	return path:match("([^/]+)$") or path
end

local function buildScanCommand()
	local script = shellQuote(noctalia.pluginDir() .. "/scan_projects.sh")
	local ignoreArgs = ""
	for _, name in ipairs(ignoredIdes()) do
		ignoreArgs = ignoreArgs .. " " .. shellQuote(name)
	end

	return string.format(
		"JB_CONFIG_DIR=%s JB_TOOLBOX_DIR=%s JB_MAX_RESULTS=%d bash %s%s 2>/dev/null",
		shellQuote(getConfigDir()),
		shellQuote(getToolboxDir()),
		getMaxResults(),
		script,
		ignoreArgs
	)
end

local function parseScanOutput(stdout)
	local projects = {}
	productIcons = {}

	for line in stdout:gmatch("[^\n]+") do
		local kind, product, value = line:match("^(%w+)\t([^%c]+)\t(.+)$")
		if kind == "ICON" and product and value then
			productIcons[product] = value
		elseif kind and tonumber(kind) and product and value then
			table.insert(projects, {
				timestamp = tonumber(kind) or 0,
				product = product,
				path = value,
			})
		end
	end

	return projects
end

local function makeRows(projects, filter)
	local home = noctalia.getenv("HOME") or ""
	local rows = {}
	for _, project in ipairs(projects) do
		local path = project.path
		local name = projectName(path)
		local score = filter == "" and 0 or noctalia.fuzzyScore(filter, name)
		if score == nil then
			score = noctalia.fuzzyScore(filter, path)
		end
		if filter == "" or score ~= nil then
			local display = (home ~= "" and path:sub(1, #home) == home) and "~" .. path:sub(#home + 1) or path
			local iconPath = productIcons[project.product]
			local row = {
				id = project.product .. "|" .. path,
				title = name,
				subtitle = project.product .. " · " .. display,
				score = filter == "" and nil or score,
			}
			if iconPath then
				row.icon = iconPath
			else
				row.glyph = "code"
			end
			table.insert(rows, row)
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

local function loadProjects(onDone)
	noctalia.runAsync(buildScanCommand(), function(result)
		local projects = {}
		if result.exitCode == 0 and type(result.stdout) == "string" then
			projects = parseScanOutput(result.stdout)
		end
		cachedProjects = projects
		onDone(projects)
	end)
end

local function resolveLauncher(product)
	local meta = PRODUCTS[product]
	if meta == nil then
		return nil
	end

	local script = getToolboxDir() .. "/" .. meta.slug .. "/bin/" .. meta.cmd .. ".sh"
	if noctalia.fileExists(script) then
		return script
	end

	return meta.cmd
end

function onQuery(query)
	local filter = trim(query or "")

	if filter == "" then
		cachedProjects = nil
		productIcons = {}
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

	local product, path = id:match("^(.-)|(.+)$")
	if product == nil or path == nil or path == "" then
		return
	end

	local launcherCmd = resolveLauncher(product)
	if launcherCmd == nil then
		return
	end

	noctalia.runAsync(string.format("nohup %s %s &>/dev/null &", shellQuote(launcherCmd), shellQuote(path)))
end
