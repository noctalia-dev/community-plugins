-- OmniRoute Quota service: one collector process shared by all widgets/panels.

local DATA_KEY = "omniroute_quota.data"
local STATUS_KEY = "omniroute_quota.status"
local ERROR_KEY = "omniroute_quota.error"

local running = false

local function shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function publish_status(status)
    noctalia.state.set(STATUS_KEY, status)
end

local function publish_error(message)
    noctalia.state.set(ERROR_KEY, message or "")
end

local function refresh()
    if running then return end
    running = true
    publish_status("loading")
    publish_error("")

    local plugin_dir = noctalia.pluginDir()
    if type(plugin_dir) ~= "string" or plugin_dir == "" then
        running = false
        publish_status("error")
        publish_error("plugin directory is unavailable")
        return
    end

    local command = "node " .. shell_quote(plugin_dir .. "/scripts/get-omniroute-quota.mjs")
    if noctalia.getConfig("show_inactive") == true then
        command = command .. " --show-inactive"
    end

    local started = noctalia.runAsync(command, function(result)
        running = false
        if not result or result.exitCode ~= 0 then
            local detail = result and result.stderr or "collector did not start"
            publish_status("error")
            publish_error(noctalia.string.trim(tostring(detail or "collector failed")))
            return
        end

        local ok, payload = pcall(noctalia.json.decode, result.stdout or "")
        if not ok or type(payload) ~= "table" or payload.ok ~= true then
            publish_status("error")
            publish_error(type(payload) == "table" and payload.error or "invalid collector response")
            return
        end

        noctalia.state.set(DATA_KEY, payload)
        publish_status("ready")
        publish_error("")
    end, 30000)

    if not started then
        running = false
        publish_status("error")
        publish_error("collector did not start")
    end
end

function onIpc(event, _payload)
    if event == "refresh" then refresh() end
end

function onOpen()
    local seconds = tonumber(noctalia.getConfig("refresh_seconds")) or 120
    noctalia.setUpdateInterval(math.max(30, seconds) * 1000)
    publish_status("loading")
    refresh()
end

function update()
    refresh()
end

function onConfigChanged()
    local seconds = tonumber(noctalia.getConfig("refresh_seconds")) or 120
    noctalia.setUpdateInterval(math.max(30, seconds) * 1000)
    refresh()
end

function onExit()
end

onOpen()
