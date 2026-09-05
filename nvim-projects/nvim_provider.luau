--!nonstrict

local cachedProjects = nil

local function getMaxResults()
	local n = noctalia.getConfig("max_results")
	return (type(n) == "number" and n > 0) and math.floor(n) or 20
end

local function getProjectsDir()
	local d = noctalia.getConfig("projects_dir")
	if type(d) == "string" and d ~= "" then
		return noctalia.expandPath(d)
	end
	return noctalia.expandPath("~/Projects")
end

local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

local function projectName(path)
	local name = path:match("([^/]+)$")
	if not name or name == "" then
		return path
	end
	return name
end

local function shellQuote(s)
	return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

local function loadProjects(onDone)
	local limit = getMaxResults()
	local projDir = getProjectsDir()

	local script = [[
limit="$1"
proj_dir="$2"
seen="|"
count=0

add_dir() {
  local p="$1"
  [ -d "$p" ] || return 0
  [ "$p" = "$HOME" ] && return 0
  case "$seen" in
    *"|$p|"*) return 0 ;;
  esac
  seen="${seen}${p}|"
  echo "$p"
  count=$((count + 1))
  if [ "$count" -ge "$limit" ]; then
    exit 0
  fi
  return 0
}

# 1. Recent Neovim sessions from persistence.nvim
if [ -d "$HOME/.local/state/nvim/sessions" ]; then
  while IFS= read -r -d '' f; do
    b="${f##*/}"
    b="${b%.vim}"
    p="/${b#%}"
    p="${p//%//}"
    add_dir "$p"
  done < <(find "$HOME/.local/state/nvim/sessions" -maxdepth 1 -name "*.vim" -printf '%T@\t%p\0' 2>/dev/null | sort -z -r -n -k1,1 | cut -z -f2-)
fi

# 2. Subdirectories in projects directory
if [ -d "$proj_dir" ]; then
  for sub in "$proj_dir"/*; do
    add_dir "$sub"
  done
fi

# 3. Known project / config workspaces
add_dir "$HOME/.config/nvim"

exit 0
]]

	local cmd = string.format("bash -c %s bash %d %s", shellQuote(script), limit, shellQuote(projDir))

	noctalia.runAsync(cmd, function(result)
		local projects = {}
		if result.exitCode == 0 and type(result.stdout) == "string" then
			for line in result.stdout:gmatch("[^\n]+") do
				local path = trim(line)
				if path ~= "" then
					table.insert(projects, path)
				end
			end
		end
		cachedProjects = projects
		onDone(projects)
	end)
end

local function makeRows(projects, filter)
	local home = noctalia.getenv("HOME") or ""
	local rows = {}
	for _, path in projects do
		local name = projectName(path)
		local score = filter == "" and 0 or noctalia.fuzzyScore(filter, name)
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

function onActivate(id)
	if id == "" then
		return
	end
	local cmd = string.format("cd %s && nvim .", shellQuote(id))
	local customTerm = trim(noctalia.getConfig("terminal") or "")
	if customTerm ~= "" then
		local first = customTerm:match("^%S+") or customTerm
		local bin = first:match("([^/]+)$") or first
		local separator = (bin == "gnome-terminal" or bin == "kgx" or bin == "ptyxis") and "--" or "-e"
		noctalia.runAsync(string.format("%s %s sh -lc %s", customTerm, separator, shellQuote(cmd)))
	else
		noctalia.runInTerminal(cmd)
	end
end
