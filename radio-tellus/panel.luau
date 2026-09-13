--!nonstrict
local shared = require("./shared.luau")
local stationDisplay = require("./station-display.luau")

-- Displayed version comes from plugin.toml; unavailable manifests show none.
local pluginVersion = (function()
    local text = noctalia.readFile("plugin.toml")
    if type(text) ~= "string" then return "" end
    return shared.singleLine(("\n" .. text):match('\nversion%s*=%s*"([^"]+)"') or "", 24)
end)()

local stations, favorites, recent = {}, {}, {}
local view, activeLabel = "discover", "Recent popular stations"
local selectedIndex, selectedStation = 0, nil
local loading, errorText, stateError = false, "", ""
local query, panelOpen = "", false
local searchRevision = 0
local suppressStopOnClose = false
local fetchGeneration = 0
local randomGeneration = 0
local refreshPending, refreshStatus = false, ""
local playerVolume, playerMuted = shared.DEFAULT_VOLUME, false
local render

local SHORTCUTS = {
    previous = tostring(noctalia.getConfig("shortcut_previous") or "Up"),
    next = tostring(noctalia.getConfig("shortcut_next") or "Down"),
    play = tostring(noctalia.getConfig("shortcut_play") or "Return"),
    toggle = tostring(noctalia.getConfig("shortcut_toggle") or "space"),
    random = tostring(noctalia.getConfig("shortcut_random") or "r"),
    favorite = tostring(noctalia.getConfig("shortcut_favorite") or "f"),
    mute = tostring(noctalia.getConfig("shortcut_mute") or "m"),
}

local function resetSearch(force, preserveRefresh)
    if not preserveRefresh then refreshPending, refreshStatus = false, "" end
    if force or query ~= "" then searchRevision += 1 end
    query = ""
end

local MOODS = {
    { "Chill", "chillout", "coffee" }, { "Focus", "lofi", "brain" },
    { "Happy", "happy", "mood-smile" }, { "Energy", "dance", "bolt" },
    { "Calm", "ambient", "leaf" }, { "Sleep", "sleep", "moon" },
    { "Romantic", "love", "heart" }, { "Melancholy", "melancholic", "cloud-rain" },
}

local GENRES = {
    { "Pop", "pop", "sparkles" }, { "Rock", "rock", "guitar-pick" },
    { "Electronic", "electronic", "wave-sine" }, { "Hip-hop", "hiphop", "microphone-2" },
    { "Jazz", "jazz", "music" }, { "Classical", "classical", "music" },
    { "Soul & R&B", "soul", "heart" }, { "Reggae", "reggae", "sun" },
    { "Metal", "metal", "flame" }, { "Folk", "folk", "trees" },
    { "Country", "country", "hat-cowboy" }, { "Talk", "talk", "message-circle" },
}

local PLACES = {
    { "Sweden", "SE" }, { "United Kingdom", "GB" }, { "United States", "US" },
    { "France", "FR" }, { "Germany", "DE" }, { "Spain", "ES" },
    { "Italy", "IT" }, { "Brazil", "BR" }, { "Japan", "JP" },
    { "India", "IN" }, { "Australia", "AU" }, { "Canada", "CA" },
}

local PICKER_VIEWS = {
    moods = { prompt = "Pick a mood", choices = MOODS },
    genres = { prompt = "Pick a genre", choices = GENRES },
    places = { prompt = "Pick a place", choices = PLACES },
}

local function configuredLimit()
    return shared.clampInteger(noctalia.getConfig("station_limit"), 40, 10, 100)
end

local function cacheSeconds()
    local hours = shared.clampInteger(noctalia.getConfig("cache_hours"), 6, 1, 72)
    return hours * 3600
end

local function reloadLibrary()
    local state, err = shared.loadState()
    favorites, recent = state.favorites, state.recent
    playerVolume = tonumber(noctalia.state.get("player_volume")) or shared.effectiveVolume(state)
    local publishedMuted = noctalia.state.get("player_muted")
    playerMuted = type(publishedMuted) == "boolean" and publishedMuted or state.muted
    stateError = err or ""
