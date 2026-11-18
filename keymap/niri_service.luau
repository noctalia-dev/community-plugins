--!nonstrict
-- Niri data service for Keymap.
-- Niri IPC does not expose keybindings, so this service reads the active KDL
-- config and positional include files. It deliberately performs no subprocesses.

local SNAPSHOT_KEY = "keymap.snapshot"
local REFRESH_REQUEST_KEY = "keymap.refresh_request"
local MAX_FILES = 64
local MAX_SOURCE_BYTES = 512 * 1024
local MAX_HIDDEN_BYTES = 2 * 1024 * 1024
local EXACT_SOURCE_FINGERPRINT = "exact-v1"
-- The host meters every callback with an interrupt-driven CPU budget. Real
-- Niri configs exceed it when parsed in one resume, so the parser yields to
-- the next update tick every few lines. A wall-clock early-out tightens the
-- slice further when the sandbox exposes os.clock; without it, the fixed
-- line budget alone keeps each resume safely small.
local PARSE_LINE_SLICE = 25
local PARSE_SLICE_SECONDS = 0.005
local sliceStartedAt = nil

local function noteSliceStart()
	if type(os) == "table" and type(os.clock) == "function" then
		sliceStartedAt = os.clock()
	else
		sliceStartedAt = nil
	end
end

local function sliceExpired()
	if sliceStartedAt == nil then
		return false
	end
	return os.clock() - sliceStartedAt >= PARSE_SLICE_SECONDS
end

local refreshing = false
local refreshQueued = false
local lastRefreshRequest = nil
local pendingRefresh = false
local parseCoroutine = nil
local parseSource = ""
local parseUpdatedAt = ""
local parseGeneration = 0
local linesThisResume = 0
local fastTicks = false

local function setFastTicks(enabled)
	if fastTicks == enabled then return end
	if type(noctalia.setUpdateInterval) ~= "function" then return end
	fastTicks = enabled
	noctalia.setUpdateInterval(enabled and 60 or 1000)
end

local function config(key, fallback)
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end
	return value:match("^%s*(.-)%s*$") or ""
end

local function env(name)
	return trim(noctalia.getenv(name))
end

-- Shared compositor priority used by all three parser services.
local function detectedCompositor()
	local selected = trim(config("compositor", "auto")):lower()
	if selected ~= "" and selected ~= "auto" then
		if selected == "mango" then
			return "mangowc"
		end
		return selected
	end
	if env("NIRI_SOCKET") ~= "" then
		return "niri"
	end
	if env("HYPRLAND_INSTANCE_SIGNATURE") ~= "" then
		return "hyprland"
	end
	if env("MANGO_INSTANCE_SIGNATURE") ~= "" then
		return "mangowc"
	end
	local desktop = (env("XDG_CURRENT_DESKTOP") .. ":" .. env("XDG_SESSION_DESKTOP")
		.. ":" .. env("DESKTOP_SESSION")):lower()
	if desktop:find("niri", 1, true) ~= nil then
		return "niri"
	end
	if desktop:find("hyprland", 1, true) ~= nil then
		return "hyprland"
	end
	if desktop:find("mangowc", 1, true) ~= nil or desktop:find("mango", 1, true) ~= nil then
		return "mangowc"
	end
	return "unknown"
end

