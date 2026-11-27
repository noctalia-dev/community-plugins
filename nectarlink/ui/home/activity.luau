--!nonstrict
-- Compact projections of the selected phone's notification and timeline feeds.
local palette = require("../palette.luau")

local M = {}
local pad, gap, headerHeight, rowHeight, rowLimit = 10, 6, 30, 62, 3
local eventIcons = {
  clipboard = "clipboard",
  file = "file",
  photo = "photo",
  link = "link",
  notification = "bell",
  mirror = "devices-pc",
}

local function timeLabel(timestamp, label, milliseconds)
  if noctalia.formatTime and type(timestamp) == "number" then
    local seconds = milliseconds and timestamp / 1000 or timestamp
    if seconds > 0 and seconds < 253402300800 then
      return label(noctalia.formatTime("%H:%M", math.floor(seconds)), 10, "on_surface_variant", false, 43)
    end
  end
end

local function cardHeader(spec, width, label, actions)
  return ui.row({
    key = spec.key .. "-header",
    width = width,
    height = headerHeight,
    gap = 7,
    align = "center",
  }, {
    ui.glyph({ name = spec.icon, size = 19, color = "on_surface" }),
    label(spec.heading, 15, "on_surface", true, width - 99),
    ui.spacer({ flexGrow = 1 }),
    ui.row({
      key = spec.key .. "-more",
      width = 66,
      height = 26,
      gap = 4,
      align = "center",
      justify = "end",
      tooltip = noctalia.tr(spec.hint),
      onClick = function()
        actions.send(spec.command)
      end,
    }, {
      label(noctalia.tr("common.all"), 11, "primary", true, 42),
      ui.glyph({ name = "arrow-up-right", size = 15, color = "primary" }),
    }),
  })
end

