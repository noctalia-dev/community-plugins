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

function Activity.levelForCount(count, thresholds)
  if type(count) ~= "number" or count <= 0 then
    return 0
  end
  thresholds = thresholds or {}
  local q1 = thresholds[1] or 1
  local q2 = thresholds[2] or q1
  local q3 = thresholds[3] or q2
  if count <= q1 then
    return 1
  elseif count <= q2 then
    return 2
  elseif count <= q3 then
    return 3
  end
  return 4
end

function Activity.symbol(levelOrCount, thresholds)
  if type(thresholds) == "table" then
    return LEVEL_SYMBOLS[Activity.levelForCount(levelOrCount, thresholds) + 1]
  end
  return LEVEL_SYMBOLS[clampLevel(levelOrCount) + 1]
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
    if type(count) == "number" and count > 0 then
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
    elseif index > #values then
      index = #values
    end
    return values[index]
  end

  local low = at(0.25)
  local mid = at(0.50)
  local high = at(0.75)
  if mid < low then
    mid = low
  end
  if high < mid then
    high = mid
  end
  return { low, mid, high }
end

-- Current and longest streak, computed from the counts that span the rolling
-- window. Only a fallback: the streak endpoint reports the authoritative
-- numbers.
function Activity.streaks(counts)
  local best = 0
  local running = 0

  if type(counts) ~= "table" then
    return 0, 0
  end

  for _, count in ipairs(counts) do
    if type(count) == "number" and count > 0 then
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
    local count = counts[index]
    if type(count) ~= "number" or count <= 0 then
      break
    end
    current = current + 1
  end

  return current, best
end

local function isAvailableCount(count)
  return type(count) == "number" and count >= 0
end

-- Lay `counts` out as seven weekday rows of week columns, ending on
-- `lastTimestamp`. The leading and trailing cells outside the window are padded
-- to keep rows and details aligned to columns. Returns the grid plus the
-- covered range (first/last dates with actual data available).
function Activity.build(counts, lastTimestamp)
  counts = counts or {}
  local count = #counts
  local total = 0
  for index = 1, count do
    local value = counts[index]
    if isAvailableCount(value) then
      total = total + value
    end
  end

  local thresholds = Activity.quartiles(counts)

  local firstTimestamp = lastTimestamp - (count - 1) * SECONDS_PER_DAY
  local firstWeekday = tonumber(os.date("!%w", firstTimestamp)) or 0
  local columns = math.ceil((count + firstWeekday) / 7)
  if columns < 1 then
    columns = 1
  end

  local rows = {}
  local details = {}

  for weekday = 1, 7 do
    local symbols = {}
    local fields = {}
    for column = 1, columns do
      local index = (column - 1) * 7 + (weekday - 1 - firstWeekday) + 1
      if index >= 1 and index <= count then
        local timestamp = firstTimestamp + (index - 1) * SECONDS_PER_DAY
        local dateStr = Activity.utcDate(timestamp)
        local value = counts[index]
        if isAvailableCount(value) then
          table.insert(symbols, Activity.symbol(value, thresholds))
          table.insert(fields, dateStr .. "|" .. tostring(value))
        else
          table.insert(symbols, " ")
          table.insert(fields, dateStr .. "|-1")
        end
      else
        table.insert(symbols, " ")
        table.insert(fields, "")
      end
    end
    rows[weekday] = table.concat(symbols)
    details[weekday] = table.concat(fields, "\t")
  end

  local coveredFirstDate = nil
  local coveredLastDate = nil
  for index = 1, count do
    if isAvailableCount(counts[index]) then
      local timestamp = firstTimestamp + (index - 1) * SECONDS_PER_DAY
      local dateStr = Activity.utcDate(timestamp)
      if coveredFirstDate == nil then
        coveredFirstDate = dateStr
      end
      coveredLastDate = dateStr
    end
  end

  return {
    rows = rows,
    details = details,
    columns = columns,
    thresholds = thresholds,
    windowTotal = total,
    firstDate = Activity.utcDate(firstTimestamp),
    lastDate = Activity.utcDate(lastTimestamp),
    coveredFirstDate = coveredFirstDate,
    coveredLastDate = coveredLastDate,
  }
end

