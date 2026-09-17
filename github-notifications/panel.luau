--!nonstrict

local Time = require("./lib/time.luau")
local Notifications = require("./lib/notifications.luau")

local items = noctalia.state.get("github_notifications:items") or {}
local unreadCount = noctalia.state.get("github_notifications:unread_count") or 0
local status = noctalia.state.get("github_notifications:status") or "loading"
local errorDetail = noctalia.state.get("github_notifications:error") or ""
local lastUpdated = noctalia.state.get("github_notifications:last_updated")
local stale = noctalia.state.get("github_notifications:stale") == true
local tr = noctalia.tr

local function getRadius(baseRadius)
  if noctalia.getSetting then
    local scale = noctalia.getSetting("shell.corner_radius_scale")
    if type(scale) == "number" then
      return math.floor(baseRadius * scale)
    end
  end
  return baseRadius
end

local function requestRefresh()
  noctalia.state.set("github_notifications:action", {
    type = "refresh",
    nonce = noctalia.nowMs(),
  })
end

local function markAsRead(item)
  if not item or not item.id or not Notifications.isValidThreadId(item.id) then
    return
  end

  -- Optimistic local update
  local updated = {}
  for _, it in ipairs(items) do
    if tostring(it.id) ~= tostring(item.id) then
      table.insert(updated, it)
    end
  end
  items = updated
  unreadCount = #updated

  -- Notify service
  noctalia.state.set("github_notifications:action", {
    type = "mark_read",
    id = item.id,
    nonce = noctalia.nowMs(),
  })

  -- Rerender immediately for crisp UX
  renderPanel()
end

local function openNotification(item)
  if not item or not item.url or item.url == "" then
    noctalia.notifyError(tr("panel.title"), tr("status.notification_link_missing"))
    return
  end

  if not Notifications.isValidGithubUrl(item.url) then
    noctalia.notifyError(tr("panel.title"), tr("status.invalid_notification_link"))
    return
  end

  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(tr("panel.title"), tr("status.missing_xdg_open"))
    return
  end

  -- Only dispatch mark-read after verifying link is valid and openable
  markAsRead(item)
  noctalia.runAsync({ "xdg-open", item.url })
end

local function markAllNotificationsRead()
  if #items == 0 then
    return
  end

  items = {}
  unreadCount = 0

  noctalia.state.set("github_notifications:action", {
    type = "mark_all_read",
    nonce = noctalia.nowMs(),
  })

  renderPanel()
end

local function renderHeader()
  local count = unreadCount or 0
  local subtitle = ""
  if status == "loading" then
    subtitle = tr("status.loading")
  elseif count == 0 then
    subtitle = tr("empty.subtitle")
  elseif count == 1 then
    subtitle = tr("panel.one_unread")
  else
    subtitle = tr("panel.multiple_unread", { count = count })
  end

  if lastUpdated and status ~= "loading" then
    local clock = Time.formatClock(math.floor(lastUpdated / 1000))
    subtitle = subtitle .. " · " .. tr("panel.updated_at", { time = clock })
  end
  if stale then
    subtitle = subtitle .. " (" .. tr("widget.cached") .. ")"
  end

  return ui.row({
    align = "center",
    justify = "space_between",
  }, {
    ui.column({ gap = 2 }, {
      ui.label({
        text = tr("panel.title"),
        fontSize = 15,
        fontWeight = "bold",
        color = "primary",
      }),
      ui.label({
        text = subtitle,
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph = "checks",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("action.mark_all_read"),
        enabled = count > 0 and status ~= "loading",
        onClick = function()
          markAllNotificationsRead()
        end,
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("action.refresh"),
        onClick = function()
          requestRefresh()
        end,
      }),
    }),
  })
end

local function renderNotificationCard(item)
  return ui.row({
    key = "card_" .. tostring(item.id),
    radius = getRadius(8),
    paddingV = 7,
    paddingH = 10,
    gap = 8,
    fill = "surface_variant/0.25",
    border = "outline/0.60",
    borderWidth = 1,
    align = "center",
  }, {
    -- Clickable notification body: opens link in browser and marks read
    ui.row({
      flexGrow = 1,
      gap = 8,
      align = "center",
      onClick = function()
        openNotification(item)
      end,
    }, {
      ui.column({
        width = 22,
        align = "center",
        justify = "center",
      }, {
        ui.glyph({
          name = item.icon or "bell",
          size = 16,
          color = item.iconColor or "on_surface_variant",
        }),
      }),
      ui.column({
        flexGrow = 1,
        gap = 1,
      }, {
        ui.label({
          text = item.title,
          maxLines = 2,
          fontSize = 12,
          fontWeight = "medium",
          color = "on_surface",
        }),
        ui.label({
          text = item.repo,
          fontSize = 10,
          color = "on_surface_variant",
          maxLines = 1,
        }),
        ui.row({
          gap = 5,
          align = "center",
        }, {
          ui.label({
            text = item.reasonLabel,
            fontSize = 9,
            fontWeight = "medium",
            color = item.isFailure and "error" or "primary",
          }),
          ui.label({
            text = "·",
            fontSize = 9,
            color = "on_surface_variant",
          }),
          ui.label({
            text = item.relativeTime,
            fontSize = 9,
            color = "on_surface_variant",
          }),
        }),
      }),
    }),
    -- Separate check button: marks as read only, does NOT open browser
    ui.button({
      glyph = "check",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("action.mark_read"),
      onClick = function()
        markAsRead(item)
      end,
    }),
  })
