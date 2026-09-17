--!nonstrict
-- Bangumi Progress panel: collection filters, episode controls, completion, and subject links.

local snapshot = noctalia.state.get("bgm_snapshot") or {}

local COVER_WIDTH = 40
local COVER_HEIGHT = 56

local FILTERS = {
  { type = 3, key = "filter_watching" },
  { type = 1, key = "filter_wish" },
  { type = 2, key = "filter_done" },
  { type = 4, key = "filter_on_hold" },
  { type = 5, key = "filter_dropped" },
}

local activeType = 3
local dirty = true
local render -- Forward declaration for functions such as setFilter and onOpen.

local function tr(key, subst)
  return noctalia.tr("panel." .. key, subst)
end

local function sendCommand(action, values)
  local command = { action = action }
  if type(values) == "table" then
    for k, v in pairs(values) do
      command[k] = v
    end
  end
  noctalia.state.set("bgm_command", command)
end

local function collectionOf(type)
  for _, c in ipairs(snapshot.collections or {}) do
    if c.type == type then
      return c
    end
  end
  return nil
end

local function errorText(code)
  if code == "not_configured" then
    return tr("not_configured")
  elseif code == "unauthorized" then
    return tr("unauthorized")
  elseif code == "network" then
    return tr("network_error")
  elseif code == "parse" then
    return tr("parse_error")
  elseif code == "busy" then
    return tr("busy")
  elseif code == "episodes_unavailable" then
    return tr("episodes_unavailable")
  elseif code == "no_next_episode" then
    return tr("no_next_episode")
  elseif code == "no_prev_episode" then
    return tr("no_prev_episode")
  elseif code and code:sub(1, 4) == "http" then
    return tr("http_error", { status = code:gsub("http_", "") })
  end
  return tr("unknown_error")
end

local function setFilter(type)
  activeType = type
  local collection = collectionOf(type)
  if collection and not collection.loaded and not snapshot.loading then
    sendCommand("load_type", { type = type })
  end
  dirty = true
  render()
end

local function progressText(row)
  local current = row.epStatus or 0
  local total = row.eps or 0
  local aired = row.airedEp
  if aired == nil and total > 0 and current >= total then
    aired = total
  end
  if aired ~= nil and total > 0 then
    return tr("progress_aired", { current = current, aired = aired, total = total })
  end
  if total > 0 then
    return tr("progress", { current = current, total = total })
  end
  return tr("progress_unknown", { current = current })
end

local function subtitleText(row)
  local parts = { progressText(row) }
  if row.rate and row.rate > 0 then
    table.insert(parts, tr("score", { score = row.rate }))
  end
  if row.date and row.date ~= "" then
    table.insert(parts, row.date)
  end
  return table.concat(parts, " · ")
end

local function renderCover(row)
  if row.coverPath then
    return ui.image({
      key = "cover-" .. tostring(row.subjectId),
      path = row.coverPath,
      width = COVER_WIDTH,
      height = COVER_HEIGHT,
      radius = 4,
      fit = "cover",
    })
  end
  return ui.column({
    width = COVER_WIDTH,
    height = COVER_HEIGHT,
    radius = 4,
    fill = "surface_variant",
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = "device-tv", size = 14, color = "on_surface_variant" }),
  })
end

