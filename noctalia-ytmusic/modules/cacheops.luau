local store = require("./store.luau")

local state = store.state

-- du -sh output -> { name = size }
local function parse_stats(res)
    if type(res) ~= "table" or not res.stdout then return end
    local stats = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
        local size, path = line:match("([^|]+)|(.+)")
        if size and path then
            local name = path:match("([^/]+)$")
            if name then
                stats[name] = size
            end
        end
    end
    state.cache_stats = stats
    store.publish()
end

local STATS_SCRIPT = [[
    CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic"
    [ -d "$CACHE" ] || exit 0
    du -sh "$CACHE"/audio "$CACHE"/streams "$CACHE"/thumbnails "$CACHE"/playlists 2>/dev/null | awk '{print $1"|"$2}'
]]

local Cache = {}

function Cache.fetch_stats()
    noctalia.runAsync(STATS_SCRIPT, parse_stats)
end

function Cache.clear(target)
    if not target then return end
    noctalia.runAsync(([[
        CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic"
        rm -rf "$CACHE/%s"/*
    ]]):format(target), function()
        -- After clearing, fetch the stats directly
        noctalia.runAsync(STATS_SCRIPT, parse_stats)
    end)
end

return Cache