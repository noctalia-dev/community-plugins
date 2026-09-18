--!nonstrict
-- Bangumi Progress desktop widget: fixed natural width and viewport height based on visible entries.

local snapshot = noctalia.state.get("bgm_snapshot") or {}

local COVER_WIDTH = 40
local COVER_HEIGHT = 56
local ROW_HEIGHT = 62
local ROW_GAP = 4
local HEADER_HEIGHT = 28
local ROOT_PADDING = 12
local ROOT_GAP = 8
local OPEN_BUTTON_SIZE = 28
local pageOffset = 0

local function tr(key, subst)
  return noctalia.tr("desktop." .. key, subst)
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

local function errorText(code)
  if code == "not_configured" then
    return tr("not_configured")
  elseif code == "unauthorized" then
    return tr("unauthorized")
  elseif code == "network" then
    return tr("network_error")
  elseif code == "parse" then
    return tr("parse_error")
  elseif code and code:sub(1, 4) == "http" then
    return tr("http_error", { status = code:gsub("http_", "") })
  end
  return tr("unknown_error")
end

local function watchingRows()
  for _, collection in ipairs(snapshot.collections or {}) do
    if collection.type == 3 then
      local rows = {}
      for _, row in ipairs(collection.rows or {}) do
        table.insert(rows, row)
      end
      table.sort(rows, function(a, b)
        local aNew = (a.newlyUnwatched or 0) > 0
        local bNew = (b.newlyUnwatched or 0) > 0
        if aNew ~= bNew then
          return aNew
        end
        local aUpdated = tostring(a.updatedAt or "")
        local bUpdated = tostring(b.updatedAt or "")
        if aUpdated == bUpdated then
          return (a.subjectId or 0) > (b.subjectId or 0)
        end
        return aUpdated > bUpdated
      end)
      return rows
    end
  end
  return {}
end

local function progressRatio(row)
  if row.eps and row.eps > 0 then
    return math.min(1, (row.epStatus or 0) / row.eps)
  end
  return 0
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
  elseif total > 0 then
    return tr("progress", { current = current, total = total })
  end
  return tr("progress_unknown", { current = current })
end

local function renderCover(row, showCovers)
  if not showCovers then
    return nil
  end
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

local function renderRow(row, showCovers, rowWidth)
  local children = {}
  local cover = renderCover(row, showCovers)
  if cover then
    table.insert(children, cover)
  end

  local titleColor = "on_surface"
  if row.eps and row.eps > 0 and (row.epStatus or 0) >= row.eps then
    titleColor = "primary"
  end
  local detailWidth = rowWidth - OPEN_BUTTON_SIZE - 8
  if showCovers then
    detailWidth = detailWidth - COVER_WIDTH - 8
  end
  table.insert(children, ui.column({ width = detailWidth, minWidth = 0, gap = 4, justify = "center" }, {
    ui.label({ text = row.title or "?", fontSize = 12, maxLines = 1, color = titleColor }),
    ui.row({ width = detailWidth, gap = 8, align = "center" }, {
      ui.progress({ progress = progressRatio(row), flexGrow = 1, height = 5, radius = 2 }),
      ui.label({ text = progressText(row), fontSize = 10, color = "on_surface_variant" }),
    }),
  }))

  local subjectId = row.subjectId
  table.insert(children, ui.button({
    glyph = "external-link",
    variant = "ghost",
    width = OPEN_BUTTON_SIZE,
    height = OPEN_BUTTON_SIZE,
    tooltip = tr("open"),
    onClick = function()
      sendCommand("open_subject", { subjectId = subjectId })
    end,
  }))

  return ui.row({
    key = "row-" .. tostring(subjectId),
    width = rowWidth,
    height = ROW_HEIGHT,
    gap = 8,
    align = "center",
  }, children)
end

local function render()
  local widgetWidth = tonumber(noctalia.getConfig("widget_width")) or 320
  widgetWidth = math.max(220, math.min(800, widgetWidth))
  local visibleItems = tonumber(noctalia.getConfig("visible_items")) or 6
  visibleItems = math.max(1, math.min(20, math.floor(visibleItems)))
  local showCovers = noctalia.getConfig("show_covers")
  if showCovers == nil then
    showCovers = true
  end

  local rows = watchingRows()
  local maxOffset = math.max(0, #rows - visibleItems)
  pageOffset = math.max(0, math.min(maxOffset, pageOffset))
  local lastIndex = math.min(#rows, pageOffset + visibleItems)
  local rootHeight = nil
  local headerChildren = {
    ui.label({
      text = tr("watching_count", { count = #rows }),
      fontSize = 13,
      fontWeight = "bold",
      color = "primary",
      flexGrow = 1,
    }),
  }
  if #rows > visibleItems then
    table.insert(headerChildren, ui.label({
      text = tr("page_range", { first = pageOffset + 1, last = lastIndex, total = #rows }),
      fontSize = 10,
      color = "on_surface_variant",
    }))
    table.insert(headerChildren, ui.button({
      glyph = "chevron-left",
      variant = "ghost",
      tooltip = tr("previous_page"),
      onClick = function()
        pageOffset = math.max(0, pageOffset - visibleItems)
        render()
      end,
    }))
    table.insert(headerChildren, ui.button({
      glyph = "chevron-right",
      variant = "ghost",
      tooltip = tr("next_page"),
      onClick = function()
        pageOffset = math.min(maxOffset, pageOffset + visibleItems)
        render()
      end,
    }))
  end
  local children = {
    ui.row({ height = HEADER_HEIGHT, align = "center", gap = 4 }, headerChildren),
  }

  if snapshot.loading and #rows == 0 then
    table.insert(children, ui.label({ text = tr("loading"), fontSize = 11, color = "on_surface_variant" }))
  elseif snapshot.error and snapshot.error ~= "" and #rows == 0 then
    table.insert(children, ui.label({ text = errorText(snapshot.error), fontSize = 11, color = "error" }))
  elseif #rows == 0 then
    table.insert(children, ui.label({ text = tr("empty"), fontSize = 11, color = "on_surface_variant" }))
  else
    local rowNodes = {}
    local rowWidth = widgetWidth - ROOT_PADDING * 2
    for index = pageOffset + 1, lastIndex do
      table.insert(rowNodes, renderRow(rows[index], showCovers, rowWidth))
    end
    local shown = #rowNodes
    local viewportHeight = shown * ROW_HEIGHT + math.max(0, shown - 1) * ROW_GAP
    rootHeight = ROOT_PADDING * 2 + HEADER_HEIGHT + ROOT_GAP + viewportHeight
    table.insert(children, ui.column({
      width = rowWidth,
      height = viewportHeight,
      gap = ROW_GAP,
    }, rowNodes))
  end

  desktopWidget.render(ui.column({
    width = widgetWidth,
    height = rootHeight,
    gap = ROOT_GAP,
    padding = ROOT_PADDING,
  }, children))
end

noctalia.state.watch("bgm_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function update()
  render()
end

function onConfigChanged()
  pageOffset = 0
  render()
end

local _ = { update, onConfigChanged }

render()
