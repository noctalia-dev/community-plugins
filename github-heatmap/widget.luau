--!nonstrict
-- GitHub Heatmap — a desktop widget for Noctalia.
--
-- Renders the authenticated user's GitHub contribution calendar as a smooth,
-- theme-aware card on the wallpaper. Data comes from `gh api graphql`, is
-- cached as JSON in the plugin data dir, and refreshes on a configurable
-- interval. New/changed data fades in as a staggered left-to-right wave. The
-- wave is driven by frame ticks when available, with an update()-tick
-- fallback, and every tick is switched off once it ends, so the widget costs
-- ~0 CPU when idle.

local tr = noctalia.tr

local QUERY = [[
query {
  viewer {
    login
    contributionsCollection {
      contributionCalendar {
        totalContributions
        weeks {
          firstDay
          contributionDays {
            date
            contributionCount
            contributionLevel
            weekday
          }
        }
      }
    }
  }
}
]]

-- ── Appearance (theme roles only; no hard-coded colors) ─────────────────────
local CARD_FILL    = "surface/0.40"  -- translucent: the compositor blurs what is behind it
local CARD_RADIUS  = 16
local CARD_PADDING = 16
local CARD_GAP     = 10
local cellGap      = 3  -- derived from cellSize in readSettings
local CELL_RADIUS  = 2
local MONTH_ROW_H  = 12
local MONTH_GAP    = 4
local LABEL_WIDTH  = 24
local LABEL_GAP    = 8
local FONT_MONTH   = 10
local FONT_WEEKDAY = 10
local FONT_STATUS  = 11
local McellGap    = 4      -- month calendar: gap between day cells
local MCELL_RADIUS = 10

local LEVEL_ORDER = { "NONE", "FIRST_QUARTILE", "SECOND_QUARTILE", "THIRD_QUARTILE", "FOURTH_QUARTILE" }
local LEVEL_FILL = {
  NONE = "on_surface/0.08",
  FIRST_QUARTILE = "primary/0.30",
  SECOND_QUARTILE = "primary/0.55",
  THIRD_QUARTILE = "primary/0.80",
  FOURTH_QUARTILE = "primary",
}
local MONTH_KEYS = { "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" }
local WEEKDAY_KEYS = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" }

local ANIM_DURATION_MS = 850
local ANIM_STAGGER = 0.45
local ANIM_UPDATE_MS = 50      -- update() cadence while the wave plays
local IDLE_UPDATE_MS = 30000   -- idle cadence (settings poll + refresh timer)
local FETCH_TIMEOUT_MS = 30000

-- ── State ───────────────────────────────────────────────────────────────────
local login = ""
local total = 0
local calendar = nil             -- normalized calendar, nil until data arrives
local visibleWeeks = {}          -- last `weekCount` weeks, oldest first
local dateInfo = {}              -- "YYYY-MM-DD" -> { count = number, weekday = number }
local stats = { today = 0, streak = 0, longest = 0, bestDate = nil, bestCount = 0 }
local rangeTotal = 0             -- contributions inside the shown range
local dataSignature = ""
local animatedSignature = ""
local fetchedAtMs = nil

-- loading | ready | stale | missing_gh | auth_error | offline | offline_mode
-- | request_error | decode_error
local status = "loading"
local inFlight = false
local cachePath = nil

local refreshIntervalMs = 30 * 60 * 1000
local weekCount = 53
local cellSize = 12
local showWeekdayLabels = true
local showStatsFooter = true
local showLegend = true
local viewMode = "year"         -- "year" = GitHub-style week grid | "month" = day calendar
local monthCell = 40
local monthOffset = 0           -- 0 = current month, -1 = previous, ...
local settingsSig = ""
local nextRefreshMs = 0

local animStartMs = nil          -- nil = no animation running
local hoveredDate = nil

-- Forward declarations: closures that appear earlier in this chunk must
-- capture these slots; they are assigned below and only called at runtime.
local redraw
local startAnimation

