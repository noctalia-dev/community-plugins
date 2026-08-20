local schema = require("../utils/schema.luau")

local STATE_KEY = "noctalia_ytmusic.state"

-- Service-side singleton state. Only the service (and its domain modules)
-- require this; the panel uses schema.new() for its own read-only view.
local Store = {}
Store.state = schema.new()
Store.state.player.volume = 100

function Store.publish()
    local snap = {}
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
    -- Pass direct references for large, rarely-changing lookup tables
    snap.liked_ids = Store.state.liked_ids
    snap.cached_audio_ids = Store.state.cached_audio_ids
    snap.downloaded_playlist_ids = Store.state.downloaded_playlist_ids
    snap.quick_picks = Store.state.quick_picks
    snap.home_mixes = Store.state.home_mixes
    snap.recent_playlists = Store.state.recent_playlists
    snap.cache_stats = Store.state.cache_stats
    snap.settings = Store.state.settings
    noctalia.state.set(STATE_KEY, snap)
end

return Store