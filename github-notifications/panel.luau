--!nonstrict

local Time = require("./lib/time.luau")
local Notifications = require("./lib/notifications.luau")

-- Marking read is deferred by this long so "Undo" is real: GitHub has no
-- "mark unread" call, so the request only goes out once the window closes.
local UNDO_WINDOW_MS = 5000

local items = noctalia.state.get("github_notifications:items") or {}
local status = noctalia.state.get("github_notifications:status") or "loading"
local errorDetail = noctalia.state.get("github_notifications:error") or ""
local lastUpdated = noctalia.state.get("github_notifications:last_updated")
local stale = noctalia.state.get("github_notifications:stale") == true
local tr = noctalia.tr

local filter = "all"
local hoveredId = nil
local collapsed = {}
local pending = {} -- stack of { kind = "one" | "all", verb = "read" | "done", items = {...}, deadline = ms }
local shownItems = {}

local function getRadius(baseRadius)
  if noctalia.getSetting then
    local scale = noctalia.getSetting("shell.corner_radius_scale")
    if type(scale) == "number" then
      return math.floor(baseRadius * scale)
    end
  end
  return baseRadius
end

-- The host already multiplies every panel fontSize by the shell's ui_scale. The widget's own
-- font_scale never reaches panels, so widget.luau publishes it into plugin state (and cancels
-- it on the bar number); applying it here makes it a panel-only scale.
local widgetFontScale = 1

local function resolveWidgetFontScale()
  local value = tonumber(noctalia.state.get("github_notifications:panel_font_scale")) or 1
  widgetFontScale = math.max(0.2, math.min(2.5, value))
end

local function font(size)
  return math.floor(size * widgetFontScale + 0.5)
end

local function cfgBool(key, default)
  local value = noctalia.getConfig(key)
  if value == nil then
    return default
  end
  return value == true
end

local DENSITY = {
  compact = { padV = 4, padH = 8, gap = 6, list = 3 },
  standard = { padV = 7, padH = 10, gap = 8, list = 6 },
  comfortable = { padV = 10, padH = 12, gap = 12, list = 9 },
}

local function density()
  return DENSITY[tostring(noctalia.getConfig("appearance_density") or "standard")] or DENSITY.standard
end

local function requestRefresh()
  noctalia.state.set("github_notifications:action", {
    type = "refresh",
    nonce = noctalia.nowMs(),
  })
end

-- Items hidden because they are inside an undo window.
local function visibleItems()
  local hidden = {}
  for _, entry in ipairs(pending) do
    for _, it in ipairs(entry.items) do
      hidden[tostring(it.id)] = true
    end
  end
  local out = {}
  for _, it in ipairs(items) do
    if not hidden[tostring(it.id)] then
      table.insert(out, it)
    end
  end
  return out
end

