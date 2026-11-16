--!nonstrict
-- GitHub Contributions desktop widget: a [[desktop_widget]] client of the
-- shared sync service.
--
-- Minimalist by design: a header, the annual contribution heatmap, and one
-- footer line. No metric columns, no profile button, no schedule line. The
-- footer shows the hovered day's detail while hovering, otherwise the annual
-- summary (total + current streak).
--
-- The widget owns no fetching logic: it reflects the service's state
-- (noctalia.state) and drives it with a refresh command. The sync service
-- fetches the contribution calendar via GitHub CLI and publishes it on
-- noctalia.state; this entry only renders it.
--
-- Desktop widgets are background layer-shell surfaces that cannot take
-- keyboard focus, so there is no text input here (none is needed: the
-- calendar is read-only, with a refresh button). Tooltips do not show on
-- desktop widgets, so the hovered day's detail is rendered as a visible
-- label in the footer, not as a tooltip.
--
-- The heatmap grid is built incrementally (one weekday row per tick, then
-- one week-column per tick) to stay below Noctalia's Luau per-call budget,
-- the same pattern as the github-activity panel this widget's data layer is
-- derived from (alexmnrs/github-activity, MIT).
--
--   desktopWidget.render(tree)         declarative UI tree
--   noctalia.getConfig(key)            per-widget styling (color, cell size)
--   noctalia.state.set(key, value)     send commands to the service
--   noctalia.state.watch(key, fn)      react to state changes
--   button onClick = "name"            calls a plugin global

local Activity = require("./lib/activity.luau")
local Settings = require("./lib/settings.luau")

local data = noctalia.state.get("data")
local status = noctalia.state.get("status") or "loading"
local stale = noctalia.state.get("stale") == true
local detail = noctalia.state.get("error") or ""
local selectedYear = noctalia.state.get("year") or "last12"
local selectedDate = nil
local pinnedDate = nil
local selectedByKey = {}
local cachedHeatmap = nil
local cachedCalendar = nil
local cachedWrap = nil
local gridColumns = {}
local gridLevels = {}
local gridDetails = {}
local gridWeek = 1
local gridWeekCount = 0
local gridPreparingDay = 1
local gridReady = false
local tr = noctalia.tr
local accentColor = noctalia.getConfig("color") or "#39d353"
local cellSize = Settings.cellSize(noctalia.getConfig("cell_size"))
local calendarCellWidth = cellSize
local calendarCellHeight = cellSize + 2
local calendarColumnGap = 1
local calendarRowGap = 3
local calendarHeaderHeight = 12
local weekdayLabelFontSize = 11

-- Heatmap ramp derived from the configured accent color. A palette role
-- (e.g. "primary") uses alpha variants; a custom hex color is darkened by
-- scaling its RGB channels for the lower levels.
local function levelColor(level)
  if level <= 0 then
    return "surface_container"
  end
  if string.sub(accentColor, 1, 1) == "#" then
    local r = tonumber(string.sub(accentColor, 2, 3), 16)
    local g = tonumber(string.sub(accentColor, 4, 5), 16)
    local b = tonumber(string.sub(accentColor, 6, 7), 16)
    if r ~= nil and g ~= nil and b ~= nil then
      local factors = { 0.35, 0.55, 0.8, 1.0 }
      local f = factors[level] or 1.0
      return string.format("#%02x%02x%02x",
        math.floor(r * f + 0.5), math.floor(g * f + 0.5), math.floor(b * f + 0.5))
    end
    return Activity.color(level)
  end
  if level >= 4 then
    return accentColor
  end
  local alphas = { "0.25", "0.45", "0.70" }
  return accentColor .. "/" .. alphas[level]
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

local function resetGrid(source)
  cachedHeatmap = nil
  cachedCalendar = nil
  cachedWrap = nil
  gridColumns = {}
  gridLevels = {}
  gridDetails = {}
  selectedByKey = {}
  selectedDate = nil
  pinnedDate = nil
  gridWeek = 1
  gridPreparingDay = 1
  gridReady = source ~= nil and type(source.rows) == "table"
  gridWeekCount = 0
end

local function detailDate(day, week)
  local rawDetail = (gridDetails[day] or {})[week] or ""
  return string.match(rawDetail, "^([^|]+)|")
end

-- English month and weekday names. The widget must not depend on the
-- process LC_TIME locale (which renders Indonesian names on this system),
-- so these are hardcoded in English and the weekday is computed with
-- Zeller's congruence instead of a locale-aware date formatter.
local ENGLISH_MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local ENGLISH_WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function parseDate(date)
  local y, m, d = string.match(date or "", "^(%d%d%d%d)-(%d%d)-(%d%d)$")
  return tonumber(y), tonumber(m), tonumber(d)
end

-- Zeller's congruence (Gregorian). Returns 1 = Sunday .. 7 = Saturday.
local function weekdayNumber(year, month, day)
  if year == nil or month == nil or day == nil then
    return nil
  end
  local m = month
  local y = year
  if m <= 2 then
    m = m + 12
    y = y - 1
  end
  local K = y % 100
  local J = math.floor(y / 100)
  local h = (day + math.floor(13 * (m + 1) / 5) + K + math.floor(K / 4) + math.floor(J / 4) - 2 * J) % 7
  -- h: 0 = Saturday, 1 = Sunday, 2 = Monday, ..., 6 = Friday.
  return (h + 6) % 7 + 1
