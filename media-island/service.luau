--!nonstrict
-- Publish Noctalia's selected MPRIS player to the plugin's widgets. Querying
-- Noctalia's own D-Bus facade keeps player selection identical to the native
-- media widget instead of duplicating its preference rules.

local BUSCTL_ARGS = {
    "busctl",
    "--user",
    "--json=short",
    "call",
    "dev.noctalia.Mpris",
    "/dev/noctalia/Mpris",
    "dev.noctalia.Mpris",
    "GetActivePlayer",
}

local queryPending = false
local publishedKey = ""
local currentArtUrl = ""
local currentPlayer = nil
local runtimeConfigPending = false
local appliedRuntimeConfig = nil

local function syncRuntimeConfig()
    if runtimeConfigPending then
        return
    end

    local panelMode = noctalia.getConfig("panel_at_default_position") == true and "default" or "attached"
    -- Keep this independent from playback state. Changing title_scroll needs a
    -- full Noctalia config reload, which would rebuild the bar on every
    -- Play/Pause transition. Playback itself is published through plugin state
    -- below and updates the control in place.
    local scrollMode = noctalia.getConfig("always_scroll_title") == true and "always" or "on_hover"
    local pillClickMode = noctalia.getConfig("open_media_panel_on_click") == true and "panel" or "island"
    local desired = table.concat({ panelMode, scrollMode, pillClickMode }, "\31")
    if desired == appliedRuntimeConfig then
        return
    end

    runtimeConfigPending = true
    noctalia.runAsync({
        "sh",
        "-c",
        "exec \"$HOME/.local/bin/noctalia-media-panel-mode\" \"$1\" \"$2\" \"$3\"",
        "media-island-config",
        panelMode,
        scrollMode,
        pillClickMode,
    }, function(result)
        runtimeConfigPending = false
        if result.exitCode == 0 then
            appliedRuntimeConfig = desired
        end
    end)
end

local function field(fields, key, fallback)
    local wrapped = fields[key]
    if type(wrapped) == "table" and wrapped.data ~= nil then
        return wrapped.data
    end
    return fallback
end

local function publish(player)
    local key = "none"
    if type(player) == "table" then
        key = table.concat({
            player.busName or "",
            player.trackId or "",
            player.title or "",
            player.artist or "",
            player.status or "",
            player.artPath or "",
        }, "\31")
    end

    if key == publishedKey then
        return
    end
    publishedKey = key
    noctalia.state.set("player", player)
end

local function resolveArtwork(player, artUrl)
    currentArtUrl = artUrl
    if artUrl == "" then
        player.artPath = ""
        publish(player)
        return
    end

    if string.sub(artUrl, 1, 7) == "file://" then
        player.artPath = noctalia.string.urlDecode(string.sub(artUrl, 8))
        publish(player)
        return
    end

    if string.sub(artUrl, 1, 7) ~= "http://" and string.sub(artUrl, 1, 8) ~= "https://" then
        player.artPath = ""
        publish(player)
        return
    end

    player.artPath = ""
    publish(player)
    local dataDir = noctalia.pluginDataDir()
    if dataDir == nil then
        return
    end
    local destination = dataDir .. "/active-artwork.img"
    noctalia.download(artUrl, destination, function(success)
        if currentArtUrl ~= artUrl or currentPlayer ~= player then
            return
        end
        player.artPath = success and destination or ""
        publish(player)
    end)
end

local function handleQuery(result)
    queryPending = false
    if result.exitCode ~= 0 then
        currentPlayer = nil
        currentArtUrl = ""
        publish(nil)
        return
    end

    local decoded = noctalia.json.decode(result.stdout)
    if type(decoded) ~= "table" or type(decoded.data) ~= "table" or decoded.data[1] ~= true then
        currentPlayer = nil
        currentArtUrl = ""
        publish(nil)
        return
    end

    local fields = decoded.data[2]
    if type(fields) ~= "table" then
        currentPlayer = nil
        currentArtUrl = ""
        publish(nil)
        return
    end

    local artists = field(fields, "artists", {})
    local artist = ""
    if type(artists) == "table" then
        artist = table.concat(artists, ", ")
    end

    local player = {
        busName = field(fields, "bus_name", ""),
        trackId = field(fields, "track_id", ""),
        title = field(fields, "title", ""),
        artist = artist,
        status = field(fields, "playback_status", ""),
        playing = field(fields, "playback_status", "") == "Playing",
        artPath = "",
    }
    currentPlayer = player

    local artUrl = field(fields, "art_url", "")
    resolveArtwork(player, type(artUrl) == "string" and artUrl or "")
end

function update()
    noctalia.setUpdateInterval(500)
    syncRuntimeConfig()
    if queryPending then
        return
    end
    queryPending = noctalia.runAsync(BUSCTL_ARGS, handleQuery)
end

function onConfigChanged()
    appliedRuntimeConfig = nil
    syncRuntimeConfig()
end
