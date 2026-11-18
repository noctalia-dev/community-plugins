local function copy(values)
    local result = {}
    for key, value in pairs(values or {}) do
        result[key] = value
    end
    return result
end

local function trim(value)
    return value:match("^%s*(.-)%s*$") or ""
end

local function new(initialState)
    local values = copy(initialState)
    local watchers = {}
    local commands = {}
    local startResults = {}
    local updateInterval = nil
    local currentTimeMs = 0

    local state = {}

    function state.get(key)
        return values[key]
    end

    function state.set(key, value)
        values[key] = value

        for _, callback in ipairs(watchers[key] or {}) do
            callback(value)
        end
    end

    function state.watch(key, callback)
        if watchers[key] == nil then
            watchers[key] = {}
        end

        table.insert(watchers[key], callback)
    end

    local host = {
        state = state,
        string = {
            trim = trim,
        },
    }

    function host.runAsync(argv, callback, timeoutMs)
        local started = true
        if #startResults > 0 then
            started = table.remove(startResults, 1)
        end

        table.insert(commands, {
            argv = argv,
            callback = callback,
            timeoutMs = timeoutMs,
            started = started,
        })

        return started
    end

    function host.setUpdateInterval(intervalMs)
        updateInterval = intervalMs
    end

    function host.nowMs()
        return currentTimeMs
    end

    local fake = {
        host = host,
        commands = commands,
    }

    function fake.getState(key)
        return values[key]
    end

    function fake.setState(key, value)
        state.set(key, value)
    end

    function fake.queueStartResult(started)
        table.insert(startResults, started)
    end

    function fake.complete(commandIndex, result)
        local command = commands[commandIndex]
        if command == nil then
            error("No command at index " .. tostring(commandIndex), 2)
        end
        if not command.started then
            error("Cannot complete a command that failed to start", 2)
        end

        command.callback(result)
    end

    function fake.getUpdateInterval()
        return updateInterval
    end

    function fake.advanceTime(ms)
        currentTimeMs += ms
    end

    return fake
end

return {
    new = new,
}