local function renderRow(row)
  local subjectId = row.subjectId
  local canDecrement = (row.epStatus or 0) > 0 and not snapshot.busy
  local canIncrement = not snapshot.busy
  local isDone = row.eps > 0 and (row.epStatus or 0) >= row.eps

  local titleChildren = {}
  if (row.newlyUnwatched or 0) > 0 then
    table.insert(titleChildren, ui.box({ width = 7, height = 7, radius = 4, fill = "error" }))
  end
  table.insert(titleChildren, ui.label({
    text = row.title or "?",
    fontSize = 13,
    fontWeight = "medium",
    maxLines = 1,
    flexGrow = 1,
    minWidth = 0,
  }))

  local rowChildren = {
    renderCover(row),
    ui.column({ gap = 2, flexGrow = 1, minWidth = 0, justify = "center" }, {
      ui.row({ gap = 6, align = "center" }, titleChildren),
      ui.label({ text = subtitleText(row), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = "minus",
      variant = "ghost",
      tooltip = tr("ep_decrement"),
      onClick = canDecrement and function()
        sendCommand("decrement", { subjectId = subjectId })
      end or "onNoop",
    }),
    ui.button({
      glyph = "plus",
      variant = "ghost",
      tooltip = tr("ep_increment"),
      onClick = canIncrement and function()
        sendCommand("increment", { subjectId = subjectId })
      end or "onNoop",
    }),
    ui.button({
      glyph = if isDone then "check" else "circle-check",
      variant = if isDone then "primary" else "ghost",
      tooltip = tr("mark_done"),
      onClick = snapshot.busy and "onNoop" or function()
        sendCommand("complete", { subjectId = subjectId })
      end,
    }),
    ui.button({
      glyph = "external-link",
      variant = "ghost",
      tooltip = tr("open"),
      onClick = function()
        sendCommand("open_subject", { subjectId = subjectId })
      end,
    }),
  }

  return ui.row({
    key = "entry-" .. tostring(subjectId),
    gap = 8,
    align = "center",
    padding = { top = 6, bottom = 6 },
  }, rowChildren)
end

local function renderNotConfigured()
  return ui.column({ gap = 12, padding = 16, flexGrow = 1, align = "center", justify = "center" }, {
    ui.glyph({ name = "settings", size = 28, color = "on_surface_variant" }),
    ui.label({ text = tr("not_configured_hint"), fontSize = 13, color = "on_surface_variant", textAlign = "center" }),
    ui.button({ text = tr("open_settings"), variant = "primary", onClick = "onSettings" }),
  })
end

local function renderContent()
  local children = {}

  -- Header
  local headerChildren = {
    ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold" }),
  }
  if snapshot.viewer then
    local viewerText = ""
    if snapshot.viewer.nickname and snapshot.viewer.nickname ~= "" then
      if snapshot.authMode == "token" and snapshot.viewer.username and snapshot.viewer.username ~= "" then
        viewerText = tr("logged_in_as", { name = snapshot.viewer.nickname, username = snapshot.viewer.username })
      else
        viewerText = tr("public_view", { username = snapshot.viewer.username or snapshot.viewer.nickname })
      end
    end
    if viewerText ~= "" then
      table.insert(headerChildren, ui.label({
        text = viewerText,
        fontSize = 12,
        color = "on_surface_variant",
      }))
    end
  end

  table.insert(children, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.column({ gap = 2, flexGrow = 1 }, headerChildren),
    ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("settings"), onClick = "onSettings" }),
    ui.button({
      glyph = "refresh",
      variant = if snapshot.busy then "primary" else "ghost",
      tooltip = if snapshot.busy then tr("updating") else tr("refresh"),
      onClick = snapshot.busy and "onNoop" or "onRefresh",
    }),
  }))

  -- Collection filters
  local filterChildren = {}
  for _, f in ipairs(FILTERS) do
    local collection = collectionOf(f.type)
    local label = tr(f.key)
    if collection and collection.total and collection.total > 0 then
      label = label .. " " .. tostring(collection.total)
    end
    table.insert(filterChildren, ui.button({
      text = label,
      variant = if activeType == f.type then "primary" else "ghost",
      onClick = function()
        setFilter(f.type)
      end,
    }))
  end
  table.insert(children, ui.row({ gap = 6 }, filterChildren))

  -- Status message
  if snapshot.loading then
    table.insert(children, ui.label({ text = tr("loading"), color = "on_surface_variant" }))
  elseif snapshot.error ~= "" then
    table.insert(children, ui.label({ text = errorText(snapshot.error), color = "error" }))
  end

  -- Entry list
  local collection = collectionOf(activeType)
  local rows = collection and collection.rows or {}
  if #rows == 0 then
    if not snapshot.loading and not snapshot.error then
      table.insert(children, ui.label({ text = tr("empty"), color = "on_surface_variant" }))
    end
  else
    local displayRows = {}
    local originalIndex = {}
    for index, row in ipairs(rows) do
      table.insert(displayRows, row)
      originalIndex[row] = index
    end
    table.sort(displayRows, function(a, b)
      local aNew = (a.newlyUnwatched or 0) > 0
      local bNew = (b.newlyUnwatched or 0) > 0
      if aNew ~= bNew then
        return aNew
      end
      return originalIndex[a] < originalIndex[b]
    end)
    local listChildren = {}
    for _, row in ipairs(displayRows) do
      table.insert(listChildren, renderRow(row))
    end
    -- Keep one stretched layout root inside the viewport. During the initial
    -- burst of snapshot updates, independently measured scroll children can
    -- otherwise retain their content width and collapse later rows.
    table.insert(children, ui.scroll({ flexGrow = 1, paddingH = 4, align = "stretch" }, {
      ui.column({ gap = 4, align = "stretch" }, listChildren),
    }))
  end

  return ui.column({ gap = 10, padding = 16, flexGrow = 1 }, children)
end

render = function()
  if not snapshot.viewer and snapshot.authMode == "none" and not snapshot.loading then
    panel.render(renderNotConfigured())
    dirty = false
    return
  end
  panel.render(renderContent())
  dirty = false
end

noctalia.state.watch("bgm_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    dirty = true
    render()
  end
end)

panel.setWantsSecondTicks(true)

function onOpen(_context)
  noctalia.state.set("bgm_open", true)
  -- Silently refresh the watching list when the panel opens.
  sendCommand("refresh", { silent = true })
  local collection = collectionOf(activeType)
  if collection and not collection.loaded then
    sendCommand("load_type", { type = activeType })
  end
  dirty = true
  render()
end

function onClose()
  noctalia.state.set("bgm_open", false)
end

function update()
  if dirty then
    render()
  end
end

function onNoop() end

function onRefresh()
  sendCommand("refresh", {})
end

function onSettings()
  noctalia.openSettings()
end

render()

-- The host invokes entry points by name; this reference suppresses static-analysis unused warnings.
local _ = { update, onOpen, onClose, onNoop, onRefresh, onSettings }
