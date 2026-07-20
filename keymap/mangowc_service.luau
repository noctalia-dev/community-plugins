--!nonstrict
-- Keymap service for MangoWC / mangowm.
--
-- Mango's IPC does not expose the loaded keybinding registry. The recursively
-- included configuration tree is therefore the authoritative available source.

local SNAPSHOT_KEY = "keymap.snapshot"
local REFRESH_REQUEST_KEY = "keymap.refresh_request"
local DEFAULT_CONFIG = "~/.config/mango/config.conf"
local SYSTEM_CONFIG = "/etc/mango/config.conf"
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

local function envSet(name)
	local value = noctalia.getenv(name)
	return type(value) == "string" and value ~= ""
end

local function environment(name)
	local value = noctalia.getenv(name)
	return type(value) == "string" and value or ""
end

local function desktopHas(value, wanted)
	local normalized = tostring(value or ""):lower()
	return normalized:find(wanted, 1, true) ~= nil
end

-- Shared detection order used by all compositor-specific services.
local function detectedCompositor()
	if envSet("NIRI_SOCKET") then
		return "niri"
	end
	if envSet("HYPRLAND_INSTANCE_SIGNATURE") then
		return "hyprland"
	end
	if envSet("MANGO_INSTANCE_SIGNATURE") then
		return "mangowc"
	end

	local current = noctalia.getenv("XDG_CURRENT_DESKTOP")
	local session = noctalia.getenv("XDG_SESSION_DESKTOP")
	local desktopSession = noctalia.getenv("DESKTOP_SESSION")
	if desktopHas(current, "niri") or desktopHas(session, "niri") or desktopHas(desktopSession, "niri") then
		return "niri"
	end
	if desktopHas(current, "hyprland") or desktopHas(session, "hyprland") or desktopHas(desktopSession, "hyprland") then
		return "hyprland"
	end
	if desktopHas(current, "mango") or desktopHas(session, "mango")
		or desktopHas(desktopSession, "mango") or desktopHas(current, "mangowc")
		or desktopHas(session, "mangowc") or desktopHas(desktopSession, "mangowc") then
		return "mangowc"
	end
	return ""
end

local function selectedCompositor()
	local selected = tostring(config("compositor", "auto")):lower()
	if selected == "hyprland" or selected == "niri" or selected == "mangowc" then
		return selected
	end
	return detectedCompositor()
end

local function isActive()
	return selectedCompositor() == "mangowc"
end

local function dirname(path)
	local directory = path:match("^(.*)/[^/]*$")
	return directory ~= nil and directory ~= "" and directory or "."
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

local function expandPath(path)
	local expanded = noctalia.expandPath(path)
	if type(expanded) == "string" and expanded ~= "" then
		return normalizePath(expanded)
	end
	return normalizePath(path)
end

local function configPath()
	local configured = trim(config("mangowc_config", DEFAULT_CONFIG))
	if configured == "" then
		configured = DEFAULT_CONFIG
	end
	local path = expandPath(configured)
	if noctalia.fileExists(path) then return path end

	local xdg = environment("XDG_CONFIG_HOME")
	local mangoDir = normalizePath((xdg ~= "" and xdg or (environment("HOME") .. "/.config")) .. "/mango")
	local candidates = { normalizePath(mangoDir .. "/config.conf"), SYSTEM_CONFIG }
	for _, candidate in ipairs(candidates) do
		if noctalia.fileExists(candidate) then return candidate end
	end

	local entries = noctalia.listDir(mangoDir)
	if type(entries) ~= "table" then return path end
	table.sort(entries)
	local bestPath, bestScore = nil, -1
	for _, name in ipairs(entries) do
		if type(name) == "string" and name:match("%.conf$") and name ~= "keymap.conf"
			and not name:lower():find("backup", 1, true) then
			local candidate = normalizePath(mangoDir .. "/" .. name)
			local source = noctalia.readFile(candidate)
			if type(source) == "string" and #source <= MAX_SOURCE_BYTES then
				local _, bindCount = source:gsub("bind[%w%-]*%s*=", "")
				local _, sourceCount = source:gsub("source[%w%-]*%s*=", "")
				local score = bindCount * 10 + sourceCount * 2
				if name:lower():find("bind", 1, true) then score = score + 5 end
				if score > bestScore then bestPath, bestScore = candidate, score end
			end
		end
	end
	return bestScore > 0 and bestPath or path
end

