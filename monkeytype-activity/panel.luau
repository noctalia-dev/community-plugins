--!nonstrict

local Activity = require("./lib/activity.luau")
local Monkeytype = require("./lib/monkeytype.luau")
local Settings = require("./lib/settings.luau")

local data = noctalia.state.get("data")
local status = noctalia.state.get("status") or "loading"
local stale = noctalia.state.get("stale") == true
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
local trp = noctalia.trp
local showToday = Settings.panelElementVisible(noctalia.getConfig("show_today"))
local showCurrentStreak = Settings.panelElementVisible(noctalia.getConfig("show_current_streak"))
local showBestStreak = Settings.panelElementVisible(noctalia.getConfig("show_best_streak"))
local showYearTotal = Settings.panelElementVisible(noctalia.getConfig("show_year_total"))
local showLastTest = Settings.panelElementVisible(noctalia.getConfig("show_last_test"))
local showProfileButton = Settings.panelElementVisible(noctalia.getConfig("show_profile_button"))
local calendarExpanded = Settings.calendarExpanded(showToday, showCurrentStreak, showBestStreak)
local calendarCellWidth = 10
local calendarCellHeight = 12
local calendarColumnGap = 1
local calendarRowGap = calendarExpanded and 4 or 3
local calendarHeaderHeight = calendarExpanded and 14 or 12
local weekdayLabelFontSize = calendarExpanded and 12 or 11
local weeksPerTick = 2
local siteUrl = "https://monkeytype.com"
local username = Settings.username(noctalia.getConfig("profile_username"))
local profileUrl = Monkeytype.profileUrl(username)

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

local function resetGrid(source)
  cachedHeatmap = nil
  cachedCalendar = nil
  gridColumns = {}
  gridLevels = {}
  gridDetails = {}
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
  -- The timestamp is a UTC noon, so it has to be read back in UTC: formatting
  -- it in local time prints the next day's name past UTC+12.
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

-- The seven rows are parsed in one tick (cheap string work), then the week
-- columns are built a few at a time: every callback stays small while a cached
-- calendar is still on screen within about half a second.
local function prepareGridRows()
  if not gridReady or data == nil or gridPreparingDay > 7 then
    return
  end

  while gridPreparingDay <= 7 do
    local day = gridPreparingDay
    gridLevels[day] = Activity.rowLevels(data.rows[day])
    gridDetails[day] = splitTabs((data.details or {})[day])
    if #gridLevels[day] > gridWeekCount then
      gridWeekCount = #gridLevels[day]
    end
    gridPreparingDay = gridPreparingDay + 1
  end
end

local function prepareGridColumns()
  if not gridReady or gridPreparingDay <= 7 then
    return
  end

  local lastWeek = math.min(gridWeek + weeksPerTick - 1, gridWeekCount)
  while gridWeek <= lastWeek do
    local cells = {}
    for day = 1, 7 do
      local rawDetail = gridDetails[day][gridWeek] or ""
      local date, countText = string.match(rawDetail, "^([^|]+)|(%d+)$")
      if date ~= nil then
        local count = tonumber(countText) or 0
        table.insert(cells, ui.box({
          key = "day-" .. date,
          fill = Activity.color(gridLevels[day][gridWeek]),
          radius = 2,
          width = calendarCellWidth,
          height = calendarCellHeight,
          -- A native tooltip per day: re-rendering the tree from a hover
          -- callback replaces the node under the pointer and kills the hover.
          tooltip = trp("panel.day_total", count, { date = formatDate("%Y-%m-%d", date), count = count }),
        }))
      else
        -- A column starts on Sunday, so the leading week is short: an empty
        -- slot keeps every later cell on its weekday row.
        table.insert(cells, ui.box({
          width = calendarCellWidth,
          height = calendarCellHeight,
          fill = "on_surface/0",
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

local function activityBlocks(filled, total)
  local blocks = {}
  for index = 1, total do
    table.insert(blocks, ui.box({
      width = 9,
      height = 9,
      radius = 2,
      fill = index <= filled and "primary" or "surface_container",
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

-- Second line above the calendar: only meaningful once there is data, since
-- the empty state already names the problem.
local function statusText()
  if data == nil then
    -- The empty state already names the problem; a second identical line above
    -- it only adds noise.
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

-- Headline of the empty state, matching why there is nothing to draw.
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
    table.insert(body, cachedCalendar)

    local selectedText = showYearTotal
        and (username ~= nil
          and tr("panel.window_total_named", { username = username, count = data.windowTotal })
          or tr("panel.window_total", { count = data.windowTotal }))
      or ""
    table.insert(body, ui.label({ text = selectedText, height = 14, fontSize = 11, color = "on_surface_variant", textAlign = "center" }))
    table.insert(body, ui.label({ text = refreshSchedule(), height = 12, fontSize = 10, color = "on_surface_variant", textAlign = "center" }))

    if showLastTest then
      local lastTest = lastTestText()
      if lastTest ~= "" then
        table.insert(body, ui.label({ text = lastTest, height = 12, fontSize = 10, color = "on_surface_variant", textAlign = "center" }))
      end
    end

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
    if showYearTotal then
      table.insert(metrics, metric(
        tr("metric.last_year"),
        data.windowTotal,
        activityBlocks(math.min(math.floor(data.windowTotal / 100), 12), 12)
      ))
    end

    if #metrics > 0 then
      local metricChildren = {}
      for index, item in ipairs(metrics) do
        if index > 1 then
          table.insert(metricChildren, ui.separator({ orientation = "vertical", thickness = 1, color = "outline_variant/0.35" }))
        end
        table.insert(metricChildren, item)
      end
      table.insert(body, ui.separator({ thickness = 1, color = "outline_variant/0.35" }))
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
    -- An empty panel reads better centered than pinned to the top edge.
    justify = (centerReadyContent or data == nil) and "center" or "start",
  }, body))

  if showProfileButton and hasApeKey()
    and status ~= "invalid_key" and status ~= "inactive_key" and status ~= "auth_error" then
    table.insert(root, ui.separator({ thickness = 1, color = "outline_variant/0.35" }))
    table.insert(root, ui.row({ justify = "end", paddingH = 14, paddingV = 10 }, {
      ui.button({
        text = profileUrl ~= nil and tr("action.open_profile") or tr("action.open_site"),
        glyph = "external-link",
        variant = "outline",
        onClick = "onOpenProfile",
      }),
    }))
  end

  panel.render(ui.column({ gap = 0, fill = "surface", flexGrow = 1, align = "stretch" }, root))
end


function onOpen(_context)
  open = true
  if data ~= nil and cachedHeatmap == nil then
    -- Panels only receive fast ticks after explicitly opting into frame ticks.
    -- This lets us build the native, hoverable cell tree in small steps.
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
  openUrl(profileUrl or siteUrl)
end

function onOpenApeKeys()
  openUrl(Monkeytype.APE_KEYS_URL)
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
  -- Fallback for a compositor that coalesces frame callbacks while a panel is
  -- attached. Frame ticks normally finish the grid in about half a second.
  advanceGrid()
end

noctalia.state.watch("data", function(value) rerender("data", value) end)
noctalia.state.watch("status", function(value) rerender("status", value) end)
noctalia.state.watch("stale", function(value) rerender("stale", value) end)
