--!nonstrict
-- Keymap data service.
--
-- The live Hyprland bind registry is authoritative. Lua sources are scanned only
-- to recover user-defined category order and map descriptions back to categories.

local SNAPSHOT_KEY = "keymap.snapshot"
local REFRESH_REQUEST_KEY = "keymap.refresh_request"
local MAX_LUA_FILES = 64
local MAX_SOURCE_BYTES = 512 * 1024
local MAX_HIDDEN_BYTES = 2 * 1024 * 1024
local HYPRCTL_TIMEOUT_MS = 5000

local refreshing = false
local refreshQueued = false
local refreshGeneration = 0
local snapshotCompositor = "Hyprland"

local function config(key, fallback)
	local value = noctalia.getConfig(key)
	if value == nil then
		return fallback
	end
	return value
end

local function environment(name)
	local value = noctalia.getenv(name)
	return type(value) == "string" and value or ""
end

local function configuredCompositor()
	local selected = tostring(config("compositor", "auto")):lower()
	if selected ~= "auto" then
		return selected
	end
	if environment("NIRI_SOCKET") ~= "" then
		return "niri"
	end
	if environment("HYPRLAND_INSTANCE_SIGNATURE") ~= "" then
		return "hyprland"
	end
	if environment("MANGO_INSTANCE_SIGNATURE") ~= "" then
		return "mangowc"
	end
	local desktop = (environment("XDG_CURRENT_DESKTOP")
		.. ":" .. environment("XDG_SESSION_DESKTOP")
		.. ":" .. environment("DESKTOP_SESSION")):lower()
	if desktop:find("niri", 1, true) ~= nil then
		return "niri"
	end
	if desktop:find("hyprland", 1, true) ~= nil then
		return "hyprland"
	end
	if desktop:find("mangowc", 1, true) ~= nil or desktop:find("mango", 1, true) ~= nil then
		return "mangowc"
	end
	return nil
end

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end
	return value:match("^%s*(.-)%s*$") or ""
end

