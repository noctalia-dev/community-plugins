--!nonstrict
-- Niri data service for Keymap.
-- Niri IPC does not expose keybindings, so this service reads the active KDL
-- config and positional include files. It deliberately performs no subprocesses.

local SNAPSHOT_KEY = "keymap.snapshot"
local REFRESH_REQUEST_KEY = "keymap.refresh_request"
local MAX_FILES = 64
local MAX_SOURCE_BYTES = 512 * 1024
local MAX_HIDDEN_BYTES = 2 * 1024 * 1024

local refreshing = false
local refreshQueued = false

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

-- Returns executable code and a trailing // comment. Comment markers inside
-- strings are preserved. KDL block comments remain stateful across lines.
local function stripComments(line, inBlockComment)
	local code = {}
	local comment = nil
	local quote = nil
	local escaped = false
	local index = 1
	while index <= #line do
		local char = line:sub(index, index)
		local pair = line:sub(index, index + 1)
		if inBlockComment then
			if pair == "*/" then
				inBlockComment = false
				index = index + 2
			else
				index = index + 1
			end
		elseif quote ~= nil then
			code[#code + 1] = char
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == quote then
				quote = nil
			end
			index = index + 1
		elseif char == '"' or char == "'" then
			quote = char
			code[#code + 1] = char
			index = index + 1
		elseif pair == "//" then
			comment = line:sub(index + 2)
			break
		elseif pair == "/*" then
			inBlockComment = true
			index = index + 2
		else
			code[#code + 1] = char
			index = index + 1
		end
	end
	return table.concat(code), comment, inBlockComment
end

local function braceDelta(text)
	local delta = 0
	local quote = nil
	local escaped = false
	for index = 1, #text do
		local char = text:sub(index, index)
		if quote ~= nil then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "{" then
			delta = delta + 1
		elseif char == "}" then
			delta = delta - 1
		end
	end
	return delta
end

local function firstOpenBrace(text)
	local quote = nil
	local escaped = false
	for index = 1, #text do
		local char = text:sub(index, index)
		if quote ~= nil then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "{" then
			return index
		end
	end
	return nil
end

local function contentBeforeOuterClose(text)
	local depth = 1
	local quote = nil
	local escaped = false
	for index = 1, #text do
		local char = text:sub(index, index)
		if quote ~= nil then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "{" then
			depth = depth + 1
		elseif char == "}" then
			depth = depth - 1
			if depth == 0 then
				return text:sub(1, index - 1)
			end
		end
	end
	return text
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

local KEY_NAMES = {
	RETURN = "Enter", SPACE = "Space", ESCAPE = "Esc", PRINT = "PrtSc",
	PRIOR = "PgUp", NEXT = "PgDn",
	WHEELSCROLLUP = "Scroll Up", WHEELSCROLLDOWN = "Scroll Down",
	WHEELSCROLLLEFT = "Scroll Left", WHEELSCROLLRIGHT = "Scroll Right",
	TOUCHPADSCROLLUP = "Touchpad Up", TOUCHPADSCROLLDOWN = "Touchpad Down",
	TOUCHPADSCROLLLEFT = "Touchpad Left", TOUCHPADSCROLLRIGHT = "Touchpad Right",
	MOUSELEFT = "Left Click", MOUSERIGHT = "Right Click", MOUSEMIDDLE = "Middle Click",
	MOUSEFORWARD = "Mouse Forward", MOUSEBACK = "Mouse Back",
	XF86AUDIORAISEVOLUME = "Vol Up", XF86AUDIOLOWERVOLUME = "Vol Down",
	XF86AUDIOMUTE = "Mute", XF86AUDIOMICMUTE = "Mic Mute",
	XF86AUDIOPLAY = "Play", XF86AUDIOPAUSE = "Pause", XF86AUDIONEXT = "Next",
	XF86AUDIOPREV = "Prev", XF86AUDIOSTOP = "Stop",
	XF86MONBRIGHTNESSUP = "Bright Up", XF86MONBRIGHTNESSDOWN = "Bright Down",
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

local function cleanBind(bind)
	return {
		id = bind.id, modifiers = bind.modifiers, key = bind.key,
		description = bind.description, dispatcher = bind.dispatcher,
		activation = "press", command = bind.command, action = bind.action,
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
		-- An editable range cannot safely carry the provenance of one real bind.
		-- Preserve every effective record individually once provenance is present.
		if bind.fingerprint ~= nil then
			output[#output + 1] = cleanBind(bind)
		elseif replacements[index] ~= nil then
			output[#output + 1] = replacements[index]
		elseif not skipped[index] then
			output[#output + 1] = cleanBind(bind)
		end
	end
	return output
end

local function buildCategories(records)
	local shouldMerge = config("merge_sequential", true) == true
	local byName = {}
	local order = {}
	local seen = {}
	local total = 0
	for _, bind in ipairs(records) do
		if not bind._overridden then
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
	local description = titleAttribute(attributes)
	if description == nil or description == "" then
		description = actionDescription(normalizedAction, verb)
	end
	local command = ""
	if verb == "spawn-sh" then
		command = quotedLiteral(normalizedAction:sub(#verb + 1), 1) or ""
	end
	local rawSnippet = provenance.raw_snippet or ""
	local bind = {
		id = "niri:" .. stableFingerprint(signature .. "\0" .. verb .. "\0" .. normalizedAction),
		modifiers = modifiers, key = key, description = description, dispatcher = verb,
		activation = "press", command = command, action = normalizedAction,
		source = provenance.source, start_line = provenance.start_line,
		end_line = provenance.end_line, raw_snippet = rawSnippet,
		fingerprint = stableFingerprint(rawSnippet),
		managed = provenance.source:match("([^/]+)$") == "keymap.kdl",
		capabilities = {
			combo = true, category = true, description = true,
			command = verb == "spawn-sh", activation = false,
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

local function snapshot(status, source, errorCode, categories, total, warnings, updatedAt, hidden)
	return {
		status = status,
		error = errorCode or "",
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
		return
	end
	if refreshing then
		refreshQueued = true
		return
	end
	refreshing = true
	local source = sourcePath()
	-- The panel keeps its last ready snapshot while this status is loading.
	-- Do not copy the full bind tree through the shared-state serializer merely
	-- to replace it again at the end of this synchronous refresh.
	noctalia.state.set(
		SNAPSHOT_KEY,
		snapshot("loading", source, "", {}, 0, {}, "", {})
	)

	local rootSource = noctalia.readFile(source)
	if type(rootSource) ~= "string" then
		noctalia.state.set(
			SNAPSHOT_KEY,
			snapshot("error", source, "niri_config_unreadable", {}, 0, {}, os.date("%H:%M:%S"))
		)
		finishRefresh()
		return
	end

	local categories, total, hidden, warnings, fatalError = parseConfig(source, rootSource)
	if fatalError ~= nil then
		noctalia.state.set(
			SNAPSHOT_KEY,
			snapshot("error", source, fatalError, {}, 0, warnings, os.date("%H:%M:%S"))
		)
	elseif total == 0 and #hidden == 0 then
		noctalia.state.set(
			SNAPSHOT_KEY,
			snapshot("error", source, "niri_no_binds", {}, 0, warnings, os.date("%H:%M:%S"))
		)
	else
		noctalia.state.set(
			SNAPSHOT_KEY,
			snapshot("ready", source, "", categories, total, warnings, os.date("%H:%M:%S"), hidden)
		)
	end
	finishRefresh()
end

function onIpc(event, _payload)
	if event == "refresh" then
		refresh()
	end
end

function onConfigChanged()
	refresh()
end

-- Manual lifecycle: refreshes are driven by initial load, config changes, IPC,
-- and the shared refresh request. The host's periodic update hook is a no-op.
function update()
end

noctalia.state.watch(REFRESH_REQUEST_KEY, function(_request)
	refresh()
end)

refresh()
