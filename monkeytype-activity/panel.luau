--!nonstrict

local Activity = require("./lib/activity.luau")
local Monkeytype = require("./lib/monkeytype.luau")
local Settings = require("./lib/settings.luau")

local data = noctalia.state.get("data")
local status = noctalia.state.get("status") or "loading"
local stale = noctalia.state.get("stale") == true
local open = false
local selectedView = "rolling"
local hoveredKey = nil
local dayInfoByKey = {}
local keyToPos = {}

local cachedHeatmap = nil
local cachedCalendar = nil
local gridColumns = {}
local gridLevels = {}
local gridDetails = {}
local gridWeek = 1
local gridWeekCount = 0
local gridPreparingDay = 1
local gridReady = false
local activeViewData = nil

local tr = noctalia.tr
local trp = noctalia.trp

local showToday = Settings.panelElementVisible(noctalia.getConfig("show_today"))
local showCurrentStreak = Settings.panelElementVisible(noctalia.getConfig("show_current_streak"))
local showBestStreak = Settings.panelElementVisible(noctalia.getConfig("show_best_streak"))
local showYearTotal = Settings.panelElementVisible(noctalia.getConfig("show_year_total"))
local showLastTest = Settings.panelElementVisible(noctalia.getConfig("show_last_test"))
local showProfileButton = Settings.panelElementVisible(noctalia.getConfig("show_profile_button"))
local calendarExpanded = Settings.calendarExpanded(showToday, showCurrentStreak, showBestStreak)

-- Slightly larger cells, and one minimalist weekday label so the grid breathes.
local calendarCellWidth = 11
local calendarCellHeight = 13
local calendarColumnGap = 2
local calendarRowGap = 3
local calendarHeaderHeight = 14
local weekdayLabelFontSize = 11
local weekdayLabelWidth = 28
local weeksPerTick = 2
local siteUrl = "https://monkeytype.com"

local function effectiveUsername()
  return Settings.username(noctalia.getConfig("profile_username"))
end

local function profileUrl()
  return Monkeytype.profileUrl(effectiveUsername())
end

local function hasApeKey()
  return Settings.hasApeKey(noctalia.getConfig("ape_key"))
end

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

local function resetGrid()
  cachedHeatmap = nil
  cachedCalendar = nil
  gridColumns = {}
  gridLevels = {}
  gridDetails = {}
  dayInfoByKey = {}
  keyToPos = {}
  gridWeek = 1
  gridPreparingDay = 1
  gridWeekCount = 0
  gridReady = activeViewData ~= nil and type(activeViewData.rows) == "table"
end

local function resolveView()
  if data == nil then
    activeViewData = nil
    return
  end
  activeViewData = Activity.buildView(data, selectedView)
  if activeViewData ~= nil and activeViewData.viewId ~= nil then
    -- Keep the selected ID ("rolling" or the year), not the view type: a
    -- generic "year" would match no button and reset the calendar on the
    -- next data update. An unavailable year falls back to rolling here.
    selectedView = activeViewData.viewId
  end
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
  return noctalia.formatTime(pattern, timestamp, "UTC")
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

  return ui.row({ gap = calendarColumnGap, align = "start" }, segments)
end

