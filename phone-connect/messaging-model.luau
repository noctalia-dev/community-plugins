--!nonstrict
-- Pure state and lookup helpers shared by the service, panel and tests.
-- This module performs no I/O. reduce mutates one device's session state.
local MessageModel = {}

-- Maps use string IDs from bridge.py. Threads contain the latest message;
-- messages[threadId][messageId] contains only history fetched in this session.
function MessageModel.device()
	return {
		connected = false,
		capabilities = {},
		contacts = {},
		threads = {},
		messages = {},
		notifications = {},
		calls = {},
		history = {},
		status = { messages = "loading", contacts = "loading", notifications = "loading" },
		error = "",
	}
end

-- Ignore presentation punctuation, but never infer a country code or suffix match.
function MessageModel.number(value)
	return tostring(value or ""):gsub("^tel:", ""):gsub("[%s%(%)%.%-]", ""):lower()
end

-- Ambiguous matches retain the number instead of selecting an arbitrary person.
function MessageModel.name(contacts, number)
	local normalized = MessageModel.number(number)
	local found
	for _, contact in ipairs(contacts or {}) do
		for _, candidate in ipairs(contact.numbers or {}) do
			if normalized ~= "" and MessageModel.number(candidate) == normalized then
				if found and found ~= contact.name then
					return number
				end
				found = contact.name
			end
		end
	end
	return found or number
end

-- Build the contact-name index lazily and reuse it across conversation rows.
-- A contacts event invalidates the index, including ambiguous-number entries.
function MessageModel.title(deviceState, message)
	if not deviceState.contactNames then
		deviceState.contactNames = {}
		for _, contact in ipairs(deviceState.contacts or {}) do
			for _, number in ipairs(contact.numbers or {}) do
				local key = MessageModel.number(number)
				local old = deviceState.contactNames[key]
				if old == nil then
					deviceState.contactNames[key] = contact.name
				elseif old ~= contact.name then
					deviceState.contactNames[key] = false
				end
			end
		end
	end
	local names = {}
	for _, number in ipairs(message.addresses or {}) do
		table.insert(names, deviceState.contactNames[MessageModel.number(number)] or number)
	end
	return table.concat(names, ", ")
end

-- Return a new date-ordered array without changing the ID-keyed source map.
function MessageModel.sorted(map, ascending)
	local items = {}
	for _, item in pairs(map or {}) do
		table.insert(items, item)
	end
	table.sort(items, function(a, b)
		if a.date == b.date then
			return tostring(a.id) < tostring(b.id)
		end
		if ascending then
			return (a.date or 0) < (b.date or 0)
		end
		return (a.date or 0) > (b.date or 0)
	end)
	return items
end

-- Merge snapshots and signals by identity. Older history must not replace a
-- newer thread preview; disconnects retain cached content until reconnection.
function MessageModel.reduce(deviceState, event)
	local kind = event.type
	if kind == "connection" then
		deviceState.connected = event.connected == true
	elseif kind == "capabilities" then
		if not deviceState.connected then
			-- A reloaded KDE plugin has a new history cache; old offsets are invalid.
			deviceState.messages = {}
			deviceState.history = {}
			deviceState.threads = {}
		end
		deviceState.connected = event.connected == true
		deviceState.capabilities = event.capabilities or {}
		deviceState.error = ""
		for _, key in ipairs({ "messages", "contacts", "notifications" }) do
			if not deviceState.capabilities[key] then
				deviceState.status[key] = "unsupported"
			end
		end
	elseif kind == "contacts" then
		deviceState.contacts = event.items or {}
		deviceState.contactNames = nil
		deviceState.status.contacts = #deviceState.contacts > 0 and "ready" or "empty"
	elseif kind == "threads" then
		-- Signals can overtake a snapshot subprocess. Merge instead of erasing a
		-- newly arrived thread; removals have their own signal. Reconnect starts fresh.
		local threads = deviceState.threads
		for _, message in ipairs(event.items or {}) do
			local old = deviceState.threads[message.thread]
			threads[message.thread] = old and old.date > message.date and old or message
		end
		deviceState.threads = threads
		deviceState.status.messages = next(threads) and "ready" or "empty"
	elseif kind == "message" then
		local message = event.message
		if not message or not message.thread or not message.id then
			return
		end
		local id = message.thread
		deviceState.messages[id] = deviceState.messages[id] or {}
		deviceState.messages[id][message.id] = message
		local latest = deviceState.threads[id]
		if not latest or message.date >= latest.date then
			deviceState.threads[id] = message
		end
		deviceState.status.messages = "ready"
	elseif kind == "thread_removed" then
		deviceState.threads[event.thread] = nil
		deviceState.messages[event.thread] = nil
		deviceState.history[event.thread] = nil
		deviceState.status.messages = next(deviceState.threads) and "ready" or "empty"
	elseif kind == "loaded" then
		local history = deviceState.history[event.thread] or {}
		history.knownCount = event.count
		deviceState.history[event.thread] = history
	elseif kind == "notifications" then
		deviceState.notifications = {}
		for _, item in ipairs(event.items or {}) do
			deviceState.notifications[item.id] = item
		end
		deviceState.status.notifications = next(deviceState.notifications) and "ready" or "empty"
	elseif kind == "notification" then
		deviceState.notifications[event.notification.id] = event.notification
		deviceState.status.notifications = "ready"
	elseif kind == "notification_removed" then
		deviceState.notifications[event.id] = nil
		deviceState.status.notifications = next(deviceState.notifications) and "ready" or "empty"
	elseif kind == "call" then
		table.insert(deviceState.calls, 1, event.call)
		if #deviceState.calls > 20 then
			table.remove(deviceState.calls)
		end
	elseif kind == "error" then
		deviceState.error = event.message or ""
	end
end

-- Search contact names, recipients, previews and fetched history only.
-- Searching never requests additional messages from the phone.
function MessageModel.matches(deviceState, thread, query)
	query = (query or ""):lower()
	if query == "" then
		return true
	end
	local haystack = MessageModel.title(deviceState, thread)
		.. " "
		.. table.concat(thread.addresses or {}, " ")
		.. " "
		.. (thread.body or "")
	if haystack:lower():find(query, 1, true) then
		return true
	end
	for _, message in pairs(deviceState.messages[thread.thread] or {}) do
		if (message.body or ""):lower():find(query, 1, true) then
			return true
		end
	end
	return false
end

return MessageModel
