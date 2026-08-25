--!nonstrict

local Settings = {}

local DEFAULT_REFRESH_INTERVAL_MINUTES = 30
local DEFAULT_WIDGET_DISPLAY_MODE = "icon_and_value"
local DEFAULT_WIDGET_DISPLAY_METRIC = "today"
local refreshIntervalMinutes = {
  ["15"] = 15,
  ["30"] = 30,
  ["60"] = 60,
}
local widgetDisplayModes = {
  icon_only = true,
  icon_and_value = true,
}
local widgetDisplayMetrics = {
  today = true,
  current_streak = true,
  year_total = true,
}

function Settings.refreshIntervalMinutes(value)
  return type(value) == "string" and refreshIntervalMinutes[value]
    or DEFAULT_REFRESH_INTERVAL_MINUTES
end

function Settings.refreshIntervalMs(value)
  return Settings.refreshIntervalMinutes(value) * 60 * 1000
end

function Settings.widgetDisplayMode(value)
  return type(value) == "string" and widgetDisplayModes[value] and value
    or DEFAULT_WIDGET_DISPLAY_MODE
end

function Settings.widgetDisplayMetric(value)
  return type(value) == "string" and widgetDisplayMetrics[value] and value
    or DEFAULT_WIDGET_DISPLAY_METRIC
end

return Settings
