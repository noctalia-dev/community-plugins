-- Minimal JSON for the test harness. decode: null -> nil. encode: sorted keys.
local json = {}

local escapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }

local function utf8char(cp)
  if utf8 and utf8.char then
    return utf8.char(cp)
  end
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function fail(str, pos, msg)
  error("json: " .. msg .. " at " .. pos, 0)
end

local parseValue

local function skip(str, pos)
  return str:find("[^ \t\r\n]", pos) or #str + 1
end

local function parseString(str, pos)
  local out = {}
  pos = pos + 1
  while true do
    local c = str:sub(pos, pos)
    if c == "" then fail(str, pos, "unterminated string") end
    if c == '"' then return table.concat(out), pos + 1 end
    if c == "\\" then
      local e = str:sub(pos + 1, pos + 1)
      if e == "u" then
        local hex = str:match("^%x%x%x%x", pos + 2)
        if not hex then fail(str, pos, "bad unicode escape") end
        local cp = tonumber(hex, 16)
        pos = pos + 6
        if cp >= 0xD800 and cp < 0xDC00 then
          local lo = str:match("^\\u(%x%x%x%x)", pos)
          if lo then
            cp = 0x10000 + (cp - 0xD800) * 1024 + (tonumber(lo, 16) - 0xDC00)
            pos = pos + 6
          end
        end
        out[#out + 1] = utf8char(cp)
      elseif escapes[e] then
        out[#out + 1] = escapes[e]
        pos = pos + 2
      else
        fail(str, pos, "bad escape")
      end
    else
      out[#out + 1] = c
      pos = pos + 1
    end
  end
end

parseValue = function(str, pos)
  pos = skip(str, pos)
  local c = str:sub(pos, pos)
  if c == "{" then
    local obj = {}
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
      pos = skip(str, pos)
      if str:sub(pos, pos) ~= '"' then fail(str, pos, "expected key") end
      local key
      key, pos = parseString(str, pos)
      pos = skip(str, pos)
      if str:sub(pos, pos) ~= ":" then fail(str, pos, "expected ':'") end
      local val
      val, pos = parseValue(str, pos + 1)
      obj[key] = val
      pos = skip(str, pos)
      local d = str:sub(pos, pos)
      if d == "}" then return obj, pos + 1 end
      if d ~= "," then fail(str, pos, "expected ',' or '}'") end
      pos = pos + 1
    end
  elseif c == "[" then
    local arr, n = {}, 0
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == "]" then return arr, pos + 1 end
    while true do
      local val
      val, pos = parseValue(str, pos)
      n = n + 1
      arr[n] = val
      pos = skip(str, pos)
      local d = str:sub(pos, pos)
      if d == "]" then return arr, pos + 1 end
      if d ~= "," then fail(str, pos, "expected ',' or ']'") end
      pos = pos + 1
    end
  elseif c == '"' then
    return parseString(str, pos)
  elseif str:sub(pos, pos + 3) == "true" then
    return true, pos + 4
  elseif str:sub(pos, pos + 4) == "false" then
    return false, pos + 5
  elseif str:sub(pos, pos + 3) == "null" then
    return nil, pos + 4
  end
  local num = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
  if not num or num == "" then fail(str, pos, "unexpected character") end
  return tonumber(num), pos + #num
end

-- Returns value, or (nil, err) on malformed input.
function json.decode(str)
  local ok, val, pos = pcall(parseValue, str, 1)
  if not ok then return nil, val end
  if skip(str, pos) <= #str then return nil, "json: trailing data at " .. pos end
  return val
end

local function encodeString(s)
  s = s:gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }
    return map[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end

local function encodeValue(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return tostring(v)
  end
  if t == "string" then return encodeString(v) end
  if t == "table" then
    local n = #v
    local count = 0
    for _ in pairs(v) do count = count + 1 end
    local parts = {}
    if count == n and n > 0 then
      for i = 1, n do parts[i] = encodeValue(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    if count == 0 then return "{}" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for i, k in ipairs(keys) do
      parts[i] = encodeString(k) .. ":" .. encodeValue(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("json: cannot encode " .. t, 0)
end

-- Returns string, or (nil, err). Keys sorted; empty table encodes as {}.
function json.encode(v)
  local ok, out = pcall(encodeValue, v)
  if not ok then return nil, out end
  return out
end

return json
