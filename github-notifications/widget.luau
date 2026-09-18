--!nonstrict

local Time = require("./lib/time.luau")

local unreadCount = noctalia.state.get("github_notifications:unread_count")
local status = noctalia.state.get("github_notifications:status") or "loading"
local lastUpdated = noctalia.state.get("github_notifications:last_updated")
local stale = noctalia.state.get("github_notifications:stale") == true
local tr = noctalia.tr

local function getDisplayMode()
  return tostring(noctalia.getConfig("display_mode") or "icon_and_count")
end

local function getHideWhenZero()
  return noctalia.getConfig("hide_when_zero") == true
end

local function formatTooltip()
  if status == "missing_gh" then
    return tr("status.missing_gh")
  elseif status == "auth_error" then
    return tr("status.auth_error")
  elseif status == "rate_limited" then
    return tr("status.rate_limited")
  elseif status == "error" then
    return tr("status.unavailable")
  end

  local count = unreadCount or 0
  local timeStr = lastUpdated and (" · " .. Time.formatClock(math.floor(lastUpdated / 1000))) or ""
  local staleNote = stale and (" (" .. tr("widget.cached") .. ")") or ""

  if count == 0 then
    return tr("widget.tooltip_empty") .. timeStr .. staleNote
  else
    return tr("widget.tooltip_unread", { count = count }) .. timeStr .. staleNote
  end
end

local function formatText()
  local mode = getDisplayMode()
  if mode == "icon_only" then
    return ""
  end

  if unreadCount == nil then
    return status == "loading" and "…" or "—"
  end

  local count = tonumber(unreadCount) or 0
  if count == 0 and getHideWhenZero() then
    return ""
  end

  return tostring(count)
end

local function render()
  local count = tonumber(unreadCount) or 0
  barWidget.setGlyph("brand-github")
  if count > 0 then
    barWidget.setGlyphColor("primary")
  else
    barWidget.setGlyphColor("default")
  end
  barWidget.setText(formatText())
  barWidget.setTooltip(formatTooltip())
  barWidget.setVisible(true)
end

noctalia.state.watch("github_notifications:unread_count", function(val)
  unreadCount = val
  render()
end)

noctalia.state.watch("github_notifications:status", function(val)
  status = val or "ready"
  render()
end)

noctalia.state.watch("github_notifications:last_updated", function(val)
  lastUpdated = val
  render()
end)

noctalia.state.watch("github_notifications:stale", function(val)
  stale = val == true
  render()
end)

function onClick()
  noctalia.togglePanel("hy4ri/github-notifications:panel")
end

function onRightClick()
  noctalia.state.set("github_notifications:action", {
    type = "refresh",
    nonce = noctalia.nowMs(),
  })
end

render()
