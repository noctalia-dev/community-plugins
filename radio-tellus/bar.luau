--!nonstrict
local shared = require("./shared.luau")

local glyph = noctalia.getConfig("glyph") or "radio"
local showPlaybackStatus = noctalia.getConfig("show_playback_status") ~= false
local showStationName = noctalia.getConfig("show_station_name") ~= false
local stationNameLimit = shared.clampInteger(noctalia.getConfig("station_name_limit"), 24, 8, 60)
local volumeStep = shared.clampInteger(noctalia.getConfig("volume_step"), 5, 1, 20)
local state = tostring(noctalia.state.get("player_state") or "stopped")
local station = tostring(noctalia.state.get("station_name") or "")
local track = tostring(noctalia.state.get("track_title") or "")
local saved = shared.loadState()
local volume = tonumber(noctalia.state.get("player_volume")) or shared.effectiveVolume(saved)
local muted = noctalia.state.get("player_muted") == true
local isolation = tostring(noctalia.state.get("playback_isolation") or "")

local function glyphPresentation()
    if showPlaybackStatus and state == "playing" and (muted or volume <= 0) then
        return "volume-off", "on_surface_variant"
    elseif showPlaybackStatus and state == "playing" then
        return "antenna-bars-5", "primary"
    elseif showPlaybackStatus and state == "paused" then
        return "player-pause", "on_surface_variant"
    elseif showPlaybackStatus and state == "starting" then
        return "antenna-bars-3", "primary"
    end

    return glyph, "on_surface"
end

local function render()
    local active = state == "playing" or state == "paused" or state == "starting"
    local displayGlyph, glyphColor = glyphPresentation()
    local children = {
        ui.glyph({ name = displayGlyph, size = 16, color = glyphColor }),
    }
    if active and showStationName then
        table.insert(children, ui.label({
            text = shared.truncateCharacters(shared.singleLine(station ~= "" and station or "Radio", 200), stationNameLimit),
            maxLines = 1,
        }))
    end

    local container = barWidget.isVertical() and ui.column or ui.row
    barWidget.render(container({ gap = 4, align = "center", paddingH = 4, paddingV = 2 }, children))

    if active then
        local status = state == "paused" and "Paused: " or (state == "starting" and "Connecting: " or "Playing: ")
        local detail = track ~= "" and track ~= station and "\n" .. track or ""
        barWidget.setTooltip(status .. station .. detail .. " · " .. (muted and "muted" or tostring(math.floor(volume)) .. "%")
            .. (isolation == "full" and "\nFull playback isolation"
                or (isolation == "compatible" and "\nProxy playback isolation" or ""))
            .. "\nLeft: open · Middle: settings · Right: stop · Wheel: volume")
    else
        barWidget.setTooltip("Open Radio Tellus\nMiddle: widget settings · Wheel: radio volume")
    end
end

noctalia.state.watch("player_state", function(value) state = tostring(value or "stopped"); render() end)
noctalia.state.watch("station_name", function(value) station = tostring(value or ""); render() end)
noctalia.state.watch("track_title", function(value) track = tostring(value or ""); render() end)
noctalia.state.watch("player_volume", function(value) volume = tonumber(value) or volume; render() end)
noctalia.state.watch("player_muted", function(value) muted = value == true; render() end)
noctalia.state.watch("playback_isolation", function(value) isolation = tostring(value or ""); render() end)

function update()
    noctalia.setUpdateInterval(60000)
    render()
end

function onClick()
    noctalia.togglePanel("mirenel/radio-tellus:panel")
end

function onRightClick()
    shared.stop()
end

function onScroll(axis, steps)
    if axis ~= "vertical" then return end
    volume = math.max(0, math.min(100, volume - (tonumber(steps) or 0) * volumeStep))
    shared.setVolume(volume)
    render()
end
