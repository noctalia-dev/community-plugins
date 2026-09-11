-- lib/json.luau — self-contained JSON encode/decode with error returns.
--
-- noctalia.json.* throws on malformed input, which would take a whole entry
-- down. This module returns (ok, value_or_error) instead so callers can
-- recover. It is written in the Lua 5.4 subset of Luau so the same file runs
-- unchanged inside Noctalia and in the plugin's plain-Lua test suite.
--
-- No network, no host APIs, no globals mutated.

local M = {}

local ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

-- Reverse map for the decoder: escape LETTER (after the backslash) -> control
-- character. Quotes and backslashes map to themselves.
local UNESCAPES = {
  ['"'] = '"',
  ['\\'] = '\\',
  ['b'] = '\b',
  ['f'] = '\f',
  ['n'] = '\n',
  ['r'] = '\r',
  ['t'] = '\t',
  ["/"] = "/",
}

-- True when s.start..s.finish is a well-formed UTF-8 sequence (or ASCII).
local function utf8_seq_len(s, i)
  local b = string.byte(s, i)
  if b < 0x80 then
    return 1
  elseif b >= 0xC2 and b <= 0xDF then
    local b2 = string.byte(s, i + 1)
    if b2 and b2 >= 0x80 and b2 <= 0xBF then
      return 2
    end
  elseif b >= 0xE0 and b <= 0xEF then
    local b2, b3 = string.byte(s, i + 1, i + 2)
    local lo, hi = 0x80, 0xBF
    if b == 0xE0 then lo = 0xA0 end -- no overlongs
    if b == 0xED then hi = 0x9F end -- no surrogates
    if b2 and b3 and b2 >= lo and b2 <= hi and b3 >= 0x80 and b3 <= 0xBF then
      return 3
    end
  elseif b >= 0xF0 and b <= 0xF4 then
    local b2, b3, b4 = string.byte(s, i + 1, i + 3)
    local lo = 0x80
    if b == 0xF0 then lo = 0x90 end -- no overlongs
    if b2 and b3 and b4 and b2 >= lo and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
      return 4
    end
  end
  return nil
end

