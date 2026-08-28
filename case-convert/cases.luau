--!nonstrict
-- Pure conversion logic: no noctalia APIs, so it can be unit tested standalone
-- with the `luau` CLI (see tests/cases_test.luau).
--
-- Everything is byte-oriented Lua patterns. That is deliberate: splitting on
-- `%W` would tear multi-byte UTF-8 apart, so the tokenizer only ever splits on
-- an explicit ASCII separator set and never on "not a letter".
--
-- Casing is handled by M.upper/M.lower, which understand ASCII plus Latin-1
-- Supplement (`café` → `CAFÉ`, `Straße` → `STRAßE` — ß has no single-character
-- uppercase). Letters beyond that block (Ł, Ż, Ș, Greek, Cyrillic) are copied
-- verbatim instead of cased. They are never corrupted, and no input can throw:
-- the decoder walks bytes rather than calling the utf8 library, which errors on
-- the invalid sequences a raw X11 selection can hand us.

local M = {}

-- Byte length of the UTF-8 sequence starting with `first`. Continuation bytes
-- and other malformed leads count as one byte, so the walk always advances.
local function charBytes(first: number): number
	if first < 0xC0 then
		return 1
	elseif first < 0xE0 then
		return 2
	elseif first < 0xF0 then
		return 3
	end
	return 4
end

-- ASCII fast path, then a byte walk that cases the Latin-1 Supplement block:
-- its code points live at 0xC3 0x80..0xBF, and the upper/lower halves of that
-- block are exactly 0x20 apart — except × (0xC3 0x97) and ÷ (0xC3 0xB7), which
-- are maths symbols, not letters.
local function mapCase(text: string, toUpper: boolean): string
	if not text:find("[\128-\255]") then
		return if toUpper then text:upper() else text:lower()
	end

	local out = {}
	local index, length = 1, #text
	while index <= length do
		local lead = text:byte(index)
		if lead < 0x80 then
			local char = text:sub(index, index)
			table.insert(out, if toUpper then char:upper() else char:lower())
			index += 1
		elseif lead == 0xC3 and index < length then
			local trail = text:byte(index + 1)
			if toUpper and trail >= 0xA0 and trail <= 0xBE and trail ~= 0xB7 then
				trail -= 0x20
			elseif not toUpper and trail >= 0x80 and trail <= 0x9E and trail ~= 0x97 then
				trail += 0x20
			end
			table.insert(out, string.char(lead, trail))
			index += 2
		else
			local size = charBytes(lead)
			table.insert(out, text:sub(index, math.min(index + size - 1, length)))
			index += size
		end
	end
	return table.concat(out)
end

function M.upper(text: string): string
	return mapCase(text, true)
end

function M.lower(text: string): string
	return mapCase(text, false)
end

-- Word separators. Anything else (apostrophes, brackets, …) stays inside a token.
local SEPARATOR_PATTERN = "[%s_%-%./\\:,;|]+"

-- Words that stay lowercase inside Title Case, unless they are first or last.
local SMALL_WORD_LIST = {
	"a", "an", "and", "as", "at", "but", "by", "en", "for", "from", "if", "in",
	"into", "nor", "of", "on", "onto", "or", "over", "per", "so", "the", "to",
	"up", "v", "via", "vs", "with", "yet",
}

local SMALL_WORDS = {}
for _, word in SMALL_WORD_LIST do
	SMALL_WORDS[word] = true
end

function M.trim(text: string): string
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split text into words. Separators are dropped; camel and acronym boundaries
-- become splits too, so `parseHTTPResponse` and `parse-http-response` tokenize
-- identically.
function M.tokenize(text: string): { string }
	local spaced = text:gsub(SEPARATOR_PATTERN, " ")
	spaced = spaced:gsub("(%l)(%u)", "%1 %2") -- fooBar    → foo Bar
	spaced = spaced:gsub("(%d)(%u)", "%1 %2") -- utf8Text  → utf8 Text
	spaced = spaced:gsub("(%u)(%u%l)", "%1 %2") -- HTTPCode → HTTP Code

	local tokens = {}
	for word in spaced:gmatch("%S+") do
		table.insert(tokens, word)
	end
	return tokens
end