local function normalizePath(path)
	local absolute = path:sub(1, 1) == "/"
	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == ".." then
			if #parts > 0 and parts[#parts] ~= ".." then
				table.remove(parts)
			elseif not absolute then
				parts[#parts + 1] = part
			end
		elseif part ~= "." and part ~= "" then
			parts[#parts + 1] = part
		end
	end
	local normalized = table.concat(parts, "/")
	if absolute then
		return "/" .. normalized
	end
	return normalized ~= "" and normalized or "."
end

local function dirname(path)
	local directory = path:match("^(.*)/[^/]*$")
	return directory ~= nil and directory ~= "" and directory or "."
end

local function expandHome(path)
	if path == "~" then
		return env("HOME")
	end
	if path:sub(1, 2) == "~/" then
		return env("HOME") .. path:sub(2)
	end
	return path
end

local function sourcePath()
	local configured = trim(config("niri_config", ""))
	if configured == "" then
		configured = "~/.config/niri/config.kdl"
	end
	local expanded = normalizePath(expandHome(configured))
	if noctalia.fileExists(expanded) then return expanded end

	local xdg = env("XDG_CONFIG_HOME")
	local niriDir = normalizePath((xdg ~= "" and xdg or (env("HOME") .. "/.config")) .. "/niri")
	local candidates = {
		normalizePath(expandHome(env("NIRI_CONFIG"))),
		normalizePath(niriDir .. "/config.kdl"),
	}
	for _, path in ipairs(candidates) do
		if path ~= "." and noctalia.fileExists(path) then return path end
	end

	local entries = noctalia.listDir(niriDir)
	if type(entries) ~= "table" then return expanded end
	table.sort(entries)
	local bestPath, bestScore = nil, -1
	for _, name in ipairs(entries) do
		if type(name) == "string" and name:match("%.kdl$") and name ~= "keymap.kdl"
			and not name:lower():find("backup", 1, true) then
			local path = normalizePath(niriDir .. "/" .. name)
			local source = noctalia.readFile(path)
			if type(source) == "string" and #source <= MAX_SOURCE_BYTES then
				local _, bindBlocks = source:gsub("%f[%a]binds%s*{", "")
				local _, includes = source:gsub("%f[%a]include%s+", "")
				local score = bindBlocks * 20 + includes * 2
				if name:lower():find("bind", 1, true) then score = score + 5 end
				if score > bestScore then bestPath, bestScore = path, score end
			end
		end
	end
	return bestScore > 0 and bestPath or expanded
end

local function resolveInclude(currentFile, path)
	local expanded = expandHome(path)
	if expanded:sub(1, 1) == "/" then
		return normalizePath(expanded)
	end
	return normalizePath(dirname(currentFile) .. "/" .. expanded)
end

local ESCAPES = {
	n = "\n",
	r = "\r",
	t = "\t",
	["\\"] = "\\",
	['"'] = '"',
	["'"] = "'",
}

local function quotedLiteral(text, startAt)
	local start = startAt or 1
	while start <= #text and text:sub(start, start):match("%s") do
		start = start + 1
	end
	local quote = text:sub(start, start)
	if quote ~= '"' and quote ~= "'" then
		return nil, nil
	end
	local output = {}
	local escaped = false
	for index = start + 1, #text do
		local char = text:sub(index, index)
		if escaped then
			output[#output + 1] = ESCAPES[char] or char
			escaped = false
		elseif char == "\\" then
			escaped = true
		elseif char == quote then
			return table.concat(output), index + 1
		else
			output[#output + 1] = char
		end
	end
	return nil, nil
end

-- Native spawn actions pass an argv vector directly to Niri rather than
-- invoking a shell. Expose only the conservative, single-line KDL form to the
-- editor: `spawn` followed by one or more ordinary quoted string arguments.
-- More elaborate KDL remains visible but read-only so editing can never
-- silently change its execution semantics.
local function editableNativeSpawn(action)
	if type(action) ~= "string" or action:find("[%c]") ~= nil
		or action:sub(1, 5) ~= "spawn" or not action:sub(6, 6):match("%s") then
		return false
	end
	local cursor = 6
	local arguments = 0
	while true do
		while cursor <= #action and action:sub(cursor, cursor):match("%s") do
			cursor = cursor + 1
		end
		if cursor > #action then return arguments > 0 end
		-- Niri's documented argv form uses KDL double-quoted strings. Keeping
		-- this subset strict also lets the writer validate edits without a full
		-- KDL parser.
		if action:sub(cursor, cursor) ~= '"' then return false end
		local _, nextAt = quotedLiteral(action, cursor)
		if nextAt == nil then return false end
		arguments = arguments + 1
		cursor = nextAt
		if cursor <= #action and not action:sub(cursor, cursor):match("%s") then
			return false
		end
	end
end

-- Returns executable code and a trailing // comment. Comment markers inside
-- strings are preserved. KDL block comments remain stateful across lines.
-- Every host call runs under an interrupt-driven CPU budget, so this stays
-- find-based: character loops over plain code are the parser's hot path.
local function stripComments(line, inBlockComment)
	if not inBlockComment and line:find('[/"\'\']') == nil then
		return line, nil, false
	end
	if inBlockComment then
		local closeAt = line:find("*/", 1, true)
		if closeAt == nil then
			return "", nil, true
		end
		local rest, comment, stillInBlock = stripComments(line:sub(closeAt + 2), false)
		return rest, comment, stillInBlock
	end
	-- Find the first interesting token: comment opener or quote.
	local slashAt = line:find("//", 1, true)
	local blockAt = line:find("/*", 1, true)
	local quoteAt = line:find('["\']')
	local cut = nil
	if slashAt ~= nil and (cut == nil or slashAt < cut) then cut = slashAt end
	if blockAt ~= nil and (cut == nil or blockAt < cut) then cut = blockAt end
	if quoteAt ~= nil and (cut == nil or quoteAt < cut) then cut = quoteAt end
	if cut == nil then
		return line, nil, false
	end
	if slashAt == cut then
		return line:sub(1, cut - 1), line:sub(cut + 2), false
	end
	if blockAt == cut then
		local rest, comment, stillInBlock = stripComments(line:sub(cut + 2), true)
		return line:sub(1, cut - 1) .. rest, comment, stillInBlock
	end
	-- Quote first: find its closing quote, then re-scan the remainder.
	local quote = line:sub(cut, cut)
	local scan = cut + 1
	while scan <= #line do
		local nextAt = line:find('[%\\' .. quote .. ']', scan)
		if nextAt == nil then
			-- Unterminated quote: treat the rest as literal code.
			return line, nil, false
		end
		local char = line:sub(nextAt, nextAt)
		if char == "\\" then
			scan = nextAt + 2
		else
			local rest, comment, inBlock = stripComments(line:sub(nextAt + 1), false)
			return line:sub(1, nextAt) .. rest, comment, inBlock
		end
	end
	return line, nil, false
end

local function braceDelta(text)
	local delta = 0
	local quote = nil
	local escaped = false
	-- find-based token hop: orders of magnitude cheaper under the host's
	-- interrupt-driven CPU meter than one sub() call per character.
	if text:find('[{}"\'\\]') == nil then
		return 0
	end
	local index = 1
	while index <= #text do
		local char
		if quote ~= nil then
			local nextAt = text:find('[%\\' .. quote .. ']', index)
			if nextAt == nil then break end
			char = text:sub(nextAt, nextAt)
			if char == "\\" then
				index = nextAt + 2
			else
				quote = nil
				index = nextAt + 1
			end
		else
			local nextAt = text:find('[{}"\'\\]', index)
			if nextAt == nil then break end
			char = text:sub(nextAt, nextAt)
			if char == '"' or char == "'" then
				quote = char
			elseif char == "{" then
				delta = delta + 1
			elseif char == "}" then
				delta = delta - 1
			end
			index = nextAt + 1
		end
	end
	return delta
end

local function firstOpenBrace(text)
	local quote = nil
	if text:find('[{"\'\\]', 1) == nil then
		return nil
	end
	local index = 1
	while index <= #text do
		if quote ~= nil then
			local nextAt = text:find('[%\\' .. quote .. ']', index)
			if nextAt == nil then return nil end
			if text:sub(nextAt, nextAt) == "\\" then
				index = nextAt + 2
			else
				quote = nil
				index = nextAt + 1
			end
		else
			local nextAt = text:find('[{"\'\\]', index)
			if nextAt == nil then return nil end
			local char = text:sub(nextAt, nextAt)
			if char == '"' or char == "'" then
				quote = char
				index = nextAt + 1
			elseif char == "{" then
				return nextAt
			else
				index = nextAt + 1
			end
		end
	end
	return nil
end

local function contentBeforeOuterClose(text)
	local depth = 1
	local quote = nil
	local index = 1
	while index <= #text do
		if quote ~= nil then
			local nextAt = text:find('[%\\' .. quote .. ']', index)
			if nextAt == nil then return text end
			if text:sub(nextAt, nextAt) == "\\" then
				index = nextAt + 2
			else
				quote = nil
				index = nextAt + 1
			end
		else
			local nextAt = text:find('[{}"\'\\]', index)
			if nextAt == nil then return text end
			local char = text:sub(nextAt, nextAt)
			if char == '"' or char == "'" then
				quote = char
			elseif char == "{" then
				depth = depth + 1
			elseif char == "}" then
				depth = depth - 1
				if depth == 0 then
					return text:sub(1, nextAt - 1)
				end
			end
			index = nextAt + 1
		end
	end
	return text
end

local function rawActionMatches(snippet, action)
	local openAt = firstOpenBrace(snippet)
	if openAt == nil then return false end
	local body = trim(contentBeforeOuterClose(snippet:sub(openAt + 1)))
	body = trim(body:gsub(";%s*$", ""))
	return body == trim(action)
end

local function includeNode(code)
	local rest = code:match("^%s*include%s+(.+)$")
	if rest == nil then
		return nil, false
	end
	local optional = rest:match("%f[%w]optional%s*=%s*true%f[^%w]") ~= nil
	local quoteAt = rest:find('"', 1, true) or rest:find("'", 1, true)
	if quoteAt == nil then
		return nil, optional
	end
	return quotedLiteral(rest, quoteAt), optional
end

local MODIFIER_ALIASES = {
	Control = "Ctrl", Ctrl = "Ctrl", Win = "Super", Super = "Super",
	Mod = "Mod", Alt = "Alt", Shift = "Shift",
	ISO_Level3_Shift = "Mod5", Mod5 = "Mod5",
	ISO_Level5_Shift = "ISO_Level5_Shift",
}

-- Display names shared with the Hyprland and MangoWC services. Keep the three
-- tables identical so a key reads the same no matter which compositor reports
-- it.
local KEY_NAMES = {
	RETURN = "Enter", SPACE = "Space", ESCAPE = "Esc", PRINT = "PrtSc",
	PRIOR = "PgUp", NEXT = "PgDn",
	BRACKETLEFT = "[", BRACKETRIGHT = "]",
	LEFT = "Left", RIGHT = "Right", UP = "Up", DOWN = "Down",
	EQUAL = "=", MINUS = "-", PLUS = "+",
	COMMA = ",", PERIOD = ".", SEMICOLON = ";", APOSTROPHE = "'", GRAVE = "`",
	SLASH = "/", BACKSLASH = "\\",
	WHEELSCROLLUP = "Scroll Up", WHEELSCROLLDOWN = "Scroll Down",
	WHEELSCROLLLEFT = "Scroll Left", WHEELSCROLLRIGHT = "Scroll Right",
	TOUCHPADSCROLLUP = "Touchpad Up", TOUCHPADSCROLLDOWN = "Touchpad Down",
	TOUCHPADSCROLLLEFT = "Touchpad Left", TOUCHPADSCROLLRIGHT = "Touchpad Right",
	MOUSELEFT = "Left Click", MOUSERIGHT = "Right Click", MOUSEMIDDLE = "Middle Click",
	MOUSEFORWARD = "Mouse Forward", MOUSEBACK = "Mouse Back",
	MOUSE_DOWN = "Scroll Down", MOUSE_UP = "Scroll Up",
	["MOUSE:272"] = "Left Click", ["MOUSE:273"] = "Right Click", ["MOUSE:274"] = "Middle Click",
	XF86AUDIORAISEVOLUME = "Vol Up", XF86AUDIOLOWERVOLUME = "Vol Down",
	XF86AUDIOMUTE = "Mute", XF86AUDIOMICMUTE = "Mic Mute",
	XF86AUDIOPLAY = "Play", XF86AUDIOPAUSE = "Pause", XF86AUDIONEXT = "Next",
	XF86AUDIOPREV = "Prev", XF86AUDIOSTOP = "Stop", XF86AUDIOMEDIA = "Media",
	XF86MONBRIGHTNESSUP = "Bright Up", XF86MONBRIGHTNESSDOWN = "Bright Down",
	XF86CALCULATOR = "Calc", XF86MAIL = "Mail", XF86SEARCH = "Search",
	XF86EXPLORER = "Files", XF86WWW = "Browser", XF86HOMEPAGE = "Home",
	XF86FAVORITES = "Favorites", XF86POWEROFF = "Power", XF86SLEEP = "Sleep",
	XF86EJECT = "Eject",
}

local function splitCombo(combo)
	local modifiers = {}
	local mainKey = ""
	local signature = {}
	for part in combo:gmatch("[^+]+") do
		local item = trim(part)
		local modifier = MODIFIER_ALIASES[item]
		if modifier ~= nil then
			modifiers[#modifiers + 1] = modifier
			signature[#signature + 1] = modifier:lower()
		elseif item ~= "" then
			mainKey = item
			signature[#signature + 1] = item:lower()
		end
	end
	return modifiers, KEY_NAMES[mainKey:upper()] or mainKey, mainKey, table.concat(signature, "+")
end

local function bindHeader(prefix)
	local header = trim(prefix)
	if header:sub(1, 1) == '"' or header:sub(1, 1) == "'" then
		local combo, nextAt = quotedLiteral(header, 1)
		return combo, combo ~= nil and trim(header:sub(nextAt)) or nil
	end
	local combo, attributes = header:match("^(%S+)%s*(.-)%s*$")
	return combo, attributes
end

local function titleAttribute(attributes)
	local _, valueAt = (attributes or ""):find("hotkey%-overlay%-title%s*=%s*")
	if valueAt == nil then
		return nil
	end
	local suffix = attributes:sub(valueAt + 1)
	if suffix:match("^%s*null%f[^%w_]") then
		return nil
	end
	local value = quotedLiteral(suffix, 1)
	if value == nil then
		return nil
	end
	value = value:gsub("<[^>]*>", "")
	value = value:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
	return trim(value)
end

local ACTION_CATEGORIES = {
	spawn = "category.niri.applications", ["spawn-sh"] = "category.niri.applications",
	["focus-column"] = "category.niri.column_navigation", ["focus-window"] = "category.niri.window_focus",
	["focus-workspace"] = "category.niri.workspace_navigation",
	["move-column-to-workspace"] = "category.niri.workspace_management",
	["move-window-to-workspace"] = "category.niri.workspace_management",
	["move-column"] = "category.niri.move_columns", ["move-window"] = "category.niri.move_windows",
	["consume-window"] = "category.niri.window_management", ["expel-window"] = "category.niri.window_management",
	["close-window"] = "category.niri.window_management", ["fullscreen-window"] = "category.niri.window_management",
	["maximize-column"] = "category.niri.column_management", ["set-column-width"] = "category.niri.column_width",
	["switch-preset-column-width"] = "category.niri.column_width", ["reset-window-height"] = "category.niri.window_size",
	screenshot = "category.niri.screenshots", ["power-off-monitors"] = "category.niri.power",
	["power-on-monitors"] = "category.niri.power", quit = "category.niri.system",
	["toggle-animation"] = "category.niri.animations",
}

local function actionVerb(action)
	return action:match("^%s*([%w_-]+)") or ""
end

local function actionDescription(action, verb)
	if verb == "spawn" or verb == "spawn-sh" then
		local command = quotedLiteral(action:sub(#verb + 1), 1)
		if command ~= nil and command ~= "" then
			return noctalia.tr("actions.run", { command = command })
		end
	end
	return noctalia.tr("actions.native", { action = trim(action:gsub(";%s*$", "")) })
end

local function actionCategory(action, verb)
	local lower = action:lower()
	if lower:find("noctalia", 1, true) ~= nil
		and (lower:find(" msg ", 1, true) ~= nil or lower:find(" ipc ", 1, true) ~= nil)
	then
		return noctalia.tr("category.noctalia")
	end
	local best = nil
	local bestLength = -1
	for prefix, category in pairs(ACTION_CATEGORIES) do
		if verb:sub(1, #prefix) == prefix and #prefix > bestLength then
			best = category
			bestLength = #prefix
		end
	end
	return noctalia.tr(best or "category.other")
end

local function slug(value)
	local id = value:lower():gsub("[^%a%d]+", "-"):gsub("^-+", ""):gsub("-+$", "")
	return id ~= "" and id or "category"
end

local function xorByte(left, right)
	local result = 0
	local place = 1
	for _ = 1, 8 do
		local leftBit = left % 2
		local rightBit = right % 2
		if leftBit ~= rightBit then result = result + place end
		left = math.floor(left / 2)
		right = math.floor(right / 2)
		place = place * 2
	end
	return result
end

local xorByteFast = type(bit32) == "table" and type(bit32.bxor) == "function" and bit32.bxor or xorByte

-- Splitting the FNV prime (0x01000193) into 2^24 + 403 keeps every
-- intermediate below the exact integer limit of a Lua/Luau number. Luau's
-- native bit32 fast path avoids eight interpreted operations for every byte;
-- the arithmetic fallback keeps the parser usable in plain-Lua tests.
local function stableFingerprint(value)
	local hash = 2166136261
	for index = 1, #value do
		local low = hash % 256
		hash = hash - low + xorByteFast(low, value:byte(index))
		hash = (hash * 403 + (hash % 256) * 16777216) % 4294967296
	end
	return string.format("%08x", hash)
end

local function stableBindId(fields)
	local identity = {}
	for _, value in ipairs(fields) do
		local field = tostring(value or "")
		identity[#identity + 1] = tostring(#field) .. ":" .. field
	end
	return "niri:" .. table.concat(identity)
end

local function sourceLines(source)
	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
	return lines
end

local function hexDecode(value)
	if value == "" or #value % 2 ~= 0 or value:find("[^0-9a-f]") ~= nil then return nil end
	local output = {}
	for index = 1, #value, 2 do output[#output + 1] = string.char(tonumber(value:sub(index, index + 1), 16)) end
	return table.concat(output)
end

local function hiddenBlockAt(lines, startLine)
	local namespace = "^([\t ]*)// Keymap hidden "
	if lines[startLine]:match(namespace) == nil then return nil, startLine, false end
	local indent, blockId, originalFingerprint = lines[startLine]:match(
		namespace .. "v1 begin ([0-9a-f]+) ([0-9a-f]+)$"
	)
	if indent == nil or #blockId ~= 8 or #originalFingerprint ~= 8 then return nil, startLine, true end
	local marker = indent .. "// Keymap hidden v1"
	local escaped = marker:gsub("(%W)", "%%%1")
	local encoded, cursor = {}, startLine + 1
	while cursor <= #lines do
		local chunk = lines[cursor]:match("^" .. escaped .. " data ([0-9a-f]+)$")
		if chunk ~= nil then
			if #chunk > 96 or #chunk % 2 ~= 0 then return nil, cursor, true end
			encoded[#encoded + 1] = chunk
			cursor = cursor + 1
		else
			local endId = lines[cursor]:match("^" .. escaped .. " end ([0-9a-f]+)$")
			if endId == nil then return nil, math.max(startLine, cursor - 1), true end
			local original = hexDecode(table.concat(encoded))
			if #encoded == 0 or endId ~= blockId or original == nil or original == ""
				or #original > MAX_HIDDEN_BYTES or stableFingerprint(original) ~= originalFingerprint
				or stableFingerprint("Niri\0" .. original) ~= blockId then return nil, cursor, true end
			return { block_id = blockId, original = original, original_fingerprint = originalFingerprint,
				raw_snippet = table.concat(lines, "\n", startLine, cursor) }, cursor, true
		end
	end
	return nil, #lines, true
end

local function hiddenTarget(block, path, startLine, endLine, inheritedCategory)
	local original = block.original
	local markedCategory = original:match(
		"^%s*//%s*Keymap bind%-category:%s*([^\n]-)%s*\n"
	)
	local codeLines, inBlock = {}, false
	for raw in (original .. "\n"):gmatch("([^\n]*)\n") do
		local code
		code, _, inBlock = stripComments(raw, inBlock)
		if trim(code) ~= "" then codeLines[#codeLines + 1] = code end
	end
	local code = table.concat(codeLines, "\n")
	local openAt = firstOpenBrace(code)
	local combo, attributes, action = "", "", ""
	if openAt ~= nil then
		combo, attributes = bindHeader(code:sub(1, openAt - 1))
		action = contentBeforeOuterClose(code:sub(openAt + 1))
	end
	combo, attributes = combo or "", attributes or ""
	local modifiers, key, _, signature = splitCombo(combo)
	local normalizedAction = trim(action):gsub(";%s*$", "")
	local verb = actionVerb(normalizedAction)
	local description = titleAttribute(attributes)
	if description == nil or description == "" then description = actionDescription(normalizedAction, verb) end
	local command = verb == "spawn-sh" and (quotedLiteral(normalizedAction:sub(#verb + 1), 1) or "") or ""
	return {
		hidden = true, id = "hidden:niri:" .. stableFingerprint(path .. "\0" .. tostring(startLine) .. "\0" .. block.block_id),
		source = path, line = startLine, start_line = startLine, end_line = endLine,
		raw_snippet = block.raw_snippet, fingerprint = stableFingerprint(block.raw_snippet),
		original_fingerprint = block.original_fingerprint, modifiers = modifiers, key = key,
		description = description, dispatcher = verb, command = command, action = normalizedAction,
		activation = "press", category = markedCategory or inheritedCategory or actionCategory(normalizedAction, verb),
		capabilities = { restore = true, delete = true }, _signature = signature,
	}
end

-- Clean records stay editable, so numeric runs keep their source provenance
-- through the displayed range (the writer re-checks every constituent snippet
-- before replacing the whole run).

local function cleanBind(bind)
	return {
		id = bind.id, modifiers = bind.modifiers, key = bind.key,
		description = bind.description, dispatcher = bind.dispatcher,
		activation = "press", command = bind.command, command_kind = bind.command_kind,
		action = bind.action,
		has_overlay_title = bind.has_overlay_title,
		source = bind.source, start_line = bind.start_line, end_line = bind.end_line,
		raw_snippet = bind.raw_snippet, fingerprint = bind.fingerprint,
		managed = bind.managed == true, capabilities = bind.capabilities,
	}
end

local function mergeSequential(binds)
	local groups = {}
	for index, bind in ipairs(binds) do
		local number = bind._rawKey:match("^%d+$") and tonumber(bind._rawKey) or nil
		local template, replacements = bind.description:gsub("%f[%d]%d+%f[%D]", "%%N%%")
		if number ~= nil and replacements > 0 then
			local signature = table.concat(bind.modifiers, "+") .. "|" .. bind.dispatcher .. "|" .. template
			groups[signature] = groups[signature] or {}
			groups[signature][#groups[signature] + 1] = { index = index, number = number, bind = bind }
		end
	end
	local replacements = {}
	local skipped = {}
	for _, group in pairs(groups) do
		table.sort(group, function(a, b)
			return a.number == b.number and a.index < b.index or a.number < b.number
		end)
		local runStart = 1
		for cursor = 2, #group + 1 do
			local continues = cursor <= #group and group[cursor].number == group[cursor - 1].number + 1
			if not continues then
				if cursor - runStart >= 3 then
					local first = group[runStart]
					local last = group[cursor - 1]
					local range = tostring(first.number) .. "-" .. tostring(last.number)
					local merged = cleanBind(first.bind)
					merged.id = "range:" .. first.bind.id .. ":" .. last.bind.id
					merged.key = range
					merged.description = first.bind.description:gsub("%f[%d]%d+%f[%D]", range, 1)
					replacements[first.index] = merged
					for item = runStart + 1, cursor - 1 do
						skipped[group[item].index] = true
					end
				end
				runStart = cursor
			end
		end
	end
	local output = {}
	for index, bind in ipairs(binds) do
		if replacements[index] ~= nil then
			output[#output + 1] = replacements[index]
		elseif not skipped[index] then
			output[#output + 1] = cleanBind(bind)
		end
	end
	return output
end

-- Collapse binds that trigger the same action into one row carrying every
-- key combination (for example "Close Window" on Super+W and Alt+F4).
-- Grouped rows lose edit provenance on purpose: one row cannot be rewritten
-- to a single source location.
local function mergeSimilar(binds)
	local grouped = {}
	local order = {}
	for index, bind in ipairs(binds) do
		local signature = "action:"
			.. tostring(bind.dispatcher) .. "\0" .. tostring(bind.action)
		local group = grouped[signature]
		if group == nil then
			group = { first = index, parts = {} }
			grouped[signature] = group
			order[#order + 1] = signature
		end
		group.parts[#group.parts + 1] = bind
	end
	local mergedAt = {}
	local swallowed = {}
	for _, signature in ipairs(order) do
		local group = grouped[signature]
		if #group.parts > 1 then
			local first = group.parts[1]
			local combos = {}
			local ids = {}
			for _, part in ipairs(group.parts) do
				combos[#combos + 1] = { modifiers = part.modifiers, key = part.key }
				ids[#ids + 1] = part.id
			end
			mergedAt[group.first] = {
				id = "similar:" .. table.concat(ids, "|"),
				modifiers = {},
				key = combos[1].key,
				combos = combos,
				description = first.description,
				dispatcher = first.dispatcher,
				activation = "press",
				command = first.command,
				action = first.action,
				capabilities = {
					combo = false, category = false, description = false,
					command = false, activation = false,
				},
			}
			for partIndex = 2, #group.parts do
				swallowed[group.parts[partIndex]] = true
			end
		end
	end
	local output = {}
	for index, bind in ipairs(binds) do
		if mergedAt[index] ~= nil then
			output[#output + 1] = mergedAt[index]
		elseif not swallowed[bind] then
			output[#output + 1] = bind
		end
	end
	return output
end

local function buildCategories(records)
	local showUndescribed = config("show_undescribed", true) == true
	local shouldMerge = config("merge_sequential", true) == true
	local shouldMergeSimilar = config("merge_similar", false) == true
	local byName = {}
	local order = {}
	local seen = {}
	local total = 0
	for _, bind in ipairs(records) do
		if not bind._overridden and (showUndescribed or bind.has_overlay_title ~= false) then
			if not seen[bind._category] then
				seen[bind._category] = true
				order[#order + 1] = bind._category
			end
			byName[bind._category] = byName[bind._category] or {}
			byName[bind._category][#byName[bind._category] + 1] = bind
			total = total + 1
		end
	end
	local categories = {}
	local usedIds = {}
	for _, name in ipairs(order) do
		local baseId = slug(name)
		local id = baseId
		local suffix = 2
		while usedIds[id] do
			id = baseId .. "-" .. tostring(suffix)
			suffix = suffix + 1
		end
		usedIds[id] = true
		local binds = byName[name]
		local output = {}
		if shouldMerge then
			output = mergeSequential(binds)
		else
			for _, bind in ipairs(binds) do
				output[#output + 1] = cleanBind(bind)
			end
		end
		if shouldMergeSimilar then
			output = mergeSimilar(output)
		end
		categories[#categories + 1] = { id = id, name = name, binds = output }
	end
	return categories, total
end

local function parseBind(combo, attributes, action, category, records, activeByCombo, provenance)
	local modifiers, key, rawKey, signature = splitCombo(combo)
	local normalizedAction = trim(action):gsub(";%s*$", "")
	local verb = actionVerb(normalizedAction)
	if rawKey == "" or verb == "" then
		return
	end
	local previous = activeByCombo[signature]
	if previous ~= nil then
		previous._overridden = true
	end
	local overlayTitle = titleAttribute(attributes)
	local hasOverlayTitle = overlayTitle ~= nil and overlayTitle ~= ""
	local description = hasOverlayTitle and overlayTitle or actionDescription(normalizedAction, verb)
	local rawSnippet = provenance.raw_snippet or ""
	local command = ""
	local commandKind = "shell"
	if verb == "spawn-sh" then
		command = quotedLiteral(normalizedAction:sub(#verb + 1), 1) or ""
	elseif verb == "spawn" and editableNativeSpawn(normalizedAction)
		and rawActionMatches(rawSnippet, normalizedAction) then
		command = normalizedAction
		commandKind = "native"
	end
	local bind = {
		id = stableBindId({ signature, verb, normalizedAction }),
		modifiers = modifiers, key = key, description = description, dispatcher = verb,
		activation = "press", command = command, command_kind = commandKind, action = normalizedAction,
		has_overlay_title = hasOverlayTitle,
		source = provenance.source, start_line = provenance.start_line,
		end_line = provenance.end_line, raw_snippet = rawSnippet,
		fingerprint = EXACT_SOURCE_FINGERPRINT,
		managed = provenance.source:match("([^/]+)$") == "keymap.kdl",
		capabilities = {
			combo = true, category = true, description = true,
			command = verb == "spawn-sh" or commandKind == "native",
			native_spawn = commandKind == "native", activation = false,
		},
		_rawKey = rawKey, _category = category or actionCategory(normalizedAction, verb),
	}
	records[#records + 1] = bind
	activeByCombo[signature] = bind
end

local function parseConfig(root, rootSource)
	local records = {}
	local hidden = {}
	local activeByCombo = {}
	local warnings = {}
	local warningSeen = {}
	local visiting = {}
	local filesRead = 0
	local fatalError = nil

	local function warn(value)
		if not warningSeen[value] then
			warningSeen[value] = true
			warnings[#warnings + 1] = value
		end
	end

	local parseFile
	parseFile = function(path, optional, providedSource)
		if visiting[path] then
			warn("niri_include_cycle:" .. path)
			return
		end
		if filesRead >= MAX_FILES then
			warn("niri_file_limit_reached")
			return
		end
		local source = providedSource or noctalia.readFile(path)
		if type(source) ~= "string" then
			warn((optional and "niri_optional_include_missing:" or "niri_include_unreadable:") .. path)
			if not optional then
				fatalError = "niri_required_include_missing"
			end
			return
		end
		filesRead = filesRead + 1
		visiting[path] = true
		if #source > MAX_SOURCE_BYTES then
			source = source:sub(1, MAX_SOURCE_BYTES)
			warn("niri_source_truncated:" .. path)
		end

		local inBlockComment = false
		local topDepth = 0
		local inBinds = false
		local bindsDepth = 0
		local currentCategory = nil
		local pendingBindCategory = nil
		local pendingMarkerLine = nil
		local pendingMarkerRaw = nil
		local currentBind = nil
		local slashdashDepth = nil
		local lineNumber = 0
		-- Hidden sentinels are uncommon. Avoid a second character-by-character
		-- pass over every ordinary config: on large stock Niri configs that pass
		-- alone can consume a substantial part of Luau's callback CPU budget.
		if source:find("// Keymap hidden ", 1, true) ~= nil then
			local hiddenLines = sourceLines(source)
			local hiddenCategory = nil
			local hiddenCursor = 1
			while hiddenCursor <= #hiddenLines do
				local block, blockEnd, candidate = hiddenBlockAt(hiddenLines, hiddenCursor)
				if candidate then
					if block == nil then
						warn("hidden_block_invalid:" .. path .. ":" .. tostring(hiddenCursor))
					else
						hidden[#hidden + 1] = hiddenTarget(block, path, hiddenCursor, blockEnd, hiddenCategory)
					end
					hiddenCursor = blockEnd + 1
				else
					local _, comment = stripComments(hiddenLines[hiddenCursor], false)
					local label = type(comment) == "string" and comment:match('^%s*#?%s*"([^\"]+)"%s*$') or nil
					if label ~= nil and label ~= "" then hiddenCategory = label end
					hiddenCursor = hiddenCursor + 1
				end
			end
		end

		-- Most split Niri setups also include theme, output, input, and window
		-- rule files. Once hidden sentinels have been handled, a file without
		-- either keyword cannot contribute binds or extend the include graph.
		-- This cheap rejection keeps unrelated config files out of the parser's
		-- character-level brace/comment scan.
		if source:find("binds", 1, true) == nil and source:find("include", 1, true) == nil then
			visiting[path] = nil
			return
		end

		local function finishBind()
			local action = contentBeforeOuterClose(table.concat(currentBind.parts, "\n"))
			parseBind(
				currentBind.combo, currentBind.attributes, action, currentBind.category,
				records, activeByCombo,
				{
					source = path, start_line = currentBind.start_line,
					end_line = lineNumber, raw_snippet = table.concat(currentBind.raw_lines, "\n"),
				}
			)
			currentBind = nil
		end

		for rawLine in (source .. "\n"):gmatch("([^\n]*)\n") do
			lineNumber = lineNumber + 1
			-- Yield once a slice gets expensive so a multi-file parse never
			-- holds the callback past its budget; update() resumes on the
			-- next tick with a fresh window. The counter spans included files,
			-- so many short includes cannot dodge the yield check.
			linesThisResume = linesThisResume + 1
			if linesThisResume >= PARSE_LINE_SLICE or sliceExpired() then
				linesThisResume = 0
				coroutine.yield()
			end
			local code, comment
			code, comment, inBlockComment = stripComments(rawLine, inBlockComment)
			local stripped = trim(code)
			if slashdashDepth ~= nil then
				slashdashDepth = slashdashDepth + braceDelta(code)
				if slashdashDepth <= 0 then slashdashDepth = nil end
			elseif stripped:sub(1, 2) == "/-" then
				local delta = braceDelta(stripped:sub(3))
				if delta > 0 then slashdashDepth = delta end
			elseif inBinds then
				local delta = braceDelta(code)
				if currentBind ~= nil then
					currentBind.parts[#currentBind.parts + 1] = code
					currentBind.raw_lines[#currentBind.raw_lines + 1] = rawLine
					currentBind.depth = currentBind.depth + delta
					bindsDepth = bindsDepth + delta
					if currentBind.depth <= 0 then finishBind() end
				else
					local bindCategory = type(comment) == "string" and comment:match(
						"^%s*Keymap bind%-category:%s*(.-)%s*$"
					) or nil
					if bindCategory ~= nil and bindCategory ~= "" then
						pendingBindCategory = bindCategory
						pendingMarkerLine = lineNumber
						pendingMarkerRaw = rawLine
					else
						local label = type(comment) == "string" and comment:match('^%s*#?%s*"([^\"]+)"%s*$') or nil
						if label ~= nil and label ~= "" then currentCategory = label end
					end
					if stripped ~= "" and not stripped:match("^}") then
						local openAt = firstOpenBrace(code)
						if openAt ~= nil then
							local combo, attributes = bindHeader(code:sub(1, openAt - 1))
							if combo ~= nil then
								local actionStart = code:sub(openAt + 1)
								currentBind = {
									combo = combo, attributes = attributes,
									category = pendingBindCategory or currentCategory,
									parts = { actionStart }, depth = 1 + braceDelta(actionStart),
									start_line = pendingMarkerLine or lineNumber,
									raw_lines = pendingMarkerRaw ~= nil and { pendingMarkerRaw, rawLine } or { rawLine },
								}
								pendingBindCategory = nil
								pendingMarkerLine = nil
								pendingMarkerRaw = nil
								if currentBind.depth <= 0 then finishBind() end
							else
								pendingBindCategory = nil
								pendingMarkerLine = nil
								pendingMarkerRaw = nil
							end
						end
					end
					bindsDepth = bindsDepth + delta
				end
				if bindsDepth <= 0 then
					inBinds = false
					bindsDepth = 0
					currentCategory = nil
					pendingBindCategory = nil
					pendingMarkerLine = nil
					pendingMarkerRaw = nil
					currentBind = nil
				end
			else
				if topDepth == 0 then
					local includePath, optionalInclude = includeNode(code)
					if includePath ~= nil then
						parseFile(resolveInclude(path, includePath), optionalInclude)
					end
					if code:match("^%s*binds%s*{") then
						inBinds = true
						bindsDepth = braceDelta(code)
						currentCategory = nil
					end
				end
				if not inBinds then topDepth = topDepth + braceDelta(code) end
			end
		end
		visiting[path] = nil
	end

	parseFile(root, false, rootSource)
	local categories, total = buildCategories(records)
	return categories, total, hidden, warnings, fatalError
end

local function snapshot(status, source, errorCode, categories, total, warnings, updatedAt, hidden, errorDetail)
	return {
		status = status,
		error = errorCode or "",
		error_detail = errorDetail or "",
		compositor = "Niri",
		source = source,
		updated_at = updatedAt or "",
		total = total or 0,
		categories = categories or {},
		warnings = warnings or {},
		hidden = hidden or {},
	}
end

local function finishRefresh()
	refreshing = false
	if refreshQueued then
		refreshQueued = false
		refresh()
	end
end

function refresh()
	-- Each compositor service receives the same events. Only the selected or
	-- auto-detected service may publish, preventing snapshot races.
	if detectedCompositor() ~= "niri" then
		-- Invalidate any in-flight parse from a previous compositor selection:
		-- its result must never overwrite the new owner's snapshot.
		parseGeneration = parseGeneration + 1
		parseCoroutine = nil
		refreshing = false
		refreshQueued = false
		setFastTicks(false)
		return
	end
	if refreshing then
		refreshQueued = true
		return
	end
	refreshing = true
	parseGeneration = parseGeneration + 1
	local generation = parseGeneration
	local source = sourcePath()
	parseSource = source
	parseUpdatedAt = os.date("%H:%M:%S")
	-- The panel keeps its last ready snapshot while this status is loading.
	-- Do not copy the full bind tree through the shared-state serializer merely
	-- to replace it again at the end of this refresh.
	noctalia.state.set(
		SNAPSHOT_KEY,
		snapshot("loading", source, "", {}, 0, {}, "", {})
	)

	local rootSource = noctalia.readFile(source)
	if type(rootSource) ~= "string" then
		noctalia.state.set(
			SNAPSHOT_KEY,
			snapshot("error", source, "niri_config_unreadable", {}, 0, {}, parseUpdatedAt)
		)
		finishRefresh()
		return
	end

	parseCoroutine = coroutine.create(function()
		local categories, total, hidden, warnings, fatalError = parseConfig(source, rootSource)
		if generation ~= parseGeneration then
			-- A compositor switch or a newer refresh superseded this parse.
			return
		end
		if fatalError ~= nil then
			noctalia.state.set(
				SNAPSHOT_KEY,
				snapshot("error", source, fatalError, {}, 0, warnings, parseUpdatedAt)
			)
		elseif total == 0 and #hidden == 0 then
			noctalia.state.set(
				SNAPSHOT_KEY,
				snapshot("error", source, "niri_no_binds", {}, 0, warnings, parseUpdatedAt)
			)
		else
			noctalia.state.set(
				SNAPSHOT_KEY,
				snapshot("ready", source, "", categories, total, warnings, parseUpdatedAt, hidden)
			)
		end
	end)
	-- Resume once within this budget; a large config suspends and continues on
	pumpParse()
end

-- Resume the in-flight parse until it either finishes or yields. Called from
-- refresh() and from update() ticks, so every slice runs inside its own
-- budget window.
function pumpParse()
	if parseCoroutine == nil then
		return
	end
	noteSliceStart()
	linesThisResume = 0
	local ok, err = coroutine.resume(parseCoroutine)
	if not ok then
		parseCoroutine = nil
		setFastTicks(false)
		noctalia.state.set(
			SNAPSHOT_KEY,
			snapshot("error", parseSource, "niri_parse_failed", {}, 0, {}, parseUpdatedAt, {}, tostring(err))
		)
		finishRefresh()
		return
	end
	if coroutine.status(parseCoroutine) == "dead" then
		parseCoroutine = nil
		setFastTicks(false)
		finishRefresh()
		return
	end
	-- Still suspended: left parked for the next update() tick.
	setFastTicks(true)
end

function onIpc(event, _payload)
	if event == "refresh" then
		local current = tonumber(noctalia.state.get(REFRESH_REQUEST_KEY)) or 0
		noctalia.state.set(REFRESH_REQUEST_KEY, current + 1)
	end
end

function onConfigChanged()
	pendingRefresh = true
end

-- The watch callback only records intent and acknowledges the request with a
-- cheap loading marker: parsing inside the 25ms callback slot risks
-- exhausting the budget when other work shares it, and a budget abort there
-- would leave the snapshot stuck at "loading". The periodic update tick
-- performs the actual refresh in slices, one budget window at a time.
function update()
	if pendingRefresh then
		pendingRefresh = false
		refresh()
	elseif parseCoroutine ~= nil then
		pumpParse()
	else
		setFastTicks(false)
	end
end

-- Refresh requests issued before this service loaded are covered by the boot
-- refresh below; the watcher only reacts to genuinely new counter values,
-- ignoring host echoes of a value this service already handled.
lastRefreshRequest = noctalia.state.get(REFRESH_REQUEST_KEY)
noctalia.state.watch(REFRESH_REQUEST_KEY, function(request)
	if request ~= lastRefreshRequest then
		lastRefreshRequest = request
		pendingRefresh = true
		-- Acknowledge immediately so the panel leaves its ready state even
		-- though the parse itself waits for the update tick. Keep the previous
		-- categories out of the marker: the panel hides them while loading.
		if detectedCompositor() == "niri" then
			local current = noctalia.state.get(SNAPSHOT_KEY)
			local source = type(current) == "table" and current.source or nil
			noctalia.state.set(SNAPSHOT_KEY, snapshot("loading", source, "", {}, 0, {}, "", {}))
		end
	end
end)

refresh()
