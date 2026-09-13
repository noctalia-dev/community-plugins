--!nonstrict
local shared = require("./shared.luau")

local busy, failures, activeGeneration, confirmedGeneration = false, 0, "", ""
local STATUS_ERROR = "Radio player status is temporarily unavailable."
local ACTIVE_INTERVAL_MS, IDLE_INTERVAL_MS = 2500, 60000
local STATUS_REQUEST = table.concat({
    '{"command":["get_property","pause"],"request_id":1}',
    '{"command":["get_property","media-title"],"request_id":2}',
    '{"command":["get_property","volume"],"request_id":3}',
    '{"command":["get_property","mute"],"request_id":4}',
    '{"command":["get_property","audio-params"],"request_id":5}',
}, "\n") .. "\n"

local function publishChanged(key, value)
    if noctalia.state.get(key) == value then return false end
    noctalia.state.set(key, value)
    return true
end

local function setPollingActive(active)
    noctalia.setUpdateInterval(active and ACTIVE_INTERVAL_MS or IDLE_INTERVAL_MS)
end

local function parsePlayerStatus(output)
    local status = { audio_ready = false }
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local decoded = noctalia.json.decode(line)
        if type(decoded) == "table" and decoded.error == "success" then
            if decoded.request_id == 1 and type(decoded.data) == "boolean" then status.paused = decoded.data
            elseif decoded.request_id == 2 and type(decoded.data) == "string" then status.title = shared.trackTitle(decoded.data)
            elseif decoded.request_id == 3 and type(decoded.data) == "number" then
                status.volume = shared.clampInteger(decoded.data + 0.5, 0, 0, 100)
            elseif decoded.request_id == 4 and type(decoded.data) == "boolean" then status.muted = decoded.data
            elseif decoded.request_id == 5 and type(decoded.data) == "table" then status.audio_ready = true end
        end
    end
    return status
end

local saved = shared.loadState()
shared.hardenDataDir()
shared.pruneState()
shared.restorePlayback()
publishChanged("player_volume", shared.effectiveVolume(saved))
publishChanged("player_muted", saved.muted)
setPollingActive(shared.socketPath() ~= nil)

function onConfigChanged()
    shared.pruneState()
end

function onExit(_signal, reason)
    -- Reloads retain playback; real teardown stops it.
    -- Detached control can finish after this VM exits.
    if reason ~= "reload" then
        shared.socketCommand('{"command":["quit"]}\n')
    end
end

function update()
    if busy or not noctalia.commandExists("socat") then return end
    local socket = shared.socketPath()
    if socket == nil then
        setPollingActive(false)
        if tostring(noctalia.state.get("player_state") or "stopped") ~= "stopped" then
            shared.clearNowPlaying()
        end
        return
    end
    if not noctalia.fileExists(socket) then
        local state = tostring(noctalia.state.get("player_state") or "stopped")
        local startedMs = tonumber(noctalia.state.get("player_started_ms")) or 0
        local age = noctalia.nowMs() - startedMs
        if state == "starting" and age >= 0 and age < 10000 then return end
        shared.clearPlayback(noctalia.state.get("player_generation"))
        shared.clearNowPlaying()
        publishChanged("player_error", "This station stopped or could not be played.")
        setPollingActive(false)
        return
    end
    setPollingActive(true)
    local isolation = shared.playbackIsolation()
    if isolation ~= "" then publishChanged("playback_isolation", isolation) end
    local generation = tostring(noctalia.state.get("player_generation") or "")
    if generation ~= activeGeneration then failures, activeGeneration = 0, generation end
    busy = true
    local script = "printf %s " .. shared.shellQuote(STATUS_REQUEST)
        .. " | socat -T 1 - UNIX-CONNECT:" .. shared.shellQuote(socket)
        .. " | head -c 65536"
    local started = noctalia.runAsync({ "bash", "-o", "pipefail", "-c", script }, function(result)
        busy = false
        if socket ~= shared.socketPath()
            or generation ~= tostring(noctalia.state.get("player_generation") or "") then return end
        if type(result) ~= "table" then
            failures += 1
            if failures >= 2 then publishChanged("player_error", STATUS_ERROR) end
            return
        end
        local status = parsePlayerStatus(result.stdout)
        if status.paused == nil then
            failures += 1
            local commandFailed = math.floor(tonumber(result.exitCode) or -1) ~= 0
            local timedOut = result.timedOut == true
            if failures >= 2 and commandFailed and not timedOut then
                -- Timeout failures may be transient; remove sockets only after
                -- a non-timeout failure.
                if noctalia.fileExists(socket) then noctalia.removeFile(socket) end
                shared.clearPlayback(generation)
                shared.clearNowPlaying()
                publishChanged("player_error", "This station stopped or could not be played.")
                setPollingActive(false)
            elseif failures >= 2 then
                publishChanged("player_error", STATUS_ERROR)
            end
            return
        end
        failures = 0
        if tostring(noctalia.state.get("player_error") or "") == STATUS_ERROR then
            publishChanged("player_error", "")
        end
        if status.audio_ready then
            publishChanged("player_state", status.paused and "paused" or "playing")
            if generation ~= confirmedGeneration then
                local confirmed = shared.confirmPlayback(generation)
                if confirmed == true then confirmedGeneration = generation end
            end
        end
        if status.title then publishChanged("track_title", status.title) end
        if status.volume then publishChanged("player_volume", status.volume) end
        if status.muted ~= nil then publishChanged("player_muted", status.muted) end
    end, 1800)
    if not started then
        busy = false
        failures += 1
        if failures >= 2 then publishChanged("player_error", STATUS_ERROR) end
    end
end

noctalia.state.watch("player_socket", function(value)
    local active = tostring(value or "") ~= ""
    setPollingActive(active)
    if active and not busy then update() end
end)