-- ── Settings ────────────────────────────────────────────────────────────────
local function readSettings()
  local mins = tonumber(noctalia.getConfig("refresh_interval_minutes") or "30") or 30
  refreshIntervalMs = math.max(1, mins) * 60000
  weekCount = tonumber(noctalia.getConfig("weeks") or "53") or 53
  weekCount = math.max(1, math.min(53, weekCount))
  cellSize = tonumber(noctalia.getConfig("cell_size") or "11") or 11
  cellSize = math.max(8, math.min(36, cellSize))
  cellGap = math.max(3, math.floor(cellSize / 6))
  showWeekdayLabels = noctalia.getConfig("show_weekday_labels") ~= false
  showStatsFooter = noctalia.getConfig("show_stats_footer") ~= false
  showLegend = noctalia.getConfig("show_legend") ~= false
  viewMode = (noctalia.getConfig("view") == "calendar") and "month" or "year" -- "year" = GitHub-style week grid
  monthCell = math.max(28, math.min(52, tonumber(noctalia.getConfig("month_cell_size") or "40") or 40))
  local sig = table.concat({
    tostring(mins), tostring(weekCount), tostring(cellSize),
    tostring(showWeekdayLabels), tostring(showStatsFooter), tostring(showLegend),
    viewMode, tostring(monthCell), tostring(cellGap),
  }, "|")
  if sig ~= settingsSig then
    settingsSig = sig
    return true
  end
  return false
end

-- ── Data ────────────────────────────────────────────────────────────────────
local function todayStr()
  return os.date("%Y-%m-%d")
end

local function normalize(decoded)
  if type(decoded) ~= "table" then return nil end
  local viewer = decoded.data and decoded.data.viewer
  local cal = viewer and viewer.contributionsCollection
    and viewer.contributionsCollection.contributionCalendar
  if type(cal) ~= "table" or type(cal.weeks) ~= "table" or #cal.weeks == 0 then
    return nil
  end
  return {
    login = type(viewer.login) == "string" and viewer.login or "",
    totalContributions = tonumber(cal.totalContributions) or 0,
    weeks = cal.weeks,
  }
end

local function signature(normalized)
  local parts = {}
  for _, week in ipairs(normalized.weeks) do
    for _, day in ipairs(week.contributionDays or {}) do
      table.insert(parts, tostring(day.date) .. ":" .. tostring(day.contributionCount or 0))
    end
  end
  return table.concat(parts, ";")
end

