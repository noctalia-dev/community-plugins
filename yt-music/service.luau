local REQ_KEY = "yt_music.request"

local api = require("./api.luau")
local store = require("./modules/store.luau")
local state = store.state

local handled_nonce = 0
local probe_tick = 19

local logger = require("./utils/log.luau")
local network = require("./utils/network.luau")
local log = logger.module("ytm", "service")

-- Domain logic lives in dedicated backend modules under modules/.
-- Service keeps the wiring: logging, and request dispatch.
local auth = require("./modules/auth.luau")
local home = require("./modules/home.luau")
local library = require("./modules/library.luau")
local mpv = require("./modules/mpv.luau")
local player = require("./modules/player.luau")
local downloader = require("./modules/downloader.luau")
local playlist = require("./modules/playlist.luau")
local search = require("./modules/search.luau")
local cacheops = require("./modules/cacheops.luau")

local ACTIONS = {
	extract = function(r)
		auth.extract_cookies(r.browser)
	end,
	open_login = function(r)
		auth.open_login(r.browser)
	end,
	search = function(r)
		search.run(r.query, r.type)
	end,
	play = function(r)
		player.play(r.item or {})
	end,
	play_next = function(r)
		player.play_next(r.item or {})
	end,
	play_suggestion = function(r)
		player.play_now(r.item or {})
	end,
	play_queue_index = function(r)
		player.play_index(r.index or 1)
	end,
	play_with_queue = function(r)
		if r.queue and #r.queue > 0 then
			playlist.play_queue(r.queue, r.index, r.source_playlist)
		elseif r.item then
			player.play(r.item)
		end
	end,
	play_playlist = function(r)
		playlist.play(r.id or r.playlist_id, r.title)
	end,
	open_playlist = function(r)
		playlist.open(r.id or r.playlist_id, r.title)
	end,
	refresh_playlist = function(r)
		playlist.refresh(r.id or r.playlist_id)
	end,
	fetch_next_page = function(r)
		playlist.fetch_next_page(r.playlist_id, r.token)
	end,
	toggle_like = function(r)
		library.toggle_like(r.id or r.video_id)
	end,
	toggle_shuffle = function(r)
		player.toggle_shuffle()
	end,
	cycle_repeat = function(r)
		player.cycle_repeat()
	end,
	refresh_quick_picks = function(r)
		home.refresh_quick_picks()
	end,
	download_track = function(r)
		local vid = (r.item and r.item.id) or r.id or r.video_id
		if vid and vid ~= "" then
			-- Already on disk? ⬇ becomes "add to offline downloads" — no
			-- re-download, just register metadata and list it.
			if state.cached_audio_ids[vid] == true then
				log("download_track: already cached, registering explicit id=" .. tostring(vid))
				downloader.register_explicit(vid, r.item)
			else
				downloader.enqueue(vid, "", r.item)
			end
		end
	end,
	download_playlist = function(r)
		downloader.enqueue_playlist(state.playlist.tracks, state.playlist.id)
	end,
	toggle = function(r)
		player.toggle()
	end,
	next = function(r)
		player.next()
	end,
	prev = function(r)
		player.prev()
	end,
	seek = function(r)
		player.seek(r.seconds or r.value or r.position)
	end,
	volume = function(r)
		player.volume(r.value)
	end,
	toggle_mute = function(r)
		player.mute()
	end,
	stop = function(r)
		player.stop()
	end,
	prefetch = function(r)
		if api and api.prefetch_track and r.item then
			api.prefetch_track(r.item)
		end
	end,
	fetch_cache_stats = function(r)
		cacheops.fetch_stats()
	end,
	fetch_offline = function(r)
		library.sync_audio_cache()
		if api and api.ensure_thumbnails and type(state.offline_tracks) == "table" and #state.offline_tracks > 0 then
			noctalia.runAsync("true", function()
				api.ensure_thumbnails(state.offline_tracks, store.publish, "offline")
			end)
		end
	end,
	fetch_artist = function(r)
		local bid = tostring((r and r.browse_id) or "")
		if bid == "" then
			return
		end
		state.artist =
			{ id = bid, title = tostring(r.title or "Artist"), thumbnail_url = r.thumbnail_url or "", thumb_path = r.thumb_path or nil }
		
		local cached = api and api.load_cached_artist and api.load_cached_artist(bid)
		if cached then
			if type(cached.artist) == "table" then
				if cached.artist.thumb_path and noctalia.fileExists(cached.artist.thumb_path) then
					state.artist.thumb_path = cached.artist.thumb_path
				end
				if (not state.artist.thumbnail_url or state.artist.thumbnail_url == "") and cached.artist.thumbnail_url then
					state.artist.thumbnail_url = cached.artist.thumbnail_url
				end
			end
			state.artist_tracks = cached.tracks or {}
			state.artist_related = cached.related or {}
			store.publish()
		else
			state.artist_tracks = {}
			state.artist_related = {}
			store.publish()
		end

		if not network.isOnline() then
			return
		end
		api.artist_page(bid, function(res)
			state.artist_tracks = res.tracks or {}
			state.artist_related = res.related or {}
			store.publish()
			if api and api.save_artist_cache then
				api.save_artist_cache(bid, { artist = state.artist, tracks = state.artist_tracks, related = state.artist_related })
			end
			local items = { state.artist }
			for _, t in ipairs(state.artist_tracks) do
				table.insert(items, t)
			end
			if type(state.artist_related) == "table" then
				for _, pl in ipairs(state.artist_related) do
					table.insert(items, pl)
				end
			end
			noctalia.runAsync("true", function()
				api.ensure_thumbnails(items, store.publish, "artist")
			end)
		end)
	end,
	clear_cache = function(r)
		cacheops.clear(r.target)
	end,
	toggle_autoplay = function(r)
		state.settings.autoplay = not state.settings.autoplay
		store.publish()
	end,
}

