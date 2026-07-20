-- ASUS UM5606 Fan State - headless service.
-- Owns all fan_state shell calls and runs for the whole session. The bar widget
-- is a thin client: it reads the published "status" and drives this service by
-- writing to the "command" channel.

local STATE_COUNT = 4

local fanState = -1
local available = false
local refreshPending = false
local lastStatusKey

local function publishStatus()
    local key = tostring(fanState) .. (available and "/1" or "/0")
    if key == lastStatusKey then return end
    lastStatusKey = key
    noctalia.state.set("status", { state = fanState, available = available })
end

local function setState(state)
    if fanState == state then return end
    fanState = state
end

local function parseFanState(stdout)
    return tonumber((stdout or ""):match("^%s*(.-)%s*$"))
end

local function refreshFanState()
    if refreshPending then return end

    refreshPending = true
    local ok = noctalia.runAsync("fan_state get --int", function(result)
        refreshPending = false

        if result.exitCode ~= 0 then
            available = false
            noctalia.log("fan_control: failed to get fan state")
            publishStatus()
            return
        end

        local parsed = parseFanState(result.stdout)
        if parsed == nil then
            available = false
            noctalia.log("fan_control: failed to parse fan state")
            publishStatus()
            return
        end

        available = true
        setState(parsed)
        publishStatus()
    end)

    if not ok then
        refreshPending = false
        available = false
        noctalia.log("fan_control: failed to start fan state command")
        publishStatus()
    end
end

local function setFanState(nextState)
    if type(nextState) ~= "number" then return end
    if nextState < 0 or nextState >= STATE_COUNT then return end

    available = true
    setState(nextState)
    publishStatus()

    local ok = noctalia.runAsync("fan_state set " .. tostring(nextState), function(result)
        if result.exitCode ~= 0 then
            noctalia.log("fan_control: failed to set fan state")
        end
        refreshFanState()
    end)

    if not ok then
        noctalia.log("fan_control: failed to start fan state command")
        refreshFanState()
    end
end

local function cycleFanState()
    if not available then
        refreshFanState()
        return
    end

    setFanState((fanState + 1) % STATE_COUNT)
end

local function handleCommand(command)
    local action = command
    local state = nil

    if type(command) == "table" then
        action = command.action
        state = tonumber(command.state)
    end

    if action == "cycle" then
        cycleFanState()
    elseif action == "refresh" then
        refreshFanState()
    elseif action == "set" then
        setFanState(state)
    elseif type(action) == "string" then
        local parsed = tonumber(action:match("^set%s+([0-3])$"))
        if parsed ~= nil then
            setFanState(parsed)
        else
            noctalia.log("fan_control: unknown command '" .. tostring(action) .. "'")
        end
    end
end

local pollInterval = tonumber(noctalia.getConfig("poll_interval")) or 2000
noctalia.setUpdateInterval(pollInterval)

publishStatus()
refreshFanState()

function update()
    refreshFanState()
end

noctalia.state.watch("command", handleCommand)
