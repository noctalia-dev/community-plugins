-- Shell Command launcher provider.
--
-- Type `/sh <command>` in the launcher to run a shell command in your default
-- terminal. Fish-style autosuggestions: as you type it queries the shell's own
-- completion engine (`fish -c 'complete -C "<query>"'`, falling back to bash
-- `compgen -c`) so suggestions grow dynamically with your system — no hardcoded
-- list. Commands from your own history and user-defined snippets are offered
-- too. A `cd` mode lists folders so you can open a terminal in a chosen
-- directory. Selecting any entry opens it in a real terminal (via
-- noctalia.runInTerminal), so you get a full shell with live output, TUI apps,
-- and native history.

local HISTORY_FILE = "history"
local HISTORY_LIMIT = 100
local MAX_SUGGESTIONS = 8

local history = {}

local function shellQuote(s)
	return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

local function trim(s)
	return noctalia.string.trim(tostring(s or ""))
end

-- Private per-plugin storage (XDG state); the host creates the directory on
-- every call. nil (with a log line) when no state directory resolves.
local function dataDir()
	local dir, err = noctalia.pluginDataDir()
	if dir == nil then
		noctalia.log("shell-command: pluginDataDir failed: " .. tostring(err))
		return nil
	end
	return dir
end

local function loadHistory()
	local dir = dataDir()
	if dir == nil then
		return
	end
	local raw = noctalia.readFile(dir .. "/" .. HISTORY_FILE)
	if type(raw) ~= "string" or raw == "" then
		return
	end
	history = {}
	for line in raw:gmatch("[^\r\n]+") do
		line = trim(line)
		if line ~= "" then
			history[#history + 1] = line
		end
	end
end

local function saveHistory()
	local dir = dataDir()
	if dir == nil then
		return
	end
	local ok, err = noctalia.writeFile(dir .. "/" .. HISTORY_FILE, table.concat(history, "\n"))
	if not ok then
		noctalia.log("shell-command: could not persist history: " .. tostring(err))
	end
end

-- Record a run command: move it to the front (most recent), dedupe, cap size.
local function recordHistory(cmd)
	for i, entry in ipairs(history) do
		if entry == cmd then
			table.remove(history, i)
			break
		end
	end
	table.insert(history, 1, cmd)
	if #history > HISTORY_LIMIT then
		for _ = HISTORY_LIMIT + 1, #history do
			table.remove(history)
		end
	end
	saveHistory()
end

-- Build the command actually launched in the terminal.
--
-- If the query itself is a `cd <dir> && <cmd>` compound, we cd into `<dir>`
-- instead of the workspace — that way navigation and a command can be combined
-- in one launch (`/sh cd ~/proj && ls`). Otherwise, if a default workspace is
-- configured, cd there first.
--
-- Commands run through the user's own `$SHELL` (not `sh`), so aliases,
-- shell functions and environment from the login shell are available. The
-- command is wrapped so the terminal stays open after it finishes (a fast
-- command like `git status` would otherwise close the window before you can
-- read the output). We hold the output on screen with `read`, then drop into a
-- fresh interactive shell so the user can keep typing — exec'ing the shell
-- directly clears the result before it can be read.
-- Wrap a command in the terminal-held-open wrapper and run it via the user's
-- own interactive shell (`$SHELL -ic`) so aliases and functions from the
-- login/rc config are available — a bare `-c` ignores them and breaks things
-- like fish aliases. After the command we `exec $SHELL` into a fresh
-- interactive shell.
local function buildLaunch(inner)
	local shell = noctalia.getenv("SHELL") or "sh"
	-- `-ic`: user's rc config/aliases load. Alias-safe `read` (fish shows an
	-- ugly `read>` prompt interactively — use the silent `-s`/`-l` variant; bash
	-- and zsh `read` are silent already and have no such prompt) holds the
	-- output until Enter, then we exec a fresh interactive shell that stays open.
	local base = shell:match("([^/]+)$") or "sh"
	local readCmd = (base == "fish") and "read -l -s __x" or "read __x"
	local printfPrompt = "printf '%s\\n' '[Press Enter to continue]  [Ctrl+C to Close]'"
	return shell .. " -ic " .. shellQuote(inner .. "; " .. printfPrompt .. "; " .. readCmd .. "; exec $SHELL")
