--!nonstrict

local cachedHosts = nil

local function trim(s)
	return noctalia.string.trim(s or "")
end

local function shellQuote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function getConfigPath()
	local configured = noctalia.getConfig("config_path")
	if type(configured) == "string" and configured ~= "" then
		return noctalia.expandPath(configured)
	end
	return noctalia.expandPath("~/.ssh/config")
end

local function getMaxResults()
	local n = noctalia.getConfig("max_results")
	return (type(n) == "number" and n > 0) and math.floor(n) or 30
end

local function statusRow(title, subtitle, glyph)
	return { id = "", title = title, subtitle = subtitle, glyph = glyph }
end

local function isValidHostAlias(alias)
	return alias ~= "*" and not alias:match("[*?]")
end

local function hostSubtitle(host)
	if host.user and host.hostname then
		return host.user .. "@" .. host.hostname
	end
	return host.hostname or host.user or ""
end

local function parseSshConfig(content)
	local entries = {}
	local current = nil

	local function flushBlock()
		if not current or #current.aliases == 0 then
			return
		end
		local subtitle = hostSubtitle(current)
		for _, alias in current.aliases do
			table.insert(entries, { alias = alias, subtitle = subtitle })
		end
	end

	for line in content:gmatch("[^\r\n]+") do
		local trimmed = trim(line)
		if trimmed ~= "" and not trimmed:match("^#") then
			local key, value = trimmed:match("^(%S+)%s+(.+)$")
			if key and value then
				key = key:lower()
				if key == "host" then
					flushBlock()
					current = { aliases = {}, hostname = nil, user = nil }
					for alias in value:gmatch("%S+") do
						if isValidHostAlias(alias) then
							table.insert(current.aliases, alias)
						end
					end
				elseif current then
					if key == "hostname" then
						current.hostname = trim(value)
					elseif key == "user" then
						current.user = trim(value)
					end
				end
			end
		end
	end

	flushBlock()
	return entries
end

local function loadHosts()
	local content = noctalia.readFile(getConfigPath())
	if type(content) ~= "string" or content == "" then
		return nil
	end
	return parseSshConfig(content)
end

local function launchTerminal(cmd)
	local term = trim(noctalia.getConfig("terminal") or "")
	if term == "" then
		return noctalia.runInTerminal(cmd)
	end

	local first = term:match("^%S+") or term
	local bin = first:match("([^/]+)$") or first
	local separator = (bin == "gnome-terminal" or bin == "kgx" or bin == "ptyxis") and "--" or "-e"
	return noctalia.runAsync(term .. " " .. separator .. " sh -lc " .. shellQuote(cmd))
end

local function fuzzyScoreForHost(filter, host)
	for _, text in { host.alias, host.subtitle } do
		if text ~= "" then
			local score = noctalia.fuzzyScore(filter, text)
			if score then
				return score
			end
		end
	end
end

local function makeRows(hosts, filter)
	local rows = {}
	local limit = getMaxResults()

	for _, host in hosts do
		local score = filter == "" and nil or fuzzyScoreForHost(filter, host)
		if filter == "" or score ~= nil then
			table.insert(rows, {
				id = host.alias,
				title = host.alias,
				subtitle = host.subtitle ~= "" and host.subtitle or nil,
				glyph = "terminal",
				score = score,
			})
		end
	end

	if filter == "" then
		table.sort(rows, function(a, b)
			return a.title:lower() < b.title:lower()
		end)
		while #rows > limit do
			table.remove(rows)
		end
	end

	return rows
end

local function showResults(query, hosts, filter)
	local rows = makeRows(hosts, filter)
	if #rows == 0 then
		launcher.setResults(query, {
			statusRow(
				noctalia.tr("no-hosts-found"),
				filter ~= "" and noctalia.tr("filter-empty", { filter = filter }) or noctalia.tr("config-empty"),
				"terminal"
			),
		})
	else
		launcher.setResults(query, rows)
	end
end

function onQuery(query)
	local filter = trim(query)

	if not noctalia.commandExists("ssh") then
		launcher.setResults(query, {
			statusRow(noctalia.tr("err-no-ssh"), noctalia.tr("err-no-ssh-subtitle"), "triangle-alert"),
		})
		return
	end

	if cachedHosts then
		showResults(query, cachedHosts, filter)
		return
	end

	launcher.setResults(query, {
		statusRow(noctalia.tr("loading"), noctalia.tr("loading-subtitle"), "loader"),
	})

	local hosts = loadHosts()
	if not hosts then
		launcher.setResults(query, {
			statusRow(noctalia.tr("config-missing"), getConfigPath(), "file-x"),
		})
		return
	end

	cachedHosts = hosts
	showResults(query, hosts, filter)
end

function onActivate(id)
	if id == "" then
		return
	end

	local extra = trim(noctalia.getConfig("extra_args") or "")
	local cmd = "ssh " .. shellQuote(id) .. (extra ~= "" and (" " .. extra) or "")

	if not launchTerminal(cmd) then
		noctalia.notifyError("SSH Launcher", noctalia.tr("err-terminal"))
	end
end
