local files = {}
local stateValues = {}
local watchers = {}
local failVerify = false
local failReload = false
local reloadAttempts = 0
local writeCount = 0
local failRenameAt = nil
local renameAttempts = 0

noctalia = {
	state = {
		get = function(key) return stateValues[key] end,
		set = function(key, value)
			stateValues[key] = value
			if watchers[key] ~= nil then watchers[key](value) end
		end,
		watch = function(key, callback) watchers[key] = callback end,
	},
	readFile = function(path) return files[path] end,
	fileExists = function(path) return files[path] ~= nil end,
	writeFile = function(path, content)
		writeCount = writeCount + 1
		files[path] = content
		return true
	end,
	renameFile = function(source, target)
		renameAttempts = renameAttempts + 1
		if failRenameAt ~= nil and renameAttempts == failRenameAt then return false end
		if files[source] == nil then return false end
		files[target] = files[source]
		files[source] = nil
		return true
	end,
	removeFile = function(path) files[path] = nil return true end,
	runAsync = function(command, callback, _timeout)
		local result = { exitCode = 0, timedOut = false }
		if failVerify and command:find("verify", 1, true) ~= nil then result.exitCode = 1 end
		if failReload and command == "hyprctl reload" then
			reloadAttempts = reloadAttempts + 1
			if reloadAttempts == 1 then result.exitCode = 1 end
		end
		callback(result)
		return true
	end,
	json = { decode = function() return {} end },
}

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

local function fingerprint(value)
	local hash = 2166136261
	for index = 1, #value do
		local low = hash % 256
		hash = hash - low + xorByte(low, value:byte(index))
		hash = (hash * 403 + (hash % 256) * 16777216) % 4294967296
	end
	return string.format("%08x", hash)
end

local function hexEncode(value)
	local output = {}
	for index = 1, #value do output[#output + 1] = string.format("%02x", value:byte(index)) end
	return table.concat(output)
end

