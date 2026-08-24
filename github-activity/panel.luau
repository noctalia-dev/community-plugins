--!nonstrict

local Activity = require("./lib/activity.luau")

local data = noctalia.state.get("data")
local status = noctalia.state.get("status") or "loading"
local stale = noctalia.state.get("stale") == true
local detail = noctalia.state.get("error") or ""
local selectedDate = nil
local selectedByKey = {}
local cachedHeatmap = nil
local gridColumns = {}
local gridLevels = {}
local gridDetails = {}
local gridWeek = 1
local gridWeekCount = 0
local gridPreparingDay = 1
local gridReady = false
local open = false
local tr = noctalia.tr
local cellColors = { "surface_variant", "primary/0.25", "primary/0.45", "primary/0.70", "primary" }

local function requestRefresh()
  noctalia.state.set("refresh_request", noctalia.nowMs())
end

local function splitTabs(value)
  local fields = {}
  for field in string.gmatch((value or "") .. "\t", "(.-)\t") do
    table.insert(fields, field)
  end
  return fields
end

local function resetGrid(source)
  cachedHeatmap = nil
  gridColumns = {}
  gridLevels = {}
  gridDetails = {}
  selectedByKey = {}
  selectedDate = nil
  gridWeek = 1
  gridPreparingDay = 1
  gridReady = source ~= nil and type(source.rows) == "table"
  gridWeekCount = 0
end

local function prepareGridDay()
  if not gridReady or data == nil or gridPreparingDay > 7 then
    return
  end

  local day = gridPreparingDay
  gridLevels[day] = Activity.rowLevels(data.rows[day])
  gridDetails[day] = splitTabs((data.details or {})[day])
  gridWeekCount = math.max(gridWeekCount, #gridLevels[day])
  gridPreparingDay = gridPreparingDay + 1
end

local function prepareGridColumns()
  if not gridReady or gridPreparingDay <= 7 then
    return
  end

  -- One native week per tick keeps every callback well below Noctalia's Luau
  -- budget. The completed tree is otherwise identical to the original UI.
  local lastWeek = math.min(gridWeek, gridWeekCount)
  while gridWeek <= lastWeek do
    local cells = {}
    for day = 1, 7 do
      local rawDetail = gridDetails[day][gridWeek] or ""
      local date, countText = string.match(rawDetail, "^([^|]+)|(%d+)$")
      if date ~= nil then
        local key = "day-" .. date
        selectedByKey[key] = { date = date, count = tonumber(countText) or 0 }
        table.insert(cells, ui.box({
          key = key,
          fill = cellColors[(gridLevels[day][gridWeek] or 0) + 1],
          radius = 2,
          width = 11,
          height = 11,
          onHover = "onDayHover",
        }))
      end
    end
    table.insert(gridColumns, ui.column({ key = "week-" .. tostring(gridWeek), gap = 2, align = "center" }, cells))
    gridWeek = gridWeek + 1
  end

  if gridWeek > gridWeekCount then
    cachedHeatmap = ui.row({ gap = 1, align = "start" }, gridColumns)
  end
end

resetGrid(data)

local function selectedDay()
  if selectedDate == nil then
    return nil
  end
  return selectedByKey["day-" .. selectedDate]
end

local function metric(label, value)
  return ui.column({ gap = 2, align = "center", flexGrow = 1 }, {
    ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
    ui.label({ text = tostring(value), fontSize = 20, fontWeight = "bold" }),
  })
end

local function statusText()
  if status == "loading" then
    return data ~= nil and tr("status.refreshing") or tr("status.loading")
  elseif status == "stale" then
    return tr("status.stale")
  elseif status == "missing_gh" then
    return tr("status.missing_gh")
  elseif status == "auth_error" then
    return tr("status.auth_error")
  elseif status == "request_error" then
    return tr("status.request_error")
  elseif status == "invalid_response" then
    return tr("status.invalid_response")
  end

  return stale and tr("status.stale") or ""
end

function render()
  local body = {
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = "brand-github", size = 19, color = "primary" }),
      ui.label({ text = tr("panel.title"), fontSize = 17, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("action.refresh"), onClick = "onRefreshClicked" }),
      ui.button({ glyph = "x", variant = "ghost", tooltip = tr("action.close"), onClick = "onCloseClicked" }),
    }),
  }

  local message = statusText()
  if message ~= "" then
    table.insert(body, ui.label({ text = message, fontSize = 11, color = status == "ready" and "on_surface_variant" or "primary", maxLines = 2 }))
  end

  if data == nil or cachedHeatmap == nil then
    local emptyText = data ~= nil and "Preparing interactive calendar…"
      or (detail ~= "" and statusText() or tr("status.no_data"))
    table.insert(body, ui.spacer({ flexGrow = 1 }))
    table.insert(body, ui.column({ gap = 12, align = "center" }, {
      ui.glyph({ name = "brand-github", size = 36, color = "on_surface_variant" }),
      ui.label({ text = emptyText, maxWidth = 520, textAlign = "center" }),
      ui.button({ text = tr("action.try_again"), glyph = "refresh", variant = "primary", onClick = "onRefreshClicked" }),
    }))
  else
    table.insert(body, ui.label({ text = tr("panel.year_total", { login = data.login, count = data.total }), fontSize = 12, color = "on_surface_variant" }))
    table.insert(body, ui.row({ justify = "center", align = "start" }, { cachedHeatmap }))

    local day = selectedDay()
    local selectedText = day ~= nil
      and tr("panel.day_total", { date = day.date, count = day.count })
      or "Hover a day to inspect its activity."
    table.insert(body, ui.label({ text = selectedText, fontSize = 11, color = "on_surface_variant", textAlign = "center" }))
    table.insert(body, ui.separator({ spacing = 2 }))
    table.insert(body, ui.row({ gap = 8, align = "center" }, {
      metric(tr("metric.today"), data.today),
      metric(tr("metric.current_streak"), tr("metric.days", { count = data.currentStreak })),
      metric(tr("metric.best_streak"), tr("metric.days", { count = data.bestStreak })),
    }))
    table.insert(body, ui.row({ justify = "end" }, {
      ui.button({ text = tr("action.open_profile"), glyph = "external-link", variant = "outline", onClick = "onOpenProfile" }),
    }))
  end

  panel.render(ui.column({ gap = 12, padding = 20, fill = "surface" }, body))
