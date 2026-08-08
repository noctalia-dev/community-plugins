--!nonstrict
-- dictionary-english — launcher provider.
--
-- `/dic <word>` autocompletes headwords from the pre-built prefix.json index
-- (a map of first-two-letters -> sorted headwords, built at data-generation
-- time). Reading the small index keeps the launcher fast; the full dictionary
-- is only decoded by the panel when a word is selected.


local PANEL_ID = "weinguyen/dictionary-english:panel"
local STATE_KEY = "dictionary-english.word"
local MAX_RESULTS = 10
-- Cap how many words are fed to fuzzyScore per query. Sorting the whole
-- 1731-word "co" bucket would blow the per-callback CPU budget.
local FUZZY_SCAN = 200

-- prefixIndex[first2] = { words starting with that 2-char prefix }.
-- Lets onQuery scan only the relevant bucket instead of all 50k headwords,
	-- which would blow the per-callback CPU budget.
local prefixIndex = {}

-- Search history, newest first, persisted in the plugin data dir so it
-- survives restart/update. Shown in the launcher when the query is empty.
local HISTORY_MAX = 20
local HISTORY_GLYPH = "history"
local historyPath
local function historyLocation()
	if historyPath == nil then
		local dir, err = noctalia.pluginDataDir()
		if type(dir) == "string" then
			historyPath = dir .. "/history.json"
		else
			noctalia.log("dictionary-english: data dir unavailable: " .. tostring(err))
			historyPath = false
		end
	end
	return historyPath
end

-- Returns the search history as a list of words (newest first), or {}.
-- Re-reads the file on every call so it is always current across entries.
local function loadHistory()
	local path = historyLocation()
	if not path then
		return {}
	end
	local raw = noctalia.readFile(path)
	if type(raw) ~= "string" or raw == "" then
		return {}
	end
	local data = noctalia.json.decode(raw)
	if type(data) ~= "table" then
		return {}
	end
	local out = {}
	for _, w in ipairs(data) do
		if type(w) == "string" then
			out[#out + 1] = w
		end
	end
	return out
end

-- Record a searched word: drop duplicates, prepend, cap the size, persist.
local function recordHistory(word)
	local list = loadHistory()
	for i = #list, 1, -1 do
		if list[i] == word then
			table.remove(list, i)
		end
	end
	table.insert(list, 1, word)
	if #list > HISTORY_MAX then
		for i = #list, HISTORY_MAX + 1, -1 do
			table.remove(list)
		end
	end
	local path = historyLocation()
	if path then
		noctalia.writeFile(path, noctalia.json.encode(list))
	end
end

-- Results for an empty query: the search history, or a hint when empty.
local function historyResults()
	local list = loadHistory()
	local results = {}
	for _, w in ipairs(list) do
		results[#results + 1] = { id = w, title = w, glyph = HISTORY_GLYPH }
		if #results >= HISTORY_MAX then
			break
		end
	end
	if #results == 0 then
		results[1] = {
			id = "",
			title = "Type a word to look up",
			subtitle = "e.g. abandon, a priori, 24/7",
			glyph = "book",
		}
	end
	return results
end


local function lower(s)
	return string.lower(s)
end

local function loadIndex()
	local raw = noctalia.readFile("assets/dictionary/prefix.json")
	if type(raw) ~= "string" or raw == "" then
		noctalia.log("dictionary-english: could not read assets/dictionary/prefix.json")
		return
	end
	local data = noctalia.json.decode(raw)
	if type(data) ~= "table" then
		noctalia.log("dictionary-english: failed to parse assets/dictionary/prefix.json")
		return
	end
	prefixIndex = data
end

local function matchResults(query)
	local q = lower(query)
	local bucket = prefixIndex[q:sub(1, 2)] or {}

	-- Rank every word in the (narrow) prefix bucket: exact and start-with
	-- matches always outrank fuzzy ones, and within each group a shorter word
	-- ranks higher. Sorting on the rank keeps the closest suggestion on top
	-- instead of bucket order, so e.g. "abandon" beats "absentee-landlord"
	-- when the user types "abandon".
	local prefixBest = {}
	local fuzzyBest = {}
	local scans = 0

	for _, word in ipairs(bucket) do
		local wl = lower(word)
		if wl == q then
			prefixBest[#prefixBest + 1] = { rank = 4096, id = word }
		elseif wl:sub(1, #q) == q then
			local diff = #wl - #q
			prefixBest[#prefixBest + 1] = { rank = 2048 - diff, id = word }
		elseif scans < FUZZY_SCAN then
			scans = scans + 1
			local s = noctalia.fuzzyScore(query, word)
			if s ~= nil then
				fuzzyBest[#fuzzyBest + 1] = { rank = s, id = word }
			end
		end
	end

	table.sort(prefixBest, function(a, b) return a.rank > b.rank end)
	table.sort(fuzzyBest, function(a, b) return a.rank > b.rank end)

	local results = {}
	for _, p in ipairs(prefixBest) do
		results[#results + 1] = { id = p.id, title = p.id, glyph = "book" }
		if #results >= MAX_RESULTS then
			return results
		end
	end
	for _, f in ipairs(fuzzyBest) do
		results[#results + 1] = { id = f.id, title = f.id, glyph = "book", score = f.rank }
		if #results >= MAX_RESULTS then
			break
		end
	end
	return results
end

function onQuery(query)
	query = noctalia.string.trim(query)
	if query == "" then
		launcher.setResults(query, historyResults())
		return
	end
	launcher.setResults(query, matchResults(query))
end

function onActivate(id)
	if id == "" then
		return
	end
	recordHistory(id)
	noctalia.state.set(STATE_KEY, id)
	noctalia.togglePanel(PANEL_ID)
end

loadIndex()
