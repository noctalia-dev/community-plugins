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
local network = require("../utils/network.luau")

-- Client choice. Forcing mweb,web (the old setting) now yields only format
-- 18, a 360p video with AAC audio, never the Opus audio-only formats.
--
-- Fast path: the visionos client without cookies. Same Opus 251 as yt-dlp's
-- default clients, but in one player request (~1.4 s instead of ~4.5 s), with
-- no JS challenge (no deno needed) and no preroll ad. With cookies, most
-- tracks carry a 6 s preroll ad, and googlevideo answers 403 to the fresh URL
-- until ~4 s after it is minted, which is where tracks died on start.
-- visionos needs the watch page's visitor data (without it YouTube asks to
-- confirm you're not a bot), so the webpage request is kept.
--
-- Its result is accepted only when it is audio-only; otherwise the resolve is
-- redone at once with the default clients and cookies, and the fast path
-- rests for FAST_BACKOFF_S. A miss about the video itself (age gate, private,
-- members-only) does not rest it.
local FAST_EXTRACTOR_ARGS = "youtube:player_client=visionos;player_skip=configs,initial_data"
local FAST_BACKOFF_S = 10 * 60
local fast_disabled_until = 0
local VIDEO_SPECIFIC_ERRORS = { "confirm your age", "Private video", "members-only", "Join this channel" }

local function video_specific_error(res: any): boolean
	local err = type(res) == "table" and res.stderr or ""
	for _, needle in ipairs(VIDEO_SPECIFIC_ERRORS) do
		if err:find(needle, 1, true) then
			return true
		end
	end
	return false
end

-- Offline, timed out, or reaped by our own supersede kill: no verdict on the
-- client.
local function inconclusive(res: any): boolean
	if type(res) ~= "table" then
		return true
	end
	local out = res.stdout or ""
	return out:find("NETGATE=OFFLINE", 1, true) ~= nil or res.timedOut or res.exitCode == 143 or res.exitCode == 137
end

local function build_resolve_argv(safe_id: string, fast: boolean): { string }
	local argv = {
		"yt-dlp",
		"-f",
		"bestaudio/best",
		"-g",
		"--print",
		"FMT=%(acodec)s|%(vcodec)s",
		"--no-playlist",
		"--no-warnings",
	}
	if fast then
		table.insert(argv, "--extractor-args")
		table.insert(argv, FAST_EXTRACTOR_ARGS)
		table.insert(argv, "https://www.youtube.com/watch?v=" .. safe_id)
		return argv
	end
	if noctalia.fileExists(COOKIE_PATH) then
		table.insert(argv, "--cookies")
		table.insert(argv, COOKIE_PATH)
	end
	table.insert(argv, "https://music.youtube.com/watch?v=" .. safe_id)
	return argv
end

