-- Read local OMP journals and supported-harness process state only.
local collector = noctalia.pluginDir() .. "/omp_sessions.py"
local chat_bridge = noctalia.pluginDir() .. "/chat_bridge.py"
-- Journals grow over time; give the collector the full window so a slow
-- refresh is not killed by runAsync's 5 s default timeout with empty stdout.
local collector_timeout_ms = 60000
local refreshing = false
local chat_refreshing = false
local chat_feed_revision = nil
local active_sessions = 0
local chat_busy = false
local previous_sessions = noctalia.state.get("sessions")
if type(previous_sessions) == "table" then
    active_sessions = tonumber(previous_sessions.active) or 0
end
local previous_health = noctalia.state.get("agentik.monitor_health")
local monitor_health = {
    status = "pending",
    last_attempt_ms = noctalia.nowMs(),
    stale_after_ms = 15000,
}
if type(previous_health) == "table" then
    monitor_health.last_success_ms = previous_health.last_success_ms
    monitor_health.last_success_at = previous_health.last_success_at
    monitor_health.status = previous_health.status or "pending"
    monitor_health.error = previous_health.error
end

local function publish_health(status, detail, successful)
    local next_health = {
        status = status,
        last_attempt_ms = monitor_health.last_attempt_ms,
        last_success_ms = monitor_health.last_success_ms,
        last_success_at = monitor_health.last_success_at,
        stale_after_ms = 15000,
        error = detail,
    }
    if successful then next_health.last_success_ms = noctalia.nowMs() end
    monitor_health = next_health
    noctalia.state.set("agentik.monitor_health", next_health)
end

local function collector_failure(detail)
    local message = tostring(detail or "Collector returned no result")
    message = string.gsub(message, "%c", " ")
    publish_health("error", string.sub(message, 1, 240), false)
end

local function valid_items(items, outcomes)
    if type(items) ~= "table" then return false end
    local count = 0
    for key, item in pairs(items) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0
            or type(item) ~= "table" or type(item.id) ~= "string"
            or item.id == "" or type(item.project) ~= "string"
            or type(item.state) ~= "string" or type(item.status) ~= "string"
            or (item.exited ~= nil and (type(item.exited) ~= "number" or item.exited < 0))
        then return false end
        if outcomes and (item.exited == nil or item.exited > 600
            or (item.status ~= "completed" and item.status ~= "failed" and item.status ~= "cancelled"))
        then return false end
        count = count + 1
    end
    return count == #items and (not outcomes or count <= 8)
end

publish_health(monitor_health.status, monitor_health.error, false)

local function update_cadence()
    noctalia.setUpdateInterval((active_sessions > 0 or chat_busy) and 1000 or 5000)
end

local function hex_encode(value)
    local encoded = {}
    for index = 1, #value do
        encoded[#encoded + 1] = string.format("%02x", string.byte(value, index))
    end
    return table.concat(encoded)
end

-- Bounded arithmetic stays exact in Luau; identity is independent of list order.
local SESSION_ACCENTS = { "primary", "secondary", "on_surface" }
local function session_accent(id)
    local seed = 0
    for index = 1, #id do
        seed = (seed * 31 + string.byte(id, index)) % 65521
    end
    return SESSION_ACCENTS[seed % #SESSION_ACCENTS + 1]
end

local function refresh()
    if refreshing then return end
    refreshing = true
    monitor_health.last_attempt_ms = noctalia.nowMs()
    publish_health(monitor_health.status, monitor_health.error, false)
    local excluded = tostring(noctalia.getConfig("excluded_projects") or "")
    local launched, launch_error = pcall(function()
        noctalia.runAsync(
            {"python3", collector, hex_encode(excluded)},
            function(result)
                refreshing = false
                local handled, callback_error = pcall(function()
                    if type(result) ~= "table" then
                        collector_failure("Collector returned no result")
                        return
                    end
                    if result.timedOut then
                        collector_failure("Collector timed out after 60 seconds; check journal access and size")
                        return
                    end
                    if result.error or result.exitCode ~= 0 then
                        local detail = result.error or result.stderr
                        if detail == nil or detail == "" then detail = "Check Python and journal access" end
                        collector_failure("Collector exit " .. tostring(result.exitCode) .. ": " .. tostring(detail))
                        return
                    end
                    local decoded, sessions = pcall(noctalia.json.decode, result.stdout or "")
                    if not decoded or type(sessions) ~= "table"
                        or type(sessions.active) ~= "number" or sessions.active < 0
                        or sessions.active % 1 ~= 0
                        or not valid_items(sessions.sessions, false)
                        or not valid_items(sessions.recent_outcomes, true)
                        or sessions.active > #sessions.sessions
                    then
                        collector_failure("Collector returned invalid session JSON; check omp_sessions.py output")
                        return
                    end
                    for _, items in ipairs({sessions.sessions, sessions.recent_outcomes}) do
                        for _, item in ipairs(items) do
                            item.accent = session_accent(item.id)
                        end
                    end
                    active_sessions = sessions.active
                    -- Consumers must see successful freshness before this snapshot.
                    publish_health("ok", nil, true)
                    noctalia.state.set("sessions", sessions)
                    update_cadence()
                end)
                if not handled then collector_failure("Collector callback failed: " .. tostring(callback_error)) end
            end,
            collector_timeout_ms
        )
    end)
    if not launched then
        refreshing = false
        collector_failure("Cannot launch collector: " .. tostring(launch_error))
    end
end

local function refresh_chat()
    if chat_refreshing then return end
    chat_refreshing = true
    local command = {"python3", chat_bridge, "status"}
    if type(chat_feed_revision) == "string" then
        command[#command + 1] = hex_encode(chat_feed_revision)
    end
    noctalia.runAsync(command, function(result)
        chat_refreshing = false
        local payload = noctalia.json.decode(result.stdout or "")
        chat_busy = type(payload) == "table" and payload.busy == true
        update_cadence()
        if type(payload) == "table" and type(payload.feed) == "table"
            and type(payload.feed.revision) == "string" then
            chat_feed_revision = payload.feed.revision
        end
        noctalia.state.set("agentik_chat_status", result)
    end, collector_timeout_ms)
end


function update()
    update_cadence()
    refresh()
    refresh_chat()
end

refresh()
refresh_chat()
update_cadence()
