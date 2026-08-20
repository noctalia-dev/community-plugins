--!strict

-- stream resolution, audio download/cache, track stats, prefetch.

local logger = require("../utils/log.luau")
local log = logger.module("ytapi", "resolve")

local const = require("./constants.luau")
local COOKIE_PATH = const.COOKIE_PATH
local STREAMS_CACHE_DIR = const.STREAMS_CACHE_DIR
local AUDIO_DIR = const.AUDIO_DIR

local thumbs = require("./thumbnails.luau")
local get_thumbnail_path = thumbs.get_thumbnail_path

local types = require("../utils/types.luau")

local RESOLVE_SCRIPT = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
OUT="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-ytmusic/cookies.txt"
CACHE_FILE="]=] .. STREAMS_CACHE_DIR .. [=[/VIDEO.url"
if [ -s "$CACHE_FILE" ]; then
  URL=$(cat "$CACHE_FILE")
  if [ -n "$URL" ]; then
    echo "URL=$URL"
    exit 0
  fi
fi

[ -s "$OUT" ] || { echo "NOCACHE=1"; exit 0; }
URL=$(yt-dlp -f bestaudio/best -g --no-playlist --no-warnings --cookies "$OUT" "https://www.youtube.com/watch?v=VIDEO" 2>/dev/null | tail -1)
if [ -n "$URL" ]; then
  mkdir -p "]=] .. STREAMS_CACHE_DIR .. [=["
  echo "$URL" > "$CACHE_FILE"
  echo "URL=$URL"
else
  echo "ERR=1"
fi
]=]

local function sanitize_str(str)
    if type(str) ~= "string" then return "" end
    return (str:gsub("[^\32-\126]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local EXPO = {}

local stream_cache = {}
local prefetching_ids = {}
local resolving_in_flight = {}

function EXPO.get_audio_cache_path(video_id: string): string?
    if type(video_id) ~= "string" or video_id == "" then return nil end
    local safe_id = video_id:gsub("[^%w%-_]", "_")
    local path = AUDIO_DIR .. "/" .. safe_id .. ".opus"
    if noctalia.fileExists(path) then
        return path
    end
    return nil
end

function EXPO.get_cached_audio_ids(callback)
    local cmd = string.format("mkdir -p '%s' && ls '%s' 2>/dev/null", AUDIO_DIR, AUDIO_DIR)
    noctalia.runAsync(cmd, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local set = {}
        for id in out:gmatch("([%w%-_]+)%.opus") do
            set[id] = true
        end
        if callback then callback(set) end
    end, 5000)
end

function EXPO.cache_audio(video_id, callback)
    if type(video_id) ~= "string" or video_id == "" then
        if callback then callback(false) end
        return
    end
    local safe_id = video_id:gsub("[^%w%-_]", "_")
    local path = AUDIO_DIR .. "/" .. safe_id .. ".opus"
    if noctalia.fileExists(path) then
        if callback then callback(true) end
        return
    end

    local cmd = string.format(
        "mkdir -p '%s' && export PATH=\"/etc/profiles/per-user/$USER/bin:$PATH\" && yt-dlp -f bestaudio -o '%s' --cookies '%s' 'https://www.youtube.com/watch?v=%s' >/dev/null 2>&1 && echo 'STATUS=OK'",
        AUDIO_DIR, path, COOKIE_PATH, video_id
    )
    local launched = noctalia.runAsync(cmd, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local ok = noctalia.fileExists(path) or out:find("STATUS=OK") ~= nil
        if callback then callback(ok) end
    end, 120000)
    if not launched and callback then
        callback(false)
    end
end

function EXPO.resolve_stream(video_id: string, cb: ((string?) -> ())?)
    if type(video_id) ~= "string" or video_id == "" then
        if cb then cb(nil) end
        return
    end

    local local_audio = EXPO.get_audio_cache_path(video_id)
    if local_audio then
        log("audio_disk_cache HIT for id=" .. video_id)
        if cb then cb(local_audio) end
        return
    end

    local cached = stream_cache[video_id]
    if cached and (os.time() - cached.timestamp) < 14400 then
        log("stream_cache HIT for id=" .. video_id)
        if cb then cb(cached.url) end
        return
    end

    local safe_id = video_id:gsub("[^%w%-_]", "_")
    local disk_url_path = STREAMS_CACHE_DIR .. "/" .. safe_id .. ".url"
    if noctalia.fileExists(disk_url_path) then
        local raw_disk = noctalia.readFile(disk_url_path)
        if raw_disk and #raw_disk > 20 then
            local clean_url = sanitize_str(raw_disk)
            stream_cache[video_id] = { url = clean_url, timestamp = os.time() }
            log("stream_disk_cache HIT for id=" .. video_id)
            if cb then cb(clean_url) end
            return
        end
    end

    if resolving_in_flight[video_id] then
        table.insert(resolving_in_flight[video_id], cb)
        return
    end

    resolving_in_flight[video_id] = { cb }

    log("resolving stream URL for id=" .. video_id)
    local script = RESOLVE_SCRIPT:gsub("VIDEO", safe_id)
    noctalia.runAsync(script, function(res)
        local out = type(res) == "table" and res.stdout or ""
        local raw_url = out:match("URL=([^\n\r]+)")
        local url = sanitize_str(raw_url)
        local callbacks = resolving_in_flight[video_id] or {}
        resolving_in_flight[video_id] = nil

        if url ~= "" then
            log("stream resolved successfully (" .. #url .. " bytes) for id=" .. video_id)
            stream_cache[video_id] = { url = url, timestamp = os.time() }
            for _, callback in ipairs(callbacks) do
                if callback then callback(url) end
            end
        else
            log("stream resolution failed for id=" .. video_id)
            for _, callback in ipairs(callbacks) do
                if callback then callback(nil) end
            end
        end
    end, 30000)
end

function EXPO.prefetch_track(item: types.Track)
    if type(item) ~= "table" or not item.id or item.id == "" then return end
    local id = item.id

    if item.thumbnail_url or id ~= "" then
        local url = item.thumbnail_url or ("https://i.ytimg.com/vi/" .. id .. "/hqdefault.jpg")
        get_thumbnail_path(id, url, nil)
    end

    if EXPO.get_audio_cache_path(id) then return end

    local cached = stream_cache[id]
    if not cached or (os.time() - cached.timestamp) >= 7200 then
        prefetching_ids[id] = true
        log("prefetching stream URL into memory for id=" .. id)
        EXPO.resolve_stream(id, function()
            prefetching_ids[id] = nil
        end)
    end
end

function EXPO.prefetch_queue(queue: { types.Track }, current_index)
    if type(queue) ~= "table" or #queue == 0 then return end
    current_index = current_index or 1
    -- Only prefetch 1 track ahead to prevent thread pool exhaustion and UI freezing
    for offset = 1, 1 do
        local target = queue[current_index + offset]
        if target and target.id and target.id ~= "" then
            EXPO.prefetch_track(target)
        end
    end
end

return EXPO