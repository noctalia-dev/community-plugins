local files = { ["command_library.json"] = "test-command-library" }
local stateValues = {}
local watchers = {}
local commands = {}
local failure = {
	preflight = false,
	validator = false,
	reloadOnce = false,
	remove = false,
}
local reloadAttempts = 0

local function commandResult(command)
	local result = { exitCode = 0, timedOut = false }
	if failure.preflight and command:find("[ ! -L ", 1, true) == 1 then
		result.exitCode = 1
	elseif failure.validator and command == failure.validatorCommand then
		result.exitCode = 1
	elseif failure.reloadOnce and command == failure.reloadCommand then
		reloadAttempts = reloadAttempts + 1
		if reloadAttempts == 1 then result.exitCode = 1 end
	end
	return result
end

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
		files[path] = content
		return true
	end,
	renameFile = function(source, target)
		if files[source] == nil then return false end
		files[target] = files[source]
		files[source] = nil
		return true
	end,
	removeFile = function(path)
		if failure.remove then return false end
		files[path] = nil
		return true
	end,
	runAsync = function(command, callback, timeout)
		commands[#commands + 1] = { command = command, timeout = timeout }
		callback(commandResult(command))
		return true
	end,
	json = { decode = function(encoded)
		if encoded == "test-command-library" then
			return {
				schema = 1,
				entries = {
					{ id = "hyprland/window.close", source = "hyprland", kind = "native", template = "hl.dsp.window.close()" },
					{ id = "hyprland/exec_cmd", source = "hyprland", kind = "native", template = "hl.dsp.exec_cmd({{command}})" },
					{ id = "niri/close-window", source = "niri", kind = "native", template = "close-window" },
					{ id = "mangowc/killclient", source = "mangowc", kind = "native", template = "killclient" },
				},
			}
		end
		return {}
	end },
}

local CASES = {
	{
		id = "hyprland",
		compositor = "Hyprland",
		rootName = "hyprland.lua",
		managedName = "keymap.lua",
		comment = "--",
		root = "-- user config\n",
		includeLine = 'require("keymap")',
		validatorPrefix = "Hyprland --verify-config -c ",
		reloadCommand = "hyprctl reload",
		first = {
			modifiers = { "SUPER", "SHIFT" }, keys = { "A" }, activation = "press",
			command = "noctalia msg panel-open launcher", description = "Open app", category = "Applications",
			entry = '-- 1. Applications\nhl.bind("SUPER + SHIFT + A", hl.dsp.exec_cmd([[noctalia msg panel-open launcher]]), { description = "Open app" })\n',
		},
		second = {
			modifiers = { "SUPER" }, keys = { "B" }, activation = "release",
			command = "second-command", description = "Second action", category = "System",
			entry = '-- 1. System\nhl.bind("SUPER + B", hl.dsp.exec_cmd([[second-command]]), { release = true, description = "Second action" })\n',
		},
	},
	{
		id = "niri",
		compositor = "Niri",
		rootName = "config.kdl",
		managedName = "keymap.kdl",
		comment = "//",
		root = "// user config\n",
		includeLine = 'include "keymap.kdl"',
		validatorPrefix = "niri validate -c ",
		reloadCommand = "niri msg action load-config-file",
		first = {
			modifiers = { "SUPER", "SHIFT" }, keys = { "A" }, activation = "press",
			command = "launch-app", description = "Open app", category = "Applications",
			entry = '    //"Applications"\n    Mod+Shift+A repeat=false hotkey-overlay-title="Open app" { spawn-sh "launch-app"; }\n',
		},
		second = {
			modifiers = { "CTRL", "ALT" }, keys = { "B" }, activation = "press",
			command = "second-command", description = "Second action", category = "System",
			entry = '    //"System"\n    Ctrl+Alt+B repeat=false hotkey-overlay-title="Second action" { spawn-sh "second-command"; }\n',
		},
	},
	{
		id = "mangowc",
		compositor = "MangoWC",
		rootName = "config.conf",
		managedName = "keymap.conf",
		comment = "#",
		root = "# user config\n",
		includeLine = "source=./keymap.conf",
		validatorPrefix = "mango -c ",
		validatorSuffix = " -p",
		reloadCommand = "mmsg dispatch reload_config",
		first = {
			modifiers = { "SUPER", "ALT" }, keys = { "A" }, activation = "release",
			command = "launch-app", description = "Open app", category = "Applications",
			entry = '# Keymap category: Applications\nbindr=SUPER+ALT,A,spawn_shell,launch-app #"Open app"\n',
		},
		second = {
			modifiers = {}, keys = { "B" }, activation = "press",
			command = "second-command", description = "Second action", category = "System",
			entry = '# Keymap category: System\nbind=NONE,B,spawn_shell,second-command #"Second action"\n',
		},
	},
}

