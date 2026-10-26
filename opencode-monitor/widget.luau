-- Bar widget for OpenCode Monitor.

local shared = require("./shared.luau")

local snapshot = noctalia.state.get(shared.SNAPSHOT_KEY)

local function settingGlyph()
  local value = shared.stringSetting("glyph", "robot")
  if value == "" then
    return "robot"
  end
  return value
end

local function settingDisplayMode()
  local value = shared.stringSetting("display_mode", "activity")
  if value == "counts" or value == "dots" or value == "activity" then
    return value
  end
  return "activity"
end

local function visibleSessions()
  local showChildren = shared.boolSetting("show_children", true)
  local list = {}
  if not snapshot or type(snapshot.sessions) ~= "table" then
    return list
  end
  for _, session in ipairs(snapshot.sessions) do
    if showChildren or not session.isChild then
      list[#list + 1] = session
    end
  end
  return list
end

local function countWaiting(list)
  local waiting = 0
  for _, session in ipairs(list) do
    if session.status == "waiting_permission" or session.status == "waiting_input" then
      waiting = waiting + 1
    end
  end
  return waiting
end

local function countQueued(list)
  local queued = 0
  for _, session in ipairs(list) do
    queued = queued + (tonumber(session.queued) or 0)
  end
  return queued
end

local function widgetState()
  local list = visibleSessions()
  local waiting = countWaiting(list)
  local queued = countQueued(list)
  local server = snapshot and snapshot.server or nil
  local serverState = server and server.state or nil

  local glyph = settingGlyph()
  local color = "on_surface_variant"
  local label = "starting"
  local mode = settingDisplayMode()

  if not snapshot then
    return {
      list = list,
      waiting = waiting,
      queued = queued,
      glyph = "loader",
      color = "on_surface_variant",
      label = "starting",
      mode = mode,
      server = nil,
    }
  end

  if serverState == "offline" then
    glyph = "plug-x"
    color = "on_surface_variant"
    label = "offline"
  elseif serverState == "error" then
    glyph = "plug-x"
    color = "error"
    label = "error"
  elseif #list == 0 then
    if (snapshot.counts and snapshot.counts.active or 0) > 0 then
      glyph = "loader"
      color = "primary"
      label = "busy"
    else
      glyph = settingGlyph()
      color = "on_surface_variant"
      label = "idle"
    end
  else
    local primary = list[1]
    local meta = shared.statusMeta(primary.status)
    glyph = meta.glyph
    color = meta.color
    if primary.wait then
      glyph = primary.wait.glyph or meta.glyph
    elseif primary.activity then
      glyph = primary.activity.glyph or glyph
    end

    if mode == "counts" then
      label = string.format("%d active", #list)
    elseif mode == "dots" then
      label = string.format("%d active", #list)
    elseif waiting > 0 then
      if waiting == 1 then
        local wait = primary.wait
        local what = "input"
        if wait then
          if wait.kind == "permission" then
            what = "permission"
          elseif wait.kind == "form" then
            what = "input"
          elseif wait.title then
            what = wait.title
          end
        end
        label = "wait: " .. what
      else
        label = string.format("%d waiting", waiting)
      end
    elseif #list > 1 then
      label = string.format("%d · %s", #list, primary.activity and primary.activity.label or meta.label)
    else
      label = primary.activity and primary.activity.label or meta.label
    end
  end

  if serverState == "degraded" and #list == 0 then
    label = "no data"
  end

  return {
    list = list,
    waiting = waiting,
    queued = queued,
    glyph = glyph,
    color = color,
    label = label,
    mode = mode,
    server = server,
  }
end

local function dotColor(status)
  return shared.statusMeta(status).color
end

local function tooltipRows(state)
  local rows = {}
  local server = state.server

  if not server then
    rows[#rows + 1] = { key = "OpenCode", value = "Connecting to the local service..." }
  elseif server.state == "offline" then
    rows[#rows + 1] = { key = "OpenCode", value = server.message or "Not running" }
  elseif server.state == "error" then
    rows[#rows + 1] = { key = "OpenCode", value = server.warning or server.message or "Unavailable" }
  else
    local summary = string.format(
      "%d active · %d waiting · %d queued",
      #state.list,
      state.waiting,
      state.queued
    )
    rows[#rows + 1] = {
      key = "OpenCode" .. (server.version and (" " .. server.version) or ""),
      value = summary,
    }
  end

  local shown = 0
  for _, session in ipairs(state.list) do
    if shown >= 6 then
      break
    end
    local value
    if session.wait then
      value = session.wait.title
      if session.wait.detail and session.wait.detail ~= "" then
        value = value .. " · " .. session.wait.detail
      end
    elseif session.activity then
      value = session.activity.label
      if session.activity.detail and session.activity.detail ~= "" then
        value = value .. " · " .. session.activity.detail
      end
    else
      value = shared.statusMeta(session.status).label
    end
    local title = shared.shorten(session.title, 34)
    if session.isChild then
      title = "↳ " .. title
    end
    rows[#rows + 1] = { key = title, value = shared.shorten(value, 64) }
    shown = shown + 1
  end

  if #state.list == 0 then
    if server and server.state ~= "offline" and server.state ~= "error" then
      local recent = snapshot and snapshot.recent or {}
      if recent[1] then
        rows[#rows + 1] = { key = "Last session", value = shared.shorten(recent[1].title, 64) }
      else
        rows[#rows + 1] = { key = "No active sessions", value = "OpenCode is idle" }
      end
    end
  elseif #state.list > shown then
    rows[#rows + 1] = { key = "More sessions", value = string.format("+%d active", #state.list - shown) }
  end

  if state.queued > 0 then
    rows[#rows + 1] = { key = "Queued prompts", value = tostring(state.queued) }
  end

  if server and server.warning and server.state ~= "error" then
    rows[#rows + 1] = { key = "Warning", value = shared.shorten(server.warning, 80) }
  end

  rows[#rows + 1] = { key = "Left click", value = "Open details" }
  rows[#rows + 1] = { key = "Right click", value = "Refresh" }
  return rows
end

local function render()
  local state = widgetState()
  local vertical = barWidget.isVertical()
  local children = {}

  children[#children + 1] = ui.glyph({
    name = state.glyph,
    size = 16,
    color = state.color,
  })

  if state.mode == "dots" then
    local shown = 0
    for _, session in ipairs(state.list) do
      if shown >= 6 then
        break
      end
      children[#children + 1] = ui.box({
        width = 6,
        height = 6,
        radius = 3,
        fill = dotColor(session.status),
      })
      shown = shown + 1
    end
  end

  local showLabel = shared.boolSetting("show_label", true)
  local labelWidth = shared.intSetting("label_width", 26, 8, 60)
  if showLabel then
    local text = shared.shorten(state.label, labelWidth)
    if state.queued > 0 then
      text = text .. " +" .. tostring(state.queued)
    end
    children[#children + 1] = ui.label({
      text = text,
      fontSize = 12,
      color = state.color,
      maxLines = 1,
    })
  end

  local container
  if vertical then
    container = ui.column({ gap = 2, align = "center" }, children)
  else
    container = ui.row({ gap = 4, align = "center" }, children)
  end
  barWidget.render(container)
  barWidget.setTooltip(tooltipRows(state))
end

noctalia.state.watch(shared.SNAPSHOT_KEY, function(value)
  snapshot = value
  render()
end)

function update()
  -- Recovery is host-managed. The former PATH-resolved `touch` workaround did
  -- not trigger a reload (the inotify mask excludes IN_ATTRIB) and created an
  -- unnecessary process-execution surface, so it was removed.
  render()
end

function onConfigChanged()
  render()
end

function onRightClick()
  noctalia.state.set(shared.REFRESH_KEY, noctalia.nowMs())
end

noctalia.setUpdateInterval(2000)
render()
