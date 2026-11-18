local store = require("./store.luau")
local api = require("../api.luau")
local logger = require("../utils/log.luau")

local const = require("../api/constants.luau")
local AUDIO_DIR = const.AUDIO_DIR
local thumbs = require("../api/thumbnails.luau")

local state = store.state
local log = logger.module("ytm", "library")

local Library = {}

local auditing = false
local audit_pending = false

-- Saved-track metadata persistence (offline_meta.json): standalone
-- downloads keep their title/artist here so restarts stay labeled.
local meta_loaded = false

function Library.load_offline_meta()
	if meta_loaded then
		return
	end
	meta_loaded = true
	if not noctalia.fileExists(const.OFFLINE_META_PATH) then
		return
	end
	local raw = noctalia.readFile(const.OFFLINE_META_PATH)
	local data = raw and noctalia.json.decode(raw)
	if type(data) == "table" then
		state.offline_meta = data
		local n = 0
		for _ in pairs(data) do
			n = n + 1
		end
		log("offline_meta: loaded " .. n .. " entries")
	else
		log("offline_meta: decode failed, starting fresh")
	end
end

local save_meta_pending = false

function Library.save_offline_meta()
	if type(state.offline_meta) ~= "table" then
		return
	end
	if save_meta_pending then
		return
	end
	save_meta_pending = true
	noctalia.runAsync("true", function()
		save_meta_pending = false
		local ok, encoded = pcall(noctalia.json.encode, state.offline_meta)
		if ok and encoded then
			noctalia.writeFile(const.OFFLINE_META_PATH, encoded)
		else
			log("offline_meta: encode failed, not saved")
		end
	end)
end

local cached_meta = {}
local cached_meta_loaded = false

function Library.load_cached_meta()
	if cached_meta_loaded then
		return
	end
	cached_meta_loaded = true
	if not noctalia.fileExists(const.CACHED_META_PATH) then
		return
	end
	local raw = noctalia.readFile(const.CACHED_META_PATH)
	local data = raw and noctalia.json.decode(raw)
	if type(data) == "table" then
		cached_meta = data
		local n = 0
		for _ in pairs(data) do
			n = n + 1
		end
		log("cached_meta: loaded " .. n .. " entries")
	end
end

local save_cached_meta_pending = false

function Library.save_cached_meta()
	if save_cached_meta_pending then
		return
	end
	save_cached_meta_pending = true
	noctalia.runAsync("true", function()
		save_cached_meta_pending = false
		local ok, encoded = pcall(noctalia.json.encode, cached_meta)
		if ok and encoded then
			noctalia.writeFile(const.CACHED_META_PATH, encoded)
		end
	end)
end

function Library.remove_from_cached_meta(id)
	if id and cached_meta[id] then
		cached_meta[id] = nil
		Library.save_cached_meta()
	end
end

function Library.note_cached_track(item)
	if type(item) ~= "table" or not item.id or item.id == "" then
		return
	end
	local id = item.id
	Library.load_cached_meta()
	cached_meta[id] = {
		title = item.title or id,
		artist = item.artist or "",
		duration = tonumber(item.duration) or 0,
		thumbnail_url = item.thumbnail_url,
	}
	Library.save_cached_meta()

	-- If it's already an explicit download, it belongs in offline_tracks, not cached_tracks
	if state.offline_meta and state.offline_meta[id] then
		return
	end

	local list = state.cached_tracks or {}
	for _, t in ipairs(list) do
		if t.id == id then
			return
		end
	end
	local info = noctalia.fileInfo(AUDIO_DIR .. "/" .. id .. ".opus")
	local thumb = item.thumbnail_url and thumbs.path_for(id, item.thumbnail_url)
	table.insert(list, 1, {
		id = id,
		title = item.title or id,
		artist = item.artist or "",
		duration = tonumber(item.duration) or 0,
		thumbnail_url = item.thumbnail_url,
		thumb_path = (thumb and noctalia.fileExists(thumb)) and thumb or item.thumb_path,
		added_at = (info and info.mtime) or os.time(),
	})
	state.cached_tracks = list
	store.publish()
end

local resolving_missing = false

