--!nonstrict
-- Calendar days as "YYYY-MM-DD" strings, the keys of ledger.json, marks.json
-- and the report's history. Pure functions; times are epoch milliseconds.

local M = {}

local DAY_MS = 86400000
M.DAY_MS = DAY_MS

-- Days since 1970-01-01 for a proleptic Gregorian date, and back (Howard
-- Hinnant's algorithms). Avoids os.time, which reads tables as local time.
local function daysFromCivil(y: number, m: number, d: number): number
  if m <= 2 then
    y -= 1
  end
  local era = (if y >= 0 then y else y - 399) // 400
  local yoe = y - era * 400
  local mp = if m > 2 then m - 3 else m + 9
  local doy = (153 * mp + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

local function civilFromDays(z: number): (number, number, number)
  z += 719468
  local era = (if z >= 0 then z else z - 146096) // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = if mp < 10 then mp + 3 else mp - 9
  return yoe + era * 400 + (if m <= 2 then 1 else 0), m, d
end

-- Day number (days since the epoch) of a "YYYY-MM-DD" string, or nil.
function M.number(day: string): number?
  local y, m, d = string.match(day, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y == nil then
    return nil
  end
  return daysFromCivil(tonumber(y), tonumber(m), tonumber(d))
end

function M.fromNumber(n: number): string
  local y, m, d = civilFromDays(n)
  return string.format("%04d-%02d-%02d", y, m, d)
end

-- UTC day of an epoch-milliseconds instant, shifted by `offsetMs` for a
-- local day boundary.
function M.of(ms: number, offsetMs: number?): string
  return M.fromNumber((ms + (offsetMs or 0)) // DAY_MS)
end

-- Start of `day` in epoch milliseconds (UTC midnight minus `offsetMs`).
function M.startMs(day: string, offsetMs: number?): number
  return (M.number(day) :: number) * DAY_MS - (offsetMs or 0)
end

function M.add(day: string, n: number): string
  return M.fromNumber((M.number(day) :: number) + n)
end

-- Local UTC offset in milliseconds at `ms` (DST-aware), from os.date.
function M.localOffsetMs(ms: number): number
  local seconds = ms // 1000
  local loc = os.date("*t", seconds) :: any
  local utc = os.date("!*t", seconds) :: any
  local localDays = daysFromCivil(loc.year, loc.month, loc.day)
  local utcDays = daysFromCivil(utc.year, utc.month, utc.day)
  return ((localDays - utcDays) * 86400 + (loc.hour - utc.hour) * 3600 + (loc.min - utc.min) * 60) * 1000
end

-- "+02:00" style offset for Binance's klines `timeZone` parameter.
function M.offsetLabel(offsetMs: number): string
  local minutes = math.abs(offsetMs) // 60000
  return string.format("%s%d:%02d", if offsetMs < 0 then "-" else "+", minutes // 60, minutes % 60)
end

-- Weekday of a day number, 0 = Sunday … 6 = Saturday.
function M.weekday(n: number): number
  return (n + 4) % 7
end

return M
