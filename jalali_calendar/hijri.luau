--!nonstrict
-- Lunar Hijri (Qamari) dates as Iran actually uses them.
--
-- Iran fixes each month's start by local sighting, so no algorithm reproduces
-- the printed Iranian calendar. The bundled table (roozbehp/qamari) lists the
-- observed start of every month it covers, and that is authoritative.
--
-- Iran publishes only about a year ahead, so the table necessarily stops. Past
-- that point this module *continues the real sequence* with tabular month
-- lengths anchored to the last observed start, rather than restarting from a
-- computed epoch -- a prediction that stays within a day instead of drifting.
-- The same extrapolation runs backwards for dates before the table.
--
-- isExact() and lookup().exact report whether a date's month start was
-- observed or extrapolated, in either direction, so a caller can avoid
-- presenting a prediction as fact. The bundled UI does not currently surface
-- the distinction; this is a guarantee of the module's API.

-- Noctalia's require needs the ".luau" extension; the standalone luau CLI the
-- tests run under rejects it. Trying both lets one source file load in each,
-- which is what keeps the pure core testable outside the shell.
local function req(path: string)
  local ok, module = pcall(require, path .. ".luau")
  if ok then
    return module
  end
  return require(path)
end

local data = req("./occasions")

local M = {}

-- Flat ascending list of month starts: starts[i] = { jdn, hy, hm }.
-- Built once per VM at require time.
local starts = {}
local exactCount = 0

do
  local years = {}
  for hy in data.hijriMonths do
    table.insert(years, hy)
  end
  table.sort(years)
  for _, hy in years do
    for hm, jdn in data.hijriMonths[hy] do
      table.insert(starts, { jdn, hy, hm })
    end
  end
  table.sort(starts, function(a, b)
    return a[1] < b[1]
  end)
  exactCount = #starts
end

-- (year, month) -> position in `starts`, so month lookups are O(1). Without
-- this, monthLength scanned all 574 entries for every cell in the grid, which
-- blew the host's per-callback CPU budget.
local indexByMonth = {}

local function reindex()
  table.clear(indexByMonth)
  for i = 1, #starts do
    local entry = starts[i]
    indexByMonth[entry[2] * 12 + entry[3]] = i
  end
end

reindex()

-- Both ends of the observed table, captured once before anything can extend
-- it. `starts` is mutated in place -- extendTo() appends and extendBefore()
-- prepends -- so reading either bound from it later would move the edge of
-- "observed" to wherever the last extrapolation reached.
local EXACT_MIN_JDN = if exactCount > 0 then starts[1][1] else 0
local EXACT_MAX_JDN = if exactCount > 0 then starts[exactCount][1] else 0
local INTERPOLATED = data.hijriInterpolated or {}

-- Tabular civil lengths, used only to extend past the observed data.
local function tabularLength(hy: number, hm: number): number
  if hm == 12 then
    -- Leap years in the 30-year cycle get a 30-day twelfth month.
    return if (11 * hy + 14) % 30 < 11 then 30 else 29
  end
  return if hm % 2 == 1 then 30 else 29
end

-- Extends `starts` far enough forward to bracket jdn. Memoised in the array
-- itself, so browsing forward a year costs a handful of appends once.
local function extendTo(jdn: number)
  while #starts > 0 and starts[#starts][1] <= jdn do
    local last = starts[#starts]
    local hy, hm = last[2], last[3]
    local nextJdn = last[1] + tabularLength(hy, hm)
    if hm == 12 then
      hy += 1
      hm = 1
    else
      hm += 1
    end
    table.insert(starts, { nextJdn, hy, hm })
    indexByMonth[hy * 12 + hm] = #starts
  end
end

-- Extends backwards for dates before the table begins. The prefix is built in
-- one go and spliced once: inserting at index 1 in a loop would be quadratic.
local function extendBefore(jdn: number)
  if #starts == 0 or starts[1][1] <= jdn then
    return
  end
  local prefix = {}
  local hy, hm, edge = starts[1][2], starts[1][3], starts[1][1]
  while edge > jdn do
    if hm == 1 then
      hy -= 1
      hm = 12
    else
      hm -= 1
    end
    edge -= tabularLength(hy, hm)
    table.insert(prefix, 1, { edge, hy, hm })
  end
  for i = #prefix, 1, -1 do
    table.insert(starts, 1, prefix[i])
  end
  reindex()
end

-- Index of the last month start at or before jdn.
local function findIndex(jdn: number): number?
  if #starts == 0 then
    return nil
  end
  if jdn < starts[1][1] then
    extendBefore(jdn)
  end
  if jdn >= starts[#starts][1] then
    extendTo(jdn)
  end

  local lo, hi = 1, #starts
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if starts[mid][1] <= jdn then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo
end

function M.fromJDN(jdn: number): (number, number, number)
  local i = findIndex(jdn)
  if i == nil then
    return 0, 0, 0
  end
  local entry = starts[i]
  return entry[2], entry[3], jdn - entry[1] + 1
end

-- True only when this date's month start came from observation: inside the
-- table's range, and not one of the months bridged across a gap in the source.
function M.isExact(jdn: number): boolean
  if exactCount == 0 or jdn > EXACT_MAX_JDN or jdn < EXACT_MIN_JDN then
    return false
  end
  local hy, hm = M.fromJDN(jdn)
  return INTERPOLATED[`{hy}:{hm}`] == nil
end

function M.exactMaxJDN(): number
  return EXACT_MAX_JDN
end

-- Length of a Hijri month: observed where the table covers it, tabular beyond.
function M.monthLength(hy: number, hm: number): number
  local i = indexByMonth[hy * 12 + hm]
  if i == nil then
    return tabularLength(hy, hm)
  end
  if i >= #starts then
    extendTo(starts[i][1] + 40)
  end
  if i < #starts then
    return starts[i + 1][1] - starts[i][1]
  end
  return tabularLength(hy, hm)
end

-- Everything about one day in a single pass: the calendar grid needs the date,
-- its exactness and the month length for all 31 cells, and doing three
-- separate lookups per cell is what made this hot.
function M.lookup(jdn: number)
  local i = findIndex(jdn)
  if i == nil then
    return { year = 0, month = 0, day = 0, exact = false, monthLength = 30 }
  end
  local entry = starts[i]
  local hy, hm = entry[2], entry[3]
  if i >= #starts then
    extendTo(entry[1] + 40)
  end
  local length = if i < #starts then starts[i + 1][1] - entry[1] else tabularLength(hy, hm)
  local exact = jdn <= EXACT_MAX_JDN
    and exactCount > 0
    and jdn >= EXACT_MIN_JDN
    and INTERPOLATED[`{hy}:{hm}`] == nil
  return {
    year = hy,
    month = hm,
    day = jdn - entry[1] + 1,
    exact = exact,
    monthLength = length,
  }
end

return M