local function sanitize_str(str)
	if type(str) ~= "string" then
		return ""
	end
	return (str:gsub("[^\32-\126]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local EXPO = {}

local stream_cache = {}
local resolving_in_flight = {}
local attempt_resolve: (string, number, boolean?) -> () -- forward: resolve_stream parks the list, attempt spawns
local STREAM_DISK_TTL = 4 * 3600

function EXPO.get_audio_cache_path(video_id: string): string?
	if type(video_id) ~= "string" or video_id == "" then
		return nil
	end
	local safe_id = video_id:gsub("[^%w%-_]", "_")
	local path = AUDIO_DIR .. "/" .. safe_id .. ".opus"
	if noctalia.fileExists(path) then
		return path
	end
	return nil
end

function EXPO.get_cached_audio_ids(callback)
	noctalia.mkdirAll(AUDIO_DIR)
	local set = {}
	local entries = noctalia.listDir(AUDIO_DIR)
	if type(entries) == "table" then
		for _, name in ipairs(entries) do
			local id = tostring(name):match("([%w%-_]+)%.opus$")
			if id then
				set[id] = true
			end
		end
	end
	if callback then
		callback(set)
	end
end

function EXPO.cache_audio(video_id, callback)
	if type(video_id) ~= "string" or video_id == "" then
		if callback then
			callback(false)
		end
		return
	end
	local safe_id = video_id:gsub("[^%w%-_]", "_")
	local path = AUDIO_DIR .. "/" .. safe_id .. ".opus"
	if noctalia.fileExists(path) then
		if callback then
			callback(true)
		end
		return
	end

	noctalia.mkdirAll(AUDIO_DIR)
	-- Same fast path as streaming (see FAST_EXTRACTOR_ARGS): no preroll ad
	-- means yt-dlp does not sleep until the ad would have ended. "bestaudio"
	-- without "/best" so a client offering only muxed video fails instead of
	-- saving a video; any miss redoes the download with the default clients.
	local function run(fast: boolean)
		local argv = { "yt-dlp", "-f", fast and "bestaudio" or "bestaudio/best", "-o", path }
		if fast then
			table.insert(argv, "--extractor-args")
			table.insert(argv, FAST_EXTRACTOR_ARGS)
			table.insert(argv, "https://www.youtube.com/watch?v=" .. safe_id)
		else
			if noctalia.fileExists(COOKIE_PATH) then
				table.insert(argv, "--cookies")
				table.insert(argv, COOKIE_PATH)
			end
			table.insert(argv, "https://music.youtube.com/watch?v=" .. safe_id)
		end

		local launched = network.runAsync(argv, function(res)
			local ok = noctalia.fileExists(path)
			if not ok and type(res) == "table" then
				ok = res.exitCode == 0
			end
			if not ok and fast and not inconclusive(res) then
				if not video_specific_error(res) then
					fast_disabled_until = os.time() + FAST_BACKOFF_S
				end
				log("audio download via visionos failed for id=" .. video_id .. "; default clients")
				noctalia.removeFile(path .. ".part")
				run(false)
				return
			end
			if callback then
				callback(ok)
			end
		end, 120000)
		if not launched and callback then
			callback(false)
		end
	end
	run(os.time() >= fast_disabled_until)
end

function EXPO.resolve_stream(video_id: string, cb: ((string?) -> ())?)
	if type(video_id) ~= "string" or video_id == "" then
		if cb then
			cb(nil)
		end
		return
	end

	local local_audio = EXPO.get_audio_cache_path(video_id)
	if local_audio then
		log("audio_disk_cache HIT for id=" .. video_id)
		if cb then
			cb(local_audio)
		end
		return
	end

	local cached = stream_cache[video_id]
	if cached and (os.time() - cached.timestamp) < 14400 then
		log("stream_cache HIT for id=" .. video_id)
		if cb then
			cb(cached.url)
		end
		return
	end

	local safe_id = video_id:gsub("[^%w%-_]", "_")
	local disk_url_path = STREAMS_CACHE_DIR .. "/" .. safe_id .. ".url"
	local info = noctalia.fileInfo(disk_url_path)
	local disk_fresh = false
	if info then
		local mtime_s = info.mtime
		if mtime_s > 1e11 then
			mtime_s = mtime_s / 1000
		end
		disk_fresh = (os.time() - mtime_s) < STREAM_DISK_TTL
		if not disk_fresh then
			log("stream_disk_cache STALE for id=" .. video_id)
			noctalia.removeFile(disk_url_path)
		end
	end
	if disk_fresh then
		local raw_disk = noctalia.readFile(disk_url_path)
		if raw_disk and #raw_disk > 20 then
			local clean_url = sanitize_str(raw_disk)
			stream_cache[video_id] = { url = clean_url, timestamp = os.time() }
			log("stream_disk_cache HIT for id=" .. video_id)
			if cb then
				cb(clean_url)
			end
			return
		end
	end

	if resolving_in_flight[video_id] then
		table.insert(resolving_in_flight[video_id], cb)
		return
	end

	resolving_in_flight[video_id] = { cb }
	attempt_resolve(video_id, 0)
end

-- Spawn the yt-dlp fetch for a video_id whose callback list is already parked
-- in resolving_in_flight. Attempt 0 is the first try; on host spawn refusal
-- (burst saturation from rapid skips) one delayed retry follows, then fail.
attempt_resolve = function(video_id, attempt, fast)
	if fast == nil then
		fast = os.time() >= fast_disabled_until
	end
	local safe_id = video_id:gsub("[^%w%-_]", "_")
	log("resolving stream URL for id=" .. video_id .. (fast and " (visionos)" or ""))
	local argv = build_resolve_argv(safe_id, fast)
	local started_ms = noctalia.nowMs()
	local launched = network.runAsync(argv, function(res)
		local elapsed_ms = noctalia.nowMs() - started_ms
		local out = type(res) == "table" and res.stdout or ""
		local raw_url = out:match("([^\n\r]+)%s*$")
		local url = sanitize_str(raw_url)
		if url:sub(1, 4) ~= "http" then
			url = ""
		end

		if fast then
			local acodec, vcodec = out:match("FMT=([^|\n]*)|([^|\n]*)")
			local audio_only = acodec and acodec ~= "none" and vcodec == "none"
			if not (url ~= "" and audio_only) and not inconclusive(res) then
				local video_specific = video_specific_error(res)
				if not video_specific then
					fast_disabled_until = os.time() + FAST_BACKOFF_S
				end
				log(
					"visionos rejected for id="
						.. video_id
						.. " ("
						.. tostring(acodec)
						.. "/"
						.. tostring(vcodec)
						.. ", "
						.. elapsed_ms
						.. "ms"
						.. (video_specific and ", video-specific" or (", off for " .. FAST_BACKOFF_S .. " s"))
						.. "); default clients"
				)
				if resolving_in_flight[video_id] then
					attempt_resolve(video_id, attempt, false)
				end
				return
			end
		end

		local callbacks = resolving_in_flight[video_id] or {}
		resolving_in_flight[video_id] = nil

		if url ~= "" then
			log("stream resolved successfully (" .. #url .. " bytes, " .. elapsed_ms .. "ms) for id=" .. video_id)
			stream_cache[video_id] = { url = url, timestamp = os.time() }
			noctalia.mkdirAll(STREAMS_CACHE_DIR)
			noctalia.writeFile(STREAMS_CACHE_DIR .. "/" .. safe_id .. ".url", url)
			for _, callback in ipairs(callbacks) do
				if callback then
					callback(url)
				end
			end
		else
			local reason = "failed"
			if out:find("NETGATE=OFFLINE", 1, true) then
				reason = "offline, deferred"
			elseif type(res) == "table" and res.timedOut then
				reason = "timed out"
			elseif type(res) == "table" and (res.exitCode == 143 or res.exitCode == 137) then
				-- SIGTERM/SIGKILL is our own supersede kill reaping a stale
				-- fetch during rapid skips — expected, not an error.
				reason = "superseded (stale fetch reaped)"
			end
			log("stream resolution " .. reason .. " (" .. elapsed_ms .. "ms) for id=" .. video_id)
			for _, callback in ipairs(callbacks) do
				if callback then
					callback(nil)
				end
			end
		end
	end, 30000)
	if not launched and network.isOnline() then
		-- Host refused the spawn: rapid skips fill every slot with stale
		-- yt-dlp fetches, so the final song's resolve is the one refused and
		-- its entry would wedge (UI loading forever + id poisoned). Retry once
		-- after the burst drains; if that also fails, fail fast with nil so
		-- the owner falls back to stopped instead of hanging. Offline needs
		-- no handling: the net gate already scheduled its synthetic failure.
		if attempt < 1 then
			log("stream resolve launch refused for id=" .. video_id .. ", retrying")
			local scheduled = noctalia.runAsync("sleep 1.5", function()
				if resolving_in_flight[video_id] then
					attempt_resolve(video_id, attempt + 1, fast)
				end
			end)
			if scheduled then
				return
			end
		end
		log("stream resolve launch refused for id=" .. video_id)
		local pending = resolving_in_flight[video_id] or {}
		resolving_in_flight[video_id] = nil
		for _, callback in ipairs(pending) do
			if callback then
				callback(nil)
			end
		end
	end
end

function EXPO.prefetch_track(item: types.Track)
	if type(item) ~= "table" or not item.id or item.id == "" then
		return
	end
	-- Prefetching is pure network work; skip entirely when offline.
	if not network.isOnline() then
		return
	end
	local id = item.id

	if item.thumbnail_url or id ~= "" then
		local url = item.thumbnail_url or ("https://i.ytimg.com/vi/" .. id .. "/hqdefault.jpg")
		get_thumbnail_path(id, url, nil)
	end

	if EXPO.get_audio_cache_path(id) then
		return
	end

	local cached = stream_cache[id]
	if not cached or (os.time() - cached.timestamp) >= 7200 then
		log("prefetching stream URL into memory for id=" .. id)
		EXPO.resolve_stream(id, nil)
	end
end

function EXPO.prefetch_queue(queue: { types.Track }, current_index)
	if type(queue) ~= "table" or #queue == 0 then
		return
	end
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
