--!nonstrict

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

return Settings
