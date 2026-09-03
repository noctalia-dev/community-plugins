--!strict

-- on-disk cache read/write: library, playlists, session, recent playlists.

local logger = require("../utils/log.luau")
local log = logger.module("ytapi", "cache")

local const = require("./constants.luau")
local LIBRARY_CACHE_PATH = const.LIBRARY_CACHE_PATH
local RECENT_PLAYLISTS_CACHE_PATH = const.RECENT_PLAYLISTS_CACHE_PATH
local PLAYLISTS_CACHE_DIR = const.PLAYLISTS_CACHE_DIR
local ARTISTS_CACHE_DIR = const.ARTISTS_CACHE_DIR
local SESSION_CACHE_PATH = const.SESSION_CACHE_PATH

local thumbs = require("./thumbnails.luau")
local attach_cached_thumbs = thumbs.attach_cached_thumbs

local types = require("../utils/types.luau")

local EXPO = {}

function EXPO.load_cached_recent_playlists(): { types.Playlist }?
    if not noctalia.fileExists(RECENT_PLAYLISTS_CACHE_PATH) then return nil end
    local raw = noctalia.readFile(RECENT_PLAYLISTS_CACHE_PATH)
    if not raw or raw == "" then return nil end
    local data, _ = noctalia.json.decode(raw)
    if type(data) == "table" and #data > 0 then
        return data
    end
    return nil
end

function EXPO.save_recent_playlists_cache(playlists: { types.Playlist })
    if type(playlists) ~= "table" or #playlists == 0 then return end
    local encoded = noctalia.json.encode(playlists)
    if encoded then
        noctalia.writeFile(RECENT_PLAYLISTS_CACHE_PATH, encoded)
        log("saved " .. #playlists .. " playlists to recent_playlists cache")
    end
end

function EXPO.load_cached_library(): { types.Playlist }?
    if not noctalia.fileExists(LIBRARY_CACHE_PATH) then return nil end
    local raw = noctalia.readFile(LIBRARY_CACHE_PATH)
    if not raw or raw == "" then return nil end
    local data = noctalia.json.decode(raw)
    if type(data) == "table" and #data > 0 then
        attach_cached_thumbs(data)
        log("loaded " .. #data .. " playlists from library cache")
        return data
    end
    return nil
end

function EXPO.save_library_cache(playlists: { types.Playlist })
    if type(playlists) ~= "table" or #playlists == 0 then return end
    local encoded = noctalia.json.encode(playlists)
    if encoded then
        noctalia.writeFile(LIBRARY_CACHE_PATH, encoded)
        log("saved " .. #playlists .. " playlists to library cache")
    end
end

function EXPO.load_cached_playlist(playlist_id): { types.Track }?
    if type(playlist_id) ~= "string" or playlist_id == "" then return nil end
    local safe_id = playlist_id:gsub("[^%w%-_]", "_")
    local path = PLAYLISTS_CACHE_DIR .. "/" .. safe_id .. ".json"
    if not noctalia.fileExists(path) then return nil end
    local raw = noctalia.readFile(path)
    if not raw or raw == "" then return nil end
    local data = noctalia.json.decode(raw)
    if type(data) == "table" and #data > 0 then
        attach_cached_thumbs(data)
        log("loaded " .. #data .. " tracks from cache for playlist " .. playlist_id)
        return data
    end
    return nil
end

function EXPO.save_playlist_cache(playlist_id, tracks: { types.Track })
    if type(playlist_id) ~= "string" or playlist_id == "" or type(tracks) ~= "table" or #tracks == 0 then return end
    local safe_id = playlist_id:gsub("[^%w%-_]", "_")
    local path = PLAYLISTS_CACHE_DIR .. "/" .. safe_id .. ".json"
    local encoded = noctalia.json.encode(tracks)
    if encoded then
        noctalia.runAsync("mkdir -p '" .. PLAYLISTS_CACHE_DIR .. "'", function()
            noctalia.writeFile(path, encoded)
            log("saved " .. #tracks .. " tracks to cache for playlist " .. playlist_id)
        end, 5000)
    end
end

function EXPO.load_session(): types.Player?
    if not noctalia.fileExists(SESSION_CACHE_PATH) then return nil end
    local raw = noctalia.readFile(SESSION_CACHE_PATH)
    if not raw or raw == "" then return nil end
    local data = noctalia.json.decode(raw)
    if type(data) == "table" then
        if type(data.queue) == "table" then
            attach_cached_thumbs(data.queue)
        end
        log("loaded session: title='" .. tostring(data.title) .. "' index=" .. tostring(data.index))
        return data
    end
    return nil
end

function EXPO.save_session(player: types.Player)
    if type(player) ~= "table" then return end
    local session = {
        id = player.id or "",
        title = player.title or "",
        artist = player.artist or "",
        thumbnail_url = player.thumbnail_url or "",
        thumb_path = player.thumb_path or "",
        duration = player.duration or 0,
        position = player.position or 0,
        volume = player.volume or 70,
        index = player.index or 0,
        queue = player.queue or {}
    }
    local encoded = noctalia.json.encode(session)
    if encoded then
        noctalia.writeFile(SESSION_CACHE_PATH, encoded)
    end
end

function EXPO.load_cached_artist(artist_id: string): { artist: any?, tracks: { types.Track }, related: { any } }?
    if type(artist_id) ~= "string" or artist_id == "" then return nil end
    local safe_id = artist_id:gsub("[^%w%-_]", "_")
    local path = ARTISTS_CACHE_DIR .. "/" .. safe_id .. ".json"
    if not noctalia.fileExists(path) then return nil end
    local raw = noctalia.readFile(path)
    if not raw or raw == "" then return nil end
    local data = noctalia.json.decode(raw)
    if type(data) == "table" and type(data.tracks) == "table" then
        if type(data.artist) == "table" then attach_cached_thumbs({ data.artist }) end
        if type(data.tracks) == "table" then attach_cached_thumbs(data.tracks) end
        if type(data.related) == "table" then attach_cached_thumbs(data.related) end
        log("loaded cached artist data for " .. artist_id)
        return data
    end
    return nil
end

function EXPO.save_artist_cache(artist_id: string, data: { artist: any?, tracks: { types.Track }, related: { any } })
    if type(artist_id) ~= "string" or artist_id == "" or type(data) ~= "table" then return end
    local safe_id = artist_id:gsub("[^%w%-_]", "_")
    local path = ARTISTS_CACHE_DIR .. "/" .. safe_id .. ".json"
    local encoded = noctalia.json.encode(data)
    if encoded then
        noctalia.runAsync("mkdir -p '" .. ARTISTS_CACHE_DIR .. "'", function()
            noctalia.writeFile(path, encoded)
            log("saved artist cache for " .. artist_id)
        end, 5000)
    end
end

function EXPO.invalidate_playlist_cache(playlist_id)
    if type(playlist_id) ~= "string" or playlist_id == "" then return end
    local safe_id = playlist_id:gsub("[^%w%-_]", "_")
    local path = PLAYLISTS_CACHE_DIR .. "/" .. safe_id .. ".json"
    local script = string.format("rm -f '%s'", path)
    noctalia.runAsync(script, function() end, 2000)
end

return EXPO