local Player = {}

local store = require("./store.luau")
local api = require("../api.luau")
local logger = require("../utils/log.luau")
local mpv = require("./mpv.luau")

local state = store.state
local log = logger.module("ytm", "player")

local publish = store.publish

local stream_generation = 0

-- Original insertion order kept while shuffling so toggling shuffle OFF can
-- restore it. Module-local on purpose: never published to the UI snapshot or
-- saved into the session.
local original_queue = nil

-- Last click wins: bumped on every explicit play request so stream-resolve
-- responses from earlier rapid clicks are recognised as stale and dropped
-- instead of hijacking playback when they finally arrive.
local play_generation = 0
local start_stream

-- Coalesced manual skips: rapid next/prev presses accumulate into
-- pending_steps and fire once the burst settles, so intermediate songs never
-- audibly start — only the final landing resolves and plays.
local pending_steps = 0
local skip_nonce = 0
local firing_debounce = false
local queue_skip -- forward: Player.next/prev coalesce through this, defined below

-- Last click wins, structurally: when a new intent supersedes a still-loading
-- one, the older yt-dlp stream-resolves are already useless (the generation
-- guard would drop their results) but still hold spawn slots the final song
-- needs. Kill them before spawning the new fetch. The pattern matches ONLY
-- stream resolves (-f bestaudio/best -g); audio downloads use -f bestaudio -o
-- and are untouched. The -[g] bracket form keeps pkill from matching its own
-- command line.
local function kill_stale_resolves(done)
	local scheduled = noctalia.runAsync("pkill -f 'bestaudio/best -[g]' 2>/dev/null; true", function()
		if done then
			done()
		end
	end, 2000)
	if not scheduled and done then
		done()
	end
end

local function player_set(item, stream_url)
	state.player.title = item.title or "Unknown track"
	state.player.artist = item.artist or ""
	state.player.id = item.id or ""
	local thumb_url = item.thumbnail_url
		or (item.id and ("https://i.ytimg.com/vi/" .. item.id .. "/hqdefault.jpg") or nil)
	state.player.thumbnail_url = thumb_url
	state.player.thumb_path = item.thumb_path
		or (api and api.get_thumbnail_path and api.get_thumbnail_path(item.id, thumb_url, nil) or nil)
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

	-- Stats responses can outlive the click that started them; drop any that
	-- arrive after a newer play intent so old counts never flash on screen.
	local gen = play_generation
	if api and api.track_stats and item.id and item.id ~= "" then
		api.track_stats(item.id, function(views, likes)
			if gen ~= play_generation then
				return
			end
			state.player.views = views or 0
			state.player.likes = likes or 0
			publish()
		end)
	end

	local title = item.title or "Unknown track"
	if item.artist and item.artist ~= "" then
		title = item.title .. " - " .. item.artist
	end

	if api and api.cache_audio and item.id and item.id ~= "" then
		api.cache_audio(item.id, function(ok)
			-- Keep the tick/bolt state honest right away instead of waiting
			-- for the next boot-time directory scan.
			if ok and not state.cached_audio_ids[item.id] then
				state.cached_audio_ids[item.id] = true
				publish()
			end
		end)
	end

	mpv.play(stream_url, title, state.player.volume, function(ready)
		if ready then
			start_stream()
		end
	end)
	-- Speculative work happens only for settled playback: the song that
	-- actually starts earns its next-track prefetch and queue thumbnails.
	-- Skipped-over intents never get here, so rapid skipping spawns nothing
	-- but one kill + one resolve per click.
	if api and api.prefetch_queue then
		api.prefetch_queue(state.player.queue, state.player.index)
	elseif api and api.prefetch_track then
		local q = state.player.queue
		local idx = state.player.index
		if q[idx + 1] then
			api.prefetch_track(q[idx + 1])
		end
		if q[idx + 2] then
			api.prefetch_track(q[idx + 2])
		end
	end
	if api and api.ensure_thumbnails then
		noctalia.runAsync("true", function()
			api.ensure_thumbnails(state.player.queue, publish, "queue")
		end)
	end
	if api and api.save_session then
		noctalia.runAsync("true", function()
			api.save_session(state.player)
		end)
	end
	publish()
