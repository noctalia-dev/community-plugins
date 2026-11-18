--!nonstrict
-- TOML values, the part of TOML that a manifest's setting fields and `noctalia msg config-set`
-- use: strings, numbers, booleans, arrays and inline tables. Toml.parse reads one value as
-- written in a manifest; Toml.encode writes one for config-set.

local Toml = {}

local ESCAPES = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\" }

local parseValue

local function skip(text, at)
  while true do
    local _, last = text:find("^[%s,]+", at)
    if last then
      at = last + 1
    elseif text:sub(at, at) == "#" then
      at = (text:find("\n", at, true) or #text) + 1
    else
      return at
    end
  end
end

local function parseString(text, at)
  local quote = text:sub(at, at)
  if quote == "'" then
    local close = text:find("'", at + 1, true)
    if close == nil then
      return nil, #text + 1
    end
    return text:sub(at + 1, close - 1), close + 1
  end
  local parts = {}
  local i = at + 1
  while true do
    -- The next quote or backslash; the text before it is taken whole.
    local stop = text:find('["\\]', i)
    if stop == nil then
      return nil, #text + 1
    end
    table.insert(parts, text:sub(i, stop - 1))
    if text:sub(stop, stop) == '"' then
      return table.concat(parts), stop + 1
    end
    local nextChar = text:sub(stop + 1, stop + 1)
    if nextChar == "u" or nextChar == "U" then
      local size = nextChar == "u" and 4 or 8
      local code = tonumber(text:sub(stop + 2, stop + 1 + size), 16)
      table.insert(parts, code and utf8.char(code) or "")
      i = stop + 2 + size
    else
      table.insert(parts, ESCAPES[nextChar] or nextChar)
      i = stop + 2
    end
  end
end

local function parseKey(text, at)
  local c = text:sub(at, at)
  if c == '"' or c == "'" then
    return parseString(text, at)
  end
  local key = text:match("^[%w_%-]+", at)
  if key == nil then
    return nil, at
  end
  return key, at + #key
end

parseValue = function(text, at)
  at = skip(text, at)
  local c = text:sub(at, at)
  if c == '"' or c == "'" then
    return parseString(text, at)
  elseif c == "[" then
    local list = {}
    at = skip(text, at + 1)
    while at <= #text and text:sub(at, at) ~= "]" do
      local value
      value, at = parseValue(text, at)
      if value == nil then
        return nil, at
      end
      table.insert(list, value)
      at = skip(text, at)
    end
    return list, at + 1
  elseif c == "{" then
    local map = {}
    at = skip(text, at + 1)
    while at <= #text and text:sub(at, at) ~= "}" do
      local key
      key, at = parseKey(text, at)
      at = skip(text, at)
      if key == nil or text:sub(at, at) ~= "=" then
        return nil, at
      end
      map[key], at = parseValue(text, at + 1)
      at = skip(text, at)
    end
    return map, at + 1
  end
  local word = text:match("^[%w_%.%+%-:]+", at)
  if word == nil then
    return nil, at
  end
  if word == "true" or word == "false" then
    return word == "true", at + #word
  end
  return tonumber((word:gsub("_", ""))), at + #word
end

-- The value written in <text>, or nil when it is not one this reads.
function Toml.parse(text)
  if type(text) ~= "string" then
    return nil
  end
  return (parseValue(text, 1))
end

-- How many brackets and braces <line> leaves open, outside strings and comments.
local function openBrackets(line)
  if not line:find("[%[%]{}]") then
    return 0
  end
  line = line:gsub('"[^"\\]*\\.', ""):gsub('"[^"]*"', ""):gsub("'[^']*'", ""):gsub("#.*$", "")
  local opened = select(2, line:gsub("[%[{]", ""))
  local closed = select(2, line:gsub("[%]}]", ""))
  return opened - closed
end

-- The tables of a plugin manifest, in order, as { header, values }. The first has no header:
-- the top-level keys. A header is the name inside [[...]] or [...], such as "panel" or
-- "widget.setting". A value may span lines, as an array does. With <only>, a set of key
-- names, other values are skipped, which is quicker.
function Toml.manifest(text, only)
  local current = { header = nil, values = {} }
  local sections = { current }
  local pendingKey, pendingText, depth = nil, nil, 0
  for line in (text or ""):gmatch("[^\n]*") do
    if pendingKey then
      pendingText ..= "\n" .. line
      depth += openBrackets(line)
      if depth <= 0 then
        if only == nil or only[pendingKey] then
          current.values[pendingKey] = Toml.parse(pendingText)
        end
        pendingKey = nil
      end
      continue
    end
    line = line:match("^%s*(.*)")
    local header = line:match("^%[%[%s*([%w_%.%-]+)%s*%]%]") or line:match("^%[%s*([%w_%.%-]+)%s*%]")
    if header then
      current = { header = header, values = {} }
      table.insert(sections, current)
    else
      local key, value = line:match("^([%w_%-]+)%s*=%s*(.*)$")
      if key then
        depth = openBrackets(value)
        if depth > 0 then
          pendingKey, pendingText = key, value
        elseif only == nil or only[key] then
          current.values[key] = Toml.parse(value)
        end
      end
    end
  end
  return sections
end

local function quote(text)
  return '"' .. text:gsub('[%c"\\]', function(c)
    if c == '"' or c == "\\" then
      return "\\" .. c
    end
    return string.format("\\u%04X", string.byte(c))
  end) .. '"'
end

-- <value> as TOML. A number is an integer when <kind> is "int", and has a decimal point
-- when it is "double". Table keys are always quoted.
function Toml.encode(value, kind)
  local t = type(value)
  if t == "string" then
    return quote(value)
  elseif t == "boolean" then
    return tostring(value)
  elseif t == "number" then
    if kind == "int" then
      return string.format("%d", value)
    end
    local text = string.format("%.15g", value)
    return text:find("[%.eEn]") and text or text .. ".0"
  elseif t == "table" then
    if #value > 0 or next(value) == nil then
      local items = {}
      for _, item in ipairs(value) do
        table.insert(items, Toml.encode(item))
      end
      return "[" .. table.concat(items, ", ") .. "]"
    end
    local items = {}
    for key, item in pairs(value) do
      table.insert(items, quote(tostring(key)) .. " = " .. Toml.encode(item, kind))
    end
    table.sort(items)
    return "{ " .. table.concat(items, ", ") .. " }"
  end
  return nil
end

return Toml
