-- panel.luau — dashboard panel entry (declarative ui.* tree).
--
-- Consumes wdid_state + wdid_sessions from the service; commands go through
-- wdid_command. Tabs: Today / Yesterday / 7 days. Pause toggle + settings
-- shortcut in the header; Delete history lives in a confirmation view
-- (never a single ambiguous click, spec §24).
--
-- RTL: no hardcoded left/right. Rows are built so text and values flow in
-- the surface's writing direction (justify=space_between mirrors naturally);
-- no arrows or directional icons are used.

local formatting = require("./lib/formatting.luau")
local aggregation = require("./lib/aggregation.luau")
local timeutil = require("./lib/timeutil.luau")
local appnames = require("./lib/appnames.luau")
local appicons = require("./lib/appicons.luau")

formatting._tr = noctalia.tr

-- UI labels resolve through one resolver; app_id stays untouched in the data.
local displayNames = appnames.newResolver({
  readFile = noctalia.readFile,
  listDir = noctalia.listDir,
  getenv = noctalia.getenv,
})

-- Icons resolve from the technical app_id (never the display name) through
-- the host's desktop-entry/XDG lookup, cached per id+size (misses included)
-- so no lookup repeats on every render/update.
local icons = appicons.newResolver({ appIconPath = noctalia.appIconPath })

-- Tooltip text for an application row: the primary label plus the technical
-- identifier (kept out of the main row; the id is not translatable and is
-- never mirrored for RTL — identifiers render as-is).

local state = {
  tab = "today",             -- "today" | "yesterday" | "week"
  confirmDelete = false,
  sessions = {},
}

-- ── data helpers ─────────────────────────────────────────────────────────────

local function todayKey()
  return timeutil.dateKeyOf(noctalia.nowMs() / 1000, 0)
end

local function yesterdayKey()
  return timeutil.dateKeyOf(noctalia.nowMs() / 1000, -1)
end

local function snapshot()
  local payload = noctalia.state.get("wdid_sessions")
  if type(payload) == "table" and type(payload.sessions) == "table" then
    state.sessions = payload.sessions
  end
end

local function serviceState()
  return noctalia.state.get("wdid_state") or {}
end

-- ── ui builders ──────────────────────────────────────────────────────────

-- Header tracking controls per state: when tracking is unavailable for the
-- compositor, the pause/resume toggle cannot do anything real, so it becomes
-- a passive indicator (the honest explanation lives in the subtitle).
local function trackingControls(s)
  if s.trackingAvailable == false then
    return ui.glyph({ name = "plug-off", size = 14, color = "on_surface/0.5" })
  end
  return ui.button({
    glyph = s.paused and "player-play" or "player-pause",
    glyphSize = 14,
    variant = "ghost",
    tooltip = s.paused and noctalia.tr("launcher.resume") or noctalia.tr("launcher.pause"),
    onClick = function()
      noctalia.state.set("wdid_command", { op = s.paused and "resume" or "pause" })
    end,
  })
end

local TAB_ORDER = { "today", "yesterday", "week" }
local TAB_KEYS = { today = "panel.tab.today", yesterday = "panel.tab.yesterday", week = "panel.tab.week" }

local function tabButton(tabId)
  return ui.button({
    key = "tab-" .. tabId,
    text = noctalia.tr(TAB_KEYS[tabId]),
    variant = state.tab == tabId and "primary" or "ghost",
    controlSize = "sm",
    onClick = function()
      state.tab = tabId
      state.confirmDelete = false
      render()
    end,
  })
end

local function headerRow()
  local s = serviceState()
  -- "No state published yet" (never received wdid_state) and "no focused app
  -- right now" are independent facts: the first means the tracker has not
  -- started once, the second is a normal steady state and must never hide
  -- the day's history below (state 2 of the required states).
  local subtitle
  if next(s) == nil then
    subtitle = noctalia.tr("panel.waiting_for_tracker")
  elseif s.tracking == false then
    subtitle = noctalia.tr("panel.paused_banner")
  elseif s.trackingAvailable == false then
    -- Distinct state: tracking unavailable for this compositor (history
    -- below stays visible — the user must never read this as data loss).
    subtitle = noctalia.tr("panel.unavailable")
  elseif s.currentAppName ~= nil and s.currentAppName ~= "" then
    subtitle = noctalia.tr("panel.current_session") .. " · " .. s.currentAppName
  else
    subtitle = noctalia.tr("panel.idle")
  end
  return ui.column({ gap = 8 }, {
    ui.row({ gap = 8, align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.row({ gap = 6, align = "center" }, {
        trackingControls(s),
        ui.button({
          glyph = "settings",
          glyphSize = 14,
          variant = "ghost",
          tooltip = noctalia.tr("panel.settings_hint"),
          onClick = function()
            noctalia.openSettings()
          end,
        }),
      }),
    }),
    ui.label({ text = subtitle, fontSize = 12, color = "on_surface/0.7" }),
    ui.row({ gap = 6 }, {
      tabButton("today"),
      tabButton("yesterday"),
      tabButton("week"),
    }),
  })