local function reset(case)
	files = {}
	stateValues = {}
	commands = {}
	failure = { preflight = false, validator = false, reloadOnce = false, remove = false }
	reloadAttempts = 0
	local directory = "/tmp/keymap-create-test/" .. case.id
	case.rootPath = directory .. "/" .. case.rootName
	case.managedPath = directory .. "/" .. case.managedName
	files[case.rootPath] = case.root
	stateValues["keymap.snapshot"] = {
		status = "ready",
		compositor = case.compositor,
		source = case.rootPath,
		categories = {},
		hidden = {},
	}
end

local function createRequest(case, spec, requestId, source)
	return {
		request_id = requestId,
		compositor = case.compositor,
		source = source or case.rootPath,
		modifiers = spec.modifiers,
		keys = spec.keys,
		activation = spec.activation,
		command = spec.command,
		command_kind = spec.command_kind,
		library_entry_id = spec.library_entry_id,
		description = spec.description,
		category = spec.category,
	}
end

local function submit(case, spec, requestId, source)
	noctalia.state.set("keymap.create_request", createRequest(case, spec, requestId, source))
	local result = stateValues["keymap.create_result"]
	assert(type(result) == "table", case.id .. ": missing create result")
	assert(result.request_id == requestId, case.id .. ": result request id mismatch")
	return result
end

local function includeBlock(case)
	return case.comment .. " BEGIN Keymap managed include\n"
		.. case.includeLine .. "\n"
		.. case.comment .. " END Keymap managed include"
end

local function expectedRoot(case)
	return case.root .. "\n" .. includeBlock(case) .. "\n"
end

local function expectedDirectRoot(case, entries)
	if case.compositor == "Niri" then
		local content = case.root .. "\nbinds {\n"
		for _, entry in ipairs(entries) do content = content .. entry end
		return content .. "}\n"
	end
	if case.compositor == "MangoWC" then
		local content = case.root .. "\nkeymode=default\n"
		for _, entry in ipairs(entries) do content = content .. "\n" .. entry end
		return content
	end
	local content = case.root
	for _, entry in ipairs(entries) do content = content .. "\n" .. entry end
	return content
end

local function expectedMigratedRoot(case, entries)
	return expectedDirectRoot(case, entries)
end

local function managedHeader(case)
	return case.comment .. " Managed by Noctalia Keymap.\n"
		.. case.comment .. " Existing entries are preserved; new entries are appended.\n"
end

local function expectedManaged(case, entries)
	local content
	if case.compositor == "Niri" then
		content = managedHeader(case) .. "binds {\n"
		for _, entry in ipairs(entries) do content = content .. entry end
		return content .. "}\n"
	end
	if case.compositor == "MangoWC" then
		content = managedHeader(case) .. "\nkeymode=default\n\n"
	else
		content = managedHeader(case) .. "\n"
	end
	for _, entry in ipairs(entries) do content = content .. entry end
	return content
end

local function validatorCommand(case)
	return case.validatorPrefix .. "'" .. case.rootPath .. "'" .. (case.validatorSuffix or "")
end

