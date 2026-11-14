--!nonstrict
-- Lyrics model: the adapter's JSON as plain tables, plus the questions the
-- renderer asks: which line is active, how much of it has been sung, and
-- whether the player is in an instrumental gap.
--
-- Pure Lua: no noctalia, no ui. bin/test-render.lua drives it directly.

local M = {}

-- A sung line is never longer than this. LRC marks the end of a line with the
-- start of the next one, so a 90 second instrumental break would otherwise be
-- "sung" for 90 seconds. Past this, the interval is a gap.
M.MAX_LINE_SECONDS = 12

local function clamp(value, low, high)
  if value < low then
    return low
  elseif value > high then
    return high
  end
  return value
end

--- Turn the adapter's decoded JSON into the model, or nil if it is not lyrics.
function M.normalize(data)
  if type(data) ~= "table" or data.ok ~= true then
    return nil
  end
  if type(data.lines) ~= "table" or #data.lines == 0 then
    return nil
  end
  local lines = {}
  for index, item in ipairs(data.lines) do
    if type(item) == "table" and tonumber(item.start) ~= nil then
      local start = tonumber(item.start)
      local finish = tonumber(item["end"]) or start
      lines[index] = {
        start = start,
        ["end"] = finish,
        text = tostring(item.text or ""),
        chars = type(item.chars) == "table" and item.chars or nil,
      }
    end
  end
  if #lines == 0 then
    return nil
  end
  return { synced = data.synced == true, lines = lines }
end

--- Identity of a track, for the service: reload only when it changes.
function M.trackKey(title, artist, duration)
  return string.format(
    "%s\x1f%s\x1f%d",
    tostring(title or ""),
    tostring(artist or ""),
    math.floor(tonumber(duration) or 0)
  )
end

--- Line being sung at `position`, 1-based. 0 while the intro plays.
function M.activeIndex(lines, position)
  if type(lines) ~= "table" or #lines == 0 then
    return 0
  end
  if position < lines[1].start then
    return 0
  end
  local low, high = 1, #lines
  local found = 0
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if lines[middle].start <= position then
      found = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return found
end

--- Seconds of a line's interval that can be sung.
function M.sungSpan(line)
  local start = tonumber(line.start) or 0
  local finish = tonumber(line["end"]) or start
  return math.min(math.max(finish - start, 0), M.MAX_LINE_SECONDS)
end

--- Seconds of a line's interval that are a gap (0 for ordinary lines).
function M.gapSpan(line)
  local start = tonumber(line.start) or 0
  local finish = tonumber(line["end"]) or start
  return math.max(finish - start - M.MAX_LINE_SECONDS, 0)
end

--- Characters of a line, UTF-8 aware.
--
-- The adapter emits one timing per character and `#text` counts bytes, so
-- accented lyrics ("canción" is 7 characters and 8 bytes) would look
-- misaligned. Luau has no `utf8.codes`, hence the offset walk.
function M.characters(text)
  text = tostring(text or "")
  local count = utf8.len(text)
  if count == nil then
    local bytes = {}
    for index = 1, #text do
      bytes[index] = text:sub(index, index)
    end
    return bytes
  end
  local out = {}
  for index = 1, count do
    local first = utf8.offset(text, index)
    local after = utf8.offset(text, index + 1)
    out[index] = text:sub(first, (after or (#text + 1)) - 1)
  end
  return out
end

--- True if the line carries usable per-character timings.
--
-- Strict on purpose: the renderer switches to the whole-line fill when the
-- timings are missing, not aligned with the text, out of order or outside the
-- line. A wrong set of timings looks worse than no karaoke at all.
function M.hasWordTiming(line)
  local chars = line and line.chars
  local text = (line and line.text) or ""
  local count = #M.characters(text)
  if type(chars) ~= "table" or count < 2 or #chars < count then
    return false
  end
  local start = tonumber(line.start) or 0
  local finish = tonumber(line["end"]) or start
  local previous = nil
  for index = 1, count do
    local value = tonumber(chars[index])
    if value == nil then
      return false
    end
    if previous ~= nil and value < previous then
      return false
    end
    previous = value
  end
  if previous == nil then
    return false
  end
  local first = tonumber(chars[1]) or start
  return first >= start - 0.25 and previous <= finish + 0.5
end

--- How much of the line has been sung, 0..1.
function M.lineProgress(line, position)
  if line == nil then
    return 0
  end
  if M.hasWordTiming(line) then
    local count = #M.characters(line.text)
    local finish = tonumber(line.chars[count]) or line.start
    local begin = tonumber(line.chars[1]) or line.start
    if finish <= begin then
      return 1
    end
    return clamp((position - begin) / (finish - begin), 0, 1)
  end
  local span = M.sungSpan(line)
  if span <= 0 then
    return position >= line.start and 1 or 0
  end
  return clamp((position - line.start) / span, 0, 1)
end

--- Fill amount for each character of the line, 0..1 per character.
--
-- Word timings give a smooth edge inside the character being sung; without
-- them the whole line advances as one block.
function M.charAmounts(line, position)
  local text = (line and line.text) or ""
  local amounts = {}
  local count = #M.characters(text)
  if count == 0 then
    return amounts
  end
  if not M.hasWordTiming(line) then
    local amount = M.lineProgress(line, position)
    for index = 1, count do
      amounts[index] = amount
    end
    return amounts
  end
  local chars = line.chars
  local tail = tonumber(line["end"]) or (tonumber(chars[count]) or 0)
  for index = 1, count do
    local begin = tonumber(chars[index]) or 0
    local finish = tonumber(chars[index + 1])
    if finish == nil then
      finish = tail
    end
    if finish <= begin then
      finish = begin + 0.12
    end
    amounts[index] = clamp((position - begin) / (finish - begin), 0, 1)
  end
  return amounts
end

--- True if `position` falls in a stretch with nothing to sing.
--
-- Three cases: an explicit empty line (some providers mark breaks that way),
-- the intro before the first line, and the tail of an interval longer than a
-- line (a long break or the outro). A gap only counts when it is at least
-- `threshold` seconds long, so a slightly long line is not a gap.
function M.instrumental(lines, position, duration, threshold)
  if type(lines) ~= "table" or #lines == 0 then
    return false
  end
  threshold = tonumber(threshold) or 4
  local index = M.activeIndex(lines, position)
  if index == 0 then
    return lines[1].start >= threshold
  end
  local line = lines[index]
  local start = tonumber(line.start) or 0
  local finish = tonumber(line["end"]) or start
  local span = math.max(finish - start, 0)
  if line.text == "" then
    return span >= threshold
  end
  local gap = span - M.sungSpan(line)
  if gap < threshold then
    return false
  end
  if position > start + M.sungSpan(line) then
    return true
  end
  -- The last line: anything after it belongs to the outro.
  if index == #lines and duration and duration > finish then
    return position > finish
  end
  return false
end

return M