end

local function buildCommand(cmd)
	local inner = cmd
	-- Try to split a leading `cd <path> && <rest>` compound, honouring quoted
	-- paths, spaces and `\ ` escapes inside the directory argument.
	local dir = cmd:match("^%s*cd%s+(.+)$")
	if dir then
		local i, n = 1, #dir
		local out = {}
		local quote
		local done
		while i <= n do
			local c = dir:sub(i, i)
			if quote then
				if c == quote then
					quote = nil
				elseif c == "\\" and i < n then
					out[#out + 1] = dir:sub(i + 1, i + 1)
					i = i + 1
				else
					out[#out + 1] = c
				end
			elseif c == '"' or c == "'" then
				quote = c
			elseif c == " " then
				done = true
				break
			else
				out[#out + 1] = c
			end
			i = i + 1
		end
		if not done then
			i = n + 1 -- path ran to end; nothing appended
		end
		local rest = dir:sub(i):match("^%s*&&%s*(.+)$")
		if #out > 0 and rest then
			local path = table.concat(out)
			local abs = path:gsub("^~/+", (noctalia.getenv("HOME") or "/") .. "/")
			inner = "cd " .. shellQuote(abs) .. " && " .. rest
		else
			inner = cmd
		end
	else
		local cwd = noctalia.getConfig("default_workspace")
		if type(cwd) == "string" and cwd ~= "" then
			inner = "cd " .. shellQuote(cwd) .. " && " .. cmd
		end
	end
	-- Run through the user's own interactive shell (`-ic`) so aliases and
	-- functions from the login/rc config are available, not just `-c` which
	-- ignores them. The wrapper is a real terminal so it's interactive-stable;
	-- after the command we `exec $SHELL` into a fresh interactive shell.
	return buildLaunch(inner)
end

-- Open a terminal directly inside a chosen directory (no command to run).
local function buildCdCommand(path)
	-- Also interactive so aliases work inside the opened shell.
	return buildLaunch("cd " .. shellQuote(path))
end

-- The first token of the command, used to detect whether the binary exists.
local function firstToken(cmd)
	local token = cmd:match("^%s*([^%s]+)")
	return token or ""
end

local function runEntry(cmd, subtitle)
	return {
		id = "run:" .. cmd,
		title = noctalia.tr("run_title", { command = cmd }),
		subtitle = subtitle,
		glyph = "terminal",
	}
end

-- Rebuild the full command from a completion token. The completion engine
-- returns only the token being completed, so we re-attach the typed prefix.
local function fullCommand(query, comp)
	local prefix = query:match("^(.*%s)") or ""
	return prefix .. comp
end

-- Parse `fish -c 'complete -C "<query>"'` output: one completion per line,
-- optionally `completion<TAB>description`. We keep the completion token.
local function parseFish(output)
	local comps = {}
	for line in (tostring(output or "") .. "\n"):gmatch("(.-)\n") do
		line = trim(line)
		if line ~= "" then
			local comp = line:match("^([^\t]+)")
			if comp and comp ~= "" then
				comps[#comps + 1] = comp
			end
		end
	end
	return comps
end

-- Parse `compgen -c` output: one command name per line.
local function parseCompgen(output)
	local comps = {}
	for line in (tostring(output or "") .. "\n"):gmatch("(.-)\n") do
		line = trim(line)
		if line ~= "" then
			comps[#comps + 1] = line
		end
	end
	return comps
end

-- Query the shell's completion engine for the typed prefix. Prefers fish
-- (full subcommand/flag completions); falls back to bash `compgen -c` for
-- command names when fish is unavailable.
local function fetchCompletions(query, callback)
	if noctalia.commandExists("fish") then
		noctalia.runAsync("fish -c " .. shellQuote("complete -C " .. shellQuote(query)), function(result)
			callback(parseFish(result.stdout))
		end)
		return
	end
	if noctalia.commandExists("bash") then
		local word = query:match("([^%s]+)%s*$") or ""
		noctalia.runAsync("bash -c " .. shellQuote("compgen -c " .. shellQuote(word)), function(result)
			callback(parseCompgen(result.stdout))
		end)
		return
	end
	callback({})
end

-- List subdirectories of the cd root (default workspace, else $HOME) so the
-- user can open a terminal inside a chosen folder. Uses `ls -d */` (fast, one
-- level) rather than `find`, which can crawl slowly over a large home dir.
-- Expand leading ~ and join a relative path onto the workspace base so
-- breadcrumb navigation works from any spelling: `~/Builds`, `Builds`,
-- `/abs/path`. Trailing slash preserved. Returns an absolute path.
local function resolvePath(p)
	local base = noctalia.getConfig("default_workspace")
	if type(base) ~= "string" or base == "" then
		base = noctalia.getenv("HOME") or "/"
	end
	if type(p) ~= "string" or (p:match("^%s*$")) then
		return base
	end
	p = p:gsub("^~/+", (noctalia.getenv("HOME") or "/") .. "/")
	if p:sub(1, 1) ~= "/" then
		-- Relative (or empty) — resolve against workspace base.
		p = base .. "/" .. p:gsub("^/+", "")
	end
	return p
end

-- List subdirectories to navigate into, breadcrumb-style. The query after
-- `cd` is a path you're halfway through typing: the parent directory is listed
-- and the typed prefix filters it. Selecting a folder fills the input with that
-- path (cd:<path>/), letting you drill deeper or continue typing.
--
--   /sh cd            -> list top-level dirs of the workspace
--   /sh cd proj       -> list workspace dirs starting with "proj"
--   /sh cd ~/Builds   -> list ~/Builds sub-entries starting with the rest
--   /sh cd ~/Builds/  -> list everything directly inside ~/Builds
local function listDirs(query)
	local pathPart = query:match("^cd%s*(.*)$") or ""

	local parent, prefix
	if pathPart == "" then
		-- Root of the workspace, and nothing typed to drill before it.
		parent, prefix = resolvePath(""), ""
	elseif pathPart:match("[/]$") then
		-- Ends with a slash: navigate into an existing directory.
		parent, prefix = resolvePath(pathPart), ""
	else
		local slash = pathPart:match("^.*/")
		if slash then
			-- Mid-path: split at the last slash into parent + typed prefix.
			local base2 = resolvePath(slash:gsub("/$", ""))
			parent = base2
			prefix = pathPart:sub(#slash + 1):gsub("^%s", "")
		else
			-- Bare first segment — resolve against base, prefix is the whole pathPart.
			parent, prefix = resolvePath(""), pathPart
		end
	end

	local dirs = {}
	local names = noctalia.listDir(parent) or {}
	table.sort(names)
	for _, name in ipairs(names) do
		if name ~= "." and name ~= ".." and (prefix == "" or name:sub(1, #prefix) == prefix) then
			local info = noctalia.fileInfo(parent .. "/" .. name)
			if info and info.isDir then
				dirs[#dirs + 1] = { path = parent .. "/" .. name, name = name }
			end
		end
	end
	return dirs, parent
end

local pendingQuery = nil

function onQuery(query)
	query = trim(query)
	pendingQuery = query

	if query == "" then
		-- Empty query: hint, then user snippets, then recent commands.
		local results = {
			{
				id = "",
				title = noctalia.tr("hint_title"),
				subtitle = noctalia.tr("hint_subtitle"),
				glyph = "terminal",
			},
		}
		local snippets = noctalia.getConfig("snippets")
		if type(snippets) == "table" then
			for _, snippet in ipairs(snippets) do
				snippet = trim(snippet)
				if snippet ~= "" then
					results[#results + 1] = {
						id = "fill:" .. snippet,
						title = snippet,
						subtitle = noctalia.tr("snippet_subtitle"),
						glyph = "bookmark",
					}
				end
			end
		end
		for i = 1, math.min(MAX_SUGGESTIONS, #history) do
			results[#results + 1] = {
				id = "fill:" .. history[i],
				title = history[i],
				subtitle = noctalia.tr("history_subtitle"),
				glyph = "history",
			}
		end
		launcher.setResults(query, results)
		return
	end

	-- cd mode: breadcrumb folder navigation. Folder rows fill input with
	-- trailing-slash path (`fill:`) so Enter drills one level deeper and can
	-- keep going. First "Open in:" row launches terminal directly in the
	-- current parent dir (`cdgo:`).
		-- A `cd <path> && <cmd>` compound launches a real command (navigation +
		-- execution), not folder navigation. Skip the cd branch so it reaches the
		-- run path, where buildCommand parses and executes it.
		local isCompound = query:match("^%s*cd%s+.+&&.+$")

		if not isCompound and (query == "cd" or query:match("^cd%s")) then
		local dirs, parent = listDirs(query)
		local results = {}
		results[#results + 1] = {
			id = "cdgo:" .. parent,
			title = noctalia.tr("cd_open_title", { path = parent }),
			subtitle = noctalia.tr("cd_open_subtitle"),
			glyph = "folder-open",
		}
		for _, dir in ipairs(dirs) do
			results[#results + 1] = {
				id = "fill:cd " .. dir.path .. "/",
				title = dir.name,
				subtitle = dir.path,
				glyph = "folder",
			}
		end
		if #dirs == 0 then
			results[#results + 1] = {
				id = "",
				title = noctalia.tr("cd_empty"),
				subtitle = noctalia.tr("cd_empty_subtitle"),
				glyph = "folder",
			}
		end
		launcher.setResults(query, results)
		return
	end

	local token = firstToken(query)
	local subtitle = noctalia.tr("run_subtitle")
	if token ~= "" and noctalia.commandExists(token) then
		subtitle = noctalia.tr("run_subtitle_found", { command = token })
	end

	-- Show the exact command immediately, then fill in suggestions async.
	launcher.setResults(query, { runEntry(query, subtitle) })

	fetchCompletions(query, function(comps)
		if pendingQuery ~= query then
			return -- a newer query superseded this one
		end
		local results = { runEntry(query, subtitle) }
		-- Snap-complete: a single distinct expanding candidate (a completion that
		-- actually extends the typed text) becomes the one Enter action — run the
		-- completed command directly without first picking a fill row. Multiple
		-- candidates: keep normal suggestions. Uses its own seen-table so the
		-- suggestion pass below still emits the full list.
		local seenScan, single, count = { [query] = true }, nil, 0
		for _, comp in ipairs(comps) do
			local full = fullCommand(query, comp)
			if full ~= query and not seenScan[full] then
				seenScan[full] = true
				single, count = full, count + 1
			end
		end
		if count == 1 and single then
			results = { runEntry(single, noctalia.tr("snap_subtitle", { command = single })) }
		end
		local seen = { [query] = true }
		for _, comp in ipairs(comps) do
			local full = fullCommand(query, comp)
			if not seen[full] then
				seen[full] = true
				results[#results + 1] = {
					id = "fill:" .. full,
					title = full,
					subtitle = noctalia.tr("suggest_subtitle"),
					glyph = "lightbulb",
				}
			end
			if #results >= 1 + MAX_SUGGESTIONS then
				break
			end
		end
		-- History matches, ranked after shell completions.
		for _, cmd in ipairs(history) do
			if cmd:sub(1, #query) == query and not seen[cmd] then
				seen[cmd] = true
				results[#results + 1] = {
					id = "fill:" .. cmd,
					title = cmd,
					subtitle = noctalia.tr("history_subtitle"),
					glyph = "history",
				}
			end
			if #results >= 1 + MAX_SUGGESTIONS then
				break
			end
		end
		launcher.setResults(query, results)
	end)
end

function onActivate(id)
	if id == "" then
		return
	end

	local kind, value = id:match("^(%a+):(.+)$")
	if not kind or not value then
		noctalia.log("shell-command: onActivate received malformed id: " .. tostring(id))
		return
	end

	if kind == "fill" then
			launcher.setQuery(value)
		elseif kind == "run" then
			recordHistory(value)
			noctalia.runInTerminal(buildCommand(value))
		elseif kind == "cdgo" then
			noctalia.runInTerminal(buildCdCommand(value))
		else
			noctalia.log("shell-command: unknown activation kind: " .. kind)
		end
	end

loadHistory()