end

-- Builds a children array that silently drops nil entries: a nil inside a
-- children array is a hole in the UI tree and the host logs "ui tree node is
-- not a table" on every render (the per-second desktop widget turns that
-- into thousands of warnings). select("#", ...) counts trailing nils
-- correctly, unlike #t on a holey table.
local function kidsList(...)
  local n = select("#", ...)
  local out = {}
  for i = 1, n do
    local v = select(i, ...)
    if v ~= nil then
      out[#out + 1] = v
    end
  end
  return out
end

local function appRow(rank, app, totalForPeriod)
  local seconds = tonumber(app.seconds) or 0
  local appId = tostring(app.appId or app.appName or "?")
  local displayName = displayNames.resolve(app.appId, app.appName)
  -- Icon lookup keys on the technical app_id; nil means "no icon" and the
  -- row simply renders without one.
  local iconPath = icons.resolve(appId, 24)
  local leading = iconPath and ui.image({ path = iconPath, width = 20, height = 20, radius = 5 }) or nil
  local share = 0
  if totalForPeriod > 0 then
    share = math.min(1, seconds / totalForPeriod)
  end
  -- Leading icon first (nil omits it — a row never breaks on a missing
  -- icon). The name button carries the tooltip (the id); the label stays
  -- human. controlSize = "sm" matters: at default size the button's vertical
  -- padding makes each row ~40px+ tall and six rows alone ate most of the
  -- panel, squeezing the session viewport to a single row.
  return ui.row({ key = "app-" .. rank .. "-" .. appId, gap = 8, align = "center" }, kidsList(
    leading,
    ui.button({
      key = "app-name-" .. rank .. "-" .. appId,
      text = displayName,
      fontSize = 13,
      variant = "ghost",
      controlSize = "sm",
      contentAlign = "start",
      flexGrow = 1,
      tooltip = noctalia.tr("panel.app_id_tip") .. " " .. appId,
      onClick = function() end,
    }),
    ui.progress({
      progress = share,
      width = 70,
      height = 4,
      radius = 2,
      fill = "primary/0.8",
      track = "on_surface/0.08",
    }),
    ui.label({
      text = formatting.fmtDuration(seconds),
      fontSize = 12,
      color = "on_surface/0.8",
    })
  ))
end

local function sessionRow(session)
  local when = formatting.fmtClock((tonumber(session.startedAtMs) or 0) / 1000, noctalia.formatTime)
  local isCurrent = session.open == true
  local dur
  if isCurrent then
    dur = formatting.fmtDuration(math.max(0, math.floor((noctalia.nowMs() - (tonumber(session.startedAtMs) or 0)) / 1000)))
  else
    dur = formatting.fmtDuration(tonumber(session.durationSeconds) or 0)
  end
  local display = displayNames.resolve(session.appId, session.appName)
  local sessId = tostring(session.appId or session.appName or "?")
  local title = display
  if session.title and session.title ~= "" then
    title = title .. " — " .. session.title
  end
  -- Smaller icon than the top-app rows; keyed on the same technical id the
  -- tooltip shows. nil simply omits the node — scrolling layout is untouched.
  local sessIcon
  do
    local iconPath = icons.resolve(sessId, 16)
    if iconPath then
      sessIcon = ui.image({ path = iconPath, width = 16, height = 16, radius = 4 })
    end
  end
  return ui.row({ key = "sess-" .. session.id, gap = 8, align = "center" }, kidsList(
    ui.label({ text = when, fontSize = 11, color = "on_surface/0.5", width = 44 }),
    ui.glyph({ name = isCurrent and "point" or "circle", size = 8, color = isCurrent and "primary" or "on_surface/0.3" }),
    sessIcon,
    ui.button({
      key = "sess-name-" .. session.id,
      text = title,
      fontSize = 12,
      variant = "ghost",
      controlSize = "sm",
      contentAlign = "start",
      flexGrow = 1,
      tooltip = noctalia.tr("panel.app_id_tip") .. " " .. sessId,
      onClick = function() end,
    }),
    ui.label({ text = dur, fontSize = 11, color = "on_surface/0.7" })
  ))
end

local function emptyView()
  return ui.column({ gap = 6, align = "center", padding = 24 }, {
    ui.glyph({ name = "moon", size = 28, color = "on_surface/0.4" }),
    ui.label({ text = noctalia.tr("panel.empty_history"), color = "on_surface/0.6" }),
    ui.label({ text = noctalia.tr("panel.empty_guide"), fontSize = 11, color = "on_surface/0.4" }),
    ui.label({ text = noctalia.tr("panel.empty_hint"), fontSize = 11, color = "on_surface/0.4" }),
  })
end

local function topAppsSection(rows, total, limit)
  local kids = {
    ui.label({ text = noctalia.tr("panel.top_apps"), fontSize = 12, fontWeight = "semibold", color = "on_surface/0.7" }),
  }
  if #rows == 0 then
    table.insert(kids, emptyView())
  else
    for i, app in ipairs(rows) do
      if i > (limit or 6) then
        break
      end
      table.insert(kids, appRow(i, app, total))
    end
  end
  return ui.column({ gap = 8 }, kids)
end

-- Returns the "N sessions" heading (fixed region) and the row list for the
-- scroll region separately: the heading must not scroll with the rows, and
-- every viewport row must be a session, not chrome. No row cap — the scroll
-- region renders every session of the day; the viewport does the clipping.
local function sessionsSection(sessions)
  local heading = ui.label({
    text = noctalia.trp("panel.sessions_count", #sessions, { count = #sessions }),
    fontSize = 12,
    fontWeight = "semibold",
    color = "on_surface/0.7",
  })
  -- Most recent first: sessions are appended chronologically.
  local rows = {}
  for i = #sessions, 1, -1 do
    table.insert(rows, sessionRow(sessions[i]))
  end
  if #rows == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.empty_history"), fontSize = 12, color = "on_surface/0.5" }))
  end
  return heading, rows
end

-- The day/week body scrolls inside a bounded region (ui.scroll is the panel
-- scroll container, API 21): the panel can no longer grow past the visible
-- UI no matter how many sessions a day holds. Header, tabs, total and the
-- sessions HEADING stay fixed in place; only the session rows flow through
-- the scroll (the heading inside the viewport would waste rows of it and
-- shrink the visible list to a single row on busy days).
--
-- scrollableBody takes the CHILD LIST directly: ui.scroll's signature is
-- (props, { UiNode }) — it lays out its children itself. Passing a single
-- ui.column node instead of a list silently renders nothing (a column node
-- has no array part to iterate), which is exactly the "header there, body
-- blank" bug. No inner column: the scroll owns the gap/padding itself.
--
-- Height policy: flexGrow = 1 (the pattern every panel in this repo uses),
-- backed by flexGrow = 1 on the root column in render() — the scroll can
-- only flex into a parent that itself flexes to the panel's height.
-- justify = "start" (as git_companion does) keeps short lists pinned to the
-- top instead of stretching, so 1–2 sessions don't get smeared vertically.
local function scrollableBody(children)
  return ui.scroll({
    key = "body-scroll",
    flexGrow = 1,
    gap = 10,
    align = "stretch",
    justify = "start",
  }, children)
end

local function dayView(dateKey, pausedHintKey)
  local summary = aggregation.daySummary(state.sessions, dateKey, 10)
  -- Nothing measurable that day (and nothing open right now): show the
  -- compact empty state instead of a tall shell with a big blank scroll
  -- region under it. A live open session still gets the normal view.
  if summary.total == 0 and summary.sessionCount == 0
    and not (dateKey == todayKey() and serviceState().currentApp ~= nil) then
    local kids = {}
    if serviceState().tracking == false and dateKey == todayKey() then
      table.insert(kids, ui.row({
        fill = "primary/0.08",
        radius = 8,
        padding = 10,
        gap = 8,
        align = "center",
      }, {
        ui.glyph({ name = "player-pause", size = 16, color = "primary" }),
        ui.label({ text = noctalia.tr(pausedHintKey or "panel.paused_day_hint"), fontSize = 12, color = "on_surface/0.8" }),
      }))
    elseif serviceState().trackingAvailable == false and dateKey == todayKey() then
      -- Unavailable NOW, not "no data": the banner says so explicitly while
      -- the rest of the (possibly empty) view renders normally below.
      table.insert(kids, ui.row({
        fill = "on_surface/0.06",
        radius = 8,
        padding = 10,
        gap = 8,
        align = "center",
      }, {
        ui.glyph({ name = "plug-off", size = 16, color = "on_surface/0.6" }),
        ui.label({ text = noctalia.tr("panel.unavailable_body"), fontSize = 12, color = "on_surface/0.8" }),
      }))
    end
    table.insert(kids, emptyView())
    -- Views return a LIST of sibling nodes; render() splices them into the
    -- root column's children so the scroll node stays a direct child of the
    -- flexing root (a scroll nested inside a non-flexing column collapses).
    return kids
  end
  local bigTotal = summary.total
  if dateKey == todayKey() then
    -- Today includes the live open session, mirroring the widget.
    local open = nil
    for _, s in ipairs(state.sessions) do
      if s.open then
        open = s
      end
    end
    if open then
      bigTotal = bigTotal + math.max(0, math.floor((noctalia.nowMs() - (tonumber(open.startedAtMs) or 0)) / 1000))
    end
  end

  local kids = {}
  if serviceState().tracking == false and dateKey == todayKey() then
    table.insert(kids, ui.row({
      fill = "primary/0.08",
      radius = 8,
      padding = 10,
      gap = 8,
      align = "center",
    }, {
      ui.glyph({ name = "player-pause", size = 16, color = "primary" }),
      ui.label({ text = noctalia.tr(pausedHintKey or "panel.paused_day_hint"), fontSize = 12, color = "on_surface/0.8" }),
    }))
  elseif serviceState().trackingAvailable == false and dateKey == todayKey() then
    -- Same banner as the empty-day path: unavailable NOW, with history below.
    table.insert(kids, ui.row({
      fill = "on_surface/0.06",
      radius = 8,
      padding = 10,
      gap = 8,
      align = "center",
    }, {
      ui.glyph({ name = "plug-off", size = 16, color = "on_surface/0.6" }),
      ui.label({ text = noctalia.tr("panel.unavailable_body"), fontSize = 12, color = "on_surface/0.8" }),
    }))
  end

  -- Merged total row: the big number and the app count share one row — a
  -- separate app-count line cost a full row of the FIXED region and squeezed
  -- the session viewport below (the "one visible session row" bug).
  table.insert(kids, ui.row({ gap = 8, align = "end", justify = "space_between" }, {
    ui.label({
      text = formatting.fmtDuration(bigTotal),
      fontSize = 24,
      fontWeight = "bold",
      color = "primary",
    }),
    ui.label({
      text = noctalia.trp("panel.apps_count", summary.appCount, { count = summary.appCount }),
      fontSize = 12,
      color = "on_surface/0.6",
    }),
  }))
  table.insert(kids, ui.separator({ spacing = 8 }))
  -- Render 5 rows (sm controls keep them compact) while the count label
  -- reflects the TRUE number of apps used that day (rankApps limit 10).
  table.insert(kids, topAppsSection(summary.topApps, summary.total, 5))
  -- Fixed region (total + top apps + sessions heading) and scrollable region
  -- (session rows only) are separate root children: only the session list
  -- scrolls, per spec — and the heading sits ABOVE the viewport, not in it.
  -- No row cap: the scroll region renders every session of the day and the
  -- viewport does the clipping — a "scroll to the bottom" must reach the
  -- oldest session, not stop at an arbitrary limit.
  local sessionsHeading, sessionRows = sessionsSection(summary.sessions)
  table.insert(kids, sessionsHeading)
  return {
    ui.column({ gap = 8 }, kids),
    scrollableBody(sessionRows),
  }
end

local function weekView()
  local wk = aggregation.weekSummary(state.sessions, todayKey(), 7, 10)
  -- Fixed: the big 7-day total. Scrollable: per-day breakdown + top apps
  -- (bounded regardless of window length).
  -- Same merged total row as the day view: label caption + big number share
  -- one fixed row instead of two.
  local kids = {
    ui.label({
      text = noctalia.tr("panel.week.total"),
      fontSize = 12,
      color = "on_surface/0.6",
    }),
    ui.label({
      text = formatting.fmtDuration(wk.total),
      fontSize = 24,
      fontWeight = "bold",
      color = "primary",
    }),
  }
  local scrollKids = {
    ui.separator({ spacing = 8 }),
    ui.label({ text = noctalia.tr("panel.week.per_day"), fontSize = 12, fontWeight = "semibold", color = "on_surface/0.7" }),
  }
  for _, day in ipairs(wk.perDay) do
    local isToday = day.dateKey == todayKey()
    local label = isToday and noctalia.tr("panel.tab.today") or formatting.fmtDateShort(isoToUnix(day.dateKey), noctalia.formatTime)
    table.insert(scrollKids, ui.row({ key = "day-" .. day.dateKey, gap = 8, align = "center" }, {
      ui.label({ text = label, fontSize = 12, width = 84, color = isToday and "primary" or "on_surface/0.7" }),
      ui.progress({
        progress = wk.total > 0 and math.min(1, day.total / wk.total) or 0,
        flexGrow = 1,
        height = 6,
        radius = 3,
        fill = "primary/0.8",
        track = "on_surface/0.08",
      }),
      ui.label({ text = formatting.fmtDuration(day.total), fontSize = 11, color = "on_surface/0.8" }),
    }))
  end
  table.insert(scrollKids, ui.label({
    text = noctalia.tr("panel.week.average") .. ": " .. formatting.fmtDuration(wk.dailyAverage),
    fontSize = 12,
    color = "on_surface/0.6",
  }))
  table.insert(scrollKids, ui.separator({ spacing = 8 }))
  table.insert(scrollKids, topAppsSection(wk.topApps, wk.total, 5))
  return {
    ui.column({ gap = 8 }, kids),
    scrollableBody(scrollKids),
  }
end

-- ISO date key -> unix seconds (for label formatting only).
function isoToUnix(key)
  local y, m, d = key:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return 0
  end
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

-- ── delete-history confirmation view ─────────────────────────────────────────

local function deleteView()
  return ui.column({ gap = 12, padding = 4 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 18, color = "error" }),
      ui.label({ text = noctalia.tr("panel.delete.title"), fontSize = 14, fontWeight = "bold" }),
    }),
    ui.label({ text = noctalia.tr("panel.delete.body"), fontSize = 12, color = "on_surface/0.8" }),
    ui.row({ gap = 8, justify = "end" }, {
      ui.button({
        text = noctalia.tr("panel.delete.cancel"),
        variant = "outline",
        onClick = function()
          state.confirmDelete = false
          render()
        end,
      }),
      ui.button({
        text = noctalia.tr("panel.delete.confirm"),
        variant = "destructive",
        onClick = function()
          state.confirmDelete = false
          noctalia.state.set("wdid_command", { op = "delete" })
          render()
        end,
      }),
    }),
  })
