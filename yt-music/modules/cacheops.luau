local store = require("./store.luau")

local api = require("../api.luau")
local state = store.state

local const = require("../api/constants.luau")
local AUDIO_DIR = const.AUDIO_DIR

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

-- Stats lines come in two shapes:
--   <size>|<path>          du -sh rows, keyed by dir basename
--   bytes|<name>|<n>       precomputed byte counts (audio split by intent)
local function parse_stats(res)
	if type(res) ~= "table" or not res.stdout then
		return
	end
	local stats = {}
	for line in res.stdout:gmatch("[^\r\n]+") do
		local kind, name, value = line:match("^(bytes)|([%w_]+)|(%d+)$")
		if kind then
			stats[name] = human_bytes(value)
		else
			local size, path = line:match("([^|]+)|(.+)")
			if size and path then
				local base = path:match("([^/]+)$")
				if base then
					stats[base] = size
				end
			end
		end
	end
	state.cache_stats = stats
	store.publish()
end

-- Audio is one shared dir, so its du total is split into downloads vs cached
-- using offline_meta.json (explicit saves) as the partition.
local STATS_SCRIPT = [[
    CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/yt-music"
    [ -d "$CACHE" ] || exit 0
    du -sh "$CACHE"/streams "$CACHE"/thumbnails "$CACHE"/playlists 2>/dev/null | awk '{print $1"|"$2}'
    META="$CACHE/offline_meta.json"
    TOTAL=$(du -sb "$CACHE/audio" 2>/dev/null | cut -f1)
    [ -n "$TOTAL" ] || TOTAL=0
    DL=0
    if [ -f "$META" ]; then
      DL=$(jq -r 'keys[] | $CACHE + "/audio/" + . + ".opus"' --arg CACHE "$CACHE" "$META" 2>/dev/null \
           | xargs -r -d '\n' du -cb 2>/dev/null | tail -1 | cut -f1)
      [ -n "$DL" ] || DL=0
    fi
    CACHED=$(( TOTAL - DL ))
    [ "$CACHED" -lt 0 ] && CACHED=0
    echo "bytes|audio|$TOTAL"
    echo "bytes|downloads|$DL"
    echo "bytes|cached_audio|$CACHED"
]]

local Cache = {}

function Cache.fetch_stats()
	noctalia.runAsync(STATS_SCRIPT, parse_stats)
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

local function rm_files(ids)
	local files = {}
	for vid in pairs(ids) do
		table.insert(files, "'" .. AUDIO_DIR .. "/" .. vid .. ".opus'")
	end
	if #files == 0 then
		return nil
	end
	return "rm -f " .. table.concat(files, " ")
end

function Cache.clear(target)
	if type(target) ~= "string" or not ALLOWED_TARGETS[target] then
		return
	end

	local script
	if target == "downloads" or target == "cached_audio" then
		-- Split the shared audio dir by intent:
		--   intentional  explicit ⬇ saves + every track of fully-downloaded playlists
		--   downloads    clears ONLY the intentional set
		--   cached_audio clears everything EXCEPT it
		local intentional = {}
		for vid in pairs(state.offline_meta or {}) do
			intentional[vid] = true
		end
		for pid in pairs(state.downloaded_playlist_ids or {}) do
			local tracks = api.load_cached_playlist(pid)
			if tracks then
				for _, tr in ipairs(tracks) do
					if tr.id then intentional[tr.id] = true end
				end
			end
		end

		local ids = {}
		if target == "downloads" then
			for vid in pairs(intentional) do
				ids[vid] = true
			end
		else
			for vid in pairs(state.cached_audio_ids or {}) do
				if not intentional[vid] then ids[vid] = true end
			end
		end
		script = rm_files(ids)
		if not script then
			noctalia.runAsync(STATS_SCRIPT, parse_stats)
			return
		end
	else
		script = ([[
			CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/yt-music"
			rm -rf "$CACHE/%s"/*
		]]):format(target)
	end

	noctalia.runAsync(script, function()
		-- After clearing, refresh stats; audio splits must also re-classify.
		noctalia.runAsync(STATS_SCRIPT, parse_stats)
		if target == "downloads" then
			state.offline_meta = {}
			require("./library.luau").save_offline_meta()
		end
		if target == "downloads" or target == "cached_audio" then
			require("./library.luau").sync_audio_cache()
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
	end)
end

return Cache