noctalia.state.watch(REQ_KEY, function(req)
	if type(req) ~= "table" or not req.nonce or req.nonce <= handled_nonce then
		return
	end
	handled_nonce = req.nonce
	log("request nonce=" .. req.nonce .. " action=" .. tostring(req.action))

	local handler = ACTIONS[tostring(req.action or "")]
	if handler then
		handler(req)
	else
		log("request: unhandled action '" .. tostring(req.action) .. "'")
	end
end)

function update()
	if api.library_pending() then
		api.finish_library(function(playlists)
			state.library = type(playlists) == "table" and playlists or {}
			store.publish()
			if type(playlists) == "table" then
				log("ytmusic: loaded " .. #playlists .. " library playlists")
				noctalia.runAsync("true", function()
					api.ensure_thumbnails(state.library, store.publish, "library")
				end)
			else
				log("ytmusic: library decode failed")
			end
		end)
	end

	-- Connectivity probe every ~20s (update ticks at 1s). First probe fires
	-- one tick after boot thanks to the pre-advanced counter.
	probe_tick = probe_tick + 1
	if probe_tick >= 20 then
		probe_tick = 0
		noctalia.runAsync(
			"curl -s -o /dev/null -m 3 https://music.youtube.com && echo 'NET=UP' || echo 'NET=DOWN'",
			function(res)
				local out = (type(res) == "table" and res.stdout) or ""
				local now_online = out:find("NET=UP", 1, true) ~= nil
				if now_online ~= state.online then
					state.online = now_online
					network.setOnline(now_online)
					store.publish()
					log(now_online and "network: back online" or "network: offline")
				end
			end,
			5000
		)
	end
end

noctalia.setUpdateInterval(1000)

log("boot: service started, api=" .. tostring(type(api)) .. " library=" .. tostring(type(api and api.library)))
mpv.kill()
library.load_offline_meta()
auth.detect_browsers()
auth.load_cached_cookies()
if api and api.load_cached_library then
	local cached_lib = api.load_cached_library()
	if cached_lib then
		state.library = cached_lib
	end
end
noctalia.runAsync("true", function()
	local const = require("./api/constants.luau")
	if not noctalia.fileExists(const.COOKIE_PATH) then
		-- Signed out (e.g. cookies cleared between runs): drop recently-played
		-- and the saved session from memory AND delete their persisted copies
		-- so nothing stale resurrects after a later sign-in.
		state.recent_playlists = {}
		noctalia.removeFile(const.RECENT_PLAYLISTS_CACHE_PATH)
		state.player = require("./utils/schema.luau").new().player
		noctalia.removeFile(const.SESSION_CACHE_PATH)
	elseif api and api.load_cached_recent_playlists then
		local cached_recent = api.load_cached_recent_playlists()
		if cached_recent then
			state.recent_playlists = cached_recent
		end
	end
	if api and api.fetch_quick_picks then
		home.refresh_quick_picks()
	end
	if api and api.load_session then
		local sess = api.load_session()
		if type(sess) == "table" and sess.id and sess.id ~= "" then
			player.restore_session(sess)
		end
	end
	store.publish()
end)
if api and api.library then
	api.library()
end
store.publish()

function onStop()
	if api and api.save_session then
		api.save_session(state.player)
	end
end
