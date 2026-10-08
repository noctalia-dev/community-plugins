--!strict

-- browse/home/library endpoints + parse.

local logger = require("../utils/log.luau")
local log = logger.module("ytapi", "browse")

local helpers = require("../utils/helpers.luau")
local sanitize = helpers.sanitize
local clean_artist = helpers.clean_artist
local fmt_seconds = helpers.fmt_seconds

local filters = require("../utils/filters.luau")

local const = require("./constants.luau")
local CONTEXT = const.CONTEXT
local QUICK_PICKS_CACHE_PATH = const.QUICK_PICKS_CACHE_PATH

local scratch = require("../utils/scratch.luau")
local network = require("../utils/network.luau")

local it = require("./innerTube.luau")

local thumbs = require("./thumbnails.luau")
local attach_cached_thumbs = thumbs.attach_cached_thumbs
local cache = require("./cache.luau")
local save_library_cache = cache.save_library_cache

local types = require("../utils/types.luau")

local EXPO = {}

local pending_library: any? = nil

function EXPO.library()
	if not network.isOnline() then
		log("library: skipped network call because offline")
		return
	end
	log("library called")
	local tmp_raw = scratch.path("lib-raw")
	it.innerTube("browse", { context = CONTEXT.context, browseId = "FEmusic_library_landing" }, function(raw_body, _err)
		if not raw_body or raw_body == "" then
			pending_library = false
			return
		end
		noctalia.writeFile(tmp_raw, raw_body)
		local filter = filters.LIBRARY
		network.runAsync({ "jq", filter, tmp_raw }, function(res)
			local out = (type(res) == "table" and res.stdout) or ""
			if out == "" then
				pending_library = false
				return
			end
			local data = noctalia.json.decode(out)
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
				if item.id == "VLLM" or tostring(item.title or ""):lower():find("liked", 1, true) then
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
		end, 15000)
	end, true)
end

function EXPO.library_pending()
	return pending_library ~= nil
end

function EXPO.finish_library(cb: (any?, string?) -> ()?)
	local playlists = pending_library
	pending_library = nil
	if cb then
		if type(playlists) == "table" then
			cb(playlists)
		else
			cb(nil)
		end
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
	local req: any = { context = CONTEXT.context }
	if is_cont then
		req.continuation = continuation_token
	else
		req.browseId = pid
	end

	local tmp_raw = scratch.path("pl-raw")
	it.innerTube("browse", req, function(raw_body, _err)
		if not raw_body or raw_body == "" then
			cb({ tracks = {}, next_token = nil })
			return
		end
		noctalia.writeFile(tmp_raw, raw_body)
		local filter = filters.PLAYLIST_PAGE
		network.runAsync({ "jq", filter, tmp_raw }, function(res)
			local out = (type(res) == "table" and res.stdout) or ""
			if out == "" then
				cb({ tracks = {}, next_token = nil })
				return
			end
			local data = noctalia.json.decode(out)
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
	end, true)
end

-- Artist page (browseId UC…): top-ish tracks from the first shelves plus
-- albums/singles/playlists as related rows. Offline callers get nothing —
-- the network gate skips the script.
function EXPO.artist_page(browse_id: string, cb: (any) -> ())
	if type(browse_id) ~= "string" or browse_id == "" then
		cb({ tracks = {}, related = {} })
		return
	end

	local tmp_raw = scratch.path("ar-raw")
	it.innerTube("browse", { context = CONTEXT.context, browseId = sanitize(browse_id) }, function(raw_body, _err)
		if not raw_body or raw_body == "" then
			cb({ tracks = {}, related = {} })
			return
		end
		noctalia.writeFile(tmp_raw, raw_body)
		local filter = filters.ARTIST_PAGE
		network.runAsync({ "jq", filter, tmp_raw }, function(res)
			local out = (type(res) == "table" and res.stdout) or ""
			if out == "" then
				cb({ tracks = {}, related = {} })
				return
			end
			local data = noctalia.json.decode(out)
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
	end, true)
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
	local tmp_raw = scratch.path("qp-raw")
	it.innerTube("browse", { context = CONTEXT.context, browseId = "FEmusic_home" }, function(raw_body, _err)
		if not raw_body or raw_body == "" then
			if callback then
				callback({}, {})
			end
			return
		end
		noctalia.writeFile(tmp_raw, raw_body)
		local filter = filters.QUICK_PICKS
		network.runAsync({ "jq", filter, tmp_raw }, function(res)
			local out = (type(res) == "table" and res.stdout) or ""
			if out == "" then
				if callback then
					callback({}, {})
				end
				return
			end
			local data = noctalia.json.decode(out)
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
		end, 15000)
	end, true)
end

return EXPO
