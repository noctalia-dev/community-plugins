local stateValues = { clipper_panel_open = false }
local stateWatchers = {}
local asyncCalls = {}
local streamCalls = {}
local files = {}
local config = {
	database_mode = "global",
	history_limit = 3,
	manage_watchers = true,
	auto_paste_delay = 300,
	max_pinned = 20,
	notes_color = "#112233",
}

local globalCliphistCommand = "CLIPHIST_MAX_ITEMS=3 CLIPHIST_PREVIEW_WIDTH=240 cliphist"

noctalia = {
	pluginDataDir = function() return "/virtual/clipper-data", nil end,
	expandPath = function(path) return path:gsub("^~", "/virtual/home") end,
	getConfig = function(key) return config[key] end,
	json = {
		encode = function(_value) return "{}" end,
		decode = function(_value) return {} end,
	},
	readFile = function(path) return files[path] end,
	writeFile = function(path, value) files[path] = value return true end,
	renameFile = function(from, to)
		if files[from] == nil then return false end
		files[to] = files[from]
		files[from] = nil
		return true
	end,
	removeFile = function(path) files[path] = nil return true end,
	mkdirAll = function(_path) return true end,
	listDir = function(_path) return {} end,
	fileExists = function(path) return files[path] ~= nil end,
	fileInfo = function(path)
		local value = files[path]
		if value == nil then return nil end
		return { size = #value, isDir = false, mtime = 0 }
	end,
	commandExists = function(command)
		return command == "cliphist" or command == "wl-paste"
			or command == "wl-copy" or command == "wtype"
	end,
	state = {
		get = function(key) return stateValues[key] end,
		set = function(key, value)
			stateValues[key] = value
			if stateWatchers[key] ~= nil then stateWatchers[key](value) end
		end,
		watch = function(key, callback) stateWatchers[key] = callback end,
	},
	runAsync = function(command, callback, timeout)
		asyncCalls[#asyncCalls + 1] = { command = command, callback = callback, timeout = timeout }
		return true
	end,
	runStream = function(command, callback)
		streamCalls[#streamCalls + 1] = { command = command, callback = callback }
		return true
	end,
	setUpdateInterval = function(value) stateValues.update_interval = value end,
	tr = function(key) return key end,
	notify = function(_title, _body) end,
	notifyError = function(_title, _body) end,
	log = function(_message) end,
}

local function request(value)
	noctalia.state.set("clipper_request", value)
	return stateValues.clipper_result
end

local function takeAsync()
	assert(#asyncCalls > 0, "missing asynchronous call")
	return table.remove(asyncCalls, 1)
end

local function completeNext(result)
	local call = takeAsync()
	call.callback(result or { exitCode = 0, stdout = "", stderr = "", timedOut = false })
	return call
end

local function assertGlobalCommand(command)
	assert(command:find("CLIPHIST_DB_PATH", 1, true) == nil, "global command forced a private database")
	assert(command:find("/virtual/clipper-data/cliphist.db", 1, true) == nil, "global command used private data")
end

assert(loadfile("service.luau"))()

do
	local snapshot = stateValues.clipper_snapshot
	assert(snapshot.status == "idle")
	assert(snapshot.watchers_running == false, "global mode claimed ownership of external watchers")
	assert(#streamCalls == 0, "global mode started duplicate clipboard watchers")
end

-- Listing uses cliphist's standard global database resolution. The mock only
-- records this command; it never accesses the user's real database.
noctalia.state.set("clipper_panel_open", true)
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == globalCliphistCommand .. " list | head -n 4")
assertGlobalCommand(asyncCalls[1].command)
completeNext({ exitCode = 0, stdout = "42\tglobal preview\n", stderr = "", timedOut = false })
assert(stateValues.clipper_snapshot.items[1].id == "42")
noctalia.state.set("clipper_panel_open", false)

-- Reopening global history verifies externally managed clipboard changes, but
-- keeps the previous snapshot visible instead of flashing a loading state.
noctalia.state.set("clipper_panel_open", true)
assert(#asyncCalls == 1)
assert(stateValues.clipper_snapshot.status == "ready")
completeNext({ exitCode = 0, stdout = "42\tglobal preview\n", stderr = "", timedOut = false })
noctalia.state.set("clipper_panel_open", false)

request({ request_id = "global-activate", operation = "activate", id = "42", paste = false })
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == globalCliphistCommand .. " decode '42' | wl-copy")
assertGlobalCommand(asyncCalls[1].command)
completeNext()

request({ request_id = "global-pin", operation = "pin", id = "42" })
assert(#asyncCalls == 1)
local pinCall = asyncCalls[1]
assert(pinCall.command:find(globalCliphistCommand .. " decode '42' > ", 1, true) == 1)
assertGlobalCommand(pinCall.command)
local pinPath = pinCall.command:match(" > '([^']+)'$")
assert(pinPath ~= nil)
files[pinPath] = "global payload copied into private pin storage"
completeNext()
assert(stateValues.clipper_result.ok == true)

request({ request_id = "global-delete", operation = "delete", id = "42" })
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == "printf '%s\\n' '42' | " .. globalCliphistCommand .. " delete")
assertGlobalCommand(asyncCalls[1].command)
completeNext()
-- A successful delete always verifies the resulting history with the same DB.
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == globalCliphistCommand .. " list | head -n 4")
assertGlobalCommand(asyncCalls[1].command)
completeNext()

request({ request_id = "global-wipe", operation = "wipe" })
assert(#asyncCalls == 0, "global wipe spawned cliphist")
assert(stateValues.clipper_result.ok == false)
assert(stateValues.clipper_result.operation == "wipe")
assert(stateValues.clipper_result.error == "global_wipe_disabled")

onIpc("clear", "")
assert(#asyncCalls == 0, "global IPC clear spawned cliphist")
assert(stateValues.clipper_result.ok == false)
assert(stateValues.clipper_result.operation == "wipe")
assert(stateValues.clipper_result.error == "global_wipe_disabled")

assert(#asyncCalls == 0)
assert(#streamCalls == 0)
print("clipper global database tests: ok")
