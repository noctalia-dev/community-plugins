-- Details panel for OpenCode Monitor.

local shared = require("./shared.luau")

local snapshot = noctalia.state.get(shared.SNAPSHOT_KEY)
local opened = false
local showRecent = true
local collapsed = {}
local render

local function refresh()
  pcall(function()
    noctalia.state.set(shared.REFRESH_KEY, noctalia.nowMs())
  end)
end

local function chip(text, color, glyph)
  local role = color or "on_surface_variant"
  local children = {}
  if glyph then
    children[#children + 1] = ui.glyph({ name = glyph, size = 12, color = role })
  end
  children[#children + 1] = ui.label({
    text = text,
    fontSize = 11,
    fontWeight = "medium",
    color = role,
    maxLines = 1,
  })
  return ui.row({
    gap = 5,
    align = "center",
    paddingH = 9,
    paddingV = 3,
    radius = 8,
    fill = role .. "/0.12",
    border = role .. "/0.16",
    borderWidth = 1,
  }, children)
end

local function tile(glyph, color, size)
  local dimension = size or 38
  return ui.column({
    width = dimension,
    height = dimension,
    radius = math.floor(dimension / 3),
    fill = color .. "/0.14",
    border = color .. "/0.18",
    borderWidth = 1,
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = glyph, size = math.floor(dimension / 2), color = color }),
  })
end

local function statusTile(session)
  local meta = shared.statusMeta(session.status)
  local glyph = meta.glyph
  local color = meta.color
  if session.wait then
    glyph = session.wait.glyph or glyph
    color = session.status == "waiting_permission" and "error" or "secondary"
  elseif session.activity then
    glyph = session.activity.glyph or glyph
  end
  return tile(glyph, color, 38)
end

local function sectionHeader(title, count, color)
  local items = {
    ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = color or "on_surface" }),
    ui.label({ text = tostring(count), fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" }),
    ui.separator({ orientation = "horizontal", color = "outline_variant", opacity = 0.18, flexGrow = 1 }),
  }
  return ui.row({ gap = 8, align = "center", paddingV = 2 }, items)
end

local function waitBanner(session)
  local wait = session.wait
  if not wait then
    return nil
  end
  local color = session.status == "waiting_permission" and "error" or "secondary"
  local children = {
    ui.glyph({ name = wait.glyph or "bell-ringing", size = 18, color = color }),
  }
  local text = {
    ui.label({
      text = wait.title,
      fontSize = 12,
      fontWeight = "semibold",
      color = color,
      maxLines = 2,
      flexGrow = 1,
    }),
  }
  if wait.detail and wait.detail ~= "" then
    text[#text + 1] = ui.label({
      text = wait.detail,
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    })
  end
  children[#children + 1] = ui.column({ gap = 3, flexGrow = 1, align = "stretch" }, text)
  if (tonumber(wait.count) or 0) > 1 then
    children[#children + 1] = chip(tostring(wait.count) .. " requests", color)
  end
  local rows = {
    ui.row({
      gap = 10,
      align = "center",
      padding = 10,
      radius = 10,
      fill = color .. "/0.12",
      border = color .. "/0.20",
      borderWidth = 1,
    }, children),
  }
  if wait.kind == "permission" then
    rows[#rows + 1] = ui.label({
      text = "Respond in the OpenCode TUI.",
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
    })
  elseif wait.kind == "form" then
    rows[#rows + 1] = ui.label({
      text = "This prompt needs structured input. Respond in the OpenCode TUI.",
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 2,
    })
  end
  return ui.column({ gap = 8 }, rows)
end

local function activityRow(session, now)
  local activity = session.activity
  local meta = shared.statusMeta(session.status)
  local color = session.status == "running" and "primary" or meta.color
  local children = {
    ui.glyph({ name = activity.glyph or meta.glyph, size = 14, color = color }),
    ui.label({ text = activity.label, fontSize = 12, fontWeight = "semibold", color = color }),
  }
  if activity.detail and activity.detail ~= "" then
    children[#children + 1] = ui.label({
      text = "· " .. activity.detail,
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    })
  else
    children[#children + 1] = ui.spacer({ flexGrow = 1 })
  end
  if activity.since then
    children[#children + 1] = ui.label({
      text = shared.formatDuration((now - activity.since) / 1000),
      fontSize = 11,
      color = "on_surface_variant",
    })
  end
  return ui.row({ gap = 6, align = "center" }, children)
