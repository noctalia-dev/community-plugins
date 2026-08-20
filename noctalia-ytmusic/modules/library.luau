local store = require("./store.luau")
local api = require("../api.luau")
local logger = require("../utils/log.luau")

local state = store.state
local log = logger.module("ytm", "library")

local Library = {}

local auditing = false
local audit_pending = false

function Library.audit_downloaded_playlists()
    if not api or not api.load_cached_playlist then return end
    if auditing then
        audit_pending = true
        return
    end
    auditing = true
    noctalia.runAsync("true", function()
        state.downloaded_playlist_ids = {}
        local done = 0
        for _, pl in ipairs(state.library) do
            local pid = tostring(pl.id or "")
            if pid ~= "" then
                local tracks = api.load_cached_playlist(pid)
                if tracks and #tracks > 0 and type(state.cached_audio_ids) == "table" then
                    local all_dl = true
                    for _, tr in ipairs(tracks) do
                        if tr.id and not state.cached_audio_ids[tr.id] then
                            all_dl = false
                            break
                        end
                    end
                    if all_dl then
                        state.downloaded_playlist_ids[pid] = true
                        done = done + 1
                    end
                end
            end
        end
        log("audit_downloaded_playlists: " .. done .. " fully downloaded")
        auditing = false
        if audit_pending then
            audit_pending = false
            Library.audit_downloaded_playlists()
        end
    end)
end

function Library.remember_playlist(pid, title)
    if not pid or pid == "" then return end
    local cleaned = {}
    for _, pl in ipairs(state.recent_playlists or {}) do
        if tostring(pl.id or "") ~= pid then table.insert(cleaned, pl) end
    end
    table.insert(cleaned, 1, { id = pid, title = tostring(title or "Playlist") })
    while #cleaned > 3 do table.remove(cleaned) end
    state.recent_playlists = cleaned
    if api and api.save_recent_playlists_cache then
        api.save_recent_playlists_cache(cleaned)
    end
end

function Library.sync_liked_tracks(tracks)
    if type(tracks) ~= "table" then return end
    for _, tr in ipairs(tracks) do
        if tr.id and tr.id ~= "" then
            state.liked_ids[tr.id] = true
        end
    end
    log("sync_liked_tracks: +" .. tostring(#tracks))
end

function Library.sync_audio_cache()
    if api and api.get_cached_audio_ids then
        api.get_cached_audio_ids(function(set)
            if type(set) == "table" then
                state.cached_audio_ids = set
                Library.audit_downloaded_playlists()
                store.publish()
            end
        end)
    end
end

function Library.toggle_like(vid)
    vid = vid or state.player.id
    log("toggle_like: vid=" .. tostring(vid) .. " current=" .. tostring(state.liked_ids and state.liked_ids[vid]))
    if vid and vid ~= "" then
        if api and api.invalidate_playlist_cache then
            api.invalidate_playlist_cache("VLLM")
        end
        if state.liked_ids[vid] then
            state.liked_ids[vid] = nil
            log("toggle_like: unliking vid=" .. tostring(vid))
            store.publish()
            if api and api.unlike_video then
                api.unlike_video(vid, function(ok) end)
            end
        else
            state.liked_ids[vid] = true
            log("toggle_like: liking vid=" .. tostring(vid))
            store.publish()
            if api and api.like_video then
                api.like_video(vid, function(ok) end)
            end
        end
    end
end

return Library