-- Split off the first character as a whole UTF-8 sequence, so casing it can
-- never leave half a code point behind.
local function splitFirst(word: string): (string, string)
	local lead = word:byte(1)
	if not lead then
		return "", ""
	end
	local size = math.min(charBytes(lead), #word)
	return word:sub(1, size), word:sub(size + 1)
end

local function upperFirst(word: string): string
	local first, rest = splitFirst(word)
	return M.upper(first) .. rest
end

local function lowerFirst(word: string): string
	local first, rest = splitFirst(word)
	return M.lower(first) .. rest
end

-- With `preserve` on, a token keeps the casing inside it, so an acronym stays an
-- acronym: `NASA rocks` becomes `NASA_Rocks` in Pascal_Snake_Case rather than
-- `Nasa_Rocks`. With it off, every token is flattened to lowercase first.
local function norm(word: string, preserve: boolean): string
	return if preserve then word else M.lower(word)
end

local function join(tokens: { string }, separator: string, transform): string
	local parts = {}
	for index, token in tokens do
		parts[index] = transform(token, index, #tokens)
	end
	return table.concat(parts, separator)
end

local function swapCase(text: string): string
	return (text:gsub("%a", function(char)
		return if char:match("%u") then char:lower() else char:upper()
	end))
end

local function alternatingCase(text: string): string
	local out, letters = {}, 0
	for index = 1, #text do
		local char = text:sub(index, index)
		if char:match("%a") then
			letters += 1
			out[index] = if letters % 2 == 1 then char:upper() else char:lower()
		else
			out[index] = char
		end
	end
	return table.concat(out)
end

-- ctx = { text: string (trimmed input), tokens: { string }, preserve: boolean }
-- Word-based conversions read `tokens`; character-based ones read `text`, which
-- keeps punctuation intact (that is what makes `UPPER CASE` differ from `no case`).
M.CONVERSIONS = {
	{
		key = "camel",
		name = "camelCase",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, "", function(token, index)
				local word = norm(token, ctx.preserve)
				return if index == 1 then lowerFirst(word) else upperFirst(word)
			end)
		end,
	},
	{
		key = "pascal",
		name = "PascalCase",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, "", function(token)
				return upperFirst(norm(token, ctx.preserve))
			end)
		end,
	},
	{
		key = "kebab",
		name = "kebab-case",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, "-", function(token)
				return M.lower(token)
			end)
		end,
	},
	{
		key = "snake",
		name = "snake_case",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, "_", function(token)
				return M.lower(token)
			end)
		end,
	},
	{
		key = "constant",
		name = "CONSTANT_CASE",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, "_", function(token)
				return M.upper(token)
			end)
		end,
	},
	{
		key = "dot",
		name = "dot.case",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, ".", function(token)
				return M.lower(token)
			end)
		end,
	},
	{
		key = "path",
		name = "path/case",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, "/", function(token)
				return M.lower(token)
			end)
		end,
	},
	{
		key = "pascal_snake",
		name = "Pascal_Snake_Case",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, "_", function(token)
				return upperFirst(norm(token, ctx.preserve))
			end)
		end,
	},
	{
		key = "kebab_upper",
		name = "KEBAB-UPPER-CASE",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, "-", function(token)
				return M.upper(token)
			end)
		end,
	},
	{
		key = "header",
		name = "Header-Case",
		category = "Programming",
		convert = function(ctx)
			return join(ctx.tokens, "-", function(token)
				return upperFirst(norm(token, ctx.preserve))
			end)
		end,
	},
	{
		key = "title",
		name = "Title Case",
		category = "Text",
		convert = function(ctx)
			return join(ctx.tokens, " ", function(token, index, total)
				local lowered = M.lower(token)
				if index > 1 and index < total and SMALL_WORDS[lowered] then
					return lowered
				end
				return upperFirst(norm(token, ctx.preserve))
			end)
		end,
	},
	{
		key = "capital",
		name = "Capital Case",
		category = "Text",
		convert = function(ctx)
			return join(ctx.tokens, " ", function(token)
				return upperFirst(norm(token, ctx.preserve))
			end)
		end,
	},
	{
		key = "sentence",
		name = "Sentence case",
		category = "Text",
		convert = function(ctx)
			return join(ctx.tokens, " ", function(token, index)
				local word = norm(token, ctx.preserve)
				return if index == 1 then upperFirst(word) else word
			end)
		end,
	},
	{
		key = "no_case",
		name = "no case",
		category = "Text",
		convert = function(ctx)
			return join(ctx.tokens, " ", function(token)
				return M.lower(token)
			end)
		end,
	},
	{
		key = "lower",
		name = "lower case",
		category = "Text",
		convert = function(ctx)
			return M.lower(ctx.text)
		end,
	},
	{
		key = "upper",
		name = "UPPER CASE",
		category = "Text",
		convert = function(ctx)
			return M.upper(ctx.text)
		end,
	},
	{
		key = "swap",
		name = "sWAP cASE",
		category = "Fun",
		convert = function(ctx)
			return swapCase(ctx.text)
		end,
	},
	{
		key = "alternating",
		name = "AlTeRnAtInG cAsE",
		category = "Fun",
		convert = function(ctx)
			return alternatingCase(ctx.text)
		end,
	},
}

-- Convert `text` with every conversion. Returns a list of
-- { key, name, category, value } in declaration order, skipping conversions
-- that produce nothing (a separators-only input has no word tokens, so the
-- word-based conversions come out empty).
function M.convertAll(text: string, preserve: boolean)
	local trimmed = M.trim(text)
	local ctx = { text = trimmed, tokens = M.tokenize(trimmed), preserve = preserve }

	local results = {}
	for _, conversion in M.CONVERSIONS do
		local value = conversion.convert(ctx)
		if value ~= "" then
			table.insert(results, {
				key = conversion.key,
				name = conversion.name,
				category = conversion.category,
				value = value,
			})
		end
	end
	return results
end

return M
