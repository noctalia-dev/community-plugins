--!nonstrict
-- Config patching for Monitor Control, kept free of host globals so it can be
-- unit-tested outside Noctalia (see tests/run.lua).
--
-- The Umbriel config is TOML: we locate the [output.<name>] section (bare or
-- quoted connector/monitor name, matched case-insensitively like Umbriel
-- itself), replace or append the `mode` / `position` / `transform` keys in
-- place, and touch nothing else - comments, other sections, and hand edits
-- survive.

local M = {}

-- The transform vocabulary Umbriel accepts for [output.*] transform, in the
-- order the compositor prints them: the four rotations, then the same four
-- mirrored. Only these values are ever written, so a bad rotation cannot
-- reach the config.
M.TRANSFORMS = {
  "normal", "90", "180", "270",
  "flipped", "flipped-90", "flipped-180", "flipped-270",
}

function M.isTransform(value)
  if type(value) ~= "string" then
    return false
  end
  for _, transform in ipairs(M.TRANSFORMS) do
    if transform == value then
      return true
    end
  end
  return false
end

-- Zero-based position of a live transform in TRANSFORMS, for a select field.
-- An unknown or absent value reads as the first entry (no rotation).
function M.rotationIndex(value)
  local live = value or "normal"
  for index, transform in ipairs(M.TRANSFORMS) do
    if transform == live then
      return index - 1
    end
  end
  return 0
end

-- The label a rotation select shows for a transform value: "normal" and
-- "flipped" read 0°, "90" and "flipped-90" read 90°, and so on. The mirrored
-- variants carry the caller's word for "flipped" (the caller passes the
-- translated one). An unknown value falls through as itself.
function M.rotationLabel(value, flippedWord)
  local mirrored = string.match(value, "^flipped%-?(%d*)$")
  if mirrored ~= nil then
    local degrees = mirrored == "" and "0" or mirrored
    return degrees .. "° " .. (flippedWord or "flipped")
  end
  local degrees = string.match(value, "^(%d+)$")
  if degrees ~= nil then
    return degrees .. "°"
  end
  if value == "normal" then
    return "0°"
  end
  return value
end

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

-- Trailing TOML comment on a line, or nil. Returned WITHOUT its leading '#',
-- so callers can re-attach exactly one. A '#' inside a double-quoted string is
-- not a comment; scan for the first one outside quotes so values containing
-- '#' survive.
local function trailingComment(line)
  local inString = false
  for index = 1, #line do
    local c = line:sub(index, index)
    if c == '"' then
      inString = not inString
    elseif c == "#" and not inString then
      return line:sub(index + 1):match("^%s*(.-)%s*$")
    end
  end
  return nil
end

-- Sets key = value inside [start, stop): replaces an active line for that key
-- (keeping any trailing comment), otherwise appends it at the end of the
-- section. The comment is re-attached with a single "# ", so patching the same
-- key repeatedly leaves the line's comment count unchanged.
function M.setKey(lines, start, stop, key, value)
  for index = start + 1, stop - 1 do
    local trimmed = string.match(lines[index], "^%s*(.-)%s*$")
    if string.match(trimmed, "^" .. key .. "%s*=") then
      local comment = trailingComment(trimmed)
      if comment ~= nil and comment ~= "" then
        lines[index] = key .. " = " .. value .. " # " .. comment
      else
        lines[index] = key .. " = " .. value
      end
      return
    end
  end
  table.insert(lines, stop, key .. " = " .. value)
end

-- fields.mode / fields.x,y / fields.transform are optional; only present keys
-- are written. Returns patched text, or nil plus a reason.
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

  -- Each write re-locates the section afterwards: setKey inserts AT `stop`, and
  -- that insert is the new end of the section, so a second key written with the
  -- stale boundary would land before the first - a freshly appended section
  -- would come out in reverse key order.
  local function writeKey(key, value)
    M.setKey(lines, start, stop, key, value)
    start, stop = M.findSection(lines, name)
  end

  if type(fields.mode) == "string" then
    writeKey("mode", '"' .. fields.mode .. '"')
  end
  if type(fields.x) == "number" and type(fields.y) == "number" then
    writeKey("position", "[" .. fields.x .. ", " .. fields.y .. "]")
  end
  if M.isTransform(fields.transform) then
    writeKey("transform", '"' .. fields.transform .. '"')
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
