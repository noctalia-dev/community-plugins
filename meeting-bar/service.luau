--!nonstrict
local common = require("./common.luau")
local model = common.model
local bookmarks, fired = {}, {}
local dataDir = noctalia.pluginDataDir()
local snoozed = {}

local function read(name)
	if not dataDir then
		return nil
	end
	local raw = noctalia.readFile(dataDir .. "/" .. name .. ".json")
	if not raw then
		return nil
	end
	local value = noctalia.json.decode(raw)
	return type(value) == "table" and value or nil
end

local function write(name, value)
	if not dataDir then
		noctalia.notifyError("Meeting Bar", "Cannot save preferences.")
		return false
	end
	local json = noctalia.json.encode(value)
	if not json or not noctalia.writeFile(dataDir .. "/" .. name .. ".json", json) then
		noctalia.notifyError("Meeting Bar", "Could not save " .. name .. ".")
		return false
	end
	return true
end

for _, entry in ipairs(read("bookmarks") or {}) do
	if type(entry) == "table" and model.url(entry.url) then
		bookmarks[#bookmarks + 1] = { title = model.clean(entry.title), url = entry.url }
	end
end
fired = read("reminders") or {}
snoozed = read("snoozed") or {}
noctalia.state.set("bookmarks", bookmarks)
noctalia.setUpdateInterval(15000)

noctalia.state.watch("bookmarkRequest", function(request)
	if type(request) ~= "table" or not model.url(request.url) then
		return
	end
	local updated, found = {}, false
	for _, entry in ipairs(bookmarks) do
		if entry.url == request.url then
			found = true
		else
			updated[#updated + 1] = entry
		end
	end
	if not found then
		updated[#updated + 1] = { title = model.clean(request.title), url = request.url }
	end
	if write("bookmarks", updated) then
		bookmarks = updated
		noctalia.state.set("bookmarks", bookmarks)
	end
end)

noctalia.state.watch("reminderAction", function(action)
	local event = noctalia.state.get("reminder")
	if not event or type(action) ~= "table" then
		return
	end
	if action.kind == "snooze" then
		snoozed[model.key(event)] = noctalia.nowMs() + noctalia.getConfig("snooze_minutes") * 60000
		fired[model.key(event)] = nil
		write("reminders", fired)
		write("snoozed", snoozed)
	else
		fired[model.key(event)] = event.endMs
		snoozed[model.key(event)] = nil
		write("reminders", fired)
		write("snoozed", snoozed)
	end
	noctalia.layer.hide("reminder")
	noctalia.state.set("reminder", nil)
end)

function update()
	local now = noctalia.nowMs()
	-- One native snapshot read per tick for all monitors and UI entries.
	local events = noctalia.calendarEvents()
	noctalia.state.set("snapshot", { ready = events ~= nil, events = events or {}, readAt = now })
	local active = noctalia.state.get("reminder")
	local filtered = common.events(now) or {}
	if active then
		local stillPresent = false
		for _, event in ipairs(filtered) do
			if model.key(event) == model.key(active) and event.endMs > now then
				stillPresent = true
				noctalia.state.set("reminder", event)
				break
			end
		end
		if not noctalia.getConfig("fullscreen_reminders") or not stillPresent then
			noctalia.layer.hide("reminder")
			noctalia.state.set("reminder", nil)
		end
	end
	if not noctalia.getConfig("fullscreen_reminders") then
		return
	end
	if noctalia.state.get("reminder") then
		return
	end
	for key, endMs in pairs(fired) do
		if type(endMs) ~= "number" or endMs < now - 86400000 then
			fired[key] = nil
		end
	end
	for _, event in ipairs(filtered) do
		local key = model.key(event)
		local wakeAt = snoozed[key]
		local snoozedDue = type(wakeAt) == "number" and wakeAt <= now and event.endMs > now
		if
			not event.allDay
			and model.service(event.url)
			and not fired[key]
			and (wakeAt == nil or snoozedDue)
			and (event.startMs >= now - 60000 or snoozedDue)
			and event.startMs <= now + noctalia.getConfig("reminder_minutes") * 60000
		then
			fired[key] = event.endMs
			snoozed[key] = nil
			write("reminders", fired)
			write("snoozed", snoozed)
			noctalia.state.set("reminder", event)
			noctalia.layer.show("reminder")
			break
		end
	end
end

function onResume()
	update()
end

function onIpc(event)
	if event == "join" then
		update()
		common.joinNext()
	elseif event == "dismiss" or event == "snooze" then
		noctalia.state.set("reminderAction", { kind = event, nonce = noctalia.nowMs() })
	elseif event == "refresh" then
		update()
	elseif event == "calendar" then
		common.calendar()
	end
end

function onExit()
	noctalia.layer.hide("reminder")
end
