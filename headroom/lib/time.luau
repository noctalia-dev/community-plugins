--!nonstrict
-- Time helpers: ISO-8601 parsing and compact human durations.
--
-- Pure functions apart from the translation lookups, so every provider and
-- surface agrees on how "3h 12m" or "2d 4h" is written. Timestamps are whole
-- Unix seconds (UTC) throughout the plugin.

local M = {}

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil). Avoids os.time, which interprets tables in local time.
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

-- "2026-10-03T20:19:59.911287+00:00" / "...Z" / "... 20:19:59" -> Unix seconds.
-- Returns nil for anything that is not a full date-time.
function M.parseIso8601(value: any): number?
  if type(value) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s, rest =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
  if y == nil then
    return nil
  end
  local offset = 0
  if rest ~= "" and rest ~= "Z" and rest ~= "z" then
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if sign == nil then
      return nil
    end
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (if sign == "-" then -1 else 1)
  end
  local days = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d))
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s) - offset
end

-- Accepts Unix seconds (number or numeric string) or an ISO-8601 string.
function M.toUnix(value: any): number?
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    local n = tonumber(value)
    if n ~= nil then
      return n
    end
    return M.parseIso8601(value)
  end
  return nil
end

-- Renew a little early: a token that dies in flight turns a refresh into a
-- spurious "sign-in rejected".
M.EXPIRY_MARGIN = 60

-- True when an expiry (Unix seconds, epoch milliseconds or ISO-8601) has
-- passed or is about to. Unknown expiry counts as valid: let the vendor decide.
function M.isExpired(expiry: any, now: number): boolean
  local at = M.toUnix(expiry)
  if at == nil then
    return false
  end
  if at > 1e11 then
    at /= 1000 -- epoch milliseconds
  end
  return at - M.EXPIRY_MARGIN <= now
end

-- Compact duration: "<1m", "45m", "3h 12m", "3h", "2d 4h", "6d".
function M.duration(seconds: number): string
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then
    return noctalia.tr("duration.lt_minute")
  end
  local minutes = seconds // 60
  if minutes < 60 then
    return noctalia.tr("duration.m", { m = minutes })
  end
  local hours = minutes // 60
  if hours < 24 then
    local m = minutes % 60
    if m == 0 then
      return noctalia.tr("duration.h", { h = hours })
    end
    return noctalia.tr("duration.hm", { h = hours, m = m })
  end
  local days = hours // 24
  local h = hours % 24
  if h == 0 then
    return noctalia.tr("duration.d", { d = days })
  end
  return noctalia.tr("duration.dh", { d = days, h = h })
end

-- "just now" / "4m ago" / "2h ago" / "3d ago".
function M.ago(seconds: number): string
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then
    return noctalia.tr("ago.now")
  end
  if seconds < 3600 then
    return noctalia.tr("ago.m", { m = seconds // 60 })
  end
  if seconds < 86400 then
    return noctalia.tr("ago.h", { h = seconds // 3600 })
  end
  return noctalia.tr("ago.d", { d = seconds // 86400 })
end

return M
