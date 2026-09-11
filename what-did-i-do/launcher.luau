-- launcher.luau — /activity launcher provider.
--
-- Type `/activity` in the launcher for a live summary; drill into
-- "today / yesterday / week / apps"; actions to pause/resume, open the
-- dashboard, or delete history (requires typing "confirm" first — the
-- launcher is an easy place for fat-finger deletions).
--
-- Consumes wdid_state / wdid_sessions; sends commands via wdid_command.

local formatting = require("./lib/formatting.luau")
local aggregation = require("./lib/aggregation.luau")
local timeutil = require("./lib/timeutil.luau")
local appnames = require("./lib/appnames.luau")
local appicons = require("./lib/appicons.luau")

formatting._tr = noctalia.tr

-- Human-readable titles; the technical app_id travels in the badge.
local displayNames = appnames.newResolver({
  readFile = noctalia.readFile,
  listDir = noctalia.listDir,
  getenv = noctalia.getenv,
})

-- Launcher rows use the host's dedicated LauncherResult.icon field (an icon
-- path for ui.image), not the glyph slot and not the badge. Same shared,
-- cached resolver as panel/desktop widget; keys on the technical app_id.
local icons = appicons.newResolver({ appIconPath = noctalia.appIconPath })

-- appRow(title, appId, subtitle, badge, score) -> LauncherResult for an
-- application. icon carries the resolved path (nil when nothing resolves —
-- the host then falls back to the glyph, which stays "app-window").
local function appRow(title, appId, subtitle, badge, score)
  return {
    id = "noop:" .. appId,
    title = title,
    subtitle = subtitle,
    badge = badge,
    glyph = "app-window",
    icon = icons.resolve(appId, 32),
    score = score,
  }
end

local MAX_ROWS = 25
local PANEL_ID = "alitura1/what-did-i-do:dashboard"

local state = { sessions = {}, drill = nil }

local function snapshot()
  local payload = noctalia.state.get("wdid_sessions")
  if type(payload) == "table" and type(payload.sessions) == "table" then
    state.sessions = payload.sessions
  end
end

local function serviceState()
  return noctalia.state.get("wdid_state") or {}
end

snapshot()

noctalia.state.watch("wdid_sessions", function(_v)
  snapshot()
end)

local function todayKey()
  return timeutil.dateKeyOf(noctalia.nowMs() / 1000, 0)
end

local function yesterdayKey()
  return timeutil.dateKeyOf(noctalia.nowMs() / 1000, -1)
end

local function send(op)
  noctalia.state.set("wdid_command", { op = op })
end

local function totalFor(dateKey)
  local summary = aggregation.daySummary(state.sessions, dateKey, 1000)
  local total = summary.total
  if dateKey == todayKey() then
    for _, s in ipairs(state.sessions) do
      if s.open then
        total = total + math.max(0, math.floor((noctalia.nowMs() - (tonumber(s.startedAtMs) or 0)) / 1000))
      end
    end
  end
  return total
end

local function statusRow(title, subtitle, glyph)
  return { id = "", title = title, subtitle = subtitle, glyph = glyph or "info-circle", score = 1 }
end

local function topCategories()
  local s = serviceState()
  local paused = s.paused == true or s.tracking == false
  local unavailable = s.trackingAvailable == false
  local total = totalFor(todayKey())
  local appsCount = tonumber(s.todayApps) or 0
  -- Live toggle is only offered when tracking exists; on an unsupported
  -- compositor the slot becomes an honest, action-less explanation instead
  -- of a control that cannot work. History drills stay fully functional.
  local toggleRow
  if unavailable then
    toggleRow = {
      id = "",
      title = noctalia.tr("panel.unavailable"),
      subtitle = noctalia.tr("panel.unavailable_body"),
      glyph = "plug-off",
      score = 60,
    }
  else
    toggleRow = {
      id = "act:toggle",
      title = paused and noctalia.tr("launcher.resume") or noctalia.tr("launcher.pause"),
      subtitle = paused and noctalia.tr("launcher.resume_sub") or noctalia.tr("launcher.pause_sub"),
      glyph = paused and "player-play" or "player-pause",
      score = 60,
    }
  end
  local rows = {
    {
      id = "cat:today",
      title = noctalia.tr("panel.tab.today"),
      subtitle = formatting.fmtDuration(total)
        .. " · "
        .. noctalia.trp("launcher.stats_apps", appsCount, { count = appsCount }),
      glyph = "clock-hour-4",
      score = 100,
    },
    {
      id = "cat:yesterday",
      title = noctalia.tr("panel.tab.yesterday"),
      subtitle = formatting.fmtDuration(totalFor(yesterdayKey())),
      glyph = "calendar-event",
      score = 95,
    },
    {
      id = "cat:week",
      title = noctalia.tr("panel.tab.week"),
      subtitle = formatting.fmtDuration(aggregation.weekSummary(state.sessions, todayKey(), 7, 1000).total),
      glyph = "calendar-stats",
      score = 90,
    },
    {
      id = "act:panel",
      title = noctalia.tr("launcher.open_panel"),
      subtitle = noctalia.tr("launcher.open_panel_sub"),
      glyph = "layout-dashboard",
      score = 70,
    },
    toggleRow,
    {
      id = "act:delete",
      title = noctalia.tr("launcher.delete_confirm"),
      subtitle = noctalia.tr("launcher.delete_confirm_sub"),
      glyph = "trash",
      score = 10,
    },
  }
  if s.currentAppName ~= nil and s.currentAppName ~= "" and not paused then
    table.insert(rows, 2, {
      id = "act:current",
      title = s.currentAppName,
      subtitle = noctalia.tr("panel.current_session")
        .. " · "
        .. formatting.fmtDuration(math.max(0, math.floor((noctalia.nowMs() - (tonumber(s.currentAppSinceMs) or noctalia.nowMs()) / 1000)))),
      glyph = "point",
      score = 99,
    })
  end
  return rows
