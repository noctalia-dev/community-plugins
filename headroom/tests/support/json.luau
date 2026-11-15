--!nonstrict
-- Minimal JSON for the fake host (noctalia.json): enough to decode the fixtures
-- and translations, and to round-trip the service's cache. Test-only.

local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

function M.decode(text: string): (any, string?)
  local pos = 1

  local function fail(msg)
    error({ json = `{msg} at {pos}` })
  end

  local function skip()
    pos = string.find(text, "[^ \t\r\n]", pos) or #text + 1
  end

  local value

  local function str()
    pos += 1
    local out = {}
    while true do
      local c = string.sub(text, pos, pos)
      if c == "" then
        fail("unterminated string")
      elseif c == '"' then
        pos += 1
        return table.concat(out)
      elseif c == "\\" then
        local e = string.sub(text, pos + 1, pos + 1)
        if e == "u" then
          local code = tonumber(string.sub(text, pos + 2, pos + 5), 16) or fail("bad \\u escape")
          table.insert(out, utf8.char(code))
          pos += 6
        else
          table.insert(out, ESCAPES[e] or fail("bad escape"))
          pos += 2
        end
      else
        table.insert(out, c)
        pos += 1
      end
    end
  end

  function value()
    skip()
    local c = string.sub(text, pos, pos)
    if c == "{" then
      pos += 1
      local obj = {}
      skip()
      if string.sub(text, pos, pos) == "}" then
        pos += 1
        return obj
      end
      while true do
        skip()
        if string.sub(text, pos, pos) ~= '"' then
          fail("expected key")
        end
        local key = str()
        skip()
        if string.sub(text, pos, pos) ~= ":" then
          fail("expected ':'")
        end
        pos += 1
        local v = value()
        if v ~= M.null then
          obj[key] = v
        end
        skip()
        local d = string.sub(text, pos, pos)
        pos += 1
        if d == "}" then
          return obj
        elseif d ~= "," then
          fail("expected ',' or '}'")
        end
      end
    elseif c == "[" then
      pos += 1
      local arr = {}
      skip()
      if string.sub(text, pos, pos) == "]" then
        pos += 1
        return arr
      end
      while true do
        local v = value()
        table.insert(arr, if v == M.null then nil else v)
        skip()
        local d = string.sub(text, pos, pos)
        pos += 1
        if d == "]" then
          return arr
        elseif d ~= "," then
          fail("expected ',' or ']'")
        end
      end
    elseif c == '"' then
      return str()
    elseif string.sub(text, pos, pos + 3) == "true" then
      pos += 4
      return true
    elseif string.sub(text, pos, pos + 4) == "false" then
      pos += 5
      return false
    elseif string.sub(text, pos, pos + 3) == "null" then
      pos += 4
      return M.null
    end
    local num = string.match(text, "^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if num == nil or num == "" then
      fail("unexpected character")
    end
    pos += #num
    return tonumber(num)
  end

  local ok, result = pcall(value)
  if not ok then
    return nil, if type(result) == "table" then result.json else tostring(result)
  end
  if result == M.null then
    return nil, nil
  end
  return result, nil
end

local function encodeString(s: string): string
  return '"' .. s:gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return map[c] or string.format("\\u%04x", string.byte(c))
  end) .. '"'
end

function M.encode(value: any): string
  local t = type(value)
  if t == "nil" then
    return "null"
  elseif t == "boolean" or t == "number" then
    return tostring(value)
  elseif t == "string" then
    return encodeString(value)
  elseif t == "table" then
    if #value > 0 or next(value) == nil then
      local parts = {}
      for _, v in value do
        table.insert(parts, M.encode(v))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in value do
      table.insert(keys, tostring(k))
    end
    table.sort(keys)
    local parts = {}
    for _, k in keys do
      table.insert(parts, encodeString(k) .. ":" .. M.encode(value[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error(`cannot encode {t}`)
end

return M
