--!nonstrict
-- Shared settings helpers for GitHub Contributions.
-- Adapted from alexmnrs/github-activity (MIT), which this plugin is based on.

local Settings = {}

local DEFAULT_REFRESH_INTERVAL_MINUTES = 30
local refreshIntervalMinutes = {
  ["15"] = 15,
  ["30"] = 30,
  ["60"] = 60,
}

function Settings.refreshIntervalMinutes(value)
  return type(value) == "string" and refreshIntervalMinutes[value]
    or DEFAULT_REFRESH_INTERVAL_MINUTES
end

function Settings.refreshIntervalMs(value)
  return Settings.refreshIntervalMinutes(value) * 60 * 1000
end

function Settings.cellSize(value)
  local size = tonumber(value) or 10
  return math.clamp(math.floor(size), 6, 24)
end

-- How many stacked blocks the year is split into: 1 (one long strip, the
-- default), 2, 3, or 4. Anything else (including "off") falls back to 1.
function Settings.wrapBlocks(value)
  local blocks = tonumber(value)
  if blocks == 2 or blocks == 3 or blocks == 4 then
    return blocks
  end
  return 1
end

-- The year the calendar covers: "last12" (trailing 12 months, the default)
-- or a four-digit calendar year. Anything else falls back to "last12".
function Settings.selectedYear(value)
  if value == "last12" then
    return "last12"
  end
  local year = tonumber(value)
  local currentYear = tonumber(os.date("%Y")) or 2026
  if year ~= nil and year >= 2008 and year <= currentYear then
    return tostring(math.floor(year))
  end
  return "last12"
end

return Settings
