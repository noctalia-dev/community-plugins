--!strict

-- browse/home/library endpoints + parse.

local logger = require("../utils/log.luau")
local log = logger.module("ytapi", "browse")

local helpers = require("../utils/helpers.luau")
local sanitize = helpers.sanitize
local clean_artist = helpers.clean_artist
local fmt_seconds = helpers.fmt_seconds

local const = require("./constants.luau")
local CONTEXT = const.CONTEXT
local ORIGIN = const.ORIGIN
local COOKIE_PATH = const.COOKIE_PATH
local QUICK_PICKS_CACHE_PATH = const.QUICK_PICKS_CACHE_PATH

local scratch = require("../utils/scratch.luau")
local network = require("../utils/network.luau")

local it = require("./innerTube.luau")
local build_auth = it.build_auth

local thumbs = require("./thumbnails.luau")
local attach_cached_thumbs = thumbs.attach_cached_thumbs
local cache = require("./cache.luau")
local save_library_cache = cache.save_library_cache

local types = require("../utils/types.luau")

local EXPO = {}

local pending_library: any? = nil

function EXPO.library()
	log("library called")
	local body_json = noctalia.json.encode({ context = CONTEXT.context, browseId = "FEmusic_library_landing" }) or ""
	local auth = build_auth()
	local auth_header = auth and ('-H "Authorization: ' .. auth .. '"') or ""
	local origin_header = '-H "Origin: ' .. ORIGIN .. '"'

	local tmp_payload = scratch.path("lib-payload")
	local tmp_raw = scratch.path("lib-raw")
	local tmp_out = scratch.path("lib-out")
	noctalia.writeFile(tmp_payload, body_json)

	local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"]=] .. tmp_payload .. [=[" > "]=] .. tmp_raw .. [=[" 2>/dev/null

jq '{
  playlists: [.. | select(.musicTwoRowItemRenderer? != null) | .musicTwoRowItemRenderer | {
    id: (.navigationEndpoint.browseEndpoint.browseId // ""),
    title: (.title.runs[0].text // ""),
    subtitle: ([.subtitle.runs[]?.text] | join("")),
    thumbnail_url: (.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "")] | unique_by(.id)
}' "]=] .. tmp_raw .. [=[" > "]=] .. tmp_out .. [=[" 2>/dev/null
echo "STATUS=OK"
]=]

	network.runAsync(script, function(res)
		local out = (type(res) == "table" and res.stdout) or ""
		if out:find("STATUS=OK") and noctalia.fileExists(tmp_out) then
			local raw = noctalia.readFile(tmp_out)
			local data = noctalia.json.decode(raw or "")
			local raw_pls = (type(data) == "table" and type(data.playlists) == "table") and data.playlists or {}
			local playlists = {}
			local liked_item = nil
			for _, item in ipairs(raw_pls) do
				local cnt = tonumber(tostring(item.subtitle or ""):match("(%d+)%s+tracks")) or 0
				local pl_obj = {
					id = item.id,
					title = item.title,
					subtitle = item.subtitle,
					count = cnt,
					thumbnail_url = item.thumbnail_url,
				}
				if item.id == "VLLM" or item.title:lower():find("liked", 1, true) then
					liked_item = pl_obj
				else
					table.insert(playlists, pl_obj)
				end
			end
			if liked_item then
				table.insert(playlists, 1, liked_item)
			end
			if #playlists > 0 then
				attach_cached_thumbs(playlists)
				save_library_cache(playlists)
			end
			pending_library = playlists
		else
			pending_library = {}
		end
	end, 15000)
end

function EXPO.library_pending()
	return pending_library ~= nil
end

function EXPO.finish_library(cb: (any?, string?) -> ()?)
	local playlists = pending_library
	pending_library = nil
	if cb then
		cb(playlists or {})
	end
end

function EXPO.playlist_page(
	playlist_id: string?,
	continuation_token: string?,
	cb: (types.PlaylistPageResult?, string?) -> ()
)
	if type(playlist_id) ~= "string" or playlist_id == "" then
		cb({ tracks = {}, next_token = nil })
		return
	end
	local pid = sanitize(playlist_id)

	local is_cont = continuation_token and continuation_token ~= ""
	local body_json
	if is_cont then
		body_json = noctalia.json.encode({ context = CONTEXT.context, continuation = continuation_token }) or ""
	else
		body_json = noctalia.json.encode({ context = CONTEXT.context, browseId = pid }) or ""
	end

	local auth = build_auth()
	local auth_header = auth and ('-H "Authorization: ' .. auth .. '"') or ""
	local origin_header = '-H "Origin: ' .. ORIGIN .. '"'

	local tmp_payload = scratch.path("pl-payload")
	local tmp_raw = scratch.path("pl-raw")
	local tmp_out = scratch.path("pl-out")
	noctalia.writeFile(tmp_payload, body_json)

	local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"]=] .. tmp_payload .. [=[" > "]=] .. tmp_raw .. [=["

