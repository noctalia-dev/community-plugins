--!nonstrict
-- Duration parsing and formatting for Timed.
--
-- Units: y (365 days), d, h, m, s. Units may appear in any order and may
-- repeat. A bare number after a unit takes the next smaller unit, so 1h5 is
-- 1 hour 5 minutes and 1s4h is 1 second 4 hours. A lone number means minutes.

local M = {}

local UNIT_SECONDS = { y = 31536000, d = 86400, h = 3600, m = 60, s = 1 }
local NEXT_UNIT = { y = "d", d = "h", h = "m", m = "s" }
local MAX_SECONDS = 100 * UNIT_SECONDS.y

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.parse(text)
  local input = tostring(text or ""):lower():gsub("%s+", "")
  if input == "" then
    return nil
  end

  local total = 0
  local pos = 1
  local lastUnit = nil

  while pos <= #input do
    local rest = input:sub(pos)
    local digits, unit, length = rest:match("^(%d+)([ydhms]?)()")
    if not digits then
      return nil
    end

    local value = tonumber(digits)
    if not value then
      return nil
    end

    if unit == "" then
      if lastUnit then
        unit = NEXT_UNIT[lastUnit]
      else
        unit = "m"
      end
      if not unit then
        return nil
      end
    end

    total = total + value * UNIT_SECONDS[unit]
    lastUnit = unit
    pos = pos + length - 1
  end

  if total <= 0 or total > MAX_SECONDS then
    return nil
  end

  return total
end

-- Splits launcher or IPC text into a duration and an optional message.
-- The whole text wins when it parses as a duration, so spaced formats still
-- work. Otherwise the first word is the duration and the rest is the message.
function M.split(text)
  local input = trim(tostring(text or ""))
  if input == "" then
    return nil
  end

  local seconds = M.parse(input)
  if seconds then
    return seconds
  end

  local token, rest = input:match("^(%S+)%s*(.*)$")
  if not token then
    return nil
  end
  seconds = M.parse(token)
  if not seconds then
    return nil
  end

  local message = trim(rest)
  if message == "" then
    return seconds
  end
  return seconds, message
end

function M.clock(seconds)
  local total = math.max(0, math.floor(seconds))
  local d = total // 86400
  local h = (total % 86400) // 3600
  local m = (total % 3600) // 60
  local s = total % 60
  if d > 0 then
    return string.format("%dd %d:%02d:%02d", d, h, m, s)
  end
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

function M.human(seconds)
  local total = math.max(0, math.floor(seconds))
  local y = total // UNIT_SECONDS.y
  total = total % UNIT_SECONDS.y
  local d = total // 86400
  local h = (total % 86400) // 3600
  local m = (total % 3600) // 60
  local s = total % 60
  local parts = {}
  if y > 0 then
    table.insert(parts, y .. "y")
  end
  if d > 0 then
    table.insert(parts, d .. "d")
  end
  if h > 0 then
    table.insert(parts, h .. "h")
  end
  if m > 0 then
    table.insert(parts, m .. "m")
  end
  if s > 0 then
    table.insert(parts, s .. "s")
  end
  if #parts == 0 then
    return "0s"
  end
  return table.concat(parts, " ")
end

return M
