--!nonstrict

-- Pure helpers behind `faminec/monkeytype-activity`: the compact heatmap
-- representation, UTC day bucketing, and normalisation of the API payloads.
--
-- MonkeyType buckets test activity by UTC day (the backend's
-- `generateCurrentTestActivity` reads the per-year UTC day counters), so every
-- date derived here is UTC on purpose. Local time would shift the columns
-- against the heatmap on monkeytype.com/profile.

local Activity = {}

local LEVEL_SYMBOLS = { "·", "░", "▒", "▓", "█" }
local LEVEL_COLORS = {
  "surface_container",
  "primary/0.25",
  "primary/0.45",
  "primary/0.70",
  "primary",
}
local SECONDS_PER_DAY = 86400

local function clampLevel(value)
  if type(value) ~= "number" then
    return 0
  end
  local level = math.floor(value)
  if level < 0 then
    return 0
  end
  if level > 4 then
    return 4
  end
  return level
end

function Activity.color(level)
  return LEVEL_COLORS[clampLevel(level) + 1]
end

function Activity.symbol(level)
  return LEVEL_SYMBOLS[clampLevel(level) + 1]
end

-- Levels of one stored heatmap row. The panel keeps the grid as seven short
-- strings so a cached calendar stays small and cheap to rebuild.
function Activity.rowLevels(row)
  local levels = {}
  local byCodepoint = {
    [0x00B7] = 0,
    [0x2591] = 1,
    [0x2592] = 2,
    [0x2593] = 3,
    [0x2588] = 4,
  }
  for _, codepoint in utf8.codes(row or "") do
    table.insert(levels, byCodepoint[codepoint] or 0)
  end
  return levels
end

-- MonkeyType reports timestamps in milliseconds (`lastDay`,
-- `lastResultTimestamp`), while Luau's os.date/os.time work in seconds. Any
-- value past this threshold cannot be a plausible second timestamp.
local MILLISECOND_THRESHOLD = 100000000000

function Activity.toSeconds(timestamp)
  if type(timestamp) ~= "number" or timestamp <= 0 then
    return nil
  end
  if timestamp > MILLISECOND_THRESHOLD then
    return math.floor(timestamp / 1000)
  end
  return math.floor(timestamp)
end

-- ISO date of a UTC timestamp, e.g. "2026-02-14".
function Activity.utcDate(timestamp)
  return os.date("!%Y-%m-%d", timestamp)
end

-- Parse an ISO calendar date as local noon. Noon avoids DST boundary changes,
-- while the round trip rejects values that os.time would otherwise normalize.
-- Only used to format labels. `os.time(table)` is UTC in Luau and `os.date`
-- without "!" is local, so the round trip is verified in UTC to stay correct at
-- any offset, including the +12…+14 zones where local noon is the next day.
function Activity.dateTimestamp(value)
  if type(value) ~= "string" then
    return nil
  end

  local year, month, day = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if year == nil then
    return nil
  end

  local timestamp = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = 12,
  })

  if type(timestamp) ~= "number" or os.date("!%Y-%m-%d", timestamp) ~= value then
    return nil
  end

  return timestamp
end