jq '{
  tracks: [.. | .musicResponsiveListItemRenderer? | select(. != null) | {
    id: (.playlistItemData.videoId // .navigationEndpoint.watchEndpoint.videoId // ""),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "")],
  count_text: ([.. | .musicResponsiveHeaderRenderer? | select(. != null) | (.subtitle?.runs // []) + (.secondSubtitle?.runs // []) | .[]?.text | select(. != null and test("song|track"))] | .[0] // null),
  next_token: ([.. | (.continuationCommand?.token // .nextContinuationData?.continuation) | select(. != null and . != "")] | .[0] // null)
}' "]=] .. tmp_raw .. [=[" > "]=] .. tmp_out .. [=["
echo "BROWSE_OK"
]=]

	network.runAsync(script, function(res)
		-- Success token, not file existence: scratch outputs from earlier runs
		-- must never be mistaken for a fresh response (offline gate skips the
		-- script but leaves old files behind).
		local out = (type(res) == "table" and res.stdout) or ""
		if not out:find("BROWSE_OK", 1, true) or not noctalia.fileExists(tmp_out) then
			cb({ tracks = {}, next_token = nil })
			return
		end
		local raw = noctalia.readFile(tmp_out)
		if not raw or raw == "" then
			cb({ tracks = {}, next_token = nil })
			return
		end
		local data = noctalia.json.decode(raw)
		if type(data) == "table" then
			local tracks = type(data.tracks) == "table" and data.tracks or {}
			-- YT duplicates shelf rows inside one payload; keep first-seen only
			local seen, uniq = {}, {}
			for _, tr in ipairs(tracks) do
				if tr.id and not seen[tr.id] then
					seen[tr.id] = true
					table.insert(uniq, tr)
				end
			end
			tracks = uniq
			for _, tr in ipairs(tracks) do
				if tr.duration_text and tr.duration_text ~= "" then
					tr.duration = fmt_seconds(tr.duration_text)
				end
				tr.artist = clean_artist(tr.artist)
			end
			local next_tok = type(data.next_token) == "string" and data.next_token ~= "" and data.next_token or nil
			local count_text = type(data.count_text) == "string" and data.count_text or ""
			local count_num = tonumber(count_text:match("(%d+)"))
			log(
				"jq playlist page got "
					.. #tracks
					.. " tracks, next_token="
					.. tostring(next_tok ~= nil)
					.. ", count_num="
					.. tostring(count_num)
			)
			if #tracks > 0 then
				attach_cached_thumbs(tracks)
			end
			cb({ tracks = tracks, next_token = next_tok, total_count = count_num })
		else
			cb({ tracks = {}, next_token = nil })
		end
	end, 15000)
end

-- Artist page (browseId UC…): top-ish tracks from the first shelves plus
-- albums/singles/playlists as related rows. Offline callers get nothing —
-- the network gate skips the script.
function EXPO.artist_page(browse_id: string, cb: (any) -> ())
	if type(browse_id) ~= "string" or browse_id == "" then
		cb({ tracks = {}, related = {} })
		return
	end

	local tmp_payload = scratch.path("ar-payload")
	local tmp_raw = scratch.path("ar-raw")
	local tmp_out = scratch.path("ar-out")
	local auth = build_auth()
	local auth_header = auth and ('-H "Authorization: ' .. auth .. '"') or ""
	local origin_header = '-H "Origin: ' .. ORIGIN .. '"'
	noctalia.writeFile(
		tmp_payload,
		noctalia.json.encode({ context = CONTEXT.context, browseId = sanitize(browse_id) }) or ""
	)

	local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"]=] .. tmp_payload .. [=[" > "]=] .. tmp_raw .. [=["

jq '{
  tracks: [.. | .musicResponsiveListItemRenderer? | select(. != null) | {
    id: (.playlistItemData.videoId // .overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId // ""),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""),
    duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "")] | unique_by(.id)
    | .[0:30],
  related: [.. | .musicTwoRowItemRenderer? | select(. != null) | {
    id: (.navigationEndpoint.browseEndpoint.browseId // ""),
    title: (.title.runs[0].text // ""),
    artist: (.subtitle.runs[0].text // ""),
    thumbnail_url: (
      .thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails[-1].url //
      .thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // ""
    )
  } | select(.id != "" and .title != "" and ((.id | startswith("MPRE")) or (.id | startswith("VL"))))] | unique_by(.id)
    | .[0:8]
}' "]=] .. tmp_raw .. [=[" > "]=] .. tmp_out .. [=["
echo "BROWSE_OK"
]=]

	network.runAsync(script, function(res)
		local out = (type(res) == "table" and res.stdout) or ""
		if not out:find("BROWSE_OK", 1, true) or not noctalia.fileExists(tmp_out) then
			cb({ tracks = {}, related = {} })
			return
		end
		local raw = noctalia.readFile(tmp_out)
		local data = raw and noctalia.json.decode(raw)
		if type(data) ~= "table" then
			cb({ tracks = {}, related = {} })
			return
		end
		local tracks = type(data.tracks) == "table" and data.tracks or {}
		for _, tr in ipairs(tracks) do
			if tr.duration_text and tr.duration_text ~= "" then
				tr.duration = fmt_seconds(tr.duration_text)
			end
			tr.artist = clean_artist(tr.artist)
		end
		if #tracks > 0 then
			attach_cached_thumbs(tracks)
		end
		cb({ tracks = tracks, related = type(data.related) == "table" and data.related or {} })
	end, 15000)
end

function EXPO.load_cached_quick_picks()
	if not noctalia.fileExists(QUICK_PICKS_CACHE_PATH) then
		return nil
	end
	local raw = noctalia.readFile(QUICK_PICKS_CACHE_PATH)
	if not raw or raw == "" then
		return nil
	end
	local data = noctalia.json.decode(raw)
	if type(data) == "table" and #data > 0 then
		attach_cached_thumbs(data)
		return data
	end
	return nil
end

function EXPO.save_quick_picks_cache(tracks: { types.Track }?)
	if type(tracks) ~= "table" or #tracks == 0 then
		return
	end
	local encoded = noctalia.json.encode(tracks)
	if encoded then
		noctalia.writeFile(QUICK_PICKS_CACHE_PATH, encoded)
	end
end

function EXPO.fetch_quick_picks(callback: ((any?, any?) -> ())?)
	local body_json = noctalia.json.encode({ context = CONTEXT.context, browseId = "FEmusic_home" }) or ""
	local auth = build_auth()
	local auth_header = auth and ('-H "Authorization: ' .. auth .. '"') or ""
	local origin_header = '-H "Origin: ' .. ORIGIN .. '"'

	local tmp_payload = scratch.path("qp-payload")
	local tmp_raw = scratch.path("qp-raw")
	local tmp_out = scratch.path("qp-out")
	noctalia.writeFile(tmp_payload, body_json)

	local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"]=] .. tmp_payload .. [=[" > "]=] .. tmp_raw .. [=["

jq '{
  tracks: [.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer | {
    id: (.playlistItemData.videoId // .navigationEndpoint.watchEndpoint.videoId // ""),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "")] | unique_by(.id) | .[0:15],
  mixes: [.. | select(.musicTwoRowItemRenderer? != null) | .musicTwoRowItemRenderer | {
    id: (.navigationEndpoint.browseEndpoint.browseId // .navigationEndpoint.watchEndpoint.playlistId // ""),
    title: (.title.runs[0].text // ""),
    subtitle: (.subtitle.runs[0].text // ""),
    videoId: (.navigationEndpoint.watchEndpoint.videoId // ""),
    thumbnail_url: (.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // .thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "" and .videoId == "" and (.id | test("^(VL)?RD")) and (.subtitle != "Album") and (.subtitle != "Playlist") and (.subtitle != "Song") and (.subtitle != "Single") and (.subtitle | endswith("subscribers") | not))] | unique_by(.id) | .[0:60]
}' "]=] .. tmp_raw .. [=[" > "]=] .. tmp_out .. [=[" 2>/dev/null
echo "STATUS=OK"
]=]

	network.runAsync(script, function(res)
		local out = (type(res) == "table" and res.stdout) or ""
		if out:find("STATUS=OK") and noctalia.fileExists(tmp_out) then
			local raw = noctalia.readFile(tmp_out)
			local data = noctalia.json.decode(raw or "")
			local tracks = (type(data) == "table" and type(data.tracks) == "table") and data.tracks or {}
			local mixes = (type(data) == "table" and type(data.mixes) == "table") and data.mixes or {}
			if #tracks > 0 then
				attach_cached_thumbs(tracks)
				EXPO.save_quick_picks_cache(tracks)
			end
			if #mixes > 0 then
				math.randomseed(os.time() + #mixes)
				for i = #mixes, 2, -1 do
					local j = math.random(1, i)
					mixes[i], mixes[j] = mixes[j], mixes[i]
				end
				-- Keep up to 24 candidate mixes for filtering
				for i = #mixes, 25, -1 do
					table.remove(mixes)
				end
				attach_cached_thumbs(mixes)
			end
			if callback then
				callback(tracks, mixes)
			end
		else
			if callback then
				callback({}, {})
			end
		end
	end, 15000)
end

return EXPO
