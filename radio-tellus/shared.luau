--!nonstrict
-- Shared persistence and playback helpers used by each Noctalia entry.
-- Entries run in separate VMs, so files and noctalia.state bridge them.

local station = require("./station-utils.luau")
local storage = require("./storage-utils.luau")
local shared = {}

shared.API_BASE = "https://all.api.radio-browser.info/json"
shared.USER_AGENT = "Radio-Tellus"
shared.STATE_FILE = "state.json"
shared.DISCOVER_CACHE_FILE = "discover.json"
shared.QUEUE_FILE = "queue.json"
shared.PLAYBACK_FILE = "playback.json"
shared.MAX_CATALOG_STATIONS = station.MAX_CATALOG_STATIONS
shared.MAX_PERSISTED_BYTES = storage.MAX_BYTES
shared.MAX_FAVORITES = 500
shared.MAX_RECENT = 100
shared.DEFAULT_VOLUME = 69

-- Re-export validation helpers for the entry modules.
shared.trim = station.trim
shared.truncateCharacters = station.truncateCharacters
shared.singleLine = station.singleLine
shared.trackTitle = station.trackTitle
shared.urlEncode = station.urlEncode
shared.countryCode = station.countryCode
shared.stationKey = station.stationKey
shared.matchesSearch = station.matchesSearch
shared.radioBrowserUuid = station.radioBrowserUuid
shared.validateStreamUrl = station.validateStreamUrl
shared.streamAllowed = station.streamAllowed
shared.sanitizeStation = station.sanitizeStation
shared.sanitizeStations = station.sanitizeStations
shared.parseStationResponse = station.parseStationResponse

function shared.clampInteger(value, fallback, minimum, maximum)
    local number = math.floor(tonumber(value) or fallback)
    return math.max(minimum, math.min(maximum, number))
end

function shared.historyLimit()
    return shared.clampInteger(noctalia.getConfig("history_limit"), 30, 0, shared.MAX_RECENT)
end

function shared.httpRequest(url)
    return {
        url = url,
        method = "GET",
        headers = { "Accept: application/json", "User-Agent: " .. shared.USER_AGENT },
        follow_redirects = false,
        allow_insecure_tls = false,
    }
end

shared.dataDir = storage.dataDir
shared.dataPath = storage.dataPath
shared.hardenDataDir = storage.hardenDataDir

local readJson = storage.readJson
local writeJson = storage.writeJson

local function defaultState()
    return {
        favorites = {}, recent = {}, volume = shared.DEFAULT_VOLUME,
        volume_set = false, muted = false,
    }
end

function shared.loadState()
    local raw, err = readJson(shared.STATE_FILE)
    if raw == nil then
        if err ~= "missing" then return defaultState(), "Saved radio state is " .. err .. "; it was not overwritten." end
        local migrated = defaultState()
        local text = storage.readText("favorites.tsv")
        if type(text) == "string" then
            for line in text:gmatch("[^\r\n]+") do
                local name, url = line:match("^([^\t]+)\t(https?://.+)$")
                local station = shared.sanitizeStation({ name = name, url_resolved = url, country = "Favorite" })
                if station then table.insert(migrated.favorites, station) end
                if #migrated.favorites >= shared.MAX_FAVORITES then break end
            end
            writeJson(shared.STATE_FILE, migrated)
        end
        return migrated
    end
    if type(raw) ~= "table" or type(raw.favorites) ~= "table" or type(raw.recent) ~= "table" then
        return defaultState(), "Saved radio state is invalid; it was not overwritten."
    end
    local historyLimit = shared.historyLimit()
    local volume = shared.clampInteger(raw.volume, shared.DEFAULT_VOLUME, 0, 100)
    local volumeSet = raw.volume_set == true
        or (raw.volume_set == nil and tonumber(raw.volume) ~= nil and volume ~= shared.DEFAULT_VOLUME)
    local loaded = {
        favorites = shared.sanitizeStations(raw.favorites, shared.MAX_FAVORITES),
        recent = shared.sanitizeStations(raw.recent, historyLimit),
        volume = volume,
        volume_set = volumeSet,
        muted = raw.muted == true,
    }
    if historyLimit == 0 and next(raw.recent) ~= nil and not writeJson(shared.STATE_FILE, loaded) then
        return loaded, "Recent history could not be cleared."
    end
    return loaded