function Library.resolve_missing_meta(vids: { string })
	if resolving_missing or #vids == 0 then
		return
	end
	resolving_missing = true

	local idx = 1
	local function next_vid()
		if idx > #vids or idx > 15 then
			resolving_missing = false
			return
		end
		local vid = vids[idx]
		idx = idx + 1
		local url = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=" .. vid .. "&format=json"
		noctalia.runAsync({ "curl", "-s", "--max-time", "5", url }, function(res)
			if type(res) == "table" and res.stdout and res.stdout ~= "" then
				local data = noctalia.json.decode(res.stdout)
				if type(data) == "table" and data.title then
					local title = tostring(data.title)
					local author = tostring(data.author_name or ""):gsub("%s*-%s*Topic$", "")
					local thumb = data.thumbnail_url
					cached_meta[vid] = {
						title = title,
						artist = author,
						duration = 0,
						thumbnail_url = thumb,
					}
					Library.save_cached_meta()

					if state.cached_tracks then
						for _, t in ipairs(state.cached_tracks) do
							if t.id == vid then
								t.title = title
								t.artist = author
								t.thumbnail_url = thumb
								if thumb then
									local tp = thumbs.path_for(vid, thumb)
									t.thumb_path = noctalia.fileExists(tp) and tp or nil
								end
								store.publish()
								break
							end
						end
					end
				end
			end
			noctalia.runAsync("sleep 0.2", next_vid)
		end)
	end

	next_vid()
end