local function recomputeStats()
  local todayValue = todayStr()
  local today = 0
  local counts = {}
  local dates = {}
  for _, week in ipairs(visibleWeeks) do
    for _, day in ipairs(week.contributionDays or {}) do
      local c = tonumber(day.contributionCount) or 0
      table.insert(counts, c)
      table.insert(dates, day.date)
      if day.date == todayValue then
        today = c
      end
    end
  end

  local n = #counts

  -- Current streak: from today, or from yesterday when today is still empty
  -- (GitHub's convention).
  local streak = 0
  local streakStart = n
  if n > 0 and counts[n] == 0 then
    streakStart = n - 1
  end
  for i = streakStart, 1, -1 do
    if counts[i] > 0 then streak = streak + 1 else break end
  end

  local longest = 0
  local run = 0
  for i = 1, n do
    if counts[i] > 0 then run = run + 1 else run = 0 end
    if run > longest then longest = run end
  end

  local bestDate, bestCount = nil, 0
  for i = 1, n do
    if counts[i] > bestCount then
      bestCount = counts[i]
      bestDate = dates[i]
    end
  end

  local sum = 0
  for i = 1, n do sum = sum + counts[i] end
  rangeTotal = sum
  stats = { today = today, streak = streak, longest = longest, bestDate = bestDate, bestCount = bestCount }
end

local function recomputeVisible()
  visibleWeeks = {}
  dateInfo = {}
  local weeks = calendar and calendar.weeks or {}
  local start = if viewMode == "month" then 1 else math.max(1, #weeks - weekCount + 1)
  for i = start, #weeks do
    local week = weeks[i]
    table.insert(visibleWeeks, week)
    for _, day in ipairs(week.contributionDays or {}) do
      if type(day.date) == "string" then
        dateInfo[day.date] = {
          count = tonumber(day.contributionCount) or 0,
          weekday = tonumber(day.weekday),
          level = day.contributionLevel,
        }
      end
    end
  end
  recomputeStats()
end

local function applyData(normalized, fetchedAt)
  calendar = normalized
  login = normalized.login
  total = normalized.totalContributions
  fetchedAtMs = fetchedAt or noctalia.nowMs()
  dataSignature = signature(normalized)
  hoveredDate = nil
  recomputeVisible()
end

-- ── Cache ───────────────────────────────────────────────────────────────────
local function persist(response)
  if cachePath == nil then return end
  local encoded = noctalia.json.encode({ fetchedAtMs = noctalia.nowMs(), response = response })
  if encoded == nil then
    noctalia.log("github-heatmap: could not encode cache")
    return
  end
  local ok, err = noctalia.writeFile(cachePath, encoded)
  if not ok then
    noctalia.log("github-heatmap: cache write failed: " .. tostring(err))
  end
end

local function loadCache()
  local dataDir, dirErr = noctalia.pluginDataDir()
  if dataDir == nil then
    noctalia.log("github-heatmap: no data dir: " .. tostring(dirErr))
    return
  end
  cachePath = dataDir .. "/heatmap.json"
  local contents = noctalia.readFile(cachePath)
  if contents == nil then
    return -- first run, nothing cached yet
  end
  local decoded, decodeErr = noctalia.json.decode(contents)
  if decoded == nil then
    noctalia.log("github-heatmap: cache decode failed: " .. tostring(decodeErr))
    return
  end
  local response = decoded.response or decoded
  local normalized = normalize(response)
  if normalized == nil then
    noctalia.log("github-heatmap: cache has an unexpected shape")
    return
  end
  applyData(normalized, tonumber(decoded.fetchedAtMs))
  status = "stale"
  animatedSignature = dataSignature
  startAnimation()
  redraw()
end

-- ── Fetch ───────────────────────────────────────────────────────────────────
local function offlineMode()
  return noctalia.getSetting("shell.offline_mode") == true
end

local function refresh()
  if inFlight then return end
  if not noctalia.commandExists("gh") then
    status = "missing_gh"
    redraw()
    return
  end
  if offlineMode() then
    status = "offline_mode"
    redraw()
    return
  end

  inFlight = true
  if calendar == nil then
    status = "loading"
    redraw()
  end

  noctalia.runAsync({ "gh", "api", "graphql", "-f", "query=" .. QUERY }, function(result)
    inFlight = false
    if result.timedOut then
      status = calendar ~= nil and "stale" or "request_error"
      redraw()
      return
    end
    if result.exitCode ~= 0 then
      local message = string.lower(result.stderr or "")
      if string.find(message, "auth", 1, true) or string.find(message, "token", 1, true) then
        status = "auth_error"
      elseif string.find(message, "offline", 1, true)
        or string.find(message, "connection", 1, true)
        or string.find(message, "network", 1, true)
        or string.find(message, "resolve", 1, true) then
        status = "offline"
      else
        status = "request_error"
      end
      redraw()
      return
    end

    local decoded, decodeErr = noctalia.json.decode(result.stdout or "")
    local normalized = decoded ~= nil and normalize(decoded) or nil
    if normalized == nil then
      noctalia.log("github-heatmap: unexpected payload: " .. tostring(decodeErr))
      status = "decode_error"
      redraw()
      return
    end

    local sig = signature(normalized)
    local changed = sig ~= animatedSignature
    applyData(normalized, noctalia.nowMs())
    status = "ready"
    persist(decoded)
    if changed then
      animatedSignature = sig
      startAnimation()
    end
    redraw()
  end, FETCH_TIMEOUT_MS)
end

-- ── Animation ───────────────────────────────────────────────────────────────
startAnimation = function()
  animStartMs = noctalia.nowMs()
  noctalia.setUpdateInterval(ANIM_UPDATE_MS)
  desktopWidget.setNeedsFrameTick(true)
end

local function finishAnimation()
  animStartMs = nil
  noctalia.setUpdateInterval(IDLE_UPDATE_MS)
  desktopWidget.setNeedsFrameTick(false)
end

local function advanceAnimation()
  if animStartMs == nil then return end
  if noctalia.nowMs() - animStartMs >= ANIM_DURATION_MS then
    finishAnimation()
  end
end

function onFrameTick(_deltaMs)
  if animStartMs == nil then
    desktopWidget.setNeedsFrameTick(false)
    return
  end
  advanceAnimation()
  redraw()
end

local function columnOpacity(index, total)
  if animStartMs == nil then return 1 end
  local t = (noctalia.nowMs() - animStartMs) / ANIM_DURATION_MS
  if t >= 1 then return 1 end
  local startT = (index - 1) / math.max(1, total) * ANIM_STAGGER
  local localT = (t - startT) / (1 - ANIM_STAGGER)
  if localT <= 0 then return 0 end
  if localT >= 1 then return 1 end
  local inv = 1 - localT
  return 1 - inv * inv * inv -- easeOutCubic
end

-- ── Date formatting ─────────────────────────────────────────────────────────
local function dateParts(date)
  if type(date) ~= "string" or #date < 10 then return nil end
  local m = tonumber(string.sub(date, 6, 7))
  local d = tonumber(string.sub(date, 9, 10))
  if m == nil or d == nil or m < 1 or m > 12 then return nil end
  return m, d
end

local function shortDate(date)
  local m, d = dateParts(date)
  if m == nil then return "–" end
  return tr("month." .. MONTH_KEYS[m]) .. " " .. tostring(d)
end

local function longDate(date, weekday)
  local m, d = dateParts(date)
  if m == nil then return date or "–" end
  local wdKey = (weekday ~= nil and weekday >= 0 and weekday <= 6)
    and WEEKDAY_KEYS[weekday + 1] or nil
  if wdKey ~= nil then
    return tr("weekday." .. wdKey) .. ", " .. tr("month." .. MONTH_KEYS[m]) .. " " .. tostring(d)
  end
  return tr("month." .. MONTH_KEYS[m]) .. " " .. tostring(d)
end

-- ── Status line ─────────────────────────────────────────────────────────────
local STATUS_KEYS = {
  loading = "status.loading",
  stale = "status.stale",
  missing_gh = "status.missing_gh",
  auth_error = "status.auth_error",
  offline = "status.offline",
  offline_mode = "status.offline_mode",
  request_error = "status.request_error",
  decode_error = "status.decode_error",
}

local function statusText()
  if status == nil or status == "ready" then return nil end
  local key = STATUS_KEYS[status]
  if key == nil then return nil end
  if status == "stale" then
    local time = "–"
    if fetchedAtMs ~= nil then
      time = os.date("%H:%M", math.floor(fetchedAtMs / 1000))
    end
    return tr(key, { time = time })
  end
  return tr(key)
end

-- ── Tree builders ───────────────────────────────────────────────────────────
local function cardWidth()
  if viewMode == "month" then
    return CARD_PADDING * 2 + 7 * (monthCell + McellGap) - McellGap
  end
  if calendar == nil or #visibleWeeks == 0 then return 320 end
  local gridWidth = #visibleWeeks * (cellSize + cellGap) - cellGap
  local width = CARD_PADDING * 2 + gridWidth
  if showWeekdayLabels then
    width = width + LABEL_WIDTH + LABEL_GAP
  end
  return math.max(264, width)
end

local function buildHeader()
  if calendar == nil then
    return ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "brand-github", size = 16, color = "primary" }),
      ui.label({ text = tr("plugin.name"), fontSize = 14, fontWeight = "semibold" }),
    })
  end
  local summary
  if weekCount >= 52 then
    summary = tr("header.last_year", { count = rangeTotal })
  else
    summary = tr("header.last_weeks", { weeks = weekCount, count = rangeTotal })
  end
  return ui.column({ gap = 3 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "brand-github", size = 16, color = "primary" }),
      ui.label({ text = "@" .. login, fontSize = 14, fontWeight = "semibold" }),
    }),
    ui.label({ text = summary, fontSize = 11, color = "on_surface_variant" }),
  })