end

local function monthAbbr(date)
  local _, month = parseDate(date)
  if month == nil then
    return ""
  end
  return ENGLISH_MONTHS[month] or ""
end

local function weekdayAbbr(date)
  local year, month, day = parseDate(date)
  local w = weekdayNumber(year, month, day)
  if w == nil then
    return ""
  end
  return ENGLISH_WEEKDAYS[w] or ""
end

-- "2026-11-13" -> "Nov 13".
local function formatMonthDay(date)
  local _, month, day = parseDate(date)
  if month == nil or day == nil then
    return date or ""
  end
  return ENGLISH_MONTHS[month] .. " " .. tostring(day)
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

-- Month labels for one block of weeks (startWeek..endWeek). A wrapped year
-- gives each block its own header covering only the months in that block.
local function buildMonthHeaderForRange(startWeek, endWeek)
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
        text = segmentWeeks >= 2 and monthAbbr(segmentDate) or "",
        fontSize = 10,
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }))
  end

  for week = startWeek, endWeek do
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
        text = date ~= nil and weekdayAbbr(date) or "",
        fontSize = weekdayLabelFontSize,
        color = "on_surface_variant",
        textAlign = "end",
      }),
    }))
  end
  return ui.column({ gap = calendarRowGap, align = "end" }, labels)
end

-- Group the built week-columns into stacked blocks per the wrap setting
-- and rebuild the two cached trees from them. A year is 53 week-columns in
-- one row, which is why the widget is a long strip; wrapping splits it into
-- 2/3/4 blocks so the widget is narrower and taller instead.
-- Grouping only rearranges already-built column nodes, so it is cheap and
-- safe to rerun when the wrap setting changes, unlike the incremental cell
-- build (which stays in prepareGridColumns).
local function layoutGrid()
  local wrap = Settings.wrapBlocks(noctalia.getConfig("wrap"))
  cachedWrap = wrap
  if #gridColumns == 0 then
    cachedHeatmap = nil
    cachedCalendar = nil
    return
  end

  local blockWeeks = math.ceil(gridWeekCount / wrap)
  local heatmapBlocks = {}
  local calendarBlocks = {}
  for block = 1, wrap do
    local startWeek = (block - 1) * blockWeeks + 1
    if startWeek > gridWeekCount then
      break
    end
    local endWeek = math.min(block * blockWeeks, gridWeekCount)
    local blockColumns = {}
    for week = startWeek, endWeek do
      table.insert(blockColumns, gridColumns[week])
    end
    local blockRow = ui.row({ gap = calendarColumnGap, align = "start" }, blockColumns)
    table.insert(heatmapBlocks, blockRow)
    table.insert(calendarBlocks, ui.row({ gap = 10, align = "end", justify = "center" }, {
      buildWeekdayLabels(),
      ui.column({ gap = 6, align = "start" }, {
        buildMonthHeaderForRange(startWeek, endWeek),
        blockRow,
      }),
    }))
  end

  if #heatmapBlocks == 1 then
    cachedHeatmap = heatmapBlocks[1]
    cachedCalendar = calendarBlocks[1]
  else
    cachedHeatmap = ui.column({ gap = 10, align = "start" }, heatmapBlocks)
    cachedCalendar = ui.column({ gap = 14, align = "start" }, calendarBlocks)
  end
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
          fill = levelColor(gridLevels[day][gridWeek]),
          radius = 2,
          width = calendarCellWidth,
          height = calendarCellHeight,
          onHover = "onDayHover",
          onClick = "onDayClick",
        }))
      end
    end
    table.insert(gridColumns, ui.column({ key = "week-" .. tostring(gridWeek), gap = calendarRowGap, align = "center" }, cells))
    gridWeek = gridWeek + 1
  end

  if gridWeek > gridWeekCount then
    layoutGrid()
  end
end

resetGrid(data)

local function selectedDay()
  if selectedDate == nil then
    return nil
  end
  return selectedByKey["day-" .. selectedDate]
end

local function pinnedDay()
  if pinnedDate == nil then
    return nil
  end
  return selectedByKey["day-" .. pinnedDate]
end

