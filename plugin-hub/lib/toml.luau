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
  local parts = {}
  local i = at + 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == quote then
      return table.concat(parts), i + 1
    elseif c == "\\" and quote == '"' then
      local nextChar = text:sub(i + 1, i + 1)
      if nextChar == "u" or nextChar == "U" then
        local size = nextChar == "u" and 4 or 8
        local code = tonumber(text:sub(i + 2, i + 1 + size), 16)
        table.insert(parts, code and utf8.char(code) or "")
        i += 2 + size
      else
        table.insert(parts, ESCAPES[nextChar] or nextChar)
        i += 2
      end
    else
      table.insert(parts, c)
      i += 1
    end
  end
  return nil, i
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
