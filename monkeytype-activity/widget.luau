--!nonstrict

local Settings = require("./lib/settings.luau")

local data = noctalia.state.get("data")
local status = noctalia.state.get("status") or "loading"
local stale = noctalia.state.get("stale") == true
local tr = noctalia.tr
local displayMode = Settings.widgetDisplayMode(noctalia.getConfig("display_mode"))
local displayMetric = Settings.widgetDisplayMetric(noctalia.getConfig("display_metric"))

local function tooltip()
  if data ~= nil then
    local freshness = stale and tr("widget.cached") or tr("widget.up_to_date")
    local refreshSchedule = tr("status.refresh_schedule", {
      time = noctalia.formatTime(noctalia.timeFormat(), math.floor(data.fetchedAt)),
      interval = Settings.refreshIntervalMinutes(noctalia.getConfig("refresh_interval_minutes")),
    })
    return tr("widget.tooltip", {
      today = data.today,
      streak = data.currentStreak,
      total = data.windowTotal,
      wpm = data.lastWpm or "—",
      accuracy = data.lastAcc or "—",
      freshness = freshness,
      refresh = refreshSchedule,
    })
  end

  if status == "no_key" then
    return tr("status.no_key")
  elseif status == "invalid_key" then
    return tr("status.invalid_key")
  elseif status == "inactive_key" then
    return tr("status.inactive_key")
  elseif status == "auth_error" then
    return tr("status.auth_error")
  elseif status == "rate_limited" then
    return tr("status.rate_limited")
  elseif status == "no_activity" then
    return tr("status.no_activity")
  elseif status == "request_error" or status == "invalid_response" then
    return tr("status.unavailable")
  end

  return tr("status.loading")
end

local function displayText()
  if displayMode == "icon_only" then
    return ""
  end

  if data == nil then
    return "—"
  elseif displayMetric == "current_streak" then
    return tostring(data.currentStreak)
  elseif displayMetric == "year_total" then
    return tostring(data.windowTotal)
  elseif displayMetric == "last_wpm" then
    return data.lastWpm ~= nil and tostring(data.lastWpm) or "—"
  end

  return tostring(data.today)
end

local function render()
  barWidget.setGlyph("keyboard")
  barWidget.setText(displayText())
  barWidget.setTooltip(tooltip())
  barWidget.setVisible(true)
end

noctalia.state.watch("data", function(value)
  data = value
  render()
end)

noctalia.state.watch("status", function(value)
  status = value or "loading"
  render()
end)

noctalia.state.watch("stale", function(value)
  stale = value == true
  render()
end)

function onClick()
  -- Without an Ape Key the panel has nothing to show, so the click goes
  -- straight to the setting that fixes it.
  if status == "no_key" then
    noctalia.openSettings()
    return
  end

  noctalia.togglePanel("faminec/monkeytype-activity:calendar")
end

function onRightClick()
  noctalia.state.set("refresh_request", noctalia.nowMs())
end

render()
