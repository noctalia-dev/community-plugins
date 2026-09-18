-- Read local OMP journals and supported-harness process state only.
local collector = noctalia.pluginDir() .. "/omp_sessions.py"
local chat_bridge = noctalia.pluginDir() .. "/chat_bridge.py"
local orb_builder = noctalia.pluginDir() .. "/build_orbs.py"
local home = noctalia.getenv("HOME") or ""
local cache_home = noctalia.getenv("XDG_CACHE_HOME")
if cache_home == nil or cache_home == "" then cache_home = home .. "/.cache" end
local orb_dir = cache_home .. "/agentik/orbs"
-- Journals grow over time; give the collector the full window so a slow
-- refresh is not killed by runAsync's 5 s default timeout with empty stdout.
local collector_timeout_ms = 60000
local orb_builder_timeout_ms = 120000
local refreshing = false
local chat_refreshing = false
local chat_feed_revision = nil
local active_sessions = 0
local chat_busy = false

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

local function ensure_orbs()
    local current = noctalia.state.get("agentik_orbs")
    if type(current) ~= "table" or current.directory ~= orb_dir then
        noctalia.state.set("agentik_orbs", {
            ready = false,
            directory = orb_dir,
            fps = 30,
            frame_count = 60,
        })
    end
    noctalia.runAsync(
        {"python3", orb_builder, "--output", orb_dir, "--ensure"},
        function(result)
            local payload = noctalia.json.decode(result.stdout or "")
            if type(payload) == "table"
                and payload.ready == true
                and payload.directory == orb_dir
                and (payload.fps == 30 or payload.fps == 60)
            then
                noctalia.state.set("agentik_orbs", payload)
            end
        end,
        orb_builder_timeout_ms
    )
end

local function refresh()
    if refreshing then return end
    refreshing = true
    local excluded = tostring(noctalia.getConfig("excluded_projects") or "")
    noctalia.runAsync(
        {"python3", collector, hex_encode(excluded)},
        function(result)
        refreshing = false
        local sessions = noctalia.json.decode(result.stdout)
        if type(sessions) == "table" then
            active_sessions = tonumber(sessions.active) or 0
            noctalia.state.set("sessions", sessions)
            update_cadence()
        end
    end, collector_timeout_ms)
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

ensure_orbs()
refresh()
refresh_chat()
update_cadence()
