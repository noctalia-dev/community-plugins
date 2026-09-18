--!nonstrict
-- Launcher provider: type a filesystem path and it completes as you type; Enter
-- opens it in your file manager / default handler. Type anything that isn't a
-- path and Enter runs it as a shell command.
--
-- Path mode is chosen when the input starts with "/", "~" or ".". Everything
-- else is treated as a command. An empty input is treated like "~", so the
-- keybind on its own lists your home directory.
--
-- "." and ".." resolve against $HOME, not a process cwd - the launcher has none.
--
-- The first result row is always "Open <name>" for whatever the input resolves
-- to right now, and the launcher preselects the first row, so typing a path and
-- pressing Enter opens it. Activating a directory row below it descends into
-- that directory via launcher.setQuery() instead of opening it, so the list
-- doubles as navigation.

local lastOpenTarget = nil

local function trim(s)
	return noctalia.string.trim(s or "")
end

local function homeDir()
	local home = noctalia.getenv("HOME")
	if home and home ~= "" then
		return home
	end
	return noctalia.expandPath("~")
end

local function isPathLike(s)
	local c = s:sub(1, 1)
	return c == "/" or c == "~" or c == "."
end

local function resolvePath(s)
	local c = s:sub(1, 1)
	if c == "~" then
		return noctalia.expandPath(s)
	elseif c == "/" then
		return s
	else
		return homeDir() .. "/" .. s
	end
end

-- Splits a resolved path into (directory to list, partial name to filter by).
-- A trailing "/" means the whole thing is the directory and there is no
-- partial yet.
local function splitForCompletion(resolved)
	if resolved:sub(-1) == "/" then
		local dir = resolved:sub(1, -2)
		if dir == "" then
			dir = "/"
		end
		return dir, ""
	end
	local dir, partial = resolved:match("^(.*)/([^/]*)$")
	if not dir then
		return "/", resolved
	end
	if dir == "" then
		dir = "/"
	end
	return dir, partial
end

local function shellQuote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function displayName(resolved)
	local name = resolved:match("([^/]+)/?$")
	return name or resolved
end

local function getSetting(key, default)
	local value = noctalia.getConfig(key)
	if value == nil or value == "" then
		return default
	end
	return value
end

local function getMaxResults()
	local n = noctalia.getConfig("max_results")
	return (type(n) == "number" and n > 0) and math.floor(n) or 20
end

local function showHiddenEnabled()
	return noctalia.getConfig("show_hidden") == true
end

local function statusRow(title, subtitle, glyph)
	return { id = "", title = title, subtitle = subtitle, glyph = glyph }
end

-- Lists dirPath, filtered case-insensitively to entries whose name starts with
-- partial, sorted, and capped to the configured max. Each row's id is the
-- entry's resolved path, with a trailing "/" added for directories - that
-- trailing slash is how onActivate later tells a directory (descend) from a
-- file (open) apart.
local function listEntries(dirPath, partial)
	local names, err = noctalia.listDir(dirPath)
	if not names then
		return nil, err
	end

	local showHidden = showHiddenEnabled()
	local partialLower = partial:lower()
	local matches = {}
	for _, name in names do
		if showHidden or name:sub(1, 1) ~= "." then
			if partial == "" or name:lower():sub(1, #partialLower) == partialLower then
				table.insert(matches, name)
			end
		end
	end
	table.sort(matches, function(a, b)
		return a:lower() < b:lower()
	end)

	local rows = {}
	local limit = getMaxResults()
	for _, name in matches do
		if #rows >= limit then
			break
		end
		local full = (dirPath == "/") and ("/" .. name) or (dirPath .. "/" .. name)
		local info = noctalia.fileInfo(full)
		local isDir = info ~= nil and info.isDir
		table.insert(rows, {
			id = isDir and (full .. "/") or full,
			title = isDir and (name .. "/") or name,
			subtitle = full,
			glyph = isDir and "folder" or "file",
		})
	end
	return rows
end

-- "~", "." and ".." name a directory outright, with no parent-relative partial
-- to complete - list what they point at instead of treating the last path
-- component as a partial name inside its parent.
local function namesDirectoryOutright(text)
	return text == "~" or text == "." or text == ".."
end

local function showPathResults(query, text)
	local resolved = resolvePath(text)
	lastOpenTarget = resolved

	local listPath = resolved
	if namesDirectoryOutright(text) and listPath:sub(-1) ~= "/" then
		listPath = listPath .. "/"
	end
	local dirPath, partial = splitForCompletion(listPath)
	local dirInfo = noctalia.fileInfo(dirPath)
	if not dirInfo or not dirInfo.isDir then
		launcher.setResults(query, {
			statusRow(noctalia.tr("no-such-directory"), dirPath, "folder-x"),
		})
		return
	end

	local rows, err = listEntries(dirPath, partial)
	if not rows then
		launcher.setResults(query, {
			statusRow(noctalia.tr("cannot-list-directory"), err or dirPath, "folder-x"),
		})
		return
	end

	local openInfo = noctalia.fileInfo(resolved)
	local openGlyph = (openInfo and openInfo.isDir) and "folder-open" or "file"
	table.insert(rows, 1, {
		id = "open",
		title = noctalia.tr("open-row", { name = displayName(resolved) }),
		subtitle = resolved,
		glyph = openGlyph,
	})

	launcher.setResults(query, rows)
end

function onQuery(query)
	local raw = trim(query)
	local text = (raw == "") and "~" or raw

	if isPathLike(text) then
		showPathResults(query, text)
	else
		lastOpenTarget = nil
		launcher.setResults(query, {
			{
				id = "run:" .. text,
				title = noctalia.tr("run-row", { command = text }),
				subtitle = noctalia.tr("run-subtitle"),
				glyph = "terminal",
			},
		})
	end
end

local function openPath(path)
	local info = noctalia.fileInfo(path)
	local isDir = info ~= nil and info.isDir
	local command = isDir and getSetting("file_manager", "xdg-open") or getSetting("file_opener", "xdg-open")

	if not noctalia.runAsync(command .. " " .. shellQuote(path)) then
		noctalia.notifyError("Run / Open Path", noctalia.tr("err-open-failed"))
	end
end

function onActivate(id)
	if id == "" then
		return
	end

	if id == "open" then
		if lastOpenTarget then
			openPath(lastOpenTarget)
		end
		return
	end

	local command = id:match("^run:(.*)$")
	if command then
		if not noctalia.runAsync(command) then
			noctalia.notifyError("Run / Open Path", noctalia.tr("err-run-failed"))
		end
		return
	end

	-- Any other id is a resolved path; a trailing "/" marks a directory, so
	-- descend into it instead of opening it.
	if id:sub(-1) == "/" then
		launcher.setQuery(id)
	else
		openPath(id)
	end
end