local function syncFrameTick()
  if panel.setNeedsFrameTick then
    panel.setNeedsFrameTick(#pending > 0)
  end
end

local function dispatch(entry)
  if entry.kind == "all" then
    noctalia.state.set("github_notifications:action", {
      type = "mark_all_read",
      nonce = noctalia.nowMs(),
    })
  else
    for _, it in ipairs(entry.items) do
      noctalia.state.set("github_notifications:action", {
        type = entry.verb == "done" and "mark_done" or "mark_read",
        id = it.id,
        nonce = noctalia.nowMs(),
      })
    end
  end

  local gone = {}
  for _, it in ipairs(entry.items) do
    gone[tostring(it.id)] = true
  end
  local kept = {}
  for _, it in ipairs(items) do
    if not gone[tostring(it.id)] then
      table.insert(kept, it)
    end
  end
  items = kept
end

-- Sends every expired entry (or all of them) to the service. Returns true if any went out.
local function flush(everything)
  local now = noctalia.nowMs()
  local keep, due = {}, {}
  for _, entry in ipairs(pending) do
    if everything or entry.deadline <= now then
      table.insert(due, entry)
    else
      table.insert(keep, entry)
    end
  end
  if #due == 0 then
    return false
  end
  pending = keep
  for _, entry in ipairs(due) do
    dispatch(entry)
  end
  syncFrameTick()
  return true
end

local function queueRead(kind, list, verb)
  if #list == 0 then
    return
  end
  table.insert(pending, { kind = kind, verb = verb or "read", items = list, deadline = noctalia.nowMs() + UNDO_WINDOW_MS })
  syncFrameTick()
  renderPanel()
end

local function undoLast()
  if #pending == 0 then
    return
  end
  table.remove(pending)
  syncFrameTick()
  renderPanel()
end

local function markAsRead(item, verb)
  if not item or not item.id or not Notifications.isValidThreadId(item.id) then
    return
  end
  queueRead("one", { item }, verb)
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

  -- Only touch read state after verifying the link is valid and openable
  if cfgBool("mark_read_on_open", true) then
    markAsRead(item, "read")
  end
  noctalia.runAsync({ "xdg-open", item.url })
end

local function markAllNotificationsRead()
  -- "Mark all" is global on GitHub, so it only runs on the unfiltered list.
  if filter ~= "all" then
    return
  end
  local list = visibleItems()
  if #list == 0 then
    return
  end
  queueRead("all", list)
end

local FILTERS = { "mentions", "reviews", "ci" }

local function categoryOf(item)
  local reason = item.reason
  if reason == "mention" or reason == "team_mention" then
    return "mentions"
  end
  if reason == "review_requested" or reason == "approval_requested" then
    return "reviews"
  end
  if reason == "ci_activity" or reason == "security_alert" or item.type == "CheckSuite" or item.type == "WorkflowRun" then
    return "ci"
  end
  return nil
end

local function categoryCounts(list)
  local counts = { mentions = 0, reviews = 0, ci = 0 }
  for _, it in ipairs(list) do
    local cat = categoryOf(it)
    if cat then
      counts[cat] = counts[cat] + 1
    end
  end
  return counts
end

local function applyFilter(list)
  if filter == "all" then
    return list
  end
  local out = {}
  for _, it in ipairs(list) do
    if categoryOf(it) == filter then
      table.insert(out, it)
    end
  end
  return out
end

local function renderHeader()
  local count = #shownItems
  local subtitle = ""
  if status == "loading" and count == 0 then
    subtitle = tr("status.loading")
  elseif count == 0 then
    subtitle = tr("empty.subtitle")
  elseif count == 1 then
    subtitle = tr("panel.one_unread")
  else
    subtitle = tr("panel.multiple_unread", { count = count })
  end
  if stale then
    subtitle = subtitle .. " · " .. tr("widget.cached")
  end

  local loading = status == "loading"
  local refreshTooltip = tr("action.refresh")
  if lastUpdated and not loading then
    local clock = Time.formatClock(math.floor(lastUpdated / 1000))
    refreshTooltip = tr("action.refresh_updated", { time = clock })
  end

  local markAllTooltip = tr("action.mark_all_read")
  if filter ~= "all" then
    markAllTooltip = tr("action.mark_all_filtered")
  end

  return ui.row({
    align = "center",
    justify = "space_between",
  }, {
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({
        text = tr("panel.title"),
        fontSize = font(15),
        fontWeight = "bold",
        color = "primary",
        maxLines = 1,
      }),
      ui.label({
        text = subtitle,
        fontSize = font(11),
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }),
    ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph = "checks",
        variant = "ghost",
        controlSize = "sm",
        tooltip = markAllTooltip,
        enabled = count > 0 and not loading and filter == "all",
        onClick = function()
          markAllNotificationsRead()
        end,
      }),
      ui.button({
        glyph = loading and "loader-2" or "refresh",
        variant = "ghost",
        controlSize = "sm",
        tooltip = refreshTooltip,
        enabled = not loading,
        onClick = function()
          requestRefresh()
        end,
      }),
    }),
  })
end

