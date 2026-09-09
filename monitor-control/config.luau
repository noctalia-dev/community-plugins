--!nonstrict
-- Config patching for Monitor Control, kept free of host globals so it can be
-- unit-tested outside Noctalia (see tests/run.lua).
--
-- The Umbriel config is TOML: we locate the [output.<name>] section (bare or
-- quoted connector/monitor name, matched case-insensitively like Umbriel
-- itself), replace or append the `mode` / `position` keys in place, and touch
-- nothing else - comments, other sections, and hand edits survive.

local M = {}

function M.splitLines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return lines
end

-- Output name (lowercased) from a [output.X] or [output."Make Model Serial"]
-- header line, or nil. Nested headers like [output.DP-1.layout.scrolling]
-- return their full dotted tail, which never equals a bare connector name -
-- so they correctly count as the end of the base section.
local function headerName(line)
  local tail = string.match(line, '^%s*%[output%.(.-)%]%s*$')
  if tail == nil then
    return nil
  end
  local quoted = string.match(tail, '^"(.*)"$')
  if quoted ~= nil then
    tail = quoted
  end
  return string.lower(tail)
end

-- Index of the [output.<name>] header and the exclusive end index: the next
-- table header of any kind (keys below it belong to that table), or just past
-- the last line. nil when the section is absent.
function M.findSection(lines, name)
  local wanted = string.lower(name)
  local found = nil
  for index, line in ipairs(lines) do
    if found == nil then
      if headerName(line) == wanted then
        found = index
      end
    elseif string.match(line, '^%s*%[') then
      return found, index
    end
  end
  if found == nil then
    return nil
  end
  return found, #lines + 1
end

-- Trailing TOML comment on a line ("# ..."), or nil. A '#' inside a
-- double-quoted string is not a comment; scan for the first one outside
-- quotes so values containing '#' survive.
local function trailingComment(line)
  local inString = false
  for index = 1, #line do
    local c = line:sub(index, index)
    if c == '"' then
      inString = not inString
    elseif c == "#" and not inString then
      return line:sub(index):match("^%s*(.-)%s*$")
    end
  end
  return nil
end

-- Sets key = value inside [start, stop): replaces an active line for that key
-- (keeping any trailing comment), otherwise appends it at the end of the
-- section.
function M.setKey(lines, start, stop, key, value)
  for index = start + 1, stop - 1 do
    local trimmed = string.match(lines[index], "^%s*(.-)%s*$")
    if string.match(trimmed, "^" .. key .. "%s*=") then
      local comment = trailingComment(trimmed)
      if comment ~= nil then
        lines[index] = key .. " = " .. value .. " # " .. comment
      else
        lines[index] = key .. " = " .. value
      end
      return
    end
  end
  table.insert(lines, stop, key .. " = " .. value)
end

-- fields.mode / fields.x,y are optional; only present keys are written.
-- Returns patched text, or nil plus a reason.
function M.patchConfig(text, name, fields)
  if type(name) ~= "string" or name == "" then
    return nil, "empty output name"
  end
  local lines = M.splitLines(text)
  local start, stop = M.findSection(lines, name)

  if start == nil then
    local quote = string.match(name, "[^%w_%-%.]") ~= nil
    local header
    if quote then
      header = '[output."' .. name .. '"]'
    else
      header = "[output." .. name .. "]"
    end
    table.insert(lines, "")
    table.insert(lines, header)
    start, stop = #lines - 1, #lines + 1
  end

  if type(fields.mode) == "string" then
    M.setKey(lines, start, stop, "mode", '"' .. fields.mode .. '"')
  end
  if type(fields.x) == "number" and type(fields.y) == "number" then
    M.setKey(lines, start, stop, "position", "[" .. fields.x .. ", " .. fields.y .. "]")
  end
  return table.concat(lines, "\n")
end

-- refresh_mhz -> short Hz label: 143999 -> "144", 59940 -> "59.94".
function M.hzText(refreshMhz)
  local hz = refreshMhz / 1000
  local rounded = math.floor(hz + 0.5)
  if math.abs(hz - rounded) < 0.02 then
    return tostring(rounded)
  end
  return string.format("%.2f", hz)
end

return M
