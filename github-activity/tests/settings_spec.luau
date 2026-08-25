--!nonstrict

local Settings = require("../github-activity/lib/settings")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
  end
end

equal(Settings.refreshIntervalMs("15"), 15 * 60 * 1000, "15 minute refresh interval")
equal(Settings.refreshIntervalMs("30"), 30 * 60 * 1000, "30 minute refresh interval")
equal(Settings.refreshIntervalMs("60"), 60 * 60 * 1000, "60 minute refresh interval")
equal(Settings.refreshIntervalMinutes("15"), 15, "15 minute display interval")
equal(Settings.refreshIntervalMinutes("30"), 30, "30 minute display interval")
equal(Settings.refreshIntervalMinutes("60"), 60, "60 minute display interval")

equal(Settings.refreshIntervalMs(nil), 30 * 60 * 1000, "missing refresh interval defaults to 30 minutes")
equal(Settings.refreshIntervalMs("5"), 30 * 60 * 1000, "unsupported refresh interval defaults to 30 minutes")
equal(Settings.refreshIntervalMs("abc"), 30 * 60 * 1000, "malformed refresh interval defaults to 30 minutes")
equal(Settings.refreshIntervalMs(15), 30 * 60 * 1000, "numeric refresh interval defaults to 30 minutes")
equal(Settings.refreshIntervalMs({}), 30 * 60 * 1000, "table refresh interval defaults to 30 minutes")
equal(Settings.refreshIntervalMinutes(nil), 30, "missing display interval defaults to 30 minutes")

equal(Settings.widgetDisplayMode("icon_only"), "icon_only", "icon-only widget display mode")
equal(Settings.widgetDisplayMode("icon_and_value"), "icon_and_value", "icon-and-value widget display mode")
equal(Settings.widgetDisplayMode(nil), "icon_and_value", "missing widget display mode uses compatible default")
equal(Settings.widgetDisplayMode("value_only"), "icon_and_value", "unsupported widget display mode uses compatible default")
equal(Settings.widgetDisplayMode(1), "icon_and_value", "numeric widget display mode uses compatible default")
equal(Settings.widgetDisplayMode({}), "icon_and_value", "table widget display mode uses compatible default")

equal(Settings.widgetDisplayMetric("today"), "today", "today widget metric")
equal(Settings.widgetDisplayMetric("current_streak"), "current_streak", "current-streak widget metric")
equal(Settings.widgetDisplayMetric("year_total"), "year_total", "year-total widget metric")
equal(Settings.widgetDisplayMetric(nil), "today", "missing widget metric uses compatible default")
equal(Settings.widgetDisplayMetric("best_streak"), "today", "unsupported widget metric uses compatible default")
equal(Settings.widgetDisplayMetric(1), "today", "numeric widget metric uses compatible default")
equal(Settings.widgetDisplayMetric({}), "today", "table widget metric uses compatible default")

print("GitHub Activity settings tests passed")
