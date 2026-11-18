--!nonstrict

local Time = {}

-- Compute local UTC offset once
local localNow = os.time(os.date("*t"))
local utcNow = os.time(os.date("!*t"))
local utcOffset = localNow - utcNow

function Time.parseIso8601(s)
  if type(s) ~= "string" or s == "" then
    return nil
  end
  local y, m, d, h, min, sec = string.match(s, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then
    return nil
  end
  local localTime = os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(min),
    sec = tonumber(sec),
  })
  if not localTime then
    return nil
  end
  return localTime + utcOffset
end

function Time.formatRelative(isoStr)
  local ts = Time.parseIso8601(isoStr)
  if not ts then
    return ""
  end
  local now = os.time()
  local diff = now - ts
  if diff < 0 then
    diff = 0
  end

  if diff < 60 then
    return "now"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h"
  elseif diff < 604800 then
    return math.floor(diff / 86400) .. "d"
  else
    return math.floor(diff / 604800) .. "w"
  end
end

function Time.getShellTimeFormat()
  if noctalia and type(noctalia.timeFormat) == "function" then
    local ok, fmt = pcall(noctalia.timeFormat)
    if ok and type(fmt) == "string" and fmt ~= "" then
      return fmt
    end
  end
  return "%H:%M"
end

function Time.formatClock(unixTimestamp)
  if not unixTimestamp then
    return ""
  end
  local val = tonumber(unixTimestamp) or 0
  if val <= 0 then
    return ""
  end

  -- Handle milliseconds vs seconds gracefully
  local secs = val
  if val > 100000000000 then
    secs = math.floor(val / 1000)
  else
    secs = math.floor(val)
  end

  local pattern = Time.getShellTimeFormat()

  -- Use Noctalia's native time formatter (handles 12h / 24h shell settings)
  if noctalia and type(noctalia.formatTime) == "function" then
    local ok, formatted = pcall(noctalia.formatTime, pattern, secs)
    if ok and type(formatted) == "string" and formatted ~= "" then
      return formatted
    end
  end

  -- Fallback: extract strftime format from Noctalia template "{:...}"
  local strftimePattern = pattern:match("{:(.-)}") or pattern
  local ok, fallback = pcall(os.date, strftimePattern, secs)
  if ok and type(fallback) == "string" and fallback ~= "" then
    return fallback
  end

  return os.date("%H:%M", secs)
end

return Time