local function buildWeekdayLabels()
  local labeled = { [2] = true, [4] = true, [6] = true }
  local labels = {}
  for day = 1, 7 do
    local date = labeled[day] and representativeDateForDay(day) or nil
    table.insert(labels, ui.column({
      width = weekdayLabelWidth,
      height = calendarCellHeight,
      align = "center",
      justify = "center",
    }, {
      ui.label({
        text = date ~= nil and formatDate("%a", date) or "",
        fontSize = weekdayLabelFontSize,
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }))
  end
  return ui.column({ gap = calendarRowGap, align = "center" }, labels)
end

local function prepareGridRows()
  if not gridReady or activeViewData == nil or gridPreparingDay > 7 then
    return
  end

  while gridPreparingDay <= 7 do
    local day = gridPreparingDay
    gridLevels[day] = Activity.rowLevels(activeViewData.rows[day])
    gridDetails[day] = splitTabs((activeViewData.details or {})[day])
    if #gridLevels[day] > gridWeekCount then
      gridWeekCount = #gridLevels[day]
    end
    gridPreparingDay = gridPreparingDay + 1
  end
end

local function buildLegend()
  local swatches = {}
  for level = 0, 4 do
    table.insert(swatches, ui.box({
      width = calendarCellWidth,
      height = calendarCellHeight,
      radius = 2,
      fill = Activity.color(level),
    }))
  end
  return ui.row({ gap = 6, align = "center" }, {
    ui.label({ text = tr("panel.less"), fontSize = 10, color = "on_surface_variant" }),
    ui.row({ gap = 3, align = "center" }, swatches),
    ui.label({ text = tr("panel.more"), fontSize = 10, color = "on_surface_variant" }),
  })
end

local function buildWeekColumn(week)
  local cells = {}
  for day = 1, 7 do
    local rawDetail = (gridDetails[day] or {})[week] or ""
    local date, countText = string.match(rawDetail, "^([^|]+)|(%d+)$")
    if date ~= nil then
      local count = tonumber(countText) or 0
      local key = "day-" .. date
      dayInfoByKey[key] = { date = date, count = count }
      keyToPos[key] = { week = week, day = day }
      local hovered = hoveredKey == key
      table.insert(cells, ui.box({
        key = key,
        fill = Activity.color((gridLevels[day] or {})[week] or 0),
        radius = 2,
        width = calendarCellWidth,
        height = calendarCellHeight,
        borderWidth = 1,
        border = hovered and "on_surface_variant" or "on_surface/0",
        onHover = "onDayHover",
        tooltip = trp("panel.day_total", count, { date = formatDate("%Y-%m-%d", date), count = count }),
      }))
    else
      table.insert(cells, ui.box({
        width = calendarCellWidth,
        height = calendarCellHeight,
        fill = "on_surface/0",
        borderWidth = 1,
        border = "on_surface/0",
      }))
    end
  end
  return ui.column({ key = "week-" .. tostring(week), gap = calendarRowGap, align = "start" }, cells)
end

local function assembleCalendar()
  cachedHeatmap = ui.row({ gap = calendarColumnGap, align = "start" }, gridColumns)
  local gridBlock = ui.column({ gap = 6, align = "start" }, {
    buildMonthHeader(),
    cachedHeatmap,
  })
  local rightEdge = gridWeekCount * (calendarCellWidth + calendarColumnGap) - calendarColumnGap
  cachedCalendar = ui.column({ gap = 8, align = "start" }, {
    ui.row({ gap = 8, align = "end" }, {
      buildWeekdayLabels(),
      gridBlock,
    }),
    ui.row({ width = weekdayLabelWidth + 8 + rightEdge, justify = "end" }, {
      buildLegend(),
    }),
  })
end

local function buildGridImmediate()
  resolveView()
  resetGrid()
  if not gridReady then
    return
  end
  while gridPreparingDay <= 7 do
    local day = gridPreparingDay
    gridLevels[day] = Activity.rowLevels(activeViewData.rows[day])
    gridDetails[day] = splitTabs((activeViewData.details or {})[day])
    if #gridLevels[day] > gridWeekCount then
      gridWeekCount = #gridLevels[day]
    end
    gridPreparingDay = gridPreparingDay + 1
  end
  gridWeek = 1
  gridColumns = {}
  while gridWeek <= gridWeekCount do
    table.insert(gridColumns, buildWeekColumn(gridWeek))
    gridWeek = gridWeek + 1
  end
  assembleCalendar()
end

local function prepareGridColumns()
  if not gridReady or gridPreparingDay <= 7 then
    return
  end

  local lastWeek = math.min(gridWeek + weeksPerTick - 1, gridWeekCount)
  while gridWeek <= lastWeek do
    table.insert(gridColumns, buildWeekColumn(gridWeek))
    gridWeek = gridWeek + 1
  end

  if gridWeek > gridWeekCount then
    assembleCalendar()
  end
end

local function viewTotalText()
  if not showYearTotal or activeViewData == nil then
    return ""
  end
  local label
  if selectedView == "rolling" then
    label = tr("panel.range_last_12_months")
  else
    local first = activeViewData.coveredFirstDate
    local last = activeViewData.coveredLastDate
    if type(first) == "string" and type(last) == "string" then
      label = first .. " – " .. last
    else
      label = selectedView
    end
  end
  return tr("panel.view_total", { count = activeViewData.windowTotal, range = label })
end

local function buildViewSelector()
  local years = Activity.availableYears(data and data.counts, data and data.lastTimestamp)
  local options = { "rolling" }
  for _, y in ipairs(years) do
    table.insert(options, y)
  end

  local total = viewTotalText()
  local children = {}

  if #options > 1 then
    local buttons = {}
    for _, opt in ipairs(options) do
      local value = opt
      local isSelected = selectedView == value
      local text = value == "rolling" and tr("panel.last_12_months") or value
      table.insert(buttons, ui.button({
        key = "view-" .. value,
        text = text,
        variant = isSelected and "primary" or "ghost",
        controlSize = "sm",
        onClick = function()
          onViewClicked(value)
        end,
      }))
    end
    table.insert(children, ui.row({ gap = 4, align = "center" }, buttons))
  else
    -- Single view: keep the row compact when there is nothing to switch.
    table.insert(children, ui.spacer({ width = 0 }))
  end

  if total ~= "" then
    table.insert(children, ui.spacer({ flexGrow = 1 }))
    table.insert(children, ui.label({ text = total, fontSize = 11, color = "on_surface_variant", textAlign = "end" }))
  end

  return ui.row({ gap = 6, align = "center" }, children)
end

resolveView()
resetGrid()

local function metric(label, value, visual)
  return ui.column({ gap = 8, align = "center", flexGrow = 1 }, {
    ui.label({ text = label, fontSize = 12, color = "on_surface_variant" }),
    ui.label({ text = tostring(value), fontSize = 25, fontWeight = "bold" }),
    visual,
  })
end

local function statusText()
  if data == nil then
    return ""
  end

  if status == "loading" then
    return tr("status.refreshing")
  elseif status == "stale" then
    return tr("status.stale")
  elseif status == "no_key" then
    return tr("status.no_key")
  elseif status == "invalid_key" then
    return tr("status.invalid_key")
  elseif status == "inactive_key" then
    return tr("status.inactive_key")
  elseif status == "auth_error" then
    return tr("status.auth_error")
  elseif status == "rate_limited" then
    return tr("status.rate_limited")
  elseif status == "no_activity" then
    return tr("status.no_activity")
  elseif status == "request_error" then
    return tr("status.request_error")
  elseif status == "invalid_response" then
    return tr("status.invalid_response")
  end

  return stale and tr("status.stale") or ""
end

local function emptyStateText()
  if data ~= nil then
    return tr("panel.preparing")
  elseif status == "no_key" then
    return tr("status.no_key")
  elseif status == "invalid_key" then
    return tr("status.invalid_key")
  elseif status == "inactive_key" then
    return tr("status.inactive_key")
  elseif status == "auth_error" then
    return tr("status.auth_error")
  elseif status == "no_activity" then
    return tr("status.no_activity")
  elseif status == "rate_limited" then
    return tr("status.rate_limited")
  end

  return tr("status.unavailable")
end

local function refreshSchedule()
  if data == nil then
    return ""
  end
  return tr("status.refresh_schedule", {
    time = noctalia.formatTime(noctalia.timeFormat(), math.floor(data.fetchedAt)),
    interval = Settings.refreshIntervalMinutes(noctalia.getConfig("refresh_interval_minutes")),
  })
end

local function modeText()
  local mode = data ~= nil and data.lastMode or nil
  if mode == nil then
    return nil
  end

  if mode == "time" and data.lastMode2 ~= nil then
    return tr("panel.mode.time", { value = data.lastMode2 })
  elseif mode == "words" and data.lastMode2 ~= nil then
    return tr("panel.mode.words", { value = data.lastMode2 })
  elseif mode == "quote" then
    return tr("panel.mode.quote")
  elseif mode == "zen" then
    return tr("panel.mode.zen")
  elseif mode == "custom" then
    return tr("panel.mode.custom")
  end

  return mode
end

local function lastTestText()
  if data == nil or data.lastWpm == nil then
    return ""
  end

  local mode = modeText()
  if mode == nil then
    return tr("panel.last_test_plain", { wpm = data.lastWpm, accuracy = data.lastAcc or "—" })
  end

  return tr("panel.last_test", {
    wpm = data.lastWpm,
    accuracy = data.lastAcc or "—",
    mode = mode,
  })
end

local function openUrl(url)
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(tr("panel.title"), tr("status.missing_xdg_open"))
    return
  end
  noctalia.runAsync({ "xdg-open", url })
end

function render()
  local root = {
    ui.row({ align = "center", gap = 12, paddingH = 18, paddingV = 10 }, {
      ui.glyph({ name = "keyboard", size = 25, color = "on_surface" }),
      ui.label({ text = tr("panel.title"), fontSize = 19, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("action.refresh"), onClick = "onRefreshClicked" }),
    }),
    ui.separator({ thickness = 1, color = "outline_variant/0.35" }),
  }
  local body = {}

  local message = statusText()
  if message ~= "" then
    table.insert(body, ui.label({
      text = message,
      fontSize = 11,
      color = status == "ready" and "on_surface_variant" or "primary",
      maxLines = 2,
    }))
  end

  if data == nil or cachedCalendar == nil then
    local emptyText = emptyStateText()
    local actions = {
      ui.button({ text = tr("action.try_again"), glyph = "refresh", variant = "primary", onClick = "onRefreshClicked" }),
    }
    if status == "invalid_key" or status == "inactive_key" then
      table.insert(actions, 1, ui.button({
        text = tr("action.open_ape_keys"),
        glyph = "external-link",
        variant = "outline",
        onClick = "onOpenApeKeys",
      }))
    end
    if not hasApeKey() or status == "invalid_key" or status == "inactive_key" then
      table.insert(actions, 1, ui.button({
        text = tr("action.open_settings"),
        glyph = "settings",
        variant = "outline",
        onClick = "onOpenSettings",
      }))
    end
    table.insert(body, ui.column({ gap = 12, align = "center" }, {
      ui.glyph({ name = "keyboard", size = 36, color = "on_surface_variant" }),
      ui.label({ text = emptyText, maxWidth = 520, textAlign = "center" }),
      ui.row({ gap = 10, align = "center", justify = "center" }, actions),
    }))
  else
    table.insert(body, buildViewSelector())
    -- Keep the calendar slightly off the right edge instead of flush-centered.
    table.insert(body, ui.row({ justify = "start", align = "start" }, {
      cachedCalendar,
      ui.spacer({ width = 8 }),
    }))

    local infoLine = refreshSchedule()
    if hoveredKey ~= nil and dayInfoByKey[hoveredKey] ~= nil then
      local d = dayInfoByKey[hoveredKey]
      infoLine = trp("panel.day_total", d.count, { date = formatDate("%Y-%m-%d", d.date), count = d.count })
    end
    table.insert(body, ui.label({ text = infoLine, height = 12, fontSize = 10, color = hoveredKey ~= nil and "on_surface" or "on_surface_variant", textAlign = "center" }))

    if showLastTest then
      local lastTest = lastTestText()
      if lastTest ~= "" then
        table.insert(body, ui.label({ text = lastTest, height = 12, fontSize = 10, color = "on_surface_variant", textAlign = "center" }))
      end
    end

    local function activityBlocks(filled, total)
      local blocks = {}
      for i = 1, total do
        table.insert(blocks, ui.box({
          width = 9,
          height = 9,
          radius = 2,
          fill = i <= filled and "primary" or "surface_container",
        }))
      end
      return ui.row({ gap = 3, align = "center", justify = "center" }, blocks)
    end

    -- Bottom row keeps three core metrics; the view total lives above the grid.
    local metrics = {}
    if showToday then
      table.insert(metrics, metric(tr("metric.today"), data.today, activityBlocks(data.today > 0 and 1 or 0, 1)))
    end
    if showCurrentStreak then
      local s = data.currentStreak or 0
      local shown = math.min(s, 12)
      table.insert(metrics, metric(
        tr("metric.current_streak"),
        s,
        activityBlocks(shown, math.max(1, shown))
      ))
    end
    if showBestStreak then
      local b = data.bestStreak or 0
      table.insert(metrics, metric(tr("metric.best_streak"), b, activityBlocks(math.min(b, 12), 12)))
    end

    if #metrics > 0 then
      local metricChildren = {}
      for index, item in ipairs(metrics) do
        if index > 1 then
          table.insert(metricChildren, ui.separator({ orientation = "vertical", thickness = 1, color = "outline_variant/0.35" }))
        end
        table.insert(metricChildren, item)
      end
      table.insert(body, ui.spacer({ height = 4 }))
      table.insert(body, ui.separator({ thickness = 1, color = "outline_variant/0.35" }))
      table.insert(body, ui.spacer({ height = 2 }))
      table.insert(body, ui.row({ gap = 14, align = "stretch", paddingV = 4 }, metricChildren))
    end
  end

  local centerReadyContent = calendarExpanded and data ~= nil and cachedCalendar ~= nil
  table.insert(root, ui.column({
    gap = centerReadyContent and 10 or 12,
    paddingH = 18,
    paddingV = 16,
    flexGrow = 1,
    align = "stretch",
    justify = "start",
  }, body))

  local pUrl = profileUrl()
  if showProfileButton and hasApeKey()
    and status ~= "invalid_key" and status ~= "inactive_key" and status ~= "auth_error" then
    table.insert(root, ui.separator({ thickness = 1, color = "outline_variant/0.35" }))
    table.insert(root, ui.row({ justify = "end", paddingH = 14, paddingV = 8 }, {
      ui.button({
        text = pUrl ~= nil and tr("action.open_profile") or tr("action.open_site"),
        glyph = "external-link",
        variant = "outline",
        onClick = "onOpenProfile",
      }),
    }))
  end

  -- Transparent panel background so the shell's border/context shows through.
  panel.render(ui.column({ gap = 0, flexGrow = 1, align = "stretch" }, root))
end

local function refreshHoveredColumns(oldKey, newKey)
  if cachedHeatmap == nil or gridWeekCount == 0 then
    return false
  end

  local weeks = {}
  local function mark(k)
    local pos = keyToPos[k]
    if pos ~= nil and pos.week ~= nil then
      weeks[pos.week] = true
    end
  end
  mark(oldKey)
  mark(newKey)

  local changed = false
  for week in pairs(weeks) do
    if week >= 1 and week <= #gridColumns then
      gridColumns[week] = buildWeekColumn(week)
      changed = true
    end
  end

  if changed then
    assembleCalendar()
  end
  return changed
end

function onDayHover(hovered, key)
  if hovered == "true" then
    if hoveredKey ~= key then
      local oldKey = hoveredKey
      hoveredKey = key
      if open and data ~= nil then
        if not refreshHoveredColumns(oldKey, key) then
          buildGridImmediate()
        end
        render()
      end
    end
  elseif hoveredKey == key then
    local oldKey = hoveredKey
    hoveredKey = nil
    if open and data ~= nil then
      if not refreshHoveredColumns(oldKey, nil) then
        buildGridImmediate()
      end
      render()
    end
  end
end

function onViewClicked(view)
  if view == selectedView then
    return
  end
  selectedView = view
  hoveredKey = nil
  resolveView()
  resetGrid()
  if open and data ~= nil then
    -- Building all 53 columns at once blows past the panel's per-callback CPU
    -- budget, so let the frame tick fill the grid a couple of weeks at a time
    -- exactly like the first open does.
    panel.setWantsSecondTicks(true)
    panel.setNeedsFrameTick(true)
    render()
  end
end

function onOpen(_context)
  open = true
  resolveView()
  if data ~= nil and cachedHeatmap == nil then
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

function onOpenSettings()
  noctalia.openSettings()
end

function onOpenProfile()
  openUrl(profileUrl() or siteUrl)
end

function onOpenApeKeys()
  openUrl(Monkeytype.APE_KEYS_URL)
end

local function rerender(valueName, value)
  if valueName == "data" then
    data = value
    hoveredKey = nil
    resolveView()
    resetGrid()
    if open and data ~= nil then
      panel.setWantsSecondTicks(true)
      panel.setNeedsFrameTick(true)
    end
  elseif valueName == "status" then
    status = value or "loading"
  elseif valueName == "stale" then
    stale = value == true
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
    prepareGridRows()
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
  advanceGrid()
end

noctalia.state.watch("data", function(value) rerender("data", value) end)
noctalia.state.watch("status", function(value) rerender("status", value) end)
noctalia.state.watch("stale", function(value) rerender("stale", value) end)