local function encode_string(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local seq = utf8_seq_len(s, i)
    if seq then
      local chunk = string.sub(s, i, i + seq - 1)
      out[#out + 1] = ESCAPES[chunk] or chunk
      i = i + seq
    else
      -- Invalid UTF-8 byte: never emit it raw (JSON must be valid UTF-8).
      out[#out + 1] = "\xEF\xBF\xBD" -- U+FFFD replacement character
      i = i + 1
    end
  end
  return '"' .. table.concat(out) .. '"'
end

local function encode_number(v)
  if v ~= v or v == math.huge or v == -math.huge then
    return nil, "cannot encode NaN or infinity"
  end
  if v % 1 == 0 and math.abs(v) < 2 ^ 53 then
    return string.format("%d", v)
  end
  return string.format("%.14g", v)
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then
      return false
    end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return true
end

local function encode_value(v, indent, depth, out)
  local t = type(v)
  if t == "nil" then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    local s, err = encode_number(v)
    if not s then
      return err
    end
    out[#out + 1] = s
  elseif t == "string" then
    out[#out + 1] = encode_string(v)
  elseif t == "table" then
    if depth > 96 then
      return "table nesting too deep"
    end
    if is_array(v) then
      out[#out + 1] = "["
      local n = #v
      for i = 1, n do
        if indent then
          out[#out + 1] = "\n" .. indent .. string.rep("  ", depth + 1)
        end
        local err = encode_value(v[i], indent, depth + 1, out)
        if err then
          return err
        end
        if i < n and not indent then
          out[#out + 1] = ","
        elseif i < n and indent then
          out[#out + 1] = ","
        end
      end
      if indent and n > 0 then
        out[#out + 1] = "\n" .. indent .. string.rep("  ", depth)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= "string" then
          return "table has a non-string key"
        end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for idx, k in ipairs(keys) do
        if indent then
          out[#out + 1] = "\n" .. indent .. string.rep("  ", depth + 1)
        end
        out[#out + 1] = encode_string(k)
        out[#out + 1] = indent and ": " or ":"
        local err = encode_value(v[k], indent, depth + 1, out)
        if err then
          return err
        end
        if idx < #keys then
          out[#out + 1] = ","
        end
      end
      if indent and #keys > 0 then
        out[#out + 1] = "\n" .. indent .. string.rep("  ", depth)
      end
      out[#out + 1] = "}"
    end
  else
    return "cannot encode value of type " .. t
  end
  return nil
end

-- encode(value) -> ok, text|err
-- encode(value, true) -> pretty-printed with two-space indentation
function M.encode(value, pretty)
  local out = {}
  local err = encode_value(value, pretty and "" or nil, 0, out)
  if err then
    return false, err
  end
  return true, table.concat(out)
end

-- ── Decoder ──────────────────────────────────────────────────────────────────

local Decoder = {}
Decoder.__index = Decoder

function Decoder.new(text)
  return setmetatable({ text = text, pos = 1 }, Decoder)
end

function Decoder:fail(msg)
  return nil, msg .. " at position " .. self.pos
end

function Decoder:skip_ws()
  local text, pos = self.text, self.pos
  while pos <= #text do
    local b = string.byte(text, pos)
    if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D then
      pos = pos + 1
    else
      break
    end
  end
  self.pos = pos
end

function Decoder:peek()
  if self.pos > #self.text then
    return nil
  end
  return string.sub(self.text, self.pos, self.pos)
end

function Decoder:expect(literal)
  if string.sub(self.text, self.pos, self.pos + #literal - 1) ~= literal then
    return self:fail("expected '" .. literal .. "'")
  end
  self.pos = self.pos + #literal
  return true
end

function Decoder:decode_string()
  local text, pos = self.text, self.pos
  if string.byte(text, pos) ~= 0x22 then
    return self:fail("expected string")
  end
  pos = pos + 1
  local parts = {}
  while pos <= #text do
    local b = string.byte(text, pos)
    if b == 0x22 then
      self.pos = pos + 1
      return table.concat(parts)
    elseif b == 0x5C then -- backslash
      local esc = string.sub(text, pos + 1, pos + 1)
      if esc == "u" then
        local hex = string.sub(text, pos + 2, pos + 5)
        local code = tonumber(hex, 16)
        if not code or #hex ~= 4 then
          self.pos = pos
          return self:fail("invalid \\u escape")
        end
        pos = pos + 6
        if code >= 0xD800 and code <= 0xDBFF then
          -- High surrogate: must be followed by a low surrogate.
          if string.byte(text, pos) == 0x5C and string.sub(text, pos + 1, pos + 1) == "u" then
            local hex2 = string.sub(text, pos + 2, pos + 5)
            local low = tonumber(hex2, 16)
            if low and #hex2 == 4 and low >= 0xDC00 and low <= 0xDFFF then
              pos = pos + 6
              code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            else
              code = 0xFFFD
            end
          else
            code = 0xFFFD
          end
        elseif code >= 0xDC00 and code <= 0xDFFF then
          code = 0xFFFD -- lone low surrogate
        end
        parts[#parts + 1] = utf8_encode_codepoint(code)
      elseif UNESCAPES[esc] then
        parts[#parts + 1] = UNESCAPES[esc]
        pos = pos + 2
      else
        self.pos = pos
        return self:fail("invalid escape sequence")
      end
    elseif b < 0x20 then
      self.pos = pos
      return self:fail("unescaped control character in string")
    else
      local seq = utf8_seq_len(text, pos)
      if seq then
        parts[#parts + 1] = string.sub(text, pos, pos + seq - 1)
        pos = pos + seq
      else
        parts[#parts + 1] = "\xEF\xBF\xBD"
        pos = pos + 1
      end
    end
  end
  self.pos = pos
  return self:fail("unterminated string")
end

local CODEPOINT_BUF = { 0, 0, 0, 0 }

function utf8_encode_codepoint(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    CODEPOINT_BUF[1] = 0xC0 + math.floor(code / 0x40)
    CODEPOINT_BUF[2] = 0x80 + code % 0x40
    return string.char(CODEPOINT_BUF[1], CODEPOINT_BUF[2])
  elseif code < 0x10000 then
    CODEPOINT_BUF[1] = 0xE0 + math.floor(code / 0x1000)
    CODEPOINT_BUF[2] = 0x80 + math.floor(code / 0x40) % 0x40
    CODEPOINT_BUF[3] = 0x80 + code % 0x40
    return string.char(CODEPOINT_BUF[1], CODEPOINT_BUF[2], CODEPOINT_BUF[3])
  else
    CODEPOINT_BUF[1] = 0xF0 + math.floor(code / 0x40000)
    CODEPOINT_BUF[2] = 0x80 + math.floor(code / 0x1000) % 0x40
    CODEPOINT_BUF[3] = 0x80 + math.floor(code / 0x40) % 0x40
    CODEPOINT_BUF[4] = 0x80 + code % 0x40
    return string.char(CODEPOINT_BUF[1], CODEPOINT_BUF[2], CODEPOINT_BUF[3], CODEPOINT_BUF[4])
  end
end

function Decoder:decode_number()
  local text, pos = self.text, self.pos
  local start = pos
  if string.byte(text, pos) == 0x2D then -- '-'
    pos = pos + 1
  end
  local digits = 0
  while pos <= #text and string.byte(text, pos) >= 0x30 and string.byte(text, pos) <= 0x39 do
    pos = pos + 1
    digits = digits + 1
  end
  if digits == 0 then
    return self:fail("invalid number")
  end
  if string.byte(text, pos) == 0x2E then -- '.'
    pos = pos + 1
    local frac = 0
    while pos <= #text and string.byte(text, pos) >= 0x30 and string.byte(text, pos) <= 0x39 do
      pos = pos + 1
      frac = frac + 1
    end
    if frac == 0 then
      return self:fail("invalid number")
    end
  end
  local b = string.byte(text, pos)
  if b == 0x65 or b == 0x45 then -- e/E
    pos = pos + 1
    if string.byte(text, pos) == 0x2B or string.byte(text, pos) == 0x2D then
      pos = pos + 1
    end
    local exp = 0
    while pos <= #text and string.byte(text, pos) >= 0x30 and string.byte(text, pos) <= 0x39 do
      pos = pos + 1
      exp = exp + 1
    end
    if exp == 0 then
      return self:fail("invalid number")
    end
  end
  local literal = string.sub(text, start, pos - 1)
  local value = tonumber(literal)
  if value == nil then
    self.pos = start
    return self:fail("invalid number")
  end
  self.pos = pos
  return value
end

function Decoder:decode_value(depth)
  if depth > 128 then
    return self:fail("nesting too deep")
  end
  self:skip_ws()
  local c = self:peek()
  if c == "{" then
    self.pos = self.pos + 1
    local obj = {}
    self:skip_ws()
    if self:peek() == "}" then
      self.pos = self.pos + 1
      return obj
    end
    while true do
      self:skip_ws()
      local key, key_err = self:decode_string()
      if key == nil then
        return nil, key_err
      end
      self:skip_ws()
      if not self:expect(":") then
        return nil, "expected ':'"
      end
      local value, err = self:decode_value(depth + 1)
      if value == nil and err then
        return nil, err
      end
      obj[key] = value
      self:skip_ws()
      local sep = self:peek()
      if sep == "," then
        self.pos = self.pos + 1
      elseif sep == "}" then
        self.pos = self.pos + 1
        return obj
      else
        return self:fail("expected ',' or '}'")
      end
    end
  elseif c == "[" then
    self.pos = self.pos + 1
    local arr = {}
    self:skip_ws()
    if self:peek() == "]" then
      self.pos = self.pos + 1
      return arr
    end
    while true do
      local value, err = self:decode_value(depth + 1)
      if value == nil and err then
        return nil, err
      end
      arr[#arr + 1] = value
      self:skip_ws()
      local sep = self:peek()
      if sep == "," then
        self.pos = self.pos + 1
      elseif sep == "]" then
        self.pos = self.pos + 1
        return arr
      else
        return self:fail("expected ',' or ']'")
      end
    end
  elseif c == '"' then
    local s, str_err = self:decode_string()
    if s == nil then
      return nil, str_err
    end
    return s
  elseif c == "t" then
    if not self:expect("true") then
      return nil, "expected 'true'"
    end
    return true
  elseif c == "f" then
    if not self:expect("false") then
      return nil, "expected 'false'"
    end
    return false
  elseif c == "n" then
    if not self:expect("null") then
      return nil, "expected 'null'"
    end
    return nil
  elseif c == "-" or (c and string.byte(c) >= 0x30 and string.byte(c) <= 0x39) then
    local n, num_err = self:decode_number()
    if n == nil then
      return nil, num_err
    end
    return n
  else
    return self:fail("unexpected character")
  end
end

-- decode(text) -> ok, value|err
function M.decode(text)
  if type(text) ~= "string" then
    return false, "input is not a string"
  end
  if #text == 0 then
    return false, "empty input"
  end
  if #text > 32 * 1024 * 1024 then
    return false, "input too large"
  end
  local d = Decoder.new(text)
  local value, err = d:decode_value(0)
  if err then
    return false, err
  end
  d:skip_ws()
  if d.pos <= #text then
    return false, "trailing content at position " .. d.pos
  end
  return true, value
end

return M