-- One pass over every known playlist cache that simultaneously:
--  1. marks fully-downloaded playlists (downloaded_playlist_ids)
--  2. collects metadata for any track seen in those caches
--  3. classifies leftover locally-cached audio as Saved Tracks
--     (state.offline_tracks), excluding members of fully-downloaded playlists,
--     newest download first. A song therefore moves between sections
--     automatically when its playlist gains/loses full-offline status.
--
-- Processing is chained one playlist per async tick: decoding every cache in
-- a single callback blows Noctalia's per-callback CPU budget on large libs.
function Library.audit_downloaded_playlists()
	if not api or not api.load_cached_playlist then
		return
	end
	if auditing then
		audit_pending = true
		return
	end
	auditing = true

	local cached = (type(state.cached_audio_ids) == "table") and state.cached_audio_ids or {}

	-- Every pid we know a title for: library first, then recents, then open playlist.
	local sources, seen_pid = {}, {}
	local function add_source(list)
		if type(list) ~= "table" then
			return
		end
		for _, pl in ipairs(list) do
			local pid = tostring(pl.id or "")
			if pid ~= "" and not seen_pid[pid] then
				seen_pid[pid] = true
				table.insert(sources, pid)
			end
		end
	end
	add_source(state.library)
	add_source(state.recent_playlists)
	if state.playlist and state.playlist.id then
		add_source({ state.playlist })
	end

	local new_downloaded_playlist_ids = {}
	local member_ids = {}
	local meta = {}
	local done = 0
	local meta_added = false

	local function harvest_meta(track_list)
		if type(track_list) ~= "table" then
			return
		end
		for _, tr in ipairs(track_list) do
			if tr and tr.id and not meta[tr.id] then
				meta[tr.id] = {
					title = tr.title,
					artist = tr.artist or "",
					duration = tonumber(tr.duration) or 0,
					thumbnail_url = tr.thumbnail_url,
				}
			end
		end
	end

	local function finalize()
		pcall(function()
			if state.player and type(state.player.queue) == "table" then
				harvest_meta(state.player.queue)
			end
			if type(state.quick_picks) == "table" then
				harvest_meta(state.quick_picks)
			end
			if type(state.home_mixes) == "table" then
				for _, mix in ipairs(state.home_mixes) do
					if type(mix.tracks) == "table" then
						harvest_meta(mix.tracks)
					end
				end
			end

			if noctalia.fileExists(const.SESSION_CACHE_PATH) then
				local raw = noctalia.readFile(const.SESSION_CACHE_PATH)
				local sess = raw and noctalia.json.decode(raw)
				if type(sess) == "table" and type(sess.queue) == "table" then
					harvest_meta(sess.queue)
				end
			end
			if noctalia.fileExists(const.QUICK_PICKS_CACHE_PATH) then
				local raw = noctalia.readFile(const.QUICK_PICKS_CACHE_PATH)
				local qp = raw and noctalia.json.decode(raw)
				if type(qp) == "table" then
					harvest_meta(qp)
				end
			end
		end)

		Library.load_cached_meta()
		for vid, m in pairs(cached_meta) do
			if not meta[vid] then
				meta[vid] = m
			end
		end

		-- Saved Tracks are EXPLICIT downloads only: songs that were merely
		-- auto-cached during playback have no offline_meta entry and go
		-- into cached_tracks instead.
		local offline = {}
		local cached_tracks = {}
		for vid, own in pairs(state.offline_meta) do
			if cached[vid] and not member_ids[vid] then
				local m = meta[vid] or own
				local info = noctalia.fileInfo(AUDIO_DIR .. "/" .. vid .. ".opus")
				local thumb = thumbs.path_for(vid, m.thumbnail_url)
				table.insert(offline, {
					id = vid,
					title = m.title,
					artist = m.artist or "",
					duration = m.duration or 0,
					thumbnail_url = m.thumbnail_url,
					thumb_path = noctalia.fileExists(thumb) and thumb or nil,
					added_at = (info and info.mtime) or 0,
				})
			end
		end

		local cached_meta_updated = false
		for vid in pairs(cached) do
			if not state.offline_meta[vid] and not member_ids[vid] then
				local m = meta[vid] or {}
				if m.title and not cached_meta[vid] then
					cached_meta[vid] = {
						title = m.title,
						artist = m.artist or "",
						duration = tonumber(m.duration) or 0,
						thumbnail_url = m.thumbnail_url,
					}
					cached_meta_updated = true
				end
				local info = noctalia.fileInfo(AUDIO_DIR .. "/" .. vid .. ".opus")
				local thumb = m.thumbnail_url and thumbs.path_for(vid, m.thumbnail_url)
				table.insert(cached_tracks, {
					id = vid,
					title = m.title or vid,
					artist = m.artist or "",
					duration = m.duration or 0,
					thumbnail_url = m.thumbnail_url,
					thumb_path = (thumb and noctalia.fileExists(thumb)) and thumb or nil,
					added_at = (info and info.mtime) or 0,
				})
			end
		end
		if cached_meta_updated then
			Library.save_cached_meta()
		end

		table.sort(offline, function(a, b)
			return (a.added_at or 0) > (b.added_at or 0)
		end)
		table.sort(cached_tracks, function(a, b)
			return (a.added_at or 0) > (b.added_at or 0)
		end)
		state.offline_tracks = offline
		state.cached_tracks = cached_tracks

		local missing_vids = {}
		for _, tr in ipairs(cached_tracks) do
			if not tr.artist or tr.artist == "" or tr.title == tr.id then
				table.insert(missing_vids, tr.id)
			end
		end
		if #missing_vids > 0 then
			Library.resolve_missing_meta(missing_vids)
		end

		-- Prune metadata whose audio vanished (e.g. Clear Audio) so the
		-- persisted file cannot grow stale entries forever.
		local pruned = false
		for vid in pairs(state.offline_meta) do
			if not cached[vid] then
				state.offline_meta[vid] = nil
				pruned = true
			end
		end
		if pruned or meta_added then
			Library.save_offline_meta()
		end

		local cached_pruned = false
		for vid in pairs(cached_meta) do
			if not cached[vid] or (state.offline_meta and state.offline_meta[vid]) then
				cached_meta[vid] = nil
				cached_pruned = true
			end
		end
		if cached_pruned then
			Library.save_cached_meta()
		end

		state.downloaded_playlist_ids = new_downloaded_playlist_ids
		log(
			"audit_downloaded_playlists: "
				.. done
				.. " fully downloaded, "
				.. #offline
				.. " saved tracks, "
				.. #cached_tracks
				.. " cached tracks"
		)
		auditing = false
		store.publish()
		if audit_pending then
			audit_pending = false
			Library.audit_downloaded_playlists()
		end
	end

	local function step(idx)
		if idx > #sources then
			finalize()
			return
		end
		noctalia.runAsync("true", function()
			pcall(function()
				local tracks = api.load_cached_playlist(sources[idx])
				if tracks and #tracks > 0 then
					for _, tr in ipairs(tracks) do
						if tr.id then
							meta[tr.id] = {
								title = tr.title,
								artist = tr.artist,
								duration = tonumber(tr.duration) or 0,
								thumbnail_url = tr.thumbnail_url,
							}
						end
					end
					local all_dl = true
					for _, tr in ipairs(tracks) do
						if tr.id and not cached[tr.id] then
							all_dl = false
							break
						end
					end
					if all_dl then
						new_downloaded_playlist_ids[sources[idx]] = true
						done = done + 1
						for _, tr in ipairs(tracks) do
							if tr.id then
								member_ids[tr.id] = true
								if not state.offline_meta[tr.id] and meta[tr.id] then
									state.offline_meta[tr.id] = meta[tr.id]
									meta_added = true
								end
							end
						end
					end
				end
			end)
			step(idx + 1)
		end)
	end

	step(1)
