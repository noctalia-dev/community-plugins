--!nonstrict

local M = {}

local UNITS = { "", "K", "M", "G", "T" }

-- Roll over before rounding would produce "1000K".
local function scale(bytesPerSecond: number): (string, string)
  local value, unit = math.max(bytesPerSecond, 0), 1
  while value >= 999.5 and unit < #UNITS do
    value /= 1000
    unit += 1
  end
  local text = if unit > 1 and value < 9.95 then string.format("%.1f", value) else tostring(math.round(value))
  return text, UNITS[unit]
end

function M.compact(bytesPerSecond: number): string
  local value, unit = scale(bytesPerSecond)
  return value .. unit
end

function M.full(bytesPerSecond: number): string
  local value, unit = scale(bytesPerSecond)
  return `{value} {unit}B/s`
end

return M