end

-- Offline mode helpers: first index whose audio exists locally.
--   pick_playable_forward — start..end, no wrap (repeat off/one)
--   pick_playable_cycle   — full cycle incl. wrap (repeat all)
-- Return the index plus how many entries were skipped, or nil when none.
local function pick_playable_forward(start_idx, queue)
	for idx = start_idx, #queue do
		local t = queue[idx]
		if t and t.id and api.get_audio_cache_path(t.id) then
			return idx, idx - start_idx
		end
	end
	return nil, math.max(0, #queue - start_idx + 1)
end

local function pick_playable_cycle(start_idx, queue)
	local n = #queue
	for offset = 0, n - 1 do
		local idx = ((start_idx - 1 + offset) % n) + 1
		local t = queue[idx]
		if t and t.id and api.get_audio_cache_path(t.id) then
			return idx, offset
		end
	end
	return nil, n
end

function Player.play_index(index, queue)
	queue = queue or state.player.queue
	if #queue == 0 then
		return
	end
	if not firing_debounce then
		-- Any direct play voids queued-up manual skips: they were aimed at
		-- whatever was current before this intent (clicks, play-now, resume,
		-- natural advance).
		skip_nonce = skip_nonce + 1
		pending_steps = 0
	end
	if queue ~= state.player.queue then
		original_queue = nil
	end

	-- A new intent while the previous one is still loading supersedes it: the
	-- older fetches are dead weight and the skipped songs earn no prefetch or
	-- thumbnails — only the song we land on gets work done.
	local superseding = (state.player.status == "loading")
	-- Any new play intent invalidates every in-flight resolve before it.
	play_generation = play_generation + 1
	local gen = play_generation

	-- When offline, silently jump past undownloaded entries (covers natural
	-- advance, manual next/prev and clicks into partial playlists). Repeat
	-- all may wrap to earlier tracks; any other mode stops at queue end.
	local skipped_offline = 0
	if not state.online and api and api.get_audio_cache_path then
		local eff, skipped
		if state.player.repeat_mode == "all" then
			eff, skipped = pick_playable_cycle(index, queue)
		else
			eff, skipped = pick_playable_forward(index, queue)
		end
		if not eff then
			mpv.kill()
			state.player.status = "stopped"
			if state.player.repeat_mode == "all" then
				state.status_text = "Offline: no downloaded tracks to play"
				noctalia.notify("YouTube Music", "Nothing downloaded to play offline")
			else
				state.status_text = "Offline: reached end of downloaded tracks"
				noctalia.notify("YouTube Music", "Reached end of downloaded tracks")
			end
			publish()
			return
		end
		index = eff
		skipped_offline = skipped
	end

	index = math.max(1, math.min(index, #queue))
	state.player.queue = queue
	state.player.index = index
	local item = queue[index]
	if not superseding then
		-- Silence the outgoing track. Skipped when superseding: the previous
		-- intent already sent exactly one of these, and piled-up delayed
		-- copies are what used to pause the final song after it started.
		mpv.send((noctalia.json.encode({ command = { "set_property", "pause", true } })))
	end
	state.player.id = item.id or ""
	state.player.title = item.title or "Loading track..."
	state.player.artist = item.artist or ""
	state.player.thumbnail_url = item.thumbnail_url
	state.player.thumb_path = item.thumb_path
		or (api and api.get_thumbnail_path and api.get_thumbnail_path(item.id, item.thumbnail_url, nil) or nil)
	state.player.duration = tonumber(item.duration) or 0
	state.player.position = 0
	-- Clear previous song's stats at click time, not on resolve.
	state.player.views = 0
	state.player.likes = 0
	state.player.status = "loading"
	publish()

	if skipped_offline > 0 then
		noctalia.notify("Offline mode", "Skipped " .. skipped_offline .. " undownloaded track(s)")
	end

	log(
		"play_index: "
			.. index
			.. "/"
			.. #queue
			.. " id="
			.. tostring(item.id)
			.. " title='"
			.. tostring(item.title)
			.. "'"
	)

	local function on_resolved(url)
		if gen ~= play_generation then
			log(
				"play_index: dropped stale stream response (gen "
					.. gen
					.. " < "
					.. play_generation
					.. ") for '"
					.. tostring(item.title)
					.. "'"
			)
			return
		end
		if not url or url == "" then
			state.player.status = "stopped"
			state.status_text = "Could not resolve stream for " .. tostring(item.title)
			publish()
			log("play_index: stream resolve FAILED for '" .. tostring(item.title) .. "'")
			return
		end
		log("play_index: stream resolved (" .. #url .. " chars), dispatching to mpv")
		player_set(item, url)
	end

	if superseding then
		-- Newest intent's fetch spawns only after the stale ones are dead, so
		-- a saturated pool can never refuse the song we actually land on.
		kill_stale_resolves(function()
			api.resolve_stream(item.id, on_resolved)
		end)
	else
		api.resolve_stream(item.id, on_resolved)
	end
end

function Player.play(item)
	local n = #state.player.queue
	-- Rapid re-clicks while the tail entry is still loading swap it out
	-- instead of stacking duplicates; last click always owns that slot.
	if state.player.status == "loading" and n > 0 and state.player.index == n then
		state.player.queue[n] = {
			id = item.id,
			title = item.title,
			artist = item.artist or "",
			duration = tonumber(item.duration) or 0,
			thumbnail_url = item.thumbnail_url,
			thumb_path = item.thumb_path,
		}
		Player.play_index(n)
		return
	end
	table.insert(state.player.queue, {
		id = item.id,
		title = item.title,
		artist = item.artist or "",
		duration = tonumber(item.duration) or 0,
		thumbnail_url = item.thumbnail_url,
		thumb_path = item.thumb_path,
	})
	Player.play_index(#state.player.queue)
end

function Player.play_next(item)
	if not item or not item.id or item.id == "" then
		return
	end
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
		thumb_path = item.thumb_path,
	})
	log("play_next: inserted '" .. tostring(item.title) .. "' at queue position " .. insert_at)
	if state.player.status == "stopped" then
		Player.play_index(insert_at)
	else
		publish()
	end
end

-- Play immediately while preserving the upcoming queue: the suggestion slots
-- in right after the current track and starts, so everything queued below
-- keeps its order.
function Player.play_now(item)
	if not item or not item.id or item.id == "" then
		return
	end
	local insert_at = 1
	if state.player.status ~= "stopped" and #state.player.queue > 0 then
		insert_at = math.min((state.player.index or 0) + 1, #state.player.queue + 1)
	end
	table.insert(state.player.queue, insert_at, {
		id = item.id,
		title = item.title,
		artist = item.artist or "",
		duration = tonumber(item.duration) or 0,
		thumbnail_url = item.thumbnail_url,
		thumb_path = item.thumb_path,
	})
	log("play_now: inserted '" .. tostring(item.title) .. "' at queue position " .. insert_at)
	Player.play_index(insert_at)
end

function Player.stop()
	mpv.kill()
	state.player.status = "stopped"
	state.player.queue = {}
	original_queue = nil
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
		noctalia.runAsync(
			[[
            SOCK="/tmp/yt-music/mpv.sock"
            [ -S "$SOCK" ] && echo "YES" || echo "NO"
        ]],
			function(res)
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
			end
		)
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
	if #state.player.queue == 0 then
		return
	end

	if is_natural_end and state.player.repeat_mode == "one" then
		log("next: repeat_mode=one, looping track id=" .. tostring(state.player.id))
		mpv.send((noctalia.json.encode({ command = { "set_property", "pause", false } })))
		mpv.send((noctalia.json.encode({ command = { "seek", 0, "absolute" } })))
		state.player.position = 0
		state.player.status = "playing"
		publish()
		return
	end

	-- With shuffle on the queue is physically reordered by toggle_shuffle,
	-- so a plain sequential advance IS the shuffled order.
	queue_skip(1)
end

-- Walk the accumulated manual steps in one go and resolve+play only the
-- landing: no intermediate player_set, so skipped-over songs (even cached
-- ones) never become audible.
local function advance_steps()
	local steps = pending_steps
	pending_steps = 0
	if steps == 0 then
		return
	end
	local n = #state.player.queue
	if n == 0 then
		return
	end
	local idx = state.player.index
	local dir = steps > 0 and 1 or -1
	for _ = 1, math.abs(steps) do
		idx = idx + dir
		if idx > n then
			if state.player.repeat_mode == "all" then
				idx = 1
			else
				-- Past the end without repeat-all: stop, like a single
				-- next at the tail would.
				state.player.status = "stopped"
				publish()
				return
			end
		elseif idx < 1 then
			idx = n
		end
	end
	firing_debounce = true
	Player.play_index(idx)
	firing_debounce = false
end

-- Each press within the window replaces the previous timer; the burst fires
-- once quiet. Net-zero bursts (next then prev) stay put.
queue_skip = function(dir)
	pending_steps = pending_steps + dir
	skip_nonce = skip_nonce + 1
	local my = skip_nonce
	local scheduled = noctalia.runAsync("sleep 0.25", function()
		if my ~= skip_nonce then
			return
		end
		advance_steps()
	end, 2000)
	if not scheduled then
		-- No slot even for the timer: run the backlog now rather than
		-- dropping the press.
		advance_steps()
	end
end

function Player.prev()
	if #state.player.queue == 0 then
		return
	end
	if state.player.position > 3 then
		mpv.send((noctalia.json.encode({ command = { "seek", 0, "absolute" } })))
		state.player.position = 0
		publish()
	else
		queue_skip(-1)
	end
end

function Player.seek(seconds)
	local val = tonumber(seconds)
	if not val then
		return
	end
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
	local enabling = not state.player.shuffle
	state.player.shuffle = enabling
	local q = state.player.queue

	if enabling then
		original_queue = {}
		for i, t in ipairs(q) do
			original_queue[i] = t
		end
		-- Fisher-Yates on the upcoming region only; history above the current
		-- track stays exactly as played.
		local start = (state.player.index or 0) + 1
		for i = #q, start + 1, -1 do
			local j = math.random(start, i)
			q[i], q[j] = q[j], q[i]
		end
		log("toggle_shuffle: on, randomized " .. math.max(0, #q - start) .. " upcoming tracks")
	elseif original_queue then
		local cur = q[state.player.index]
		state.player.queue = original_queue
		original_queue = nil
		local restored = false
		if cur and cur.id then
			for i, t in ipairs(state.player.queue) do
				if t.id == cur.id then
					state.player.index = i
					restored = true
					break
				end
			end
		end
		if not restored then
			state.player.index = math.max(1, math.min(state.player.index or 1, #state.player.queue))
		end
		log("toggle_shuffle: off, order restored at index " .. state.player.index)
	end
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
	original_queue = nil
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
	if not line or line == "" then
		return
	end
	local data = noctalia.json.decode(line)
	if type(data) ~= "table" then
		return
	end

	if data.event ~= "property-change" then
		if data.request_id == 100 then
			local pos = tonumber(data.data)
			if
				pos
				and state.player.status ~= "loading"
				and state.player.status ~= "stopped"
				and pos ~= state.player.position
			then
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
		if state.player.status == "loading" or state.player.status == "stopped" then
			return
		end
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
		if stream_generation ~= gen then
			return
		end
		handle_stream_line(line)
	end)
end

return Player
