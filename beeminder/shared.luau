--!nonstrict
local shared = {}

shared.PLUGIN_ID = "giodamelio/beeminder"
shared.SITE = "https://www.beeminder.com"

local ICON_BY_COLORKEY = {
  red = "icons/bee-red.svg",
  orange = "icons/bee-orange.svg",
  blue = "icons/bee-blue.svg",
  green = "icons/bee-green.svg",
  dkgreen = "icons/bee-green.svg",
  gray = "icons/bee-gray.svg",
}
shared.ICON_LOADING = "icons/bee-loading.svg"
shared.ICON_ERROR = "icons/bee-error.svg"

function shared.iconFor(colorkey)
  return ICON_BY_COLORKEY[colorkey] or ICON_BY_COLORKEY.gray
end

function shared.report()
  return noctalia.state.get("report")
end

function shared.requestRefresh()
  noctalia.state.set("refresh_request", noctalia.nowMs())
end

function shared.openUrl(url)
  noctalia.runAsync({ "xdg-open", url })
end

function shared.profileUrl(username)
  return `{shared.SITE}/{username}`
end

function shared.goalUrl(username, slug)
  return `{shared.SITE}/{username}/{slug}`
end

function shared.isInactive(goal)
  return goal.frozen or goal.won
end

function shared.isDue(goal)
  return goal.safebuf <= 0
end

-- Goals that drive the bee's color and the bar text: active and not ignored, most urgent first.
-- The service already sorts by urgencykey, so order is preserved.
function shared.trackedGoals(report)
  local ignored = {}
  for _, slug in ipairs(noctalia.getConfig("ignored_goals") or {}) do
    ignored[noctalia.string.trim(slug)] = true
  end
  local tracked = {}
  for _, goal in ipairs(report.goals or {}) do
    if not shared.isInactive(goal) and not ignored[goal.slug] then
      table.insert(tracked, goal)
    end
  end
  return tracked
end

function shared.formatCountdown(losedate)
  local remaining = losedate - os.time()
  if remaining <= 0 then
    return noctalia.tr("countdown.now")
  end
  local days = remaining // 86400
  local hours = (remaining % 86400) // 3600
  local minutes = (remaining % 3600) // 60
  if days > 0 then
    return noctalia.tr("countdown.days_hours", { days = days, hours = hours })
  elseif hours > 0 then
    return noctalia.tr("countdown.hours_minutes", { hours = hours, minutes = minutes })
  end
  return noctalia.tr("countdown.minutes", { minutes = math.max(minutes, 1) })
end

function shared.formatMoney(amount)
  if amount == math.floor(amount) then
    return string.format("$%d", amount)
  end
  return string.format("$%.2f", amount)
end

function shared.formatAge(unixSeconds)
  local age = os.time() - unixSeconds
  if age < 60 then
    return noctalia.tr("age.just_now")
  end
  return noctalia.tr("age.minutes_ago", { minutes = age // 60 })
end

function shared.errorMessage(report)
  if report.status == "no_token" then
    return noctalia.tr("error.no_token")
  elseif report.status == "unauthorized" then
    return noctalia.tr("error.unauthorized")
  end
  return noctalia.tr("error.failed", { detail = report.detail or "" })
end

return shared
