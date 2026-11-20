--!nonstrict

-- Normalisation of the values read back from the manifest, so a stale or
-- hand-edited config can never produce an unusable interval or metric.

local Settings = {}

local DEFAULT_REFRESH_INTERVAL_MINUTES = 30
local DEFAULT_WIDGET_DISPLAY_MODE = "icon_and_value"
local DEFAULT_WIDGET_DISPLAY_METRIC = "today"

local refreshIntervalMinutes = {
  ["10"] = 10,
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
  last_wpm = true,
  year_total = true,
}

-- Ape Keys are pasted from MonkeyType, so surrounding whitespace and stray
-- newlines are the usual corruption.
function Settings.apeKey(value)
  if type(value) ~= "string" then
    return ""
  end

  return (string.gsub(value, "^%s+", ""):gsub("%s+$", ""))
end

function Settings.hasApeKey(value)
  return #Settings.apeKey(value) > 0
end

-- Optional display name, used only for the profile button and the panel
-- caption; the Ape Key is what identifies the account.
function Settings.username(value)
  local name = Settings.apeKey(value)
  if name == "" then
    return nil
  end
  return name
end

-- The setting is a select, so Noctalia hands over the option value as a string;
-- a hand-edited settings file can also hold a plain number.
function Settings.refreshIntervalMinutes(value)
  if type(value) == "string" and refreshIntervalMinutes[value] then
    return refreshIntervalMinutes[value]
  end
  if type(value) == "number" then
    for minutes in pairs(refreshIntervalMinutes) do
      if math.floor(value) == refreshIntervalMinutes[minutes] then
        return refreshIntervalMinutes[minutes]
      end
    end
  end
  return DEFAULT_REFRESH_INTERVAL_MINUTES
end

function Settings.refreshIntervalMs(value)
  return Settings.refreshIntervalMinutes(value) * 60 * 1000
end

function Settings.widgetDisplayMode(value)
  if type(value) == "string" and widgetDisplayModes[value] then
    return value
  end
  return DEFAULT_WIDGET_DISPLAY_MODE
end

function Settings.widgetDisplayMetric(value)
  if type(value) == "string" and widgetDisplayMetrics[value] then
    return value
  end
  return DEFAULT_WIDGET_DISPLAY_METRIC
end

function Settings.panelElementVisible(value)
  if type(value) == "boolean" then
    return value
  end
  return true
end

function Settings.calendarExpanded(showToday, showCurrentStreak, showBestStreak)
  return not showToday and not showCurrentStreak and not showBestStreak
end

return Settings
