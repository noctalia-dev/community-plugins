local directory = arg[1] or "phone-connect"
local clock, enabled, ready = 100, true, true
local calls, tokens, syncs = {}, {}, {}
local refreshes, publications = 0, 0
local devices = { a = { id = "a", isPaired = true, isReachable = true } }
local api = {
	pluginDir = function()
		return directory
	end,
	getConfig = function()
		return enabled
	end,
	json = {
		encode = function(value)
			table.insert(tokens, value)
			return tostring(#tokens)
		end,
		decode = function(raw)
			return tokens[tonumber(raw)]
		end,
	},
	runAsync = function(argv, callback)
		table.insert(calls, { argv = argv, callback = callback })
		return true
	end,
}
local env = setmetatable({ os = {
	time = function()
		return clock
	end,
} }, { __index = _G })
local monitor = assert(loadfile(directory .. "/connection-service.luau", "t", env))().start(api, {
	devices = function()
		return devices
	end,
	publish = function()
		publications = publications + 1
	end,
	bridgeReady = function()
		return ready
	end,
	refresh = function()
		refreshes = refreshes + 1
	end,
	sync = function(id)
		table.insert(syncs, id)
	end,
})
local function reply(call, responding, supported)
	call.callback({
		exitCode = 0,
		stdout = api.json.encode({
			ok = true,
			events = {
				{
					type = "health",
					device = "a",
					responding = responding,
					supported = supported ~= false,
				},
			},
		}),
	})
end
local function take()
	return assert(table.remove(calls, 1), "Expected one queued action")
end
local function isProbe(call)
	assert(call.argv[1] == "python3")
	local command = api.json.decode(call.argv[4])
	assert(command.op == "connection_check" and command.device == "a")
end
local function isReconnect(call)
	assert(#call.argv == 2 and call.argv[1] == "kdeconnect-cli" and call.argv[2] == "--refresh")
end

monitor.tick()
local probe = take()
isProbe(probe)
assert(devices.a.connectionStatus == "checking")
monitor.tick()
assert(#calls == 0, "Do not overlap probes")
reply(probe, true)
assert(devices.a.connectionStatus == "connected" and refreshes == 0)
for _ = 1, 3 do
	clock = clock + 30
	monitor.tick()
	probe = take()
	isProbe(probe)
	reply(probe, true)
end
assert(refreshes == 0 and #calls == 0, "A quiet, responding phone must not be reconnected")

-- An uncertain SMS prompts a fresh health check and data sync, never a resend.
monitor.suspect("a")
monitor.tick()
probe = take()
reply(probe, true)
assert(#syncs == 1 and syncs[1] == "a" and refreshes == 0)

clock = clock + 30
monitor.tick()
reply(take(), false)
assert(
	#calls == 0 and devices.a.connectionStatus == "checking",
	"One missed reply is not enough to reconnect"
)
clock = clock + 30
monitor.tick()
reply(take(), false)
local reconnect = take()
isReconnect(reconnect)
assert(devices.a.connectionStatus == "reconnecting")
devices.b = { id = "b", isPaired = true, isReachable = false }
monitor.tick()
assert(#calls == 0, "A reconnect already in flight must be coalesced")
devices.b = nil
reconnect.callback({ exitCode = 0 })
assert(
	refreshes == 1 and devices.a.connectionStatus == "reconnecting",
	"CLI success is not a phone acknowledgement"
)
monitor.tick()
reply(take(), true)
assert(devices.a.connectionStatus == "connected")

-- Repeated offline failures back off, with one global discovery request.
devices.a.isReachable = false
clock = clock + 30
monitor.tick()
reconnect = take()
isReconnect(reconnect)
reconnect.callback({ exitCode = 0 })
clock = clock + 29
monitor.tick()
assert(#calls == 0)
clock = clock + 1
monitor.tick()
reconnect = take()
isReconnect(reconnect)
reconnect.callback({ exitCode = 0 })
clock = clock + 30
monitor.tick()
assert(#calls == 0, "Second retry should wait 60 seconds")
clock = clock + 30
monitor.tick()
reconnect = take()
isReconnect(reconnect)
-- A lost CLI callback cannot lock recovery forever, or refresh data later.
clock = clock + 16
monitor.tick()
local before = refreshes
reconnect.callback({ exitCode = 0 })
assert(refreshes == before, "Expired reconnect callbacks must be ignored")

enabled = false
monitor.tick()
clock = clock + 1000
monitor.tick()
assert(
	#calls == 0 and devices.a.connectionStatus == nil,
	"Disabling recovery must stop automatic actions"
)

enabled, devices.a.isReachable = true, true
monitor.tick()
probe = take()
isProbe(probe)
clock = clock + 16
monitor.tick()
reply(probe, true)
assert(devices.a.connectionStatus == "checking", "An expired probe cannot restore Connected")
clock = clock + 30
monitor.tick()
probe = take()
enabled = false
monitor.tick()
reply(probe, true)
assert(devices.a.connectionStatus == nil, "A disabled monitor must ignore a late check")

enabled = true
monitor.tick()
reply(take(), nil, false)
assert(devices.a.connectionStatus == "reported", "Unsupported probes must not imply disconnection")
clock = clock + 30
monitor.tick()
assert(#calls == 0, "A disabled media plugin must not cause repeated reconnection")

-- Unpaired devices and missing helpers are excluded from automatic probes.
devices.a.isPaired = false
clock = clock + 300
monitor.tick()
assert(#calls == 0)
devices.a.isPaired, ready = true, false
monitor.tick()
assert(#calls == 0)
assert(publications > 0)
print("Connection health and automatic recovery regressions passed")
