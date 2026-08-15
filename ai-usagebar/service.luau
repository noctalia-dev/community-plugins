--!nonstrict
-- Headless poller: the single owner of `ai-usagebar usage --json`.
--
-- One call returns every configured vendor, so the capsules and the panel are
-- pure subscribers of noctalia.state and never spawn a process of their own.

local function shellQuote(value)
    return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function command()
    local configured = tostring(noctalia.getConfig("binPath") or "ai-usagebar")
    if string.sub(configured, 1, 1) == "~" then
        configured = noctalia.expandPath(configured)
    end
    return shellQuote(configured) .. " usage --json"
end

local function intervalMs()
    local minutes = tonumber(noctalia.getConfig("refreshMinutes")) or 5
    if minutes < 1 then minutes = 1 end
    return math.floor(minutes * 60 * 1000)
end

local inFlight = false

local function refresh()
    if inFlight then return end
    inFlight = true
    noctalia.state.set("polling", true)

    noctalia.runAsync(command(), function(result)
        inFlight = false
        noctalia.state.set("polling", false)

        local decoded = result ~= nil and noctalia.json.decode(result.stdout or "") or nil
        if type(decoded) == "table" and type(decoded.entries) == "table" then
            -- A vendor that failed still comes back as an entry with `status =
            -- "error"`, so a non-zero exit is not a reason to drop the report.
            noctalia.state.set("report", decoded)
            noctalia.state.set("error", "")
            noctalia.state.set("polledAt", os.time())
            return
        end

        local message = "ai-usagebar returned no usage data"
        if result == nil then
            message = "could not run ai-usagebar"
        elseif result.timedOut then
            message = "ai-usagebar timed out"
        elseif result.exitCode ~= 0 then
            local stderr = noctalia.string.trim(result.stderr or "")
            message = stderr ~= "" and stderr or ("ai-usagebar exited with code " .. tostring(result.exitCode))
        end
        noctalia.state.set("error", message)
        noctalia.state.set("polledAt", os.time())
    end, 30000)
end

-- Manual refresh from a capsule or the panel.
noctalia.state.watch("command", function(value)
    if type(value) == "table" and value.action == "refresh" then refresh() end
end)

function update()
    noctalia.setUpdateInterval(intervalMs())
    refresh()
end

function onConfigChanged()
    noctalia.setUpdateInterval(intervalMs())
    refresh()
end

function onIpc(event, _payload)
    if event == "refresh" then refresh() end
end

noctalia.setUpdateInterval(intervalMs())
refresh()
