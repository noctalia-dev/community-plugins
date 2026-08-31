--!strict

-- thumbnail path/ensure/attach helpers.

local const = require("./constants.luau")
local THUMB_DIR = const.THUMB_DIR

local scratch = require("../utils/scratch.luau")
local network = require("../utils/network.luau")
local Bash = require("../utils/bash.luau")

local EXPO = {}

-- Thumbnail filename = stable resource id extracted from the URL itself:
--   yt3.googleusercontent.com/<seg>=w120…   → <seg>
--   i.ytimg.com/vi/<videoId>/hqdefault.jpg  → <videoId>
-- Identical covers therefore collapse to one file/download with zero hashing
-- or extra machinery. Unrecognised shapes fall back to the legacy per-id name
-- (dedup skipped for those, none observed in practice).
local function thumb_key(url): string?
	if type(url) ~= "string" or url == "" then
		return nil
	end
	local seg1 = url:match("yt3%.googleusercontent%.com/([^/=]+)")
	if seg1 and seg1 ~= "" then
		return seg1
	end
	local seg2 = url:match("lh3%.googleusercontent%.com/([^/=]+)")
	if seg2 and seg2 ~= "" then
		return seg2
	end
	local vid = url:match("i%.ytimg%.com/vi/([%w%-_]+)")
	if vid and vid ~= "" then
		return vid
	end
	return nil
end

-- Content-addressed thumbnail path: one file per unique source resource, so
-- album playlists sharing a cover download (and store) it exactly once.
-- Falls back to the legacy per-id name when no key is extractable.
function EXPO.path_for(id: string, url: string?): string
	local key = thumb_key(url)
	if key then
		return THUMB_DIR .. "/" .. key .. ".jpg"
	end
	return THUMB_DIR .. "/" .. id .. ".jpg"
end

local path_for = EXPO.path_for

function EXPO.get_thumbnail_path(id: string, url: string?, callback: ((string) -> ())?): string?
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local path = path_for(id, url)

	if noctalia.fileExists(path) then
		return path
	end

	if type(url) == "string" and url ~= "" then
		network.runAsync(
			"mkdir -p "
				.. Bash.sh_quote(THUMB_DIR)
				.. " && curl -s -L -o "
				.. Bash.sh_quote(path)
				.. " "
				.. Bash.sh_quote(url),
			function()
				if noctalia.fileExists(path) and callback then
					callback(path)
				end
			end,
			10000
		)
	end

	return nil
end

local known_thumb_files = {}

local function preload_thumb_cache()
	noctalia.runAsync("find /tmp -name 'yt-music-thumb-*.jpg' 2>/dev/null", function(res)
		local out = type(res) == "table" and res.stdout or ""
		for line in out:gmatch("[^\r\n]+") do
			known_thumb_files[line] = true
		end
	end)
end
preload_thumb_cache()

function EXPO.ensure_thumbnails(items, on_updated, tag)
	if type(items) ~= "table" or #items == 0 then
		return
	end

	local missing = {}
	local updated_cached = false

	for _, item in ipairs(items) do
		if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
			if not item.thumb_path then
				local url = (type(item.thumbnail_url) == "string" and item.thumbnail_url ~= "") and item.thumbnail_url
					or ("https://i.ytimg.com/vi/" .. item.id .. "/hqdefault.jpg")
				local path = path_for(item.id, url)
				if known_thumb_files[path] then
					item.thumb_path = path
					updated_cached = true
				else
					table.insert(missing, { item = item, path = path, url = url })
				end
			end
		end
	end

	if #missing == 0 then
		if updated_cached and type(on_updated) == "function" then
			on_updated()
		end
		return
	end

	local configFile = scratch.path("thumbcfg")
	-- One config entry per unique output path: same-resource covers collapse
	-- to a single download instead of one per track.
	local lines = {}
	local seen_paths = {}
	for _, m in ipairs(missing) do
		if not seen_paths[m.path] then
			seen_paths[m.path] = true
			-- curl -K config values: strip quotes/control chars so a hostile URL
			-- cannot inject additional curl options via the config file
			local safe_url = tostring(m.url):gsub('[%c"]', "")
			table.insert(lines, string.format('output = "%s"\nurl = "%s"', m.path, safe_url))
		end
	end
	noctalia.writeFile(configFile, table.concat(lines, "\n"))

	local script = ([=[
mkdir -p "%s"
if command -v curl >/dev/null 2>&1; then
  curl -s --parallel --parallel-max 16 --parallel-immediate -K "%s" >/dev/null 2>&1
fi
echo "THUMBS_DONE=1"
]=]):format(THUMB_DIR, configFile)

	network.runAsync(script, function(res)
		local out = (type(res) == "table" and res.stdout) or ""
		if out:find("THUMBS_DONE=1") then
			for _, m in ipairs(missing) do
				known_thumb_files[m.path] = true
				m.item.thumb_path = m.path
			end
			if type(on_updated) == "function" then
				on_updated()
			end
		end
	end, 15000)
end

function EXPO.attach_cached_thumbs(items: { { [string]: any } })
	if type(items) ~= "table" then
		return
	end
	local count = #items
	if count > 50 then
		count = 50
	end
	for i = 1, count do
		local item = items[i]
		if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
			local path = path_for(item.id, item.thumbnail_url)
			if noctalia.fileExists(path) then
				item.thumb_path = path
			end
		end
	end
end

return EXPO