end

local function idleRow(session)
  local meta = shared.statusMeta(session.status)
  local color = meta.color
  local text = meta.label
  if session.updatedLabel and session.updatedLabel ~= "" then
    text = text .. " · " .. session.updatedLabel
  end
  return ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = meta.glyph, size = 14, color = color }),
    ui.label({ text = text, fontSize = 12, color = color }),
  })
end

local function metaRow(session)
  local children = {
    ui.glyph({ name = "user", size = 12, color = "on_surface_variant" }),
    ui.label({ text = shared.shorten(session.agent or "?", 22), fontSize = 11, color = "on_surface" }),
  }
  if session.model and session.model ~= "" then
    children[#children + 1] = ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" })
    children[#children + 1] = ui.label({
      text = shared.shorten(session.model, 26),
      fontSize = 11,
      color = "on_surface_variant",
    })
  end
  if session.shortDirectory and session.shortDirectory ~= "" then
    children[#children + 1] = ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" })
    children[#children + 1] = ui.glyph({ name = "folder", size = 12, color = "on_surface_variant" })
    children[#children + 1] = ui.label({
      text = session.shortDirectory,
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    })
  else
    children[#children + 1] = ui.spacer({ flexGrow = 1 })
  end
  return ui.row({ gap = 5, align = "center" }, children)
end

local RELATED_ROW_LIMIT = 12

local function relatedInfo(session)
  if type(session) ~= "table" then
    return {}, 0
  end
  local related = type(session.related) == "table" and session.related or {}
  local shown = #related
  local total = tonumber(session.relatedTotal) or tonumber(session.relatedCount) or shown
  if total < shown then
    total = shown
  end
  if total < 0 then
    total = 0
  end
  return related, total
end

local function metricsRow(session)
  local items = {}
  if session.isChild then
    local text = "child"
    if session.parentTitle and session.parentTitle ~= "" then
      text = "child of " .. shared.shorten(session.parentTitle, 30)
    end
    items[#items + 1] = chip(text, "secondary", "corner-down-right")
  end
  local _, relatedTotal = relatedInfo(session)
  if relatedTotal > 0 then
    local text = relatedTotal == 1 and "1 related" or (tostring(relatedTotal) .. " subagents")
    items[#items + 1] = chip(text, "secondary", "corner-down-right")
  end
  local tokens = session.tokens
  if type(tokens) == "table" and (tonumber(tokens.total) or 0) > 0 then
    items[#items + 1] = chip(shared.formatTokens(tokens.total) .. " tokens", "on_surface_variant", "database")
  end
  if (tonumber(session.cost) or 0) > 0 then
    items[#items + 1] = chip(shared.formatCost(session.cost), "on_surface_variant", "coin")
  end
  if (tonumber(session.queued) or 0) > 0 then
    items[#items + 1] = chip(tostring(session.queued) .. " queued", "secondary", "inbox")
  end
  if session.detailsIncomplete == true then
    items[#items + 1] = chip("partial data", "secondary", "alert-triangle")
  end
  if #items == 0 then
    return nil
  end
  return ui.row({ gap = 8, align = "center" }, items)
end

local function relatedRow(child, now)
  child = type(child) == "table" and child or {}
  local depth = tonumber(child.depth) or 1
  depth = math.max(1, math.floor(depth))
  local indent = 8 + (depth - 1) * 12
  local wait = type(child.wait) == "table" and child.wait or nil
  local activity = type(child.activity) == "table" and child.activity or nil
  local meta = shared.statusMeta(child.status)
  local glyph = meta.glyph
  local color = meta.color
  if wait then
    glyph = wait.glyph or glyph
    color = child.status == "waiting_permission" and "error" or "secondary"
  elseif activity then
    glyph = activity.glyph or glyph
  end

  local titleRow = {
    ui.glyph({ name = glyph, size = 12, color = color }),
    ui.label({
      text = tostring(child.title or "Untitled"),
      fontSize = 11,
      fontWeight = "semibold",
      color = "on_surface",
      maxLines = 1,
      flexGrow = 1,
    }),
  }
  local childCount = tonumber(child.childCount) or 0
  if childCount > 0 then
    titleRow[#titleRow + 1] = chip(
      tostring(childCount) .. (childCount == 1 and " child" or " children"),
      "on_surface_variant",
      "corner-down-right"
    )
  end

  local infoItems = {
    ui.label({
      text = shared.shorten(child.agent or "?", 20),
      fontSize = 10,
      color = "on_surface",
      maxLines = 1,
    }),
  }
  if child.model and child.model ~= "" then
    infoItems[#infoItems + 1] = ui.label({ text = "·", fontSize = 10, color = "on_surface_variant" })
    infoItems[#infoItems + 1] = ui.label({
      text = shared.shorten(child.model, 26),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    })
  else
    infoItems[#infoItems + 1] = ui.spacer({ flexGrow = 1 })
  end
  infoItems[#infoItems + 1] = ui.label({
    text = "· " .. meta.label,
    fontSize = 10,
    color = color,
    maxLines = 1,
  })

  local body = {
    ui.row({ gap = 6, align = "center" }, titleRow),
    ui.row({ gap = 5, align = "center" }, infoItems),
  }

  if wait then
    local banner = waitBanner(child)
    if banner then
      body[#body + 1] = banner
    end
  end
  if activity then
    body[#body + 1] = activityRow(child, now)
  elseif not wait and child.isActive then
    body[#body + 1] = idleRow(child)
  end

  local metrics = metricsRow(child)
  if metrics then
    body[#body + 1] = metrics
  end

  return ui.column({ paddingH = indent, align = "stretch" }, {
    ui.column({
      gap = 6,
      paddingH = 12,
      paddingV = 10,
      radius = 10,
      fill = "on_surface/0.06",
      border = "outline_variant/0.10",
      borderWidth = 1,
      align = "stretch",
    }, body),
  })
end

local function relatedPanel(session, now)
  local related, total = relatedInfo(session)
  if #related == 0 then
    return nil
  end
  local shown = math.min(#related, RELATED_ROW_LIMIT)
  local headerItems = {
    ui.glyph({ name = "corner-down-right", size = 13, color = "secondary" }),
    ui.label({ text = "Subagents", fontSize = 12, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = tostring(total), fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" }),
    ui.separator({ orientation = "horizontal", color = "outline_variant", opacity = 0.18, flexGrow = 1 }),
  }
  if shown < total then
    headerItems[#headerItems + 1] = ui.label({
      text = string.format("showing %d of %d", shown, total),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
    })
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, headerItems),
  }
  for index = 1, shown do
    local child = related[index]
    if type(child) == "table" then
      children[#children + 1] = relatedRow(child, now)
    end
  end
  return ui.column({
    gap = 8,
    align = "stretch",
    padding = 10,
    radius = 12,
    fill = "on_surface/0.03",
    border = "outline_variant/0.12",
    borderWidth = 1,
  }, children)
end

local function sessionCard(session, now)
  local meta = shared.statusMeta(session.status)
  local related = type(session.related) == "table" and session.related or {}
  local hasRelated = #related > 0
  local right = {
    ui.label({ text = meta.label, fontSize = 11, fontWeight = "bold", color = meta.color }),
  }
  if session.updatedLabel and session.updatedLabel ~= "" then
    right[#right + 1] = ui.label({
      text = session.updatedLabel,
      fontSize = 10,
      color = "on_surface_variant",
    })
  end

  local titleRow = {
    ui.label({
      text = session.title,
      fontSize = 14,
      fontWeight = "semibold",
      color = "on_surface",
      maxLines = 1,
      flexGrow = 1,
    }),
  }
  local isExpanded = hasRelated and not collapsed[session.id]
  if hasRelated then
    titleRow[#titleRow + 1] = ui.button({
      glyph = isExpanded and "chevron-up" or "chevron-down",
      variant = "ghost",
      controlSize = "sm",
      width = 30,
      height = 30,
      tooltip = isExpanded and "Hide subagents" or "Show subagents",
      onClick = function()
        collapsed[session.id] = isExpanded
        render()
      end,
    })
  end
  local body = {
    ui.row({ gap = 12, align = "center" }, {
      statusTile(session),
      ui.column({ gap = 4, flexGrow = 1, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, titleRow),
        metaRow(session),
      }),
      ui.column({ gap = 3, align = "end" }, right),
    }),
  }

  if session.wait then
    local banner = waitBanner(session)
    if banner then
      body[#body + 1] = banner
    end
  end
  if session.activity then
    body[#body + 1] = activityRow(session, now)
  elseif not session.wait and session.isActive then
    body[#body + 1] = idleRow(session)
  end

  local metrics = metricsRow(session)
  if metrics then
    body[#body + 1] = metrics
  end

  if hasRelated and not collapsed[session.id] then
    local relatedView = relatedPanel(session, now)
    if relatedView then
      body[#body + 1] = relatedView
    end
  end

  return ui.column({
    gap = 12,
    padding = 16,
    radius = 14,
    fill = "on_surface/0.08",
    border = "outline_variant/0.14",
    borderWidth = 1,
  }, body)
end

local function emptyState()
  return ui.column({
    gap = 10,
    align = "center",
    justify = "center",
    paddingV = 36,
    paddingH = 16,
  }, {
    ui.glyph({ name = "moon", size = 36, color = "on_surface_variant" }),
    ui.label({
      text = "No active OpenCode sessions",
      fontSize = 14,
      fontWeight = "semibold",
      color = "on_surface",
    }),
    ui.label({
      text = "Start a session in OpenCode and it will appear here.",
      fontSize = 12,
      color = "on_surface_variant",
      textAlign = "center",
    }),
  })
end

local function offlineState(server)
  local isError = server and server.state == "error"
  local color = isError and "error" or "on_surface_variant"
  local title = isError and "OpenCode is not responding" or "OpenCode is not running"
  local message = server and (server.warning or server.message) or "Waiting for the local service..."
  return ui.column({
    gap = 12,
    padding = 24,
    radius = 14,
    fill = isError and "error/0.10" or "on_surface/0.04",
    border = isError and "error/0.18" or "outline_variant/0.12",
    borderWidth = 1,
    align = "center",
  }, {
    ui.glyph({ name = "plug-x", size = 36, color = color }),
    ui.label({ text = title, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.label({
      text = shared.shorten(message, 220),
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 3,
      textAlign = "center",
    }),
    ui.label({
      text = "Start OpenCode or its background service, then press refresh.",
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 2,
      textAlign = "center",
    }),
  })
end

local function warningBanner(server)
  local warning = server and (server.warning or server.message)
  if not warning or warning == "" then
    return nil
  end
  return ui.row({
    gap = 8,
    align = "center",
    paddingH = 12,
    paddingV = 9,
    radius = 10,
    fill = "secondary/0.10",
    border = "secondary/0.18",
    borderWidth = 1,
  }, {
    ui.glyph({ name = "alert-triangle", size = 15, color = "secondary" }),
    ui.label({
      text = shared.shorten(warning, 200),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 2,
      flexGrow = 1,
    }),
  })
end

local function summaryRow(counts)
  local items = {}
  items[#items + 1] = chip(tostring(counts.active or 0) .. " active", "primary", "bolt")
  items[#items + 1] = chip(
    tostring(counts.waiting or 0) .. " waiting",
    (counts.waiting or 0) > 0 and "error" or "on_surface_variant",
    "bell-ringing"
  )
  items[#items + 1] = chip(tostring(counts.queued or 0) .. " queued", "secondary", "inbox")
  items[#items + 1] = chip(tostring(counts.recent or 0) .. " recent", "on_surface_variant", "history")
  items[#items + 1] = ui.spacer({ flexGrow = 1 })
  return ui.row({ gap = 8, align = "center" }, items)
end

local function header(now, counts)
  local server = snapshot and snapshot.server or nil
  counts = counts or { active = 0, waiting = 0, queued = 0, recent = 0 }
  local state = server and server.state or "offline"

  local glyph = "robot"
  local color = "primary"
  if state == "offline" or state == "error" then
    glyph = "plug-x"
    color = state == "error" and "error" or "on_surface_variant"
  elseif (counts.waiting or 0) > 0 then
    glyph = "bell-ringing"
    color = "error"
  end

  local subtitle
  if not snapshot then
    subtitle = "Connecting to the local OpenCode service..."
  elseif state == "error" then
    subtitle = "Service error · details below"
  elseif state == "offline" then
    subtitle = "Waiting for OpenCode · details below"
  else
    subtitle = string.format(
      "%d active · %d waiting · %d queued%s",
      counts.active or 0,
      counts.waiting or 0,
      counts.queued or 0,
      (counts.recent or 0) > 0 and string.format(" · %d recent", counts.recent) or ""
    )
  end

  return ui.row({ gap = 12, align = "center" }, {
    tile(glyph, color, 40),
    ui.column({ gap = 3, flexGrow = 1, align = "stretch" }, {
      ui.label({
        text = "OpenCode Monitor",
        fontSize = 18,
        fontWeight = "bold",
        color = "on_surface",
        maxLines = 1,
      }),
      ui.label({
        text = shared.shorten(subtitle, 100),
        fontSize = 12,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }),
    ui.label({
      text = shared.relativeTime(snapshot and snapshot.generatedAt or nil, now),
      fontSize = 11,
      color = "on_surface_variant",
    }),
    ui.row({ gap = 4, align = "center" }, {
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        width = 30,
        height = 30,
        tooltip = "Refresh now",
        onClick = function()
          refresh()
        end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        width = 30,
        height = 30,
        tooltip = "Open plugin settings",
        onClick = function()
          noctalia.openSettings()
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        width = 30,
        height = 30,
        tooltip = "Close",
        onClick = function()
          panel.close()
        end,
      }),
    }),
  })
end

local function footer(now)
  local server = snapshot and snapshot.server or nil
  local left
  if server then
    local url = server.url and server.url:gsub("^https?://", "") or ""
    local pieces = {}
    if server.version then
      pieces[#pieces + 1] = "OpenCode " .. tostring(server.version)
    end
    if server.pid then
      pieces[#pieces + 1] = "pid " .. tostring(server.pid)
    end
    if url ~= "" then
      pieces[#pieces + 1] = url
    end
    if server.pollInterval then
      pieces[#pieces + 1] = "poll " .. tostring(server.pollInterval) .. "s"
    end
    left = table.concat(pieces, " · ")
  else
    left = "Waiting for the local service"
  end
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "database", size = 12, color = "on_surface_variant" }),
    ui.label({
      text = shared.shorten(left, 110),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
      flexGrow = 1,
    }),
    ui.label({
      text = "Updated " .. shared.relativeTime(snapshot and snapshot.generatedAt or nil, now),
      fontSize = 10,
      color = "on_surface_variant",
    }),
  })
end

render = function()
  local now = noctalia.nowMs()
  local content = {}
  local display = { active = 0, waiting = 0, queued = 0, recent = 0 }

  if not snapshot then
    content[#content + 1] = offlineState(nil)
  else
    local server = snapshot.server or {}
    local active = type(snapshot.sessions) == "table" and snapshot.sessions or {}
    local recent = type(snapshot.recent) == "table" and snapshot.recent or {}

    local activeIDs = {}
    for _, session in ipairs(active) do
      if type(session) == "table" and session.id ~= nil then
        activeIDs[tostring(session.id)] = true
      end
    end
    local knownIDs = {}
    for id in pairs(activeIDs) do
      knownIDs[id] = true
    end
    for _, session in ipairs(recent) do
      if type(session) == "table" and session.id ~= nil then
        knownIDs[tostring(session.id)] = true
      end
    end
    local function parentIsActive(session)
      if type(session) ~= "table" or not session.isChild or session.parentID == nil then
        return false
      end
      return activeIDs[tostring(session.parentID)] == true
    end
    local function parentIsVisible(session)
      if type(session) ~= "table" or not session.isChild or session.parentID == nil then
        return false
      end
      return knownIDs[tostring(session.parentID)] == true
    end

    local waiting = {}
    local running = {}
    for _, session in ipairs(active) do
      if session.status == "waiting_permission" or session.status == "waiting_input" then
        -- Waiting children stay top-level so their wait reason is never hidden
        -- behind a collapsed parent card.
        waiting[#waiting + 1] = session
      elseif not parentIsActive(session) then
        running[#running + 1] = session
      end
    end

    local visibleRecent = {}
    for _, session in ipairs(recent) do
      if not parentIsVisible(session) then
        visibleRecent[#visibleRecent + 1] = session
      end
    end

    local queued = 0
    for _, session in ipairs(waiting) do
      queued = queued + (tonumber(session.queued) or 0)
    end
    for _, session in ipairs(running) do
      queued = queued + (tonumber(session.queued) or 0)
    end
    display.active = #waiting + #running
    display.waiting = #waiting
    display.queued = queued
    display.recent = #visibleRecent

    if server.state == "offline" or server.state == "error" then
      content[#content + 1] = offlineState(server)
    elseif server.state == "degraded" then
      local warning = warningBanner(server)
      if warning then
        content[#content + 1] = warning
      end
    end

    content[#content + 1] = summaryRow(display)

    if #waiting > 0 then
      content[#content + 1] = sectionHeader("Needs attention", #waiting, "error")
      for _, session in ipairs(waiting) do
        content[#content + 1] = sessionCard(session, now)
      end
    end

    if #running > 0 then
      content[#content + 1] = sectionHeader("Running", #running, "primary")
      for _, session in ipairs(running) do
        content[#content + 1] = sessionCard(session, now)
      end
    end

    if #active == 0 and (server.state == "online" or server.state == "degraded") then
      content[#content + 1] = emptyState()
    end

    if #visibleRecent > 0 then
      local headerChildren = {
        ui.label({ text = "Recent", fontSize = 12, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = tostring(#visibleRecent), fontSize = 10, color = "on_surface_variant" }),
        ui.separator({ orientation = "horizontal", color = "outline_variant", opacity = 0.2, flexGrow = 1 }),
        ui.button({
          glyph = showRecent and "chevron-up" or "chevron-down",
          variant = "ghost",
          controlSize = "sm",
          width = 30,
          height = 30,
          tooltip = showRecent and "Hide recent sessions" or "Show recent sessions",
          onClick = function()
            showRecent = not showRecent
            render()
          end,
        }),
      }
      content[#content + 1] = ui.row({ gap = 6, align = "center" }, headerChildren)
      if showRecent then
        for _, session in ipairs(visibleRecent) do
          content[#content + 1] = sessionCard(session, now)
        end
      end
    end
  end

  panel.render(ui.column({ gap = 14, flexGrow = 1, fill = "surface/0.88", border = "outline_variant/0.16", borderWidth = 1, radius = 16, padding = 16 }, {
    header(now, display),
    ui.scroll({ flexGrow = 1, gap = 12 }, content),
    footer(now),
  }))
end

noctalia.state.watch(shared.SNAPSHOT_KEY, function(value)
  snapshot = value
  if opened then
    render()
  end
end)

function onIpc(event)
  if tostring(event or ""):lower() == "refresh" then
    refresh()
  end
end

function onOpen()
  opened = true
  collapsed = {}
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  opened = false
  panel.setWantsSecondTicks(false)
end

function update()
  if opened then
    render()
  end
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "Escape" or chord == "Esc" then
    panel.close()
  end
end

render()
