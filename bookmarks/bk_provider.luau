-- Launcher provider: "/bk" fuzzy-searches bookmark labels (root + one level
-- of folders, bookmarks only - same scope as the panel's own search) and
-- runs the selected one on activation. Reads the same data.json the panel
-- writes, resolved via shared.luau, so no state is shared beyond the file on disk.

local shared = require("./shared.luau")

-- Bookmarks are indexed by a stable synthetic id (path-qualified label),
-- rather than by array position, since onActivate only receives the id
-- string and the list is re-read from disk on every query.
local function resultId(item)
	return (item.path or "") .. "\30" .. (item.entry.label or "")
end

local function buildResults(query)
	local bookmarks = shared.loadBookmarks()
	local flat = shared.flatten(bookmarks)

	local results = {}
	for _, item in ipairs(flat) do
		local score
		if query == "" then
			score = 0
		else
			score = noctalia.fuzzyScore(query, item.entry.label or "")
		end
		if score ~= nil then
			table.insert(results, {
				id = resultId(item),
				title = item.entry.label or "",
				subtitle = item.path,
				glyph = item.entry.glyph or "bookmark",
				score = score,
			})
		end
	end

	table.sort(results, function(a, b)
		return (a.score or 0) > (b.score or 0)
	end)
	return results
end

local function providerEnabled()
	return noctalia.getConfig("enable_bk_provider") == true
end

-- "history" (most-recently-used first) or "usage_count" (most-frequently-
-- used first). Only affects ordering when the query is empty; a non-empty
-- query always ranks by fuzzy match score, same as before.
local function sortBy()
	local value = noctalia.getConfig("bk_sort_by")
	if value == "usage_count" then
		return "usage_count"
	end
	return "history"
end

local function statsPath()
	local dataDir = noctalia.pluginDataDir()
	if dataDir == nil then
		return nil
	end
	return dataDir .. (sortBy() == "history" and "/bk_history.json" or "/bk_usage.json")
end

-- Reads and decodes the current stats file (history array or usage-count
-- map, per sortBy()), falling back to an empty table when the file is
-- missing, unreadable, or corrupt. Shared by getSortScores/recordActivation
-- so the read/decode/default boilerplate only lives in one place.
local function readStatsData()
	local path = statsPath()
	if path == nil then
		return {}, nil
	end
	local file = noctalia.readFile(path)
	if file == nil then
		return {}, path
	end
	local decoded = noctalia.json.decode(file)
	if type(decoded) ~= "table" then
		return {}, path
	end
	return decoded, path
end

-- Scores used to order results when the query is empty, keyed by result id.
-- History ranks by recency (higher = more recently used); usage_count ranks
-- by frequency (higher = used more often). Reads/decodes the stats file
-- once for the whole batch rather than once per result. Ids missing from
-- the stats file fall back to 0 (unranked, sorted last).
local function getSortScores(ids)
	local data = readStatsData()
	local scores = {}

	if sortBy() == "history" then
		for _, id in ipairs(ids) do
			local i = table.find(data, id)
			scores[id] = i ~= nil and (#data - i) or 0
		end
	else
		for _, id in ipairs(ids) do
			scores[id] = data[id] or 0
		end
	end

	return scores
end

-- Records an activation for ranking purposes: pushes `id` to the front of
-- the history list, or increments its usage count, depending on `sort_by`.
local function recordActivation(id)
	local data, path = readStatsData()
	if path == nil then
		return
	end

	if sortBy() == "history" then
		local i = table.find(data, id)
		if i ~= nil then
			table.remove(data, i)
		end
		table.insert(data, 1, id)
	else
		data[id] = (data[id] or 0) + 1
	end

	local encoded = noctalia.json.encode(data)
	if encoded ~= nil then
		noctalia.writeFile(path, encoded)
	end
end

function onQuery(query)
	query = noctalia.string.trim(query)

	if not providerEnabled() then
		launcher.setResults(query, {})
		return
	end

	local results = buildResults(query)

	if query == "" then
		local ids = {}
		for _, result in ipairs(results) do
			table.insert(ids, result.id)
		end
		local scores = getSortScores(ids)
		for _, result in ipairs(results) do
			result.score = scores[result.id] or 0
		end
		table.sort(results, function(a, b)
			return (a.score or 0) > (b.score or 0)
		end)
	end

	if #results == 0 then
		launcher.setResults(query, {
			{
				id = "",
				title = noctalia.tr("no_bookmarks"),
				glyph = "bookmark-off",
			},
		})
		return
	end
	launcher.setResults(query, results)
end

function onActivate(id)
	if id == "" or not providerEnabled() then
		return
	end

	local wantPath, wantLabel = id:match("^([^\30]*)\30(.*)$")
	if wantLabel == nil then
		return
	end
	if wantPath == "" then
		wantPath = nil
	end

	local bookmarks = shared.loadBookmarks()
	for _, item in ipairs(shared.flatten(bookmarks)) do
		if item.entry.label == wantLabel and (item.path or nil) == wantPath then
			recordActivation(id)
			shared.runBookmark(item.entry)
			return
		end
	end
end
