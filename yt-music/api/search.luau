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

local filters = require("../utils/filters.luau")

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
		log(string.format("search got %d results type='playlists' first='%s'", #out, tostring(out[1] and out[1].title)))
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
			noctalia.writeFile(raw_file, raw_body)
			noctalia.runAsync({ "jq", "-a", filters.SEARCH_PLAYLISTS, raw_file }, function(res)
				local out_json = (type(res) == "table" and res.stdout) or ""
				local data = noctalia.json.decode(out_json)
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
	elseif st == "albums" then
		params = "EgWKAQIYAWoKEAkQBRAKEAMQBA%3D%3D"
	elseif st == "artists" then
		params = "EgWKAQIgAWoKEAkQBRAKEAMQBA%3D%3D"
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
		noctalia.writeFile(raw_file, raw_body)

		local filter = st == "top" and filters.SEARCH_TOP or filters.SEARCH_TRACKS

		noctalia.runAsync({ "jq", "-a", filter, raw_file }, function(res)
			local out: { types.SearchResult } = {}
			local out_json = (type(res) == "table" and res.stdout) or ""
			local data = noctalia.json.decode(out_json)
			local raw_key = (st == "top") and "results" or "tracks"
			local raw_items = (type(data) == "table" and type(data[raw_key]) == "table") and data[raw_key] or {}
			for idx, tr in ipairs(raw_items) do
				local item_title = helpers.clean_utf8(tr.title or "")
				local item_artist = clean_artist(tr.artist)
				local item_album = helpers.clean_utf8(tr.album or "")
				local is_top_hero = (st == "top" and idx == 1 and tr.kind == "artist")
				if tr.kind == "playlist" or tr.kind == "album" or (tr.id and tr.id:sub(1, 5) == "MPREb") then
					table.insert(out, {
						type = "playlist",
						id = tr.id,
						title = item_title,
						artist = item_artist,
						thumbnail_url = tr.thumbnail_url,
					})
				elseif tr.kind == "artist" then
					table.insert(out, {
						type = "artist",
						id = tr.id,
						title = item_title,
						artist = item_artist,
						is_hero = is_top_hero,
						thumbnail_url = tr.thumbnail_url,
					})
				else
					table.insert(out, {
						id = tr.id,
						title = item_title,
						artist = item_artist,
						album = item_album,
						duration = fmt_seconds(tr.duration_text),
						duration_text = tr.duration_text,
						thumbnail_url = tr.thumbnail_url,
					})
				end
				if #out >= count then
					break
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
