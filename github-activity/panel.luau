--!nonstrict

local Activity = require("./lib/activity.luau")
local Settings = require("./lib/settings.luau")

local data = noctalia.state.get("data")
local status = noctalia.state.get("status") or "loading"
local stale = noctalia.state.get("stale") == true
local detail = noctalia.state.get("error") or ""
local selectedDate = nil
local selectedByKey = {}
local cachedHeatmap = nil
local cachedCalendar = nil
local gridColumns = {}
local gridLevels = {}
local gridDetails = {}
local gridWeek = 1
local gridWeekCount = 0
local gridPreparingDay = 1
local gridReady = false
local open = false
local tr = noctalia.tr
local showToday = Settings.panelElementVisible(noctalia.getConfig("show_today"))
local showCurrentStreak = Settings.panelElementVisible(noctalia.getConfig("show_current_streak"))
local showBestStreak = Settings.panelElementVisible(noctalia.getConfig("show_best_streak"))
local showYearTotal = Settings.panelElementVisible(noctalia.getConfig("show_year_total"))
local showProfileButton = Settings.panelElementVisible(noctalia.getConfig("show_profile_button"))
local calendarExpanded = Settings.calendarExpanded(showToday, showCurrentStreak, showBestStreak)
local calendarCellWidth = 10
local calendarCellHeight = 12
local calendarColumnGap = 1
local calendarRowGap = calendarExpanded and 4 or 3
local calendarHeaderHeight = calendarExpanded and 14 or 12
local weekdayLabelFontSize = calendarExpanded and 12 or 11

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
  cachedCalendar = nil
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

local function detailDate(day, week)
  local rawDetail = (gridDetails[day] or {})[week] or ""
  return string.match(rawDetail, "^([^|]+)|")
end

local function formatDate(pattern, date)
  local timestamp = Activity.dateTimestamp(date)
  if timestamp == nil then
    return ""
  end
  return noctalia.formatTime(pattern, timestamp)
end

local function representativeDateForWeek(week)
  local preferredDays = { 4, 1, 2, 3, 5, 6, 7 }
  for _, day in ipairs(preferredDays) do
    local date = detailDate(day, week)
    if date ~= nil then
      return date
    end
  end
  return nil
end

local function representativeDateForDay(day)
  for week = 1, gridWeekCount do
    local date = detailDate(day, week)
    if date ~= nil then
      return date
    end
  end
  return nil
end

local function buildMonthHeader()
  local segments = {}
  local segmentKey = nil
  local segmentDate = nil
  local segmentWeeks = 0

  local function appendSegment()
    if segmentKey == nil or segmentWeeks == 0 then
      return
    end
    table.insert(segments, ui.column({
      width = segmentWeeks * (calendarCellWidth + calendarColumnGap) - calendarColumnGap,
      height = calendarHeaderHeight,
      align = "center",
      justify = "center",
    }, {
      ui.label({
        text = segmentWeeks >= 2 and formatDate("%b", segmentDate) or "",
        fontSize = 10,
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }))
  end

  for week = 1, gridWeekCount do
    local date = representativeDateForWeek(week)
    local monthKey = date ~= nil and string.sub(date, 1, 7) or nil
    if segmentKey ~= nil and monthKey ~= nil and monthKey ~= segmentKey then
      appendSegment()
      segmentWeeks = 0
    end
    segmentKey = monthKey or segmentKey
    segmentDate = date or segmentDate
    segmentWeeks = segmentWeeks + 1
  end
  appendSegment()

  return ui.row({ gap = calendarColumnGap, align = "center" }, segments)
end

local function buildWeekdayLabels()
  local labels = {}
  for day = 1, 7 do
    local date = (day == 2 or day == 4 or day == 6) and representativeDateForDay(day) or nil
    table.insert(labels, ui.column({
      width = 30,
      height = calendarCellHeight,
      align = "end",
      justify = "center",
    }, {
      ui.label({
        text = date ~= nil and formatDate("%a", date) or "",
        fontSize = weekdayLabelFontSize,
        color = "on_surface_variant",
        textAlign = "end",
      }),
    }))
  end
  return ui.column({ gap = calendarRowGap, align = "end" }, labels)
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
  -- budget while preserving individual hover targets for every day.
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
          fill = Activity.color(gridLevels[day][gridWeek]),
          radius = 2,
          width = calendarCellWidth,
          height = calendarCellHeight,
          onHover = "onDayHover",
        }))
      end
    end
    table.insert(gridColumns, ui.column({ key = "week-" .. tostring(gridWeek), gap = calendarRowGap, align = "center" }, cells))
    gridWeek = gridWeek + 1
  end

  if gridWeek > gridWeekCount then
    cachedHeatmap = ui.row({ gap = calendarColumnGap, align = "start" }, gridColumns)
    cachedCalendar = ui.row({ gap = 10, align = "end", justify = "center" }, {
      buildWeekdayLabels(),
      ui.column({ gap = 6, align = "start" }, {
        buildMonthHeader(),
        cachedHeatmap,
      }),
    })
  end
