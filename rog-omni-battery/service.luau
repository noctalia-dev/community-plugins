--!nonstrict

local snapshotKey = "battery"
local refreshKey = "refresh"
local cacheLifetime = 15 * 60
local readings = {}
local receiver
local busy = false

local function withCache(kind, device, now)
    if not device.pid then
        readings[kind] = nil
        return device
    end
    if device.level ~= nil then
        readings[kind] = { pid = device.pid, level = device.level, time = now }
        return device
    end
    local previous = readings[kind]
    if previous and previous.pid == device.pid and now >= previous.time
        and now - previous.time < cacheLifetime then
        device.level = previous.level
        device.cached = true
    else
        readings[kind] = nil
    end
    return device
end

local function publish(data)
    if data.error or receiver ~= data.receiver then
        readings = {}
        receiver = data.receiver
    end
    if not data.error then
        local now = os.time()
        data.mouse = withCache("mouse", data.mouse, now)
        data.keyboard = withCache("keyboard", data.keyboard, now)
    end
    data.receiver = nil
    noctalia.state.set(snapshotKey, data)
end

local function poll()
    if busy then
        return
    end
    if not noctalia.commandExists("python3") then
        publish({ error = "python_missing" })
        return
    end

    busy = true
    local script = noctalia.pluginDir() .. "/rog-omni-status.py"
    local started = noctalia.runAsync({ "python3", "-I", script }, function(result)
        busy = false
        local data = if result.exitCode == 0 and not result.timedOut
            then noctalia.json.decode(result.stdout) else nil
        if type(data) ~= "table" then
            publish({ error = "read_failed" })
            return
        end
        publish(data)
    end, 6000)
    if not started then
        busy = false
        publish({ error = "read_failed" })
    end
end

function update()
    poll()
end

function onIpc(event)
    if event == "refresh" then
        poll()
    end
end

noctalia.state.watch(refreshKey, poll)
noctalia.setUpdateInterval(60000)
poll()
