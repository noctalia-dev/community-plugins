local stateValues = { clipper_panel_open = false }
local stateWatchers = {}
local asyncCalls = {}
local streamCalls = {}
local notifications = {}
local contextMenuRequests = {}
local files = {}
local mockEnv = {}
local mkdirCalls = {}
local mkdirAllowed = true
local failExportWrites = false
local config = {
	-- database_mode is deliberately omitted: missing or invalid values must
	-- preserve the backward-compatible private database.
	history_limit = 3,
	manage_watchers = true,
	auto_paste_delay = 300,
	max_pinned = 20,
	notes_color = "#11223366",
}
local fakeClock = 10
local cliphistCommand = "CLIPHIST_DB_PATH='/virtual/clipper-data/cliphist.db' CLIPHIST_MAX_ITEMS=3 CLIPHIST_PREVIEW_WIDTH=240 cliphist"

local realClock = os.clock
local realDate = os.date
os.clock = function() return fakeClock end
os.date = function(format)
	if format == "%Y%m%d-%H%M%S" then return "20260820-231500" end
	return realDate(format)
end

noctalia = {
	pluginDataDir = function() return "/virtual/clipper-data", nil end,
	expandPath = function(path) return path:gsub("^~", "/virtual/home") end,
	getConfig = function(key) return config[key] end,
	json = {
		encode = function(_value) return "{}" end,
		decode = function(value)
			if value:find('"address":"0xabc123"', 1, true) ~= nil then
				return { address = "0xabc123" }
			end
			local operation = value:match('"operation"%s*:%s*"([^"]+)"')
			local id = value:match('"id"%s*:%s*"([^"]+)"')
			local title = value:match('"title"%s*:%s*"([^"]*)"')
			local content = value:match('"content"%s*:%s*"([^"]*)"')
			local x = tonumber(value:match('"x"%s*:%s*([%d%.%-]+)'))
			local y = tonumber(value:match('"y"%s*:%s*([%d%.%-]+)'))
			local targetIndex = tonumber(value:match('"target_index"%s*:%s*(%d+)'))
			if operation ~= nil or id ~= nil then
				return {
					operation = operation, id = id, title = title, content = content,
					x = x, y = y, target_index = targetIndex,
				}
			end
			return {}
		end,
	},
	getenv = function(key) return mockEnv[key] end,
	readFile = function(path) return files[path] end,
	writeFile = function(path, value)
		if failExportWrites and path:find("/virtual/home/Documents/Clipper/", 1, true) == 1 then return false end
		files[path] = value
		return true
	end,
	renameFile = function(from, to)
		if files[from] == nil then return false end
		files[to] = files[from]
		files[from] = nil
		return true
	end,
	removeFile = function(path) files[path] = nil return true end,
	mkdirAll = function(path)
		mkdirCalls[#mkdirCalls + 1] = path
		return mkdirAllowed
	end,
	listDir = function(path)
		local entries = {}
		local prefix = path .. "/"
		for filePath, _ in pairs(files) do
			if filePath:sub(1, #prefix) == prefix then
				local name = filePath:sub(#prefix + 1)
				if name:find("/", 1, true) == nil then entries[#entries + 1] = name end
			end
		end
		return entries
	end,
	fileExists = function(path) return files[path] ~= nil end,
	fileInfo = function(path)
		local value = files[path]
		if value == nil then return nil end
		return { size = #value, isDir = false, mtime = 0 }
	end,
	commandExists = function(command)
		return command == "cliphist" or command == "wl-paste"
			or command == "wl-copy" or command == "wtype" or command == "hyprctl"
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
	tr = function(key, args)
		if key == "selection.add_to" then return "Add to " .. tostring(args.title) end
		return key
	end,
	notify = function(title, body) notifications[#notifications + 1] = { title, body } end,
	notifyError = function(title, body) notifications[#notifications + 1] = { title, body } end,
	log = function(_message) end,
}

service = {
	openContextMenu = function(request)
		contextMenuRequests[#contextMenuRequests + 1] = request
		return true
	end,
}

local function request(value)
	noctalia.state.set("clipper_request", value)
	return stateValues.clipper_result
end

local function completeNext(result)
	assert(#asyncCalls > 0, "missing asynchronous call")
	local call = table.remove(asyncCalls, 1)
	call.callback(result or { exitCode = 0, stdout = "", stderr = "", timedOut = false })
	return call
end

assert(loadfile("service.luau"))()

do
	local snapshot = stateValues.clipper_snapshot
	assert(snapshot.status == "idle", "service eagerly loaded history")
	assert(snapshot.watchers_running == true, "managed watchers were not reported")
	assert(type(snapshot.items) == "table" and #snapshot.items == 0)
	assert(type(snapshot.pinned) == "table" and #snapshot.pinned == 0)
	assert(type(snapshot.notes) == "table" and #snapshot.notes == 0)
	assert(snapshot.total == 0)
	assert(#asyncCalls == 0, "history refreshed while panel was closed")
	assert(#streamCalls == 1, "text and image watchers must share one lifecycle stream")
	assert(streamCalls[1].command:find("wl%-paste %-%-type text %-%-watch") ~= nil)
	assert(streamCalls[1].command:find("wl%-paste %-%-type image %-%-watch") ~= nil)
end

-- Watcher noise is ignored, and a valid event only dirties the closed panel.
streamCalls[1].callback("not clipboard content")
streamCalls[1].callback("__clipper_changed__")
assert(#asyncCalls == 0, "closed panel refreshed after watcher event")

-- Opening the panel performs one bounded query.
noctalia.state.set("clipper_panel_open", true)
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == cliphistCommand .. " list | head -n 4")
assert(asyncCalls[1].timeout == 5000)
assert(stateValues.clipper_snapshot.status == "loading")

local syntheticList = table.concat({
	"42\talpha preview",
	"not-an-id\tignored",
	"42\tduplicate ignored",
	"43\t[[ binary data 30 KiB png 681x170 ]]",
	"44\tcontains\0control",
	"45\tfourth valid row is beyond the configured snapshot",
}, "\n") .. "\n"
completeNext({ exitCode = 0, stdout = syntheticList, stderr = "", timedOut = false })

do
	local snapshot = stateValues.clipper_snapshot
	assert(snapshot.status == "ready" and snapshot.error == "")
	assert(snapshot.total == 3 and #snapshot.items == 3, "history limit was not enforced")
	assert(snapshot.items[1].id == "42" and snapshot.items[1].kind == "text")
	assert(snapshot.items[1].is_image == false and snapshot.items[1].mime == "text/plain")
	assert(snapshot.items[2].id == "43" and snapshot.items[2].kind == "image")
	assert(snapshot.items[2].is_image == true and snapshot.items[2].mime == "image/png")
	assert(snapshot.items[3].preview:find("%c") == nil, "control byte escaped into shared state")
end

-- Image history entries are decoded outside Lua into a bounded, plugin-owned
-- cache. The snapshot is republished only after the temporary file is valid.
assert(#asyncCalls == 1, "image thumbnail decode was not queued")
local thumbnailPath = "/virtual/clipper-data/thumbnails/43.png"
assert(asyncCalls[1].command == cliphistCommand .. " decode '43' > '" .. thumbnailPath .. ".tmp'")
files[thumbnailPath .. ".tmp"] = "synthetic png bytes"
completeNext()
assert(files[thumbnailPath] == "synthetic png bytes")
assert(stateValues.clipper_snapshot.items[2].image_path == thumbnailPath)
assert(#asyncCalls == 0)

-- Refreshes coalesce while one callback is in flight.
local firstRefresh = request({ request_id = "refresh-1", operation = "refresh" })
assert(firstRefresh.ok == true and #asyncCalls == 1)
local secondRefresh = request({ request_id = "refresh-2", operation = "refresh" })
assert(secondRefresh.ok == true and #asyncCalls == 1, "refresh callbacks were not bounded")
completeNext({ exitCode = 0, stdout = "42\talpha preview\n", stderr = "", timedOut = false })
assert(#asyncCalls == 1, "queued explicit refresh was lost")
completeNext({ exitCode = 0, stdout = "42\talpha preview\n", stderr = "", timedOut = false })
assert(#asyncCalls == 0)

noctalia.state.set("clipper_panel_open", false)

-- Numeric validation rejects shell metacharacters before spawning anything.
local invalid = request({ request_id = "bad-id", operation = "activate", id = "42; touch /tmp/no" })
assert(invalid.ok == false and invalid.error == "invalid_id")
assert(#asyncCalls == 0)

-- Activation streams cliphist directly to wl-copy and does not include a preview.
local activate = request({ request_id = "activate-1", operation = "activate", id = "42", paste = false })
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == cliphistCommand .. " decode '42' | wl-copy")
assert(asyncCalls[1].command:find("alpha preview", 1, true) == nil)
completeNext()
activate = stateValues.clipper_result
assert(activate.ok == true and activate.operation == "activate")
assert(activate.paste_requested == false and activate.paste_scheduled == false)

-- Explicit paste schedules one bounded timer and invokes the V4 shortcut only
-- after restoring the window that was focused when the panel opened.
mockEnv.HYPRLAND_INSTANCE_SIGNATURE = "test-instance"
noctalia.state.set("clipper_panel_open", true)
assert(#asyncCalls == 2, "panel open did not capture focus and refresh history")
assert(asyncCalls[1].command == "hyprctl -j activewindow")
completeNext({ exitCode = 0, stdout = '{"address":"0xabc123"}', stderr = "", timedOut = false })
assert(#asyncCalls == 1 and asyncCalls[1].command == cliphistCommand .. " list | head -n 4")
completeNext({ exitCode = 0, stdout = "42\talpha preview\n", stderr = "", timedOut = false })
noctalia.state.set("clipper_panel_open", false)

request({ request_id = "activate-paste", operation = "activate", id = 42, paste = true })
completeNext()
assert(stateValues.clipper_result.paste_scheduled == true)
assert(stateValues.update_interval == 50)
update()
assert(#asyncCalls == 0, "paste ran before its deadline")
fakeClock = 10.31
update()
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == "(hyprctl dispatch focuswindow 'address:0xabc123' || hyprctl eval 'hl.dsp.focus({window = \"address:0xabc123\"})') || exit 70; sleep 0.05; wtype -M ctrl -M shift v")
completeNext()
assert(stateValues.update_interval == 1000)

-- Pinning stores decoded bytes outside Lua and publishes only bounded metadata.
request({ request_id = "pin-1", operation = "pin", id = "42" })
assert(#asyncCalls == 1 and asyncCalls[1].command:find(cliphistCommand .. " decode '42' > ", 1, true) == 1)
local pinnedPath = asyncCalls[1].command:match(" > '([^']+)'$")
assert(pinnedPath ~= nil)
files[pinnedPath] = "persisted clipboard bytes"
completeNext()
local pinned = stateValues.clipper_snapshot.pinned[1]
assert(pinned ~= nil and pinned.preview == "alpha preview")
assert(pinned.id:match("^pin%-%d+%-%d+$") ~= nil)
assert(files[pinnedPath] ~= nil, "pin payload was not retained")

request({ request_id = "copy-pin-1", operation = "copy_pinned", id = pinned.id, paste = false })
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == "wl-copy --type 'text/plain' < '" .. pinnedPath .. "'")
completeNext()
assert(stateValues.clipper_result.ok == true)

request({ request_id = "unpin-1", operation = "unpin", id = pinned.id })
assert(#stateValues.clipper_snapshot.pinned == 0)
assert(files[pinnedPath] == nil, "unpin did not remove its private payload")

-- Notecards are synchronous, bounded, persistent service mutations.
request({ request_id = "note-create-1", operation = "create_note" })
local firstNote = stateValues.clipper_snapshot.notes[1]
assert(firstNote ~= nil and firstNote.color == "#112233")
assert(firstNote.x == 24 and firstNote.y == 24 and firstNote.z == 1)
assert(files["/virtual/clipper-data/notes.json"] == "{}", "notecards were not persisted in plugin data")
request({
	request_id = "note-update-1", operation = "update_note", id = firstNote.id,
	title = "Title", content = "Body",
})
assert(stateValues.clipper_snapshot.notes[1].title == "Title")
assert(stateValues.clipper_snapshot.notes[1].content == "Body")
request({ request_id = "note-color-1", operation = "cycle_note_color", id = firstNote.id })
assert(stateValues.clipper_snapshot.notes[1].color == "#FFD54F")
request({ request_id = "note-create-2", operation = "create_note" })
local secondNote = stateValues.clipper_snapshot.notes[2]
request({
	request_id = "note-reorder-1", operation = "reorder_note", id = secondNote.id, target_index = 1,
})
assert(stateValues.clipper_snapshot.notes[1].id == secondNote.id)
request({
	request_id = "note-move-1", operation = "move_note", id = firstNote.id, x = 412.4, y = 237.7,
})
assert(firstNote.x == 412 and firstNote.y == 238)
assert(firstNote.z > secondNote.z)
request({ request_id = "note-export-1", operation = "export_note", id = firstNote.id })
assert(stateValues.clipper_result.ok == true)
local firstExportPath = stateValues.clipper_result.path
assert(type(firstExportPath) == "string")
assert(firstExportPath:match("^/virtual/home/Documents/Clipper/notecard%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-note%-%d+%-%d+%.txt$") ~= nil)
assert(mkdirCalls[#mkdirCalls] == "/virtual/home/Documents/Clipper")
assert(files[firstExportPath] == "Title\n\nBody", "notecard export lost its title or content")

-- Repeated exports in the same second never overwrite an earlier file.
request({ request_id = "note-export-2", operation = "export_note", id = firstNote.id })
local secondExportPath = stateValues.clipper_result.path
assert(secondExportPath == firstExportPath:gsub("%.txt$", "-2.txt"))
assert(files[firstExportPath] == "Title\n\nBody" and files[secondExportPath] == "Title\n\nBody")

-- Directory and file failures are reported without publishing a false path.
mkdirAllowed = false
request({ request_id = "note-export-mkdir-failure", operation = "export_note", id = firstNote.id })
assert(stateValues.clipper_result.ok == false and stateValues.clipper_result.error == "note_export_failed")
assert(stateValues.clipper_result.path == nil)
mkdirAllowed = true
failExportWrites = true
request({ request_id = "note-export-write-failure", operation = "export_note", id = firstNote.id })
assert(stateValues.clipper_result.ok == false and stateValues.clipper_result.error == "note_export_failed")
assert(stateValues.clipper_result.path == nil)
failExportWrites = false

-- The selection workflow reads primary selection before opening a native menu.
-- Its actions are generated from current note titles and retain only one
-- short-lived, generation-checked selection.
onIpc("selection-menu", "")
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == "wl-paste --primary --no-newline --type text")
assert(asyncCalls[1].timeout == 5000)
completeNext({ exitCode = 0, stdout = "Selected text", stderr = "", timedOut = false })
assert(#contextMenuRequests == 1)
local firstMenu = contextMenuRequests[1]
assert(firstMenu.onActivate == "onSelectionContextAction")
assert(type(firstMenu.context) == "number")
assert(#firstMenu.items == 3)
assert(firstMenu.items[1].id == "new" and firstMenu.items[1].enabled == true)
local menuItemsById = {}
for _, item in ipairs(firstMenu.items) do menuItemsById[item.id] = item end
assert(menuItemsById["note:" .. firstNote.id].label == "Add to Title")
assert(menuItemsById["note:" .. secondNote.id].label == "Add to panel.notes.untitled")

onSelectionContextAction("note:" .. firstNote.id, firstMenu.context)
assert(firstNote.content == "Body\n\nSelected text")
assert(stateValues.clipper_result.operation == "append_note" and stateValues.clipper_result.ok == true)

onIpc("selection-menu", "")
completeNext({ exitCode = 0, stdout = "A new card", stderr = "", timedOut = false })
local secondMenu = contextMenuRequests[2]
onSelectionContextAction("new", secondMenu.context)
local selectionNote = stateValues.clipper_snapshot.notes[#stateValues.clipper_snapshot.notes]
assert(selectionNote.content == "A new card")
assert(stateValues.clipper_result.operation == "create_note" and stateValues.clipper_result.ok == true)

-- The named export IPC preserves an untitled note's body without adding a
-- synthetic title to the portable file.
onIpc("export-note", selectionNote.id)
assert(stateValues.clipper_result.operation == "export_note" and stateValues.clipper_result.ok == true)
assert(files[stateValues.clipper_result.path] == "A new card")

-- An old menu callback cannot consume or redirect a newer selection.
onIpc("selection-menu", "")
completeNext({ exitCode = 0, stdout = "Current generation", stderr = "", timedOut = false })
local currentMenu = contextMenuRequests[3]
local noteCountBeforeStaleAction = #stateValues.clipper_snapshot.notes
onSelectionContextAction("new", secondMenu.context)
assert(#stateValues.clipper_snapshot.notes == noteCountBeforeStaleAction)
onSelectionContextAction("note:" .. secondNote.id, currentMenu.context)
assert(secondNote.content == "Current generation")

-- A title-only notecard exports its title without trailing blank lines.
request({
	request_id = "note-title-only", operation = "update_note", id = secondNote.id,
	title = "Only title", content = "",
})
request({ request_id = "note-title-only-export", operation = "export_note", id = secondNote.id })
assert(stateValues.clipper_result.ok == true)
assert(files[stateValues.clipper_result.path] == "Only title")

onIpc("selection-menu", "")
completeNext({ exitCode = 1, stdout = "", stderr = "no selection", timedOut = false })
assert(#contextMenuRequests == 3, "failed selection unexpectedly opened a menu")
request({ request_id = "note-delete-1", operation = "delete_note", id = firstNote.id })
assert(#stateValues.clipper_snapshot.notes == noteCountBeforeStaleAction - 1)

-- Delete sends only the validated ID to cliphist, never preview/content.
local deleted = request({ request_id = "delete-1", operation = "delete", id = "42" })
assert(#asyncCalls == 1)
assert(asyncCalls[1].command == "printf '%s\\n' '42' | " .. cliphistCommand .. " delete")
assert(asyncCalls[1].command:find("alpha preview", 1, true) == nil)
completeNext()
deleted = stateValues.clipper_result
assert(deleted.ok == true and deleted.operation == "delete")
-- A successful mutation forces a bounded refresh even with the panel closed.
assert(#asyncCalls == 1 and asyncCalls[1].command:find("cliphist list", 1, true) ~= nil)
completeNext({ exitCode = 0, stdout = "", stderr = "", timedOut = false })

local wiped = request({ request_id = "wipe-1", operation = "wipe" })
assert(#asyncCalls == 1 and asyncCalls[1].command == cliphistCommand .. " wipe")
completeNext()
wiped = stateValues.clipper_result
assert(wiped.ok == true and wiped.operation == "wipe")
assert(stateValues.clipper_snapshot.total == 0 and #stateValues.clipper_snapshot.items == 0)

-- Duplicate request IDs are idempotent.
request({ request_id = "wipe-1", operation = "wipe" })
assert(#asyncCalls == 0)

-- A list-side error is not misreported as an empty, ready history.
request({ request_id = "refresh-error", operation = "refresh" })
completeNext({ exitCode = 0, stdout = "", stderr = "opening db failed", timedOut = false })
assert(stateValues.clipper_snapshot.status == "error")
assert(stateValues.clipper_snapshot.error == "refresh_failed")

-- IPC events reuse the service request dispatcher instead of bypassing its
-- validation. Named events cover every UI operation; structured note edits
-- and the generic request event accept bounded JSON objects.
onIpc("refresh", "")
assert(stateValues.clipper_result.operation == "refresh" and stateValues.clipper_result.ok == true)
completeNext({ exitCode = 0, stdout = "42\tIPC preview\n", stderr = "", timedOut = false })

onIpc("copy", " 42 ")
assert(#asyncCalls == 1 and asyncCalls[1].command == cliphistCommand .. " decode '42' | wl-copy")
completeNext()
assert(stateValues.clipper_result.operation == "activate")

local invalidIdEvents = {
	{ "paste", "activate", "invalid_id" },
	{ "pin", "pin", "invalid_id" },
	{ "delete", "delete", "invalid_id" },
	{ "unpin", "unpin", "item_not_found" },
	{ "copy-pinned", "copy_pinned", "item_not_found" },
	{ "paste-pinned", "copy_pinned", "item_not_found" },
	{ "delete-note", "delete_note", "note_not_found" },
	{ "cycle-note-color", "cycle_note_color", "note_not_found" },
	{ "export-note", "export_note", "note_not_found" },
}
for _, event in ipairs(invalidIdEvents) do
	onIpc(event[1], "not-an-id")
	assert(stateValues.clipper_result.operation == event[2])
	assert(stateValues.clipper_result.ok == false and stateValues.clipper_result.error == event[3])
end

local noteCount = #stateValues.clipper_snapshot.notes
onIpc("create-note", "")
assert(stateValues.clipper_result.operation == "create_note" and stateValues.clipper_result.ok == true)
assert(#stateValues.clipper_snapshot.notes == noteCount + 1)
local ipcNote = stateValues.clipper_snapshot.notes[#stateValues.clipper_snapshot.notes]

onIpc("update-note", '{"id":"' .. ipcNote.id .. '","title":"IPC title","content":"IPC body"}')
assert(stateValues.clipper_result.operation == "update_note" and stateValues.clipper_result.ok == true)
assert(ipcNote.title == "IPC title" and ipcNote.content == "IPC body")

onIpc("move-note", '{"id":"' .. ipcNote.id .. '","x":125,"y":250}')
assert(stateValues.clipper_result.operation == "move_note" and stateValues.clipper_result.ok == true)
assert(ipcNote.x == 125 and ipcNote.y == 250)

onIpc("reorder-note", '{"id":"' .. ipcNote.id .. '","target_index":1}')
assert(stateValues.clipper_result.operation == "reorder_note" and stateValues.clipper_result.ok == true)

onIpc("request", '{"operation":"cycle_note_color","id":"' .. ipcNote.id .. '"}')
assert(stateValues.clipper_result.operation == "cycle_note_color" and stateValues.clipper_result.ok == true)

onIpc("clear", "")
assert(#asyncCalls == 1 and asyncCalls[1].command == cliphistCommand .. " wipe")
completeNext()
assert(stateValues.clipper_result.operation == "wipe" and stateValues.clipper_result.ok == true)

onIpc("unknown-event", "")
assert(stateValues.clipper_result.ok == false and stateValues.clipper_result.error == "invalid_operation")

os.clock = realClock
os.date = realDate
print("clipper service parser tests: ok")