end

local function renderContent()
  if status == "missing_gh" then
    return ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 10,
      padding = 20,
    }, {
      ui.glyph({ name = "alert-triangle", size = 32, color = "error" }),
      ui.label({ text = tr("status.missing_gh_title"), fontSize = 13, fontWeight = "bold", color = "error" }),
      ui.label({ text = tr("status.missing_gh_detail"), fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
    })
  end

  if status == "auth_error" then
    return ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 10,
      padding = 20,
    }, {
      ui.glyph({ name = "lock", size = 32, color = "error" }),
      ui.label({ text = tr("status.auth_error_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = (errorDetail ~= "" and errorDetail or tr("status.auth_error_detail")), fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
      ui.button({
        text = tr("action.try_again"),
        variant = "primary",
        controlSize = "sm",
        onClick = function()
          requestRefresh()
        end,
      }),
    })
  end

  if status == "rate_limited" then
    return ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 10,
      padding = 20,
    }, {
      ui.glyph({ name = "hourglass", size = 32, color = "primary" }),
      ui.label({ text = tr("status.rate_limited_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = tr("status.rate_limited_detail"), fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
      ui.button({
        text = tr("action.try_again"),
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          requestRefresh()
        end,
      }),
    })
  end

  if status == "error" and (#items == 0) then
    return ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 10,
      padding = 20,
    }, {
      ui.glyph({ name = "alert-circle", size = 32, color = "error" }),
      ui.label({ text = tr("status.generic_error"), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = errorDetail ~= "" and errorDetail or tr("status.unavailable"), fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
      ui.button({
        text = tr("action.try_again"),
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          requestRefresh()
        end,
      }),
    })
  end

  if status == "loading" and (#items == 0) then
    return ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 10,
      paddingV = 20,
    }, {
      ui.glyph({ name = "loader-2", size = 28, color = "primary" }),
      ui.label({ text = tr("status.loading"), fontSize = 12, color = "on_surface_variant" }),
    })
  end

  if #items == 0 then
    return ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 8,
      paddingV = 20,
    }, {
      ui.column({
        width = 54,
        height = 54,
        radius = getRadius(27),
        fill = "primary/0.12",
        align = "center",
        justify = "center",
      }, {
        ui.glyph({ name = "circle-check", size = 28, color = "primary" }),
      }),
      ui.label({
        text = tr("empty.title"),
        fontSize = 14,
        fontWeight = "semibold",
        color = "on_surface",
      }),
      ui.label({
        text = tr("empty.subtitle"),
        fontSize = 11,
        color = "on_surface_variant",
      }),
    })
  end

  local cards = {}
  for _, it in ipairs(items) do
    table.insert(cards, renderNotificationCard(it))
  end

  return ui.scroll({
    flexGrow = 1,
    gap = 6,
    paddingV = 2,
    align = "stretch",
  }, cards)
end

function renderPanel()
  local content = renderContent()

  panel.render(ui.column({
    flexGrow = 1,
    gap = 10,
    align = "stretch",
  }, {
    renderHeader(),
    ui.separator({ thickness = 1, color = "outline/0.2", spacing = 6 }),
    content,
  }))
end

noctalia.state.watch("github_notifications:items", function(val)
  items = val or {}
  renderPanel()
end)

noctalia.state.watch("github_notifications:unread_count", function(val)
  unreadCount = val or 0
  renderPanel()
end)

noctalia.state.watch("github_notifications:status", function(val)
  status = val or "ready"
  renderPanel()
end)

noctalia.state.watch("github_notifications:error", function(val)
  errorDetail = val or ""
  renderPanel()
end)

noctalia.state.watch("github_notifications:last_updated", function(val)
  lastUpdated = val
  renderPanel()
end)

noctalia.state.watch("github_notifications:stale", function(val)
  stale = val == true
  renderPanel()
end)

function onOpen(_context)
  -- Refresh relative timestamps on open
  for _, item in ipairs(items) do
    item.relativeTime = Time.formatRelative(item.updatedAt)
  end
  renderPanel()
end

function onClose()
  -- Clean up if needed
end
