-- lib/timeutil.luau — clock handling: date keys, midnight rollover, clock jumps.
--
-- All public functions are pure and testable without a host. The module needs
-- one host clock source injected as `clockMs()` (default os.time()*1000).
--
-- Design rules (spec §9, §17):
--   * history is keyed by local calendar date (YYYY-MM-DD), so a day boundary
--     is a *data* boundary; the session continues across midnight but its
--     duration is split across the two date buckets.
--   * wall-clock time can jump (NTP sync, suspend-with-wrong-rtc, manual
--     change). Any negative observed delta is treated as a clock jump: the
--     current session is ended and a new one starts, never fabricating
--     backwards durations.

local M = {}

local DATE_PATTERN = "(%d%d%d%d)-(%d%d)-(%d%d)"

local function days_from_civil(y, m, d)
  -- Howard Hinnant's days_from_civil algorithm (proleptic Gregorian).
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  return y + (m <= 2 and 1 or 0), m, d
end

-- dateKey(unixSeconds) -> "YYYY-MM-DD" in the machine's local calendar.
-- os.date() is local-time based, matching what a user considers "today".
function M.dateKey(unixSeconds)
  local t = os.date("*t", unixSeconds)
  return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

-- dateKeyOf(unixSeconds, offsetDays) -> same key shifted by whole days.
function M.dateKeyOf(unixSeconds, offsetDays)
  local t = os.date("*t", unixSeconds)
  local z = days_from_civil(t.year, t.month, t.day) + offsetDays
  local y, m, d = civil_from_days(z)
  return string.format("%04d-%02d-%02d", y, m, d)
end

-- todayKey(clockMs) -> key for "now".
function M.todayKey(clockMs)
  return M.dateKey(math.floor((clockMs or (os.time() * 1000)) / 1000))
end

-- isValidDateKey(s) -> true for "YYYY-MM-DD" strings with real calendar dates.
function M.isValidDateKey(s)
  if type(s) ~= "string" then
    return false
  end
  local y, m, d = s:match("^" .. DATE_PATTERN .. "$")
  if not y then
    return false
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 1 or m > 12 or d < 1 or d > 31 then
    return false
  end
  local cy, cm, cd = civil_from_days(days_from_civil(y, m, d))
  return cy == y and cm == m and cd == d
end

-- Returns true if dateKey a is earlier than dateKey b (both validated).
function M.isBefore(a, b)
  if not M.isValidDateKey(a) or not M.isValidDateKey(b) then
    return false
  end
  return a < b -- ISO-8601 keys sort lexicographically
end

-- dayDiff(keyA, keyB) -> whole days from A to B (B - A). Non-validated input
-- returns a conservative large number so retention treats it as ancient.
function M.dayDiff(keyA, keyB)
  if not M.isValidDateKey(keyA) or not M.isValidDateKey(keyB) then
    return 1000000
  end
  local ya, ma, da = keyA:match(DATE_PATTERN)
  local yb, mb, db = keyB:match(DATE_PATTERN)
  local za = days_from_civil(tonumber(ya), tonumber(ma), tonumber(da))
  local zb = days_from_civil(tonumber(yb), tonumber(mb), tonumber(db))
  return zb - za
end

-- classifyTick(prevMs, nowMs, maxGapMs) -> "normal" | "gap" | "clock_back"
--   * "normal": wall clock moved forward plausibly
--   * "gap":    forward jump larger than maxGapMs (suspend, SIGSTOP, VM pause)
--   * "clock_back": wall clock moved backwards (NTP correction, tz change)
function M.classifyTick(prevMs, nowMs, maxGapMs)
  local delta = nowMs - prevMs
  if delta < 0 then
    return "clock_back"
  elseif delta > (maxGapMs or 60000) then
    return "gap"
  end
  return "normal"
end

-- monotonicSafeNow(clockMs, lastSeenMs) -> nowMs guarded against clock jumps.
-- When the wall clock went backwards, we keep progressing from lastSeenMs so
-- durations never go negative; callers detect "clock_back" separately.
function M.monotonicSafeNow(clockMs, lastSeenMs)
  local now = clockMs or (os.time() * 1000)
  if lastSeenMs and now < lastSeenMs then
    return lastSeenMs
  end
  return now
end

return M