-- Years present in the rolling window (descending, newest first). A year counts
-- as available when at least one day in that calendar year falls inside the
-- window, so the selector only offers views the data can actually render.
function Activity.availableYears(counts, lastTimestamp)
  if type(counts) ~= "table" or #counts == 0 or Activity.toSeconds(lastTimestamp) == nil then
    return {}
  end

  local count = #counts
  local firstTimestamp = lastTimestamp - (count - 1) * SECONDS_PER_DAY
  local firstYear = tonumber(os.date("!%Y", firstTimestamp))
  local lastYear = tonumber(os.date("!%Y", lastTimestamp))
  local years = {}
  if firstYear == nil or lastYear == nil then
    return years
  end
  for year = lastYear, firstYear, -1 do
    table.insert(years, tostring(year))
  end
  return years
end

-- Build the compact grid for a single calendar year. Days outside the
-- available data window are marked unavailable so the panel can distinguish
-- them from days with zero tests.
function Activity.buildYear(counts, lastTimestamp, yearStr)
  if type(counts) ~= "table" or #counts == 0 or Activity.toSeconds(lastTimestamp) == nil then
    return nil
  end

  local y = tonumber(yearStr)
  if y == nil then
    return nil
  end

  local count = #counts
  local firstData = lastTimestamp - (count - 1) * SECONDS_PER_DAY
  local jan1 = os.time({ year = y, month = 1, day = 1, hour = 12 })
  local dec31 = os.time({ year = y, month = 12, day = 31, hour = 12 })
  if jan1 == nil or dec31 == nil then
    return nil
  end
  jan1 = jan1 - jan1 % SECONDS_PER_DAY
  dec31 = dec31 - dec31 % SECONDS_PER_DAY

  local daysInYear = math.floor((dec31 - jan1) / SECONDS_PER_DAY) + 1
  local yearCounts = {}
  local yearTotal = 0
  local activeDays = 0
  for i = 1, daysInYear do
    local ts = jan1 + (i - 1) * SECONDS_PER_DAY
    if ts >= firstData and ts <= lastTimestamp then
      local index = math.floor((ts - firstData) / SECONDS_PER_DAY) + 1
      local c = counts[index]
      if type(c) ~= "number" or c < 0 then
        c = 0
      end
      c = math.floor(c)
      yearCounts[i] = c
      yearTotal = yearTotal + c
      if c > 0 then
        activeDays = activeDays + 1
      end
    else
      yearCounts[i] = -1
    end
  end

  local built = Activity.build(yearCounts, dec31)
  built.windowTotal = yearTotal
  built.activeDays = activeDays
  built.view = "year"
  built.year = yearStr
  return built
end

