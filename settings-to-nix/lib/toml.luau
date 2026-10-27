--!nonstrict
-- Small TOML 1.0 reader for Noctalia's settings.toml. Scalars keep their source
-- spelling, so an int stays an int and 196.0 stays a float on the Nix side.
--
-- Nodes:
--   { t = "table", map = { [key] = node }, keys = { key, ... } }
--   { t = "array", items = { node, ... }, aot = bool }   -- aot: [[array of tables]]
--   { t = "string" | "int" | "float" | "bool" | "datetime", v = value }
--   floats inf/nan carry `special = "inf" | "-inf" | "nan"` instead of a usable `v`

local M = {}

local sub, find, match = string.sub, string.find, string.match

local function newTable()
	return { t = "table", map = {}, keys = {} }
end

local Parser = {}
Parser.__index = Parser

function Parser:fail(msg)
	local line = 1
	for _ in string.gmatch(sub(self.s, 1, self.i - 1), "\n") do
		line += 1
	end
	error(`line {line}: {msg}`, 0)
end

function Parser:peek(n)
	return sub(self.s, self.i, self.i + (n or 1) - 1)
end

function Parser:skipWs()
	local _, e = find(self.s, "^[ \t]*", self.i)
	self.i = e + 1
end

function Parser:skipComment()
	if self:peek() == "#" then
		local nl = find(self.s, "\n", self.i, true)
		self.i = nl or (#self.s + 1)
	end
end

function Parser:newline()
	if self:peek(2) == "\r\n" then
		self.i += 2
		return true
	elseif self:peek() == "\n" then
		self.i += 1
		return true
	end
	return false
end

-- Whitespace, comments and newlines, as allowed inside arrays.
function Parser:skipBlank()
	while true do
		self:skipWs()
		self:skipComment()
		if not self:newline() then
			return
		end
	end
end

function Parser:endOfLine()
	self:skipWs()
	self:skipComment()
	if self.i <= #self.s and not self:newline() then
		self:fail("expected end of line, found '" .. self:peek() .. "'")
	end
end

local ESCAPES = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", e = "\27", ['"'] = '"', ["\\"] = "\\" }

function Parser:escape(out)
	local c = sub(self.s, self.i + 1, self.i + 1)
	if ESCAPES[c] then
		table.insert(out, ESCAPES[c])
		self.i += 2
		return
	end
	local len = (c == "u" and 4) or (c == "U" and 8) or nil
	local hex = len and sub(self.s, self.i + 2, self.i + 1 + len)
	if not hex or not match(hex, "^%x+$") or #hex ~= len then
		self:fail("invalid escape '\\" .. c .. "'")
	end
	table.insert(out, utf8.char(tonumber(hex, 16)))
	self.i += 2 + len
end

function Parser:basicString()
	self.i += 1
	local out = {}
	while true do
		local p = find(self.s, '["\\\n]', self.i)
		if not p then
			self:fail("unterminated string")
		end
		table.insert(out, sub(self.s, self.i, p - 1))
		self.i = p
		local c = sub(self.s, p, p)
		if c == '"' then
			self.i += 1
			return table.concat(out)
		elseif c == "\n" then
			self:fail("newline in string")
		end
		self:escape(out)
	end
end

function Parser:literalString()
	local close = find(self.s, "['\n]", self.i + 1)
	if not close or sub(self.s, close, close) ~= "'" then
		self:fail("unterminated literal string")
	end
	local v = sub(self.s, self.i + 1, close - 1)
	self.i = close + 1
	return v
end

-- Closing delimiter of a multi-line string: up to two extra quotes belong to the content.
function Parser:closeMultiline(out, q)
	local _, e = find(self.s, "^" .. q .. "+", self.i)
	local n = e - self.i + 1
	if n < 3 then
		table.insert(out, string.rep(q, n))
		self.i = e + 1
		return false
	end
	table.insert(out, string.rep(q, math.min(n - 3, 2)))
	self.i = e + 1
	return true
end

function Parser:multilineBasic()
	self.i += 3
	self:newline()
	local out = {}
	while true do
		local p = find(self.s, '["\\]', self.i)
		if not p then
			self:fail("unterminated multi-line string")
		end
		table.insert(out, sub(self.s, self.i, p - 1))
		self.i = p
		if sub(self.s, p, p) == '"' then
			if self:closeMultiline(out, '"') then
				return table.concat(out)
			end
		else
			local _, e = find(self.s, "^\\[ \t]*\r?\n", p)
			if e then
				-- Line-ending backslash: drop the newline and leading whitespace of the next lines.
				local _, e2 = find(self.s, "^[ \t\r\n]*", e + 1)
				self.i = e2 + 1
			else
				self:escape(out)
			end
		end
	end
end

function Parser:multilineLiteral()
	self.i += 3
	self:newline()
	local out = {}
	while true do
		local p = find(self.s, "'", self.i, true)
		if not p then
			self:fail("unterminated multi-line literal string")
		end
		table.insert(out, sub(self.s, self.i, p - 1))
		self.i = p
		if self:closeMultiline(out, "'") then
			return table.concat(out)
		end
	end
end

function Parser:simpleKey()
	local c = self:peek()
	if c == '"' then
		return self:basicString()
	elseif c == "'" then
		return self:literalString()
	end
	local k = match(self.s, "^[%w_%-]+", self.i)
	if not k then
		self:fail("expected a key, found '" .. c .. "'")
	end
	self.i += #k
	return k
end

function Parser:key()
	local keys = { self:simpleKey() }
	while true do
		self:skipWs()
		if self:peek() ~= "." then
			return keys
		end
		self.i += 1
		self:skipWs()
		table.insert(keys, self:simpleKey())
	end
end

function Parser:scalar()
	local tok = match(self.s, "^[%w_%+%-%.:]+", self.i)
	if not tok then
		self:fail("expected a value, found '" .. self:peek() .. "'")
	end
	-- A date and a time may be separated by a single space.
	if match(tok, "^%d%d%d%d%-%d%d%-%d%d$") then
		local rest = match(self.s, "^ (%d%d:[%w_%+%-%.:]+)", self.i + #tok)
		if rest then
			tok = tok .. " " .. rest
		end
	end
	self.i += #tok

	if tok == "true" or tok == "false" then
		return { t = "bool", v = tok == "true" }
	end
	if match(tok, "^%d%d%d%d%-%d%d%-%d%d") or match(tok, "^%d%d:%d%d") then
		return { t = "datetime", v = tok }
	end

	local clean = string.gsub(tok, "_", "")
	local sign, body = match(clean, "^([%+%-]?)(.*)$")
	if body == "inf" or body == "nan" then
		return { t = "float", special = (sign == "-" and body == "inf") and "-inf" or body }
	end
	local neg = sign == "-" and "-" or ""
	for prefix, base in { ["0x"] = 16, ["0o"] = 8, ["0b"] = 2 } do
		if sub(body, 1, 2) == prefix then
			local n = tonumber(sub(body, 3), base)
			if not n then
				self:fail("invalid integer '" .. tok .. "'")
			end
			return { t = "int", v = string.format("%d", n) }
		end
	end
	if match(body, "^%d+$") then
		return { t = "int", v = neg .. body }
	end
	if match(body, "^%d+%.%d+$") or match(body, "^%d+%.%d+[eE][%+%-]?%d+$") or match(body, "^%d+[eE][%+%-]?%d+$") then
		return { t = "float", v = neg .. body }
	end
	self:fail("invalid value '" .. tok .. "'")
end

function Parser:array()
	self.i += 1
	local node = { t = "array", items = {}, aot = false }
	while true do
		self:skipBlank()
		if self:peek() == "]" then
			self.i += 1
			return node
		end
		table.insert(node.items, self:value())
		self:skipBlank()
		local c = self:peek()
		if c == "," then
			self.i += 1
		elseif c == "]" then
			self.i += 1
			return node
		else
			self:fail("expected ',' or ']' in array")
		end
	end
end

function Parser:inlineTable()
	self.i += 1
	local node = newTable()
	self:skipBlank()
	if self:peek() == "}" then
		self.i += 1
		return node
	end
	while true do
		self:skipBlank()
		self:keyValue(node)
		self:skipBlank()
		local c = self:peek()
		if c == "," then
			self.i += 1
		elseif c == "}" then
			self.i += 1
			return node
		else
			self:fail("expected ',' or '}' in inline table")
		end
	end
end

function Parser:value()
	local c = self:peek()
	if c == '"' then
		if self:peek(3) == '"""' then
			return { t = "string", v = self:multilineBasic() }
		end
		return { t = "string", v = self:basicString() }
	elseif c == "'" then
		if self:peek(3) == "'''" then
			return { t = "string", v = self:multilineLiteral() }
		end
		return { t = "string", v = self:literalString() }
	elseif c == "[" then
		return self:array()
	elseif c == "{" then
		return self:inlineTable()
	end
	return self:scalar()
end

-- Descends one key, creating an implicit table; an array of tables resolves to its last element.
function Parser:descend(tbl, key)
	local node = tbl.map[key]
	if node == nil then
		node = newTable()
		node.implicit = true
		tbl.map[key] = node
		table.insert(tbl.keys, key)
	elseif node.t == "array" and node.aot then
		node = node.items[#node.items]
	elseif node.t ~= "table" then
		self:fail("key '" .. key .. "' is not a table")
	end
	return node
end

function Parser:keyValue(tbl)
	local keys = self:key()
	self:skipWs()
	if self:peek() ~= "=" then
		self:fail("expected '=' after key")
	end
	self.i += 1
	self:skipWs()
	local v = self:value()
	for n = 1, #keys - 1 do
		tbl = self:descend(tbl, keys[n])
	end
	local last = keys[#keys]
	if tbl.map[last] ~= nil then
		self:fail("duplicate key '" .. last .. "'")
	end
	tbl.map[last] = v
	table.insert(tbl.keys, last)
end

function Parser:header(root)
	local aot = self:peek(2) == "[["
	self.i += aot and 2 or 1
	self:skipWs()
	local keys = self:key()
	if self:peek(aot and 2 or 1) ~= (aot and "]]" or "]") then
		self:fail("unterminated table header")
	end
	self.i += aot and 2 or 1

	local tbl = root
	for n = 1, #keys - 1 do
		tbl = self:descend(tbl, keys[n])
	end
	local last = keys[#keys]
	local existing = tbl.map[last]
	if aot then
		if existing == nil then
			existing = { t = "array", items = {}, aot = true }
			tbl.map[last] = existing
			table.insert(tbl.keys, last)
		elseif existing.t ~= "array" or not existing.aot then
			self:fail("key '" .. last .. "' is not an array of tables")
		end
		local item = newTable()
		table.insert(existing.items, item)
		return item
	end
	if existing == nil then
		existing = newTable()
		tbl.map[last] = existing
		table.insert(tbl.keys, last)
	elseif existing.t ~= "table" or not existing.implicit then
		self:fail("table '" .. last .. "' defined twice")
	end
	existing.implicit = false
	return existing
end

-- Parses a TOML document. Returns the root table node, or nil and an error message.
function M.parse(text)
	if sub(text, 1, 3) == "\239\187\191" then
		text = sub(text, 4)
	end
	local p = setmetatable({ s = text, i = 1 }, Parser)
	local root = newTable()
	local ok, err = pcall(function()
		local current = root
		while p.i <= #p.s do
			p:skipWs()
			local c = p:peek()
			if c == "" then
				break
			elseif c == "#" or c == "\n" or c == "\r" then
				p:endOfLine()
			elseif c == "[" then
				current = p:header(root)
				p:endOfLine()
			else
				p:keyValue(current)
				p:endOfLine()
			end
		end
	end)
	if not ok then
		return nil, tostring(err)
	end
	return root
end

return M