local function assertNormalCommandSequence(case, label)
	assert(#commands == 3, label .. ": expected preflight, validator and reload")
	assert(commands[1].command:find("[ ! -L ", 1, true) == 1, label .. ": preflight was not first")
	assert(commands[1].timeout == 2000, label .. ": unexpected preflight timeout")
	assert(commands[2].command == validatorCommand(case), label .. ": wrong validator command")
	assert(commands[2].timeout == 8000, label .. ": unexpected validator timeout")
	assert(commands[3].command == case.reloadCommand, label .. ": wrong reload command")
	assert(commands[3].timeout == 5000, label .. ": unexpected reload timeout")
end

local function assertNoTemporaryFiles(label)
	for path, _ in pairs(files) do
		assert(not path:match("%.keymap%-.+%.tmp$"), label .. ": temporary file left behind: " .. path)
	end
end

local function runHappyPath(case)
	reset(case)
	local firstResult = submit(case, case.first, case.id .. "-first")
	assert(firstResult.ok == true, case.id .. ": first create failed: " .. tostring(firstResult.error))
	assert(firstResult.managed_path == case.rootPath, case.id .. ": wrong result path")
	assert(files[case.rootPath] == expectedDirectRoot(case, { case.first.entry }),
		case.id .. ": first direct write differs\n" .. tostring(files[case.rootPath]))
	assert(files[case.managedPath] == nil, case.id .. ": first create left a managed file")
	assertNormalCommandSequence(case, case.id .. " first create")
	assertNoTemporaryFiles(case.id .. " first create")

	commands = {}
	local secondResult = submit(case, case.second, case.id .. "-second")
	assert(secondResult.ok == true, case.id .. ": second create failed: " .. tostring(secondResult.error))
	assert(files[case.rootPath] == expectedDirectRoot(case, { case.first.entry, case.second.entry }),
		case.id .. ": second direct write differs\n" .. tostring(files[case.rootPath]))
	assert(files[case.managedPath] == nil, case.id .. ": second create left a managed file")
	assertNormalCommandSequence(case, case.id .. " second create")

	local rootBefore = files[case.rootPath]
	local managedBefore = files[case.managedPath]
	commands = {}
	local duplicateResult = submit(case, case.second, case.id .. "-duplicate")
	assert(duplicateResult.ok == true, case.id .. ": exact duplicate was not idempotent")
	assert(files[case.rootPath] == rootBefore and files[case.managedPath] == managedBefore,
		case.id .. ": exact duplicate changed files")
	assert(#commands == 1 and commands[1].command:find("[ ! -L ", 1, true) == 1,
		case.id .. ": exact duplicate unexpectedly validated or reloaded")
	assertNoTemporaryFiles(case.id .. " duplicate")
end

local function runVerifyRollback(case)
	reset(case)
	failure.validator = true
	failure.validatorCommand = validatorCommand(case)
	local result = submit(case, case.first, case.id .. "-verify-rollback")
	assert(result.ok == false and result.error == "verify_failed",
		case.id .. ": expected verify_failed, got " .. tostring(result.error))
	assert(files[case.rootPath] == case.root, case.id .. ": verify rollback did not restore root")
	assert(files[case.managedPath] == nil, case.id .. ": verify rollback left a new managed file")
	assert(#commands == 2 and commands[2].command == validatorCommand(case),
		case.id .. ": unexpected verify rollback command sequence")
	assertNoTemporaryFiles(case.id .. " verify rollback")
end

local function runReloadRollbackOnAppend(case)
	reset(case)
	local baseline = submit(case, case.first, case.id .. "-reload-baseline")
	assert(baseline.ok == true, case.id .. ": reload rollback baseline failed")
	local rootBefore = files[case.rootPath]
	local managedBefore = files[case.managedPath]

	commands = {}
	failure.reloadOnce = true
	failure.reloadCommand = case.reloadCommand
	reloadAttempts = 0
	local result = submit(case, case.second, case.id .. "-reload-rollback")
	assert(result.ok == false and result.error == "reload_failed",
		case.id .. ": expected reload_failed, got " .. tostring(result.error))
	assert(files[case.rootPath] == rootBefore, case.id .. ": reload rollback changed root")
	assert(files[case.managedPath] == managedBefore, case.id .. ": reload rollback did not restore managed file")
	assert(#commands == 4, case.id .. ": expected preflight, validator, failed reload and recovery reload")
	assert(commands[1].command:find("[ ! -L ", 1, true) == 1, case.id .. ": missing preflight")
	assert(commands[2].command == validatorCommand(case), case.id .. ": missing validator")
	assert(commands[3].command == case.reloadCommand and commands[4].command == case.reloadCommand,
		case.id .. ": restored configuration was not reloaded")
	assert(reloadAttempts == 2, case.id .. ": expected two reload attempts")
	assertNoTemporaryFiles(case.id .. " reload rollback")
end

local function runManagedMigration(case)
	reset(case)
	files[case.rootPath] = expectedRoot(case)
	files[case.managedPath] = expectedManaged(case, { case.first.entry })
	local result = submit(case, case.second, case.id .. "-migration")
	assert(result.ok == true, case.id .. ": migration failed: " .. tostring(result.error))
	assert(files[case.rootPath] == expectedMigratedRoot(case, { case.first.entry, case.second.entry }),
		case.id .. ": migrated root differs\n" .. tostring(files[case.rootPath]))
	assert(files[case.managedPath] == nil, case.id .. ": managed file was not removed after migration")
	assertNormalCommandSequence(case, case.id .. " migration")
	assertNoTemporaryFiles(case.id .. " migration")
end

local function runManagedMigrationRollback(case)
	reset(case)
	local rootBefore = expectedRoot(case)
	local managedBefore = expectedManaged(case, { case.first.entry })
	files[case.rootPath] = rootBefore
	files[case.managedPath] = managedBefore
	failure.validator = true
	failure.validatorCommand = validatorCommand(case)
	local result = submit(case, case.second, case.id .. "-migration-rollback")
	assert(result.ok == false and result.error == "verify_failed",
		case.id .. ": migration validation failure was not reported")
	assert(files[case.rootPath] == rootBefore, case.id .. ": failed migration did not restore root")
	assert(files[case.managedPath] == managedBefore,
		case.id .. ": failed migration removed or changed the managed file")
	assertNoTemporaryFiles(case.id .. " migration rollback")
end

local function runPlainIncludeMigration(case)
	reset(case)
	files[case.rootPath] = case.root .. case.includeLine .. "\n"
	files[case.managedPath] = expectedManaged(case, { case.first.entry })
	local result = submit(case, case.second, case.id .. "-plain-migration")
	assert(result.ok == true, case.id .. ": plain-include migration failed: " .. tostring(result.error))
	local migrated = files[case.rootPath]
	assert(type(migrated) == "string" and not migrated:find(case.includeLine, 1, true),
		case.id .. ": plain include remained after migration")
	assert(migrated:find(case.first.entry, 1, true) and migrated:find(case.second.entry, 1, true),
		case.id .. ": plain-include migration lost shortcuts")
	assert(files[case.managedPath] == nil,
		case.id .. ": plain-include migration did not remove the managed file")
end

local function runManagedMigrationReloadRollback(case)
	reset(case)
	local rootBefore = expectedRoot(case)
	local managedBefore = expectedManaged(case, { case.first.entry })
	files[case.rootPath] = rootBefore
	files[case.managedPath] = managedBefore
	failure.reloadOnce = true
	failure.reloadCommand = case.reloadCommand
	local result = submit(case, case.second, case.id .. "-migration-reload-rollback")
	assert(result.ok == false and result.error == "reload_failed",
		case.id .. ": migration reload failure was not reported")
	assert(files[case.rootPath] == rootBefore, case.id .. ": reload rollback did not restore root")
	assert(files[case.managedPath] == managedBefore,
		case.id .. ": reload rollback removed or changed the managed file")
	assert(reloadAttempts == 2, case.id .. ": restored legacy configuration was not reloaded")
	assertNoTemporaryFiles(case.id .. " migration reload rollback")
end

local function runManagedMigrationRemoveRollback(case)
	reset(case)
	local rootBefore = expectedRoot(case)
	local managedBefore = expectedManaged(case, { case.first.entry })
	files[case.rootPath] = rootBefore
	files[case.managedPath] = managedBefore
	failure.remove = true
	local result = submit(case, case.second, case.id .. "-migration-remove-rollback")
	assert(result.ok == false and result.error == "migration_remove_failed",
		case.id .. ": migration removal failure was not reported")
	assert(files[case.rootPath] == rootBefore, case.id .. ": removal rollback did not restore root")
	assert(files[case.managedPath] == managedBefore,
		case.id .. ": removal rollback changed the managed file")
	assert(#commands == 4 and commands[4].command == case.reloadCommand,
		case.id .. ": removal rollback did not reload the restored configuration")
	assertNoTemporaryFiles(case.id .. " migration remove rollback")
end

local function runAutomaticMigration(case)
	reset(case)
	files[case.rootPath] = expectedRoot(case)
	files[case.managedPath] = expectedManaged(case, { case.first.entry })
	watchers["keymap.snapshot"](stateValues["keymap.snapshot"])
	local result = stateValues["keymap.migration_result"]
	assert(type(result) == "table" and result.ok == true,
		case.id .. ": automatic migration failed: " .. tostring(result and result.error))
	assert(files[case.rootPath] == expectedMigratedRoot(case, { case.first.entry }),
		case.id .. ": automatic migration changed shortcut content")
	assert(files[case.managedPath] == nil,
		case.id .. ": automatic migration did not remove the legacy file")
	assertNormalCommandSequence(case, case.id .. " automatic migration")
	assertNoTemporaryFiles(case.id .. " automatic migration")
end

assert(loadfile("writer_service.luau"))()

for _, case in ipairs(CASES) do
	runAutomaticMigration(case)
	runHappyPath(case)
	runVerifyRollback(case)
	runReloadRollbackOnAppend(case)
	runManagedMigration(case)
	runManagedMigrationRollback(case)
	runPlainIncludeMigration(case)
	runManagedMigrationReloadRollback(case)
	runManagedMigrationRemoveRollback(case)
end

do
	local case = CASES[2]
	reset(case)
	local existing = 'layout "us"\nbinds {\n    // a closing brace in a comment: }\n'
		.. '    Mod+X { spawn "brace } in a string"; }\n}\n'
	files[case.rootPath] = existing
	local result = submit(case, case.first, "niri-existing-binds")
	assert(result.ok == true, "niri existing binds create failed: " .. tostring(result.error))
	local expected = existing:sub(1, -3) .. case.first.entry .. "}\n"
	assert(files[case.rootPath] == expected,
		"niri entry was not inserted before the matching top-level binds close")
end

local NATIVE_CASES = {
	{
		base = CASES[1], id = "hypr-native", command = "hl.dsp.window.close()",
		library_entry_id = "hyprland/window.close",
		entry = '-- 1. Windows\nhl.bind("SUPER + N", hl.dsp.window.close(), { description = "Close window" })\n',
	},
	{
		base = CASES[2], id = "niri-native", command = "close-window",
		library_entry_id = "niri/close-window",
		entry = '    //"Windows"\n    Mod+N repeat=false hotkey-overlay-title="Close window" { close-window; }\n',
	},
	{
		base = CASES[3], id = "mango-native", command = "killclient",
		library_entry_id = "mangowc/killclient",
		entry = '# Keymap category: Windows\nbind=SUPER,N,killclient #"Close window"\n',
	},
}

for _, native in ipairs(NATIVE_CASES) do
	local case = native.base
	reset(case)
	local spec = {
		modifiers = { "SUPER" }, keys = { "N" }, activation = "press",
		command = native.command, command_kind = "native",
		library_entry_id = native.library_entry_id,
		description = "Close window", category = "Windows",
	}
	local result = submit(case, spec, native.id)
	assert(result.ok == true, native.id .. ": native create failed: " .. tostring(result.error))
	assert(files[case.rootPath] == expectedDirectRoot(case, { native.entry }),
		native.id .. ": wrong native root entry")
	assert(files[case.managedPath] == nil, native.id .. ": native create left a managed file")
end

do
	local case = CASES[1]
	reset(case)
	local spec = {
		modifiers = { "SUPER" }, keys = { "N" }, activation = "press",
		command = "hl.dsp.window.kill()", command_kind = "native",
		library_entry_id = "hyprland/window.close",
		description = "Tampered action", category = "Windows",
	}
	local result = submit(case, spec, "native-tampered")
	assert(result.ok == false and result.error == "library_entry_invalid",
		"tampered native action was accepted")
	assert(files[case.managedPath] == nil, "tampered native action changed files")
end

do
	local case = CASES[1]
	reset(case)
	local spec = {
		modifiers = { "SUPER" }, keys = { "N" }, activation = "press",
		command = "hl.dsp.exec_cmd({{command}})", command_kind = "native",
		library_entry_id = "hyprland/exec_cmd",
		description = "Incomplete action", category = "Applications",
	}
	local result = submit(case, spec, "native-placeholder")
	assert(result.ok == false and result.error == "library_arguments_required",
		"unresolved native placeholder was accepted")
	assert(files[case.managedPath] == nil, "unresolved native placeholder changed files")
end

do
	local case = CASES[3]
	reset(case)
	local spec = {
		modifiers = { "SUPER" }, keys = { "N" }, activation = "press",
		command = "hl.dsp.window.close()", command_kind = "native",
		library_entry_id = "hyprland/window.close",
		description = "Foreign action", category = "Windows",
	}
	local result = submit(case, spec, "native-foreign-source")
	assert(result.ok == false and result.error == "library_entry_invalid",
		"native action from another compositor was accepted")
	assert(files[case.managedPath] == nil, "foreign native action changed files")
end

do
	local case = CASES[1]
	reset(case)
	stateValues["keymap.snapshot"].source = case.rootPath .. ".other"
	local result = submit(case, case.first, "stale-context")
	assert(result.ok == false and result.error == "stale_context", "stale context was accepted")
	assert(files[case.rootPath] == case.root and files[case.managedPath] == nil,
		"stale context changed files")
	assert(#commands == 0, "stale context reached preflight")
end

do
	local case = CASES[1]
	reset(case)
	failure.preflight = true
	local result = submit(case, case.first, "symlink-preflight")
	assert(result.ok == false and result.error == "symlink_unsupported", "symlink preflight was accepted")
	assert(files[case.rootPath] == case.root and files[case.managedPath] == nil,
		"failed symlink preflight changed files")
	assert(#commands == 1 and commands[1].command:find("[ ! -L ", 1, true) == 1,
		"symlink rejection did not stop after preflight")
end

print("writer create tests: ok")
