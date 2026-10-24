--!nonstrict
-- Writes parsed TOML nodes (see toml.luau) as a Nix expression. Attribute names are
-- sorted, so the output is deterministic and matches how Nix itself orders them.

local M = {}

local KEYWORDS = {
	["assert"] = true,
	["else"] = true,
	["if"] = true,
	["in"] = true,
	["inherit"] = true,
	["let"] = true,
	["or"] = true,
	["rec"] = true,
	["then"] = true,
	["with"] = true,
}

local MAX_INLINE = 80

function M.string(s)
	s = string.gsub(s, "\\", "\\\\")
	s = string.gsub(s, '"', '\\"')
	s = string.gsub(s, "%${", "\\${")
	s = string.gsub(s, "\n", "\\n")
	s = string.gsub(s, "\r", "\\r")
	s = string.gsub(s, "\t", "\\t")
	return '"' .. s .. '"'
end

function M.attrName(k)
	if string.match(k, "^[%a_][%w_'%-]*$") and not KEYWORDS[k] then
		return k
	end
	return M.string(k)
end

-- Nix floats need a dot: TOML's 1e5 becomes 1.0e5.
local function float(v)
	if not string.find(v, ".", 1, true) then
		v = string.gsub(v, "[eE]", ".0e", 1)
	end
	return v
end

local function scalar(node, inList)
	local t = node.t
	if t == "string" or t == "datetime" then
		return M.string(node.v)
	elseif t == "bool" then
		return node.v and "true" or "false"
	end
	local v = t == "float" and float(node.v) or node.v
	-- A negative number is an expression, which a list element cannot be without parentheses.
	if inList and string.sub(v, 1, 1) == "-" then
		return "(" .. v .. ")"
	end
	return v
end

local value

local function sortedKeys(tbl)
	local keys = table.clone(tbl.keys)
	table.sort(keys)
	return keys
end

-- `a = { b = { c = 1; }; }` is written as `a.b.c = 1;`.
local function binding(key, node, indent)
	local path = { M.attrName(key) }
	while node.t == "table" and #node.keys == 1 do
		local only = node.keys[1]
		table.insert(path, M.attrName(only))
		node = node.map[only]
	end
	return table.concat(path, ".") .. " = " .. value(node, indent, false) .. ";"
end

local function attrset(node, indent)
	if #node.keys == 0 then
		return "{ }"
	end
	local inner = indent .. "  "
	local lines = { "{" }
	for _, k in sortedKeys(node) do
		if not node.map[k].special then
			table.insert(lines, inner .. binding(k, node.map[k], inner))
		end
	end
	table.insert(lines, indent .. "}")
	return table.concat(lines, "\n")
end

local function list(node, indent)
	local inner = indent .. "  "
	local parts = {}
	local simple = true
	for _, item in node.items do
		-- Nix has no literal for inf/nan; such list elements are left out.
		if item.special then
			continue
		end
		if item.t == "table" or item.t == "array" then
			simple = false
		end
		table.insert(parts, value(item, inner, true))
	end
	if #parts == 0 then
		return "[ ]"
	end
	if simple then
		local line = "[ " .. table.concat(parts, " ") .. " ]"
		if #indent + #line <= MAX_INLINE then
			return line
		end
	end
	return "[\n" .. inner .. table.concat(parts, "\n" .. inner) .. "\n" .. indent .. "]"
end

function value(node, indent, inList)
	if node.t == "table" then
		return attrset(node, indent)
	elseif node.t == "array" then
		return list(node, indent)
	end
	return scalar(node, inList)
end

-- Renders a root table node as a Nix attribute set. `indent` is the indentation of the
-- line the set starts on; the result has no trailing newline.
function M.render(root, indent)
	return value(root, indent or "", false)
end

return M
