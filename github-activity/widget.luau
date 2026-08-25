--!nonstrict

local Settings = require("./lib/settings.luau")

local data = noctalia.state.get("data")
local status = noctalia.state.get("status") or "loading"
local stale = noctalia.state.get("stale") == true
local tr = noctalia.tr

local function tooltip()
  if data ~= nil then
    local freshness = stale and tr("widget.cached") or tr("widget.up_to_date")
    local refreshSchedule = tr("status.refresh_schedule", {
      time = os.date("%H:%M", math.floor(data.fetchedAt)),
      interval = Settings.refreshIntervalMinutes(noctalia.getConfig("refresh_interval_minutes")),
    })
    return tr("widget.tooltip", {
      login = data.login,
      today = data.today,
      streak = data.currentStreak,
      freshness = freshness,
      refresh = refreshSchedule,
    })
  end

  if status == "missing_gh" then
    return tr("status.missing_gh")
  elseif status == "auth_error" then
    return tr("status.auth_error")
  elseif status == "request_error" or status == "invalid_response" then
    return tr("status.unavailable")
  end

  return tr("status.loading")
end

local function render()
  barWidget.setGlyph("brand-github")
  barWidget.setText(data ~= nil and tostring(data.today) or "—")
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
  noctalia.togglePanel("alexmnrs/github-activity:calendar")
end

function onRightClick()
  noctalia.state.set("refresh_request", noctalia.nowMs())
end

render()