local function appendUnique(items, seen, value)
	if value == "" or seen[value] then
		return
	end
	seen[value] = true
	items[#items + 1] = value
end

local function dirname(path)
	local directory = path:match("^(.*)/[^/]*$")
	if directory == nil or directory == "" then
		return "."
	end
	return directory
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

local function expandedConfigPath()
	local configured = config("hyprland_config", "~/.config/hypr/hyprland.lua")
	local expanded = noctalia.expandPath(configured)
	if type(expanded) ~= "string" or expanded == "" then
		expanded = configured
	end
	expanded = normalizePath(expanded)
	if noctalia.fileExists(expanded) then return expanded end

	local xdg = environment("XDG_CONFIG_HOME")
	local configRoot = xdg ~= "" and xdg or (environment("HOME") .. "/.config")
	local hyprDir = normalizePath(configRoot .. "/hypr")
	local candidates = {
		normalizePath(hyprDir .. "/hyprland.lua"),
		normalizePath(hyprDir .. "/init.lua"),
		"/etc/xdg/hypr/hyprland.lua",
	}
	for _, path in ipairs(candidates) do
		if noctalia.fileExists(path) then return path end
	end

	local entries = noctalia.listDir(hyprDir)
	if type(entries) ~= "table" then return expanded end
	table.sort(entries)
	local bestPath, bestScore = nil, -1
	for _, name in ipairs(entries) do
		if type(name) == "string" and name:match("%.lua$") and name ~= "keymap.lua"
			and not name:lower():find("backup", 1, true) then
			local path = normalizePath(hyprDir .. "/" .. name)
			local source = noctalia.readFile(path)
			if type(source) == "string" and #source <= MAX_SOURCE_BYTES then
				local _, bindCount = source:gsub("hl%.bind%s*%(", "")
				local _, requireCount = source:gsub("%f[%a]require%f[^%a]", "")
				local score = bindCount * 10 + requireCount * 2
				if name:lower():find("keybind", 1, true) then score = score + 5 end
				if score > bestScore then bestPath, bestScore = path, score end
			end
		end
	end
	return bestScore > 0 and bestPath or expanded
end

local function modulePath(currentFile, moduleName)
	local name = trim(moduleName)
	if name == "" then
		return nil
	end
	if name:sub(-4) == ".lua" then
		name = name:sub(1, -5)
	end
	if not name:find("/", 1, true) then
		name = name:gsub("%.", "/")
	end
	name = name .. ".lua"
	if name:sub(1, 1) == "/" then
		return normalizePath(name)
	end
	return normalizePath(dirname(currentFile) .. "/" .. name)
end

local ESCAPES = {
	a = "\a",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
	v = "\v",
	["\\"] = "\\",
	['"'] = '"',
	["'"] = "'",
}

-- Returns a quoted literal assigned to `field` and whether it is immediately
-- concatenated (for example: description = "Workspace " .. i).
local function assignmentLiteral(line, field)
	local pattern = "%f[%w_]" .. field .. "%f[^%w_]"
	local _, fieldEnd = line:find(pattern)
	if fieldEnd == nil then
		return nil, false
	end

	local suffix = line:sub(fieldEnd + 1)
	local _, assignmentEnd = suffix:find("^%s*=%s*")
	if assignmentEnd == nil then
		return nil, false
	end
	local literal = suffix:sub(assignmentEnd + 1)
	local quote = literal:sub(1, 1)
	if quote ~= '"' and quote ~= "'" then
		return nil, false
	end

	local out = {}
	local escaped = false
	for index = 2, #literal do
		local char = literal:sub(index, index)
		if escaped then
			out[#out + 1] = ESCAPES[char] or char
			escaped = false
		elseif char == "\\" then
			escaped = true
		elseif char == quote then
			local tail = literal:sub(index + 1)
			return table.concat(out), tail:match("^%s*%.%.") ~= nil
		else
			out[#out + 1] = char
		end
	end
	return nil, false
end

local function requiredModules(line)
	local modules = {}
	local seen = {}
	for moduleName in line:gmatch('require%s*%(%s*"([^"]+)"%s*%)') do
		appendUnique(modules, seen, moduleName)
	end
	for moduleName in line:gmatch("require%s*%(%s*'([^']+)'%s*%)") do
		appendUnique(modules, seen, moduleName)
	end
	for moduleName in line:gmatch('require%s+"([^"]+)"') do
		appendUnique(modules, seen, moduleName)
	end
	for moduleName in line:gmatch("require%s+'([^']+)'") do
		appendUnique(modules, seen, moduleName)
	end
	return modules
end

local function multiKeySequence(line)
	local combo = line:match('hl%.bind%s*%(%s*"([^"]+)"')
		or line:match("hl%.bind%s*%(%s*'([^']+)'")
	if combo == nil then return nil end
	local keys = {}
	for token in combo:gmatch("[^+]+") do
		local value = trim(token)
		local upper = value:upper()
		if upper ~= "SUPER" and upper ~= "CTRL" and upper ~= "CONTROL"
			and upper ~= "SHIFT" and upper ~= "ALT" and upper ~= "META"
			and upper ~= "MOD" and upper ~= "MOD1" and upper ~= "MOD4" then
			keys[#keys + 1] = value
		end
	end
	return #keys > 1 and keys or nil
end

local function generatedCommand(line)
	local startIndex, endIndex = line:find("hl%.dsp%.exec_cmd%s*%(%s*")
	if endIndex == nil then return nil end
	local suffix = line:sub(endIndex + 1)
	local quote = suffix:sub(1, 1)
	if quote == '"' or quote == "'" then
		local out = {}
		local escaped = false
		for index = 2, #suffix do
			local char = suffix:sub(index, index)
			if escaped then
				out[#out + 1] = ESCAPES[char] or char
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == quote then
				return table.concat(out)
			else
				out[#out + 1] = char
			end
		end
		return nil
	end
	local equals = suffix:match("^%[(=*)%[")
	if equals == nil then return nil end
	local openingLength = #equals + 2
	local closeIndex = suffix:find("]" .. equals .. "]", openingLength + 1, true)
	if closeIndex == nil then return nil end
	return suffix:sub(openingLength + 1, closeIndex - 1)
end

local function generatedAction(line)
	local startIndex = line:find("hl%.dsp%.")
	if startIndex == nil then return nil end
	local quote, escaped, depth, opened = nil, false, 0, false
	for index = startIndex, #line do
		local char = line:sub(index, index)
		if quote ~= nil then
			if escaped then escaped = false
			elseif char == "\\" then escaped = true
			elseif char == quote then quote = nil end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "(" then
			depth = depth + 1
			opened = true
		elseif char == ")" then
			depth = depth - 1
			if opened and depth == 0 then return line:sub(startIndex, index) end
		end
	end
	return nil
end

local function xorByte(left, right)
	local result, place = 0, 1
	for _ = 1, 8 do
		if left % 2 ~= right % 2 then result = result + place end
		left = math.floor(left / 2)
		right = math.floor(right / 2)
		place = place * 2
	end
	return result
end

local xorByteFast = type(bit32) == "table" and type(bit32.bxor) == "function" and bit32.bxor or xorByte

local function fingerprint(value)
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
	for index = 1, #value, 2 do
		local byte = tonumber(value:sub(index, index + 1), 16)
		if byte == nil then return nil end
		output[#output + 1] = string.char(byte)
	end
	return table.concat(output)
end

-- Exact v1 sentinel parser. It runs before ordinary comment handling so only
-- blocks emitted by the writer become restorable targets.
local function hiddenBlockAt(lines, startLine)
	local namespace = "^([\t ]*)%-%- Keymap hidden "
	if lines[startLine]:match(namespace) == nil then return nil, startLine, false end
	local indent, blockId, originalFingerprint = lines[startLine]:match(
		namespace .. "v1 begin ([0-9a-f]+) ([0-9a-f]+)$"
	)
	if indent == nil or #blockId ~= 8 or #originalFingerprint ~= 8 then
		return nil, startLine, true
	end
	local marker = indent .. "-- Keymap hidden v1"
	local escapedMarker = marker:gsub("(%W)", "%%%1")
	local encoded = {}
	local cursor = startLine + 1
	while cursor <= #lines do
		local chunk = lines[cursor]:match("^" .. escapedMarker .. " data ([0-9a-f]+)$")
		if chunk ~= nil then
			if #chunk > 96 or #chunk % 2 ~= 0 then return nil, cursor, true end
			encoded[#encoded + 1] = chunk
			cursor = cursor + 1
		else
			local endId = lines[cursor]:match("^" .. escapedMarker .. " end ([0-9a-f]+)$")
			if endId == nil then return nil, math.max(startLine, cursor - 1), true end
			local original = hexDecode(table.concat(encoded))
			if #encoded == 0 or endId ~= blockId or original == nil or original == ""
				or #original > MAX_HIDDEN_BYTES or fingerprint(original) ~= originalFingerprint
				or fingerprint("Hyprland\0" .. original) ~= blockId then
				return nil, cursor, true
			end
			return {
				block_id = blockId, original = original,
				original_fingerprint = originalFingerprint,
				raw_snippet = table.concat(lines, "\n", startLine, cursor),
			}, cursor, true
		end
	end
	return nil, #lines, true
end

local function scanLuaSources(rootPath)
	local headers = {}
	local headerSeen = {}
	local exactCategories = {}
	local prefixes = {}
	local prefixSeen = {}
	local keySequences = {}
	local origins = {}
	local commands = {}
	local actions = {}
	local warnings = {}
	local hidden = {}

	local queue = { rootPath }
	local queued = { [rootPath] = true }
	local visited = {}
	local cursor = 1
	local filesRead = 0

	while cursor <= #queue and filesRead < MAX_LUA_FILES do
		local path = queue[cursor]
		cursor = cursor + 1
		if not visited[path] then
			visited[path] = true
			local source = noctalia.readFile(path)
			if type(source) ~= "string" then
				if path == rootPath then
					warnings[#warnings + 1] = "lua_config_unreadable"
				end
			else
				filesRead = filesRead + 1
				if #source > MAX_SOURCE_BYTES then
					source = source:sub(1, MAX_SOURCE_BYTES)
					warnings[#warnings + 1] = "lua_source_truncated"
				end

				local currentCategory = nil
				local pendingBindCategory = nil
				local pendingMarkerLine = nil
				local pendingMarkerRaw = nil
				local lines = sourceLines(source)
				local lineNumber = 1
				while lineNumber <= #lines do
					local line = lines[lineNumber]
					local block, blockEnd, candidate = hiddenBlockAt(lines, lineNumber)
					if candidate then
						if block == nil then
							warnings[#warnings + 1] = "hidden_block_invalid:" .. path .. ":" .. tostring(lineNumber)
						else
							local originalLine = block.original:match("([^\n]*hl%.bind[^\n]*)") or ""
							local combo = originalLine:match('hl%.bind%s*%(%s*"([^"]+)"')
								or originalLine:match("hl%.bind%s*%(%s*'([^']+)'") or ""
							local modifiers, keys = {}, {}
							for token in combo:gmatch("[^+]+") do
								local value = trim(token)
								local upper = value:upper()
								if upper == "SUPER" or upper == "CTRL" or upper == "CONTROL"
									or upper == "SHIFT" or upper == "ALT" or upper == "META"
									or upper == "MOD" or upper == "MOD1" or upper == "MOD4" then
									modifiers[#modifiers + 1] = upper == "CONTROL" and "Ctrl"
										or upper:sub(1, 1) .. upper:sub(2):lower()
								elseif value ~= "" then keys[#keys + 1] = value end
							end
							local category = block.original:match(
								"^%s*%-%-%s*Keymap bind%-category:%s*([^\n]-)%s*\n"
							) or currentCategory
							local description = assignmentLiteral(originalLine, "description")
								or assignmentLiteral(originalLine, "desc") or ""
							hidden[#hidden + 1] = {
								hidden = true,
								id = "hidden:hypr:" .. fingerprint(path .. "\0" .. tostring(lineNumber) .. "\0" .. block.block_id),
								source = path, line = lineNumber, start_line = lineNumber, end_line = blockEnd,
								raw_snippet = block.raw_snippet, fingerprint = fingerprint(block.raw_snippet),
								original_fingerprint = block.original_fingerprint,
								modifiers = modifiers, key = keys[#keys] or "", keys = #keys > 1 and keys or nil,
								description = description, dispatcher = generatedAction(originalLine) or "",
								command = generatedCommand(originalLine) or "", action = generatedAction(originalLine) or "",
								activation = originalLine:match("release%s*=%s*true") and "release" or "press",
								category = category or "", capabilities = { restore = true, delete = true },
							}
						end
						lineNumber = blockEnd + 1
					else
						local bindCategory = line:match(
						"^%s*%-%-%s*Keymap bind%-category:%s*(.-)%s*$"
					)
					local header = line:match("^%s*%-%-%s*%d+%.%s*(.-)%s*$")
					if bindCategory ~= nil and bindCategory ~= "" then
						pendingBindCategory = bindCategory
						pendingMarkerLine = lineNumber
						pendingMarkerRaw = line
					elseif header ~= nil and header ~= "" then
						currentCategory = header
						appendUnique(headers, headerSeen, header)
					elseif not line:match("^%s*%-%-") then
						local modules = requiredModules(line)
						for _, moduleName in ipairs(modules) do
							local requiredPath = modulePath(path, moduleName)
							if requiredPath ~= nil and not queued[requiredPath] and noctalia.fileExists(requiredPath) then
								queued[requiredPath] = true
								queue[#queue + 1] = requiredPath
							end
						end

						local effectiveCategory = pendingBindCategory or currentCategory
						if effectiveCategory ~= nil then
							local description, dynamic = assignmentLiteral(line, "description")
							if description == nil then
								description, dynamic = assignmentLiteral(line, "desc")
							end
							if description ~= nil and trim(description) ~= "" then
								if dynamic then
									local prefixKey = description .. "\0" .. effectiveCategory
									if not prefixSeen[prefixKey] then
										prefixSeen[prefixKey] = true
										prefixes[#prefixes + 1] = {
											prefix = description,
											category = effectiveCategory,
										}
									end
								elseif exactCategories[description] == nil then
									exactCategories[description] = effectiveCategory
								end
								if keySequences[description] == nil then
									keySequences[description] = multiKeySequence(line)
								end
								if origins[description] == nil then
									local command = generatedCommand(line)
									local action = generatedAction(line)
									local rawSnippet = pendingMarkerRaw ~= nil
										and (pendingMarkerRaw .. "\n" .. line) or line
									origins[description] = {
										source = path,
										line = pendingMarkerLine or lineNumber,
										start_line = pendingMarkerLine or lineNumber,
										end_line = lineNumber,
										managed = path:match("([^/]+)$") == "keymap.lua",
										raw_snippet = rawSnippet,
										fingerprint = fingerprint(rawSnippet),
										action = action,
										capabilities = {
											combo = not dynamic,
											category = not dynamic,
											description = not dynamic,
											command = not dynamic and command ~= nil,
											activation = not dynamic,
										},
									}
								end
							if commands[description] == nil then commands[description] = generatedCommand(line) end
							if actions[description] == nil then actions[description] = generatedAction(line) end
							end
						end
						if line:find("hl.bind", 1, true) ~= nil then
							pendingBindCategory = nil
							pendingMarkerLine = nil
							pendingMarkerRaw = nil
						end
					end
						lineNumber = lineNumber + 1
					end
				end
			end
		end
	end

	if cursor <= #queue then
		warnings[#warnings + 1] = "lua_scan_limit_reached"
	end

	return {
		headers = headers,
		exactCategories = exactCategories,
		prefixes = prefixes,
		keySequences = keySequences,
		origins = origins,
		commands = commands,
		actions = actions,
		warnings = warnings,
		hidden = hidden,
	}
end

local function hasMaskBit(mask, bit)
	return math.floor(mask / bit) % 2 == 1
end

local function decodeModifiers(value)
	local mask = tonumber(value) or 0
	local modifiers = {}
	if hasMaskBit(mask, 64) then
		modifiers[#modifiers + 1] = "Super"
	end
	if hasMaskBit(mask, 1) then
		modifiers[#modifiers + 1] = "Shift"
	end
	if hasMaskBit(mask, 4) then
		modifiers[#modifiers + 1] = "Ctrl"
	end
	if hasMaskBit(mask, 8) then
		modifiers[#modifiers + 1] = "Alt"
	end
	if hasMaskBit(mask, 16) then
		modifiers[#modifiers + 1] = "Mod2"
	end
	if hasMaskBit(mask, 32) then
		modifiers[#modifiers + 1] = "Mod3"
	end
	if hasMaskBit(mask, 128) then
		modifiers[#modifiers + 1] = "Mod5"
	end
	return modifiers
end

local KEY_NAMES = {
	RETURN = "Enter",
	SPACE = "Space",
	ESCAPE = "Esc",
	PRINT = "PrtSc",
	PRIOR = "PgUp",
	NEXT = "PgDn",
	BRACKETLEFT = "[",
	BRACKETRIGHT = "]",
	LEFT = "Left",
	RIGHT = "Right",
	UP = "Up",
	DOWN = "Down",
	MOUSE_DOWN = "Scroll Down",
	MOUSE_UP = "Scroll Up",
	["MOUSE:272"] = "Left Click",
	["MOUSE:273"] = "Right Click",
	["MOUSE:274"] = "Middle Click",
	XF86AUDIORAISEVOLUME = "Vol Up",
	XF86AUDIOLOWERVOLUME = "Vol Down",
	XF86AUDIOMUTE = "Mute",
	XF86AUDIOMICMUTE = "Mic Mute",
	XF86AUDIOPLAY = "Play",
	XF86AUDIOPAUSE = "Pause",
	XF86AUDIONEXT = "Next",
	XF86AUDIOPREV = "Prev",
	XF86AUDIOSTOP = "Stop",
	XF86AUDIOMEDIA = "Media",
	XF86MONBRIGHTNESSUP = "Bright Up",
	XF86MONBRIGHTNESSDOWN = "Bright Down",
	XF86CALCULATOR = "Calc",
	XF86MAIL = "Mail",
	XF86SEARCH = "Search",
	XF86EXPLORER = "Files",
	XF86WWW = "Browser",
	XF86HOMEPAGE = "Home",
	XF86FAVORITES = "Favorites",
	XF86POWEROFF = "Power",
	XF86SLEEP = "Sleep",
	XF86EJECT = "Eject",
}

local function formatKey(value)
	local key = tostring(value or "")
	return KEY_NAMES[key:upper()] or key
end

local function boolFlag(value)
	return value == true and "1" or "0"
end

local function stableBindId(bind)
	local dispatcher = tostring(bind.dispatcher or "")
	local dispatchIdentity = dispatcher
	if dispatcher ~= "__lua" then
		dispatchIdentity = dispatcher .. ":" .. tostring(bind.arg or "")
	end
	local flags = boolFlag(bind.release) .. boolFlag(bind.mouse) .. boolFlag(bind.long_press)
	local identity = table.concat({
		tostring(bind.submap or ""),
		tostring(bind.modmask or 0),
		tostring(bind.key or ""),
		flags,
		dispatchIdentity,
	}, "|")
	return "hypr:" .. fingerprint(identity)
end

-- Hyprland 0.56 can emit invalid JSON for native Lua binds while its plain
-- `hyprctl binds` output remains complete. Keep a strict, line-oriented
-- fallback so the plugin still reads the live registry instead of guessing
-- solely from source files.
local function parseHyprctlText(output)
	if type(output) ~= "string" or output == "" then return nil end
	local records = {}
	local current = nil
	local function finish()
		if current == nil then return end
		if type(current.key) == "string" and current.key ~= "" then
			current.modmask = tonumber(current.modmask) or 0
			current.has_description = type(current.description) == "string" and current.description ~= ""
			local kind = tostring(current._kind or "")
			current.release = kind:find("r", 1, true) ~= nil
			current.mouse = kind:find("m", 1, true) ~= nil
			records[#records + 1] = current
		end
		current = nil
	end
	for line in (output .. "\n"):gmatch("([^\n]*)\n") do
		local kind = line:match("^bind([%a]*)%s*$")
		if kind ~= nil then
			finish()
			current = { _kind = kind }
		elseif current ~= nil then
			local key, value = line:match("^%s+([%w_]+):%s?(.*)$")
			if key ~= nil then current[key] = value end
		end
	end
	finish()
	return #records > 0 and records or nil
end

local function categoryForDescription(description, metadata)
	local exact = metadata.exactCategories[description]
	if exact ~= nil then
		return exact
	end
	local bestCategory = nil
	local bestLength = -1
	for _, entry in ipairs(metadata.prefixes) do
		if description:sub(1, #entry.prefix) == entry.prefix and #entry.prefix > bestLength then
			bestCategory = entry.category
			bestLength = #entry.prefix
		end
	end
	return bestCategory
end

local function slug(value)
	local id = value:lower():gsub("[^%a%d]+", "-"):gsub("^-+", ""):gsub("-+$", "")
	return id ~= "" and id or "category"
end

local function cleanBind(bind)
	return {
		id = bind.id,
		modifiers = bind.modifiers,
		key = bind.key,
		keys = bind.keys,
		description = bind.description,
		dispatcher = bind.dispatcher,
		activation = bind.release == true and "release" or "press",
		source = bind.source,
		line = bind.line,
		managed = bind.managed == true,
		command = bind.command,
		action = bind.action,
		start_line = bind.start_line,
		end_line = bind.end_line,
		raw_snippet = bind.raw_snippet,
		fingerprint = bind.fingerprint,
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
	local description = first.description:gsub("%f[%d]%d+%f[%D]", range, 1)
	return {
		id = "range:" .. first.id .. ":" .. last.id,
		modifiers = first.modifiers,
		key = range,
		description = description,
		dispatcher = first.dispatcher,
		activation = first.release == true and "release" or "press",
	}
end

-- Merge runs even when Hyprland interleaves them (Super+1, Super+Alt+1,
-- Super+2, Super+Alt+2, ...). The V4 adjacent-only implementation missed this.
local function mergeSequential(binds)
	if #binds < 3 then
		local output = {}
		for _, bind in ipairs(binds) do
			output[#output + 1] = cleanBind(bind)
		end
		return output
	end

	local groups = {}
	for index, bind in ipairs(binds) do
		local rawKey = tostring(bind._rawKey or "")
		local number = rawKey:match("^%d+$") and tonumber(rawKey) or nil
		local template, hasNumber = descriptionTemplate(bind.description)
		if number ~= nil and hasNumber then
			local signature = table.concat(bind.modifiers, "+")
				.. "|" .. bind.dispatcher .. "|" .. template
			groups[signature] = groups[signature] or {}
			groups[signature][#groups[signature] + 1] = {
				index = index,
				number = number,
				bind = bind,
			}
		end
	end

	local replacements = {}
	local skipped = {}
	for _, group in pairs(groups) do
		table.sort(group, function(a, b)
			if a.number == b.number then
				return a.index < b.index
			end
			return a.number < b.number
		end)

		local runStart = 1
		for cursor = 2, #group + 1 do
			local continues = cursor <= #group
				and group[cursor].number == group[cursor - 1].number + 1
			if not continues then
				local runLength = cursor - runStart
				if runLength >= 3 then
					local run = {}
					local insertionIndex = group[runStart].index
					for itemIndex = runStart, cursor - 1 do
						local item = group[itemIndex]
						run[#run + 1] = item
						if item.index < insertionIndex then
							insertionIndex = item.index
						end
					end
					replacements[insertionIndex] = mergedBind(run)
					for _, item in ipairs(run) do
						if item.index ~= insertionIndex then
							skipped[item.index] = true
						end
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

local function buildCategories(liveBinds, metadata)
	local showUndescribed = config("show_undescribed", true) == true
	local shouldMerge = config("merge_sequential", true) == true
	local otherName = noctalia.tr("category.other")
	local undescribedName = noctalia.tr("category.undescribed")
	local byName = {}
	local total = 0
	local uncategorized = 0

	for _, raw in ipairs(liveBinds) do
		if type(raw) == "table" and raw.key ~= nil then
			local description = ""
			if raw.has_description ~= false and type(raw.description) == "string" then
				description = raw.description
			end
			local isUndescribed = description == ""
			if showUndescribed or not isUndescribed then
				local categoryName
				if isUndescribed then
					categoryName = undescribedName
				else
					categoryName = categoryForDescription(description, metadata)
					if categoryName == nil then
						categoryName = otherName
						uncategorized = uncategorized + 1
					end
				end

				byName[categoryName] = byName[categoryName] or {}
				byName[categoryName][#byName[categoryName] + 1] = {
					id = stableBindId(raw),
					modifiers = decodeModifiers(raw.modmask),
					key = formatKey(raw.key),
					keys = (function()
						local sequence = metadata.keySequences[description]
						if type(sequence) ~= "table" then return nil end
						local formatted = {}
						for _, value in ipairs(sequence) do formatted[#formatted + 1] = formatKey(value) end
						return formatted
					end)(),
					source = type(metadata.origins[description]) == "table" and metadata.origins[description].source or nil,
					line = type(metadata.origins[description]) == "table" and metadata.origins[description].line or nil,
					managed = type(metadata.origins[description]) == "table"
						and metadata.origins[description].managed == true,
					command = metadata.commands[description],
					action = metadata.actions[description],
					start_line = type(metadata.origins[description]) == "table"
						and metadata.origins[description].start_line or nil,
					end_line = type(metadata.origins[description]) == "table"
						and metadata.origins[description].end_line or nil,
					raw_snippet = type(metadata.origins[description]) == "table"
						and metadata.origins[description].raw_snippet or nil,
					fingerprint = type(metadata.origins[description]) == "table"
						and metadata.origins[description].fingerprint or nil,
					capabilities = type(metadata.origins[description]) == "table"
						and metadata.origins[description].capabilities or nil,
					description = description,
					dispatcher = tostring(raw.dispatcher or ""),
					release = raw.release == true,
					_rawKey = tostring(raw.key),
				}
				total = total + 1
			end
		end
	end

	local categories = {}
	local emitted = {}
	local usedIds = {}
	local function emit(name, preferredId)
		local binds = byName[name]
		if binds == nil or #binds == 0 or emitted[name] then
			return
		end
		emitted[name] = true
		local baseId = preferredId or slug(name)
		local id = baseId
		local suffix = 2
		while usedIds[id] do
			id = baseId .. "-" .. tostring(suffix)
			suffix = suffix + 1
		end
		usedIds[id] = true
		categories[#categories + 1] = {
			id = id,
			name = name,
			binds = shouldMerge and mergeSequential(binds) or (function()
				local output = {}
				for _, bind in ipairs(binds) do
					output[#output + 1] = cleanBind(bind)
				end
				return output
			end)(),
		}
	end

	for _, name in ipairs(metadata.headers) do
		emit(name)
	end
	-- These synthetic buckets are deliberately last and have fixed IDs for UI use.
	local otherBinds = byName[otherName]
	local undescribedBinds = byName[undescribedName]
	for name, _ in pairs(byName) do
		if name ~= otherName and name ~= undescribedName then
			emit(name)
		end
	end
	if otherBinds ~= nil then
		emit(otherName, "other")
	end
	if undescribedBinds ~= nil then
		emit(undescribedName, "undescribed")
	end

	return categories, total, uncategorized
end

local function snapshot(status, source, errorCode, categories, total, warnings, updatedAt, hidden)
	return {
		status = status,
		error = errorCode or "",
		compositor = snapshotCompositor,
		source = source,
		updated_at = updatedAt or "",
		total = total or 0,
		categories = categories or {},
		warnings = warnings or {},
		hidden = hidden or {},
	}
end

local function publishError(source, errorCode, warnings)
	noctalia.state.set(SNAPSHOT_KEY, snapshot("error", source, errorCode, {}, 0, warnings, os.date("%H:%M:%S")))
end

local function finishRefresh()
	refreshing = false
	if refreshQueued then
		refreshQueued = false
		refresh()
	end
end

function refresh()
	refreshGeneration = refreshGeneration + 1
	local requestGeneration = refreshGeneration
	local compositor = configuredCompositor()
	if compositor == nil then
		snapshotCompositor = "Unknown"
		noctalia.state.set(
			SNAPSHOT_KEY,
			snapshot("error", "", "compositor_unknown", {}, 0, {}, os.date("%H:%M:%S"))
		)
		return
	end
	if compositor ~= "hyprland" then
		return
	end
	snapshotCompositor = "Hyprland"
	if refreshing then
		refreshQueued = true
		return
	end
	refreshing = true

	local source = expandedConfigPath()
	-- The panel keeps its last ready snapshot while this status is loading.
	-- Avoid serializing the complete bind tree a second time on every refresh.
	noctalia.state.set(
		SNAPSHOT_KEY,
		snapshot("loading", source, "", {}, 0, {}, "", {})
	)

	if not noctalia.commandExists("hyprctl") then
		publishError(source, "hyprctl_not_found", {})
		finishRefresh()
		return
	end

	local metadata = scanLuaSources(source)
	local function publishLive(liveBinds)
		local categories, total, uncategorized = buildCategories(liveBinds, metadata)
		if uncategorized > 0 then
			metadata.warnings[#metadata.warnings + 1] = "uncategorized_binds:" .. tostring(uncategorized)
		end
		if total == 0 then
			metadata.warnings[#metadata.warnings + 1] = "no_binds"
		end
		noctalia.state.set(
			SNAPSHOT_KEY,
			snapshot("ready", source, "", categories, total, metadata.warnings, os.date("%H:%M:%S"), metadata.hidden)
		)
		finishRefresh()
	end
	local function requestTextFallback()
		local fallbackStarted = noctalia.runAsync("hyprctl binds", function(fallbackResult)
			if requestGeneration ~= refreshGeneration or configuredCompositor() ~= "hyprland" then
				finishRefresh()
				return
			end
			if fallbackResult.timedOut == true then
				publishError(source, "hyprctl_timeout", metadata.warnings)
				finishRefresh()
				return
			end
			local decoded = fallbackResult.exitCode == 0 and parseHyprctlText(fallbackResult.stdout) or nil
			if decoded == nil then
				publishError(source, "hyprctl_invalid_json", metadata.warnings)
				finishRefresh()
				return
			end
			publishLive(decoded)
		end, HYPRCTL_TIMEOUT_MS)
		if not fallbackStarted then
			publishError(source, "hyprctl_start_failed", metadata.warnings)
			finishRefresh()
		end
	end
	local started = noctalia.runAsync("hyprctl binds -j", function(result)
		-- A config change can activate another compositor while hyprctl is still
		-- running. Never let that stale result replace the newer adapter snapshot.
		if requestGeneration ~= refreshGeneration or configuredCompositor() ~= "hyprland" then
			finishRefresh()
			return
		end
		if result.timedOut == true then
			publishError(source, "hyprctl_timeout", metadata.warnings)
			finishRefresh()
			return
		end
		if result.exitCode ~= 0 or type(result.stdout) ~= "string" or result.stdout == "" then
			publishError(source, "hyprctl_failed", metadata.warnings)
			finishRefresh()
			return
		end

		local ok, decoded = pcall(noctalia.json.decode, result.stdout)
		if not ok or type(decoded) ~= "table" then
			requestTextFallback()
			return
		end

		publishLive(decoded)
	end, HYPRCTL_TIMEOUT_MS)

	if not started then
		publishError(source, "hyprctl_start_failed", metadata.warnings)
		finishRefresh()
	end
end

function onIpc(event, _payload)
	if event == "refresh" then
		local current = tonumber(noctalia.state.get(REFRESH_REQUEST_KEY)) or 0
		noctalia.state.set(REFRESH_REQUEST_KEY, current + 1)
	end
end

function onConfigChanged()
	refresh()
end

noctalia.state.watch(REFRESH_REQUEST_KEY, function(_request)
	refresh()
end)

refresh()