end

-- GitHub-style title: sits above the bordered card, summary left, login right.
local function buildGithubTitle()
  local summary
  if weekCount >= 52 then
    summary = tr("header.last_year", { count = rangeTotal })
  else
    summary = tr("header.last_weeks", { weeks = weekCount, count = rangeTotal })
  end
  return ui.row({ justify = "space_between", align = "center", width = cardWidth() }, {
    ui.label({ text = summary, fontSize = 14, color = "on_surface" }),
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "brand-github", size = 14, color = "on_surface_variant" }),
      ui.label({ text = "@" .. login, fontSize = 12, color = "on_surface_variant" }),
    }),
  })
end

local function buildMonthRow()
  local segments = {}
  local current = nil
  for _, week in ipairs(visibleWeeks) do
    local month = nil
    local firstDay = week.firstDay
    if type(firstDay) == "string" and #firstDay >= 7 then
      month = tonumber(string.sub(firstDay, 6, 7))
    end
    if month == nil or month < 1 or month > 12 then
      month = nil
      local days = week.contributionDays
      if type(days) == "table" and type(days[1]) == "table" and type(days[1].date) == "string" and #days[1].date >= 7 then
        local m = tonumber(string.sub(days[1].date, 6, 7))
        if m ~= nil and m >= 1 and m <= 12 then month = m end
      end
    end
    if current == nil then
      current = { month = month, weeks = 1 }
    elseif month ~= nil and month ~= current.month then
      table.insert(segments, current)
      current = { month = month, weeks = 1 }
    else
      current.weeks = current.weeks + 1
      if month ~= nil then current.month = month end
    end
  end
  if current ~= nil then
    table.insert(segments, current)
  end

  local children = {}
  for _, seg in ipairs(segments) do
    local label = ""
    if seg.month ~= nil and seg.weeks >= 2 then
      label = tr("month." .. MONTH_KEYS[seg.month])
    end
    table.insert(children, ui.column({
      width = seg.weeks * (cellSize + cellGap) - cellGap,
      height = MONTH_ROW_H,
      align = "center",
      justify = "center",
    }, {
      ui.label({ text = label, fontSize = FONT_MONTH, color = "on_surface_variant", textAlign = "center" }),
    }))
  end
  return ui.row({ gap = cellGap }, children)
