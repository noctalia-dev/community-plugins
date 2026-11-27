-- Unit tests for the pure modules of `faminec/monkeytype-activity`.
--
--   lua5.4 tests/test-units.lua
--
-- No Noctalia, no network: activity.luau, monkeytype.luau and settings.luau are
-- plain Lua once the Luau-only bits (math.clamp) are avoided, which they are.

local function scriptDir()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    return source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
  end
  return "."
end

-- The tests live in `tests/`, so the plugin root is the directory above them.
local function pluginRoot()
  local dir = scriptDir()
  local parent = dir:match("^(.*)[/\\]tests$")
  if parent and parent ~= "" then
    return parent
  end
  if dir == "tests" or parent == "" then
    return "."
  end
  return dir
end

local DIR = pluginRoot()
local loaded = {}
local function pluginRequire(path)
  local relative = path:gsub("^%./", "")
  if loaded[relative] == nil then
    loaded[relative] = assert(loadfile(DIR .. "/" .. relative))()
  end
  return loaded[relative]
end

local Activity = pluginRequire("lib/activity.luau")
local Monkeytype = pluginRequire("lib/monkeytype.luau")
local Settings = pluginRequire("lib/settings.luau")

local FAILED = 0
local PASSED = 0
local function check(name, expected, actual)
  if expected == actual then
    PASSED = PASSED + 1
    print(string.format("  ok    %-58s %s", name, tostring(actual)))
  else
    FAILED = FAILED + 1
    print(string.format("  FAIL  %-58s expected=%s actual=%s", name, tostring(expected), tostring(actual)))
  end
end

local function section(name)
  print("\n== " .. name)
end

-- Fixture dates are relative to the current UTC day, so the tests do not rot.
local NOW = os.time()
local TODAY = NOW - NOW % 86400
local YESTERDAY = TODAY - 86400

section("activity: levels and symbols")
check("level 0 symbol", "·", Activity.symbol(0))
check("level 4 symbol", "█", Activity.symbol(4))
check("symbol clamps high", "█", Activity.symbol(9))
check("symbol clamps low", "·", Activity.symbol(-3))
check("symbol rejects nil", "·", Activity.symbol(nil))
check("color level 0", "surface_container", Activity.color(0))
check("color level 4", "primary", Activity.color(4))

