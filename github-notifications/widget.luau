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

local WIDGET_TYPE = "hy4ri/github-notifications:inbox"
local BAR_FONT_SIZE = 14 -- Noctalia's default bar text size, before any font_scale

-- The widget's own `font_scale` is the one the user edits in the widget settings. The host
-- multiplies every bar label by it, so the bar number divides it back out and the value is
-- handed to the panel instead. getConfig cannot see it (not a plugin-declared setting).
local function widgetFontScale()
  if not noctalia.getSetting then
    return 1
  end
  local widgets = noctalia.getSetting("widget")
  if type(widgets) ~= "table" then
    return 1
  end
  for _, def in pairs(widgets) do
    if type(def) == "table" and def.type == WIDGET_TYPE and type(def.font_scale) == "number" then
      return math.max(0.2, math.min(2.5, def.font_scale))
    end
  end
  return 1
end

local function render()
  local count = tonumber(unreadCount) or 0
  local scale = widgetFontScale()
  noctalia.state.set("github_notifications:panel_font_scale", scale)

  local children = {
    ui.glyph({ name = "brand-github", color = count > 0 and "primary" or "on_surface" }),
  }
  local text = formatText()
  if text ~= "" then
    table.insert(children, ui.label({
      text = text,
      fontSize = BAR_FONT_SIZE / scale,
      color = "on_surface",
    }))
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 5, align = "center" }, children))
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

function onConfigChanged()
  render()
end

render()
