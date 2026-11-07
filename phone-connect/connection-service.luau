--!nonstrict
-- Phone health is separate from KDE Connect's local link and SMS outcomes.
-- Only status reads and rediscovery are automatic; message commands never enter
-- this module. One global reconnect covers all paired devices.
local ConnectionService = {}
local CHECK_INTERVAL = 30
local REQUEST_TIMEOUT_MS = 15000
local RETRY_MIN, RETRY_MAX = 30, 300

function ConnectionService.start(api, options)
	local health = {}
	local reconnectRequest
	local nextReconnect = 0
	local helperPath = api.pluginDir() .. "/bridge.py"
	local function now()
		return os.time()
	end
	local function setStatus(device, status)
		if device.connectionStatus ~= status then
			device.connectionStatus = status
			options.publish()
		end
	end
	local function entryFor(id)
		if not health[id] then
			health[id] = { failures = 0, nextCheck = 0, nextRetry = 0, delay = RETRY_MIN }
		end
		return health[id]
	end
	local function decode(result)
		if not result or result.exitCode ~= 0 then
			return nil
		end
		local ok, reply = pcall(api.json.decode, result.stdout or "")
		return ok and type(reply) == "table" and reply.ok and reply or nil
	end

	-- The CLI return is not a phone acknowledgement. Keep recovery status until
	-- a subsequent phone check succeeds. Ignore callbacks from expired attempts.
	local function reconnect(id, manual)
		if reconnectRequest or (not manual and now() < nextReconnect) then
			return false
		end
		local entry = id and entryFor(id)
		if not manual and entry and now() < entry.nextRetry then
			return false
		end
		local request = { deadline = now() + REQUEST_TIMEOUT_MS / 1000 }
		reconnectRequest = request
		nextReconnect = now() + RETRY_MIN
		if entry then
			entry.check = nil
			entry.nextRetry = now() + entry.delay
			entry.delay = math.min(RETRY_MAX, entry.delay * 2)
			entry.nextCheck = now() + CHECK_INTERVAL
			entry.recovering = true
			local device = options.devices()[id]
			if device then
				setStatus(device, "reconnecting")
			end
		end
		local launched = api.runAsync({ "kdeconnect-cli", "--refresh" }, function()
			if reconnectRequest ~= request then
				return
			end
			reconnectRequest = nil
			if not manual and api.getConfig("auto_reconnect") == false then
				return
			end
			options.refresh()
			if id then
				if health[id] == entry then
					entry.nextCheck = 0
				end
				options.sync(id)
			end
		end, REQUEST_TIMEOUT_MS)
		if not launched then
			reconnectRequest = nil
		end
		return launched
	end

	local function checked(id, device, entry, result)
		entry.check = nil
		entry.nextCheck = now() + CHECK_INTERVAL
		if result and result.supported == false then
			-- Do not interpret a disabled media plugin as an unresponsive phone.
			entry.nextCheck = now() + RETRY_MAX
			setStatus(device, "reported")
			if entry.needsSync then
				entry.needsSync = false
				options.sync(id)
			end
		elseif result and result.responding == true then
			local recovered = entry.recovering
			entry.failures, entry.delay, entry.nextRetry, entry.recovering = 0, RETRY_MIN, 0, false
			setStatus(device, "connected")
			if recovered or entry.needsSync then
				entry.needsSync = false
				options.sync(id)
			end
		else
			entry.failures = entry.failures + 1
			setStatus(device, entry.failures >= 2 and "reconnecting" or "checking")
			if entry.failures >= 2 then
				reconnect(id, false)
			end
		end
	end

	local function check(id, device, entry)
		local request = { deadline = now() + REQUEST_TIMEOUT_MS / 1000 }
		entry.check = request
		if
			not entry.recovering
			and entry.failures == 0
			and device.connectionStatus ~= "connected"
		then
			setStatus(device, "checking")
		end
		local launched = api.runAsync({
			"python3",
			helperPath,
			"request",
			api.json.encode({ op = "connection_check", device = id }),
		}, function(processResult)
			if
				health[id] ~= entry
				or entry.check ~= request
				or options.devices()[id] ~= device
				or api.getConfig("auto_reconnect") == false
				or not device.isPaired
			then
				return
			end
			if now() >= request.deadline then
				checked(id, device, entry, nil)
				return
			end
			local reply = decode(processResult)
			local result
			for _, event in ipairs((reply and reply.events) or {}) do
				if event.type == "health" and event.device == id then
					result = event
				end
			end
			checked(id, device, entry, result)
		end, REQUEST_TIMEOUT_MS)
		if not launched then
			checked(id, device, entry, nil)
		end
	end

	return {
		refresh = function(id)
			reconnect(id, true)
		end,
		suspect = function(id)
			local entry = entryFor(id)
			entry.nextCheck = 0
			entry.needsSync = true
		end,
		tick = function()
			local devices = options.devices()
			if reconnectRequest and now() >= reconnectRequest.deadline then
				reconnectRequest = nil
			end
			for id in pairs(health) do
				if not devices[id] or not devices[id].isPaired then
					health[id] = nil
				end
			end
			for id, device in pairs(devices) do
				if api.getConfig("auto_reconnect") == false or not device.isPaired then
					health[id] = nil
					setStatus(device, nil)
				else
					local entry = entryFor(id)
					if not device.isReachable then
						entry.check = nil
						entry.nextCheck = 0
						entry.recovering = true
						setStatus(device, "reconnecting")
						reconnect(id, false)
					elseif options.bridgeReady() then
						if entry.check and now() >= entry.check.deadline then
							checked(id, device, entry, nil)
						elseif not entry.check and now() >= entry.nextCheck then
							check(id, device, entry)
						end
					else
						entry.check = nil
						setStatus(device, entry.recovering and "reconnecting" or "reported")
					end
				end
			end
		end,
	}
end

return ConnectionService
