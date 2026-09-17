--!strict

-- Track stats (views/likes) fetched via yt-dlp, cached in a single JSON file.

local logger = require("../utils/log.luau")
local network = require("../utils/network.luau")
local log = logger.module("ytapi", "stats")

local const = require("./constants.luau")
local STATS_CACHE_PATH = const.STATS_CACHE_PATH

local STATS_TTL = 24 * 3600

local EXPO = {}

local stats_cache = {}
local stats_in_flight = {}
local cache_loaded = false

local function load_cache()
    if cache_loaded then return end
    cache_loaded = true
    if not noctalia.fileExists(STATS_CACHE_PATH) then return end
    local raw = noctalia.readFile(STATS_CACHE_PATH)
    local data = raw and noctalia.json.decode(raw)
    if type(data) ~= "table" then return end
    for id, entry in pairs(data) do
        if type(id) == "string" and type(entry) == "table" then
            stats_cache[id] = {
                views = tonumber(entry.views) or 0,
                likes = tonumber(entry.likes) or 0,
                timestamp = tonumber(entry.fetched) or 0,
            }
        end
    end
end

local function save_cache()
    local data = {}
    local now = os.time()
    for id, entry in pairs(stats_cache) do
        if (now - entry.timestamp) < STATS_TTL then
            data[id] = { views = entry.views, likes = entry.likes, fetched = entry.timestamp }
        else
            stats_cache[id] = nil
        end
    end
    local encoded = noctalia.json.encode(data)
    if encoded then
        noctalia.writeFile(STATS_CACHE_PATH, encoded)
    end
end

function EXPO.track_stats(video_id: string, cb: ((number, number) -> ())?)
    if type(video_id) ~= "string" or video_id == "" then
        if cb then cb(0, 0) end
        return
    end

    load_cache()

    local cached = stats_cache[video_id]
    if cached and (os.time() - cached.timestamp) < STATS_TTL then
        if cb then cb(cached.views, cached.likes) end
        return
    end

    if stats_in_flight[video_id] then
        table.insert(stats_in_flight[video_id], cb)
        return
    end
    stats_in_flight[video_id] = { cb }

    local safe_id = video_id:gsub("[^%w%-_]", "_")
    local script = ([=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
OUT="${XDG_CACHE_HOME:-$HOME/.cache}/yt-music/cookies.txt"
[ -s "$OUT" ] || { echo "NOCACHE=1"; exit 0; }
LINE=$(yt-dlp --skip-download --no-playlist --no-warnings --cookies "$OUT" --print "%(view_count)s|%(like_count)s" "https://www.youtube.com/watch?v=VIDEO" 2>/dev/null | tail -1)
VIEWS=$(printf '%s' "$LINE" | cut -d'|' -f1)
LIKES=$(printf '%s' "$LINE" | cut -d'|' -f2)
case "$VIEWS" in
  ''|*[!0-9]*) VIEWS=0;;
esac
case "$LIKES" in
  ''|*[!0-9]*) LIKES=0;;
esac
echo "STATS=$VIEWS|$LIKES"
]=]):gsub("VIDEO", safe_id)

    network.runAsync(script, function(res)
        local out = type(res) == "table" and res.stdout or ""
        local views_likes = out:match("STATS=([%d|]+)")
        local views = 0
        local likes = 0
        if views_likes then
            local v, l = views_likes:match("^(%d*)|(%d*)$")
            views = tonumber(v) or 0
            likes = tonumber(l) or 0
        end
        log("stats fetched for id=" .. video_id .. " views=" .. views .. " likes=" .. likes)
        stats_cache[video_id] = { views = views, likes = likes, timestamp = os.time() }
        save_cache()
        local callbacks = stats_in_flight[video_id] or {}
        stats_in_flight[video_id] = nil
        for _, callback in ipairs(callbacks) do
            if callback then callback(views, likes) end
        end
    end, 30000)
end

return EXPO
