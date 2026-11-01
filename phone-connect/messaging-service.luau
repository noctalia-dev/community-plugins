--!nonstrict
-- Owns messaging state and the Python helper lifecycle. UI entries submit
-- commands through service.luau and observe the published pc.messaging snapshot.
local Model = require("./messaging-model.luau")
local MessagingService = {}

local HISTORY_PAGE_SIZE = 50
local REQUEST_TIMEOUT_MS = 15000
local SYNC_TIMEOUT_SECONDS = 12
local DEFERRED_REQUEST_TIMEOUT_SECONDS = 15
local WATCHDOG_TIMEOUT_SECONDS = 35

-- Start one watcher per service. The caller must invoke tick once per second.
-- All tables below are session state; none are persisted to plugin storage.
function MessagingService.start(api)
	local devices = {}
	local pending = {}
	local results = {}
	local deferredRequests = {}

	-- A daemon reset invalidates every request. A device epoch invalidates only
	-- requests for that phone; both are checked when asynchronous replies arrive.
	local generation = 0
	local lastHeartbeat = 0
	local watcherStarting = false
	local watcherReady = false
	local command -- Forward declaration: ready events release deferred commands.

	local bridgeError = ""
	local bridgeStatus = "starting"
	local snapshotDirty = false
	local snapshotChunks = {}
	local snapshotChunkCount = 0
	local helperPath = api.pluginDir() .. "/bridge.py"

	local function now()
		return os.time()
	end

	-- Commands publish immediately; incoming signals share one publication per tick.
	local function publish()
		snapshotDirty = false
		api.state.set("pc.messaging", {
			devices = devices,
			pending = pending,
			results = results,
			error = bridgeError,
			bridgeStatus = bridgeStatus,
		})
	end

	local function deviceFor(id)
		if not devices[id] then
			devices[id] = Model.device()
		end
		return devices[id]
	end

	-- Reduce a typed helper event without writing personal data to logs or disk.
	local function applyEvent(bridgeEvent)
		if type(bridgeEvent) ~= "table" then
			return
		end
		lastHeartbeat = now()
		if bridgeEvent.type == "heartbeat" then
			return
		end
		if bridgeEvent.type == "ready" then
			bridgeError = ""
			bridgeStatus = "ready"
			watcherReady = true
			local waiting = deferredRequests
			deferredRequests = {}
			for target, item in pairs(waiting) do
				pending[target] = nil
				command(item.cmd)
			end
		elseif bridgeEvent.type == "reset" then
			bridgeStatus = "starting"
			watcherReady = false
			generation = generation + 1
			for _, deviceState in pairs(devices) do
				deviceState.connected = false
			end
		elseif bridgeEvent.type == "removed" then
			devices[bridgeEvent.device] = nil
		elseif bridgeEvent.device then
			local deviceState = deviceFor(bridgeEvent.device)
			if
				bridgeEvent.type == "notification"
				or bridgeEvent.type == "notification_removed"
				or bridgeEvent.type == "notifications"
			then
				deviceState.notificationRevision = (deviceState.notificationRevision or 0) + 1
			end
			if bridgeEvent.type == "connection" and not bridgeEvent.connected then
				deviceState.epoch = (deviceState.epoch or 0) + 1
			end
			Model.reduce(deviceState, bridgeEvent)
			if bridgeEvent.type == "message" then
				local thread = bridgeEvent.message.thread
				local history = deviceState.history[thread]
				if
					history
					and history.loading
					and #Model.sorted(deviceState.messages[thread])
						>= (history.start or 0) + HISTORY_PAGE_SIZE
				then
					history.loading = false
					history.incomplete = false
				end
			end
		elseif bridgeEvent.type == "error" then
			bridgeError = bridgeEvent.message or "Bridge failed"
		end
		-- Conversation sync can emit hundreds of signals. Publish their latest
		-- combined state on the service tick, rather than serializing and making
		-- every panel decode the entire history once per message. Commands still
		-- publish pending/results immediately so sends cannot be duplicated.
		snapshotDirty = true
	end

	local function decodeObject(raw)
		local ok, value = pcall(api.json.decode, raw or "")
		if ok and type(value) == "table" then
			return value
		end
		return nil
	end

	-- Stream frames arrive in order. Apply a large snapshot only after every
	-- fragment is present; a new first fragment replaces an incomplete frame.
	local function receiveStreamLine(line)
		local bridgeEvent = decodeObject(line)
		if bridgeEvent and bridgeEvent.type == "chunk" then
			if bridgeEvent.index == 1 then
				snapshotChunks = {}
				snapshotChunkCount = bridgeEvent.count
			end
			if
				bridgeEvent.index ~= #snapshotChunks + 1
				or bridgeEvent.count ~= snapshotChunkCount
				or type(bridgeEvent.data) ~= "string"
			then
				snapshotChunks = {}
				snapshotChunkCount = 0
				return
			end
			table.insert(snapshotChunks, bridgeEvent.data)
			if #snapshotChunks < snapshotChunkCount then
				return
			end
			bridgeEvent = decodeObject(table.concat(snapshotChunks))
			snapshotChunks = {}
			snapshotChunkCount = 0
		end
		if bridgeEvent then
			applyEvent(bridgeEvent)
		end
	end

	-- Start the long-running signal subscription after checking Python/Gio.
	-- No history command is released until the helper announces ready.
	local function startWatcher()
		if watcherStarting then
			return
		end
		watcherStarting = true
		watcherReady = false
		bridgeStatus = "starting"
		snapshotChunks = {}
		snapshotChunkCount = 0
		local launched = api.runAsync({ "python3", helperPath, "check" }, function(processResult)
			watcherStarting = false
			local result = decodeObject(processResult and processResult.stdout)
			if not processResult or processResult.exitCode ~= 0 or not result or not result.ok then
				bridgeStatus = "unavailable"
				bridgeError = result and result.message
					or "Install Python 3 and PyGObject to use messages and notifications."
				lastHeartbeat = now()
				publish()
				return
			end
			local quoted = "'" .. helperPath:gsub("'", "'\\''") .. "'"
			local ok = api.runStream("exec python3 -u " .. quoted .. " watch", receiveStreamLine)
			if not ok then
				bridgeStatus = "unavailable"
				bridgeError = "Could not start the KDE Connect bridge"
			end
			lastHeartbeat = now()
			publish()
		end)
		if not launched then
			watcherStarting = false
			bridgeStatus = "unavailable"
			lastHeartbeat = now()
			bridgeError = "Install Python 3 and PyGObject to use messages and notifications."
			publish()
		end
	end

	-- Acceptance clears only the exact text submitted. Text edited while a
	-- request is running, and all failed/uncertain sends, retain their drafts.
	local function finishRequest(target, command, ok, message)
		pending[target] = nil
		results[target] = { ok = ok, message = message, requestId = command.requestId }
		if ok and (command.op == "sms_send" or command.op == "notification_reply") then
			local drafts = api.state.get("pc.drafts") or {}
			local draft = drafts[target]
			if draft and draft.text == command.text then
				draft.text = ""
				draft.rev = (draft.rev or 0) + 1
				api.state.set("pc.drafts", drafts)
			end
		end
		publish()
	end

	-- One request per target may be pending. Capture connection identity before
	-- starting the process so a late reply cannot modify a reconnected device.
	command = function(cmd)
		local id = cmd.device
		if not id or id == "" then
			return
		end
		local deviceState = deviceFor(id)
		local target = cmd.target or (id .. ":" .. cmd.op)
		if pending[target] then
			return
		end
		cmd.requestId = cmd.requestId or tostring(api.nowMs())
		-- A missing helper is local to the enhanced tabs. Fail commands promptly
		-- without starting another process or changing any retained draft.
		if bridgeStatus == "unavailable" then
			finishRequest(target, cmd, false, bridgeError)
			return
		end
		pending[target] = { requestId = cmd.requestId, since = now() }
		results[target] = nil
		-- The watcher announces ready only after subscribing. A panel can open
		-- while the helper is starting, so defer reads that depend on its signals.
		if
			not watcherReady
			and (cmd.op == "history" or cmd.op == "sync" or cmd.op == "contacts_sync")
		then
			deferredRequests[target] =
				{ cmd = cmd, deadline = now() + DEFERRED_REQUEST_TIMEOUT_SECONDS }
			publish()
			return
		end
		if cmd.op == "sync" then
			deviceState.status.messages = "loading"
			deviceState.syncDeadline = now() + SYNC_TIMEOUT_SECONDS
		end
		if cmd.op == "contacts_sync" then
			deviceState.status.contacts = "loading"
			deviceState.contactsDeadline = now() + SYNC_TIMEOUT_SECONDS
		end
		if cmd.op == "history" then
			local history = deviceState.history[cmd.thread] or {}
			history.loading = true
			history.deadline = now() + SYNC_TIMEOUT_SECONDS
			history.start = cmd.start or 0
			history.error = nil
			deviceState.history[cmd.thread] = history
		end
		publish()
		local requestDeviceEpoch, requestGeneration, notificationRevision =
			deviceState.epoch or 0, generation, deviceState.notificationRevision or 0
		local launched = api.runAsync(
			{ "python3", helperPath, "request", api.json.encode(cmd) },
			function(processResult)
				if
					generation ~= requestGeneration
					or (deviceState.epoch or 0) ~= requestDeviceEpoch
					or devices[id] ~= deviceState
				then
					finishRequest(
						target,
						cmd,
						false,
						"Connection changed; check the phone before retrying."
					)
					return
				end
				local reply = decodeObject(processResult and processResult.stdout)
				local ok = processResult
					and processResult.exitCode == 0
					and reply
					and reply.ok == true
				if ok then
					for _, bridgeEvent in ipairs(reply.events or {}) do
						-- A notification can be dismissed while a snapshot is in flight.
						if
							bridgeEvent.type ~= "notifications"
							or (deviceState.notificationRevision or 0) == notificationRevision
						then
							applyEvent(bridgeEvent)
						end
					end
					if
						cmd.op == "sync"
						and deviceState.capabilities.messages
						and not next(deviceState.threads)
					then
						deviceState.status.messages = "loading"
					end
				else
					if cmd.op == "sync" then
						deviceState.status.messages = "failed"
						deviceState.syncDeadline = nil
					end
					if cmd.op == "contacts_sync" then
						deviceState.status.contacts = "failed"
						deviceState.contactsDeadline = nil
					end
					if cmd.op == "history" then
						deviceState.history[cmd.thread].loading = false
						deviceState.history[cmd.thread].error = true
					end
				end
				finishRequest(
					target,
					cmd,
					ok == true,
					ok and "accepted"
						or (
							reply and reply.message
							or "Request timed out or failed; check the phone before retrying."
						)
				)
			end,
			REQUEST_TIMEOUT_MS
		)
		if not launched then
			finishRequest(target, cmd, false, "Could not start Python 3")
		end
	end

	-- Expire loading indicators, flush signal batches, and recover a dead helper.
	local function tick()
		local changed = false
		for target, item in pairs(deferredRequests) do
			if now() >= item.deadline then
				deferredRequests[target] = nil
				finishRequest(
					target,
					item.cmd,
					false,
					"KDE Connect bridge is not ready. Refresh after it reconnects."
				)
			end
		end
		for _, deviceState in pairs(devices) do
			for _, pair in ipairs({
				{ "syncDeadline", "messages" },
				{ "contactsDeadline", "contacts" },
			}) do
				if deviceState[pair[1]] and now() >= deviceState[pair[1]] then
					deviceState[pair[1]] = nil
					if deviceState.status[pair[2]] == "loading" then
						deviceState.status[pair[2]] = "empty"
					end
					changed = true
				end
			end
			for thread, history in pairs(deviceState.history) do
				if history.loading and now() >= history.deadline then
					history.loading = false
					local count = #Model.sorted(deviceState.messages[thread])
					history.loaded = count
					-- A short page may be a slow phone, so keep Load older available.
					history.incomplete = count < (history.start or 0) + HISTORY_PAGE_SIZE
					changed = true
				end
			end
		end
		if changed or snapshotDirty then
			publish()
		end
		if now() - lastHeartbeat > WATCHDOG_TIMEOUT_SECONDS and not watcherStarting then
			lastHeartbeat = now()
			api.processMatches(function(running)
				if not running then
					startWatcher()
				end
			end, helperPath, "watch")
		end
	end

	startWatcher()
	return { command = command, tick = tick }
end

return MessagingService