end

local function displayStations()
    if view == "favorites" then return favorites end
    if view == "recent" then return recent end
    return stations
end

local function selectIndex(index)
    local rows = displayStations()
    if #rows == 0 then selectedIndex, selectedStation = 0, nil; return end
    selectedIndex = math.max(1, math.min(#rows, math.floor(tonumber(index) or 1)))
    selectedStation = rows[selectedIndex]
end

local function setStations(nextView, nextLabel, rows)
    view, activeLabel = nextView, nextLabel
    stations = shared.sanitizeStations(rows, configuredLimit())
    selectedIndex, selectedStation = 0, nil
    if #displayStations() > 0 then selectIndex(1) end
end

local function parseResponse(response)
    return shared.parseStationResponse(response, configuredLimit())
end

local function finishRefresh(succeeded)
    if not refreshPending then return end
    refreshPending = false
    refreshStatus = succeeded and "Updated just now" or ""
end

local function popularSearchUrl(field, value)
    local filter = field and (field .. "=" .. shared.urlEncode(value) .. "&") or ""
    return shared.API_BASE .. "/stations/search?" .. filter
        .. "hidebroken=true&order=clickcount&reverse=true&limit=" .. tostring(configuredLimit())
end

local function fetchUrl(nextView, label, url, cacheName)
    fetchGeneration += 1
    local generation = fetchGeneration
    loading, errorText, view, activeLabel = true, "", nextView, label
    render()
    local accepted = noctalia.http(shared.httpRequest(url), function(response)
        if generation ~= fetchGeneration then return end
        loading = false
        local rows, err = parseResponse(response)
        if rows == nil then errorText = err
        else
            setStations(nextView, label, rows)
            if cacheName then shared.saveCache(cacheName, rows, configuredLimit()) end
            errorText = #rows == 0 and "No playable stations found." or ""
        end
        finishRefresh(rows ~= nil)
        render()
    end)
    if not accepted and generation == fetchGeneration then
        loading, errorText = false, "Radio Browser request could not be started."
        finishRefresh(false)
        render()
    end
end

local function showDiscover(force, preserveRefresh)
    resetSearch(false, preserveRefresh)
    local cached = shared.loadCache(shared.DISCOVER_CACHE_FILE, configuredLimit())
    setStations("discover", "Recent popular stations", cached)
    if not force and #cached > 0
        and shared.cacheFresh(shared.DISCOVER_CACHE_FILE, cacheSeconds(), configuredLimit()) then
        loading, errorText = false, ""
        render()
        return
    end
    fetchUrl("discover", "Recent popular stations", popularSearchUrl(nil, nil), shared.DISCOVER_CACHE_FILE)
end

local function browseTag(section, label, tag, preserveRefresh)
    resetSearch(false, preserveRefresh)
    setStations(section, label, {})
    fetchUrl(section, label, popularSearchUrl("tag", tag), nil)
end

local function browsePlace(label, code, force, preserveRefresh)
    resetSearch(false, preserveRefresh)
    local cleanCode = shared.countryCode(code)
    local cacheName = "country-" .. cleanCode .. ".json"
    local cached = shared.loadCache(cacheName, configuredLimit())
    setStations("places", label, cached)
    if #cached > 0 then
        loading, errorText = false, ""
        render()
        if not force and shared.cacheFresh(cacheName, cacheSeconds(), configuredLimit()) then return end
    end
    local url = shared.API_BASE .. "/stations/bycountrycodeexact/" .. cleanCode
        .. "?hidebroken=true&order=clickcount&reverse=true&limit=" .. tostring(configuredLimit())
    fetchUrl("places", label, url, cacheName)
end

local function mergeGroups(groups)
    local rows, seen = {}, {}
    for _, group in ipairs(groups) do
        for _, station in ipairs(group) do
            local key = shared.stationKey(station)
            if key ~= "" and not seen[key] then
                seen[key] = true
                table.insert(rows, station)
                if #rows >= configuredLimit() then return rows end
            end
        end
    end
    return rows
end

local function previewSearch(value)
    fetchGeneration += 1
    query = shared.singleLine(value, 120)
    if query == "" then showDiscover(false); return end
    local source = shared.loadCache(shared.DISCOVER_CACHE_FILE, configuredLimit())
    local matches = {}
    for _, station in ipairs(source) do
        if shared.matchesSearch(station, query) then table.insert(matches, station) end
    end
    setStations("search", "Search preview", matches)
    loading, errorText = false, ""
    render()
end

local function searchRemote(value, preserveRefresh)
    if not preserveRefresh then refreshPending, refreshStatus = false, "" end
    query = shared.singleLine(value ~= nil and value or query, 120)
    if query == "" then showDiscover(false); return end
    fetchGeneration += 1
    local generation, pending, groups, failures = fetchGeneration, 3, {}, 0
    loading, errorText, view, activeLabel = true, "", "search", "Results for “" .. shared.singleLine(query, 48) .. "”"
    render()
    for _, field in ipairs({ "name", "country", "tag" }) do
        local accepted = noctalia.http(shared.httpRequest(popularSearchUrl(field, query)), function(response)
            if generation ~= fetchGeneration then return end
            local rows = parseResponse(response)
            if rows == nil then failures += 1 else table.insert(groups, rows) end
            pending -= 1
            if pending == 0 then
                loading = false
                local merged = mergeGroups(groups)
                setStations("search", activeLabel, merged)
                if #merged == 0 then errorText = failures == 3 and "Could not reach Radio Browser." or "No stations matched." end
                finishRefresh(failures < 3)
                render()
            end
        end)
        if not accepted then
            failures += 1
            pending -= 1
        end
    end
    if pending == 0 then
        loading, errorText = false, "Radio Browser requests could not be started."
        finishRefresh(false)
        render()
    end
end

local function submitSearch(value)
    local submittedQuery = type(value) == "string" and value or query
    searchRemote(submittedQuery)
end

local function showLibrary(kind, preserveRefresh)
    resetSearch(false, preserveRefresh)
    reloadLibrary()
    fetchGeneration += 1
    loading, errorText, view = false, "", kind
    activeLabel = kind == "favorites" and "Your favorites" or "Recently played"
    selectedIndex, selectedStation = 0, nil
    if #displayStations() > 0 then selectIndex(1) end
    render()
end

local function showPicker(kind)
    local picker = PICKER_VIEWS[kind]
    if picker == nil then return end
    resetSearch(false)
    fetchGeneration += 1
    loading, errorText = false, ""
    setStations(kind, picker.prompt, {})
    render()
end

local function playbackFinished(started, asyncError)
    if started then
        errorText = ""
    else
        errorText = asyncError or "MPV could not start this stream."
    end
    render()
end

local function playStation(station, queue)
    if station == nil then return end
    errorText = ""
    shared.setQueue(queue or displayStations(), station)
    local ok, err = shared.play(station, playerVolume, playbackFinished)
    if not ok then errorText = err; render() end
end

local function tuneRandom()
    randomGeneration += 1
    local generation = randomGeneration
    errorText = ""
    local httpsFilter = noctalia.getConfig("allow_insecure_http") == true and "" or "&is_https=true"
    -- Cache-busting ensures each click reaches the randomizer.
    local cachebuster = tostring(math.floor(noctalia.nowMs())) .. "-" .. tostring(generation)
    local url = shared.API_BASE .. "/stations/search?hidebroken=true&order=random&limit=1"
        .. httpsFilter .. "&cachebuster=" .. cachebuster
    local accepted = noctalia.http(shared.httpRequest(url), function(response)
        if generation ~= randomGeneration then return end
        local rows, err = shared.parseStationResponse(response, 1)
        if rows == nil or #rows == 0 then errorText = err or "No random station was returned."; render(); return end
        local station = shared.randomStation(rows)
        if station == nil then
            errorText = "No random station met the configured stream security policy."
            render()
            return
        end
        playStation(station, rows)
        render()
    end)
    if not accepted and generation == randomGeneration then
        errorText = "Random station request could not be started."
        render()
    end
end

local function refreshCurrent()
    refreshPending, refreshStatus = true, ""
    if view == "discover" then showDiscover(true, true); return end
    if view == "search" and query ~= "" then searchRemote(query, true); return end
    if view == "favorites" or view == "recent" then showLibrary(view, true); finishRefresh(true); render(); return end
    local picker = PICKER_VIEWS[view]
    for _, choice in ipairs(picker and picker.choices or {}) do
        if choice[1] == activeLabel then
            if view == "places" then browsePlace(choice[1], choice[2], true, true) else browseTag(view, choice[1], choice[2], true) end
            return
        end
    end
    finishRefresh(false)
    render()
end

local function canRefresh()
    if loading then return false end
    local picker = PICKER_VIEWS[view]
    if picker then return activeLabel ~= picker.prompt end
    return view ~= "search" or query ~= ""
end

local function toggleFavorite(station)
    if station == nil then return end
    local _, err = shared.toggleFavorite(station)
    reloadLibrary()
    if err then stateError = err end
    if view == "favorites" then
        selectedIndex, selectedStation = 0, nil
        if #favorites > 0 then selectIndex(1) end
    end
    render()
end

local function playerAction(action)
    if action == "toggle" then shared.togglePause()
    elseif action == "mute" then shared.toggleMute()
    elseif action == "stop" then shared.stop()
    elseif action == "previous" or action == "next" then
        local ok, err = shared.playQueueStep(action == "previous" and -1 or 1, playbackFinished)
        if not ok then errorText = err end
    end
    render()
end

local function activateStation(station, index)
    if station == nil then return end
    if index ~= nil then selectIndex(index) end
    local state = tostring(noctalia.state.get("player_state") or "stopped")
    local active = state ~= "stopped"
        and shared.stationKey(noctalia.state.get("station")) == shared.stationKey(station)
    if active and state == "starting" then return end
    if active and (state == "playing" or state == "paused") then
        playerAction("toggle")
    else
        playStation(station)
    end
end

local function stationRow(station, index, playerState, playingKey)
    local key = shared.stationKey(station)
    local playing = playingKey ~= "" and playingKey == key
    local connecting = playing and playerState == "starting"
    local selected = selectedIndex == index
    local saved = shared.isFavorite(favorites, station) ~= nil
    return ui.row({
        key = "station-" .. tostring(index) .. "-" .. key:sub(1, 96), align = "center", gap = 7, paddingH = 9, paddingV = 6,
        fill = playing and "primary/0.16" or (selected and "surface_variant" or "surface"), radius = 7,
        onClick = function()
            selectIndex(index)
            if tostring(noctalia.getConfig("row_click_action") or "play") ~= "select" then
                activateStation(station, index)
            end
            render()
        end,
    }, {
        ui.glyph({ name = playing and "antenna-bars-5" or "radio", size = 17, color = playing and "primary" or "on_surface_variant" }),
        ui.column({ flexGrow = 1, gap = 1 }, {
            ui.label({ text = station.name, maxLines = 1, fontSize = 13, fontWeight = playing and "bold" or "medium" }),
            ui.label({ text = stationDisplay.stationMeta(station), maxLines = 1, fontSize = 10, color = "on_surface_variant" }),
        }),
        ui.button({ glyph = saved and "star-filled" or "star", variant = "ghost", controlSize = "sm", tooltip = saved and "Remove favorite" or "Add favorite", onClick = function() toggleFavorite(station) end }),
        ui.button({
            glyph = playing and playerState == "playing" and "player-pause" or "player-play",
            variant = playing and "primary" or "ghost", controlSize = "sm", enabled = not connecting,
            tooltip = connecting and "Connecting…" or (playing and playerState == "playing" and "Pause station"
                or (playing and playerState == "paused" and "Resume station" or "Play station")),
            onClick = function() activateStation(station, index); render() end,
        }),
    })
end

local function playerCard()
    local state = tostring(noctalia.state.get("player_state") or "stopped")
    local playingStation = shared.sanitizeStation(noctalia.state.get("station"))
    local stationName = shared.singleLine(noctalia.state.get("station_name"), 160)
    local track = shared.singleLine(noctalia.state.get("track_title"), 160)
    local isolation = tostring(noctalia.state.get("playback_isolation") or "")
    local running = state ~= "stopped"
    local detail = not running and "Select a station or choose Random"
        or ((track ~= "" and track ~= stationName) and track or (state == "paused" and "Paused" or "Live now"))
    if running and isolation == "full" then detail = detail .. "  ·  Full isolation"
    elseif running and isolation == "compatible" then detail = detail .. "  ·  Proxy isolation" end
    return ui.row({ align = "center", gap = 9, padding = 10, minHeight = 64, fill = "surface_variant", radius = 10 }, {
        ui.glyph({ name = running and "antenna-bars-5" or "radio", size = 28, color = running and "primary" or "on_surface_variant" }),
        ui.column({ flexGrow = 1, gap = 3 }, {
            ui.label({ text = running and (stationName ~= "" and stationName or "Unknown station") or "No station playing", maxLines = 1, fontSize = 14, fontWeight = "bold" }),
            ui.label({ text = detail, maxLines = 1, fontSize = 11, color = "on_surface_variant" }),
            ui.row({ align = "center", gap = 4, width = 190 }, {
                ui.button({ glyph = playerMuted and "volume-off" or "volume", variant = playerMuted and "primary" or "ghost", controlSize = "sm", enabled = running, tooltip = "Mute", onClick = function() playerAction("mute") end }),
                ui.slider({ key = "volume", min = 0, max = 100, step = 1, value = playerVolume, controlSize = "sm", enabled = state ~= "starting", width = 118, onChange = function(value) playerVolume = tonumber(value) or playerVolume; shared.setVolume(playerVolume); render() end }),
                ui.label({ text = tostring(math.floor(playerVolume)) .. "%", width = 32, textAlign = "end", fontSize = 10, color = "on_surface_variant" }),
            }),
        }),
        ui.separator({ orientation = "vertical", thickness = 1, height = 44 }),
        ui.row({ align = "center", gap = 3 }, {
            ui.button({ glyph = shared.isFavorite(favorites, playingStation) and "star-filled" or "star", variant = "ghost", controlSize = "sm", enabled = playingStation ~= nil, tooltip = "Favorite playing station", onClick = function() toggleFavorite(playingStation) end }),
            ui.button({ glyph = "arrows-shuffle", glyphSize = 18, variant = "ghost", controlSize = "md", tooltip = "Random station", onClick = tuneRandom }),
            ui.button({ glyph = "player-skip-back", glyphSize = 19, variant = "ghost", controlSize = "md", tooltip = "Previous", onClick = function() playerAction("previous") end }),
            ui.button({ glyph = state == "playing" and "player-pause" or "player-play", glyphSize = 22, variant = "primary", controlSize = "lg", enabled = state ~= "starting", tooltip = state == "starting" and "Connecting…" or "Play / pause", onClick = function() if running then playerAction("toggle") else playStation(selectedStation) end end }),
            ui.button({ glyph = "player-skip-forward", glyphSize = 19, variant = "ghost", controlSize = "md", tooltip = "Next", onClick = function() playerAction("next") end }),
            ui.button({ glyph = "player-stop", glyphSize = 18, variant = "ghost", controlSize = "md", tooltip = "Stop", onClick = function() playerAction("stop") end }),
        }),
    })
end

local function choiceButton(section, choice)
    local label, value, glyph = choice[1], choice[2], choice[3]
    return ui.button({ key = "choice-" .. section .. "-" .. value, text = label, glyph = glyph,
        variant = activeLabel == label and "primary" or "outline", controlSize = "sm", flexGrow = 1,
        onClick = function() if section == "places" then browsePlace(label, value) else browseTag(section, label, value) end end })
end

local function choiceGrid(section, choices)
    local rows = {}
    for first = 1, #choices, 4 do
        local buttons = {}
        for index = first, math.min(first + 3, #choices) do table.insert(buttons, choiceButton(section, choices[index])) end
        table.insert(rows, ui.row({ gap = 5 }, buttons))
    end
    return ui.column({ gap = 5 }, rows)
end

local function browserHeader()
    local picker = PICKER_VIEWS[view]
    if picker then return choiceGrid(view, picker.choices) end
    return ui.box({ height = 0 })
end

local function openRadioSettings()
    suppressStopOnClose = true
    panel.close()
    noctalia.openSettings()
end

render = function()
    if not panelOpen then return end
    local rows, current = {}, displayStations()
    if loading and #current == 0 then table.insert(rows, ui.label({ text = "Loading stations…", textAlign = "center", color = "on_surface_variant", fontSize = 11 })) end
    local playerState = tostring(noctalia.state.get("player_state") or "stopped")
    local playingKey = playerState ~= "stopped" and shared.stationKey(noctalia.state.get("station")) or ""
    for index, station in ipairs(current) do
        table.insert(rows, stationRow(station, index, playerState, playingKey))
    end
    local playbackError = shared.singleLine(noctalia.state.get("player_error"), 160)
    local message = errorText ~= "" and errorText or (playbackError ~= "" and playbackError or stateError)

    panel.render(ui.column({ flexGrow = 1, gap = 9, padding = 12 }, {
        ui.column({ gap = 6, height = 70 }, {
            ui.row({ align = "center", gap = 6 }, {
                ui.column({ gap = 0 }, {
                    ui.row({ align = "center", gap = 6 }, {
                        ui.label({ text = "Radio Tellus", fontSize = 18, fontWeight = "bold", color = "on_surface" }),
                        ui.label({ text = pluginVersion, fontSize = 10, color = "on_surface_variant" }),
                    }),
                    ui.label({ text = "Internet radio from around the world", fontSize = 11, color = "on_surface_variant" }),
                }),
                ui.spacer({ flexGrow = 1 }),
                ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = "Radio settings", onClick = openRadioSettings }),
                ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", tooltip = "Close", onClick = function() panel.close() end }),
            }),
            ui.input({ key = "radio-search-" .. tostring(searchRevision), value = query, placeholder = "Search stations, countries, genres…", controlSize = "sm", submitOnEnter = true, onChange = previewSearch, onSubmit = submitSearch }),
        }),
        ui.separator({ thickness = 1 }),
        ui.column({ key = "station-browser-view", flexGrow = 1, gap = 8 }, {
            playerCard(),
            ui.row({ gap = 4, align = "center" }, {
                ui.button({ text = "Discover", glyph = "compass", variant = view == "discover" and "primary" or "ghost", controlSize = "sm", onClick = function() showDiscover(false) end }),
                ui.button({ text = "Moods", glyph = "mood-smile", variant = view == "moods" and "primary" or "ghost", controlSize = "sm", onClick = function() showPicker("moods") end }),
                ui.button({ text = "Genres", glyph = "category", variant = view == "genres" and "primary" or "ghost", controlSize = "sm", onClick = function() showPicker("genres") end }),
                ui.button({ text = "Places", glyph = "world", variant = view == "places" and "primary" or "ghost", controlSize = "sm", onClick = function() showPicker("places") end }),
                ui.button({ text = "Favorites", glyph = "star", variant = view == "favorites" and "primary" or "ghost", controlSize = "sm", onClick = function() showLibrary("favorites") end }),
                ui.button({ text = "Recent", glyph = "history", variant = view == "recent" and "primary" or "ghost", controlSize = "sm", onClick = function() showLibrary("recent") end }),
            }),
            browserHeader(),
            ui.column({ gap = 3, paddingH = 4 }, {
                ui.row({ align = "center", gap = 6 }, {
                    ui.label({ text = activeLabel, fontSize = 13, fontWeight = "bold", flexGrow = 1 }),
                    loading and ui.label({ text = "Loading…", fontSize = 11, color = "primary" }) or ui.box({ width = 0 }),
                    refreshStatus ~= "" and ui.label({ text = refreshStatus, fontSize = 11, color = "primary" }) or ui.box({ width = 0 }),
                    ui.label({ text = tostring(#current) .. " stations", fontSize = 11, color = "on_surface_variant" }),
                    ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", width = 34, height = 32, enabled = canRefresh(), tooltip = "Reload stations", onClick = refreshCurrent }),
                }),
                message ~= "" and ui.label({ text = message, maxLines = 2, fontSize = 12, color = "error" }) or ui.box({ height = 0 }),
            }),
            ui.scroll({ key = "stations-" .. view .. "-" .. activeLabel, flexGrow = 1, gap = 3, align = "stretch", fill = "surface/0.55", radius = 8 }, rows),
        }),
    }))
end

noctalia.state.watch("player_state", function() if panelOpen then render() end end)
noctalia.state.watch("station", function() if panelOpen then render() end end)
noctalia.state.watch("track_title", function() if panelOpen then render() end end)
noctalia.state.watch("player_error", function() if panelOpen then render() end end)
noctalia.state.watch("player_volume", function(value) playerVolume = tonumber(value) or playerVolume; if panelOpen then render() end end)
noctalia.state.watch("player_muted", function(value) playerMuted = value == true; if panelOpen then render() end end)
noctalia.state.watch("playback_isolation", function() if panelOpen then render() end end)
noctalia.state.watch("library_revision", function() if panelOpen then reloadLibrary(); render() end end)

function onOpen(_context)
    suppressStopOnClose = false
    panelOpen = true
    resetSearch(true)
    reloadLibrary()
    local startupView = tostring(noctalia.getConfig("startup_view") or "discover")
    if startupView == "favorites" or startupView == "recent" then
        showLibrary(startupView)
    elseif PICKER_VIEWS[startupView] then
        setStations(startupView, PICKER_VIEWS[startupView].prompt, {})
        loading, errorText = false, ""
        render()
    else
        showDiscover(false)
    end
end

function onClose()
    panelOpen = false
    fetchGeneration += 1
    randomGeneration += 1
    local shouldStop = noctalia.getConfig("stop_on_panel_close") == true and not suppressStopOnClose
    suppressStopOnClose = false
    if shouldStop then shared.stop() end
end

function onKey(chord, pressed)
    if not pressed then return end
    if chord == SHORTCUTS.previous then selectIndex(selectedIndex - 1); render()
    elseif chord == SHORTCUTS.next then selectIndex(selectedIndex + 1); render()
    elseif chord == SHORTCUTS.play then activateStation(selectedStation, selectedIndex)
    elseif chord == SHORTCUTS.toggle then
        if tostring(noctalia.state.get("player_state") or "stopped") == "stopped" then playStation(selectedStation) else playerAction("toggle") end
    elseif chord == SHORTCUTS.random then tuneRandom()
    elseif chord == SHORTCUTS.favorite then toggleFavorite(selectedStation)
    elseif chord == SHORTCUTS.mute then playerAction("mute") end
end

function onIpc(event, _payload)
    if event == "random" then tuneRandom()
    elseif event == "discover" then showDiscover(true) end
end