local function hiddenSnippet(compositor, snippet)
	local comments = { Hyprland = "--", Niri = "//", MangoWC = "#" }
	local indent = snippet:match("^([\t ]*)") or ""
	local marker = indent .. comments[compositor] .. " Keymap hidden v1"
	local blockId = fingerprint(compositor .. "\0" .. snippet)
	local output = { marker .. " begin " .. blockId .. " " .. fingerprint(snippet) }
	for offset = 1, #snippet, 48 do
		output[#output + 1] = marker .. " data " .. hexEncode(snippet:sub(offset, offset + 47))
	end
	output[#output + 1] = marker .. " end " .. blockId
	return table.concat(output, "\n")
end

local function lineCount(value)
	local count = 1
	for _ in value:gmatch("\n") do count = count + 1 end
	return count
end

local function target(id, source, snippet, capabilities, startLine, endLine)
	return {
		id = id, source = source, start_line = startLine or 2, end_line = endLine or 2,
		raw_snippet = snippet, fingerprint = fingerprint(snippet),
		capabilities = capabilities,
	}
end

local function runCase(case)
	files = {}
	stateValues = {}
	local root = "/tmp/keybind-test/" .. case.rootName
	local source = case.separate and "/tmp/keybind-test/entries-" .. case.rootName or root
	files[root] = case.root
	files[source] = case.content
	local bind = target(
		case.id, source, case.snippet, case.capabilities,
		case.startLine, case.endLine
	)
	stateValues["keymap.snapshot"] = {
		status = "ready", compositor = case.compositor, source = root,
		categories = { { name = case.category, binds = { bind } } },
	}
	stateValues["keymap.update_request"] = nil
	failVerify = case.failVerify == true
	failReload = false
	reloadAttempts = 0
	noctalia.state.set("keymap.update_request", {
		request_id = case.id .. "-request", target_id = case.id,
		compositor = case.compositor, source = root,
		modifiers = case.modifiers, keys = case.keys,
		activation = case.activation, command = case.command,
		command_kind = case.commandKind, library_entry_id = case.libraryEntryId,
		description = case.description, category = case.newCategory or case.category,
	})
	local result = stateValues["keymap.update_result"]
	assert(type(result) == "table", case.id .. ": missing update result")
	if case.error ~= nil then
		assert(result.ok == false and result.error == case.error,
			case.id .. ": expected " .. case.error .. ", got " .. tostring(result.error))
		assert(files[source] == case.content, case.id .. ": rejected update changed source")
	elseif case.failVerify then
		assert(result.ok == false and result.error == "verify_failed", case.id .. ": expected verify rollback")
		assert(files[source] == case.content, case.id .. ": rollback did not restore source")
	else
		assert(result.ok == true, case.id .. ": " .. tostring(result.error))
		assert(files[source] == case.expected, case.id .. ": unexpected updated content\n" .. tostring(files[source]))
	end
end

local function runMutationCase(case)
	files = {}
	stateValues = {}
	local root = "/tmp/keybind-test/" .. case.rootName
	local source = case.separate and "/tmp/keybind-test/entries-" .. case.rootName or root
	files[root] = case.root
	files[source] = case.content
	local bind = target(case.id, source, case.targetSnippet or case.snippet, case.capabilities or {
		combo = true, description = true, command = true, activation = true,
	}, case.startLine, case.endLine)
	bind.hidden = case.hidden == true
	bind.original_fingerprint = case.originalFingerprint
	if case.badFingerprint then bind.fingerprint = "00000000" end
	local categories = case.hidden and {} or { { name = case.category or "Windows", binds = { bind } } }
	stateValues["keymap.snapshot"] = {
		status = "ready", compositor = case.compositor, source = root,
		categories = categories, hidden = case.hidden and { bind } or {},
	}
	stateValues["keymap.update_request"] = nil
	failVerify = case.failVerify == true
	failReload = case.failReload == true
	reloadAttempts = 0
	writeCount = 0
	failRenameAt = case.failRenameAt
	renameAttempts = 0
	noctalia.state.set("keymap.update_request", {
		request_id = case.id .. "-request", target_id = case.id,
		operation = case.operation, compositor = case.compositor, source = root, hidden = case.hidden == true,
	})
	local result = stateValues["keymap.update_result"]
	assert(type(result) == "table", case.id .. ": missing mutation result")
	if case.error ~= nil then
		assert(result.ok == false and result.error == case.error,
			case.id .. ": expected " .. case.error .. ", got " .. tostring(result.error))
		assert(files[source] == case.content, case.id .. ": rejected mutation changed source")
	elseif case.failVerify or case.failReload then
		local expectedError = case.failReload and "reload_failed" or "verify_failed"
		assert(result.ok == false and result.error == expectedError,
			case.id .. ": expected " .. expectedError .. ", got " .. tostring(result.error))
		assert(files[source] == case.content, case.id .. ": mutation rollback did not restore source")
		if case.failReload then
			assert(reloadAttempts == 2, case.id .. ": restored config was not reloaded after rollback")
		end
	else
		assert(result.ok == true, case.id .. ": " .. tostring(result.error))
		assert(files[source] == case.expected, case.id .. ": unexpected mutated content\n" .. tostring(files[source]))
	end
end

local function runMoveCase(case)
	files = {}
	stateValues = {}
	local root = "/tmp/keybind-test/" .. case.rootName
	local source = case.separate and "/tmp/keybind-test/entries-" .. case.rootName or root
	files[root] = case.root
	files[source] = case.content
	local bind = target(
		case.id, source, case.snippet, case.capabilities or { category = true },
		case.startLine, case.endLine
	)
	if case.badFingerprint then bind.fingerprint = "00000000" end
	local categories = { { name = case.category, binds = { bind } } }
	if case.newCategory ~= case.category then
		categories[#categories + 1] = { name = case.newCategory, binds = {} }
	end
	stateValues["keymap.snapshot"] = {
		status = "ready", compositor = case.compositor, source = case.contextSource or root, categories = categories,
	}
	stateValues["keymap.update_request"] = nil
	failVerify = case.failVerify == true
	failReload = false
	reloadAttempts = 0
	writeCount = 0
	noctalia.state.set("keymap.update_request", {
		request_id = case.id .. "-request", target_id = case.id,
		operation = "move", compositor = case.compositor, source = root,
		category = case.newCategory,
	})
	local result = stateValues["keymap.update_result"]
	assert(type(result) == "table", case.id .. ": missing move result")
	if case.error ~= nil then
		assert(result.ok == false and result.error == case.error,
			case.id .. ": expected " .. case.error .. ", got " .. tostring(result.error))
		assert(files[source] == case.content, case.id .. ": rejected move changed source")
	elseif case.failVerify then
		assert(result.ok == false and result.error == "verify_failed", case.id .. ": expected verify rollback")
		assert(files[source] == case.content, case.id .. ": move rollback did not restore source")
	else
		assert(result.ok == true, case.id .. ": " .. tostring(result.error))
		assert(files[source] == case.expected, case.id .. ": unexpected moved content\n" .. tostring(files[source]))
		if case.expectedWrites ~= nil then
			assert(writeCount == case.expectedWrites,
				case.id .. ": expected " .. case.expectedWrites .. " writes, got " .. writeCount)
		end
	end
end

local function runReorderCase(case)
	files = {}
	stateValues = {}
	local root = "/tmp/keybind-test/" .. case.rootName
	local targetSource = case.targetSource or root
	local anchorSource = case.anchorSource or targetSource
	files[root] = case.root or case.content
	files[targetSource] = case.content
	if anchorSource ~= targetSource then files[anchorSource] = case.anchorContent end
	local targetBind = target(
		case.targetId or "reorder-target", targetSource, case.targetSnippet,
		case.targetCapabilities or {}, case.targetStart, case.targetEnd
	)
	local anchorBind = target(
		case.anchorId or "reorder-anchor", anchorSource, case.anchorSnippet,
		case.anchorCapabilities or {}, case.anchorStart, case.anchorEnd
	)
	if case.badTargetFingerprint then targetBind.fingerprint = "00000000" end
	if case.badAnchorFingerprint then anchorBind.fingerprint = "00000000" end
	if case.hiddenTarget then targetBind.hidden = true end
	local targetCategory = case.targetCategory or "Test"
	local anchorCategory = case.anchorCategory or targetCategory
	local categories
	if targetCategory == anchorCategory then
		categories = { { name = targetCategory, binds = { targetBind, anchorBind } } }
	else
		categories = {
			{ name = targetCategory, binds = { targetBind } },
			{ name = anchorCategory, binds = { anchorBind } },
		}
	end
	stateValues["keymap.snapshot"] = {
		status = "ready", compositor = case.compositor or "Hyprland", source = root,
		categories = categories, hidden = {},
	}
	stateValues["keymap.update_request"] = nil
	failVerify = case.failVerify == true
	failReload = case.failReload == true
	reloadAttempts = 0
	writeCount = 0
	noctalia.state.set("keymap.update_request", {
		request_id = (case.targetId or "reorder-target") .. "-request-" .. case.rootName,
		target_id = case.targetId or "reorder-target",
		anchor_id = case.anchorId or "reorder-anchor",
		operation = "reorder", placement = case.placement,
		compositor = case.compositor or "Hyprland", source = root,
	})
	local result = stateValues["keymap.update_result"]
	assert(type(result) == "table", case.rootName .. ": missing reorder result")
	if case.error ~= nil then
		assert(result.ok == false and result.error == case.error,
			case.rootName .. ": expected " .. case.error .. ", got " .. tostring(result.error))
		assert(files[targetSource] == case.content, case.rootName .. ": rejected reorder changed source")
	elseif case.failVerify or case.failReload then
		local expectedError = case.failReload and "reload_failed" or "verify_failed"
		assert(result.ok == false and result.error == expectedError,
			case.rootName .. ": expected " .. expectedError .. ", got " .. tostring(result.error))
		assert(files[targetSource] == case.content, case.rootName .. ": reorder rollback did not restore source")
		if case.failReload then
			assert(reloadAttempts == 2, case.rootName .. ": restored config was not reloaded after rollback")
		end
	else
		assert(result.ok == true, case.rootName .. ": " .. tostring(result.error))
		assert(files[targetSource] == case.expected,
			case.rootName .. ": unexpected reordered content\n" .. tostring(files[targetSource]))
		if case.expectedWrites ~= nil then
			assert(writeCount == case.expectedWrites,
				case.rootName .. ": expected " .. case.expectedWrites .. " writes, got " .. writeCount)
		end
	end
	failReload = false
end

local function runRenameCategoryCase(case)
	files = {}
	stateValues = {}
	failRenameAt = case.failRenameAt
	renameAttempts = 0
	local root = "/tmp/keybind-test/" .. case.rootName
	for path, content in pairs(case.files or {}) do files[path] = content end
	files[root] = case.root or files[root] or "-- root\n"
	local binds = {}
	for index, spec in ipairs(case.binds) do
		local bind = target(
			spec.id or ("rename-bind-" .. tostring(index)), spec.source or root, spec.snippet,
			spec.capabilities or { category = true }, spec.startLine, spec.endLine
		)
		if spec.badFingerprint then bind.fingerprint = "00000000" end
		if spec.hidden then bind.hidden = true end
		binds[#binds + 1] = bind
	end
	local categoryId = case.categoryId or "windows"
	local oldCategory = case.oldCategory or "Windows"
	local categories = { { id = categoryId, name = oldCategory, binds = binds } }
	if case.existingCategory ~= nil then
		categories[#categories + 1] = { id = "existing", name = case.existingCategory, binds = {} }
	end
	stateValues["keymap.snapshot"] = {
		status = "ready", compositor = case.compositor or "Hyprland",
		source = case.contextSource or root, categories = categories, hidden = {},
	}
	stateValues["keymap.update_request"] = nil
	failVerify = case.failVerify == true
	failReload = case.failReload == true
	reloadAttempts = 0
	writeCount = 0
	local originals = {}
	for path, content in pairs(files) do originals[path] = content end
	noctalia.state.set("keymap.update_request", {
		request_id = "rename-request-" .. case.rootName,
		operation = "rename_category", compositor = case.compositor or "Hyprland", source = root,
		category_id = case.requestCategoryId or categoryId,
		old_category = case.requestOldCategory or oldCategory,
		new_category = case.newCategory,
	})
	local result = stateValues["keymap.update_result"]
	assert(type(result) == "table", case.rootName .. ": missing category rename result")
	if case.error ~= nil then
		assert(result.ok == false and result.error == case.error,
			case.rootName .. ": expected " .. case.error .. ", got " .. tostring(result.error))
		for path, content in pairs(originals) do
			assert(files[path] == content, case.rootName .. ": rejected rename changed " .. path)
		end
	elseif case.failVerify or case.failReload then
		local expectedError = case.failReload and "reload_failed" or "verify_failed"
		assert(result.ok == false and result.error == expectedError,
			case.rootName .. ": expected " .. expectedError .. ", got " .. tostring(result.error))
		for path, content in pairs(originals) do
			assert(files[path] == content, case.rootName .. ": rollback did not restore " .. path)
		end
		if case.failReload then
			assert(reloadAttempts == 2, case.rootName .. ": restored config was not reloaded")
		end
	else
		assert(result.ok == true, case.rootName .. ": " .. tostring(result.error))
		assert(result.target_path == root, case.rootName .. ": result did not identify root source")
		for path, expected in pairs(case.expectedFiles or {}) do
			assert(files[path] == expected,
				case.rootName .. ": unexpected renamed content in " .. path .. "\n" .. tostring(files[path]))
		end
		if case.expectedWrites ~= nil then
			assert(writeCount == case.expectedWrites,
				case.rootName .. ": expected " .. case.expectedWrites .. " writes, got " .. writeCount)
		end
	end
	failVerify = false
	failReload = false
	failRenameAt = nil
end

assert(loadfile("writer_service.luau"))()

local hyprSnippet = 'hl.bind("SUPER + G", hl.dsp.exec_cmd([[old-command]]), { description = "Old title" })'
local niriSnippet = '    Mod+G repeat=false hotkey-overlay-title="Old title" { spawn-sh "old-command"; }'
runCase({
	id = "hypr", compositor = "Hyprland", rootName = "hyprland.lua", separate = true,
	root = 'require("entries-hyprland")\n', content = "-- binds\n" .. hyprSnippet .. "\n",
	snippet = hyprSnippet, category = "Windows",
	capabilities = { combo = true, description = true, command = true, activation = true },
	modifiers = { "SUPER", "SHIFT" }, keys = { "G" }, activation = "release",
	command = "noctalia msg bar-toggle", description = "New title",
	expected = '-- binds\nhl.bind("SUPER + SHIFT + G", hl.dsp.exec_cmd([[noctalia msg bar-toggle]]), { release = true, description = "New title" })\n',
})

runCase({
	id = "hypr-native-conversion", compositor = "Hyprland", rootName = "hypr-native-conversion.lua", separate = true,
	root = 'require("entries-hypr-native-conversion")\n', content = "-- binds\n" .. hyprSnippet .. "\n",
	snippet = hyprSnippet, category = "Windows",
	capabilities = { combo = true, description = true, command = true, activation = true },
	modifiers = { "SUPER" }, keys = { "G" }, activation = "press",
	command = "hl.dsp.window.close()", commandKind = "native",
	libraryEntryId = "hyprland/window.close", description = "Close window",
	error = "native_update_unsupported",
})

runCase({
	id = "hypr-category", compositor = "Hyprland", rootName = "hypr-category.lua", separate = true,
	root = 'require("entries-hypr-category")\n', content = "-- binds\n" .. hyprSnippet .. "\n",
	snippet = hyprSnippet, category = "Windows", newCategory = "Media",
	capabilities = { combo = true, category = true, description = true, command = true, activation = true },
	modifiers = { "SUPER" }, keys = { "G" }, activation = "press",
	command = "old-command", description = "Old title",
	expected = '-- binds\n-- Keymap bind-category: Media\n'
		.. hyprSnippet .. '\n',
})

local markedHyprSnippet = "-- Keymap bind-category: Media\n" .. hyprSnippet
runCase({
	id = "hypr-category-again", compositor = "Hyprland", rootName = "hypr-category-again.lua", separate = true,
	root = 'require("entries-hypr-category-again")\n', content = "-- binds\n" .. markedHyprSnippet .. "\n",
	snippet = markedHyprSnippet, startLine = 2, endLine = 3,
	category = "Media", newCategory = "System",
	capabilities = { combo = true, category = true, description = true, command = true, activation = true },
	modifiers = { "SUPER" }, keys = { "G" }, activation = "press",
	command = "old-command", description = "Old title",
	expected = '-- binds\n-- Keymap bind-category: System\n'
		.. hyprSnippet .. '\n',
})

local hyprNativeSnippet = 'hl.bind("SUPER + G", hl.dsp.group.toggle(), { description = "Group Windows" })'
runCase({
	id = "hypr-native", compositor = "Hyprland", rootName = "native.lua", separate = true,
	root = 'require("entries-native")\n', content = "-- binds\n" .. hyprNativeSnippet .. "\n",
	snippet = hyprNativeSnippet, category = "Windows",
	capabilities = { combo = true, description = true, command = false, activation = true },
	modifiers = { "SUPER", "SHIFT" }, keys = { "G" }, activation = "press",
	command = "", description = "Toggle window group",
	expected = '-- binds\nhl.bind("SUPER + SHIFT + G", hl.dsp.group.toggle(), { description = "Toggle window group" })\n',
})

runCase({
	id = "niri-category", compositor = "Niri", rootName = "niri-category.kdl",
	root = "binds {\n" .. niriSnippet .. "\n}\n",
	content = "binds {\n" .. niriSnippet .. "\n}\n",
	snippet = niriSnippet, category = "Windows", newCategory = "Media",
	capabilities = { combo = true, category = true, description = true, command = true, activation = false },
	modifiers = { "SUPER" }, keys = { "G" }, activation = "press",
	command = "old-command", description = "Old title",
	expected = 'binds {\n    // Keymap bind-category: Media\n'
		.. niriSnippet .. '\n}\n',
})

runCase({
	id = "niri", compositor = "Niri", rootName = "config.kdl",
	root = "binds {\n" .. niriSnippet .. "\n}\n", content = "binds {\n" .. niriSnippet .. "\n}\n",
	snippet = niriSnippet, category = "Windows",
	capabilities = { combo = true, description = true, command = true, activation = false },
	modifiers = { "SUPER", "SHIFT" }, keys = { "G" }, activation = "press",
	command = "new-command --flag", description = "New title",
	expected = 'binds {\n    Mod+Shift+G repeat=false hotkey-overlay-title="New title" { spawn-sh "new-command --flag"; }\n}\n',
})

local mangoSnippet = 'bind=SUPER,G,spawn_shell,old-command #"Old title"'
runCase({
	id = "mango-category", compositor = "MangoWC", rootName = "mango-category.conf",
	root = "# binds\n" .. mangoSnippet .. "\n", content = "# binds\n" .. mangoSnippet .. "\n",
	snippet = mangoSnippet, category = "Windows", newCategory = "Media",
	capabilities = { combo = true, category = true, description = true, command = true, activation = true },
	modifiers = { "SUPER" }, keys = { "G" }, activation = "press",
	command = "old-command", description = "Old title",
	expected = '# binds\n# Keymap bind-category: Media\n' .. mangoSnippet .. '\n',
})

runCase({
	id = "mango", compositor = "MangoWC", rootName = "config.conf",
	root = "# binds\n" .. mangoSnippet .. "\n", content = "# binds\n" .. mangoSnippet .. "\n",
	snippet = mangoSnippet, category = "Windows",
	capabilities = { combo = true, description = true, command = true, activation = true },
	modifiers = { "SUPER", "SHIFT" }, keys = { "G" }, activation = "release",
	command = "new-command --flag", description = "New title",
	expected = '# binds\nbindr=SUPER+SHIFT,G,spawn_shell,new-command --flag #"New title"\n',
})

local hyprMoveSnippet = "  hl.bind( 'SUPER + G' , hl.dsp.group.toggle(), {description='Keep  spacing'} ) -- trailing"
runMoveCase({
	id = "hypr-move", compositor = "Hyprland", rootName = "hypr-move.lua", separate = true,
	root = 'require("entries-hypr-move")\n', content = "-- binds\n" .. hyprMoveSnippet .. "\n",
	snippet = hyprMoveSnippet, category = "Windows", newCategory = "Media",
	expected = "-- binds\n  -- Keymap bind-category: Media\n" .. hyprMoveSnippet .. "\n",
})

local niriMoveBind = '    Mod+G repeat=false { spawn-sh "keep   exact --flag"; }'
local niriMoveSnippet = "    // Keymap bind-category: Windows\n" .. niriMoveBind
runMoveCase({
	id = "niri-move", compositor = "Niri", rootName = "niri-move.kdl",
	root = "binds {\n" .. niriMoveSnippet .. "\n}\n",
	content = "binds {\n" .. niriMoveSnippet .. "\n}\n",
	snippet = niriMoveSnippet, startLine = 2, endLine = 3,
	category = "Windows", newCategory = "Media",
	expected = "binds {\n    // Keymap bind-category: Media\n" .. niriMoveBind .. "\n}\n",
})

local mangoMoveSnippet = ' bind=SUPER,G,spawn_shell,printf "keep,  exact" #"Title"'
runMoveCase({
	id = "mango-move", compositor = "MangoWC", rootName = "mango-move.conf",
	root = "# binds\n" .. mangoMoveSnippet .. "\n",
	content = "# binds\n" .. mangoMoveSnippet .. "\n",
	snippet = mangoMoveSnippet, category = "Windows", newCategory = "Media",
	expected = "# binds\n # Keymap bind-category: Media\n" .. mangoMoveSnippet .. "\n",
})

runMoveCase({
	id = "move-same-category", compositor = "Hyprland", rootName = "move-same.lua", separate = true,
	root = 'require("entries-move-same")\n', content = "-- binds\n" .. hyprMoveSnippet .. "\n",
	snippet = hyprMoveSnippet, category = "Windows", newCategory = "Windows",
	expected = "-- binds\n" .. hyprMoveSnippet .. "\n",
	expectedWrites = 0,
})

runMoveCase({
	id = "move-from-legacy-category", compositor = "Hyprland", rootName = "move-legacy.lua", separate = true,
	root = 'require("entries-move-legacy")\n', content = "-- binds\n" .. hyprMoveSnippet .. "\n",
	snippet = hyprMoveSnippet, category = 'Legacy "quoted" category', newCategory = "Media",
	expected = "-- binds\n  -- Keymap bind-category: Media\n" .. hyprMoveSnippet .. "\n",
})

runMoveCase({
	id = "move-no-capability", compositor = "Niri", rootName = "move-no-capability.kdl",
	root = "binds {\n" .. niriMoveBind .. "\n}\n",
	content = "binds {\n" .. niriMoveBind .. "\n}\n",
	snippet = niriMoveBind, category = "Windows", newCategory = "Media",
	capabilities = { category = false }, error = "target_not_editable",
})

runMoveCase({
	id = "move-invalid-category", compositor = "MangoWC", rootName = "move-invalid-category.conf",
	root = "# binds\n" .. mangoSnippet .. "\n", content = "# binds\n" .. mangoSnippet .. "\n",
	snippet = mangoSnippet, category = "Windows", newCategory = "bad\ncategory",
	error = "invalid_category",
})

runMoveCase({
	id = "move-stale-context", compositor = "Hyprland", rootName = "move-stale-context.lua", separate = true,
	root = 'require("entries-move-stale-context")\n', content = "-- binds\n" .. hyprSnippet .. "\n",
	snippet = hyprSnippet, category = "Windows", newCategory = "Media",
	contextSource = "/tmp/keybind-test/other.lua", error = "stale_context",
})

runMoveCase({
	id = "move-stale-provenance", compositor = "Niri", rootName = "move-stale-provenance.kdl",
	root = "binds {\n" .. niriMoveBind .. "\n}\n",
	content = "binds {\n" .. niriMoveBind .. "\n}\n",
	snippet = niriMoveBind, category = "Windows", newCategory = "Media",
	badFingerprint = true, error = "target_changed",
})

runMoveCase({
	id = "move-rollback", compositor = "Hyprland", rootName = "move-rollback.lua", separate = true,
	root = 'require("entries-move-rollback")\n', content = "-- binds\n" .. hyprSnippet .. "\n",
	snippet = hyprSnippet, category = "Windows", newCategory = "Media", failVerify = true,
})

local renameHyprA = 'hl.bind("SUPER + A", action_a, { description = "A" })'
local renameHyprB = 'hl.bind("SUPER + B", action_b, { description = "B" })'
local renameHyprPath = "/tmp/keybind-test/rename-hypr.lua"
local renameHyprContent = "-- 1. Windows\n" .. renameHyprA .. "\n" .. renameHyprB .. "\n"
runRenameCategoryCase({
	rootName = "rename-hypr.lua", root = renameHyprContent, newCategory = "Applications",
	binds = {
		{ id = "rename-hypr-a", snippet = renameHyprA, startLine = 2, endLine = 2 },
		{ id = "rename-hypr-b", snippet = renameHyprB, startLine = 3, endLine = 3 },
	},
	expectedFiles = { [renameHyprPath] = "-- 1. Windows\n"
		.. "-- Keymap bind-category: Applications\n" .. renameHyprA .. "\n"
		.. "-- Keymap bind-category: Applications\n" .. renameHyprB .. "\n" },
})

local renameNiriA = table.concat({
	"    Mod+A {", '        spawn "a";', "    }",
}, "\n")
local renameNiriB = '    Mod+B { spawn "b"; }'
local renameNiriPath = "/tmp/keybind-test/rename-niri.kdl"
local renameNiriContent = "binds {\n    // \"Windows\"\n" .. renameNiriA .. "\n" .. renameNiriB .. "\n}\n"
runRenameCategoryCase({
	rootName = "rename-niri.kdl", compositor = "Niri", root = renameNiriContent,
	newCategory = "Applications",
	binds = {
		{ id = "rename-niri-a", snippet = renameNiriA, startLine = 3, endLine = 5 },
		{ id = "rename-niri-b", snippet = renameNiriB, startLine = 6, endLine = 6 },
	},
	expectedFiles = { [renameNiriPath] = "binds {\n    // \"Windows\"\n"
		.. "    // Keymap bind-category: Applications\n" .. renameNiriA .. "\n"
		.. "    // Keymap bind-category: Applications\n" .. renameNiriB .. "\n}\n" },
})

local renameMangoA = 'bind=SUPER,A,spawn_shell,a #"A"'
local renameMangoB = 'bind=SUPER,B,spawn_shell,b #"B"'
local renameMangoPath = "/tmp/keybind-test/rename-mango.conf"
local renameMangoContent = "# Keymap category: Windows\n"
	.. renameMangoA .. "\n" .. renameMangoB .. "\n"
runRenameCategoryCase({
	rootName = "rename-mango.conf", compositor = "MangoWC", root = renameMangoContent,
	newCategory = "Applications",
	binds = {
		{ id = "rename-mango-a", snippet = renameMangoA, startLine = 2, endLine = 2 },
		{ id = "rename-mango-b", snippet = renameMangoB, startLine = 3, endLine = 3 },
	},
	expectedFiles = { [renameMangoPath] = "# Keymap category: Windows\n"
		.. "# Keymap bind-category: Applications\n" .. renameMangoA .. "\n"
		.. "# Keymap bind-category: Applications\n" .. renameMangoB .. "\n" },
})

local renameMultiRoot = "/tmp/keybind-test/rename-multi.lua"
local renameMultiOne = "/tmp/keybind-test/rename-multi-one.lua"
local renameMultiTwo = "/tmp/keybind-test/rename-multi-two.lua"
local renameMultiRootContent = 'require("rename-multi-one")\nrequire("rename-multi-two")\n'
local renameMultiOneContent = "-- 1. Windows\n" .. renameHyprA .. "\n"
local renameMultiTwoContent = "-- 1. Windows\n" .. renameHyprB .. "\n"
local renameMultiFiles = {
	[renameMultiOne] = renameMultiOneContent,
	[renameMultiTwo] = renameMultiTwoContent,
}
local renameMultiBinds = {
	{ id = "rename-multi-a", source = renameMultiOne, snippet = renameHyprA, startLine = 2, endLine = 2 },
	{ id = "rename-multi-b", source = renameMultiTwo, snippet = renameHyprB, startLine = 2, endLine = 2 },
}
local renameMultiExpected = {
	[renameMultiRoot] = renameMultiRootContent,
	[renameMultiOne] = "-- 1. Windows\n-- Keymap bind-category: Media\n" .. renameHyprA .. "\n",
	[renameMultiTwo] = "-- 1. Windows\n-- Keymap bind-category: Media\n" .. renameHyprB .. "\n",
}
runRenameCategoryCase({
	rootName = "rename-multi.lua", root = renameMultiRootContent, files = renameMultiFiles,
	newCategory = "Media", binds = renameMultiBinds,
	expectedFiles = renameMultiExpected, expectedWrites = 2,
})

runRenameCategoryCase({
	rootName = "rename-write-rollback.lua", root = renameMultiRootContent, files = renameMultiFiles,
	newCategory = "Media", binds = renameMultiBinds, failRenameAt = 2,
	error = "source_write_failed",
})

runRenameCategoryCase({
	rootName = "rename-no-op.lua", root = renameHyprContent,
	newCategory = "Windows",
	binds = {
		{ id = "rename-no-op-a", snippet = renameHyprA, startLine = 2, endLine = 2 },
		{ id = "rename-no-op-b", snippet = renameHyprB, startLine = 3, endLine = 3 },
	},
	expectedFiles = { ["/tmp/keybind-test/rename-no-op.lua"] = renameHyprContent }, expectedWrites = 0,
})

runRenameCategoryCase({
	rootName = "rename-stale-fingerprint.lua", root = renameHyprContent, newCategory = "Media",
	binds = {
		{ id = "rename-stale-a", snippet = renameHyprA, startLine = 2, endLine = 2 },
		{ id = "rename-stale-b", snippet = renameHyprB, startLine = 3, endLine = 3, badFingerprint = true },
	},
	error = "target_changed",
})

runRenameCategoryCase({
	rootName = "rename-stale-context.lua", root = renameHyprContent, newCategory = "Media",
	contextSource = "/tmp/keybind-test/different-root.lua",
	binds = {
		{ id = "rename-context-a", snippet = renameHyprA, startLine = 2, endLine = 2 },
	},
	error = "stale_context",
})

runRenameCategoryCase({
	rootName = "rename-stale-category.lua", root = renameHyprContent, newCategory = "Media",
	requestOldCategory = "Old Windows",
	binds = {
		{ id = "rename-category-a", snippet = renameHyprA, startLine = 2, endLine = 2 },
	},
	error = "stale_category",
})

runRenameCategoryCase({
	rootName = "rename-existing-category.lua", root = renameHyprContent,
	newCategory = "Media", existingCategory = "Media",
	binds = {
		{ id = "rename-existing-a", snippet = renameHyprA, startLine = 2, endLine = 2 },
	},
	error = "category_exists",
})

runRenameCategoryCase({
	rootName = "rename-range.lua", root = renameHyprContent, newCategory = "Media",
	binds = {
		{ id = "range:a:b", snippet = renameHyprA, startLine = 2, endLine = 2 },
	},
	error = "category_not_editable",
})

runRenameCategoryCase({
	rootName = "rename-dynamic.lua", root = renameHyprContent, newCategory = "Media",
	binds = {
		{ id = "rename-dynamic-a", snippet = renameHyprA, startLine = 2, endLine = 2,
			capabilities = { category = false } },
	},
	error = "category_not_editable",
})

runRenameCategoryCase({
	rootName = "rename-overlap.lua", root = renameHyprContent, newCategory = "Media",
	binds = {
		{ id = "rename-overlap-a", snippet = renameHyprA, startLine = 2, endLine = 2 },
		{ id = "rename-overlap-b", snippet = renameHyprA, startLine = 2, endLine = 2 },
	},
	error = "category_ranges_overlap",
})

runRenameCategoryCase({
	rootName = "rename-invalid-name.lua", root = renameHyprContent, newCategory = "bad\nname",
	binds = {
		{ id = "rename-invalid-a", snippet = renameHyprA, startLine = 2, endLine = 2 },
	},
	error = "invalid_category",
})

runRenameCategoryCase({
	rootName = "rename-validator-rollback.lua", root = renameMultiRootContent, files = renameMultiFiles,
	newCategory = "Media", binds = renameMultiBinds, failVerify = true,
})

runRenameCategoryCase({
	rootName = "rename-reload-rollback.lua", root = renameMultiRootContent, files = renameMultiFiles,
	newCategory = "Media", binds = renameMultiBinds, failReload = true,
})

local reorderA = 'hl.bind("SUPER + A", action_a, { description = "A" })'
local reorderB = 'hl.bind("SUPER + B", action_b, { description = "B" })'
local reorderC = 'hl.bind("SUPER + C", action_c, { description = "C" })'
local reorderContent = "-- header\n" .. reorderA .. "\n" .. reorderB .. "\n" .. reorderC .. "\n-- footer\n"

runReorderCase({
	rootName = "reorder-before-up.lua", content = reorderContent,
	targetSnippet = reorderC, targetStart = 4, targetEnd = 4,
	anchorSnippet = reorderA, anchorStart = 2, anchorEnd = 2, placement = "before",
	expected = "-- header\n" .. reorderC .. "\n" .. reorderA .. "\n" .. reorderB .. "\n-- footer\n",
})

runReorderCase({
	rootName = "reorder-cross-category.lua", content = reorderContent,
	targetSnippet = reorderA, targetStart = 2, targetEnd = 2,
	anchorSnippet = reorderB, anchorStart = 3, anchorEnd = 3, placement = "after",
	targetCategory = "Applications", anchorCategory = "Media",
	targetCapabilities = { category = true },
	expected = "-- header\n" .. reorderB
		.. "\n-- Keymap bind-category: Media\n" .. reorderA
		.. "\n" .. reorderC .. "\n-- footer\n",
})

runReorderCase({
	rootName = "reorder-cross-category-no-capability.lua", content = reorderContent,
	targetSnippet = reorderA, targetStart = 2, targetEnd = 2,
	anchorSnippet = reorderB, anchorStart = 3, anchorEnd = 3, placement = "after",
	targetCategory = "Applications", anchorCategory = "Media",
	error = "target_not_editable",
})

runReorderCase({
	rootName = "reorder-after-down.lua", content = reorderContent,
	targetSnippet = reorderA, targetStart = 2, targetEnd = 2,
	anchorSnippet = reorderC, anchorStart = 4, anchorEnd = 4, placement = "after",
	expected = "-- header\n" .. reorderB .. "\n" .. reorderC .. "\n" .. reorderA .. "\n-- footer\n",
})

runReorderCase({
	rootName = "reorder-after-adjacent.lua", content = reorderContent,
	targetSnippet = reorderA, targetStart = 2, targetEnd = 2,
	anchorSnippet = reorderB, anchorStart = 3, anchorEnd = 3, placement = "after",
	expected = "-- header\n" .. reorderB .. "\n" .. reorderA .. "\n" .. reorderC .. "\n-- footer\n",
})

runReorderCase({
	rootName = "reorder-before-adjacent.lua", content = reorderContent,
	targetSnippet = reorderC, targetStart = 4, targetEnd = 4,
	anchorSnippet = reorderB, anchorStart = 3, anchorEnd = 3, placement = "before",
	expected = "-- header\n" .. reorderA .. "\n" .. reorderC .. "\n" .. reorderB .. "\n-- footer\n",
})

runReorderCase({
	rootName = "reorder-no-op.lua", content = reorderContent,
	targetSnippet = reorderA, targetStart = 2, targetEnd = 2,
	anchorSnippet = reorderB, anchorStart = 3, anchorEnd = 3, placement = "before",
	expected = reorderContent, expectedWrites = 0,
})

local reorderNiriA = '    Mod+A { spawn "a"; }\r'
local reorderNiriB = '    Mod+B { spawn "b"; }\r'
runReorderCase({
	rootName = "reorder-crlf.kdl", compositor = "Niri",
	content = "binds {\r\n" .. reorderNiriA .. "\n" .. reorderNiriB .. "\n}\r\n",
	targetSnippet = reorderNiriB, targetStart = 3, targetEnd = 3,
	anchorSnippet = reorderNiriA, anchorStart = 2, anchorEnd = 2, placement = "before",
	expected = "binds {\r\n" .. reorderNiriB .. "\n" .. reorderNiriA .. "\n}\r\n",
})

runReorderCase({
	rootName = "reorder-different-source.lua", content = "-- target\n" .. reorderA .. "\n",
	targetSource = "/tmp/keybind-test/reorder-target.lua",
	anchorSource = "/tmp/keybind-test/reorder-anchor.lua", anchorContent = "-- anchor\n" .. reorderB .. "\n",
	targetSnippet = reorderA, targetStart = 2, targetEnd = 2,
	anchorSnippet = reorderB, anchorStart = 2, anchorEnd = 2, placement = "before",
	error = "different_source",
})

runReorderCase({
	rootName = "reorder-stale-target.lua", content = reorderContent,
	targetSnippet = reorderC, targetStart = 4, targetEnd = 4, badTargetFingerprint = true,
	anchorSnippet = reorderA, anchorStart = 2, anchorEnd = 2, placement = "before",
	error = "target_changed",
})

runReorderCase({
	rootName = "reorder-stale-anchor.lua", content = reorderContent,
	targetSnippet = reorderC, targetStart = 4, targetEnd = 4,
	anchorSnippet = reorderA, anchorStart = 2, anchorEnd = 2, badAnchorFingerprint = true,
	placement = "before", error = "anchor_changed",
})

runReorderCase({
	rootName = "reorder-overlap.lua", content = reorderContent,
	targetSnippet = reorderA, targetStart = 2, targetEnd = 2,
	anchorSnippet = reorderA, anchorStart = 2, anchorEnd = 2, placement = "before",
	error = "target_anchor_overlap",
})

runReorderCase({
	rootName = "reorder-range-id.lua", content = reorderContent, targetId = "range:2-2",
	targetSnippet = reorderA, targetStart = 2, targetEnd = 2,
	anchorSnippet = reorderB, anchorStart = 3, anchorEnd = 3, placement = "before",
	error = "target_not_editable",
})

runReorderCase({
	rootName = "reorder-hidden.lua", content = reorderContent, hiddenTarget = true,
	targetSnippet = reorderA, targetStart = 2, targetEnd = 2,
	anchorSnippet = reorderB, anchorStart = 3, anchorEnd = 3, placement = "before",
	error = "target_not_editable",
})

runReorderCase({
	rootName = "reorder-validator-rollback.lua", content = reorderContent,
	targetSnippet = reorderC, targetStart = 4, targetEnd = 4,
	anchorSnippet = reorderA, anchorStart = 2, anchorEnd = 2, placement = "before",
	failVerify = true,
})

runReorderCase({
	rootName = "reorder-reload-rollback.lua", content = reorderContent,
	targetSnippet = reorderC, targetStart = 4, targetEnd = 4,
	anchorSnippet = reorderA, anchorStart = 2, anchorEnd = 2, placement = "before",
	failReload = true,
})

runMutationCase({
	id = "hypr-hide", operation = "hide", compositor = "Hyprland", rootName = "hide.lua", separate = true,
	root = 'require("entries-hide")\n', content = "-- binds\n" .. hyprSnippet .. "\n",
	snippet = hyprSnippet,
	expected = "-- binds\n" .. hiddenSnippet("Hyprland", hyprSnippet) .. "\n",
})

local niriMultilineSnippet = table.concat({
	'    Mod+G repeat=false hotkey-overlay-title="Old title" {',
	'        spawn-sh "old-command --with-flag";',
	'    }',
}, "\n")
runMutationCase({
	id = "niri-hide-multiline", operation = "hide", compositor = "Niri", rootName = "hide-multiline.kdl",
	root = "binds {\n" .. niriMultilineSnippet .. "\n}\n",
	content = "binds {\n" .. niriMultilineSnippet .. "\n}\n",
	snippet = niriMultilineSnippet, startLine = 2, endLine = 4,
	expected = "binds {\n" .. hiddenSnippet("Niri", niriMultilineSnippet) .. "\n}\n",
})

runMutationCase({
	id = "niri-delete", operation = "delete", compositor = "Niri", rootName = "delete.kdl",
	root = "binds {\n" .. niriSnippet .. "\n}\n", content = "binds {\n" .. niriSnippet .. "\n}\n",
	snippet = niriSnippet,
	expected = "binds {\n}\n",
})

runMutationCase({
	id = "mango-hide", operation = "hide", compositor = "MangoWC", rootName = "hide.conf",
	root = "# binds\n" .. mangoSnippet .. "\n", content = "# binds\n" .. mangoSnippet .. "\n",
	snippet = mangoSnippet,
	expected = "# binds\n" .. hiddenSnippet("MangoWC", mangoSnippet) .. "\n",
})

local hyprHidden = hiddenSnippet("Hyprland", hyprSnippet)
runMutationCase({
	id = "hypr-restore", operation = "restore", compositor = "Hyprland", rootName = "restore.lua", separate = true,
	root = 'require("entries-restore")\n', content = "-- binds\n" .. hyprHidden .. "\n",
	snippet = hyprHidden, startLine = 2, endLine = 1 + lineCount(hyprHidden), hidden = true,
	originalFingerprint = fingerprint(hyprSnippet),
	expected = "-- binds\n" .. hyprSnippet .. "\n",
})

local niriHidden = hiddenSnippet("Niri", niriMultilineSnippet)
runMutationCase({
	id = "niri-restore-multiline", operation = "restore", compositor = "Niri", rootName = "restore.kdl",
	root = "binds {\n" .. niriHidden .. "\n}\n", content = "binds {\n" .. niriHidden .. "\n}\n",
	snippet = niriHidden, startLine = 2, endLine = 1 + lineCount(niriHidden), hidden = true,
	originalFingerprint = fingerprint(niriMultilineSnippet),
	expected = "binds {\n" .. niriMultilineSnippet .. "\n}\n",
})

local niriCrlfSnippet = '    Mod+H repeat=false {\r\n        spawn-sh "keep-crlf";\r\n    }\r'
local niriCrlfHidden = hiddenSnippet("Niri", niriCrlfSnippet)
runMutationCase({
	id = "niri-restore-crlf", operation = "restore", compositor = "Niri", rootName = "restore-crlf.kdl",
	root = "binds {\r\n" .. niriCrlfHidden .. "\n}\r\n",
	content = "binds {\r\n" .. niriCrlfHidden .. "\n}\r\n",
	snippet = niriCrlfHidden, startLine = 2, endLine = 1 + lineCount(niriCrlfHidden), hidden = true,
	originalFingerprint = fingerprint(niriCrlfSnippet),
	expected = "binds {\r\n" .. niriCrlfSnippet .. "\n}\r\n",
})

local mangoHidden = hiddenSnippet("MangoWC", mangoSnippet)
runMutationCase({
	id = "mango-restore", operation = "restore", compositor = "MangoWC", rootName = "restore.conf",
	root = "# binds\n" .. mangoHidden .. "\n", content = "# binds\n" .. mangoHidden .. "\n",
	snippet = mangoHidden, startLine = 2, endLine = 1 + lineCount(mangoHidden), hidden = true,
	originalFingerprint = fingerprint(mangoSnippet),
	expected = "# binds\n" .. mangoSnippet .. "\n",
})

runMutationCase({
	id = "hidden-delete", operation = "delete", compositor = "MangoWC", rootName = "delete-hidden.conf",
	root = "# binds\n" .. mangoHidden .. "\n", content = "# binds\n" .. mangoHidden .. "\n",
	snippet = mangoHidden, startLine = 2, endLine = 1 + lineCount(mangoHidden), hidden = true,
	expected = "# binds\n",
})

local malformedHidden = hyprHidden:gsub(" end ([0-9a-f]+)$", " end deadbeef")
runMutationCase({
	id = "restore-malformed", operation = "restore", compositor = "Hyprland", rootName = "malformed.lua",
	root = "-- binds\n" .. malformedHidden .. "\n", content = "-- binds\n" .. malformedHidden .. "\n",
	snippet = malformedHidden, startLine = 2, endLine = 1 + lineCount(malformedHidden), hidden = true,
	error = "hidden_block_invalid",
})

runMutationCase({
	id = "delete-malformed", operation = "delete", compositor = "Hyprland", rootName = "delete-malformed.lua",
	root = "-- binds\n" .. malformedHidden .. "\n", content = "-- binds\n" .. malformedHidden .. "\n",
	snippet = malformedHidden, startLine = 2, endLine = 1 + lineCount(malformedHidden), hidden = true,
	error = "hidden_block_invalid",
})

runMutationCase({
	id = "restore-stale", operation = "restore", compositor = "Niri", rootName = "stale.kdl",
	root = "binds {\n" .. niriHidden .. "\n}\n", content = "binds {\n" .. niriHidden .. "\n}\n",
	snippet = niriHidden, startLine = 2, endLine = 1 + lineCount(niriHidden), hidden = true,
	badFingerprint = true, error = "target_changed",
})

local changedNiriHidden = niriHidden:gsub(" data ([0-9a-f])", function(first)
	return " data " .. (first == "0" and "1" or "0")
end, 1)
runMutationCase({
	id = "restore-disk-changed", operation = "restore", compositor = "Niri", rootName = "disk-changed.kdl",
	root = "binds {\n" .. changedNiriHidden .. "\n}\n",
	content = "binds {\n" .. changedNiriHidden .. "\n}\n",
	snippet = changedNiriHidden, targetSnippet = niriHidden,
	startLine = 2, endLine = 1 + lineCount(niriHidden), hidden = true,
	error = "target_changed",
})

runMutationCase({
	id = "restore-rollback", operation = "restore", compositor = "Hyprland", rootName = "restore-rollback.lua",
	root = "-- binds\n" .. hyprHidden .. "\n", content = "-- binds\n" .. hyprHidden .. "\n",
	snippet = hyprHidden, startLine = 2, endLine = 1 + lineCount(hyprHidden), hidden = true,
	failVerify = true,
})

runMutationCase({
	id = "restore-reload-rollback", operation = "restore", compositor = "Hyprland",
	rootName = "restore-reload-rollback.lua",
	root = "-- binds\n" .. hyprHidden .. "\n", content = "-- binds\n" .. hyprHidden .. "\n",
	snippet = hyprHidden, startLine = 2, endLine = 1 + lineCount(hyprHidden), hidden = true,
	failReload = true,
})

runCase({
	id = "rollback", compositor = "Hyprland", rootName = "rollback.lua", separate = true,
	root = 'require("entries-rollback")\n', content = "-- binds\n" .. hyprSnippet .. "\n",
	snippet = hyprSnippet, category = "Windows", failVerify = true,
	capabilities = { combo = true, description = true, command = true, activation = true },
	modifiers = { "SUPER" }, keys = { "H" }, activation = "press",
	command = "will-not-stick", description = "Rollback title",
})

print("writer update tests: ok")
