local schema = require("../utils/schema.luau")

local STATE_KEY = "yt_music.state"

-- Service-side singleton state. Only the service (and its domain modules)
-- require this; the panel uses schema.new() for its own read-only view.
local Store = {}
Store.state = schema.new()
Store.state.player.volume = 100

function Store.publish()
    local snap = {}
    local next_nonce = ((Store.state.nonce or 0) + 1)
    Store.state.nonce = next_nonce
    snap.nonce = next_nonce
    for k, v in pairs(Store.state) do snap[k] = v end
    -- Only shallow-copy the actively-mutated tables (player, playlist)
    if type(Store.state.player) == "table" then
        snap.player = {}
        for k, v in pairs(Store.state.player) do snap.player[k] = v end
    end
    if type(Store.state.playlist) == "table" then
        snap.playlist = {}
        for k, v in pairs(Store.state.playlist) do snap.playlist[k] = v end
    end
    if type(Store.state.quick_picks) == "table" then
        snap.quick_picks = {}
        for k, v in pairs(Store.state.quick_picks) do snap.quick_picks[k] = v end
    end
    if type(Store.state.home_mixes) == "table" then
        snap.home_mixes = {}
        for k, v in pairs(Store.state.home_mixes) do snap.home_mixes[k] = v end
    end
    if type(Store.state.search) == "table" then
        snap.search = {}
        for k, v in pairs(Store.state.search) do snap.search[k] = v end
    end
    snap.liked_ids = Store.state.liked_ids
    snap.cached_audio_ids = Store.state.cached_audio_ids
    snap.downloaded_playlist_ids = Store.state.downloaded_playlist_ids
    snap.offline_tracks = Store.state.offline_tracks
    snap.recent_playlists = Store.state.recent_playlists
    snap.settings = Store.state.settings
    noctalia.state.set(STATE_KEY, snap)
end

return Store