-- The footer shows the hovered day while hovering, otherwise the pinned day,
-- otherwise the annual summary. A click pins (or unpins) a day so its detail
-- stays in the footer after the pointer leaves.
local function footerDay()
  return selectedDay() or pinnedDay()
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
  -- The wrap setting changes the grid layout, not the data, so a change in
  -- the editor re-groups the already-built week-columns instead of
  -- rebuilding (or refetching) anything.
  if data ~= nil and cachedHeatmap ~= nil and cachedWrap ~= Settings.wrapBlocks(noctalia.getConfig("wrap")) then
    layoutGrid()
  end

  -- Heatmap-only mode: just the contribution grid, no header, no footer,
  -- and no month/weekday labels. The grid alone (cachedHeatmap) is rendered,
  -- not the full calendar (cachedCalendar) which carries the labels.
  local heatmapOnly = noctalia.getConfig("heatmap_only") == true

  if heatmapOnly and data ~= nil and cachedHeatmap ~= nil then
    desktopWidget.render(ui.column({
      gap = 0,
      fill = "surface",
      flexGrow = 1,
      align = "center",
      justify = "center",
      paddingH = 16,
      paddingV = 12,
    }, { cachedHeatmap }))
    return
  end

  local root = {
    ui.row({ align = "center", gap = 10, paddingH = 16, paddingV = 8 }, {
      ui.glyph({ name = "brand-github", size = 20, color = "on_surface" }),
      ui.label({ text = tr("desktop.title"), fontSize = 17, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefreshClicked" }),
    }),
    ui.separator({ thickness = 1, color = "outline_variant/0.35" }),
  }
  local body = {}

  local message = statusText()
  if message ~= "" then
    table.insert(body, ui.label({ text = message, fontSize = 11, color = status == "ready" and "on_surface_variant" or "primary", maxLines = 2 }))
  end

  if data == nil or cachedCalendar == nil then
    local emptyText = data ~= nil and tr("desktop.preparing")
      or (detail ~= "" and statusText() or tr("status.no_data"))
    table.insert(body, ui.spacer({ flexGrow = 1 }))
    table.insert(body, ui.column({ gap = 12, align = "center" }, {
      ui.glyph({ name = "brand-github", size = 36, color = "on_surface_variant" }),
      ui.label({ text = emptyText, maxWidth = 520, textAlign = "center" }),
      ui.button({ text = tr("action.try_again"), glyph = "refresh", variant = "primary", onClick = "onRefreshClicked" }),
    }))
  else
    table.insert(body, cachedCalendar)

    -- One footer line: the hovered day while hovering, otherwise the pinned
    -- day, otherwise the summary. A specific year shows the year instead of
    -- the "last year" streak summary.
    local day = footerDay()
    local isPinned = day ~= nil and selectedDay() == nil and pinnedDay() ~= nil
    local footerText
    if day ~= nil then
      footerText = tr("desktop.day_total", { date = formatMonthDay(day.date), count = day.count })
    elseif selectedYear ~= "last12" then
      footerText = tr("desktop.summary_year", { login = data.login, count = data.total, year = selectedYear })
    else
      footerText = tr("desktop.summary", { login = data.login, count = data.total, streak = data.currentStreak })
    end
    if isPinned then
      table.insert(body, ui.row({ gap = 6, align = "center", justify = "center" }, {
        ui.glyph({ name = "pinned", size = 12, color = "on_surface_variant" }),
        ui.label({ text = footerText, height = 14, fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
      }))
    else
      table.insert(body, ui.label({ text = footerText, height = 14, fontSize = 11, color = "on_surface_variant", textAlign = "center" }))
    end
  end

  table.insert(root, ui.column({
    gap = 10,
    paddingH = 16,
    paddingV = 12,
    fill = "surface",
    flexGrow = 1,
    justify = "start",
  }, body))

  desktopWidget.render(ui.column({ gap = 0, fill = "surface", flexGrow = 1, align = "stretch" }, root))
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

-- Click a day to pin its detail in the footer; click it again to unpin.
-- The pinned day stays after the pointer leaves, until another day is
-- pinned or the same day is clicked again.
function onDayClick(key)
  local day = selectedByKey[key]
  if day == nil then
    return
  end
  if pinnedDate == day.date then
    pinnedDate = nil
  else
    pinnedDate = day.date
  end
  render()
end

function onRefreshClicked()
  requestRefresh()
end

local function rerender(valueName, value)
  if valueName == "data" then
    data = value
    resetGrid(data)
    if data ~= nil then
      desktopWidget.setWantsSecondTicks(true)
      desktopWidget.setNeedsFrameTick(true)
    end
  elseif valueName == "status" then
    status = value or "loading"
  elseif valueName == "stale" then
    stale = value == true
  elseif valueName == "error" then
    detail = value or ""
  elseif valueName == "year" then
    selectedYear = value or "last12"
  end
  render()
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
    desktopWidget.setWantsSecondTicks(false)
    desktopWidget.setNeedsFrameTick(false)
    render()
  end
end

function onFrameTick(_deltaMs)
  advanceGrid()
end

function update()
  -- Fallback for a compositor that coalesces frame callbacks. Frame ticks
  -- normally complete the grid in about one second.
  advanceGrid()
end

noctalia.state.watch("data", function(value) rerender("data", value) end)
noctalia.state.watch("status", function(value) rerender("status", value) end)
noctalia.state.watch("stale", function(value) rerender("stale", value) end)
noctalia.state.watch("error", function(value) rerender("error", value) end)
noctalia.state.watch("year", function(value) rerender("year", value) end)

-- A desktop widget has no open/close lifecycle: build the grid as soon as
-- data is available, then draw the initial tree.
if data ~= nil then
  desktopWidget.setWantsSecondTicks(true)
  desktopWidget.setNeedsFrameTick(true)
end
render()