local function stripOuterQuotes(value)
	local text = trim(value)
	local quote = text:sub(1, 1)
	if #text >= 2 and (quote == '"' or quote == "'") and text:sub(-1) == quote then
		return text:sub(2, -2)
	end
	return text
end

local function resolveSource(rootDirectory, source)
	local path = stripOuterQuotes(source)
	if path == "" then
		return nil
	end
	if path:find("*", 1, true) or path:find("?", 1, true) or path:find("[", 1, true) then
		return nil, "mangowc_source_glob_not_supported:" .. path
	end
	path = noctalia.expandPath(path) or path
	if path:sub(1, 1) == "/" then
		return normalizePath(path)
	end
	path = path:gsub("^%./", "")
	return normalizePath(rootDirectory .. "/" .. path)
end

local function slug(value)
	local id = value:lower():gsub("[^%a%d]+", "-"):gsub("^-+", ""):gsub("-+$", "")
	return id ~= "" and id or "category"
end

local function titleCase(value)
	local text = tostring(value or ""):gsub("_", " "):gsub("%-", " ")
	text = text:gsub("(%l)(%u)", "%1 %2")
	return (text:gsub("%f[%a]%a", string.upper))
end

local function splitCsv(value)
	local parts = {}
	local start = 1
	while true do
		local comma = value:find(",", start, true)
		if comma == nil then
			parts[#parts + 1] = trim(value:sub(start))
			break
		end
		parts[#parts + 1] = trim(value:sub(start, comma - 1))
		start = comma + 1
	end
	return parts
end

local function joinTail(parts, first)
	local output = {}
	for index = first, #parts do
		output[#output + 1] = parts[index]
	end
	return trim(table.concat(output, ","))
end

-- Locate an ordinary inline comment while preserving the plugin convention
-- #"description" and quoted hashes in shell commands.
local function findUnquotedComment(line)
	local inSingle = false
	local inDouble = false
	local escaped = false
	for index = 1, #line do
		local char = line:sub(index, index)
		if escaped then
			escaped = false
		elseif char == "\\" and (inSingle or inDouble) then
			escaped = true
		elseif char == "'" and not inDouble then
			inSingle = not inSingle
		elseif char == '"' and not inSingle then
			inDouble = not inDouble
		elseif char == "#" and not inSingle and not inDouble and line:sub(index + 1, index + 1) ~= '"' then
			return index
		end
	end
	return nil
end

local function extractDescription(line)
	local description = line:match('#"(.*)"%s*$')
	local marker = line:match('()#".*"%s*$')
	if description == nil or marker == nil then
		return line, nil
	end
	description = description:gsub('\\"', '"'):gsub("\\\\", "\\")
	return trim(line:sub(1, marker - 1)), description
end

local function extractCategory(line)
	local rest = trim(line)
	if rest:sub(1, 1) ~= "#" then
		return nil
	end
	local managed = trim(rest:match("^#%s*Keymap category:%s*(.+)$") or "")
	if managed ~= "" then return managed end
	rest = trim(rest:gsub("^#+", "", 1))
	if rest == "" or #rest > 100 or rest:match("^[%w%-]+%s*=") then
		return nil
	end
	if rest:match("^[─━═=%-_*#/\\%s]+$") or rest:match("^[%(%[]") then
		return nil
	end
	if rest:match("^%-%>") or rest:match("^=%>") then
		return nil
	end
	local firstWord = rest:match("^(%a+)")
	if firstWord ~= nil then
		local upper = firstWord:upper()
		if upper == "TODO" or upper == "FIXME" or upper == "NOTE" or upper == "HACK"
			or upper == "XXX" or upper == "BUG" or upper == "WIP" then
			return nil
		end
	end
	rest = trim(rest:gsub("[─━═=%-_*][─━═=%-_*][─━═=%-_*]+%s*$", ""))
	if rest == "" then
		return nil
	end
	return trim(rest:match("^%d+%.%s*(.+)$") or rest)
end

local KEY_NAMES = {
	RETURN = "Enter", ESCAPE = "Esc", SPACE = "Space", PRINT = "PrtSc",
	PRIOR = "PgUp", NEXT = "PgDn", EQUAL = "=", MINUS = "-", PLUS = "+",
	COMMA = ",", PERIOD = ".", SEMICOLON = ";", APOSTROPHE = "'", GRAVE = "`",
	SLASH = "/", BACKSLASH = "\\", BRACKETLEFT = "[", BRACKETRIGHT = "]",
	XF86AUDIORAISEVOLUME = "Vol Up", XF86AUDIOLOWERVOLUME = "Vol Down",
	XF86AUDIOMUTE = "Mute", XF86AUDIOMICMUTE = "Mic Mute", XF86AUDIOPLAY = "Play",
	XF86AUDIOPAUSE = "Pause", XF86AUDIONEXT = "Next", XF86AUDIOPREV = "Prev",
	XF86AUDIOSTOP = "Stop", XF86MONBRIGHTNESSUP = "Bright Up",
	XF86MONBRIGHTNESSDOWN = "Bright Down",
}

local AXIS_NAMES = {
	UP = "Scroll Up", DOWN = "Scroll Down", LEFT = "Scroll Left", RIGHT = "Scroll Right",
}

local BUTTON_NAMES = {
	BTN_LEFT = "Left Click", BTN_RIGHT = "Right Click", BTN_MIDDLE = "Middle Click",
	BTN_SIDE = "Mouse Side", BTN_EXTRA = "Mouse Extra", BTN_FORWARD = "Mouse Forward",
	BTN_BACK = "Mouse Back", BTN_TASK = "Mouse Task", ["CODE:272"] = "Left Click",
	["CODE:273"] = "Right Click", ["CODE:274"] = "Middle Click",
}

local MODIFIER_NAMES = {
	SUPER = "Super", SUPER_L = "Super", SUPER_R = "Super", LOGO = "Super",
	CTRL = "Ctrl", CONTROL = "Ctrl", CTRL_L = "Ctrl", CTRL_R = "Ctrl",
	SHIFT = "Shift", SHIFT_L = "Shift", SHIFT_R = "Shift",
	ALT = "Alt", ALT_L = "Alt", ALT_R = "Alt", MOD1 = "Alt",
	HYPER = "Hyper", HYPER_L = "Hyper", HYPER_R = "Hyper",
}

local MODIFIER_CODES = {
	["37"] = "Ctrl", ["50"] = "Shift", ["62"] = "Shift", ["64"] = "Alt",
	["105"] = "Ctrl", ["108"] = "Alt", ["133"] = "Super", ["134"] = "Super",
}

local function parseModifiers(value)
	local modifiers = {}
	local seen = {}
	for token in (value .. "+"):gmatch("(.-)%+") do
		local upper = trim(token):upper()
		local name = MODIFIER_NAMES[upper]
		if name == nil then
			name = MODIFIER_CODES[upper:match("^CODE:(%d+)$") or ""]
		end
		if name ~= nil and not seen[name] then
			seen[name] = true
			modifiers[#modifiers + 1] = name
		elseif upper ~= "" and upper ~= "NONE" and name == nil then
			local code = upper:match("^CODE:(%d+)$")
			local rawName = code ~= nil and ("Code " .. code) or titleCase(upper:lower())
			if not seen[rawName] then
				seen[rawName] = true
				modifiers[#modifiers + 1] = rawName
			end
		end
	end
	return modifiers
end

local function formatKey(value)
	local key = trim(value)
	return KEY_NAMES[key:upper()] or key
end

local NO_ARG_ACTIONS = {
	killclient = "actions.mangowc.killclient", togglefullscreen = "actions.mangowc.togglefullscreen",
	togglefakefullscreen = "actions.mangowc.togglefakefullscreen", togglemaximizescreen = "actions.mangowc.togglemaximizescreen",
	togglefloating = "actions.mangowc.togglefloating", toggle_all_floating = "actions.mangowc.toggle_all_floating",
	toggleglobal = "actions.mangowc.toggleglobal", toggleoverview = "actions.mangowc.toggleoverview",
	togglejump = "actions.mangowc.togglejump", toggleoverlay = "actions.mangowc.toggleoverlay",
	toggle_scratchpad = "actions.mangowc.toggle_scratchpad", minimized = "actions.mangowc.minimized",
	restore_minimized = "actions.mangowc.restore_minimized", reload_config = "actions.mangowc.reload_config",
	quit = "actions.mangowc.quit", switch_proportion_preset = "actions.mangowc.switch_proportion_preset",
	switch_keyboard_layout = "actions.mangowc.switch_keyboard_layout", zoom = "actions.mangowc.zoom",
	restart = "actions.mangowc.restart", incnmaster = "actions.mangowc.incnmaster",
	switch_layout = "actions.mangowc.switch_layout", togglegaps = "actions.mangowc.togglegaps",
	dwindle_toggle_split_direction = "actions.mangowc.dwindle_toggle_split_direction",
}

local DIRECTION_ACTIONS = {
	focusdir = "actions.mangowc.focusdir", exchange_client = "actions.mangowc.exchange_client",
	focusmon = "actions.mangowc.focusmon", tagmon = "actions.mangowc.tagmon",
	groupjoin = "actions.mangowc.groupjoin", groupfocus = "actions.mangowc.groupfocus",
	smartmovewin = "actions.mangowc.smartmovewin", smartresizewin = "actions.mangowc.smartresizewin",
	scroller_stack = "actions.mangowc.scroller_stack",
}

local function formatAction(action, args)
	local normalized = trim(action):lower()
	local argument = trim(args)
	if NO_ARG_ACTIONS[normalized] ~= nil and (argument == "" or argument == "0") then
		return noctalia.tr(NO_ARG_ACTIONS[normalized])
	end
	if DIRECTION_ACTIONS[normalized] ~= nil then
		local label = noctalia.tr(DIRECTION_ACTIONS[normalized])
		return argument ~= "" and noctalia.tr("actions.with_argument", { action = label, argument = titleCase(argument) }) or label
	end
	if normalized == "spawn" or normalized == "spawn_shell" or normalized == "spawn_on_empty" then
		return argument ~= "" and noctalia.tr("actions.run", { command = argument }) or noctalia.tr("actions.run_command")
	end
	if normalized == "view" then
		local tag = argument:match("^([^,]+)") or argument
		return tag ~= "" and noctalia.tr("actions.view_tag_number", { tag = tag }) or noctalia.tr("actions.view_tag")
	end
	if normalized == "tag" or normalized == "tagsilent" then
		local tag = argument:match("^([^,]+)") or argument
		return tag ~= "" and noctalia.tr("actions.move_to_tag_number", { tag = tag }) or noctalia.tr("actions.move_to_tag")
	end
	if normalized == "setlayout" then
		return argument ~= "" and noctalia.tr("actions.layout_value", { layout = argument }) or noctalia.tr("actions.set_layout")
	end
	if normalized == "setkeymode" then
		return argument ~= "" and noctalia.tr("actions.key_mode_value", { mode = argument }) or noctalia.tr("actions.set_key_mode")
	end
	return noctalia.tr("actions.native", {
		action = normalized .. (argument ~= "" and (" " .. argument) or ""),
	})
end

local function parseFlags(suffix)
	local flags = {}
	for index = 1, #suffix do
		local flag = suffix:sub(index, index):lower()
		if flag == "l" then flags.locked = true
		elseif flag == "s" then flags.keysym = true
		elseif flag == "r" then flags.release = true
		elseif flag == "p" then flags.pass = true end
	end
	return flags
end

local function addCategory(context, name)
	local category = context.byCategory[name]
	if category ~= nil then
		return category
	end
	local baseId = slug(name)
	local id = baseId
	local suffix = 2
	while context.categoryIds[id] do
		id = baseId .. "-" .. tostring(suffix)
		suffix = suffix + 1
	end
	context.categoryIds[id] = true
	category = { id = id, name = name, binds = {} }
	context.byCategory[name] = category
	context.categories[#context.categories + 1] = category
	return category
end

local fingerprint

local function stableBindId(context, fields)
	local identity = table.concat(fields, "|")
	local count = (context.bindIds[identity] or 0) + 1
	context.bindIds[identity] = count
	return "mango:" .. fingerprint(identity) .. (count > 1 and (":" .. tostring(count)) or "")
end

-- FNV-1a over the exact source line. The editor recalculates this before a
-- write so a bind is never replaced after the file changed behind its back.
-- Multiplication is split into 16-bit words to retain exact 32-bit arithmetic
-- in runtimes where Lua numbers are doubles.
local function xorLowByte(value, byte)
	local low = value % 256
	local result = 0
	local place = 1
	for _ = 1, 8 do
		if low % 2 ~= byte % 2 then
			result = result + place
		end
		low = math.floor(low / 2)
		byte = math.floor(byte / 2)
		place = place * 2
	end
	return value - (value % 256) + result
end

fingerprint = function(rawSnippet)
	local hash = 2166136261
	for index = 1, #rawSnippet do
		hash = xorLowByte(hash, rawSnippet:byte(index))
		local low = hash % 65536
		local high = math.floor(hash / 65536)
		local lowProduct = low * 403
		local resultLow = lowProduct % 65536
		local resultHigh = (
			math.floor(lowProduct / 65536) + low * 256 + high * 403
		) % 65536
		hash = resultHigh * 65536 + resultLow
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
	local namespace = "^([\t ]*)# Keymap hidden "
	if lines[startLine]:match(namespace) == nil then return nil, startLine, false end
	local indent, blockId, originalFingerprint = lines[startLine]:match(
		namespace .. "v1 begin ([0-9a-f]+) ([0-9a-f]+)$"
	)
	if indent == nil or #blockId ~= 8 or #originalFingerprint ~= 8 then return nil, startLine, true end
	local marker = indent .. "# Keymap hidden v1"
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
				or #original > MAX_HIDDEN_BYTES or fingerprint(original) ~= originalFingerprint
				or fingerprint("MangoWC\0" .. original) ~= blockId then return nil, cursor, true end
			return { block_id = blockId, original = original, original_fingerprint = originalFingerprint,
				raw_snippet = table.concat(lines, "\n", startLine, cursor) }, cursor, true
		end
	end
	return nil, #lines, true
end

local function editCapabilities(kind, action)
	local isKeyboard = kind == "bind"
	return {
		combo = isKeyboard,
		category = isKeyboard,
		description = isKeyboard,
		command = isKeyboard and trim(action):lower() == "spawn_shell",
		activation = isKeyboard,
	}
end

local function disabledEditCapabilities()
	return {
		combo = false, category = false, description = false,
		command = false, activation = false,
	}
end

local function addBind(
	context, categoryName, kind, suffix, parts, description,
	source, lineNumber, rawSnippet, startLine
)
	local modifiers = {}
	local key = ""
	local action = ""
	local args = ""
	if kind == "bind" then
		if #parts < 3 then return false end
		modifiers, key, action, args = parseModifiers(parts[1]), formatKey(parts[2]), parts[3], joinTail(parts, 4)
	elseif kind == "axisbind" then
		if #parts < 3 then return false end
		modifiers = parseModifiers(parts[1])
		key, action, args = AXIS_NAMES[parts[2]:upper()] or titleCase(parts[2]), parts[3], joinTail(parts, 4)
	elseif kind == "mousebind" then
		if #parts < 3 then return false end
		modifiers = parseModifiers(parts[1])
		key, action, args = BUTTON_NAMES[parts[2]:upper()] or titleCase(parts[2]), parts[3], joinTail(parts, 4)
	elseif kind == "gesturebind" then
		if #parts < 4 then return false end
		modifiers = parseModifiers(parts[1])
		key, action, args = tostring(parts[3]) .. "-finger " .. titleCase(parts[2]), parts[4], joinTail(parts, 5)
	elseif kind == "switchbind" then
		if #parts < 2 then return false end
		local state = parts[1]:lower()
		key = state == "fold" and "Lid Closed" or (state == "unfold" and "Lid Open" or titleCase(parts[1]))
		action, args = parts[2], joinTail(parts, 3)
	else
		return false
	end

	local fields = { context.keymode, kind, table.concat(modifiers, "+"), key, suffix, action, args }
	local category = addCategory(context, categoryName)
	local activation = parseFlags(suffix).release == true and "release" or "press"
	category.binds[#category.binds + 1] = {
		id = stableBindId(context, fields), modifiers = modifiers, key = key,
		description = description or formatAction(action, args), dispatcher = trim(action),
		command = args, action = formatAction(action, args),
		mode = context.keymode, kind = kind, flags = parseFlags(suffix), activation = activation,
		source = source, line = startLine or lineNumber,
		start_line = startLine or lineNumber, end_line = lineNumber,
		raw_snippet = rawSnippet, fingerprint = fingerprint(rawSnippet),
		managed = source:match("([^/]+)$") == "keymap.conf",
		capabilities = editCapabilities(kind, action),
		_rawKey = kind == "bind" and trim(parts[2]) or key,
	}
	context.total = context.total + 1
	return true
end

local function hiddenTarget(block, path, startLine, endLine, inheritedCategory, keymode)
	local bindLine = ""
	for raw in (block.original .. "\n"):gmatch("([^\n]*)\n") do
		if trim(raw):match("^bind[lsrp]*%s*=") or trim(raw):match("^axisbind%s*=")
			or trim(raw):match("^mousebind%s*=") or trim(raw):match("^gesturebind%s*=")
			or trim(raw):match("^switchbind%s*=") then bindLine = raw end
	end
	local effective, description = extractDescription(trim(bindLine))
	local directive, value = effective:match("^([%w%-]+)%s*=%s*(.*)$")
	directive = tostring(directive or ""):lower()
	local suffix = directive:match("^bind([lsrp]*)$")
	local kind = suffix ~= nil and "bind" or directive
	if kind ~= "bind" and kind ~= "axisbind" and kind ~= "mousebind"
		and kind ~= "gesturebind" and kind ~= "switchbind" then kind, suffix = "bind", "" end
	local markedCategory = block.original:match(
		"^%s*#%s*Keymap bind%-category:%s*([^\n]-)%s*\n"
	)
	local temporary = {
		defaultCategory = inheritedCategory or "", filesRead = 0, files = {}, visited = {}, warnings = {},
		categories = {}, byCategory = {}, categoryIds = {}, bindIds = {}, total = 0,
		keymode = keymode or "default",
	}
	addBind(temporary, markedCategory or inheritedCategory or temporary.defaultCategory, kind, suffix or "",
		splitCsv(value or ""), description, path, endLine, block.original, startLine)
	local bind = temporary.categories[1] and temporary.categories[1].binds[1] or {}
	bind.hidden = true
	bind.id = "hidden:mango:" .. fingerprint(path .. "\0" .. tostring(startLine) .. "\0" .. block.block_id)
	bind.source, bind.line, bind.start_line, bind.end_line = path, startLine, startLine, endLine
	bind.raw_snippet, bind.fingerprint = block.raw_snippet, fingerprint(block.raw_snippet)
	bind.original_fingerprint = block.original_fingerprint
	bind.category = markedCategory or inheritedCategory or temporary.defaultCategory
	bind.capabilities = { restore = true, delete = true }
	return bind
end

local function parseFile(context, path, optional, depth)
	if context.filesRead >= MAX_FILES then
		context.warnings[#context.warnings + 1] = "mangowc_file_limit_reached"
		return
	end
	if context.visited[path] then
		return
	end
	context.visited[path] = true
	local source = noctalia.readFile(path)
	if type(source) ~= "string" then
		if not optional then
			local prefix = depth == 0 and "mangowc_config_unreadable:" or "mangowc_required_source_unreadable:"
			context.warnings[#context.warnings + 1] = prefix .. path
			if depth > 0 then
				context.fatalError = "mangowc_required_source_missing"
			end
		end
		return
	end
	context.filesRead = context.filesRead + 1
	context.files[#context.files + 1] = path
	if #source > MAX_SOURCE_BYTES then
		source = source:sub(1, MAX_SOURCE_BYTES)
		context.warnings[#context.warnings + 1] = "mangowc_source_truncated:" .. path
	end

	local currentCategory = nil
	local pendingBindCategory = nil
	local pendingMarkerLine = nil
	local pendingMarkerRaw = nil
	local lineNumber = 0
	local hiddenLines = sourceLines(source)
	local hiddenCategory = nil
	local hiddenKeymode = context.keymode
	local hiddenCursor = 1
	local hiddenConsumed = {}
	while hiddenCursor <= #hiddenLines do
		local block, blockEnd, candidate = hiddenBlockAt(hiddenLines, hiddenCursor)
		if candidate then
			for consumed = hiddenCursor, blockEnd do hiddenConsumed[consumed] = true end
			if block == nil then
				context.warnings[#context.warnings + 1] = "hidden_block_invalid:" .. path .. ":" .. tostring(hiddenCursor)
			else
				context.hidden[#context.hidden + 1] = hiddenTarget(
					block, path, hiddenCursor, blockEnd,
					hiddenCategory or context.defaultCategory, hiddenKeymode
				)
			end
			hiddenCursor = blockEnd + 1
		else
			local raw = hiddenLines[hiddenCursor]
			local category = extractCategory(raw)
			if category ~= nil then hiddenCategory = category end
			local effective = trim(raw:sub(1, (findUnquotedComment(raw) or (#raw + 1)) - 1))
			local directive, value = effective:match("^([%w%-]+)%s*=%s*(.*)$")
			if directive ~= nil and directive:lower() == "keymode" then
				hiddenKeymode = trim(value) ~= "" and trim(value) or "default"
			end
			hiddenCursor = hiddenCursor + 1
		end
	end
	for rawLine in (source .. "\n"):gmatch("([^\n]*)\n") do
		lineNumber = lineNumber + 1
		if not hiddenConsumed[lineNumber] then
		local commentAt = findUnquotedComment(rawLine)
		local effective = trim(commentAt ~= nil and rawLine:sub(1, commentAt - 1) or rawLine)
		if effective == "" then
			local bindCategory = rawLine:match(
				"^%s*#%s*Keymap bind%-category:%s*(.-)%s*$"
			)
			if bindCategory ~= nil and bindCategory ~= "" then
				pendingBindCategory = bindCategory
				pendingMarkerLine = lineNumber
				pendingMarkerRaw = rawLine
			else
				local category = extractCategory(rawLine)
				if category ~= nil then currentCategory = category end
			end
		else
			local cleanLine, description = extractDescription(effective)
			local directive, value = cleanLine:match("^([%w%-]+)%s*=%s*(.*)$")
			if directive ~= nil then
				directive = directive:lower()
				if directive == "source" or directive == "source-optional" then
					local included, warning = resolveSource(dirname(path), value)
					if warning ~= nil then
						context.warnings[#context.warnings + 1] = warning
					elseif included ~= nil then
						parseFile(context, included, directive == "source-optional", depth + 1)
					end
				elseif directive == "keymode" then
					context.keymode = trim(value) ~= "" and trim(value) or "default"
				else
					local suffix = directive:match("^bind([lsrp]*)$")
					local kind = suffix ~= nil and "bind" or nil
					if kind == nil and (directive == "axisbind" or directive == "mousebind"
						or directive == "gesturebind" or directive == "switchbind") then
						kind, suffix = directive, ""
					end
					if kind ~= nil then
						local rawSnippet = pendingMarkerRaw ~= nil
							and (pendingMarkerRaw .. "\n" .. rawLine) or rawLine
						if not addBind(
							context, pendingBindCategory or currentCategory or context.defaultCategory,
							kind, suffix, splitCsv(value), description, path, lineNumber,
							rawSnippet, pendingMarkerLine
						) then
							context.warnings[#context.warnings + 1] = "mangowc_invalid_bind:"
								.. path .. ":" .. tostring(lineNumber)
						end
					end
				end
			end
			pendingBindCategory = nil
			pendingMarkerLine = nil
			pendingMarkerRaw = nil
		end
		end
	end
end

local function cleanBind(bind)
	return {
		id = bind.id, modifiers = bind.modifiers, key = bind.key,
		description = bind.description, dispatcher = bind.dispatcher,
		mode = bind.mode, kind = bind.kind, flags = bind.flags,
		activation = type(bind.flags) == "table" and bind.flags.release == true and "release" or "press",
		command = bind.command, action = bind.action, managed = bind.managed == true,
		source = bind.source, line = bind.line,
		start_line = bind.start_line, end_line = bind.end_line,
		raw_snippet = bind.raw_snippet, fingerprint = bind.fingerprint,
		capabilities = bind.capabilities,
	}
end

local function descriptionTemplate(description)
	local template, replacements = description:gsub("%f[%d]%d+%f[%D]", "%%N%%")
	return template, replacements > 0
end

local function mergedBind(run)
	local first = run[1].bind
	local last = run[#run].bind
	local range = tostring(run[1].number) .. "-" .. tostring(run[#run].number)
	local startLine = first.start_line or first.line
	local endLine = first.end_line or first.line
	for _, item in ipairs(run) do
		local itemStart = item.bind.start_line or item.bind.line
		local itemEnd = item.bind.end_line or item.bind.line
		if itemStart ~= nil and (startLine == nil or itemStart < startLine) then startLine = itemStart end
		if itemEnd ~= nil and (endLine == nil or itemEnd > endLine) then endLine = itemEnd end
	end
	return {
		id = "range:" .. first.id .. ":" .. last.id,
		modifiers = first.modifiers,
		key = range,
		description = first.description:gsub("%f[%d]%d+%f[%D]", range, 1),
		dispatcher = first.dispatcher,
		mode = first.mode,
		kind = first.kind,
		flags = first.flags,
		activation = type(first.flags) == "table" and first.flags.release == true and "release" or "press",
		command = first.command, managed = first.managed == true,
		source = first.source,
		line = first.line,
		start_line = startLine, end_line = endLine,
		raw_snippet = "", fingerprint = "",
		-- A displayed numeric range can represent interleaved, non-contiguous
		-- source lines, so it deliberately cannot be edited as a single bind.
		capabilities = disabledEditCapabilities(),
	}
end

-- Merge interleaved numeric runs (for example view 1, tag 1, view 2,
-- tag 2...). Mode is part of the signature so keymodes never bleed together.
local function mergeSequential(binds)
	if #binds < 3 then
		local output = {}
		for _, bind in ipairs(binds) do output[#output + 1] = cleanBind(bind) end
		return output
	end

	local groups = {}
	for index, bind in ipairs(binds) do
		local rawKey = tostring(bind._rawKey or "")
		local number = rawKey:match("^%d+$") and tonumber(rawKey) or nil
		local template, hasNumber = descriptionTemplate(bind.description)
		if number ~= nil and hasNumber then
			local signature = table.concat({
				tostring(bind.mode or "default"),
				table.concat(bind.modifiers or {}, "+"),
				tostring(bind.dispatcher or ""),
				template,
			}, "|")
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
					local run = {}
					local insertionIndex = group[runStart].index
					for itemIndex = runStart, cursor - 1 do
						local item = group[itemIndex]
						run[#run + 1] = item
						if item.index < insertionIndex then insertionIndex = item.index end
					end
					replacements[insertionIndex] = mergedBind(run)
					for _, item in ipairs(run) do
						if item.index ~= insertionIndex then skipped[item.index] = true end
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

local function parseConfig(source)
	local context = {
		defaultCategory = noctalia.tr("category.other"),
		filesRead = 0, files = {}, visited = {}, warnings = {}, categories = {},
		byCategory = {}, categoryIds = {}, bindIds = {}, total = 0, hidden = {},
		keymode = "default", fatalError = nil,
	}
	parseFile(context, source, false, 0)
	if config("merge_sequential", true) == true then
		for _, category in ipairs(context.categories) do
			category.binds = mergeSequential(category.binds)
		end
	else
		for _, category in ipairs(context.categories) do
			local clean = {}
			for _, bind in ipairs(category.binds) do clean[#clean + 1] = cleanBind(bind) end
			category.binds = clean
		end
	end
	return context
end

local function snapshot(status, source, errorCode, categories, total, warnings, updatedAt, hidden)
	return {
		status = status, error = errorCode or "", compositor = "MangoWC", source = source,
		updated_at = updatedAt or "", total = total or 0, categories = categories or {},
		warnings = warnings or {},
		hidden = hidden or {},
	}
end

local function publishError(source, errorCode, warnings)
	noctalia.state.set(
		SNAPSHOT_KEY,
		snapshot("error", source, errorCode, {}, 0, warnings, os.date("%H:%M:%S"))
	)
end

local function finishRefresh()
	refreshing = false
	if refreshQueued then
		refreshQueued = false
		refresh()
	end
end

function refresh()
	if not isActive() then
		return
	end
	if refreshing then
		refreshQueued = true
		return
	end
	refreshing = true

	local source = configPath()
	local previous = noctalia.state.get(SNAPSHOT_KEY)
	local sameCompositor = type(previous) == "table" and previous.compositor == "MangoWC"
	local previousCategories = sameCompositor and previous.categories or {}
	local previousTotal = sameCompositor and previous.total or 0
	local previousUpdatedAt = sameCompositor and previous.updated_at or ""
	local previousHidden = sameCompositor and previous.hidden or {}
	noctalia.state.set(
		SNAPSHOT_KEY,
		snapshot("loading", source, "", previousCategories, previousTotal, {}, previousUpdatedAt, previousHidden)
	)

	local parsed = parseConfig(source)
	if #parsed.files == 0 then
		publishError(source, "mangowc_config_unreadable", parsed.warnings)
		finishRefresh()
		return
	end
	if parsed.fatalError ~= nil then
		publishError(source, parsed.fatalError, parsed.warnings)
		finishRefresh()
		return
	end
	if parsed.total == 0 and #parsed.hidden == 0 then
		publishError(source, "mangowc_no_binds", parsed.warnings)
		finishRefresh()
		return
	end
	noctalia.state.set(
		SNAPSHOT_KEY,
		snapshot("ready", source, "", parsed.categories, parsed.total, parsed.warnings, os.date("%H:%M:%S"), parsed.hidden)
	)
	finishRefresh()
end

function onIpc(event, _payload)
	if event == "refresh" then refresh() end
end

function onConfigChanged()
	refresh()
end

noctalia.state.watch(REFRESH_REQUEST_KEY, function(_request)
	refresh()
end)

refresh()
