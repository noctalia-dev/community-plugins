local store = require("./store.luau")

local api = require("../api.luau")
local state = store.state

local const = require("../api/constants.luau")
local AUDIO_DIR = const.AUDIO_DIR
local STREAMS_CACHE_DIR = const.STREAMS_CACHE_DIR
local THUMB_DIR = const.THUMB_DIR
local PLAYLISTS_CACHE_DIR = const.PLAYLISTS_CACHE_DIR

local TARGET_DIRS = {
	streams = STREAMS_CACHE_DIR,
	thumbnails = THUMB_DIR,
	playlists = PLAYLISTS_CACHE_DIR,
}

local function human_bytes(n)
	n = tonumber(n) or 0
	if n >= 1073741824 then
		return string.format("%.1fG", n / 1073741824)
	end
	if n >= 1048576 then
		return string.format("%.1fM", n / 1048576)
	end
	if n >= 1024 then
		return string.format("%.0fK", n / 1024)
	end
	return tostring(n) .. "B"
end

local function dir_size(dir_path: string): number
	if not noctalia.fileExists(dir_path) then
		return 0
	end
	local entries = noctalia.listDir(dir_path)
	if type(entries) ~= "table" then
		return 0
	end
	local total = 0
	for _, name in ipairs(entries) do
		local info = noctalia.fileInfo(dir_path .. "/" .. name)
		if info and not info.isDir then
			total = total + (info.size or 0)
		end
	end
	return total
end

-- Intentional downloads: explicit ⬇ saves + every track of fully-downloaded playlists
local function get_intentional()
	local intentional = {}
	for vid in pairs(state.offline_meta or {}) do
		intentional[vid] = true
	end
	for pid in pairs(state.downloaded_playlist_ids or {}) do
		local tracks = api.load_cached_playlist(pid)
		if tracks then
			for _, tr in ipairs(tracks) do
				if tr.id then
					intentional[tr.id] = true
				end
			end
		end
	end
	return intentional
end

local Cache = {}

-- Audio is one shared dir, so its total size is split into downloads vs cached
-- using intentional saves as the partition.
function Cache.fetch_stats()
	state.refreshing_cache_stats = true
	store.publish()

	noctalia.runAsync("sleep 0.25", function()
		local intentional = get_intentional()
		local total_audio = 0
		local dl_bytes = 0

		if noctalia.fileExists(AUDIO_DIR) then
			local entries = noctalia.listDir(AUDIO_DIR)
			if type(entries) == "table" then
				for _, name in ipairs(entries) do
					local info = noctalia.fileInfo(AUDIO_DIR .. "/" .. name)
					if info and not info.isDir then
						local sz = info.size or 0
						total_audio = total_audio + sz
						local vid = name:match("([%w%-_]+)%.opus$")
						if vid and intentional[vid] then
							dl_bytes = dl_bytes + sz
						end
					end
				end
			end
		end

		local cached_bytes = total_audio - dl_bytes
		if cached_bytes < 0 then
			cached_bytes = 0
		end

		state.cache_stats = {
			streams = human_bytes(dir_size(STREAMS_CACHE_DIR)),
			thumbnails = human_bytes(dir_size(THUMB_DIR)),
			playlists = human_bytes(dir_size(PLAYLISTS_CACHE_DIR)),
			audio = human_bytes(total_audio),
			downloads = human_bytes(dl_bytes),
			cached_audio = human_bytes(cached_bytes),
		}
		state.refreshing_cache_stats = false
		store.publish()
	end)
end

-- rm target allowlist: the request channel is external input, so anything
-- outside these names is refused rather than interpolated.
local ALLOWED_TARGETS = {
	downloads = true,
	cached_audio = true,
	streams = true,
	thumbnails = true,
	playlists = true,
}

local function clear_dir(dir_path: string)
	if not noctalia.fileExists(dir_path) then
		return
	end
	local entries = noctalia.listDir(dir_path)
	if type(entries) ~= "table" then
		return
	end
	for _, name in ipairs(entries) do
		noctalia.removeFile(dir_path .. "/" .. name)
	end
end

function Cache.clear(target)
	if type(target) ~= "string" or not ALLOWED_TARGETS[target] then
		return
	end

	if target == "downloads" then
		local intentional = get_intentional()
		for vid in pairs(intentional) do
			local path = AUDIO_DIR .. "/" .. vid .. ".opus"
			if noctalia.fileExists(path) then
				noctalia.removeFile(path)
			end
		end
		state.offline_meta = {}
		require("./library.luau").save_offline_meta()
		require("./library.luau").sync_audio_cache()
	elseif target == "cached_audio" then
		local intentional = get_intentional()
		if noctalia.fileExists(AUDIO_DIR) then
			local entries = noctalia.listDir(AUDIO_DIR)
			if type(entries) == "table" then
				for _, name in ipairs(entries) do
					local vid = name:match("([%w%-_]+)%.opus$")
					if vid and not intentional[vid] then
						noctalia.removeFile(AUDIO_DIR .. "/" .. name)
					end
				end
			end
		end
		require("./library.luau").sync_audio_cache()
	elseif TARGET_DIRS[target] then
		clear_dir(TARGET_DIRS[target])
	end
	if target == "thumbnails" then
		if api and api.reset_thumb_cache then
			api.reset_thumb_cache()
		end
		local reset_items = function(items)
			if type(items) == "table" then
				for _, item in ipairs(items) do
					if type(item) == "table" then
						item.thumb_path = nil
					end
				end
			end
		end
		reset_items(state.library)
		reset_items(state.recent_playlists)
		reset_items(state.quick_picks)
		reset_items(state.home_mixes)
		if type(state.search) == "table" then
			reset_items(state.search.results)
		end
		if api and api.ensure_thumbnails then
			if type(state.library) == "table" and #state.library > 0 then
				api.ensure_thumbnails(state.library, store.publish, "library")
			end
			if type(state.recent_playlists) == "table" and #state.recent_playlists > 0 then
				api.ensure_thumbnails(state.recent_playlists, store.publish, "recent")
			end
			if type(state.quick_picks) == "table" and #state.quick_picks > 0 then
				api.ensure_thumbnails(state.quick_picks, store.publish, "qp")
			end
			if type(state.home_mixes) == "table" and #state.home_mixes > 0 then
				api.ensure_thumbnails(state.home_mixes, store.publish, "mixes")
			end
		end
		store.publish()
	end

	Cache.fetch_stats()
end

return Cache