local function renderFilters(counts)
  local any = false
  for _, key in ipairs(FILTERS) do
    if counts[key] > 0 then
      any = true
    end
  end
  if not any then
    return nil
  end

  local chips = {}
  local function chip(key, label)
    local active = filter == key
    table.insert(chips, ui.button({
      key = "filter_" .. key,
      text = label,
      variant = active and "primary" or "ghost",
      selected = active,
      controlSize = "sm",
      fontSize = font(11),
      onClick = function()
        filter = key
        renderPanel()
      end,
    }))
  end
  chip("all", tr("filter.all") .. " " .. #shownItems)
  for _, key in ipairs(FILTERS) do
    if counts[key] > 0 then
      chip(key, tr("filter." .. key) .. " " .. counts[key])
    end
  end
  return ui.row({ gap = 4, align = "center" }, chips)
end

local function renderNotificationCard(item, d)
  local hovered = hoveredId == item.id
  return ui.row({
    key = "card_" .. tostring(item.id),
    radius = getRadius(8),
    paddingV = d.padV,
    paddingH = d.padH,
    gap = d.gap,
    fill = hovered and "surface_variant/0.55" or "surface_variant/0.25",
    border = hovered and "primary/0.45" or "outline/0.60",
    borderWidth = 1,
    align = "center",
    onHover = function(value)
      local on = value == true or value == "true"
      local before = hoveredId
      if on then
        hoveredId = item.id
      elseif hoveredId == item.id then
        hoveredId = nil
      end
      if hoveredId ~= before then
        renderPanel()
      end
    end,
  }, {
    -- Clickable notification body: opens link in browser (and marks read if enabled)
    ui.row({
      flexGrow = 1,
      gap = d.gap,
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
        gap = 2,
      }, {
        ui.label({
          text = item.title,
          maxLines = 2,
          fontSize = font(12),
          fontWeight = "medium",
          color = "on_surface",
        }),
        ui.label({
          text = item.repo,
          fontSize = font(11),
          color = "on_surface_variant",
          maxLines = 1,
        }),
        ui.row({
          gap = 6,
          align = "center",
        }, {
          ui.row({
            paddingH = 6,
            paddingV = 1,
            radius = getRadius(6),
            fill = item.isFailure and "error/0.15" or "primary/0.12",
            align = "center",
          }, {
            ui.label({
              text = item.reasonLabel,
              fontSize = font(10),
              fontWeight = "medium",
              color = item.isFailure and "error" or "primary",
              maxLines = 1,
            }),
          }),
          ui.label({
            text = item.relativeTime,
            fontSize = font(10),
            color = "on_surface_variant",
            maxLines = 1,
          }),
        }),
      }),
    }),
    -- Separate check button: marks as done on GitHub, does NOT open browser
    ui.button({
      glyph = "check",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("action.mark_done"),
      onClick = function()
        markAsRead(item, "done")
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
      ui.label({ text = tr("status.missing_gh_title"), fontSize = font(13), fontWeight = "bold", color = "error" }),
      ui.label({ text = tr("status.missing_gh_detail"), fontSize = font(11), color = "on_surface_variant", textAlign = "center" }),
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
      ui.label({ text = tr("status.auth_error_title"), fontSize = font(13), fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = (errorDetail ~= "" and errorDetail or tr("status.auth_error_detail")), fontSize = font(11), color = "on_surface_variant", textAlign = "center" }),
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
      ui.label({ text = tr("status.rate_limited_title"), fontSize = font(13), fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = tr("status.rate_limited_detail"), fontSize = font(11), color = "on_surface_variant", textAlign = "center" }),
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

  if status == "error" and (#shownItems == 0) then
    return ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 10,
      padding = 20,
    }, {
      ui.glyph({ name = "alert-circle", size = 32, color = "error" }),
      ui.label({ text = tr("status.generic_error"), fontSize = font(13), fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = errorDetail ~= "" and errorDetail or tr("status.unavailable"), fontSize = font(11), color = "on_surface_variant", textAlign = "center" }),
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

  if status == "loading" and (#shownItems == 0) then
    return ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 10,
      paddingV = 20,
    }, {
      ui.glyph({ name = "loader-2", size = 28, color = "primary" }),
      ui.label({ text = tr("status.loading"), fontSize = font(12), color = "on_surface_variant" }),
    })
  end

  if #shownItems == 0 then
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
        fontSize = font(14),
        fontWeight = "semibold",
        color = "on_surface",
      }),
      ui.label({
        text = tr("empty.subtitle"),
        fontSize = font(11),
        color = "on_surface_variant",
      }),
    })
  end

  local d = density()
  local nodes = {}
  local list = applyFilter(shownItems)

  if cfgBool("group_by_repo", false) then
    local order, byRepo = {}, {}
    for _, it in ipairs(list) do
      local repo = it.repo or "GitHub"
      if not byRepo[repo] then
        byRepo[repo] = {}
        table.insert(order, repo)
      end
      table.insert(byRepo[repo], it)
    end
    for _, repo in ipairs(order) do
      local group = byRepo[repo]
      local isCollapsed = collapsed[repo] == true
      table.insert(nodes, ui.row({
        key = "group_" .. repo,
        gap = 6,
        align = "center",
        paddingV = 3,
        paddingH = 4,
        onClick = function()
          collapsed[repo] = not isCollapsed
          renderPanel()
        end,
      }, {
        ui.glyph({ name = isCollapsed and "chevron-right" or "chevron-down", size = 14, color = "on_surface_variant" }),
        ui.label({
          text = repo,
          fontSize = font(11),
          fontWeight = "bold",
          color = "on_surface_variant",
          maxLines = 1,
          flexGrow = 1,
        }),
        ui.label({ text = tostring(#group), fontSize = font(10), color = "on_surface_variant" }),
      }))
      if not isCollapsed then
        for _, it in ipairs(group) do
          table.insert(nodes, renderNotificationCard(it, d))
        end
      end
    end
  else
    for _, it in ipairs(list) do
      table.insert(nodes, renderNotificationCard(it, d))
    end
  end

  return ui.scroll({
    flexGrow = 1,
    gap = d.list,
    paddingV = 2,
    align = "stretch",
  }, nodes)
end

local function renderUndoBar()
  local entry = pending[#pending]
  if not entry then
    return nil
  end
  local prefix = entry.verb == "done" and "undo.done_" or "undo."
  local text = #entry.items == 1 and tr(prefix .. "one") or tr(prefix .. "many", { count = #entry.items })
  return ui.row({
    radius = getRadius(8),
    paddingV = 4,
    paddingH = 10,
    gap = 8,
    fill = "surface_variant/0.6",
    border = "outline/0.60",
    borderWidth = 1,
    align = "center",
  }, {
    ui.glyph({ name = "check", size = 14, color = "primary" }),
    ui.label({ text = text, fontSize = font(11), color = "on_surface", maxLines = 1, flexGrow = 1 }),
    ui.button({
      text = tr("action.undo"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        undoLast()
      end,
    }),
  })
end

function renderPanel()
  resolveWidgetFontScale()
  shownItems = visibleItems()
  local counts = categoryCounts(shownItems)
  if filter ~= "all" and (counts[filter] or 0) == 0 then
    filter = "all"
  end

  local children = { renderHeader() }
  if #shownItems > 0 then
    local filters = renderFilters(counts)
    if filters then
      table.insert(children, filters)
    end
  end
  table.insert(children, ui.separator({ thickness = 1, color = "outline/0.2", spacing = 0 }))
  table.insert(children, renderContent())
  local undoBar = renderUndoBar()
  if undoBar then
    table.insert(children, undoBar)
  end

  panel.render(ui.column({
    flexGrow = 1,
    gap = 6,
    align = "stretch",
  }, children))
end

noctalia.state.watch("github_notifications:panel_font_scale", function(_val)
  renderPanel()
end)

noctalia.state.watch("github_notifications:items", function(val)
  items = val or {}
  hoveredId = nil
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
  hoveredId = nil
  -- Refresh relative timestamps on open
  for _, item in ipairs(items) do
    item.relativeTime = Time.formatRelative(item.updatedAt)
  end
  renderPanel()
end

function onFrameTick(_deltaMs)
  if flush(false) then
    renderPanel()
  end
end

function onClose()
  -- Anything still inside its undo window goes out now rather than being lost.
  flush(true)
  hoveredId = nil
end
