local Player = {}

local store = require("./store.luau")
local api = require("../api.luau")
local logger = require("../utils/log.luau")
local mpv = require("./mpv.luau")

local state = store.state
local log = logger.module("ytm", "player")

local publish = store.publish

local stream_generation = 0
local start_stream

local function player_set(item, stream_url)
    state.player.title = item.title or "Unknown track"
    state.player.artist = item.artist or ""
    state.player.id = item.id or ""
    local thumb_url = item.thumbnail_url or (item.id and ("https://i.ytimg.com/vi/" .. item.id .. "/hqdefault.jpg") or nil)
    state.player.thumbnail_url = thumb_url
    state.player.thumb_path = item.thumb_path or (api and api.get_thumbnail_path and api.get_thumbnail_path(item.id, thumb_url, nil) or nil)
    state.player.duration = tonumber(item.duration) or 0
    state.player.status = "playing"
    state.player.position = 0
    state.player.codec_fetched = false
    state.player.bitrate = nil
    state.player.codec = nil
    state.player.samplerate = nil
    state.player.views = 0
    state.player.likes = 0
    state.search.pending = false

    if api and api.track_stats and item.id and item.id ~= "" then
        api.track_stats(item.id, function(views, likes)
            state.player.views = views or 0
            state.player.likes = likes or 0
            publish()
        end)
    end

    local title = item.title or "Unknown track"
    if item.artist and item.artist ~= "" then
        title = item.title .. " - " .. item.artist
    end
    noctalia.writeFile("/tmp/noctalia-ytmusic-title.txt", title)

    if api and api.cache_audio and item.id and item.id ~= "" then
        api.cache_audio(item.id)
    end

    mpv.play(stream_url, state.player.volume, function(ready)
        if ready then start_stream() end
    end)
    if api and api.save_session then
        noctalia.runAsync("true", function()
            api.save_session(state.player)
        end)
    end
    publish()
end