-- Quartile thresholds over the days that have tests, so the four shaded levels
-- keep their meaning whether somebody types five tests a day or five hundred.
function Activity.quartiles(counts)
  local values = {}
  for _, count in ipairs(counts or {}) do
    if count > 0 then
      table.insert(values, count)
    end
  end

  if #values == 0 then
    return { 1, 1, 1 }
  end

  table.sort(values)
  local function at(fraction)
    -- Round up so each quartile holds roughly a quarter of the active days;
    -- flooring collapses the upper levels on short histories.
    local index = math.ceil(#values * fraction)
    if index < 1 then
      index = 1
    end
    if index > #values then
      index = #values
    end
    return values[index]
  end

  return { at(0.25), at(0.5), at(0.75) }
end

function Activity.levelForCount(count, thresholds)
  if type(count) ~= "number" or count <= 0 then
    return 0
  end

  local limits = thresholds or { 1, 1, 1 }
  if count <= limits[1] then
    return 1
  end
  if count <= limits[2] then
    return 2
  end
  if count <= limits[3] then
    return 3
  end
  return 4
end

-- Current and best run of consecutive active days inside the window. Only a
-- fallback: the streak endpoint reports the authoritative numbers.
function Activity.streaks(counts)
  local best = 0
  local running = 0

  if type(counts) ~= "table" then
    return 0, 0
  end

  for _, count in ipairs(counts) do
    if count > 0 then
      running = running + 1
      if running > best then
        best = running
      end
    else
      running = 0
    end
  end

  local current = 0
  for index = #counts, 1, -1 do
    if counts[index] == 0 then
      break
    end
    current = current + 1
  end

  return current, best
end

-- Lay `counts` out as seven weekday rows of week columns, ending on
-- `lastTimestamp` (a UTC midnight). The window usually starts mid-week, so the
-- leading cells of the first column are padded to keep rows and details
-- column aligned; the panel renders no cell for a padded position.
function Activity.build(counts, lastTimestamp)
  local count = #counts
  local total = 0
  for index = 1, count do
    total = total + counts[index]
  end

  local thresholds = Activity.quartiles(counts)
  local firstTimestamp = lastTimestamp - (count - 1) * SECONDS_PER_DAY
  local firstWeekday = os.date("!*t", firstTimestamp).wday
  local columns = math.ceil((firstWeekday - 1 + count) / 7)
  local pad = firstWeekday - 1
  local rows = {}
  local details = {}

  for weekday = 1, 7 do
    local symbols = {}
    local fields = {}
    for column = 1, columns do
      local index = (column - 1) * 7 + weekday - pad
      if index < 1 or index > count then
        table.insert(symbols, Activity.symbol(0))
        table.insert(fields, "")
      else
        local timestamp = firstTimestamp + (index - 1) * SECONDS_PER_DAY
        table.insert(symbols, Activity.symbol(Activity.levelForCount(counts[index], thresholds)))
        table.insert(fields, Activity.utcDate(timestamp) .. "|" .. tostring(counts[index]))
      end
    end
    rows[weekday] = table.concat(symbols)
    details[weekday] = table.concat(fields, "\t")
  end

  return {
    rows = rows,
    details = details,
    columns = columns,
    thresholds = thresholds,
    windowTotal = total,
    firstDate = Activity.utcDate(firstTimestamp),
    lastDate = Activity.utcDate(lastTimestamp),
  }
end

-- Tests recorded on the current UTC day, mapped back through the window's last
-- day. MonkeyType ends the window on today (UTC), so the last entry is normally
-- the count for today; the offset still handles a payload from an earlier day.
function Activity.todayCount(counts, lastTimestamp, now)
  local stamp = now or os.time()
  local todayTimestamp = stamp - stamp % SECONDS_PER_DAY
  local index = Activity.todayIndex(counts, lastTimestamp, now)
  if index == nil then
    return 0, Activity.utcDate(todayTimestamp)
  end

  return counts[index] or 0, Activity.utcDate(todayTimestamp)
end

-- Position of the current UTC day inside the window, or nil when the window
-- does not reach it (a stale cache keeps its own last day).
function Activity.todayIndex(counts, lastTimestamp, now)
  local stamp = now or os.time()
  local todayTimestamp = stamp - stamp % SECONDS_PER_DAY
  local offset = (todayTimestamp - lastTimestamp) / SECONDS_PER_DAY
  local index = #counts + offset
  if index < 1 or index > #counts then
    return nil
  end
  return index
end

-- Two figures the metric bars need, both bounded whatever the account size:
-- how many of the last 365 days have at least one test, and the average of the
-- seven days before today (a "typical day" to compare today against).
function Activity.recencyFigures(counts, todayIndex)
  local activeDays = 0
  local first = math.max(1, #counts - 364)
  local last = todayIndex or #counts
  for index = first, last do
    if (counts[index] or 0) > 0 then
      activeDays = activeDays + 1
    end
  end

  local sum, days = 0, 0
  local windowEnd = (todayIndex or #counts) - 1
  for index = windowEnd - 6, windowEnd do
    if index >= 1 and counts[index] ~= nil then
      sum = sum + counts[index]
      days = days + 1
    end
  end

  return activeDays, days > 0 and math.floor(sum / days + 0.5) or 0
end

local function positiveInteger(value)
  if type(value) ~= "number" or value < 0 then
    return nil
  end
  return math.floor(value)
end

local function numberOr(value, fallback)
  if type(value) ~= "number" then
    return fallback
  end
  return value
end

local function lastResultFields(result, previous)
  if type(result) ~= "table" then
    return previous
  end

  local wpm = type(result.wpm) == "number" and math.floor(result.wpm + 0.5) or nil
  local accuracy = type(result.acc) == "number" and math.floor(result.acc + 0.5) or nil
  local mode = type(result.mode) == "string" and result.mode or nil
  local mode2 = nil
  if type(result.mode2) == "string" or type(result.mode2) == "number" then
    mode2 = tostring(result.mode2)
  end

  return {
    lastWpm = wpm,
    lastAcc = accuracy,
    lastMode = mode,
    lastMode2 = mode2,
    lastTestAt = Activity.toSeconds(result.timestamp),
  }
end

-- Normalise the four API payloads into the cached shape shared with the widget
-- and the panel. `previous` keeps the optional values alive when one of the
-- secondary requests failed on this refresh.
function Activity.normalize(parts)
  local days = parts and parts.days
  local lastDay = parts and parts.lastDay
  if type(days) ~= "table" then
    return nil, "missing test activity"
  end
  if Activity.toSeconds(lastDay) == nil then
    return nil, "missing last activity day"
  end

  local dayCount = parts.dayCount
  if type(dayCount) ~= "number" or dayCount < 1 or dayCount > 1000 then
    dayCount = #days
  end
  if dayCount < 1 then
    return nil, "empty test activity"
  end

  -- A JSON null decodes to nil, which truncates the array in Luau, so the
  -- caller passes the real length read from the response body. Missing and
  -- trailing days become zero-test days.
  local counts = {}
  for index = 1, dayCount do
    local value = days[index]
    if type(value) == "number" and value > 0 then
      counts[index] = math.floor(value)
    else
      counts[index] = 0
    end
  end

  local lastSeconds = Activity.toSeconds(lastDay)
  local lastTimestamp = lastSeconds - lastSeconds % SECONDS_PER_DAY
  local built = Activity.build(counts, lastTimestamp)
  local today, todayDate = Activity.todayCount(counts, lastTimestamp, parts.now)
  local todayIndex = Activity.todayIndex(counts, lastTimestamp, parts.now)
  local activeDays, recentAverage = Activity.recencyFigures(counts, todayIndex)
  local streak = type(parts.streak) == "table" and parts.streak or {}
  local previous = type(parts.previous) == "table" and parts.previous or {}
  local localStreak, localBest = Activity.streaks(counts)
  local lastResult = lastResultFields(parts.lastResult, previous)

  local currentStreak = numberOr(streak.length, previous.currentStreak)
  if currentStreak == nil then
    currentStreak = localStreak
  end
  local bestStreak = numberOr(streak.maxLength, previous.bestStreak)
  if bestStreak == nil then
    bestStreak = localBest
  end

  return {
    rows = built.rows,
    details = built.details,
    columns = built.columns,
    thresholds = built.thresholds,
    windowTotal = built.windowTotal,
    firstDate = built.firstDate,
    lastDate = built.lastDate,
    today = today,
    todayDate = todayDate,
    activeDays = activeDays,
    recentAverage = recentAverage,
    currentStreak = positiveInteger(currentStreak) or 0,
    bestStreak = positiveInteger(bestStreak) or 0,
    lastResultTimestamp = Activity.toSeconds(streak.lastResultTimestamp),
    lastWpm = lastResult.lastWpm,
    lastAcc = lastResult.lastAcc,
    lastMode = lastResult.lastMode,
    lastMode2 = lastResult.lastMode2,
    lastTestAt = lastResult.lastTestAt,
    fetchedAt = parts.now or os.time(),
  }
end

function Activity.isValidCache(data)
  if type(data) ~= "table" then
    return false
  end

  if type(data.rows) ~= "table" or type(data.details) ~= "table" then
    return false
  end

  for weekday = 1, 7 do
    if type(data.rows[weekday]) ~= "string" or type(data.details[weekday]) ~= "string" then
      return false
    end
  end

  return type(data.today) == "number"
    and type(data.todayDate) == "string"
    and type(data.windowTotal) == "number"
    and type(data.currentStreak) == "number"
    and type(data.bestStreak) == "number"
    and type(data.columns) == "number"
    and type(data.fetchedAt) == "number"
    and type(data.activeDays) == "number"
    and type(data.recentAverage) == "number"
end

return Activity