end

function shared.effectiveVolume(saved)
    local current = type(saved) == "table" and saved or shared.loadState()
    return current.volume_set == true and current.volume or shared.DEFAULT_VOLUME
end

function shared.saveState(state)
    return writeJson(shared.STATE_FILE, {
        favorites = shared.sanitizeStations(state.favorites, shared.MAX_FAVORITES),
        recent = shared.sanitizeStations(state.recent, shared.historyLimit()),
        volume = shared.clampInteger(state.volume, shared.DEFAULT_VOLUME, 0, 100),
        volume_set = state.volume_set == true,
        muted = state.muted == true,
    })
end

function shared.isFavorite(favorites, station)
    local key = shared.stationKey(station)
    for index, favorite in ipairs(favorites or {}) do
        if shared.stationKey(favorite) == key then return index end
    end
    return nil
end

function shared.toggleFavorite(station)
    local state, err = shared.loadState()
    if err then return nil, err end
    local clean = shared.sanitizeStation(station)
    if clean == nil then return nil, "This station cannot be saved." end
    local index = shared.isFavorite(state.favorites, clean)
    if index then table.remove(state.favorites, index) else table.insert(state.favorites, 1, clean) end
    if not shared.saveState(state) then return nil, "Radio state could not be saved." end
    noctalia.state.set("library_revision", tostring(math.floor(noctalia.nowMs())) .. ":favorite:" .. shared.singleLine(shared.stationKey(clean), 80))
    return not index, nil
end

function shared.recordRecent(station)
    local state, err = shared.loadState()
    if err then return false end
    local clean = shared.sanitizeStation(station)
    if clean == nil then return false end
    local historyLimit = shared.historyLimit()
    if historyLimit == 0 then return true end
    local key = shared.stationKey(clean)
    local nextRecent = { clean }
    for _, recent in ipairs(state.recent) do
        if shared.stationKey(recent) ~= key and #nextRecent < historyLimit then table.insert(nextRecent, recent) end
    end
    state.recent = nextRecent
    local ok = shared.saveState(state)
    if ok then noctalia.state.set("library_revision", tostring(math.floor(noctalia.nowMs())) .. ":recent:" .. shared.singleLine(key, 80)) end
    return ok
end

function shared.reportClick(station)
    -- Reporting checks the current opt-out setting.
    if noctalia.getConfig("report_clicks") == false or type(station) ~= "table" then return false end
    local uuid = shared.radioBrowserUuid(station.uuid)
    if uuid == nil then return false end
    return noctalia.http(shared.httpRequest(shared.API_BASE .. "/url/" .. uuid), function(_) end)
end

function shared.pruneState()
    local path = shared.dataPath(shared.STATE_FILE)
    if path == nil or not noctalia.fileExists(path) then return true end
    local state, err = shared.loadState()
    if err then return false end
    local ok = shared.saveState(state)
    if ok then noctalia.state.set("library_revision", tostring(math.floor(noctalia.nowMs())) .. ":prune") end
    return ok
end

function shared.loadCache(name, maximum)
    local raw = readJson(name)
    local stations = type(raw) == "table" and type(raw.stations) == "table" and raw.stations or raw
    return shared.sanitizeStations(stations, maximum)
end

function shared.saveCache(name, stations, requestedLimit)
    local limit = shared.clampInteger(requestedLimit, shared.MAX_CATALOG_STATIONS,
        0, shared.MAX_CATALOG_STATIONS)
    return writeJson(name, {
        stations = shared.sanitizeStations(stations, shared.MAX_CATALOG_STATIONS),
        requested_limit = limit,
    })
end

