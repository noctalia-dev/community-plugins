--!nonstrict
-- Managed keybind writer for Keymap.
-- The Keymap storage namespace is shared by managed files, includes,
-- category markers, and hidden blocks.

local CREATE_REQUEST_KEY = "keymap.create_request"
local CREATE_RESULT_KEY = "keymap.create_result"
local UPDATE_REQUEST_KEY = "keymap.update_request"
local UPDATE_RESULT_KEY = "keymap.update_result"
local REFRESH_REQUEST_KEY = "keymap.refresh_request"
local LAST_HANDLED_REQUEST_KEY = "keymap.last_handled_create_request"
local LAST_HANDLED_UPDATE_KEY = "keymap.last_handled_update_request"
local SNAPSHOT_KEY = "keymap.snapshot"

local MAX_ROOT_BYTES = 2 * 1024 * 1024
local MAX_MANAGED_BYTES = 1024 * 1024
local MAX_COMMAND_BYTES = 16 * 1024
local RELOAD_TIMEOUT_MS = 5000
local VERIFY_TIMEOUT_MS = 8000
local HIDDEN_BLOCK_VERSION = "v1"
local HIDDEN_DATA_CHUNK_BYTES = 48

local busy = false
local temporaryCounter = 0

local FORMATS = {
	Hyprland = {
		managedName = "keymap.lua",
		comment = "--",
		includeLine = 'require("keymap")',
		reloadCommand = "hyprctl reload",
		validator = "Hyprland --verify-config -c ",
	},
	Niri = {
		managedName = "keymap.kdl",
		comment = "//",
		includeLine = 'include "keymap.kdl"',
		reloadCommand = "niri msg action load-config-file",
		validator = "niri validate -c ",
	},
	MangoWC = {
		managedName = "keymap.conf",
		comment = "#",
		includeLine = "source=./keymap.conf",
		reloadCommand = "mmsg dispatch reload_config",
		validator = "mango -c ",
		validatorSuffix = " -p",
	},
}

local VALID_MODIFIERS = { SUPER = true, CTRL = true, SHIFT = true, ALT = true }

local COMMAND_LIBRARY_ENTRIES = {}
do
	local encoded = noctalia.readFile("command_library.json")
	if type(encoded) == "string" and type(noctalia.json) == "table"
		and type(noctalia.json.decode) == "function" then
		local ok, decoded = pcall(noctalia.json.decode, encoded)
		if ok and type(decoded) == "table" and decoded.schema == 1
			and type(decoded.entries) == "table" then
			for _, entry in ipairs(decoded.entries) do
				if type(entry) == "table" and type(entry.id) == "string" then
					COMMAND_LIBRARY_ENTRIES[entry.id] = entry
				end
			end
		end
	end
end

local function trim(value)
	if type(value) ~= "string" then return "" end
	return value:match("^%s*(.-)%s*$") or ""
end

local function dirname(path)
	local directory = path:match("^(.*)/[^/]*$")
	return directory ~= nil and directory ~= "" and directory or "/"
end

local function hasUnsafeLineCharacters(value)
	return value:find("%c") ~= nil
end

local function validateText(value, name, allowEmpty, maxBytes)
	if type(value) ~= "string" then return nil, "invalid_" .. name end
	if hasUnsafeLineCharacters(value) then return nil, "invalid_" .. name end
	if not allowEmpty and trim(value) == "" then return nil, "empty_" .. name end
	if maxBytes ~= nil and #value > maxBytes then return nil, name .. "_too_large" end
	return value, nil
end

local function validateCategory(value)
	local category, errorCode = validateText(value, "category", false, 80)
	if errorCode ~= nil then return nil, errorCode end
	category = trim(category)
	if category:find('"', 1, true) ~= nil
		or category:find("Keymap managed", 1, true) ~= nil then
		return nil, "category_invalid"
	end
	return category, nil
end

local function escapePattern(value)
	return (value:gsub("([^%w])", "%%%1"))
end

local function matchesLibraryTemplate(template, value)
	if type(template) ~= "string" then return false end
	local pattern = "^"
	local cursor = 1
	while true do
		local first, last = template:find("{{[^}]+}}", cursor)
		if first == nil then
			pattern = pattern .. escapePattern(template:sub(cursor))
			break
		end
		pattern = pattern .. escapePattern(template:sub(cursor, first - 1)) .. "(.+)"
		cursor = last + 1
	end
	return value:match(pattern .. "$") ~= nil
end

local function validateCommandLibrary(raw, compositor, command)
	local commandKind = raw.command_kind == nil and "shell" or raw.command_kind
	if commandKind ~= "shell" and commandKind ~= "native" then
		return nil, nil, "invalid_command_kind"
	end
	local libraryEntryId = type(raw.library_entry_id) == "string" and raw.library_entry_id or ""
	if commandKind == "shell" then return commandKind, libraryEntryId, nil end
	if libraryEntryId == "" then return nil, nil, "library_entry_invalid" end
	local entry = COMMAND_LIBRARY_ENTRIES[libraryEntryId]
	local expectedSource = ({ Hyprland = "hyprland", Niri = "niri", MangoWC = "mangowc" })[compositor]
	if type(entry) ~= "table" or entry.kind ~= "native" or entry.source ~= expectedSource
		or command:find("{{", 1, true) ~= nil
		or not matchesLibraryTemplate(entry.template, command) then
		return nil, nil, command:find("{{", 1, true) ~= nil
			and "library_arguments_required" or "library_entry_invalid"
	end
	return commandKind, libraryEntryId, nil
end