end

local function buildWeekdayLabels()
  local rows = {}
  for wd = 0, 6 do
    local show = wd == 1 or wd == 3 or wd == 5 -- Mon / Wed / Fri
    local child
    if show then
      child = ui.column({
        width = LABEL_WIDTH,
        height = cellSize,
        align = "end",
        justify = "center",
      }, {
        ui.label({
          text = tr("weekday." .. WEEKDAY_KEYS[wd + 1]),
          fontSize = FONT_WEEKDAY,
          color = "on_surface_variant",
          textAlign = "end",
        }),
      })
    else
      -- ui.box draws an opaque default fill; an empty column is a transparent spacer
      child = ui.column({ width = LABEL_WIDTH, height = cellSize }, {})
    end
    table.insert(rows, child)
  end
  return ui.column({ gap = MONTH_GAP }, {
    ui.column({ width = LABEL_WIDTH, height = MONTH_ROW_H }, {}),
    ui.column({ gap = cellGap }, rows),
  })
end

local function onCellHover(state, key)
  local date = nil
  if type(key) == "string" then
    date = string.match(key, "^cell%-(%d%d%d%d%-%d%d%-%d%d)$")
  end
  if state == "true" then
    if hoveredDate ~= date then
      hoveredDate = date
      redraw()
    end
  elseif hoveredDate ~= nil then
    hoveredDate = nil
    redraw()
  end
end

local function buildGrid()
  local total = #visibleWeeks
  local today = todayStr()
  local cols = {}
  for ci = 1, total do
    local week = visibleWeeks[ci]
    local byWeekday = {}
    for _, day in ipairs(week.contributionDays or {}) do
      local wd = tonumber(day.weekday)
      if wd ~= nil then byWeekday[wd] = day end
    end
    local cells = {}
    for wd = 0, 6 do
      local day = byWeekday[wd]
      if day ~= nil and type(day.date) == "string" then
        local props = {
          key = "cell-" .. day.date,
          width = cellSize,
          height = cellSize,
          radius = CELL_RADIUS,
          fill = LEVEL_FILL[day.contributionLevel] or LEVEL_FILL.NONE,
          onHover = onCellHover,
        }
        if day.date == today then
          props.border = "primary"
          props.borderWidth = 2
        end
        table.insert(cells, ui.box(props))
      end
    end
    local colProps = {
      key = "week-" .. tostring(week.firstDay or ci),
      gap = cellGap,
      align = "start",
    }
    local opacity = columnOpacity(ci, total)
    if opacity < 1 then
      colProps.opacity = opacity
    end
    table.insert(cols, ui.column(colProps, cells))
  end
  local gridWidth = total * (cellSize + cellGap) - cellGap
  return ui.row({ gap = cellGap, align = "start", width = gridWidth }, cols)
end

local function statItem(label, value)
  return ui.row({ gap = 4, align = "center" }, {
    ui.label({ text = label, fontSize = 10, color = "on_surface_variant" }),
    ui.label({ text = value, fontSize = 11, fontWeight = "semibold", color = "on_surface" }),
  })
end

local function buildStatsRow()
  if hoveredDate ~= nil then
    local info = dateInfo[hoveredDate]
    local count = (info ~= nil and info.count) or 0
    local weekday = (info ~= nil and info.weekday) or nil
    return ui.label({
      text = tr("stats.day_total", { date = longDate(hoveredDate, weekday), count = count }),
      fontSize = FONT_STATUS,
      color = "on_surface",
    })
  end

  local bestValue = "–"
  if stats.bestDate ~= nil then
    local m, d = dateParts(stats.bestDate)
    if m ~= nil then
      bestValue = tr("stats.best_value", {
        month = tr("month." .. MONTH_KEYS[m]),
        day = tostring(d),
        count = stats.bestCount,
      })
    end
  end

  if cardWidth() < 420 then
    return ui.row({ gap = 12, align = "center" }, {
      statItem(tr("stats.today"), tostring(stats.today)),
      statItem(tr("stats.streak"), tostring(stats.streak)),
      statItem(tr("stats.best"), bestValue),
    })
  end
  return ui.row({ gap = 16, align = "center" }, {
    statItem(tr("stats.today"), tostring(stats.today)),
    statItem(tr("stats.streak"), tostring(stats.streak)),
    statItem(tr("stats.longest"), tostring(stats.longest)),
    statItem(tr("stats.best"), bestValue),
  })