end

resetGrid(data)

local function selectedDay()
  if selectedDate == nil then
    return nil
  end
  return selectedByKey["day-" .. selectedDate]
end

local function activityBlocks(filled, total)
  local blocks = {}
  for index = 1, total do
    table.insert(blocks, ui.box({
      width = 9,
      height = 9,
      radius = 2,
      fill = index <= filled and "primary" or "surface_variant",
    }))
  end
  return ui.row({ gap = 3, align = "center", justify = "center" }, blocks)
end

local function metric(label, value, visual)
  return ui.column({ gap = 6, align = "center", flexGrow = 1 }, {
    ui.label({ text = label, fontSize = 12, color = "on_surface_variant" }),
    ui.label({ text = tostring(value), fontSize = 25, fontWeight = "bold" }),
    visual,
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

local function refreshSchedule()
  return tr("status.refresh_schedule", {
    time = os.date("%H:%M", math.floor(data.fetchedAt)),
    interval = Settings.refreshIntervalMinutes(noctalia.getConfig("refresh_interval_minutes")),
  })
end

function render()
  local root = {
    ui.row({ align = "center", gap = 12, paddingH = 18, paddingV = 10 }, {
      ui.glyph({ name = "brand-github", size = 25, color = "on_surface" }),
      ui.label({ text = tr("panel.title"), fontSize = 19, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("action.refresh"), onClick = "onRefreshClicked" }),
    }),
    ui.separator({ thickness = 1, color = "outline/0.35" }),
  }
  local body = {}

  local message = statusText()
  if message ~= "" then
    table.insert(body, ui.label({ text = message, fontSize = 11, color = status == "ready" and "on_surface_variant" or "primary", maxLines = 2 }))
  end

  if data == nil or cachedCalendar == nil then
    local emptyText = data ~= nil and tr("panel.preparing")
      or (detail ~= "" and statusText() or tr("status.no_data"))
    table.insert(body, ui.spacer({ flexGrow = 1 }))
    table.insert(body, ui.column({ gap = 12, align = "center" }, {
      ui.glyph({ name = "brand-github", size = 36, color = "on_surface_variant" }),
      ui.label({ text = emptyText, maxWidth = 520, textAlign = "center" }),
      ui.button({ text = tr("action.try_again"), glyph = "refresh", variant = "primary", onClick = "onRefreshClicked" }),
    }))
  else
    table.insert(body, cachedCalendar)

    local day = selectedDay()
    local selectedText = day ~= nil
      and tr("panel.day_total", { date = day.date, count = day.count })
      or (showYearTotal and tr("panel.year_total", { login = data.login, count = data.total }) or "")
    table.insert(body, ui.label({ text = selectedText, height = 14, fontSize = 11, color = "on_surface_variant", textAlign = "center" }))
    table.insert(body, ui.label({ text = refreshSchedule(), height = 12, fontSize = 10, color = "on_surface_variant", textAlign = "center" }))

    local metrics = {}
    if showToday then
      table.insert(metrics, metric(tr("metric.today"), data.today, activityBlocks(data.today > 0 and 1 or 0, 1)))
    end
    if showCurrentStreak then
      table.insert(metrics, metric(
        tr("metric.current_streak"),
        data.currentStreak,
        activityBlocks(math.min(data.currentStreak, 12), math.max(1, math.min(data.currentStreak, 12)))
      ))
    end
    if showBestStreak then
      table.insert(metrics, metric(tr("metric.best_streak"), data.bestStreak, activityBlocks(math.min(data.bestStreak, 12), 12)))
    end

    if #metrics > 0 then
      local metricChildren = {}
      for index, item in ipairs(metrics) do
        if index > 1 then
          table.insert(metricChildren, ui.separator({ orientation = "vertical", thickness = 1, color = "outline/0.35" }))
        end
        table.insert(metricChildren, item)
      end
      table.insert(body, ui.separator({ thickness = 1, color = "outline/0.35" }))
      table.insert(body, ui.row({ gap = 14, align = "stretch" }, metricChildren))
    end
  end

  local centerReadyContent = calendarExpanded and data ~= nil and cachedCalendar ~= nil
  table.insert(root, ui.column({
    gap = centerReadyContent and 8 or 12,
    paddingH = 18,
    paddingV = 14,
    fill = "surface",
    flexGrow = 1,
    justify = centerReadyContent and "center" or "start",
  }, body))
  if data ~= nil and cachedCalendar ~= nil and showProfileButton then
    table.insert(root, ui.separator({ thickness = 1, color = "outline/0.35" }))
    table.insert(root, ui.row({ justify = "end", paddingH = 14, paddingV = 10 }, {
      ui.button({ text = tr("action.open_profile"), glyph = "external-link", variant = "outline", onClick = "onOpenProfile" }),
    }))
  end

  panel.render(ui.column({ gap = 0, fill = "surface", flexGrow = 1, align = "stretch" }, root))
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