local function validateRequest(raw)
	if type(raw) ~= "table" then return nil, "invalid_request" end

	local rawRequestId = raw.request_id
	if type(rawRequestId) == "number" then rawRequestId = tostring(rawRequestId) end
	local requestId, errorCode = validateText(rawRequestId, "request_id", false, 256)
	if errorCode ~= nil then return nil, errorCode end
	local compositor = raw.compositor
	local format = FORMATS[compositor]
	if format == nil then return nil, "invalid_compositor" end
	local source
	source, errorCode = validateText(raw.source, "source", false, 4096)
	if errorCode ~= nil then return nil, errorCode end
	if source:sub(1, 1) ~= "/" then return nil, "source_not_absolute" end
	if source:match("([^/]+)$") == format.managedName then
		return nil, "source_is_managed_file"
	end

	local activation = raw.activation
	if activation ~= "press" and activation ~= "release" then return nil, "invalid_activation" end
	if compositor == "Niri" and activation ~= "press" then return nil, "niri_release_unsupported" end

	local command
	command, errorCode = validateText(raw.command, "command", false, MAX_COMMAND_BYTES)
	if errorCode ~= nil then return nil, errorCode end
	local commandKind, libraryEntryId
	commandKind, libraryEntryId, errorCode = validateCommandLibrary(raw, compositor, command)
	if errorCode ~= nil then return nil, errorCode end
	local description
	description, errorCode = validateText(raw.description, "description", false, 1024)
	if errorCode ~= nil then return nil, errorCode end
	local category
	category, errorCode = validateCategory(raw.category)
	if errorCode ~= nil then return nil, errorCode end
	if compositor == "MangoWC" and command:find("#", 1, true) ~= nil then
		return nil, "mango_command_hash_unsupported"
	end

	if type(raw.modifiers) ~= "table" then return nil, "invalid_modifiers" end
	local modifiers = {}
	local seenModifiers = {}
	for _, modifier in ipairs(raw.modifiers) do
		if type(modifier) ~= "string" or not VALID_MODIFIERS[modifier] or seenModifiers[modifier] then
			return nil, "invalid_modifiers"
		end
		seenModifiers[modifier] = true
		modifiers[#modifiers + 1] = modifier
	end

	if type(raw.keys) ~= "table" or #raw.keys == 0 then return nil, "empty_keys" end
	if compositor ~= "Hyprland" and #raw.keys ~= 1 then return nil, "multiple_keys_unsupported" end
	if #raw.keys > 16 then return nil, "too_many_keys" end
	local keys = {}
	local seenKeys = {}
	for _, key in ipairs(raw.keys) do
		local checked
		checked, errorCode = validateText(key, "key", false, 128)
		if errorCode ~= nil then return nil, errorCode end
		-- Target key names are tokens in all three compositor grammars. Reject
		-- delimiters instead of attempting to quote compositor syntax itself.
		if not checked:match("^[%w_:%-]+$") then return nil, "invalid_key" end
		if seenKeys[checked] then return nil, "duplicate_key" end
		seenKeys[checked] = true
		keys[#keys + 1] = checked
	end

	return {
		request_id = requestId,
		compositor = compositor,
		format = format,
		source = source,
		modifiers = modifiers,
		keys = keys,
		activation = activation,
		command = command,
		command_kind = commandKind,
		library_entry_id = libraryEntryId,
		description = description,
		category = category,
	}, nil
end

local function validateCurrentContext(request)
	local snapshot = noctalia.state.get(SNAPSHOT_KEY)
	if type(snapshot) ~= "table" or snapshot.status ~= "ready" then return false end
	return snapshot.compositor == request.compositor and snapshot.source == request.source
end

local KEY_EQUIVALENTS = {
	RETURN = "ENTER", ESCAPE = "ESC", PRINT = "PRTSC", SCROLL_LOCK = "SCROLL LOCK",
	PRIOR = "PGUP", NEXT = "PGDN", KP_ENTER = "NUM ENTER", KP_ADD = "NUM +",
	KP_SUBTRACT = "NUM -", KP_MULTIPLY = "NUM *", KP_DIVIDE = "NUM /", KP_DECIMAL = "NUM .",
}

local function comparableKey(value)
	local key = trim(tostring(value or "")):upper():gsub("%s+", " ")
	return KEY_EQUIVALENTS[key] or key
end

local function comparableModifiers(modifiers)
	local result = {}
	for _, modifier in ipairs(type(modifiers) == "table" and modifiers or {}) do
		local value = tostring(modifier):upper()
		if value == "MOD" or value == "META" or value == "WIN" or value == "LOGO" then value = "SUPER" end
		if value == "CONTROL" then value = "CTRL" end
		result[#result + 1] = value
	end
	table.sort(result)
	return table.concat(result, "+")
end

local function comparableKeys(values)
	local result = {}
	for _, value in ipairs(type(values) == "table" and values or {}) do
		result[#result + 1] = comparableKey(value)
	end
	return result
end

local function conflictsWithSnapshot(request, excludedId)
	local snapshot = noctalia.state.get(SNAPSHOT_KEY)
	local modifiers = comparableModifiers(request.modifiers)
	local keys = comparableKeys(request.keys)
	for _, category in ipairs(type(snapshot) == "table" and snapshot.categories or {}) do
		for _, bind in ipairs(type(category.binds) == "table" and category.binds or {}) do
			local bindKeys = comparableKeys(type(bind.keys) == "table" and bind.keys or { bind.key })
			local sameKeys = #bindKeys == #keys
			if sameKeys then
				for index, key in ipairs(keys) do
					if bindKeys[index] ~= key then sameKeys = false break end
				end
			end
			if tostring(bind.id or "") ~= tostring(excludedId or "") and sameKeys
				and comparableModifiers(bind.modifiers) == modifiers
				and tostring(bind.activation or "press") == request.activation then
				return true
			end
		end
	end
	return false
end

local function publishResult(requestId, ok, errorCode, managedPath)
	noctalia.state.set(CREATE_RESULT_KEY, {
		request_id = requestId or "",
		ok = ok == true,
		error = errorCode or "",
		managed_path = managedPath or "",
	})
end

local function publishUpdateResult(requestId, ok, errorCode, targetPath)
	noctalia.state.set(UPDATE_RESULT_KEY, {
		request_id = requestId or "", ok = ok == true, error = errorCode or "", target_path = targetPath or "",
	})
end

local function publishOperationResult(request, ok, errorCode, path)
	if request.operation ~= nil then
		publishUpdateResult(request.request_id, ok, errorCode, path)
	else
		publishResult(request.request_id, ok, errorCode, path)
	end
end

local function luaLongString(value)
	local equals = ""
	while value:find("]" .. equals .. "]", 1, true) ~= nil do
		equals = equals .. "="
	end
	return "[" .. equals .. "[" .. value .. "]" .. equals .. "]"
end

local function quoted(value)
	return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\t", "\\t") .. '"'
end

local function hyprCombo(request)
	local parts = {}
	for _, modifier in ipairs(request.modifiers) do parts[#parts + 1] = modifier end
	for _, key in ipairs(request.keys) do parts[#parts + 1] = key end
	return table.concat(parts, " + ")
end

local function niriCombo(request)
	local parts = {}
	local aliases = { SUPER = "Mod", CTRL = "Ctrl", SHIFT = "Shift", ALT = "Alt" }
	for _, modifier in ipairs(request.modifiers) do parts[#parts + 1] = aliases[modifier] end
	parts[#parts + 1] = request.keys[1]
	return table.concat(parts, "+")
end

local function mangoCombo(request)
	return #request.modifiers > 0 and table.concat(request.modifiers, "+") or "NONE"
end

local function managedHeader(compositor)
	local prefix = FORMATS[compositor].comment
	return prefix .. " Managed by Noctalia Keymap.\n"
		.. prefix .. " Existing entries are preserved; new entries are appended.\n"
end

local function ownsManagedFile(compositor, content)
	return content:sub(1, #managedHeader(compositor)) == managedHeader(compositor)
end

local function generatedEntry(request)
	if request.compositor == "Hyprland" then
		local options = request.activation == "release"
			and ("{ release = true, description = " .. quoted(request.description) .. " }")
			or ("{ description = " .. quoted(request.description) .. " }")
		local dispatcher = request.command_kind == "native"
			and request.command or ("hl.dsp.exec_cmd(" .. luaLongString(request.command) .. ")")
		return "-- 1. " .. request.category .. "\n"
			.. "hl.bind(" .. quoted(hyprCombo(request)) .. ", " .. dispatcher
			.. ", " .. options .. ")\n"
	end
	if request.compositor == "Niri" then
		local action = request.command_kind == "native"
			and request.command or ("spawn-sh " .. quoted(request.command))
		return "    //\"" .. request.category .. "\"\n"
			.. "    " .. niriCombo(request) .. " repeat=false hotkey-overlay-title=" .. quoted(request.description)
			.. " { " .. action .. "; }\n"
	end
	local directive = request.activation == "release" and "bindr" or "bind"
	local description = request.description:gsub("\\", "\\\\"):gsub('"', '\\"')
	local dispatcher = request.command_kind == "native"
		and request.command or ("spawn_shell," .. request.command)
	return "# Keymap category: " .. request.category .. "\n"
		.. directive .. "=" .. mangoCombo(request) .. "," .. request.keys[1]
		.. "," .. dispatcher .. " #\"" .. description .. "\"\n"
end

local function buildManagedContent(request, existing, entry)
	if existing == nil then
		if request.compositor == "Niri" then
			return managedHeader(request.compositor) .. "binds {\n" .. entry .. "}\n", nil
		end
		if request.compositor == "MangoWC" then
			return managedHeader(request.compositor) .. "\nkeymode=default\n\n" .. entry, nil
		end
		return managedHeader(request.compositor) .. "\n" .. entry, nil
	end
	if not ownsManagedFile(request.compositor, existing) then return nil, "managed_file_collision" end
	if #existing > MAX_MANAGED_BYTES then return nil, "managed_file_too_large" end
	if existing:find(entry, 1, true) ~= nil then return existing, nil end

	local output
	if request.compositor == "Niri" then
		local beforeClose = existing:match("^(.*\n)%s*}%s*$")
		if beforeClose == nil then return nil, "managed_file_invalid" end
		output = beforeClose .. entry .. "}\n"
	else
		local separator = (existing == "" or existing:sub(-1) == "\n") and "" or "\n"
		output = existing .. separator .. entry
	end
	if #output > MAX_MANAGED_BYTES then return nil, "managed_file_too_large" end
	return output, nil
end

local function includeBlock(format)
	local beginMarker = format.comment .. " BEGIN Keymap managed include"
	local endMarker = format.comment .. " END Keymap managed include"
	return beginMarker, endMarker, beginMarker .. "\n" .. format.includeLine .. "\n" .. endMarker
end

local function hasExactLine(content, expected)
	for line in (content .. "\n"):gmatch("([^\n]*)\n") do
		if trim(line) == expected then return true end
	end
	return false
end

local function buildRootContent(root, format)
	local beginMarker, endMarker, block = includeBlock(format)
	if root:find(block, 1, true) ~= nil or hasExactLine(root, format.includeLine) then
		return root, nil
	end
	if root:find(beginMarker, 1, true) ~= nil or root:find(endMarker, 1, true) ~= nil then
		return nil, "managed_include_invalid"
	end
	local separator = root == "" and "" or (root:sub(-1) == "\n" and "\n" or "\n\n")
	return root .. separator .. block .. "\n", nil
end

local function atomicWrite(path, content)
	temporaryCounter = temporaryCounter + 1
	local temporary = path .. ".keymap-" .. tostring(os.time())
		.. "-" .. tostring(temporaryCounter) .. ".tmp"
	if noctalia.fileExists(temporary) then return false, "temporary_collision" end
	local written = noctalia.writeFile(temporary, content)
	if written ~= true then
		return false, "write_failed"
	end
	local renamed = noctalia.renameFile(temporary, path)
	if renamed ~= true then
		noctalia.removeFile(temporary)
		return false, "rename_failed"
	end
	return true, nil
end

local function shellQuote(value)
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function rollbackTransaction(transaction)
	if transaction.rootWritten then
		local current = noctalia.readFile(transaction.source)
		if current ~= transaction.rootNew then
			-- Keep the managed file when an external edit prevents restoring the
			-- root. The external root may still contain our include.
			return false
		end
		local restored = atomicWrite(transaction.source, transaction.rootOld)
		if restored ~= true then return false end
	end
	if transaction.managedWritten then
		local current = noctalia.readFile(transaction.managedPath)
		if current ~= transaction.managedNew then
			return false
		elseif transaction.managedExisted then
			local restored = atomicWrite(transaction.managedPath, transaction.managedOld)
			if restored ~= true then return false end
		elseif noctalia.removeFile(transaction.managedPath) ~= true then
			return false
		end
	end
	return true
end

local function publishFailureAfterRollback(request, transaction, errorCode, reloadOld)
	local rolledBack = rollbackTransaction(transaction)
	if reloadOld and rolledBack then
		-- A failed reload may still have applied part of the candidate. Restore the
		-- previous on-disk state and ask the compositor to read it once more.
		local started = noctalia.runAsync(request.format.reloadCommand, function(result)
			local recovered = result.timedOut ~= true and result.exitCode == 0
			publishOperationResult(
				request, false, recovered and errorCode or "recovery_reload_failed", transaction.managedPath
			)
			busy = false
		end, RELOAD_TIMEOUT_MS)
		if not started then
			publishOperationResult(request, false, "recovery_reload_failed", transaction.managedPath)
			busy = false
		end
		return
	end
	publishOperationResult(request, false, rolledBack and errorCode or "rollback_failed", transaction.managedPath)
	busy = false
end

local function finishSuccess(request, managedPath)
	local current = tonumber(noctalia.state.get(REFRESH_REQUEST_KEY)) or 0
	noctalia.state.set(REFRESH_REQUEST_KEY, current + 1)
	publishOperationResult(request, true, "", managedPath)
	busy = false
end

local function reloadAndFinish(request, transaction)
	local started = noctalia.runAsync(request.format.reloadCommand, function(result)
		if result.timedOut == true then
			publishFailureAfterRollback(request, transaction, "reload_timeout", true)
			return
		end
		if result.exitCode ~= 0 then
			publishFailureAfterRollback(request, transaction, "reload_failed", true)
			return
		end
		finishSuccess(request, transaction.managedPath)
	end, RELOAD_TIMEOUT_MS)
	if not started then
		publishFailureAfterRollback(request, transaction, "reload_start_failed", true)
	end
end

local function verifyAndReload(request, transaction)
	local command = request.format.validator .. shellQuote(request.source)
		.. (request.format.validatorSuffix or "")
	local started = noctalia.runAsync(command, function(result)
		if result.timedOut == true then
			publishFailureAfterRollback(request, transaction, "verify_timeout", false)
			return
		end
		if result.exitCode ~= 0 then
			local errorCode = result.exitCode == 127 and "validator_unavailable" or "verify_failed"
			publishFailureAfterRollback(request, transaction, errorCode, false)
			return
		end
		reloadAndFinish(request, transaction)
	end, VERIFY_TIMEOUT_MS)
	if not started then
		publishFailureAfterRollback(request, transaction, "verify_start_failed", false)
	end
end

local function rollbackFileSet(files)
	for index = #files, 1, -1 do
		local file = files[index]
		if file.written then
			if noctalia.readFile(file.path) ~= file.new then return false end
			if atomicWrite(file.path, file.old) ~= true then return false end
		end
	end
	return true
end

local function publishFileSetFailure(request, files, errorCode, reloadOld)
	local rolledBack = rollbackFileSet(files)
	if reloadOld and rolledBack then
		local started = noctalia.runAsync(request.format.reloadCommand, function(result)
			local recovered = result.timedOut ~= true and result.exitCode == 0
			publishUpdateResult(
				request.request_id, false,
				recovered and errorCode or "recovery_reload_failed", request.source
			)
			busy = false
		end, RELOAD_TIMEOUT_MS)
		if not started then
			publishUpdateResult(request.request_id, false, "recovery_reload_failed", request.source)
			busy = false
		end
		return
	end
	publishUpdateResult(
		request.request_id, false, rolledBack and errorCode or "rollback_failed", request.source
	)
	busy = false
end

local function reloadFileSetAndFinish(request, files)
	local started = noctalia.runAsync(request.format.reloadCommand, function(result)
		if result.timedOut == true then
			publishFileSetFailure(request, files, "reload_timeout", true)
			return
		end
		if result.exitCode ~= 0 then
			publishFileSetFailure(request, files, "reload_failed", true)
			return
		end
		finishSuccess(request, request.source)
	end, RELOAD_TIMEOUT_MS)
	if not started then publishFileSetFailure(request, files, "reload_start_failed", true) end
end

local function verifyFileSetAndReload(request, files)
	local command = request.format.validator .. shellQuote(request.source)
		.. (request.format.validatorSuffix or "")
	local started = noctalia.runAsync(command, function(result)
		if result.timedOut == true then
			publishFileSetFailure(request, files, "verify_timeout", false)
			return
		end
		if result.exitCode ~= 0 then
			local errorCode = result.exitCode == 127 and "validator_unavailable" or "verify_failed"
			publishFileSetFailure(request, files, errorCode, false)
			return
		end
		reloadFileSetAndFinish(request, files)
	end, VERIFY_TIMEOUT_MS)
	if not started then publishFileSetFailure(request, files, "verify_start_failed", false) end
end

local processValidatedRequest

local function processRequest(raw)
	local fallbackId = ""
	if type(raw) == "table" then
		local rawId = raw.request_id
		if type(rawId) == "number" then rawId = tostring(rawId) end
		if type(rawId) == "string" and #rawId <= 256 and not hasUnsafeLineCharacters(rawId) then
			fallbackId = rawId
		end
	end
	if busy then
		publishResult(fallbackId, false, "busy", "")
		return
	end
	local request, errorCode = validateRequest(raw)
	if request == nil then
		publishResult(fallbackId, false, errorCode, "")
		return
	end
	if not validateCurrentContext(request) then
		publishResult(request.request_id, false, "stale_context", "")
		return
	end
	busy = true
	local managedPath = dirname(request.source) .. "/" .. request.format.managedName
	local preflight = "[ ! -L " .. shellQuote(request.source) .. " ] && [ ! -L "
		.. shellQuote(managedPath) .. " ]"
	local started = noctalia.runAsync(preflight, function(result)
		if result.timedOut == true or result.exitCode ~= 0 then
			publishResult(request.request_id, false, "symlink_unsupported", managedPath)
			busy = false
			return
		end
		processValidatedRequest(request)
	end, 2000)
	if not started then
		publishResult(request.request_id, false, "preflight_failed", managedPath)
		busy = false
	end
end

processValidatedRequest = function(request)
	local root = noctalia.readFile(request.source)
	if type(root) ~= "string" then
		publishResult(request.request_id, false, "source_unreadable", "")
		busy = false
		return
	end
	if #root > MAX_ROOT_BYTES then
		publishResult(request.request_id, false, "source_too_large", "")
		busy = false
		return
	end

	local managedPath = dirname(request.source) .. "/" .. request.format.managedName
	local existing = nil
	if noctalia.fileExists(managedPath) then
		existing = noctalia.readFile(managedPath)
		if type(existing) ~= "string" then
			publishResult(request.request_id, false, "managed_file_unreadable", managedPath)
			busy = false
			return
		end
	end
	local entry = generatedEntry(request)
	local existingExactEntry = existing ~= nil and existing:find(entry, 1, true) ~= nil
	if conflictsWithSnapshot(request) and not existingExactEntry then
		publishResult(request.request_id, false, "conflict_blocked", managedPath)
		busy = false
		return
	end
	local managed, managedError = buildManagedContent(request, existing, entry)
	if managed == nil then
		publishResult(request.request_id, false, managedError, managedPath)
		busy = false
		return
	end
	local newRoot, rootError = buildRootContent(root, request.format)
	if newRoot == nil then
		publishResult(request.request_id, false, rootError, managedPath)
		busy = false
		return
	end
	if #newRoot > MAX_ROOT_BYTES then
		publishResult(request.request_id, false, "source_too_large", managedPath)
		busy = false
		return
	end

	-- Refuse to overwrite an edit made after the initial read. This check is
	-- intentionally immediately before the first rename.
	if noctalia.readFile(request.source) ~= root then
		publishResult(request.request_id, false, "source_changed", managedPath)
		busy = false
		return
	end
	if existing ~= nil then
		if noctalia.readFile(managedPath) ~= existing then
			publishResult(request.request_id, false, "managed_file_changed", managedPath)
			busy = false
			return
		end
	elseif noctalia.fileExists(managedPath) then
		publishResult(request.request_id, false, "managed_file_changed", managedPath)
		busy = false
		return
	end

	local transaction = {
		source = request.source,
		rootOld = root,
		rootNew = newRoot,
		rootWritten = false,
		managedPath = managedPath,
		managedOld = existing,
		managedNew = managed,
		managedExisted = existing ~= nil,
		managedWritten = false,
	}
	if existing ~= managed then
		if existing ~= nil and noctalia.readFile(managedPath) ~= existing then
			publishResult(request.request_id, false, "managed_file_changed", managedPath)
			busy = false
			return
		end
		local ok, writeError = atomicWrite(managedPath, managed)
		if not ok then
			publishResult(request.request_id, false, "managed_" .. writeError, managedPath)
			busy = false
			return
		end
		transaction.managedWritten = true
	end
	if root ~= newRoot then
		if noctalia.readFile(request.source) ~= root then
			publishFailureAfterRollback(request, transaction, "source_changed", false)
			return
		end
		local ok, writeError = atomicWrite(request.source, newRoot)
		if not ok then
			publishFailureAfterRollback(request, transaction, "source_" .. writeError, false)
			return
		end
		transaction.rootWritten = true
	end
	if not transaction.managedWritten and not transaction.rootWritten then
		finishSuccess(request, managedPath)
		return
	end
	verifyAndReload(request, transaction)
end

local function contentFingerprint(value)
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
	local hash = 2166136261
	for index = 1, #value do
		local low = hash % 256
		hash = hash - low + xorByte(low, value:byte(index))
		hash = (hash * 403 + (hash % 256) * 16777216) % 4294967296
	end
	return string.format("%08x", hash)
end

local function splitLines(content)
	local lines, cursor = {}, 1
	while cursor <= #content do
		local newline = content:find("\n", cursor, true)
		if newline == nil then
			lines[#lines + 1] = content:sub(cursor)
			break
		end
		lines[#lines + 1] = content:sub(cursor, newline - 1)
		cursor = newline + 1
	end
	return lines, content:sub(-1) == "\n"
end

local function replaceLineRange(content, firstLine, lastLine, expected, replacement)
	local lines, trailingNewline = splitLines(content)
	if firstLine < 1 or lastLine < firstLine or lastLine > #lines then return nil, "target_range_invalid" end
	local current = table.concat(lines, "\n", firstLine, lastLine)
	if current ~= expected or contentFingerprint(current) ~= contentFingerprint(expected) then
		return nil, "target_changed"
	end
	local replacementLines = {}
	if replacement ~= "" then
		for line in (replacement .. "\n"):gmatch("([^\n]*)\n") do replacementLines[#replacementLines + 1] = line end
	end
	local output = {}
	for index = 1, firstLine - 1 do output[#output + 1] = lines[index] end
	for _, line in ipairs(replacementLines) do output[#output + 1] = line end
	for index = lastLine + 1, #lines do output[#output + 1] = lines[index] end
	return table.concat(output, "\n") .. (trailingNewline and "\n" or ""), nil
end

local function reorderLineRanges(content, target, anchor, placement, replacementRaw)
	local lines, trailingNewline = splitLines(content)
	local targetFirst, targetLast = tonumber(target.start_line), tonumber(target.end_line)
	local anchorFirst, anchorLast = tonumber(anchor.start_line), tonumber(anchor.end_line)
	if targetFirst < 1 or targetLast < targetFirst or targetLast > #lines then
		return nil, "target_range_invalid"
	end
	if anchorFirst < 1 or anchorLast < anchorFirst or anchorLast > #lines then
		return nil, "anchor_range_invalid"
	end
	if not (targetLast < anchorFirst or anchorLast < targetFirst) then
		return nil, "target_anchor_overlap"
	end

	local targetRaw = tostring(target.raw_snippet or "")
	replacementRaw = replacementRaw == nil and targetRaw or tostring(replacementRaw)
	local anchorRaw = tostring(anchor.raw_snippet or "")
	local currentTarget = table.concat(lines, "\n", targetFirst, targetLast)
	local currentAnchor = table.concat(lines, "\n", anchorFirst, anchorLast)
	if currentTarget ~= targetRaw
		or contentFingerprint(currentTarget) ~= tostring(target.fingerprint or "") then
		return nil, "target_changed"
	end
	if currentAnchor ~= anchorRaw
		or contentFingerprint(currentAnchor) ~= tostring(anchor.fingerprint or "") then
		return nil, "anchor_changed"
	end

	if replacementRaw == targetRaw and (placement == "before" and targetLast + 1 == anchorFirst
		or placement == "after" and anchorLast + 1 == targetFirst) then
		return content, nil
	end

	local targetLines = splitLines(replacementRaw)
	local remaining = {}
	for index, line in ipairs(lines) do
		if index < targetFirst or index > targetLast then remaining[#remaining + 1] = line end
	end
	local targetLength = targetLast - targetFirst + 1
	if targetFirst < anchorFirst then
		anchorFirst = anchorFirst - targetLength
		anchorLast = anchorLast - targetLength
	end
	local insertionIndex = placement == "before" and anchorFirst or anchorLast + 1
	local output = {}
	for index = 1, insertionIndex - 1 do output[#output + 1] = remaining[index] end
	for _, line in ipairs(targetLines) do output[#output + 1] = line end
	for index = insertionIndex, #remaining do output[#output + 1] = remaining[index] end
	return table.concat(output, "\n") .. (trailingNewline and "\n" or ""), nil
end

local function hexEncode(value)
	local output = {}
	for index = 1, #value do output[#output + 1] = string.format("%02x", value:byte(index)) end
	return table.concat(output)
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

-- Hidden blocks are deliberately recognizable only when written by this
-- plugin. Ordinary commented-out bindings remain ordinary user comments and
-- are never offered as restorable targets. The original snippet is hex encoded
-- as bytes so multiline entries, indentation, CRLF and arbitrary command text
-- can be restored without interpreting or normalizing compositor syntax.
local function hiddenSnippet(compositor, snippet)
	local prefix = FORMATS[compositor].comment
	local indent = snippet:match("^([\t ]*)") or ""
	local originalFingerprint = contentFingerprint(snippet)
	local blockId = contentFingerprint(compositor .. "\0" .. snippet)
	local output = {}
	local marker = indent .. prefix .. " Keymap hidden " .. HIDDEN_BLOCK_VERSION
	output[#output + 1] = marker .. " begin " .. blockId .. " " .. originalFingerprint
	for offset = 1, #snippet, HIDDEN_DATA_CHUNK_BYTES do
		output[#output + 1] = marker .. " data " .. hexEncode(snippet:sub(offset, offset + HIDDEN_DATA_CHUNK_BYTES - 1))
	end
	output[#output + 1] = marker .. " end " .. blockId
	return table.concat(output, "\n")
end

local function parseHiddenSnippet(compositor, snippet)
	local format = FORMATS[compositor]
	if format == nil or type(snippet) ~= "string" or snippet == "" then return nil, "hidden_block_invalid" end
	local lines, trailingNewline = splitLines(snippet)
	if trailingNewline or #lines < 3 then return nil, "hidden_block_invalid" end
	local escapedPrefix = format.comment:gsub("(%W)", "%%%1")
	local markerPattern = "^([\t ]*)" .. escapedPrefix .. " Keymap hidden "
		.. HIDDEN_BLOCK_VERSION
	local indent, blockId, expectedFingerprint = lines[1]:match(
		markerPattern .. " begin ([0-9a-f]+) ([0-9a-f]+)$"
	)
	if indent == nil or #blockId ~= 8 or #expectedFingerprint ~= 8 then
		return nil, "hidden_block_invalid"
	end
	local marker = indent .. format.comment .. " Keymap hidden " .. HIDDEN_BLOCK_VERSION
	if lines[#lines] ~= marker .. " end " .. blockId then return nil, "hidden_block_invalid" end
	local encoded = {}
	for index = 2, #lines - 1 do
		local chunk = lines[index]:match("^" .. marker:gsub("(%W)", "%%%1") .. " data ([0-9a-f]+)$")
		if chunk == nil or #chunk > HIDDEN_DATA_CHUNK_BYTES * 2 or #chunk % 2 ~= 0 then
			return nil, "hidden_block_invalid"
		end
		encoded[#encoded + 1] = chunk
	end
	local original = hexDecode(table.concat(encoded))
	if original == nil or original == "" or #original > MAX_ROOT_BYTES then return nil, "hidden_block_invalid" end
	if contentFingerprint(original) ~= expectedFingerprint
		or contentFingerprint(compositor .. "\0" .. original) ~= blockId then
		return nil, "hidden_block_invalid"
	end
	return {
		original = original, original_fingerprint = expectedFingerprint, block_id = blockId,
	}, nil
end

local function replaceLiteralAfter(text, prefixPattern, value, useLongString)
	local _, prefixEnd = text:find(prefixPattern)
	if prefixEnd == nil then return nil end
	local startIndex = prefixEnd + 1
	while text:sub(startIndex, startIndex):match("%s") do startIndex = startIndex + 1 end
	local first = text:sub(startIndex, startIndex)
	local endIndex
	if first == '"' or first == "'" then
		local escaped = false
		for index = startIndex + 1, #text do
			local char = text:sub(index, index)
			if escaped then escaped = false
			elseif char == "\\" then escaped = true
			elseif char == first then endIndex = index break end
		end
	elseif first == "[" then
		local equals = text:sub(startIndex):match("^%[(=*)%[")
		if equals ~= nil then
			local close = "]" .. equals .. "]"
			local closeStart = text:find(close, startIndex + #equals + 2, true)
			if closeStart ~= nil then endIndex = closeStart + #close - 1 end
		end
	end
	if endIndex == nil then return nil end
	local replacement = useLongString and luaLongString(value) or quoted(value)
	return text:sub(1, startIndex - 1) .. replacement .. text:sub(endIndex + 1)
end

local function splitBindCategoryMarker(compositor, snippet)
	local prefix = FORMATS[compositor].comment
	local first, rest = snippet:match("^([^\n]*)\n(.*)$")
	if first == nil then return snippet, false end
	local escapedPrefix = prefix:gsub("(%W)", "%%%1")
	if first:match("^%s*" .. escapedPrefix .. "%s*Keymap bind%-category:%s*.+$") then
		return rest, true
	end
	return snippet, false
end

local function withBindCategoryMarker(compositor, snippet, category, forceMarker)
	if not forceMarker then return snippet end
	local prefix = FORMATS[compositor].comment
	local indent = snippet:match("^(%s*)") or ""
	return indent .. prefix .. " Keymap bind-category: " .. category .. "\n" .. snippet
end

local function renderHyprUpdate(target, request)
	local line = replaceLiteralAfter(target.raw_snippet, "hl%.bind%s*%(%s*", hyprCombo(request), false)
	if line == nil then return nil, "target_not_editable" end
	line = replaceLiteralAfter(line, "description%s*=%s*", request.description, false)
	if line == nil then return nil, "description_not_editable" end
	if target.capabilities.command == true then
		line = replaceLiteralAfter(line, "hl%.dsp%.exec_cmd%s*%(%s*", request.command, true)
		if line == nil then return nil, "command_not_editable" end
	end
	line = line:gsub("release%s*=%s*true%s*,%s*", "", 1)
	line = line:gsub(",%s*release%s*=%s*true%s*", "", 1)
	if request.activation == "release" then
		local prefix, suffix = line:match("^(.*,%s*{%s*)(.*)$")
		if prefix == nil then return nil, "activation_not_editable" end
		line = prefix .. "release = true, " .. suffix
	end
	return line, nil
end

local function renderNiriUpdate(target, request)
	local snippet, count = target.raw_snippet:gsub("^(%s*)%S+", "%1" .. niriCombo(request), 1)
	if count ~= 1 then return nil, "target_not_editable" end
	local described = replaceLiteralAfter(snippet, "hotkey%-overlay%-title%s*=%s*", request.description, false)
	if described == nil then
		described = snippet:gsub("^(%s*%S+)", "%1 hotkey-overlay-title=" .. quoted(request.description), 1)
	end
	snippet = described
	if target.capabilities.command == true then
		snippet = replaceLiteralAfter(snippet, "spawn%-sh%s+", request.command, false)
		if snippet == nil then return nil, "command_not_editable" end
	end
	return snippet, nil
end

local function renderMangoUpdate(target, request)
	local indent, flags, _mods, _key, tail = target.raw_snippet:match("^(%s*)bind([lsrp]*)=([^,]*),([^,]*),(.*)$")
	if indent == nil then return nil, "target_not_editable" end
	flags = flags:gsub("r", "")
	if request.activation == "release" then flags = flags .. "r" end
	local action = tail:gsub('%s+#".*"%s*$', "")
	if target.capabilities.command == true then action = "spawn_shell," .. request.command end
	local description = request.description:gsub("\\", "\\\\"):gsub('"', '\\"')
	return indent .. "bind" .. flags .. "=" .. mangoCombo(request) .. "," .. request.keys[1]
		.. "," .. action .. ' #"' .. description .. '"', nil
end

local function findSnapshotTarget(targetId, hiddenOnly)
	local snapshot = noctalia.state.get(SNAPSHOT_KEY)
	if hiddenOnly ~= true then
		for _, category in ipairs(type(snapshot) == "table" and snapshot.categories or {}) do
			for _, bind in ipairs(type(category.binds) == "table" and category.binds or {}) do
				if tostring(bind.id or "") == tostring(targetId or "") then return bind, category end
			end
		end
	end
	for _, bind in ipairs(type(snapshot) == "table" and type(snapshot.hidden) == "table" and snapshot.hidden or {}) do
		if tostring(bind.id or "") == tostring(targetId or "") then return bind, nil end
	end
	return nil, nil
end

local function findActiveSnapshotTarget(targetId)
	local snapshot = noctalia.state.get(SNAPSHOT_KEY)
	local found, foundCategory
	for _, category in ipairs(type(snapshot) == "table" and snapshot.categories or {}) do
		for _, bind in ipairs(type(category.binds) == "table" and category.binds or {}) do
			if tostring(bind.id or "") == tostring(targetId or "") then
				if found ~= nil then return nil, nil, true end
				found, foundCategory = bind, category
			end
		end
	end
	return found, foundCategory, false
end

local function findSnapshotCategory(categoryId)
	local snapshot = noctalia.state.get(SNAPSHOT_KEY)
	local found
	for _, category in ipairs(type(snapshot) == "table" and snapshot.categories or {}) do
		if tostring(category.id or "") == tostring(categoryId or "") then
			if found ~= nil then return nil, true end
			found = category
		end
	end
	return found, false
end

local function snapshotHasOtherCategoryName(categoryId, name)
	local snapshot = noctalia.state.get(SNAPSHOT_KEY)
	for _, category in ipairs(type(snapshot) == "table" and snapshot.categories or {}) do
		if tostring(category.id or "") ~= tostring(categoryId or "")
			and tostring(category.name or "") == name then return true end
	end
	return false
end

local function processValidatedUpdate(request, target, currentCategory)
	local targetContent = noctalia.readFile(target.source)
	if type(targetContent) ~= "string" then
		publishUpdateResult(request.request_id, false, "source_unreadable", target.source)
		busy = false
		return
	end
	if #targetContent > MAX_ROOT_BYTES then
		publishUpdateResult(request.request_id, false, "source_too_large", target.source)
		busy = false
		return
	end
	if contentFingerprint(tostring(target.raw_snippet or "")) ~= tostring(target.fingerprint or "") then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	local editableSnippet, hadCategoryMarker = splitBindCategoryMarker(
		request.compositor, tostring(target.raw_snippet or "")
	)
	local renderTarget = {}
	for key, value in pairs(target) do renderTarget[key] = value end
	renderTarget.raw_snippet = editableSnippet
	local replacement, renderError
	if request.compositor == "Hyprland" then replacement, renderError = renderHyprUpdate(renderTarget, request)
	elseif request.compositor == "Niri" then replacement, renderError = renderNiriUpdate(renderTarget, request)
	else replacement, renderError = renderMangoUpdate(renderTarget, request) end
	if replacement == nil then
		publishUpdateResult(request.request_id, false, renderError, target.source)
		busy = false
		return
	end
	replacement = withBindCategoryMarker(
		request.compositor, replacement, request.category,
		hadCategoryMarker or request.category ~= tostring(currentCategory or "")
	)
	local updated, rangeError = replaceLineRange(
		targetContent, tonumber(target.start_line) or 0, tonumber(target.end_line) or 0,
		tostring(target.raw_snippet or ""), replacement
	)
	if updated == nil then
		publishUpdateResult(request.request_id, false, rangeError, target.source)
		busy = false
		return
	end
	if #updated > MAX_ROOT_BYTES then
		publishUpdateResult(request.request_id, false, "source_too_large", target.source)
		busy = false
		return
	end
	if noctalia.readFile(target.source) ~= targetContent then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	local rootOld = noctalia.readFile(request.source)
	if type(rootOld) ~= "string" then
		publishUpdateResult(request.request_id, false, "source_unreadable", request.source)
		busy = false
		return
	end
	local transaction = {
		source = request.source, rootOld = rootOld, rootNew = rootOld, rootWritten = false,
		managedPath = target.source, managedOld = targetContent, managedNew = updated,
		managedExisted = true, managedWritten = false,
	}
	if target.source == request.source then
		transaction.rootNew = updated
		local ok = atomicWrite(target.source, updated)
		if not ok then
			publishUpdateResult(request.request_id, false, "source_write_failed", target.source)
			busy = false
			return
		end
		transaction.rootWritten = true
	else
		local ok = atomicWrite(target.source, updated)
		if not ok then
			publishUpdateResult(request.request_id, false, "source_write_failed", target.source)
			busy = false
			return
		end
		transaction.managedWritten = true
	end
	verifyAndReload(request, transaction)
end

local function processValidatedMove(request, target, currentCategory)
	local targetContent = noctalia.readFile(target.source)
	if type(targetContent) ~= "string" then
		publishUpdateResult(request.request_id, false, "source_unreadable", target.source)
		busy = false
		return
	end
	if #targetContent > MAX_ROOT_BYTES then
		publishUpdateResult(request.request_id, false, "source_too_large", target.source)
		busy = false
		return
	end
	local rawSnippet = tostring(target.raw_snippet or "")
	if contentFingerprint(rawSnippet) ~= tostring(target.fingerprint or "") then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	local bindSnippet = splitBindCategoryMarker(request.compositor, rawSnippet)
	local replacement = withBindCategoryMarker(request.compositor, bindSnippet, request.category, true)
	local updated, rangeError = replaceLineRange(
		targetContent, tonumber(target.start_line) or 0, tonumber(target.end_line) or 0,
		rawSnippet, replacement
	)
	if updated == nil then
		publishUpdateResult(request.request_id, false, rangeError, target.source)
		busy = false
		return
	end
	if #updated > MAX_ROOT_BYTES then
		publishUpdateResult(request.request_id, false, "source_too_large", target.source)
		busy = false
		return
	end
	if noctalia.readFile(target.source) ~= targetContent then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	if request.category == currentCategory or updated == targetContent then
		finishSuccess(request, target.source)
		return
	end
	local rootOld = noctalia.readFile(request.source)
	if type(rootOld) ~= "string" then
		publishUpdateResult(request.request_id, false, "source_unreadable", request.source)
		busy = false
		return
	end
	local transaction = {
		source = request.source, rootOld = rootOld, rootNew = rootOld, rootWritten = false,
		managedPath = target.source, managedOld = targetContent, managedNew = updated,
		managedExisted = true, managedWritten = false,
	}
	if noctalia.readFile(target.source) ~= targetContent then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	local ok = atomicWrite(target.source, updated)
	if target.source == request.source then
		transaction.rootNew = updated
		transaction.rootWritten = ok == true
	else
		transaction.managedWritten = ok == true
	end
	if ok ~= true then
		publishUpdateResult(request.request_id, false, "source_write_failed", target.source)
		busy = false
		return
	end
	verifyAndReload(request, transaction)
end

local function processValidatedReorder(request, target, anchor)
	local targetContent = noctalia.readFile(target.source)
	if type(targetContent) ~= "string" then
		publishUpdateResult(request.request_id, false, "source_unreadable", target.source)
		busy = false
		return
	end
	if #targetContent > MAX_ROOT_BYTES then
		publishUpdateResult(request.request_id, false, "source_too_large", target.source)
		busy = false
		return
	end
	if contentFingerprint(tostring(target.raw_snippet or "")) ~= tostring(target.fingerprint or "") then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	if contentFingerprint(tostring(anchor.raw_snippet or "")) ~= tostring(anchor.fingerprint or "") then
		publishUpdateResult(request.request_id, false, "anchor_changed", anchor.source)
		busy = false
		return
	end
	local replacementRaw = tostring(target.raw_snippet or "")
	if request.category ~= request.current_category then
		local bindSnippet = splitBindCategoryMarker(request.compositor, replacementRaw)
		replacementRaw = withBindCategoryMarker(request.compositor, bindSnippet, request.category, true)
	end
	local updated, reorderError = reorderLineRanges(
		targetContent, target, anchor, request.placement, replacementRaw
	)
	if updated == nil then
		publishUpdateResult(request.request_id, false, reorderError, target.source)
		busy = false
		return
	end
	if updated == targetContent then
		finishSuccess(request, target.source)
		return
	end
	if noctalia.readFile(target.source) ~= targetContent then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	local rootOld = noctalia.readFile(request.source)
	if type(rootOld) ~= "string" then
		publishUpdateResult(request.request_id, false, "source_unreadable", request.source)
		busy = false
		return
	end
	local transaction = {
		source = request.source, rootOld = rootOld, rootNew = rootOld, rootWritten = false,
		managedPath = target.source, managedOld = targetContent, managedNew = updated,
		managedExisted = true, managedWritten = false,
	}
	if noctalia.readFile(target.source) ~= targetContent then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	local ok = atomicWrite(target.source, updated)
	if target.source == request.source then
		transaction.rootNew = updated
		transaction.rootWritten = ok == true
	else
		transaction.managedWritten = ok == true
	end
	if ok ~= true then
		publishUpdateResult(request.request_id, false, "source_write_failed", target.source)
		busy = false
		return
	end
	verifyAndReload(request, transaction)
end

local function processValidatedCategoryRename(request, category)
	local grouped = {}
	local paths = {}
	for _, bind in ipairs(category.binds) do
		local group = grouped[bind.source]
		if group == nil then
			group = { path = bind.source, entries = {} }
			grouped[bind.source] = group
			paths[#paths + 1] = bind.source
		end
		group.entries[#group.entries + 1] = bind
	end
	table.sort(paths)

	local files = {}
	for _, path in ipairs(paths) do
		local group = grouped[path]
		local content = noctalia.readFile(path)
		if type(content) ~= "string" then
			publishUpdateResult(request.request_id, false, "source_unreadable", path)
			busy = false
			return
		end
		if #content > MAX_ROOT_BYTES then
			publishUpdateResult(request.request_id, false, "source_too_large", path)
			busy = false
			return
		end
		local lines = splitLines(content)
		table.sort(group.entries, function(left, right)
			return left.start_line < right.start_line
		end)
		local previousLast = 0
		for _, bind in ipairs(group.entries) do
			local rawSnippet = tostring(bind.raw_snippet or "")
			if bind.start_line <= previousLast then
				publishUpdateResult(request.request_id, false, "category_ranges_overlap", path)
				busy = false
				return
			end
			previousLast = bind.end_line
			if bind.end_line > #lines then
				publishUpdateResult(request.request_id, false, "target_range_invalid", path)
				busy = false
				return
			end
			local current = table.concat(lines, "\n", bind.start_line, bind.end_line)
			if contentFingerprint(rawSnippet) ~= tostring(bind.fingerprint or "")
				or current ~= rawSnippet
				or contentFingerprint(current) ~= tostring(bind.fingerprint or "") then
				publishUpdateResult(request.request_id, false, "target_changed", path)
				busy = false
				return
			end
		end

		local updated = content
		if request.new_category ~= request.old_category then
			for index = #group.entries, 1, -1 do
				local bind = group.entries[index]
				local bindSnippet = splitBindCategoryMarker(request.compositor, bind.raw_snippet)
				local replacement = withBindCategoryMarker(
					request.compositor, bindSnippet, request.new_category, true
				)
				local rangeError
				updated, rangeError = replaceLineRange(
					updated, bind.start_line, bind.end_line, bind.raw_snippet, replacement
				)
				if updated == nil then
					publishUpdateResult(request.request_id, false, rangeError, path)
					busy = false
					return
				end
			end
		end
		if #updated > MAX_ROOT_BYTES then
			publishUpdateResult(request.request_id, false, "source_too_large", path)
			busy = false
			return
		end
		files[#files + 1] = { path = path, old = content, new = updated, written = false }
	end

	local rootContent = noctalia.readFile(request.source)
	if type(rootContent) ~= "string" then
		publishUpdateResult(request.request_id, false, "source_unreadable", request.source)
		busy = false
		return
	end
	local changed = false
	for _, file in ipairs(files) do
		if file.old ~= file.new then changed = true end
		if noctalia.readFile(file.path) ~= file.old then
			publishUpdateResult(request.request_id, false, "target_changed", file.path)
			busy = false
			return
		end
	end
	if not changed then
		finishSuccess(request, request.source)
		return
	end
	for _, file in ipairs(files) do
		if file.old ~= file.new then
			local ok = atomicWrite(file.path, file.new)
			if ok ~= true then
				local rolledBack = rollbackFileSet(files)
				publishUpdateResult(
					request.request_id, false,
					rolledBack and "source_write_failed" or "rollback_failed", file.path
				)
				busy = false
				return
			end
			file.written = true
		end
	end
	verifyFileSetAndReload(request, files)
end

local function processValidatedMutation(request, target)
	local targetContent = noctalia.readFile(target.source)
	if type(targetContent) ~= "string" then
		publishUpdateResult(request.request_id, false, "source_unreadable", target.source)
		busy = false
		return
	end
	if #targetContent > MAX_ROOT_BYTES then
		publishUpdateResult(request.request_id, false, "source_too_large", target.source)
		busy = false
		return
	end
	local rawSnippet = tostring(target.raw_snippet or "")
	if contentFingerprint(rawSnippet) ~= tostring(target.fingerprint or "") then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	local replacement = ""
	if request.operation == "hide" then
		replacement = hiddenSnippet(request.compositor, rawSnippet)
	elseif target.hidden == true then
		local hidden, hiddenError = parseHiddenSnippet(request.compositor, rawSnippet)
		if hidden == nil then
			publishUpdateResult(request.request_id, false, hiddenError, target.source)
			busy = false
			return
		end
		if type(target.original_fingerprint) == "string" and target.original_fingerprint ~= ""
			and target.original_fingerprint ~= hidden.original_fingerprint then
			publishUpdateResult(request.request_id, false, "hidden_block_invalid", target.source)
			busy = false
			return
		end
		if request.operation == "restore" then replacement = hidden.original end
	end
	local updated, rangeError = replaceLineRange(
		targetContent, tonumber(target.start_line) or 0, tonumber(target.end_line) or 0,
		rawSnippet, replacement
	)
	if updated == nil then
		publishUpdateResult(request.request_id, false, rangeError, target.source)
		busy = false
		return
	end
	if #updated > MAX_ROOT_BYTES then
		publishUpdateResult(request.request_id, false, "source_too_large", target.source)
		busy = false
		return
	end
	if noctalia.readFile(target.source) ~= targetContent then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	local rootOld = noctalia.readFile(request.source)
	if type(rootOld) ~= "string" then
		publishUpdateResult(request.request_id, false, "source_unreadable", request.source)
		busy = false
		return
	end
	local transaction = {
		source = request.source, rootOld = rootOld, rootNew = rootOld, rootWritten = false,
		managedPath = target.source, managedOld = targetContent, managedNew = updated,
		managedExisted = true, managedWritten = false,
	}
	if noctalia.readFile(target.source) ~= targetContent then
		publishUpdateResult(request.request_id, false, "target_changed", target.source)
		busy = false
		return
	end
	local ok
	if target.source == request.source then
		transaction.rootNew = updated
		ok = atomicWrite(target.source, updated)
		transaction.rootWritten = ok == true
	else
		ok = atomicWrite(target.source, updated)
		transaction.managedWritten = ok == true
	end
	if ok ~= true then
		publishUpdateResult(request.request_id, false, "source_write_failed", target.source)
		busy = false
		return
	end
	verifyAndReload(request, transaction)
end

local function processMoveRequest(raw, target, currentCategory)
	local rawId = raw.request_id
	if type(rawId) == "number" then rawId = tostring(rawId) end
	local requestId, errorCode = validateText(rawId, "request_id", false, 256)
	if errorCode ~= nil then publishUpdateResult(rawId, false, errorCode, target.source) return end
	if raw.operation ~= "move" then
		publishUpdateResult(requestId, false, "invalid_operation", target.source)
		return
	end
	local compositor = raw.compositor
	local format = FORMATS[compositor]
	if format == nil then publishUpdateResult(requestId, false, "invalid_compositor", target.source) return end
	local source
	source, errorCode = validateText(raw.source, "source", false, 4096)
	if errorCode ~= nil or source:sub(1, 1) ~= "/" then
		publishUpdateResult(requestId, false, errorCode or "source_not_absolute", target.source)
		return
	end
	local category
	category, errorCode = validateCategory(raw.category)
	if errorCode ~= nil then publishUpdateResult(requestId, false, errorCode, target.source) return end
	local targetId
	targetId, errorCode = validateText(raw.target_id, "target_id", false, 256)
	if errorCode ~= nil then publishUpdateResult(requestId, false, errorCode, target.source) return end
	local targetSource, targetSourceError = validateText(target.source, "target_source", false, 4096)
	if targetSourceError ~= nil then targetSource = "" end
	local firstLine, lastLine = tonumber(target.start_line), tonumber(target.end_line)
	local capabilities = type(target.capabilities) == "table" and target.capabilities or {}
	local currentCategoryName = type(currentCategory) == "table" and tostring(currentCategory.name or "") or nil
	if capabilities.category ~= true or tostring(target.id or "") ~= targetId
		or targetId:match("^range:") or targetSource == "" or targetSource:sub(1, 1) ~= "/"
		or type(target.start_line) ~= "number" or firstLine < 1 or firstLine % 1 ~= 0
		or type(target.end_line) ~= "number" or lastLine < firstLine or lastLine % 1 ~= 0
		or type(target.raw_snippet) ~= "string" or target.raw_snippet == ""
		or type(target.fingerprint) ~= "string" or target.fingerprint == ""
		or currentCategoryName == nil then
		publishUpdateResult(requestId, false, "target_not_editable", targetSource)
		return
	end
	local request = {
		request_id = requestId, operation = "move", compositor = compositor,
		format = format, source = source, target_id = targetId, category = category,
	}
	if not validateCurrentContext(request) then
		publishUpdateResult(requestId, false, "stale_context", targetSource)
		return
	end
	busy = true
	local preflight = "[ ! -L " .. shellQuote(request.source) .. " ] && [ ! -L "
		.. shellQuote(targetSource) .. " ]"
	local started = noctalia.runAsync(preflight, function(result)
		if result.timedOut == true or result.exitCode ~= 0 then
			publishUpdateResult(requestId, false, "symlink_unsupported", targetSource)
			busy = false
		else
			processValidatedMove(request, target, currentCategoryName)
		end
	end, 2000)
	if not started then
		publishUpdateResult(requestId, false, "preflight_failed", targetSource)
		busy = false
	end
end

local function validReorderEndpoint(bind, expectedId)
	local firstLine, lastLine = tonumber(bind.start_line), tonumber(bind.end_line)
	return bind.hidden ~= true
		and tostring(bind.id or "") == expectedId
		and not expectedId:match("^range:")
		and type(bind.source) == "string" and bind.source:sub(1, 1) == "/"
		and type(bind.start_line) == "number" and firstLine >= 1 and firstLine % 1 == 0
		and type(bind.end_line) == "number" and lastLine >= firstLine and lastLine % 1 == 0
		and type(bind.raw_snippet) == "string" and bind.raw_snippet ~= ""
		and type(bind.fingerprint) == "string" and bind.fingerprint ~= ""
end

local function validCategoryRenameBind(bind)
	local firstLine, lastLine = tonumber(bind.start_line), tonumber(bind.end_line)
	local capabilities = type(bind.capabilities) == "table" and bind.capabilities or {}
	local bindId = tostring(bind.id or "")
	return bind.hidden ~= true and bindId ~= "" and not bindId:match("^range:")
		and capabilities.category == true
		and type(bind.source) == "string" and bind.source:sub(1, 1) == "/"
		and type(bind.start_line) == "number" and firstLine >= 1 and firstLine % 1 == 0
		and type(bind.end_line) == "number" and lastLine >= firstLine and lastLine % 1 == 0
		and type(bind.raw_snippet) == "string" and bind.raw_snippet ~= ""
		and type(bind.fingerprint) == "string" and bind.fingerprint ~= ""
end

local function processCategoryRenameRequest(raw, category)
	local rawId = raw.request_id
	if type(rawId) == "number" then rawId = tostring(rawId) end
	local requestId, errorCode = validateText(rawId, "request_id", false, 256)
	if errorCode ~= nil then publishUpdateResult(rawId, false, errorCode, "") return end
	local compositor = raw.compositor
	local format = FORMATS[compositor]
	if format == nil then publishUpdateResult(requestId, false, "invalid_compositor", "") return end
	local source
	source, errorCode = validateText(raw.source, "source", false, 4096)
	if errorCode ~= nil or source:sub(1, 1) ~= "/" then
		publishUpdateResult(requestId, false, errorCode or "source_not_absolute", "")
		return
	end
	local categoryId
	categoryId, errorCode = validateText(raw.category_id, "category_id", false, 256)
	if errorCode ~= nil then publishUpdateResult(requestId, false, errorCode, source) return end
	local oldCategory
	oldCategory, errorCode = validateCategory(raw.old_category)
	if errorCode ~= nil then publishUpdateResult(requestId, false, errorCode, source) return end
	local newCategory
	newCategory, errorCode = validateCategory(raw.new_category)
	if errorCode ~= nil then publishUpdateResult(requestId, false, errorCode, source) return end
	if tostring(category.id or "") ~= categoryId or tostring(category.name or "") ~= oldCategory then
		publishUpdateResult(requestId, false, "stale_category", source)
		return
	end
	if snapshotHasOtherCategoryName(categoryId, newCategory) then
		publishUpdateResult(requestId, false, "category_exists", source)
		return
	end
	if not validateCurrentContext({ compositor = compositor, source = source }) then
		publishUpdateResult(requestId, false, "stale_context", source)
		return
	end
	if type(category.binds) ~= "table" or #category.binds == 0 then
		publishUpdateResult(requestId, false, "category_not_editable", source)
		return
	end
	local bindIds = {}
	local paths, pathSeen = { source }, { [source] = true }
	for _, bind in ipairs(category.binds) do
		local bindId = tostring(bind.id or "")
		if not validCategoryRenameBind(bind) or bindIds[bindId] then
			publishUpdateResult(requestId, false, "category_not_editable", source)
			return
		end
		bindIds[bindId] = true
		if not pathSeen[bind.source] then
			pathSeen[bind.source] = true
			paths[#paths + 1] = bind.source
		end
	end
	table.sort(paths)
	local request = {
		request_id = requestId, operation = "rename_category", compositor = compositor,
		format = format, source = source, category_id = categoryId,
		old_category = oldCategory, new_category = newCategory,
	}
	busy = true
	local checks = {}
	for _, path in ipairs(paths) do checks[#checks + 1] = "[ ! -L " .. shellQuote(path) .. " ]" end
	local started = noctalia.runAsync(table.concat(checks, " && "), function(result)
		if result.timedOut == true or result.exitCode ~= 0 then
			publishUpdateResult(requestId, false, "symlink_unsupported", source)
			busy = false
		else
			processValidatedCategoryRename(request, category)
		end
	end, 2000)
	if not started then
		publishUpdateResult(requestId, false, "preflight_failed", source)
		busy = false
	end
end

local function processReorderRequest(raw, target, anchor, currentCategory, anchorCategory)
	local rawId = raw.request_id
	if type(rawId) == "number" then rawId = tostring(rawId) end
	local requestId, errorCode = validateText(rawId, "request_id", false, 256)
	if errorCode ~= nil then publishUpdateResult(rawId, false, errorCode, "") return end
	local compositor = raw.compositor
	local format = FORMATS[compositor]
	if format == nil then publishUpdateResult(requestId, false, "invalid_compositor", "") return end
	local source
	source, errorCode = validateText(raw.source, "source", false, 4096)
	if errorCode ~= nil or source:sub(1, 1) ~= "/" then
		publishUpdateResult(requestId, false, errorCode or "source_not_absolute", "")
		return
	end
	local targetId
	targetId, errorCode = validateText(raw.target_id, "target_id", false, 256)
	if errorCode ~= nil then publishUpdateResult(requestId, false, errorCode, "") return end
	local anchorId
	anchorId, errorCode = validateText(raw.anchor_id, "anchor_id", false, 256)
	if errorCode ~= nil then publishUpdateResult(requestId, false, errorCode, "") return end
	if targetId == anchorId then
		publishUpdateResult(requestId, false, "anchor_is_target", tostring(target.source or ""))
		return
	end
	if raw.placement ~= "before" and raw.placement ~= "after" then
		publishUpdateResult(requestId, false, "invalid_placement", tostring(target.source or ""))
		return
	end
	if not validReorderEndpoint(target, targetId) or not validReorderEndpoint(anchor, anchorId) then
		publishUpdateResult(requestId, false, "target_not_editable", tostring(target.source or ""))
		return
	end
	if target.source ~= anchor.source then
		publishUpdateResult(requestId, false, "different_source", target.source)
		return
	end
	local currentCategoryName = type(currentCategory) == "table" and tostring(currentCategory.name or "") or ""
	local anchorCategoryName = type(anchorCategory) == "table" and tostring(anchorCategory.name or "") or ""
	local category
	category, errorCode = validateCategory(anchorCategoryName)
	if errorCode ~= nil or currentCategoryName == "" then
		publishUpdateResult(requestId, false, errorCode or "invalid_category", target.source)
		return
	end
	local targetCapabilities = type(target.capabilities) == "table" and target.capabilities or {}
	if currentCategoryName ~= category and targetCapabilities.category ~= true then
		publishUpdateResult(requestId, false, "target_not_editable", target.source)
		return
	end
	local targetFirst, targetLast = tonumber(target.start_line), tonumber(target.end_line)
	local anchorFirst, anchorLast = tonumber(anchor.start_line), tonumber(anchor.end_line)
	if not (targetLast < anchorFirst or anchorLast < targetFirst) then
		publishUpdateResult(requestId, false, "target_anchor_overlap", target.source)
		return
	end
	local request = {
		request_id = requestId, operation = "reorder", compositor = compositor, format = format,
		source = source, target_id = targetId, anchor_id = anchorId, placement = raw.placement,
		category = category, current_category = currentCategoryName,
	}
	if not validateCurrentContext(request) then
		publishUpdateResult(requestId, false, "stale_context", target.source)
		return
	end
	busy = true
	local preflight = "[ ! -L " .. shellQuote(request.source) .. " ] && [ ! -L "
		.. shellQuote(target.source) .. " ]"
	local started = noctalia.runAsync(preflight, function(result)
		if result.timedOut == true or result.exitCode ~= 0 then
			publishUpdateResult(requestId, false, "symlink_unsupported", target.source)
			busy = false
		else
			processValidatedReorder(request, target, anchor)
		end
	end, 2000)
	if not started then
		publishUpdateResult(requestId, false, "preflight_failed", target.source)
		busy = false
	end
end

local function processMutationRequest(raw, target)
	local rawId = raw.request_id
	if type(rawId) == "number" then rawId = tostring(rawId) end
	local requestId, errorCode = validateText(rawId, "request_id", false, 256)
	if errorCode ~= nil then publishUpdateResult(rawId, false, errorCode, target.source) return end
	local operation = raw.operation
	if operation ~= "hide" and operation ~= "restore" and operation ~= "delete" then
		publishUpdateResult(requestId, false, "invalid_operation", target.source)
		return
	end
	local compositor = raw.compositor
	local format = FORMATS[compositor]
	if format == nil then publishUpdateResult(requestId, false, "invalid_compositor", target.source) return end
	local source
	source, errorCode = validateText(raw.source, "source", false, 4096)
	if errorCode ~= nil or source:sub(1, 1) ~= "/" then
		publishUpdateResult(requestId, false, errorCode or "source_not_absolute", target.source)
		return
	end
	local targetId
	targetId, errorCode = validateText(raw.target_id, "target_id", false, 256)
	if errorCode ~= nil then publishUpdateResult(requestId, false, errorCode, target.source) return end
	local targetSource, targetSourceError = validateText(target.source, "target_source", false, 4096)
	if targetSourceError ~= nil then targetSource = "" end
	local firstLine, lastLine = tonumber(target.start_line), tonumber(target.end_line)
	local capabilities = type(target.capabilities) == "table" and target.capabilities or {}
	local hiddenTarget = target.hidden == true
	local allowedByType = hiddenTarget
		and (operation == "restore" or operation == "delete")
		or (not hiddenTarget and operation ~= "restore"
			and capabilities.combo == true and capabilities.description == true)
	if not allowedByType or tostring(target.id or "") ~= targetId
		or targetId:match("^range:") or targetSource == "" or targetSource:sub(1, 1) ~= "/"
		or type(target.start_line) ~= "number" or firstLine < 1 or firstLine % 1 ~= 0
		or type(target.end_line) ~= "number" or lastLine < firstLine or lastLine % 1 ~= 0
		or type(target.raw_snippet) ~= "string" or target.raw_snippet == ""
		or tostring(target.fingerprint or "") == "" then
		publishUpdateResult(requestId, false,
			operation == "restore" and not hiddenTarget and "target_not_hidden" or "target_not_editable",
			targetSource)
		return
	end
	local request = {
		request_id = requestId, operation = operation, compositor = compositor,
		format = format, source = source, target_id = targetId,
	}
	if not validateCurrentContext(request) then
		publishUpdateResult(requestId, false, "stale_context", target.source)
		return
	end
	busy = true
	local preflight = "[ ! -L " .. shellQuote(request.source) .. " ] && [ ! -L "
		.. shellQuote(targetSource) .. " ]"
	local started = noctalia.runAsync(preflight, function(result)
		if result.timedOut == true or result.exitCode ~= 0 then
			publishUpdateResult(requestId, false, "symlink_unsupported", targetSource)
			busy = false
		else
			processValidatedMutation(request, target)
		end
	end, 2000)
	if not started then
		publishUpdateResult(requestId, false, "preflight_failed", targetSource)
		busy = false
	end
end

local function processUpdateRequest(raw)
	local rawId = type(raw) == "table" and raw.request_id or ""
	if type(rawId) == "number" then rawId = tostring(rawId) end
	if busy then publishUpdateResult(rawId, false, "busy", "") return end
	if type(raw) ~= "table" then publishUpdateResult(rawId, false, "invalid_request", "") return end
	if raw.command_kind == "native" then
		publishUpdateResult(rawId, false, "native_update_unsupported", "")
		return
	end
	if raw.operation == "rename_category" then
		local category, ambiguous = findSnapshotCategory(raw.category_id)
		if ambiguous then publishUpdateResult(rawId, false, "category_ambiguous", "") return end
		if category == nil then publishUpdateResult(rawId, false, "category_not_found", "") return end
		processCategoryRenameRequest(raw, category)
		return
	end
	if raw.operation == "reorder" then
		local target, targetCategory, targetAmbiguous = findActiveSnapshotTarget(raw.target_id)
		if targetAmbiguous then publishUpdateResult(rawId, false, "target_ambiguous", "") return end
		if target == nil then publishUpdateResult(rawId, false, "target_not_found", "") return end
		local anchor, anchorCategory, anchorAmbiguous = findActiveSnapshotTarget(raw.anchor_id)
		if anchorAmbiguous then publishUpdateResult(rawId, false, "anchor_ambiguous", "") return end
		if anchor == nil then publishUpdateResult(rawId, false, "anchor_not_found", "") return end
		processReorderRequest(raw, target, anchor, targetCategory, anchorCategory)
		return
	end
	local target, category = findSnapshotTarget(
		raw.target_id, raw.operation == "restore" or (raw.operation == "delete" and raw.hidden == true)
	)
	if target == nil then publishUpdateResult(rawId, false, "target_not_found", "") return end
	if raw.operation == "move" then
		processMoveRequest(raw, target, category)
		return
	end
	if raw.operation == "hide" or raw.operation == "restore" or raw.operation == "delete" then
		processMutationRequest(raw, target)
		return
	end
	local capabilities = type(target.capabilities) == "table" and target.capabilities or {}
	local validationRaw = {}
	for key, value in pairs(raw) do validationRaw[key] = value end
	if trim(tostring(validationRaw.command or "")) == "" and capabilities.command ~= true then
		validationRaw.command = "__preserve_native_action__"
	end
	local request, errorCode = validateRequest(validationRaw)
	if request == nil then publishUpdateResult(rawId, false, errorCode, target.source) return end
	request.operation = "update"
	request.target_id = tostring(raw.target_id or "")
	if capabilities.command ~= true then request.command = tostring(target.command or "") end
	if not validateCurrentContext(request) then
		publishUpdateResult(request.request_id, false, "stale_context", target.source) return
	end
	if capabilities.combo ~= true or capabilities.description ~= true then
		publishUpdateResult(request.request_id, false, "target_not_editable", target.source) return
	end
	if conflictsWithSnapshot(request, request.target_id) then
		publishUpdateResult(request.request_id, false, "conflict_blocked", target.source) return
	end
	busy = true
	local preflight = "[ ! -L " .. shellQuote(request.source) .. " ] && [ ! -L " .. shellQuote(target.source) .. " ]"
	local started = noctalia.runAsync(preflight, function(result)
		if result.timedOut == true or result.exitCode ~= 0 then
			publishUpdateResult(request.request_id, false, "symlink_unsupported", target.source)
			busy = false
		else processValidatedUpdate(request, target, category.name) end
	end, 2000)
	if not started then
		publishUpdateResult(request.request_id, false, "preflight_failed", target.source)
		busy = false
	end
end

function onIpc(event, payload)
	if event ~= "create-json" and event ~= "update-json" then return end
	local process = event == "update-json" and processUpdateRequest or processRequest
	local publish = event == "update-json" and publishUpdateResult or publishResult
	if type(payload) == "table" then
		process(payload)
		return
	end
	if type(payload) ~= "string" then
		publish("", false, "invalid_json", "")
		return
	end
	local ok, decoded = pcall(noctalia.json.decode, payload)
	if not ok or type(decoded) ~= "table" then
		publish("", false, "invalid_json", "")
		return
	end
	process(decoded)
end

-- Writes are transactional and do not read plugin settings. Keeping this VM
-- alive across appearance/path setting changes lets an in-flight validation,
-- reload, or rollback finish and publish its result to the panel.
function onConfigChanged()
end

noctalia.state.watch(CREATE_REQUEST_KEY, function(request)
	local requestId = type(request) == "table" and request.request_id or nil
	if type(requestId) == "number" then requestId = tostring(requestId) end
	if type(requestId) == "string" and requestId ~= "" then
		if tostring(noctalia.state.get(LAST_HANDLED_REQUEST_KEY) or "") == requestId then return end
		-- Mark before processing so a service/config reload cannot replay a
		-- request that is already validating or reloading asynchronously.
		noctalia.state.set(LAST_HANDLED_REQUEST_KEY, requestId)
	end
	processRequest(request)
end)

noctalia.state.watch(UPDATE_REQUEST_KEY, function(request)
	local requestId = type(request) == "table" and request.request_id or nil
	if type(requestId) == "number" then requestId = tostring(requestId) end
	if type(requestId) == "string" and requestId ~= "" then
		if tostring(noctalia.state.get(LAST_HANDLED_UPDATE_KEY) or "") == requestId then return end
		noctalia.state.set(LAST_HANDLED_UPDATE_KEY, requestId)
	end
	processUpdateRequest(request)
end)