end

local function buildLegend()
  local boxes = {}
  for _, level in ipairs(LEVEL_ORDER) do
    table.insert(boxes, ui.box({ width = 9, height = 9, radius = 2, fill = LEVEL_FILL[level] }))
  end
  return ui.row({ gap = 6, align = "center" }, {
    ui.label({ text = tr("legend.less"), fontSize = 10, color = "on_surface_variant" }),
    ui.row({ gap = 3, align = "center" }, boxes),
    ui.label({ text = tr("legend.more"), fontSize = 10, color = "on_surface_variant" }),
  })
end

-- ── Month calendar view ─────────────────────────────────────────────────────
local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local SAKAMOTO = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
local MONTH_WD_ORDER = { 2, 3, 4, 5, 6, 7, 1 } -- WEEKDAY_KEYS indices, Monday first
local LEVEL_LABEL_COLOR = {
  NONE = "on_surface_variant",
  FIRST_QUARTILE = "on_surface",
  SECOND_QUARTILE = "on_surface",
  THIRD_QUARTILE = "on_primary",
  FOURTH_QUARTILE = "on_primary",
}

local function daysInMonth(y, m)
  if m == 2 and ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) then return 29 end
  return DAYS_IN_MONTH[m]
end

local function weekdayOf(y, m, d) -- 0 = Sunday
  local yy = if m < 3 then y - 1 else y
  return (yy + math.floor(yy / 4) - math.floor(yy / 100) + math.floor(yy / 400) + SAKAMOTO[m] + d) % 7
end

local function currentYM()
  local today = todayStr()
  return tonumber(string.sub(today, 1, 4)), tonumber(string.sub(today, 6, 7))
end

local function shownYM()
  local y, m = currentYM()
  local idx = y * 12 + (m - 1) + monthOffset
  return math.floor(idx / 12), idx % 12 + 1
end

-- How many months back the loaded calendar reaches (<= 0).
local function earliestOffset()
  local week = calendar and calendar.weeks and calendar.weeks[1]
  local first = week and week.firstDay
  if type(first) ~= "string" or #first < 7 then return 0 end
  local ey, em = tonumber(string.sub(first, 1, 4)), tonumber(string.sub(first, 6, 7))
  if ey == nil or em == nil then return 0 end
  local cy, cm = currentYM()
  return -((cy * 12 + cm) - (ey * 12 + em))
end

local function shiftMonth(delta)
  local nxt = monthOffset + delta
  if nxt > 0 then nxt = 0 end
  local lowest = earliestOffset()
  if nxt < lowest then nxt = lowest end
  if nxt == monthOffset then return end
  monthOffset = nxt
  hoveredDate = nil
  startAnimation()
  redraw()
end

local function monthSummary(y, m)
  local sum, bestDate, bestCount = 0, nil, 0
  for d = 1, daysInMonth(y, m) do
    local info = dateInfo[string.format("%04d-%02d-%02d", y, m, d)]
    if info ~= nil then
      sum = sum + info.count
      if info.count > bestCount then
        bestCount = info.count
        bestDate = string.format("%04d-%02d-%02d", y, m, d)
      end
    end
  end
  return sum, bestDate, bestCount
end

local function navButton(glyph, delta, enabled)
  local props = { width = 26, height = 26, radius = 8, align = "center", justify = "center" }
  if enabled then
    props.fill = "on_surface/0.08"
    props.onClick = function() shiftMonth(delta) end
  end
  return ui.column(props, {
    ui.glyph({ name = glyph, size = 14, color = enabled and "on_surface" or "on_surface/0.3" }),
  })
end

local function monthContentWidth()
  return 7 * (monthCell + McellGap) - McellGap
end

