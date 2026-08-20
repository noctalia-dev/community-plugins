local Playlist = {}

local store = require("./store.luau")
local api = require("../api.luau")
local logger = require("../utils/log.luau")
local library = require("./library.luau")
local player = require("./player.luau")

local state = store.state
local log = logger.module("ytm", "playlist")

local function load_cached(pid)
    if api and api.load_cached_playlist then
        return api.load_cached_playlist(pid)
    end
    return nil
end

local function save_cache(pid)
    if api and api.save_playlist_cache then
        noctalia.runAsync("true", function()
            api.save_playlist_cache(pid, state.playlist.tracks)
        end)
    end
end

local function ensure_thumbs(kind)
    if api and api.ensure_thumbnails then
        noctalia.runAsync("true", function()
            api.ensure_thumbnails(state.playlist.tracks, store.publish, kind)
        end)
    end
end

-- keep everything already loaded plus append genuinely-new tracks
local function merge_keep_existing(existing, incoming)
    local merged = {}
    local seen = {}
    for _, tr in ipairs(existing) do
        if tr.id then
            table.insert(merged, tr)
            seen[tr.id] = true
        end
    end
    for _, tr in ipairs(incoming) do
        if tr.id and not seen[tr.id] then
            table.insert(merged, tr)
            seen[tr.id] = true
        end
    end
    return merged
end

-- full open/fetch of a playlist (open_playlist)
function Playlist.open(pid, title)
    if not pid or pid == "" then return end
    state.playlist.id = pid
    state.playlist.title = tostring(title or "Playlist")

    state.playlist.next_token = nil
    state.playlist.tracks = {}
    state.playlist.fetching = true
    store.publish()

    if api and api.playlist_page then
        api.playlist_page(pid, nil, function(res)
            state.playlist.fetching = false
            state.playlist.next_token = res.next_token
            if res.total_count and res.total_count > 0 then
                state.playlist.count = res.total_count
            end
            if res.tracks and #res.tracks > 0 then
                if pid == "VLLM" then library.sync_liked_tracks(res.tracks) end
                state.playlist.tracks = merge_keep_existing(state.playlist.tracks, res.tracks)
            end
            store.publish()
            save_cache(pid)
            ensure_thumbs("playlist")
        end)
    end

    noctalia.runAsync("true", function()
        local cached = load_cached(pid)
        if cached and #cached > 0 then
            if pid == "VLLM" then library.sync_liked_tracks(cached) end
            if state.playlist.id == pid and #state.playlist.tracks == 0 then
                state.playlist.tracks = cached
                store.publish()
            end
        end
    end)
end

-- play from cached tracks only (play_playlist)
function Playlist.play(pid, title)
    if not pid or pid == "" then return end
    state.playlist.id = pid
    state.playlist.title = tostring(title or "Playlist")
    local cached = load_cached(pid)
    if cached and #cached > 0 then
        state.playlist.tracks = cached
        player.play_index(1, cached)
    else
        state.playlist.tracks = {}
    end
    store.publish()
    if api and api.playlist_tracks then
        api.playlist_tracks(pid)
    end
end

-- hard refresh of current playlist (refresh_playlist)
function Playlist.refresh(pid)
    pid = pid or state.playlist.id
    if not pid or pid == "" then return end
    state.playlist.id = pid
    state.playlist.tracks = {}
    state.playlist.next_token = nil
    state.playlist.fetching = true
    store.publish()
    if api and api.playlist_page then
        api.playlist_page(pid, nil, function(res)
            state.playlist.fetching = false
            state.playlist.next_token = res.next_token
            state.playlist.tracks = res.tracks or {}
            save_cache(pid)
            store.publish()
            ensure_thumbs("playlist")
        end)
    end
end

-- fetch next cursor page (fetch_next_page)
local function do_fetch(pid, fetch_token)
    api.playlist_page(pid, fetch_token, function(res)
        local existing = {}
        for _, t in ipairs(state.playlist.tracks) do
            if t.id then existing[t.id] = true end
        end

        local added_count = 0
        local queue_sync = (state.player.source_playlist == pid)
        if res.tracks and #res.tracks > 0 then
            for _, tr in ipairs(res.tracks) do
                if tr.id and not existing[tr.id] then
                    table.insert(state.playlist.tracks, tr)
                    if queue_sync then
                        player.append_to_queue(tr)
                    end
                    existing[tr.id] = true
                    added_count = added_count + 1
                end
            end
        end

        local new_token = res.next_token
        local token_valid = (new_token and new_token ~= "" and new_token ~= fetch_token)

        if added_count == 0 and token_valid then
            log("fetch_next_page: all duplicates, skipping to next page")
            noctalia.runAsync("true", function()
                do_fetch(pid, new_token)
            end)
            return
        end

        if not token_valid then
            state.playlist.next_token = nil
        else
            state.playlist.next_token = new_token
        end

        state.playlist.fetching = false
        log("fetch_next_page: added " .. added_count .. " new tracks (total " .. #state.playlist.tracks .. "), next_token=" .. tostring(state.playlist.next_token ~= nil))
        store.publish()
        save_cache(pid)
        ensure_thumbs("playlist")
    end)
end

function Playlist.fetch_next_page(pid, token)
    pid = pid or state.playlist.id
    token = token or state.playlist.next_token
    if not pid or not token or token == "" or state.playlist.fetching then return end
    if not (api and api.playlist_page) then return end
    state.playlist.fetching = true
    log("fetch_next_page for pid='" .. pid .. "'")
    do_fetch(pid, token)
end

-- play a provided queue, remembering the source playlist (play_with_queue)
function Playlist.play_queue(queue, index, source_playlist)
    if queue and #queue > 0 then
        if source_playlist and source_playlist ~= "" then
            local spid = tostring(source_playlist)
            local is_library = false
            for _, pl in ipairs(state.library) do
                if tostring(pl.id or "") == spid then
                    is_library = true
                    break
                end
            end
            if not is_library then
                library.remember_playlist(spid, state.playlist.title or "Playlist")
            end
        end
        state.player.source_playlist = source_playlist
        player.play_index(index or 1, queue)
    else
        log("play_with_queue: empty or missing queue")
    end
end

return Playlist