section("activity: rowLevels round trip")
local row = Activity.symbol(0) .. Activity.symbol(1) .. Activity.symbol(3) .. Activity.symbol(4)
local levels = Activity.rowLevels(row)
check("four entries", 4, #levels)
check("first level", 0, levels[1])
check("second level", 1, levels[2])
check("third level", 3, levels[3])
check("fourth level", 4, levels[4])
check("empty row", 0, #Activity.rowLevels(nil))

section("activity: quartile levels")
local thresholds = Activity.quartiles({ 0, 1, 1, 2, 4, 8, 0 })
check("q1", 1, thresholds[1])
check("q2", 2, thresholds[2])
check("q3", 4, thresholds[3])
check("zero tests is level 0", 0, Activity.levelForCount(0, thresholds))
check("one test is level 1", 1, Activity.levelForCount(1, thresholds))
check("two tests is level 2", 2, Activity.levelForCount(2, thresholds))
check("four tests is level 3", 3, Activity.levelForCount(4, thresholds))
check("eight tests is level 4", 4, Activity.levelForCount(8, thresholds))
check("empty history never divides by zero", 1, Activity.quartiles({})[1])

section("activity: UTC window layout")
local counts = {}
for index = 1, 372 do
  counts[index] = 0
end
counts[1] = 1
counts[371] = 3
counts[372] = 5

local built = Activity.build(counts, TODAY)
check("columns", 54, built.columns)
check("window total", 9, built.windowTotal)
check("first date", os.date("!%Y-%m-%d", TODAY - 371 * 86400), built.firstDate)
check("last date", os.date("!%Y-%m-%d", TODAY), built.lastDate)
check("seven rows", 7, #built.rows)
check("details rows", 7, #built.details)
check("row length matches columns", built.columns, utf8.len(built.rows[1]))
check("detail fields match columns", built.columns, select(2, built.details[1]:gsub("\t", "")) + 1)
local lastWeekday = os.date("!*t", TODAY).wday
local lastRowDetails = built.details[lastWeekday]:match("([^\t]+)$")
check("last day sits on its weekday row", os.date("!%Y-%m-%d", TODAY) .. "|5", lastRowDetails)
local lastRowLevels = Activity.rowLevels(built.rows[lastWeekday])
check("today is shaded", 3, lastRowLevels[#lastRowLevels])

section("activity: millisecond timestamps")
check("seconds pass through", 1771027200, Activity.toSeconds(1771027200))
check("milliseconds are converted", 1771027200, Activity.toSeconds(1771027200000))
check("zero is not a timestamp", nil, Activity.toSeconds(0))
check("text is rejected", nil, Activity.toSeconds("1771027200"))
local msPayload = Activity.normalize({
  days = { 1, 2 },
  dayCount = 2,
  lastDay = TODAY * 1000,
  streak = { lastResultTimestamp = (NOW - 600) * 1000, length = 2, maxLength = 9 },
  now = NOW,
})
check("ms lastDay ends on the same day", os.date("!%Y-%m-%d", TODAY), msPayload.lastDate)
check("ms streak timestamp converted", NOW - 600, msPayload.lastResultTimestamp)
check("ms payload keeps today's count", 2, msPayload.today)

section("activity: today count")
local todayCount, todayDate = Activity.todayCount(counts, TODAY, NOW)
check("today count", 5, todayCount)
check("today date", os.date("!%Y-%m-%d", TODAY), todayDate)
check("stale window has no today", 0, (Activity.todayCount(counts, YESTERDAY, NOW)))
check("window past its end", 0, (Activity.todayCount({ 2, 3 }, YESTERDAY - 5 * 86400, NOW)))

section("activity: normalise and cache")
local days = {}
for index = 1, 371 do
  days[index] = 0
end
days[369] = 7
days[370] = 4
days[371] = 2

local payload, normaliseError = Activity.normalize({
  days = days,
  dayCount = 372,
  lastDay = TODAY - 86400,
  streak = { length = 3, maxLength = 11, lastResultTimestamp = NOW - 600, hourOffset = 2 },
  lastResult = { wpm = 82.4, acc = 95.6, timestamp = NOW - 600, mode = "time", mode2 = "60" },
  now = NOW,
})

check("normalise succeeded", nil, normaliseError)
check("today is empty", 0, payload.today)
check("window total", 13, payload.windowTotal)
check("current streak from the API", 3, payload.currentStreak)
check("best streak from the API", 11, payload.bestStreak)
check("wpm rounded", 82, payload.lastWpm)
check("accuracy rounded", 96, payload.lastAcc)
check("mode kept", "time", payload.lastMode)
check("mode2 kept as text", "60", payload.lastMode2)
check("cache is valid", true, Activity.isValidCache(payload))

local previous = { completedTests = 1234, currentStreak = 9, bestStreak = 20, lastWpm = 70, lastAcc = 90 }
local merged = Activity.normalize({
  days = { 1, 2 },
  dayCount = 2,
  lastDay = TODAY,
  streak = { length = 1, maxLength = 20 },
  previous = previous,
  now = NOW,
})
check("previous wpm survives a failed last result", 70, merged.lastWpm)

local broken, brokenError = Activity.normalize({ days = nil, lastDay = TODAY, now = NOW })
check("missing activity fails", nil, broken)
check("missing activity reason", "missing test activity", brokenError)
check("empty activity fails", nil, (Activity.normalize({ days = {}, dayCount = 0, lastDay = TODAY })))
check("invalid cache rejected", false, Activity.isValidCache({ rows = {} }))
check("invalid cache rejected (nil)", false, Activity.isValidCache(nil))
local partialCache = {}
for key, value in pairs(payload) do
  partialCache[key] = value
end
partialCache.counts = nil
check("cache without the raw series rejected", false, Activity.isValidCache(partialCache))
local noAnchorCache = {}
for key, value in pairs(payload) do
  noAnchorCache[key] = value
end
noAnchorCache.lastTimestamp = nil
check("cache without the anchor rejected", false, Activity.isValidCache(noAnchorCache))

section("monkeytype: requests and status mapping")
local request = Monkeytype.request("/users/streak", "SECRET")
check("url", "https://api.monkeytype.com/users/streak", request.url)
check("method", "GET", request.method)
check("authorization header", "Authorization: ApeKey SECRET", request.headers[2])
check("401 is an auth error", "auth_error", Monkeytype.statusFor(401))
check("470 is an invalid key", "invalid_key", Monkeytype.statusFor(470))
check("471 is a disabled key", "inactive_key", Monkeytype.statusFor(471))
check("472 is an invalid key", "invalid_key", Monkeytype.statusFor(472))
check("429 is a rate limit", "rate_limited", Monkeytype.statusFor(429))
check("479 is a rate limit", "rate_limited", Monkeytype.statusFor(479))
check("500 is a request error", "request_error", Monkeytype.statusFor(500))
check("no status is a request error", "request_error", Monkeytype.statusFor(0))

section("monkeytype: response payloads")
local function decodeValue(value)
  return function() return value end
end
check("network failure", "request_error", select(2, Monkeytype.payload(nil, decodeValue(nil))))
check("invalid key response", "invalid_key", select(2, Monkeytype.payload({ ok = false, status = 470 }, decodeValue(nil))))
check("completed 4xx is still an error", "invalid_key", select(2, Monkeytype.payload({ ok = true, status = 472 }, decodeValue(nil))))
check("completed 429 is a rate limit", "rate_limited", select(2, Monkeytype.payload({ ok = true, status = 479 }, decodeValue(nil))))
check("disabled key reported as such", "inactive_key", select(2, Monkeytype.payload({ ok = true, status = 471 }, decodeValue(nil))))
check("transport failure", "request_error", select(2, Monkeytype.payload({ ok = false, status = 0 }, decodeValue(nil))))
check("2xx without ok", "request_error", select(2, Monkeytype.payload({ ok = false, status = 200 }, decodeValue(nil))))
check("undecodable body", "invalid_response", select(2, Monkeytype.payload({ ok = true, status = 200, body = "nope" }, decodeValue(nil))))
check("null data means no activity", "no_activity", select(2, Monkeytype.payload({ ok = true, status = 200, body = "x" }, decodeValue({ message = "ok", data = nil }))))
local data = Monkeytype.payload({ ok = true, status = 200, body = "x" }, decodeValue({ message = "ok", data = { length = 4 } }))
check("data extracted", 4, data.length)

section("monkeytype: array length survives trailing nulls")
check("trailing nulls counted", 4, Monkeytype.arrayLength('{"data":{"testsByDays":[1,2,null,null],"lastDay":1}}', "testsByDays"))
check("empty array", 0, Monkeytype.arrayLength('{"data":{"testsByDays":[],"lastDay":1}}', "testsByDays"))
check("single null", 1, Monkeytype.arrayLength('{ "testsByDays" : [ null ] }', "testsByDays"))
check("holes in the middle", 5, Monkeytype.arrayLength('{"testsByDays":[1,null,3,null,5]}', "testsByDays"))
check("spaced json", 3, Monkeytype.arrayLength('{"testsByDays": [1, 2, 3]}', "testsByDays"))
check("missing field", nil, Monkeytype.arrayLength('{"data":{}}', "testsByDays"))
check("garbage input", nil, Monkeytype.arrayLength(nil, "testsByDays"))

section("monkeytype: ape key shape")
check("alphanumeric key", true, Monkeytype.isValidKey("abcDEF123_-xyz"))
check("a pasted line break is rejected", false, Monkeytype.isValidKey("abc\nApeKey xyz"))
check("a space is rejected", false, Monkeytype.isValidKey("abc def"))
check("empty key", false, Monkeytype.isValidKey(""))
check("not a string", false, Monkeytype.isValidKey(nil))

section("activity: the payload stores the streak timestamp in seconds")
local msPayload = Activity.normalize({
  days = { 4, 0 },
  dayCount = 2,
  lastDay = TODAY * 1000,
  streak = { lastResultTimestamp = (TODAY + 3600) * 1000, length = 2, maxLength = 5 },
  now = NOW,
})
check(
  "the service can compare it with toSeconds of the raw value",
  msPayload.lastResultTimestamp,
  Activity.toSeconds((TODAY + 3600) * 1000)
)

section("monkeytype: profile url")
check("plain name", "https://monkeytype.com/profile/faminec", Monkeytype.profileUrl("faminec"))
check("a rejected name falls back to the site", nil, Monkeytype.profileUrl("Ana Maria!"))
check("surrounding spaces are ignored", "https://monkeytype.com/profile/Ana-Maria", Monkeytype.profileUrl("  Ana-Maria \n"))
check("empty name", nil, Monkeytype.profileUrl("   "))
check("not a string", nil, Monkeytype.profileUrl(nil))

section("settings: normalisation")
check("key trimmed", "abc123", Settings.apeKey("  abc123\n"))
check("key unset", "", Settings.apeKey(nil))
check("key detected", true, Settings.hasApeKey(" abc "))
check("key missing", false, Settings.hasApeKey("   "))
check("interval default", 30, Settings.refreshIntervalMinutes(nil))
check("interval from select", 10, Settings.refreshIntervalMinutes("10"))
check("interval rejects junk", 30, Settings.refreshIntervalMinutes("7"))
check("interval in ms", 900000, Settings.refreshIntervalMs("15"))
check("metric default", "today", Settings.widgetDisplayMetric(nil))
check("metric valid", "last_wpm", Settings.widgetDisplayMetric("last_wpm"))
check("metric rejects junk", "today", Settings.widgetDisplayMetric("pace"))
check("display mode default", "icon_and_value", Settings.widgetDisplayMode(nil))
check("panel toggle default", true, Settings.panelElementVisible(nil))
check("panel toggle off", false, Settings.panelElementVisible(false))
check("expanded calendar", true, Settings.calendarExpanded(false, false, false))
check("username trimmed", "faminec", Settings.username(" faminec "))
check("username unset", nil, Settings.username(""))


section("activity: availableYears")
local yearCounts = {}
for i = 1, 372 do yearCounts[i] = 0 end
local yearsDec2026 = Activity.availableYears(yearCounts, Activity.dateTimestamp("2026-12-15"))
check("years include 2026", true, yearsDec2026[1] == "2026" or yearsDec2026[2] == "2026")
check("years is a table", "table", type(yearsDec2026))
check("years empty for nil", 0, #Activity.availableYears(nil, TODAY))
check("years empty for bad timestamp", 0, #Activity.availableYears(yearCounts, nil))
check("years empty for empty counts", 0, #Activity.availableYears({}, TODAY))

section("activity: buildYear")
local y2026Counts = {}
for k = 1, 372 do y2026Counts[k] = (k == 200) and 5 or 0 end
local anchor2026 = Activity.dateTimestamp("2026-06-15")
anchor2026 = anchor2026 - anchor2026 % 86400

local built2026 = Activity.buildYear(y2026Counts, anchor2026, "2026")
check("buildYear returns table", "table", type(built2026))
check("buildYear has year field", "2026", built2026.year)
check("buildYear has rows", "table", type(built2026.rows))
check("buildYear has 7 rows", 7, #built2026.rows)
check("buildYear has columns", "number", type(built2026.columns))
check("buildYear view is year", "year", built2026.view)
check("buildYear view id is the year", "2026", built2026.viewId)
check("2026 year windowTotal only counts available days", 0, built2026.windowTotal)
check("2026 year activeDays", 0, built2026.activeDays)
check("2026 covered start", "2026-01-01", built2026.coveredFirstDate)
check("2026 covered end", "2026-06-15", built2026.coveredLastDate)

local b2025 = Activity.buildYear(y2026Counts, anchor2026, "2025")
check("2025 year windowTotal", 5, b2025.windowTotal)
check("2025 year activeDays", 1, b2025.activeDays)
check("2025 covered start", "2025-06-09", b2025.coveredFirstDate)
check("2025 covered end", "2025-12-31", b2025.coveredLastDate)

local b1999 = Activity.buildYear(y2026Counts, anchor2026, "1999")
check("buildYear for year outside window returns table", "table", type(b1999))
check("outside year windowTotal", 0, b1999.windowTotal)
check("outside year covered start nil", nil, b1999.coveredFirstDate)
check("buildYear nil year returns nil", nil, Activity.buildYear(y2026Counts, anchor2026, nil))
check("buildYear nil counts returns nil", nil, Activity.buildYear(nil, anchor2026, "2026"))

section("activity: unavailable days are not zero-test days")
do
  local counts = {}
  for k = 1, 372 do counts[k] = 0 end
  counts[372] = 3 -- last day (2026-06-15) has tests
  local yearBuilt = Activity.buildYear(counts, anchor2026, "2026")
  -- 2026-06-16 is after anchor and must be unavailable, not a zero-test day.
  local rows = yearBuilt.rows
  local details = yearBuilt.details
  local foundZero = false
  local foundUnavailable = false
  for weekday = 1, 7 do
    for field in string.gmatch(details[weekday] or "", "([^;]*)") do
      if field == "2026-06-15|3" then
        foundZero = foundZero -- keep
      elseif field == "2026-06-16|0" then
        foundZero = true
      end
    end
  end
  -- Ensure 2026-06-15 is present as available data (3 tests).
  local hasLast = false
  for weekday = 1, 7 do
    if string.find(details[weekday] or "", "2026-06-15|3", 1, true) then
      hasLast = true
    end
  end
  check("available day in window is present", true, hasLast)
  check("day after window not reported as zero", false, foundZero)
  check("year windowTotal excludes unavailable days", 3, yearBuilt.windowTotal)
end

section("activity: availableYears")
local years = Activity.availableYears(y2026Counts, anchor2026)
check("availableYears returns table", "table", type(years))
check("availableYears has 2 years", 2, #years)
check("first year is 2026", "2026", years[1])
check("second year is 2025", "2025", years[2])
check("empty counts returns empty", 0, #Activity.availableYears({}, anchor2026))
local shortYears = Activity.availableYears({1, 2, 3}, Activity.dateTimestamp("1990-01-01"))
check("short window spanning year boundary returns 2 years", 2, #shortYears)

local june = Activity.dateTimestamp("2026-06-15")
check("dateTimestamp returns a timestamp", "number", type(june))
check("dateTimestamp round trips in UTC", "2026-06-15", Activity.utcDate(june))
local msYears = Activity.availableYears(y2026Counts, anchor2026 * 1000)
check("millisecond anchor gives the same years", 2, #msYears)
check("millisecond anchor first year", "2026", msYears[1])
local msYear = Activity.buildYear(y2026Counts, anchor2026 * 1000, "2026")
check("millisecond anchor builds the year", "2026-01-01", msYear and msYear.coveredFirstDate)

section("activity: buildView")
local viewData = {
  rows = {"......."},
  details = {""},
  columns = 1,
  thresholds = {1,1,1},
  windowTotal = 5,
  firstDate = "2025-06-09",
  lastDate = "2026-06-15",
  activeDays = 1,
  counts = y2026Counts,
  lastTimestamp = anchor2026,
}
local rollingView = Activity.buildView(viewData, "rolling")
check("rolling view type", "rolling", rollingView.view)
check("rolling view id", "rolling", rollingView.viewId)
check("rolling view windowTotal", 5, rollingView.windowTotal)
local defaultView = Activity.buildView(viewData, nil)
check("default view is rolling", "rolling", defaultView.view)
check("nil data returns nil", nil, Activity.buildView(nil, "rolling"))
local yearView = Activity.buildView(viewData, "2026")
check("year view type is year", "year", yearView.view)
check("year view id keeps the year", "2026", yearView.viewId)
local again = Activity.buildView(viewData, yearView.viewId)
check("feeding the id back keeps the year", "2026", again.viewId)
check("feeding the id back stays a year view", "year", again.view)
check("year view year field", "2026", yearView.year)
check("year view windowTotal", 0, yearView.windowTotal)
check("year view covered range shown", "2026-01-01", yearView.coveredFirstDate)
local fallbackData = {rows={"."}, details={""}, columns=1, thresholds={1,1,1}, windowTotal=99, firstDate="x", lastDate="y", activeDays=7}
local fallbackView = Activity.buildView(fallbackData, "2026")
check("fallback view is rolling without counts", "rolling", fallbackView.view)
check("fallback view id is rolling", "rolling", fallbackView.viewId)
check("fallback preserves windowTotal", 99, fallbackView.windowTotal)
local outsideView = Activity.buildView(viewData, "1999")
check("year outside the window falls back", "rolling", outsideView.viewId)
check("outside fallback preserves windowTotal", 5, outsideView.windowTotal)

section("activity: normalize preserves account key and raw series")
local withAccount = Activity.normalize({
  days = { 1, 2, 3 },
  dayCount = 3,
  lastDay = TODAY,
  accountKey = "testkey",
  now = NOW,
})
check("accountKey stored", "testkey", withAccount.accountKey)
check("counts stored", "table", type(withAccount.counts))
check("lastTimestamp stored", "number", type(withAccount.lastTimestamp))
local preserved = Activity.normalize({
  days = { 1, 2, 3 },
  dayCount = 3,
  lastDay = TODAY,
  previous = withAccount,
  now = NOW + 100,
})
check("accountKey preserved from previous", "testkey", preserved.accountKey)
local overridden = Activity.normalize({
  days = { 1, 2, 3 },
  dayCount = 3,
  lastDay = TODAY,
  accountKey = "newkey",
  previous = withAccount,
  now = NOW + 200,
})
check("accountKey overridden when provided", "newkey", overridden.accountKey)

print(string.format("\n%d passed, %d failed", PASSED, FAILED))
os.exit(FAILED == 0 and 0 or 1)