local function buildMonthHeader()
  local y, m = shownYM()
  local monthTotal = monthSummary(y, m)
  return ui.column({ gap = 4, width = monthContentWidth() }, {
    ui.row({ justify = "space_between", align = "center", width = monthContentWidth() }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "brand-github", size = 16, color = "primary" }),
        ui.label({ text = "@" .. login, fontSize = 14, fontWeight = "semibold" }),
      }),
      ui.row({ gap = 6, align = "center" }, {
        navButton("chevron-left", -1, monthOffset > earliestOffset()),
        ui.label({
          text = tr("month_full." .. MONTH_KEYS[m]) .. " " .. tostring(y),
          fontSize = 13,
          fontWeight = "semibold",
          textAlign = "center",
        }),
        navButton("chevron-right", 1, monthOffset < 0),
      }),
    }),
    ui.label({ text = tr("header.month_count", { count = monthTotal }), fontSize = 11, color = "on_surface_variant" }),
  })
end

local function buildMonthWeekdays()
  local cols = {}
  for _, idx in ipairs(MONTH_WD_ORDER) do
    table.insert(cols, ui.column({ width = monthCell, align = "center" }, {
      ui.label({
        text = tr("weekday." .. WEEKDAY_KEYS[idx]),
        fontSize = 10,
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }))
  end
  return ui.row({ gap = McellGap }, cols)
end

local function buildMonthGrid()
  local y, m = shownYM()
  local dim = daysInMonth(y, m)
  local first = (weekdayOf(y, m, 1) + 6) % 7 -- Monday = 0
  local rowCount = math.ceil((first + dim) / 7)
  local today = todayStr()
  local rows = {}
  for r = 1, rowCount do
    local cells = {}
    for c = 1, 7 do
      local day = (r - 1) * 7 + c - first
      if day >= 1 and day <= dim then
        local date = string.format("%04d-%02d-%02d", y, m, day)
        local info = dateInfo[date]
        local count = info and info.count or 0
        local level = info and info.level or "NONE"
        local future = date > today
        local labelColor = future and "on_surface_variant/0.4" or (LEVEL_LABEL_COLOR[level] or "on_surface")
        -- No onHover here: on a ui.column it wraps the node in a hover target that
        -- inflates the measured tree size and makes the host shrink the whole widget.
        local props = {
          key = "cell-" .. date,
          width = monthCell,
          height = monthCell,
          radius = MCELL_RADIUS,
          fill = future and "on_surface/0.03" or (LEVEL_FILL[level] or LEVEL_FILL.NONE),
          align = "center",
          justify = "center",
        }
        if date == today then
          props.border = "primary"
          props.borderWidth = 2
        end
        local kids = {
          ui.label({
            text = tostring(day),
            fontSize = 12,
            fontWeight = (date == today) and "bold" or "medium",
            color = labelColor,
            textAlign = "center",
          }),
        }
        if count > 0 then
          table.insert(kids, ui.label({ text = tostring(count), fontSize = 9, color = labelColor, textAlign = "center" }))
        end
        table.insert(cells, ui.column(props, kids))
      else
        table.insert(cells, ui.column({ width = monthCell, height = monthCell }, {}))
      end
    end
    local rowProps = { key = "mrow-" .. tostring(r), gap = McellGap }
    local opacity = columnOpacity(r, rowCount)
    if opacity < 1 then rowProps.opacity = opacity end
    table.insert(rows, ui.row(rowProps, cells))
  end
  return ui.column({ gap = McellGap }, rows)
end

local function buildMonthFooter()
  local y, m = shownYM()
  local statsRow
  if hoveredDate ~= nil then
    statsRow = buildStatsRow()
  else
    local monthTotal, bestDate, bestCount = monthSummary(y, m)
    local bestValue = "–"
    if bestDate ~= nil then
      local bm, bd = dateParts(bestDate)
      if bm ~= nil then
        bestValue = tr("stats.best_value", { month = tr("month." .. MONTH_KEYS[bm]), day = tostring(bd), count = bestCount })
      end
    end
    statsRow = ui.row({ gap = 14, align = "center" }, {
      statItem(tr("stats.today"), tostring(stats.today)),
      statItem(tr("stats.streak"), tostring(stats.streak)),
      statItem(tr("stats.month"), tostring(monthTotal)),
      statItem(tr("stats.best"), bestValue),
    })
  end
  local parts = {}
  if showStatsFooter then table.insert(parts, statsRow) end
  if showLegend then table.insert(parts, ui.row({ justify = "end", width = monthContentWidth() }, { buildLegend() })) end
  if #parts == 0 then return nil end
  return ui.column({ gap = 6, width = monthContentWidth() }, parts)
end

local function buildFooter()
  if not showStatsFooter and not showLegend then return nil end
  if showStatsFooter and showLegend then
    if cardWidth() < 420 then
      return ui.column({ gap = 6, width = cardWidth() - CARD_PADDING * 2 }, {
        buildStatsRow(),
        ui.row({ justify = "end", width = cardWidth() - CARD_PADDING * 2 }, { buildLegend() }),
      })
    end
    return ui.row({ justify = "space_between", align = "center" }, { buildStatsRow(), buildLegend() })
  elseif showStatsFooter then
    return buildStatsRow()
  end
  return ui.row({ justify = "end" }, { buildLegend() })
end

local function buildStatusLine()
  local text = statusText()
  if text == nil then return nil end
  local isError = status == "missing_gh" or status == "auth_error" or status == "offline"
    or status == "offline_mode" or status == "request_error" or status == "decode_error"
  return ui.label({
    text = text,
    fontSize = FONT_STATUS,
    color = isError and "error" or "on_surface_variant",
    maxWidth = cardWidth() - CARD_PADDING * 2,
    maxLines = 2,
  })
end

local function buildEmptyState()
  local isError = status ~= nil and status ~= "loading" and status ~= "stale"
  return ui.column({ gap = 10, align = "center", paddingV = 8 }, {
    ui.glyph({ name = "brand-github", size = 28, color = "on_surface_variant" }),
    ui.label({
      text = statusText() or tr("status.loading"),
      fontSize = 12,
      color = isError and "error" or "on_surface_variant",
      textAlign = "center",
      maxWidth = cardWidth() - CARD_PADDING * 2 - 40,
    }),
  })
end

-- ── Render ──────────────────────────────────────────────────────────────────
redraw = function()
  -- Wall-clock safety: complete any animation that outlived its duration so
  -- cells never stay stuck at partial opacity.
  if animStartMs ~= nil and noctalia.nowMs() - animStartMs >= ANIM_DURATION_MS then
    finishAnimation()
  end

  local monthMode = viewMode == "month" and calendar ~= nil and #visibleWeeks > 0
  local githubMode = not monthMode and calendar ~= nil and #visibleWeeks > 0
  local children = {}
  if not githubMode then
    table.insert(children, monthMode and buildMonthHeader() or buildHeader())
  end

  if monthMode then
    table.insert(children, ui.column({ gap = 6, width = monthContentWidth() }, { buildMonthWeekdays(), buildMonthGrid() }))
  elseif calendar ~= nil and #visibleWeeks > 0 then
    local heatmapColumn = ui.column({ gap = MONTH_GAP }, {
      buildMonthRow(),
      buildGrid(),
    })
    local heatmapRow
    if showWeekdayLabels then
      heatmapRow = ui.row({ gap = LABEL_GAP, align = "start" }, {
        buildWeekdayLabels(),
        heatmapColumn,
      })
    else
      heatmapRow = ui.row({}, { heatmapColumn })
    end
    table.insert(children, heatmapRow)
  else
    table.insert(children, buildEmptyState())
  end

  local statusLine = buildStatusLine()
  if statusLine ~= nil then
    table.insert(children, statusLine)
  end

  if calendar ~= nil then
    local footer = if monthMode then buildMonthFooter() else buildFooter()
    if footer ~= nil then
      table.insert(children, footer)
    end
  end

  if githubMode then
    desktopWidget.render(ui.column({ gap = 8, width = cardWidth() }, {
      buildGithubTitle(),
      ui.column({
        fill = CARD_FILL,
        radius = 8,
        border = "on_surface/0.18",
        borderWidth = 1,
        padding = CARD_PADDING,
        gap = CARD_GAP,
        width = cardWidth(),
      }, children),
    }))
    return
  end

  desktopWidget.render(ui.column({
    fill = CARD_FILL,
    radius = CARD_RADIUS,
    padding = CARD_PADDING,
    gap = CARD_GAP,
    width = cardWidth(),
  }, children))
end

-- ── Ticks ───────────────────────────────────────────────────────────────────
function update()
  -- While the wave plays, update() drives it as a fallback for compositors
  -- that coalesce or drop frame ticks; otherwise it is a slow settings poll.
  if animStartMs ~= nil then
    noctalia.setUpdateInterval(ANIM_UPDATE_MS)
    advanceAnimation()
    redraw()
    return
  end

  noctalia.setUpdateInterval(IDLE_UPDATE_MS)

  local changed = readSettings()
  if changed then
    recomputeVisible()
    redraw()
  end

  if noctalia.nowMs() >= nextRefreshMs then
    nextRefreshMs = noctalia.nowMs() + refreshIntervalMs
    refresh()
  end
end

-- ── Boot ────────────────────────────────────────────────────────────────────
readSettings()
nextRefreshMs = noctalia.nowMs() + refreshIntervalMs
loadCache()
refresh()
