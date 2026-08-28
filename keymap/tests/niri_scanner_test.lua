local src = assert(io.open("niri_service.luau")):read("*a")

-- reference implementations (original char loops)
local function refBraceDelta(text)
	local delta = 0
	local quote = nil
	local escaped = false
	for index = 1, #text do
		local char = text:sub(index, index)
		if quote ~= nil then
			if escaped then escaped = false
			elseif char == "\\" then escaped = true
			elseif char == quote then quote = nil end
		elseif char == '"' or char == "'" then quote = char
		elseif char == "{" then delta = delta + 1
		elseif char == "}" then delta = delta - 1 end
	end
	return delta
end
local function refFirstOpenBrace(text)
	local quote = nil
	local escaped = false
	for index = 1, #text do
		local char = text:sub(index, index)
		if quote ~= nil then
			if escaped then escaped = false
			elseif char == "\\" then escaped = true
			elseif char == quote then quote = nil end
		elseif char == '"' or char == "'" then quote = char
		elseif char == "{" then return index end
	end
	return nil
end
local function refContentBeforeOuterClose(text)
	local depth = 1
	local quote = nil
	local escaped = false
	for index = 1, #text do
		local char = text:sub(index, index)
		if quote ~= nil then
			if escaped then escaped = false
			elseif char == "\\" then escaped = true
			elseif char == quote then quote = nil end
		elseif char == '"' or char == "'" then quote = char
		elseif char == "{" then depth = depth + 1
		elseif char == "}" then
			depth = depth - 1
			if depth == 0 then return text:sub(1, index - 1) end
		end
	end
	return text
end

-- extract new implementations
local function extract(name)
	local startAt = assert(src:find("local function " .. name, 1, true), name)
	local endAt = assert(src:find("\nend", startAt, true), name)
	return assert(load(src:sub(startAt, endAt + 3) .. "\nreturn " .. name))()
end
local braceDelta = extract("braceDelta")
local firstOpenBrace = extract("firstOpenBrace")
local contentBeforeOuterClose = extract("contentBeforeOuterClose")

local corpus = {
	'', '{', '}', '{}', '{{}}', 'a{b}c',
	' spawn-sh "foot"; ', ' spawn-sh "a { b"; ',
	" spawn 'single { quote'; ",
	' bind hotkey-overlay-title="x" { focus-workspace 1; } ',
	'{"unclosed', ' "{" ', ' \\{ ',
	'{ nested { deep } close } tail',
	'no braces at all',
	'  } leading close',
}
-- add real escaped-quote sample
corpus[#corpus + 1] = ' spawn-sh "a ' .. string.char(92) .. '" b { "; '

for i, text in ipairs(corpus) do
	local rd, nd = refBraceDelta(text), braceDelta(text)
	assert(rd == nd, string.format("case %d braceDelta %s ~= %s (%q)", i, rd, nd, text))
	local rf, nf = refFirstOpenBrace(text), firstOpenBrace(text)
	assert(rf == nf, string.format("case %d firstOpenBrace %s ~= %s (%q)", i, tostring(rf), tostring(nf), text))
	local rc, nc = refContentBeforeOuterClose(text), contentBeforeOuterClose(text)
	assert(rc == nc, string.format("case %d contentBeforeOuterClose %q ~= %q", i, rc, nc))
end

-- fuzz with random token soup
local chars = { '{', '}', '"', "'", "\\", 'a', ' ', ';' }
math.randomseed(42)
for i = 1, 3000 do
	local parts = {}
	for j = 1, math.random(0, 20) do parts[#parts + 1] = chars[math.random(#chars)] end
	local text = table.concat(parts)
	local rd, nd = refBraceDelta(text), braceDelta(text)
	assert(rd == nd, string.format("fuzz %d braceDelta %s ~= %s (%q)", i, rd, nd, text))
	local rf, nf = refFirstOpenBrace(text), firstOpenBrace(text)
	assert(rf == nf, string.format("fuzz %d firstOpenBrace %s ~= %s (%q)", i, tostring(rf), tostring(nf), text))
	local rc, nc = refContentBeforeOuterClose(text), contentBeforeOuterClose(text)
	assert(rc == nc, string.format("fuzz %d content %q ~= %q", i, rc, nc))
end

print("scanner equivalence: ok (12 corpus + 3000 fuzz)")