end

function Library.remember_playlist(pid, title)
	if not pid or pid == "" then
		return
	end
	local cleaned = {}
	for _, pl in ipairs(state.recent_playlists or {}) do
		if tostring(pl.id or "") ~= pid then
			table.insert(cleaned, pl)
		end
	end
	table.insert(cleaned, 1, { id = pid, title = tostring(title or "Playlist") })
	while #cleaned > 3 do
		table.remove(cleaned)
	end
	state.recent_playlists = cleaned
	if api and api.save_recent_playlists_cache then
		api.save_recent_playlists_cache(cleaned)
	end
end

function Library.sync_liked_tracks(tracks)
	if type(tracks) ~= "table" then
		return
	end
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

function Library.toggle_like(vid, item)
	vid = vid or state.player.id
	log("toggle_like: vid=" .. tostring(vid) .. " current=" .. tostring(state.liked_ids and state.liked_ids[vid]))
	if vid and vid ~= "" then
		if state.liked_ids[vid] then
			state.liked_ids[vid] = nil
			log("toggle_like: unliking vid=" .. tostring(vid))

			if state.playlist.id == "VLLM" and type(state.playlist.tracks) == "table" then
				local filtered = {}
				for _, tr in ipairs(state.playlist.tracks) do
					if tr.id ~= vid then
						table.insert(filtered, tr)
					end
				end
				state.playlist.tracks = filtered
				if api and api.save_playlist_cache then
					api.save_playlist_cache("VLLM", filtered)
				end
			elseif api and api.load_cached_playlist and api.save_playlist_cache then
				local cached = api.load_cached_playlist("VLLM")
				if type(cached) == "table" then
					local filtered = {}
					for _, tr in ipairs(cached) do
						if tr.id ~= vid then
							table.insert(filtered, tr)
						end
					end
					api.save_playlist_cache("VLLM", filtered)
				end
			end

			store.publish()
			if api and api.unlike_video then
				api.unlike_video(vid, function(ok) end)
			end
		else
			state.liked_ids[vid] = true
			log("toggle_like: liking vid=" .. tostring(vid))

			local liked_item = item
				or (
					state.player.id == vid
						and {
							id = state.player.id,
							title = state.player.title,
							artist = state.player.artist,
							thumbnail_url = state.player.thumbnail_url,
							thumb_path = state.player.thumb_path,
							duration = state.player.duration,
						}
					or nil
				)

			if liked_item then
				if state.playlist.id == "VLLM" and type(state.playlist.tracks) == "table" then
					table.insert(state.playlist.tracks, 1, liked_item)
					if api and api.save_playlist_cache then
						api.save_playlist_cache("VLLM", state.playlist.tracks)
					end
				elseif api and api.load_cached_playlist and api.save_playlist_cache then
					local cached = api.load_cached_playlist("VLLM") or {}
					table.insert(cached, 1, liked_item)
					api.save_playlist_cache("VLLM", cached)
				end
			end

			store.publish()
			if api and api.like_video then
				api.like_video(vid, function(ok) end)
			end
		end
	end
end

return Library
