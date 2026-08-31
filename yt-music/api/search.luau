--!strict
--!nolint MultiLineStatement

local logger = require("../utils/log.luau")
local log = logger.module("ytapi", "search")

local helpers = require("../utils/helpers.luau")
local sanitize = helpers.sanitize
local clean_artist = helpers.clean_artist
local fmt_seconds = helpers.fmt_seconds

local const = require("./constants.luau")
local CONTEXT = const.CONTEXT

local scratch = require("../utils/scratch.luau")

local it = require("./innerTube.luau")
local innerTube = it.innerTube

local types = require("../utils/types.luau")

local EXPO = {}

local PLAYLISTS_PARAMS = "EgeKAQQoADgBKAI6AklTUAFQBRAFEAkQBA%3D%3D"

-- Featured-playlist search paginates via shelf continuation tokens; a single
-- page only carries ~5 rows.
function EXPO.search_playlists(q: string, count: number, cb: ({ types.SearchResult }?, string?) -> ())
	local out: { types.SearchResult } = {}
	local seen: { [string]: boolean } = {}
	local pages = 0

	local function finish()
		log(
			string.format(
				"search got %d results type='playlists' first='%s'",
				#out,
				tostring(out[1] and out[1].title)
			)
		)
		cb(out)
	end

	local function fetch(token: string?)
		pages += 1
		local req: any = { context = CONTEXT.context }
		if token then
			req.continuation = token
		else
			req.query = q
			req.params = PLAYLISTS_PARAMS
		end
		innerTube("search", req, function(raw_body, err)
			if not raw_body or raw_body == "" then
				if #out > 0 then
					finish()
				else
					cb(nil, err or "empty response")
				end
				return
			end
			local raw_file = scratch.path("search-raw")
			local clean_file = scratch.path("search-clean")
			noctalia.writeFile(raw_file, raw_body)
			local script = ([=[
jq '{
  playlists: [.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer |
    # pageType must be read off the RAW row; past the object pipe it no longer exists.
    (.navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType // "") as $pt |
    {
    id: (.navigationEndpoint.browseEndpoint.browseId // ""),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(
      (.id != "" and .title != "")
      and ($pt == "MUSIC_PAGE_TYPE_PLAYLIST")
  )],
  token: ([.. | objects | select(has("nextContinuationData")) | .nextContinuationData.continuation] | last // "")
}' "%s" > "%s" 2>/dev/null
echo "STATUS=OK"
]=]):format(raw_file, clean_file)
			noctalia.runAsync(script, function(_res)
				local data: any = nil
				if noctalia.fileExists(clean_file) then
					data = noctalia.json.decode(noctalia.readFile(clean_file) or "")
				end
				local rows = (type(data) == "table" and type(data.playlists) == "table") and data.playlists or {}
				for _, tr in ipairs(rows) do
					if not seen[tr.id] then
						seen[tr.id] = true
						table.insert(out, {
							type = "playlist",
							id = tr.id,
							title = tr.title,
							artist = clean_artist(tr.artist),
							thumbnail_url = tr.thumbnail_url,
						})
						if #out >= count then
							break
						end
					end
				end
				local next_token = (type(data) == "table" and type(data.token) == "string") and data.token or ""
				if #out >= count or next_token == "" or pages >= 8 then
					finish()
				else
					fetch(next_token)
				end
			end)
		end, true)
	end

	fetch(nil)
end

function EXPO.search(query: string?, count: any, cb: ({ types.SearchResult }?, string?) -> (), search_type: string?)
	local q: string = tostring(sanitize(query)):gsub("^%s+", ""):gsub("%s+$", "")
	count = tonumber(count) or 25
	local st: string = tostring(search_type or "songs")
	log("search query='" .. q .. "' type='" .. st .. "'")
	if q == "" then
		cb({})
		return
	end
	if st == "playlists" then
		EXPO.search_playlists(q, count, cb)
		return
	end
	local params = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
	if st == "top" then
		params = ""
	end
	innerTube("search", {
		context = CONTEXT.context,
		query = q,
		params = params,
	}, function(raw_body, err)
		if not raw_body or raw_body == "" then
			cb(nil, err or "empty response")
			return
		end
		local raw_file = scratch.path("search-raw")
		local clean_file = scratch.path("search-clean")
		noctalia.writeFile(raw_file, raw_body)

		local script
		if st == "top" then
			script = ([=[
jq '
  ([.. | objects | select(has("musicCardShelfRenderer")) | .musicCardShelfRenderer] | .[0] // null) as $rawcard
  |
  ([
    .. | objects | select(has("musicCardShelfRenderer")) | .musicCardShelfRenderer |
    .contents[]? |
    .. | objects | select(has("musicResponsiveListItemRenderer")) |
    .musicResponsiveListItemRenderer |
    (.playlistItemData.videoId // "")
  ] | map(select(. != ""))) as $skip
  |
  # Artist identity lives on the card TITLE navigation only; scanning the
  # whole subtree would catch per-row "Go to artist" menus of song cards.
  ([$rawcard.title.runs[]? | select((.navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType // "") == "MUSIC_PAGE_TYPE_ARTIST") | .navigationEndpoint.browseEndpoint.browseId] | .[0] // null) as $card_artist_id
  |
  ([$rawcard | select(((.onTap.watchEndpoint.videoId // "") != "") or ($card_artist_id != null)) | {
    id: ((.onTap.watchEndpoint.videoId // $card_artist_id) // ""),
    kind: (if (.onTap.watchEndpoint.videoId // "") != "" then "song" elif ($card_artist_id != null) then "artist" else "song" end),
    title: (.title.runs[0].text // ""),
    artist: ([.subtitle.runs[].text] | join("")),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  }] | .[0] // null) as $card
  |
  {
    results: reduce (
      ($card // empty),
      (.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer |
        ((.playlistItemData.videoId // .overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId // .doubleTapCommand.watchEndpoint.videoId // "") as $vid |
         (.navigationEndpoint.browseEndpoint.browseId // "") as $bid |
         select($vid != "" or $bid != "") |
         select(($skip | index($vid)) == null) |
         {
           id: (if $vid != "" then $vid else $bid end),
           kind: (if $vid != "" then "song" else if $bid != "" then "playlist" else "other" end end),
           title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
           artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""),
           album: (.flexColumns[2].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
           duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
           thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
         }))
    ) as $it ([]; if (map(.id) | index($it.id)) then . else . + [$it] end)
  }
' "%s" > "%s" 2>/dev/null
echo "STATUS=OK"
]=]):format(raw_file, clean_file)
		else
            script = ([=[
jq '{
  tracks: [.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer | {
    id: (.playlistItemData.videoId // .overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId // .doubleTapCommand.watchEndpoint.videoId // ""),
    kind: (
      (.playlistItemData.videoId // "") as $vid |
      (.navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType // "") as $pt |
      if $vid != "" then "song"
      elif $pt == "MUSIC_PAGE_TYPE_ARTIST" then "artist"
      else ""
      end
    ),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""),
    album: (.flexColumns[2].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.kind == "song" and .title != "")] | unique_by(.id)
}' "%s" > "%s" 2>/dev/null
echo "STATUS=OK"
]=]):format(raw_file, clean_file)
        end

		noctalia.runAsync(script, function(res)
			local out: { types.SearchResult } = {}
			if noctalia.fileExists(clean_file) then
				local raw_clean = noctalia.readFile(clean_file)
				local data = noctalia.json.decode(raw_clean or "")
				local raw_key = (st == "top") and "results" or "tracks"
				local raw_items = (type(data) == "table" and type(data[raw_key]) == "table") and data[raw_key] or {}
				for _, tr in ipairs(raw_items) do
					if st == "top" and tr.kind == "playlist" then
						table.insert(out, {
							type = "playlist",
							id = tr.id,
							title = tr.title,
							artist = clean_artist(tr.artist),
							thumbnail_url = tr.thumbnail_url,
						})
					elseif tr.kind == "artist" then
						table.insert(out, {
							type = "artist",
							id = tr.id,
							title = tr.title,
							artist = clean_artist(tr.artist),
							thumbnail_url = tr.thumbnail_url,
						})
					else
						table.insert(out, {
							id = tr.id,
							title = tr.title,
							artist = clean_artist(tr.artist),
							album = tr.album,
							duration = fmt_seconds(tr.duration_text),
							duration_text = tr.duration_text,
							thumbnail_url = tr.thumbnail_url,
						})
					end
					if #out >= count then
						break
					end
				end
			end
			log(
				string.format("search got %d results type='%s' first='%s'", #out, st, tostring(out[1] and out[1].title))
			)
			cb(out)
		end)
	end, true)
end

return EXPO
