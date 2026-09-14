local status = noctalia.state.get("status") or "loading"
local notificationCount = noctalia.state.get("notifications_count") or 0

local function render()
  local mode = noctalia.getConfig("bar_display_mode") or "both"
  barWidget.setGlyph(mode == "count" and "" or "brand-github")
  if mode == "icon" then
    barWidget.setText("")
  elseif mode == "count" then
    barWidget.setText(tostring(notificationCount))
  else
    barWidget.setText(notificationCount > 0 and tostring(notificationCount) or "")
  end
  if status == "missing_gh" then
    barWidget.setTooltip(noctalia.tr("status.missing_gh"))
  elseif status == "auth_error" then
    barWidget.setTooltip(noctalia.tr("status.auth_error"))
  else
    barWidget.setTooltip(noctalia.trp("widget.tooltip", notificationCount, { count = notificationCount }))
  end
end

noctalia.state.watch("status", function(value)
  status = value or "loading"
  render()
end)

noctalia.state.watch("notifications_count", function(value)
  notificationCount = value or 0
  render()
end)

function onClick()
  noctalia.togglePanel("shangshui0302/github-kanban:kanban")
end

function onRightClick()
  noctalia.state.set("refresh_request", noctalia.nowMs())
end

function onConfigChanged()
  render()
end

render()