end

function onDayHover(hovered, key)
  if hovered == "true" then
    local day = selectedByKey[key]
    if day ~= nil then
      selectedDate = day.date
      render()
    end
  elseif selectedDate ~= nil and key == "day-" .. selectedDate then
    selectedDate = nil
    render()
  end
end

function onOpen(_context)
  open = true
  if data ~= nil and cachedHeatmap == nil then
    -- Panels only receive fast ticks after explicitly opting into frame ticks.
    -- This lets us build the original native, hoverable cell tree safely.
    panel.setWantsSecondTicks(true)
    panel.setNeedsFrameTick(true)
  end
  render()
end

function onClose()
  open = false
end

function onRefreshClicked()
  requestRefresh()
end

function onCloseClicked()
  panel.close()
end

function onOpenProfile()
  if data == nil then
    return
  end
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(tr("panel.title"), tr("status.missing_xdg_open"))
    return
  end
  noctalia.runAsync({ "xdg-open", "https://github.com/" .. data.login })
end

local function rerender(valueName, value)
  if valueName == "data" then
    data = value
    resetGrid(data)
    if open and data ~= nil then
      panel.setWantsSecondTicks(true)
      panel.setNeedsFrameTick(true)
    end
  elseif valueName == "status" then
    status = value or "loading"
  elseif valueName == "stale" then
    stale = value == true
  elseif valueName == "error" then
    detail = value or ""
  end
  if open then
    render()
  end
end

local function advanceGrid()
  if not gridReady or cachedHeatmap ~= nil then
    return
  end

  if gridPreparingDay <= 7 then
    prepareGridDay()
    return
  end

  prepareGridColumns()
  if cachedHeatmap ~= nil then
    panel.setWantsSecondTicks(false)
    panel.setNeedsFrameTick(false)
    if open then
      render()
    end
  end
end

function onFrameTick(_deltaMs)
  advanceGrid()
end

function update()
  -- Fallback for a compositor that coalesces frame callbacks while a panel is
  -- attached. Frame ticks normally complete this in about one second.
  advanceGrid()
end

noctalia.state.watch("data", function(value) rerender("data", value) end)
noctalia.state.watch("status", function(value) rerender("status", value) end)
noctalia.state.watch("stale", function(value) rerender("stale", value) end)
noctalia.state.watch("error", function(value) rerender("error", value) end)