function Player.play_index(index, queue)
    queue = queue or state.player.queue
    if #queue == 0 then return end
    index = math.max(1, math.min(index, #queue))
    state.player.queue = queue
    state.player.index = index
    local item = queue[index]
    mpv.send((noctalia.json.encode({ command = { "set_property", "pause", true } })))
    state.player.id = item.id or ""
    state.player.title = item.title or "Loading track..."
    state.player.artist = item.artist or ""
    state.player.thumbnail_url = item.thumbnail_url
    state.player.thumb_path = item.thumb_path or (api and api.get_thumbnail_path and api.get_thumbnail_path(item.id, item.thumbnail_url, nil) or nil)
    state.player.duration = tonumber(item.duration) or 0
    state.player.position = 0
    state.player.status = "loading"
    publish()

    if api and api.ensure_thumbnails then
        noctalia.runAsync("true", function()
            api.ensure_thumbnails(state.player.queue, publish, "queue")
        end)
    end
    log("play_index: " .. index .. "/" .. #queue .. " id=" .. tostring(item.id) .. " title='" .. tostring(item.title) .. "'")

    if api and api.prefetch_queue then
        api.prefetch_queue(queue, index)
    elseif api and api.prefetch_track then
        if queue[index + 1] then api.prefetch_track(queue[index + 1]) end
        if queue[index + 2] then api.prefetch_track(queue[index + 2]) end
    end

    api.resolve_stream(item.id, function(url)
        if not url or url == "" then
            state.player.status = "stopped"
            state.status_text = "Could not resolve stream for " .. tostring(item.title)
            publish()
            log("play_index: stream resolve FAILED for '" .. tostring(item.title) .. "'")
            return
        end
        log("play_index: stream resolved (" .. #url .. " chars), dispatching to mpv")
        player_set(item, url)
    end)
end

function Player.play(item)
    table.insert(state.player.queue, {
        id = item.id,
        title = item.title,
        artist = item.artist or "",
        duration = tonumber(item.duration) or 0,
        thumbnail_url = item.thumbnail_url,
        thumb_path = item.thumb_path
    })
    Player.play_index(#state.player.queue)
end

function Player.play_next(item)
    if not item or not item.id or item.id == "" then return end
    local insert_at
    if state.player.index > 0 and #state.player.queue > 0 then
        insert_at = math.min(state.player.index + 1, #state.player.queue + 1)
    else
        insert_at = #state.player.queue + 1
    end
    table.insert(state.player.queue, insert_at, {
        id = item.id,
        title = item.title,
        artist = item.artist or "",
        duration = tonumber(item.duration) or 0,
        thumbnail_url = item.thumbnail_url,
        thumb_path = item.thumb_path
    })
    log("play_next: inserted '" .. tostring(item.title) .. "' at queue position " .. insert_at)
    if state.player.status == "stopped" then
        Player.play_index(insert_at)
    else
        publish()
    end
end

function Player.stop()
    mpv.kill()
    state.player.status = "stopped"
    state.player.queue = {}
    state.player.index = 0
    state.player.title = ""
    state.player.artist = ""
    state.player.position = 0
    state.player.duration = 0
    publish()
end

function Player.toggle()
    if state.player.status == "playing" then
        mpv.send((noctalia.json.encode({ command = { "set_property", "pause", true } })))
        state.player.status = "paused"
        publish()
    elseif state.player.status == "paused" then
        noctalia.runAsync([[
            SOCK="${XDG_RUNTIME_DIR:-/tmp}/noctalia-ytmusic-mpv.sock"
            [ -S "$SOCK" ] && echo "YES" || echo "NO"
        ]], function(res)
            if res and res.stdout and res.stdout:find("YES") then
                mpv.send((noctalia.json.encode({ command = { "set_property", "pause", false } })))
                state.player.status = "playing"
                publish()
            else
                if #state.player.queue > 0 then
                    local idx = state.player.index > 0 and state.player.index or 1
                    Player.play_index(idx)
                elseif state.player.id and state.player.id ~= "" then
                    Player.play(state.player)
                end
            end
        end)
    elseif state.player.status == "stopped" or state.player.status == "idle" then
        if #state.player.queue > 0 then
            local idx = state.player.index > 0 and state.player.index or 1
            Player.play_index(idx)
        elseif state.player.id and state.player.id ~= "" then
            Player.play(state.player)
        end
    end
end

function Player.next(is_natural_end)
    if #state.player.queue == 0 then return end

    if is_natural_end and state.player.repeat_mode == "one" then
        log("next: repeat_mode=one, looping track id=" .. tostring(state.player.id))
        mpv.send((noctalia.json.encode({ command = { "set_property", "pause", false } })))
        mpv.send((noctalia.json.encode({ command = { "seek", 0, "absolute" } })))
        state.player.position = 0
        state.player.status = "playing"
        publish()
        return
    end

    if state.player.shuffle and #state.player.queue > 1 then
        math.randomseed(os.time())
        local rand_idx = math.random(1, #state.player.queue)
        if rand_idx == state.player.index then
            rand_idx = (rand_idx % #state.player.queue) + 1
        end
        Player.play_index(rand_idx)
        return
    end

    local next_idx = state.player.index + 1
    if next_idx > #state.player.queue then
        if state.player.repeat_mode == "all" then
            next_idx = 1
        else
            state.player.status = "stopped"
            publish()
            return
        end
    end
    Player.play_index(next_idx)
end

function Player.prev()
    if #state.player.queue == 0 then return end
    if state.player.position > 3 then
        mpv.send((noctalia.json.encode({ command = { "seek", 0, "absolute" } })))
        state.player.position = 0
        publish()
    else
        local prev_idx = state.player.index - 1
        if prev_idx < 1 then
            prev_idx = #state.player.queue
        end
        Player.play_index(prev_idx)
    end
end

function Player.seek(seconds)
    local val = tonumber(seconds)
    if not val then return end
    local dur = tonumber(state.player.duration) or 0
    local sec = val
    if dur > 1 and val >= 0 and val <= 1.0 then
        sec = val * dur
    end
    if dur > 0 then
        sec = math.max(0, math.min(sec, dur))
    else
        sec = math.max(0, sec)
    end
    log("seek: raw=" .. tostring(seconds) .. " resolved=" .. tostring(sec) .. " dur=" .. tostring(dur))
    state.player.position = sec
    publish()
    mpv.send((noctalia.json.encode({ command = { "seek", sec, "absolute" } })))
end

function Player.volume(value)
    value = tonumber(value) or 100
    state.player.volume = math.max(0, math.min(100, value))
    if state.player.volume > 0 then
        state.player.last_volume = state.player.volume
    end
    mpv.send((noctalia.json.encode({ command = { "set_property", "volume", state.player.volume } })))
    publish()
end

function Player.mute()
    if (state.player.volume or 0) > 0 then
        state.player.last_volume = state.player.volume
        Player.volume(0)
    else
        Player.volume(state.player.last_volume or 70)
    end
end

function Player.toggle_shuffle()
    state.player.shuffle = not state.player.shuffle
    log("toggle_shuffle: " .. tostring(state.player.shuffle))
    publish()
end

function Player.cycle_repeat()
    local current = state.player.repeat_mode or "off"
    if current == "off" then
        state.player.repeat_mode = "all"
    elseif current == "all" then
        state.player.repeat_mode = "one"
    else
        state.player.repeat_mode = "off"
    end
    log("cycle_repeat: " .. tostring(state.player.repeat_mode))
    publish()
end

function Player.append_to_queue(track)
    table.insert(state.player.queue, track)
end

function Player.restore_session(sess)
    state.player.id = sess.id
    state.player.title = sess.title or ""
    state.player.artist = sess.artist or ""
    state.player.thumbnail_url = sess.thumbnail_url
    state.player.thumb_path = sess.thumb_path
    state.player.duration = sess.duration or 0
    state.player.position = sess.position or 0
    state.player.volume = sess.volume or 70
    state.player.index = sess.index or 0
    state.player.queue = type(sess.queue) == "table" and sess.queue or {}
    state.player.status = "paused"
    log("session restored: '" .. state.player.title .. "' queue=" .. #state.player.queue)
    if api and api.track_stats and sess.id and sess.id ~= "" then
        api.track_stats(sess.id, function(views, likes)
            state.player.views = views or 0
            state.player.likes = likes or 0
            publish()
        end)
    end
end

-- One push stream per mpv instance, launched when mpv_play reports READY.
-- Tracks a generation so lines from an old stream (mpv was killed mid switch,
-- socket lingers ~1s) are dropped the moment a newer stream takes over.
local function handle_stream_line(line)
    if not line or line == "" then return end
    local data = noctalia.json.decode(line)
    if type(data) ~= "table" then return end

    if data.event ~= "property-change" then
        if data.request_id == 100 then
            local pos = tonumber(data.data)
            if pos and state.player.status ~= "loading" and state.player.status ~= "stopped"
                and pos ~= state.player.position then
                state.player.position = pos
                publish()
            end
        elseif data.request_id == 200 then
            local v = tonumber(data.data)
            if v and v ~= state.player.bitrate then
                state.player.bitrate = v
                state.player.codec_fetched = true
                publish()
            end
        end
        return
    end

    local name = data.name
    if name == "eof-reached" then
        local st = state.player.status
        if data.data == true and (st == "playing" or st == "paused") then
            log("stream: eof-reached -> next(true)")
            Player.next(true)
        end
        return
    end
    if name == "pause" then
        if state.player.status == "loading" or state.player.status == "stopped" then return end
        local paused = (data.data == true)
        if paused and state.player.status == "playing" then
            state.player.status = "paused"
            publish()
        elseif not paused and state.player.status == "paused" then
            state.player.status = "playing"
            publish()
        end
    elseif name == "duration" then
        local d = tonumber(data.data)
        if d and d > 0 and d ~= state.player.duration then
            state.player.duration = d
            publish()
        end
    else
        local changed = false
        if name == "audio-codec-name" then
            local v = data.data
            if v and v ~= state.player.codec then
                state.player.codec = v
                changed = true
            end
        elseif name == "audio-params/samplerate" then
            local v = tonumber(data.data)
            if v and v ~= state.player.samplerate then
                state.player.samplerate = v
                changed = true
            end
        end
        if changed then
            state.player.codec_fetched = true
            publish()
        end
    end
end

start_stream = function()
    stream_generation = stream_generation + 1
    local gen = stream_generation
    mpv.stream(function(line)
        if stream_generation ~= gen then return end
        handle_stream_line(line)
    end)
end

return Player