-- Return a view descriptor: rolling (default, the cached grid) or a specific
-- calendar year. Year views are derived from the raw counts stored in the
-- cache so no extra API call is needed.
function Activity.buildView(data, view)
  if type(data) ~= "table" then
    return nil
  end

  if view == nil or view == "rolling" then
    return {
      rows = data.rows,
      details = data.details,
      columns = data.columns,
      thresholds = data.thresholds,
      windowTotal = data.windowTotal,
      firstDate = data.firstDate,
      lastDate = data.lastDate,
      coveredFirstDate = data.firstDate,
      coveredLastDate = data.lastDate,
      activeDays = data.activeDays,
      view = "rolling",
    }
  end

  if type(data.counts) == "table" and data.lastTimestamp ~= nil then
    local yearBuilt = Activity.buildYear(data.counts, data.lastTimestamp, view)
    if yearBuilt ~= nil then
      return yearBuilt
    end
  end

  return {
    rows = data.rows,
    details = data.details,
    columns = data.columns,
    thresholds = data.thresholds,
    windowTotal = data.windowTotal,
    firstDate = data.firstDate,
    lastDate = data.lastDate,
    coveredFirstDate = data.firstDate,
    coveredLastDate = data.lastDate,
    activeDays = data.activeDays,
    view = "rolling",
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

local function numberOr(value, fallback)
  if type(value) ~= "number" then
    return fallback
  end
  return value
end

local function positiveInteger(value)
  if type(value) ~= "number" or value < 0 then
    return nil
  end
  return math.floor(value)
end

local function extractLastResult(source, previous)
  source = type(source) == "table" and source or {}
  previous = type(previous) == "table" and previous or {}

  local wpm = source.wpm
  if type(wpm) ~= "number" then wpm = previous.lastWpm or previous.wpm end
  if type(wpm) == "number" then wpm = math.floor(wpm + 0.5) else wpm = nil end

  local acc = source.acc
  if type(acc) ~= "number" then acc = previous.lastAcc or previous.acc end
  if type(acc) == "number" then acc = math.floor(acc + 0.5) else acc = nil end

  local mode = source.mode
  if type(mode) ~= "string" then mode = previous.lastMode or previous.mode end

  local mode2 = source.mode2
  if mode2 == nil then mode2 = previous.lastMode2 or previous.mode2 end
  if type(mode2) == "string" or type(mode2) == "number" then
    mode2 = tostring(mode2)
  else
    mode2 = nil
  end

  local timestamp = Activity.toSeconds(source.timestamp or source.lastResultTimestamp or previous.lastResultTimestamp or previous.lastTestAt)

  return {
    lastWpm = wpm,
    lastAcc = acc,
    lastMode = mode,
    lastMode2 = mode2,
    lastResultTimestamp = timestamp,
  }
end

-- Normalise a full fetch (activity window, streak, latest result) into the
-- compact payload cached on disk and published to the UI. Accepts both
-- old-style (days/dayCount/lastDay/now) and new-style
-- (counts/lastTimestamp/fetchedAt) argument names.
function Activity.normalize(parts)
  parts = parts or {}
  local days = parts.counts or parts.days
  local lastDay = parts.lastTimestamp or parts.lastDay
  if type(days) ~= "table" then
    return nil, "missing test activity"
  end
  if Activity.toSeconds(lastDay) == nil then
    return nil, "missing last activity day"
  end

  local dayCount = parts.dayCount
  if type(dayCount) ~= "number" or dayCount < 1 then
    dayCount = #days
  end
  if dayCount < 1 then
    return nil, "empty activity window"
  end
  if dayCount > 1000 then
    dayCount = 1000
  end

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
  local now = parts.now or parts.fetchedAt or os.time()
  local built = Activity.build(counts, lastTimestamp)
  local todayIndex = Activity.todayIndex(counts, lastTimestamp, now)
  local today = 0
  local todayDate = Activity.utcDate(now)
  if todayIndex ~= nil then
    today = counts[todayIndex] or 0
    todayDate = Activity.utcDate(lastTimestamp + (todayIndex - #counts) * SECONDS_PER_DAY)
  end

  local activeDays, recentAverage = Activity.recencyFigures(counts, todayIndex)
  local localCurrent, localBest = Activity.streaks(counts)
  local streak = type(parts.streak) == "table" and parts.streak or {}
  local previous = type(parts.previous) == "table" and parts.previous or parts or {}

  local currentStreak = numberOr(streak.length, previous.currentStreak)
  if currentStreak == nil then
    currentStreak = localCurrent
  else
    currentStreak = math.max(0, math.floor(currentStreak))
  end

  local bestStreak = numberOr(streak.maxLength, previous.bestStreak)
  if bestStreak == nil then
    bestStreak = localBest
  else
    bestStreak = math.max(0, math.floor(bestStreak))
  end

  local lastResult = extractLastResult(parts.lastResult, previous)
  local lastResultTimestamp = Activity.toSeconds(streak.lastResultTimestamp)
    or lastResult.lastResultTimestamp
    or Activity.toSeconds(parts.lastResultTimestamp)
    or Activity.toSeconds(parts.lastTestAt)
    or lastTimestamp

  -- keep lastResultTimestamp consistent with the best-known result time
  if lastResult.lastResultTimestamp == nil then
    lastResult.lastResultTimestamp = lastResultTimestamp
  end

  local accountKey = parts.accountKey
  if accountKey == nil and type(previous.accountKey) == "string" then
    accountKey = previous.accountKey
  end

  return {
    rows = built.rows,
    details = built.details,
    columns = built.columns,
    thresholds = built.thresholds,
    windowTotal = built.windowTotal,
    firstDate = built.firstDate,
    lastDate = built.lastDate,
    coveredFirstDate = built.coveredFirstDate,
    coveredLastDate = built.coveredLastDate,
    today = today,
    todayDate = todayDate,
    activeDays = activeDays,
    recentAverage = recentAverage,
    currentStreak = currentStreak,
    bestStreak = bestStreak,
    lastWpm = lastResult.lastWpm,
    lastAcc = lastResult.lastAcc,
    lastMode = lastResult.lastMode,
    lastMode2 = lastResult.lastMode2,
    lastResultTimestamp = lastResultTimestamp,
    fetchedAt = parts.now or parts.fetchedAt or os.time(),
    -- Raw series and anchor: let the service do light refreshes and the panel
    -- rebuild year/rolling views without another API call.
    counts = counts,
    lastTimestamp = lastTimestamp,
    lastResult = {
      wpm = lastResult.lastWpm,
      acc = lastResult.lastAcc,
      mode = lastResult.lastMode,
      mode2 = lastResult.lastMode2,
      timestamp = lastResult.lastResultTimestamp,
    },
    accountKey = accountKey,
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
