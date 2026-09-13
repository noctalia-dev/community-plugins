--!nonstrict
local shared = require("./shared.luau")
local stationDisplay = require("./station-display.luau")
local favorites = shared.loadState().favorites
local activationStations, activationQueue = {}, {}

noctalia.state.watch("library_revision", function()
    favorites = shared.loadState().favorites
end)

local function play(station, queue)
    if station == nil then return end
    shared.setQueue(queue, station)
    local ok, err = shared.play(station, nil, function(started, asyncError)
        if not started then
            noctalia.notify("Radio Tellus", asyncError or "MPV could not start this stream.")
        end
    end)
    if not ok then noctalia.notify("Radio Tellus", err) end
end

function onQuery(query)
    local needle = shared.trim(query)
    activationStations, activationQueue = {}, favorites
    local rows = {
        { id = "open", title = "Open Radio Tellus", subtitle = "Browse stations by mood, genre, and country", glyph = "radio" },
        { id = "random", title = "Play a random station", subtitle = "Select from recent popular stations", glyph = "arrows-shuffle" },
    }
    for index, station in ipairs(favorites) do
        if shared.matchesSearch(station, needle) then
            local id = "favorite:" .. tostring(index)
            local country = stationDisplay.countryName(station.country, station.country_code)
            activationStations[id] = station
            table.insert(rows, {
                id = id,
                title = station.name,
                subtitle = "Favorite · " .. (country ~= "" and country or "Internet radio"),
                glyph = "star-filled",
            })
            if #rows >= 42 then break end
        end
    end
    launcher.setResults(query, rows)
end

function onActivate(id)
    if id:match("^favorite:%d+$") then play(activationStations[id], activationQueue); return end
    if id == "random" then
        local stations = shared.loadCache(shared.DISCOVER_CACHE_FILE, shared.MAX_CATALOG_STATIONS)
        local station = shared.randomStation(stations)
        if station then
            play(station, stations)
        elseif #stations == 0 then
            noctalia.notify("Radio Tellus", "Open Radio Tellus once to load recent popular stations.")
        else
            noctalia.notify("Radio Tellus", "No cached station met the configured stream security policy.")
        end
        return
    end
    noctalia.togglePanel("mirenel/radio-tellus:panel")
end