end

local function dayRows(dateKey)
  local summary = aggregation.daySummary(state.sessions, dateKey, 1000)
  local rows = {}
  for i, app in ipairs(summary.topApps) do
    if i > MAX_ROWS then
      break
    end
    table.insert(rows, appRow(
      displayNames.resolve(app.appId, app.appName),
      tostring(app.appId),
      formatting.fmtDuration(app.seconds),
      tostring(app.appId),
      100 - i
    ))
  end
  if #rows == 0 then
    rows[1] = statusRow(noctalia.tr("launcher.empty"), "", "moon")
  end
  return rows
end

local function weekRows()
  local wk = aggregation.weekSummary(state.sessions, todayKey(), 7, 1000)
  local rows = {}
  for i, app in ipairs(wk.topApps) do
    if i > MAX_ROWS then
      break
    end
    table.insert(rows, appRow(
      displayNames.resolve(app.appId, app.appName),
      tostring(app.appId),
      formatting.fmtDuration(app.seconds),
      tostring(app.appId),
      100 - i
    ))
  end
  if #rows == 0 then
    rows[1] = statusRow(noctalia.tr("launcher.empty"), "", "moon")
  end
  return rows
end

function onQuery(text)
  snapshot()

  local s = serviceState()
  if s.schema == nil then
    launcher.setResults(text, {
      statusRow(noctalia.tr("launcher.loading"), "", "loader"),
    })
    return
  end

  local t = noctalia.string.trim(text)
  if t == "" then
    if state.drill then
      launcher.setResults(text, drillRows(state.drill))
      return
    end
    launcher.setResults(text, topCategories())
    return
  end

  -- Text filter: match against current view's rows.
  local rows
  if state.drill then
    rows = drillRows(state.drill)
  else
    rows = topCategories()
  end
  local filtered = {}
  for _, row in ipairs(rows) do
    local title = row.title or ""
    local subtitle = row.subtitle or ""
    if string.find(string.lower(title .. " " .. subtitle), string.lower(t), 1, true) then
      table.insert(filtered, row)
    end
  end
  if #filtered == 0 then
    filtered[1] = statusRow(noctalia.tr("launcher.empty"), t, "search")
  end
  launcher.setResults(text, filtered)
end

function drillRows(which)
  if which == "today" then
    return dayRows(todayKey())
  elseif which == "yesterday" then
    return dayRows(yesterdayKey())
  elseif which == "week" then
    return weekRows()
  end
  return topCategories()
end

function onActivate(id)
  if id == nil or id == "" then
    return
  end

  if id == "cat:today" then
    state.drill = "today"
    launcher.setQuery("")
    return
  elseif id == "cat:yesterday" then
    state.drill = "yesterday"
    launcher.setQuery("")
    return
  elseif id == "cat:week" then
    state.drill = "week"
    launcher.setQuery("")
    return
  elseif id == "act:panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  elseif id == "act:toggle" then
    local s = serviceState()
    local paused = s.paused == true or s.tracking == false
    send(paused and "resume" or "pause")
    return
  elseif id == "act:delete" then
    -- Two-step confirm: activating replaces the view with an explicit
    -- confirm/cancel pair so a stray Enter cannot wipe history.
    launcher.setResults("", {
      {
        id = "act:delete:confirm",
        title = noctalia.tr("launcher.delete_confirm"),
        subtitle = noctalia.tr("launcher.delete_confirm_sub"),
        glyph = "trash",
        score = 2,
      },
      {
        id = "act:delete:cancel",
        title = noctalia.tr("panel.delete.cancel"),
        glyph = "x",
        score = 1,
      },
    })
    return
  elseif id == "act:delete:confirm" then
    send("delete")
    noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("launcher.deleted"))
    state.drill = nil
    launcher.setQuery("")
    return
  elseif id == "act:delete:cancel" then
    state.drill = nil
    launcher.setQuery("")
    return
  end
  -- "noop:*" rows have no action; the launcher just closes.
end