local function notificationRow(item, width, components)
  local app = components.preview(item.appName, 40)
  if app == "" then
    app = noctalia.tr("common.phone")
  end
  local titleWidth = width - 72
  local title = components.preview(item.title, 60)
  local source = {
    components.label(app, 10, "primary", false, titleWidth - 52),
    ui.spacer({ flexGrow = 1 }),
  }
  local time = timeLabel(item.timestamp, components.label, true)
  if time then
    source[#source + 1] = time
  end
  -- The API does not supply notification icon files. Use an app initial instead
  -- of hardcoded brand colors or unrelated imagery.
  local initial = app:sub(1, (utf8.offset(app, 2) or (#app + 1)) - 1):upper()
  return ui.row({
    key = "notice-" .. tostring(item.key),
    width = width,
    height = rowHeight,
    gap = 9,
    padding = 8,
    radius = 10,
    align = "center",
    fill = palette("raised", 0.72),
  }, {
    ui.box({ width = 6, height = 6, radius = 3, fill = "primary" }),
    ui.column({
      width = 32, height = 32, radius = 9, align = "center", justify = "center",
      fill = "primary/0.16",
    }, { components.label(initial, 14, "primary", true, 26) }),
    ui.column({
      width = titleWidth,
      gap = 1,
      align = "start",
      justify = "center",
    }, {
      ui.row({ width = titleWidth, height = 14, gap = 4, align = "center" }, source),
      components.label(title ~= "" and title or noctalia.tr("home.notification"),
        12, "on_surface", true, titleWidth),
      components.label(components.preview(item.text, 96), 10, "on_surface_variant", false, titleWidth),
    }),
  })
end

local function timelineMarker(first, last)
  local function line(visible)
    return ui.box({ width = 1, height = 27, fill = visible and "primary/0.36" or "transparent" })
  end
  return ui.column({ width = 12, height = rowHeight, gap = 0, align = "center" }, {
    line(not first),
    ui.box({ width = 7, height = 7, radius = 4, fill = "primary" }),
    line(not last),
  })
end

local function timelineRow(item, width, components, index, count)
  local cardWidth = width - 18
  local textWidth = cardWidth - 56
  local title = components.preview(item.title, 60)
  local direction = item.direction == "incoming" and "home.received" or "home.sent"
  local time = timeLabel(item.timestamp, components.label)
  local heading = {
    components.label(title ~= "" and title or noctalia.tr("home.event"),
      12, "on_surface", true, textWidth - (time and 52 or 0)),
  }
  if time then
    heading[2] = ui.spacer({ flexGrow = 1 })
    heading[3] = time
  end
  return ui.row({
    key = "event-" .. tostring(item.id), width = width, height = rowHeight, gap = 6,
  }, {
    timelineMarker(index == 1, index == count),
    ui.row({
      width = cardWidth,
      height = rowHeight,
      padding = 8,
      gap = 8,
      radius = 10,
      align = "center",
      fill = palette("raised", 0.72),
    }, {
      ui.column({
        width = 32, height = 32, radius = 16, align = "center", justify = "center",
        fill = "on_surface_variant/0.1",
      }, {
        ui.glyph({ name = eventIcons[item.kind] or "history", size = 18, color = "on_surface_variant" }),
      }),
      ui.column({ width = textWidth, gap = 3, align = "start", justify = "center" }, {
        ui.row({ width = textWidth, height = 17, gap = 4, align = "center" }, heading),
        components.label(noctalia.tr(direction), 11, "on_surface_variant", false, textWidth),
      }),
    }),
  })
end

local function activityCard(spec, width, height, phone, components, actions)
  local innerWidth = width - 2 * pad
  local selected, count = {}, 0
  if phone and spec.state == "ready" then
    for _, item in ipairs(spec.items or {}) do
      if item.deviceId == phone.id then
        count = count + 1
        if #selected < rowLimit then
          selected[#selected + 1] = item
        end
      end
    end
  end
  spec.heading = noctalia.tr(spec.headingKey, { count = count })
  local rows = { cardHeader(spec, innerWidth, components.label, actions) }
  for index, item in ipairs(selected) do
    rows[#rows + 1] = spec.row(item, innerWidth, components, index, #selected)
  end
  if #selected == 0 then
    local state = spec.state
    local message = state == "ready" and spec.empty
      or ((state == "offline" or state == "unsupported") and spec.failed or spec.loading)
    rows[#rows + 1] = ui.column({
      height = height - 2 * pad - headerHeight - gap,
      align = "center",
      justify = "center",
      gap = 6,
    }, {
      ui.glyph({ name = spec.icon, size = 23, color = "on_surface_variant/0.55" }),
      components.label(noctalia.tr(message), 12, "on_surface_variant", false, innerWidth),
    })
  end
  return ui.column({
    key = spec.key,
    width = width,
    height = height,
    gap = gap,
    padding = pad,
    radius = 14,
    fill = palette("card"),
  }, rows)
end

function M.render(context, width, height, showNotifications, showTimeline, model, components, actions)
  local snapshot = model.snapshot
  local cards = {}
  local split = showNotifications and showTimeline
  local cardHeight = split and math.floor((height - 8) / 2) or height
  if showNotifications then
    cards[#cards + 1] = activityCard({
      key = "notifications", icon = "bell", headingKey = "home.notifications",
      hint = "home.notifications_hint", command = "open",
      state = not context.ready and "offline" or snapshot.notificationsState,
      items = snapshot.notifications, row = notificationRow,
      empty = "home.no_notifications", failed = "home.notifications_failed", loading = "home.notifications_loading",
    }, width, cardHeight, context.phone, components, actions)
  end
  if showTimeline then
    cards[#cards + 1] = activityCard({
      key = "timeline", icon = "history", headingKey = "home.timeline",
      hint = "home.open_timeline", command = "timeline",
      state = not context.ready and "offline" or snapshot.timelineState,
      items = snapshot.timeline, row = timelineRow,
      empty = "home.no_events", failed = "home.events_failed", loading = "home.events_loading",
    }, width, split and (height - cardHeight - 8) or height, context.phone, components, actions)
  end
  return ui.column({ key = "sidebar", width = width, height = height, gap = 8 }, cards)
end

return M
