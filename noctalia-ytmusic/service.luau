local REQ_KEY = "noctalia_ytmusic.request"

local api = require("./api.luau")
local store = require("./modules/store.luau")
local state = store.state

local handled_nonce = 0

local logger = require("./utils/log.luau")
local log = logger.module("ytm", "service")

-- Domain logic lives in dedicated backend modules under modules/.
-- Service keeps the wiring: logging, and request dispatch.
local auth = require("./modules/auth.luau")
local home = require("./modules/home.luau")
local library = require("./modules/library.luau")
local mpv = require("./modules/mpv.luau")
local player = require("./modules/player.luau")
local downloader = require("./modules/downloader.luau")
local playlist = require("./modules/playlist.luau")
local search = require("./modules/search.luau")
local cacheops = require("./modules/cacheops.luau")

local ACTIONS = {
    extract = function(r)
        auth.extract_cookies(r.browser)
    end,
    open_login = function(r)
        auth.open_login(r.browser)
    end,
    search = function(r)
        search.run(r.query, r.type)
    end,
    play = function(r)
        player.play(r.item or {})
    end,
    play_next = function(r)
        player.play_next(r.item or {})
    end,
    play_queue_index = function(r)
        player.play_index(r.index or 1)
    end,
    play_with_queue = function(r)
        if r.queue and #r.queue > 0 then
            playlist.play_queue(r.queue, r.index, r.source_playlist)
        elseif r.item then
            player.play(r.item)
        end
    end,
    play_playlist = function(r)
        playlist.play(r.id or r.playlist_id, r.title)
    end,
    open_playlist = function(r)
        playlist.open(r.id or r.playlist_id, r.title)
    end,
    refresh_playlist = function(r)
        playlist.refresh(r.id or r.playlist_id)
    end,
    fetch_next_page = function(r)
        playlist.fetch_next_page(r.playlist_id, r.token)
    end,
    toggle_like = function(r)
        library.toggle_like(r.id or r.video_id)
    end,
    toggle_shuffle = function(r)
        player.toggle_shuffle()
    end,
    cycle_repeat = function(r)
        player.cycle_repeat()
    end,
    refresh_quick_picks = function(r)
        home.refresh_quick_picks()
    end,
    download_track = function(r)
        local vid = r.id or r.video_id
        if vid and vid ~= "" then
            log("download_track: queued for id=" .. tostring(vid))
            downloader.enqueue(vid, "")
        end
    end,
    download_playlist = function(r)
        downloader.enqueue_playlist(state.playlist.tracks, state.playlist.id)
    end,
    toggle = function(r)
        player.toggle()
    end,
    next = function(r)
        player.next()
    end,
    prev = function(r)
        player.prev()
    end,
    seek = function(r)
        player.seek(r.seconds or r.value or r.position)
    end,
    volume = function(r)
        player.volume(r.value)
    end,
    toggle_mute = function(r)
        player.mute()
    end,
    stop = function(r)
        player.stop()
    end,
    prefetch = function(r)
        if api and api.prefetch_track and r.item then
            api.prefetch_track(r.item)
        end
    end,
    fetch_cache_stats = function(r)
        cacheops.fetch_stats()
    end,
    clear_cache = function(r)
        cacheops.clear(r.target)
    end,
    toggle_autoplay = function(r)
        state.settings.autoplay = not state.settings.autoplay
        store.publish()
    end,
}

noctalia.state.watch(REQ_KEY, function(req)
    if type(req) ~= "table" or not req.nonce or req.nonce <= handled_nonce then return end
    handled_nonce = req.nonce
    log("request nonce=" .. req.nonce .. " action=" .. tostring(req.action))

    local handler = ACTIONS[tostring(req.action or "")]
    if handler then
        handler(req)
    else
        log("request: unhandled action '" .. tostring(req.action) .. "'")
    end
end)

function update()
    if api.library_pending() then
        api.finish_library(function(playlists)
            state.library = type(playlists) == "table" and playlists or {}
            store.publish()
            if type(playlists) == "table" then
                log("ytmusic: loaded " .. #playlists .. " library playlists")
                noctalia.runAsync("true", function()
                    api.ensure_thumbnails(state.library, store.publish, "library")
                end)
            else
                log("ytmusic: library decode failed")
            end
        end)
    end
end

noctalia.setUpdateInterval(1000)

log("boot: service started, api=" .. tostring(type(api)) .. " library=" .. tostring(type(api and api.library)))
mpv.kill()
auth.detect_browsers()
auth.load_cached_cookies()
if api and api.load_cached_library then
    local cached_lib = api.load_cached_library()
    if cached_lib then
        state.library = cached_lib
    end
end
noctalia.runAsync("true", function()
    if api and api.load_cached_recent_playlists then
        local cached_recent = api.load_cached_recent_playlists()
        if cached_recent then
            state.recent_playlists = cached_recent
        end
    end
    if api and api.load_session then
        local sess = api.load_session()
        if type(sess) == "table" and sess.id and sess.id ~= "" then
            player.restore_session(sess)
        end
    end
    store.publish()
end)
if api and api.library then
    api.library()
end
store.publish()

function onStop()
    if api and api.save_session then
        api.save_session(state.player)
    end
end