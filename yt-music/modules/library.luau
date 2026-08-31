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

function Library.save_offline_meta()
	if type(state.offline_meta) ~= "table" then
		return
	end
	local encoded = noctalia.json.encode(state.offline_meta)
	if encoded then
		noctalia.writeFile(const.OFFLINE_META_PATH, encoded)
	else
		log("offline_meta: encode failed, not saved")
	end
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

	-- Every pid we know a title for: library first, then recents.
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

	state.downloaded_playlist_ids = {}
	local member_ids = {}
	local meta = {}
	local done = 0

	local function finalize()
		-- Saved Tracks are EXPLICIT downloads only: songs that were merely
		-- auto-cached during playback have no offline_meta entry and stay
		-- out of the section.
		local offline = {}
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
		table.sort(offline, function(a, b)
			return (a.added_at or 0) > (b.added_at or 0)
		end)
		state.offline_tracks = offline

		-- Prune metadata whose audio vanished (e.g. Clear Audio) so the
		-- persisted file cannot grow stale entries forever.
		local pruned = false
		for vid in pairs(state.offline_meta) do
			if not cached[vid] then
				state.offline_meta[vid] = nil
				pruned = true
			end
		end
		if pruned then
			Library.save_offline_meta()
		end

		log("audit_downloaded_playlists: " .. done .. " fully downloaded, " .. #offline .. " saved tracks")
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
					state.downloaded_playlist_ids[sources[idx]] = true
					done = done + 1
					for _, tr in ipairs(tracks) do
						if tr.id then
							member_ids[tr.id] = true
						end
					end
				end
			end
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

function Library.toggle_like(vid)
	vid = vid or state.player.id
	log("toggle_like: vid=" .. tostring(vid) .. " current=" .. tostring(state.liked_ids and state.liked_ids[vid]))
	if vid and vid ~= "" then
		if api and api.invalidate_playlist_cache then
			api.invalidate_playlist_cache("VLLM")
		end
		if state.liked_ids[vid] then
			state.liked_ids[vid] = nil
			log("toggle_like: unliking vid=" .. tostring(vid))
			store.publish()
			if api and api.unlike_video then
				api.unlike_video(vid, function(ok) end)
			end
		else
			state.liked_ids[vid] = true
			log("toggle_like: liking vid=" .. tostring(vid))
			store.publish()
			if api and api.like_video then
				api.like_video(vid, function(ok) end)
			end
		end
	end
end

return Library
