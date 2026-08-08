--!nonstrict
-- dictionary-english — definition panel.
--
-- Reads the word published by the launcher provider and renders its English
-- definition(s) and example sentences. The dictionary is split into one file
-- per first three letters (assets/dictionary/chunks/<abc>.json) so the panel
-- decodes only the ~0.3 MB chunk for the selected word instead of the whole
-- dictionary, which would blow the per-callback CPU budget.
--
-- Schema (per headword):
--   word -> {
--     def: { <sense_label>: { <POS>: { <grammar>: [ [def_en, def_zh], ... ] } } },
--     example: [ [en, zh], ... ]
--   }
-- Only the English side of each pair is shown; the Chinese (zh) is skipped.

local STATE_KEY = "dictionary-english.word"

-- Human-readable labels for Cambridge POS/grammar codes. Anything not mapped
-- falls back to the raw code. Multi-code strings like "C usually singular" and
-- patterns like "+ to infinitive" are readable as-is and left unchanged.
local POS_LABEL = {
	N = "noun",
	V = "verb",
	ADJ = "adjective",
	e = "adverb",
	M = "modal verb",
	L = "linking verb",
	["I,T"] = "intransitive/transitive",
}

local GRAM_LABEL = {
	T = "transitive",
	I = "intransitive",
	C = "countable",
	U = "uncountable",
	S = "singular",
	L = "linking",
	plural = "plural",
	["C or U"] = "countable or uncountable",
	["U or C"] = "uncountable or countable",
	["I or T"] = "intransitive or transitive",
	["T or I"] = "transitive or intransitive",
	["S or U"] = "singular or uncountable",
	["U or S"] = "uncountable or singular",
	["C or S"] = "countable or singular",
	["S or C"] = "singular or countable",
	["C or S or U"] = "countable, singular or uncountable",
	["I,T"] = "intransitive/transitive",
	["+ to infinitive"] = "+ to-infinitive",
}

-- dictionary is the decoded chunk (map word -> entry) for the current word's
-- 3-letter prefix. keptChunk caches the prefix so re-selecting a word in the
-- same prefix avoids re-reading+decoding the file.
local dictionary = {}
local currentChunk = nil
local currentWord = nil

-- Load the chunk for the given word (its first 3 letters) and cache it.
local function loadForWord(word)
	local key = string.lower(word:sub(1, 3))
	if not key:match("%a") then
		dictionary = {}
		currentChunk = nil
		return
	end
	if key == currentChunk then
		return
	end
	local raw = noctalia.readFile("assets/dictionary/chunks/" .. key .. ".json")
	if type(raw) ~= "string" or raw == "" then
		dictionary = {}
		currentChunk = nil
		return
	end
	local data = noctalia.json.decode(raw)
	if type(data) == "table" then
		dictionary = data
		currentChunk = key
	else
		dictionary = {}
		currentChunk = nil
	end
end

-- Collect every [def_en, def_zh] pair under a word's def tree.
local function definitionsOf(entry)
	local out = {}
	local def = type(entry.def) == "table" and entry.def or {}
	for sense, byPos in pairs(def) do
		if type(byPos) == "table" then
			for pos, byGrammar in pairs(byPos) do
				if type(byGrammar) == "table" then
					for grammar, pairsList in pairs(byGrammar) do
						if type(pairsList) == "table" then
							for _, pair in ipairs(pairsList) do
								if type(pair) == "table" and type(pair[1]) == "string" then
									out[#out + 1] = {
										sense = sense,
										pos = pos,
										grammar = grammar,
										def = pair[1],
									}
								end
							end
						end
					end
				end
			end
		end
	end
	return out
end

-- example is a list of [en, zh] pairs.
local function examplesOf(entry)
	local out = {}
	local ex = type(entry.example) == "table" and entry.example or {}
	for _, pair in ipairs(ex) do
		if type(pair) == "table" and type(pair[1]) == "string" then
			out[#out + 1] = pair[1]
		end
	end
	return out
end

local function render()
	local entry = dictionary[currentWord]
	if type(entry) ~= "table" then
		panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 14 }, {
			ui.label({ text = currentWord or "No word selected", fontSize = 16, fontWeight = "bold" }),
			ui.label({ text = "No definition found.", fontSize = 12, color = "on_surface_variant" }),
		}))
		return
	end

	local body = {}
	for _, d in ipairs(definitionsOf(entry)) do
		local block = {}
		local posLabel = POS_LABEL[d.pos] or d.pos
		local tag
		if d.grammar == "NONE" then
			tag = posLabel
		else
			tag = posLabel .. " · " .. (GRAM_LABEL[d.grammar] or d.grammar)
		end
		if tag ~= "NONE" then
			block[#block + 1] = ui.label({ text = tag, fontSize = 11, fontWeight = "bold", color = "primary" })
		end
		if d.sense ~= "NONE" then
			block[#block + 1] = ui.label({ text = d.sense, fontSize = 12, fontWeight = "bold", color = "on_surface_variant" })
		end
		block[#block + 1] = ui.label({ text = d.def, fontSize = 13 })
		body[#body + 1] = ui.column({ gap = 4, padding = 10, fill = "primary/0.06", radius = 8 }, block)
	end

	local examples = examplesOf(entry)
	if #examples > 0 then
		body[#body + 1] = ui.column({ gap = 4, padding = 10, fill = "primary/0.06", radius = 8 }, {
			ui.label({ text = "Examples", fontSize = 11, fontWeight = "bold", color = "primary" }),
		})
		for _, s in ipairs(examples) do
			body[#body + 1] = ui.label({ text = "• " .. s, fontSize = 12, color = "on_surface_variant" })
		end
	end

	panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 14 }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "book", size = 16, color = "primary" }),
			ui.label({ text = currentWord, fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
		}),
		ui.separator({}),
		ui.scroll({ flexGrow = 1, gap = 8 }, body),
	}))
end

local function show(word)
	currentWord = word
	loadForWord(word)
	render()
end

function onOpen(_context)
	show(noctalia.state.get(STATE_KEY))
end

function onClose()
end

noctalia.state.watch(STATE_KEY, function(value)
	if type(value) == "string" and value ~= currentWord then
		show(value)
	end
end)