function shared.cacheFresh(name, seconds, minimumLimit)
    local path = shared.dataPath(name)
    local info = path and noctalia.fileInfo(path) or nil
    local age = info and tonumber(info.mtime) and (os.time() - info.mtime) or nil
    if age == nil or age < 0 or age >= seconds then return false end
    local required = shared.clampInteger(minimumLimit, 0, 0, shared.MAX_CATALOG_STATIONS)
    if required == 0 then return true end
    local raw = readJson(name)
    if type(raw) ~= "table" then return false end
    if type(raw.stations) == "table" then
        return math.floor(tonumber(raw.requested_limit) or 0) >= required
    end
    -- Legacy caches lack a requested limit; use their sanitized count.
    return #shared.sanitizeStations(raw, required) >= required
end

function shared.setQueue(stations, selected)
    local clean = shared.sanitizeStations(stations, shared.MAX_CATALOG_STATIONS)
    local selectedKey, index = shared.stationKey(selected), 1
    for candidateIndex, station in ipairs(clean) do
        if shared.stationKey(station) == selectedKey then index = candidateIndex; break end
    end
    return writeJson(shared.QUEUE_FILE, { stations = clean, index = index })
end

function shared.loadQueue()
    local raw = readJson(shared.QUEUE_FILE)
    if type(raw) ~= "table" then return {}, 0 end
    local stations = shared.sanitizeStations(raw.stations, shared.MAX_CATALOG_STATIONS)
    local index = math.max(1, math.min(#stations, math.floor(tonumber(raw.index) or 1)))
    return stations, index
end

local function validSocketPath(path)
    local dir = shared.dataDir()
    if type(path) ~= "string" or dir == nil then return nil end
    local escapedDir = dir:gsub("([^%w])", "%%%1")
    local name = path:match("^" .. escapedDir .. "/([^/]+)$")
    if name == "mpv.sock" or (name and name:match("^mpv%-%d+%-%d+%.sock$")) then return path end
    local generation = path:match("^" .. escapedDir .. "/run%-(%d+%-%d+)/mpv%.sock$")
    if generation then return path end
    return nil
end

local function playbackRecord()
    local raw = readJson(shared.PLAYBACK_FILE)
    if type(raw) ~= "table" then return nil end
    local socket = validSocketPath(raw.socket)
    local generation = shared.singleLine(raw.generation, 80)
    if socket == nil or generation == "" then return nil end
    return {
        socket = socket,
        generation = generation,
        started_ms = math.floor(tonumber(raw.started_ms) or 0),
        station = shared.sanitizeStation(raw.station),
        secure_session = raw.secure_session == true,
        confirmation_pending = raw.confirmation_pending == true,
        report_click = raw.report_click == true,
    }
end

function shared.confirmPlayback(generation)
    local record = playbackRecord()
    if record == nil or record.generation ~= tostring(generation) or record.station == nil then return false end
    if record.confirmation_pending ~= true then return true end
        -- Recording the attempt first prevents duplicate reports after reloads.
    local persisted = writeJson(shared.PLAYBACK_FILE, {
        socket = record.socket,
        generation = record.generation,
        started_ms = record.started_ms,
        station = record.station,
        secure_session = true,
        confirmation_pending = false,
        report_click = record.report_click,
    })
    if not persisted then return false end
    shared.recordRecent(record.station)
    if record.report_click then shared.reportClick(record.station) end
    return true
end

function shared.socketPath()
    local published = validSocketPath(noctalia.state.get("player_socket"))
    if published then return published end
    local record = playbackRecord()
    if record then return record.socket end
    local legacy = shared.dataPath("mpv.sock")
    return legacy and noctalia.fileExists(legacy) and legacy or nil
end

function shared.playbackIsolation()
    local socket = shared.socketPath()
    if socket == nil then return "" end
    local path = socket:gsub("/mpv%.sock$", "/isolation")
    if path == socket or not noctalia.fileExists(path) then return "" end
    local info = noctalia.fileInfo(path)
    if info and tonumber(info.size) and info.size > 32 then return "" end
    local mode = shared.trim(noctalia.readFile(path))
    return (mode == "full" or mode == "compatible") and mode or ""
end

function shared.restorePlayback()
    local record = playbackRecord()
    if record == nil then return nil end
    noctalia.state.set("player_generation", record.generation)
    noctalia.state.set("player_socket", record.socket)
    noctalia.state.set("player_started_ms", record.started_ms)
    if not record.secure_session then
        -- Sessions created before the proxy requirement are not adopted.
        shared.stop()
        noctalia.notify("Radio Tellus", "Stopped a legacy radio session that did not use the validating proxy.")
        return nil
    end
    if record.station then
        noctalia.state.set("station", record.station)
        noctalia.state.set("station_name", record.station.name)
    end
    return record
end

function shared.clearPlayback(generation)
    if generation ~= nil and tostring(noctalia.state.get("player_generation") or "") ~= tostring(generation) then return end
    local record = playbackRecord()
    if generation == nil or record == nil or record.generation == tostring(generation) then
        local path = shared.dataPath(shared.PLAYBACK_FILE)
        if path and noctalia.fileExists(path) then noctalia.removeFile(path) end
    end
    noctalia.state.set("player_socket", "")
end

function shared.clearNowPlaying()
    noctalia.state.set("player_state", "stopped")
    noctalia.state.set("station", {})
    noctalia.state.set("station_name", "")
    noctalia.state.set("track_title", "")
    noctalia.state.set("playback_isolation", "")
end

function shared.shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function shared.socketCommand(command)
    local socket = shared.socketPath()
    if socket == nil or not noctalia.commandExists("socat") or not noctalia.fileExists(socket) then return false end
    local script = "printf %s " .. shared.shellQuote(command)
        .. " | socat -T 1 - UNIX-CONNECT:" .. shared.shellQuote(socket)
    return noctalia.runAsync({ "sh", "-c", script })
end

function shared.stopPlayer(done, targetSocket)
    local socket
    if targetSocket ~= false then socket = validSocketPath(targetSocket) or shared.socketPath() end
    if socket == nil then if done then done(true) end; return true end
    local script = "printf %s " .. shared.shellQuote('{"command":["quit"]}\n')
        .. " | socat -T 1 - UNIX-CONNECT:" .. shared.shellQuote(socket)
        .. " >/dev/null 2>&1"
    local started = noctalia.runAsync({ "sh", "-c", script }, function(result)
        local timedOut = type(result) ~= "table" or result.timedOut == true
        local exitCode = type(result) == "table" and math.floor(tonumber(result.exitCode) or -1) or -1
        local socketExists = noctalia.fileExists(socket)
        -- State is retained until delivery or exit is confirmed.
        local stopped = not timedOut and (exitCode == 0 or not socketExists)
        if stopped and socketExists then noctalia.removeFile(socket) end
        if done then done(stopped) end
    end, 2000)
    if not started and done then done(false) end
    return started
end

local REQUIRED_PLAYBACK_COMMANDS = {
    "bash", "chmod", "dirname", "env", "head", "ip", "mkdir", "mpv", "python3", "rm", "rmdir",
    "setpriv", "sh", "sleep", "socat",
}

local function capturePlayerState(socket)
    return {
        socket = socket,
        generation = tostring(noctalia.state.get("player_generation") or ""),
        started_ms = tonumber(noctalia.state.get("player_started_ms")) or 0,
        state = tostring(noctalia.state.get("player_state") or "stopped"),
        station = noctalia.state.get("station"),
        station_name = noctalia.state.get("station_name"),
        track_title = noctalia.state.get("track_title"),
        isolation = noctalia.state.get("playback_isolation"),
    }
end

local function restorePlayerState(snapshot)
    noctalia.state.set("player_generation", snapshot.generation)
    noctalia.state.set("player_socket", snapshot.socket or "")
    noctalia.state.set("player_started_ms", snapshot.started_ms)
    noctalia.state.set("player_state", snapshot.state)
    noctalia.state.set("station", snapshot.station or {})
    noctalia.state.set("station_name", snapshot.station_name or "")
    noctalia.state.set("track_title", snapshot.track_title or "")
    noctalia.state.set("playback_isolation", snapshot.isolation or "")
end

local function playbackCommand(session, dir, generation, isolationMode, streamUrl, volume, muted)
    local protocols = streamUrl:match("^https://")
        and "https,tcp,tls,crypto,httpproxy" or "http,https,tcp,tls,crypto,httpproxy"
    local lavfPolicy = "protocol_whitelist=[" .. protocols .. "]"
    return {
        session, dir, generation, isolationMode, "mpv",
        "--no-config", "--load-scripts=no", "--ytdl=no", "--terminal=no",
        "--really-quiet", "--no-video", "--audio-display=no", "--force-window=no", "--idle=no",
        "--input-terminal=no", "--input-default-bindings=no", "--input-vo-keyboard=no",
        "--tls-verify=yes", "--network-timeout=15", "--load-unsafe-playlists=no",
        "--autoload-files=no", "--sub-auto=no", "--audio-file-auto=no", "--prefetch-playlist=no",
        "--cache-on-disk=no", "--cache-secs=30", "--demuxer-max-bytes=32MiB",
        "--demuxer-max-back-bytes=4MiB", "--stream-lavf-o=" .. lavfPolicy,
        "--demuxer-lavf-o=" .. lavfPolicy, "--user-agent=" .. shared.USER_AGENT,
        "--ao=pulse", "--input-ipc-server=/radio-runtime/mpv.sock",
        "--volume=" .. tostring(volume), muted and "--mute=yes" or "--mute=no", "--", streamUrl,
    }
end

function shared.play(station, volume, done)
    local clean, streamError = shared.streamAllowed(station)
    if clean == nil then return false, streamError end
    for _, command in ipairs(REQUIRED_PLAYBACK_COMMANDS) do
        if not noctalia.commandExists(command) then
            return false, command .. " is required for isolated radio playback."
        end
    end
    local isolationMode = tostring(noctalia.getConfig("isolation_mode") or "auto")
    if isolationMode ~= "auto" and isolationMode ~= "full" and isolationMode ~= "compatible" then
        isolationMode = "auto"
    end
    if isolationMode == "full" and not noctalia.commandExists("bwrap") then
        return false, "Full isolation requires bwrap; choose Automatic or Compatible isolation."
    end
    local dir = shared.dataDir()
    if dir == nil then return false, "Noctalia could not create plugin storage." end
    local pluginDir = noctalia.pluginDir()
    if pluginDir == nil then
        noctalia.log("radio-tellus: pluginDir returned no runtime directory")
        return false, "Noctalia could not locate the radio playback helpers."
    end
    local session = pluginDir .. "/stream-session"
    if not noctalia.fileExists(session) then return false, "The isolated playback helper is missing." end
    local state = shared.loadState()
    local chosenVolume = shared.clampInteger(volume, shared.effectiveVolume(state), 0, 100)
    local publishedMuted = noctalia.state.get("player_muted")
    local chosenMuted = type(publishedMuted) == "boolean" and publishedMuted or state.muted
    local oldSocket = shared.socketPath()
    local previous = capturePlayerState(oldSocket)
    local generation = tostring(math.floor(noctalia.nowMs())) .. "-" .. tostring(math.random(100000, 999999))
    local socket = dir .. "/run-" .. generation .. "/mpv.sock"
    local startedMs = math.floor(noctalia.nowMs())
    local shouldReportClick = noctalia.getConfig("report_clicks") ~= false
    noctalia.state.set("player_generation", generation)
    noctalia.state.set("player_socket", socket)
    noctalia.state.set("player_started_ms", startedMs)
    noctalia.state.set("player_state", "starting")
    noctalia.state.set("player_error", "")
    noctalia.state.set("playback_isolation", "")
    shared.stopPlayer(function(stopped)
        if tostring(noctalia.state.get("player_generation") or "") ~= generation then return end
        if not stopped then
            restorePlayerState(previous)
            local message = "The previous station did not accept the stop request."
            noctalia.state.set("player_error", message)
            if done then done(false, message) end
            return
        end
        local prepared = writeJson(shared.PLAYBACK_FILE, {
            socket = socket,
            generation = generation,
            started_ms = startedMs,
            station = clean,
            secure_session = true,
            confirmation_pending = true,
            report_click = shouldReportClick,
        })
        if not prepared then
            shared.clearPlayback(nil)
            shared.clearNowPlaying()
            local message = "Radio Tellus could not prepare its playback state."
            noctalia.state.set("player_error", message)
            if done then done(false, message) end
            return
        end
        local launchVolume = shared.clampInteger(noctalia.state.get("player_volume"), chosenVolume, 0, 100)
        -- Stream commands remain detached; callbacks are bounded for finite
        -- commands.
        local started = noctalia.runAsync(playbackCommand(
            session, dir, generation, isolationMode, clean.url_resolved, launchVolume, chosenMuted
        ))
        if started then
            noctalia.state.set("station_name", clean.name)
            noctalia.state.set("station", clean)
            noctalia.state.set("track_title", "")
            noctalia.state.set("player_volume", launchVolume)
        else
            shared.clearPlayback(generation)
            shared.clearNowPlaying()
            noctalia.state.set("player_error", "MPV could not start this stream.")
        end
        if done then done(started, started and nil or "MPV could not start this stream.") end
    end, oldSocket or false)
    return true
end

function shared.playQueueStep(delta, done)
    local stations, index = shared.loadQueue()
    if #stations == 0 then return false, "No station queue is available." end
    index = ((index - 1 + delta) % #stations) + 1
    writeJson(shared.QUEUE_FILE, { stations = stations, index = index })
    return shared.play(stations[index], nil, done)
end

function shared.randomStation(stations)
    local pool = shared.sanitizeStations(stations, shared.MAX_CATALOG_STATIONS)
    if #pool == 0 then pool = shared.loadCache(shared.DISCOVER_CACHE_FILE, shared.MAX_CATALOG_STATIONS) end
    if #pool == 0 then return nil end
    local current, choices = shared.stationKey(noctalia.state.get("station")), {}
    for _, station in ipairs(pool) do
        if shared.streamAllowed(station) ~= nil and shared.stationKey(station) ~= current then
            table.insert(choices, station)
        end
    end
    if #choices == 0 then
        for _, station in ipairs(pool) do
            if shared.streamAllowed(station) ~= nil then table.insert(choices, station) end
        end
    end
    if #choices == 0 then return nil end
    return choices[math.random(1, #choices)]
end

function shared.stop()
    local socket = shared.socketPath()
    local generation = tostring(noctalia.state.get("player_generation") or "")
    shared.stopPlayer(function(stopped)
        if tostring(noctalia.state.get("player_generation") or "") ~= generation then return end
        if stopped then
            noctalia.state.set("player_generation", "stopped-" .. tostring(math.floor(noctalia.nowMs())))
            shared.clearPlayback(nil)
            shared.clearNowPlaying()
            noctalia.state.set("player_error", "")
        else
            noctalia.state.set("player_error", "MPV did not accept the stop request; playback controls were preserved.")
        end
    end, socket or false)
end

function shared.togglePause()
    local accepted = shared.socketCommand('{"command":["cycle","pause"]}\n')
    if accepted then
        local current = tostring(noctalia.state.get("player_state") or "stopped")
        if current == "playing" then noctalia.state.set("player_state", "paused")
        elseif current == "paused" then noctalia.state.set("player_state", "playing") end
    end
    return accepted
end

function shared.toggleMute()
    local accepted = shared.socketCommand('{"command":["cycle","mute"]}\n')
    if accepted then
        local muted = noctalia.state.get("player_muted") ~= true
        local state, err = shared.loadState()
        if not err then state.muted = muted; shared.saveState(state) end
        noctalia.state.set("player_muted", muted)
    end
    return accepted
end

function shared.setVolume(value)
    local volume = shared.clampInteger(value, shared.DEFAULT_VOLUME, 0, 100)
    local state, err = shared.loadState()
    if not err then state.volume, state.volume_set = volume, true; shared.saveState(state) end
    noctalia.state.set("player_volume", volume)
    return shared.socketCommand('{"command":["set_property","volume",' .. tostring(volume) .. ']}\n')
end

return shared