end

-- ── render ───────────────────────────────────────────────────────────────────

function render()
  snapshot()
  local children = { headerRow() }

  if state.confirmDelete then
    table.insert(children, deleteView())
  else
    -- Views return a list of sibling nodes (fixed region + scroll region);
    -- splice them so the scroll stays a direct child of the root column.
    local view
    if state.tab == "today" then
      view = dayView(todayKey(), "panel.paused_day_hint")
    elseif state.tab == "yesterday" then
      view = dayView(yesterdayKey(), nil)
    else
      view = weekView()
    end
    for _, node in ipairs(view) do
      table.insert(children, node)
    end
    -- Fixed footer, OUTSIDE the scroll: the Delete history control is a plain
    -- root-column child below the flexing scroll region, so it can never sit
    -- inside or overlap a session row — the scroll always ends above it.
    table.insert(children, ui.separator({ spacing = 8 }))
    table.insert(children, ui.row({ gap = 8, justify = "end", align = "center" }, {
      ui.button({
        key = "footer-delete",
        glyph = "trash",
        glyphSize = 13,
        text = noctalia.tr("panel.delete.title"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          state.confirmDelete = true
          render()
        end,
      }),
    }))
  end

  -- flexGrow = 1 on the root column: the body scroll can only flex into a
  -- parent that itself flexes to the panel's height. Without it the scroll
  -- region has no height to grow into and the day/week body collapses to a
  -- blank area even though data is present (the exact bug the empty panel
  -- screenshot showed). Same pattern as github-prs / opencode-companion.
  panel.render(ui.column({ gap = 10, padding = 12, flexGrow = 1, align = "stretch" }, children))
end

function onOpen(_context)
  render()
end

noctalia.state.watch("wdid_state", function(_value)
  render()
end)

noctalia.state.watch("wdid_sessions", function(_value)
  render()
end)

render()
