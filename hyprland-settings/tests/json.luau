-- Small JSON decoder for the test fixtures (the host provides noctalia.json).
local function decode(text)
  local pos = 1
  local value

  local function space() pos = text:find("[^%s]", pos) or #text + 1 end

  local function str()
    local out = {}
    pos += 1
    while true do
      local c = text:sub(pos, pos)
      if c == '"' then pos += 1; return table.concat(out) end
      if c == "\\" then
        local e = text:sub(pos + 1, pos + 1)
        local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
        if e == "u" then
          table.insert(out, utf8.char(tonumber(text:sub(pos + 2, pos + 5), 16)))
          pos += 6
        else
          table.insert(out, map[e] or e)
          pos += 2
        end
      elseif c == "" then
        error("unterminated string")
      else
        table.insert(out, c)
        pos += 1
      end
    end
  end

  function value()
    space()
    local c = text:sub(pos, pos)
    if c == "{" then
      local t = {}
      pos += 1; space()
      if text:sub(pos, pos) == "}" then pos += 1; return t end
      while true do
        space()
        local k = str()
        space(); pos += 1 -- ':'
        t[k] = value()
        space()
        local d = text:sub(pos, pos); pos += 1
        if d == "}" then return t end
      end
    elseif c == "[" then
      local t = {}
      pos += 1; space()
      if text:sub(pos, pos) == "]" then pos += 1; return t end
      while true do
        table.insert(t, value())
        space()
        local d = text:sub(pos, pos); pos += 1
        if d == "]" then return t end
      end
    elseif c == '"' then
      return str()
    elseif text:sub(pos, pos + 3) == "true" then pos += 4; return true
    elseif text:sub(pos, pos + 4) == "false" then pos += 5; return false
    elseif text:sub(pos, pos + 3) == "null" then pos += 4; return nil
    end
    local num = text:match("^-?[%d%.eE+-]+", pos)
    pos += #num
    return tonumber(num)
  end

  return value()
end

return decode
