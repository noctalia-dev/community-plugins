--!nonstrict
local common = require("./common.luau")
local model = common.model
local bookmarks, fired = {}, {}
local dataDir = noctalia.pluginDataDir()
local snoozed, pending = {}, {}

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
pending = read("pending") or {}
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

local function eligible(event, now)
	return type(event.startMs) == "number"
		and type(event.endMs) == "number"
		and event.endMs >= event.startMs
		and not event.allDay
		and event.endMs > now
		and model.service(event.url) ~= nil
end

function update()
	local now = noctalia.nowMs()
	-- One native snapshot read per tick for all monitors and UI entries.
	local events = noctalia.calendarEvents()
	noctalia.state.set("snapshot", { ready = events ~= nil, events = events or {}, readAt = now })
	local enabled = noctalia.getConfig("fullscreen_reminders")
	local active = noctalia.state.get("reminder")
	local firedChanged = false
	for key, endMs in pairs(fired) do
		if type(endMs) ~= "number" or endMs < now - 86400000 then
			fired[key] = nil
			firedChanged = true
		end
	end
	if firedChanged then
		write("reminders", fired)
	end
	-- An unavailable snapshot is not evidence that a snoozed or queued event was removed.
	if events == nil then
		if active and (not enabled or not eligible(active, now)) then
			noctalia.layer.hide("reminder")
			noctalia.state.set("reminder", nil)
		end
		return
	end

	local rawEligible, filteredEligible = {}, {}
	for _, event in ipairs(events) do
		if eligible(event, now) then
			rawEligible[model.key(event)] = event
		end
	end
	local filtered = common.events(now) or {}
	for _, event in ipairs(filtered) do
		if eligible(event, now) then
			filteredEligible[model.key(event)] = event
		end
	end
	local snoozedChanged, pendingChanged = false, false
	for key, wakeAt in pairs(snoozed) do
		if type(wakeAt) ~= "number" or not rawEligible[key] then
			snoozed[key] = nil
			snoozedChanged = true
		end
	end
	for key, endMs in pairs(pending) do
		if type(endMs) ~= "number" or not enabled or not filteredEligible[key] or fired[key] then
			pending[key] = nil
			pendingChanged = true
		end
	end

	if active then
		local refreshed = enabled and filteredEligible[model.key(active)] or nil
		if refreshed then
			noctalia.state.set("reminder", refreshed)
		else
			noctalia.layer.hide("reminder")
			noctalia.state.set("reminder", nil)
		end
	end
	if enabled then
		-- Register every due meeting before checking whether another overlay is open.
		-- Queued meetings remain eligible after start, but newly discovered late events do not.
		for _, event in ipairs(filtered) do
			local key = model.key(event)
			local wakeAt = snoozed[key]
			local snoozedDue = type(wakeAt) == "number" and wakeAt <= now
			if
				filteredEligible[key]
				and not fired[key]
				and (wakeAt == nil or snoozedDue)
				and (event.startMs >= now - 60000 or snoozedDue)
				and event.startMs <= now + noctalia.getConfig("reminder_minutes") * 60000
				and pending[key] ~= event.endMs
			then
				pending[key] = event.endMs
				pendingChanged = true
			end
		end
	end
	local nextReminder
	if enabled and not noctalia.state.get("reminder") then
		for _, event in ipairs(filtered) do
			local key = model.key(event)
			if pending[key] and event.startMs <= now + noctalia.getConfig("reminder_minutes") * 60000 then
				nextReminder = event
				pending[key] = nil
				pendingChanged = true
				fired[key] = event.endMs
				snoozed[key] = nil
				snoozedChanged = true
				write("reminders", fired)
				break
			end
		end
	end
	if snoozedChanged then
		write("snoozed", snoozed)
	end
	if pendingChanged then
		write("pending", pending)
	end
	if nextReminder then
		noctalia.state.set("reminder", nextReminder)
		noctalia.layer.show("reminder")
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
