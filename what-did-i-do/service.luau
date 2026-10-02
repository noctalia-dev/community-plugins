-- service.luau — background activity service (headless [[service]] entry).
--
-- Single source of truth: the only entry that talks to the compositor
-- provider and storage. UI entries (widget, panel, launcher, shortcut)
-- consume the compact "wdid_state" snapshot and send commands via
-- "wdid_command" (noctalia.state) or IPC. They never poll hyprctl.
--
-- Provider selection (Phase 1 portability): the provider is chosen at
-- startup from the session environment (providers/capability.luau). On an
-- unsupported compositor — or when the selected provider's mechanism is
-- missing — a dependency-free fallback provider keeps every entry, setting
-- and the stored history alive while honestly reporting that tracking is
-- unavailable; no activity is ever fabricated. Being a Noctalia user must
-- not require being a Hyprland user.
--
-- Published state (plain data only — entries are isolated VMs):
--   wdid_state = {
--     schema = 1,
--     tracking = true,            -- master setting and not paused
--     paused = false,
--     todayTotal = 13692,         -- seconds
--     todayApps = 8,
--     todayTopApps = { { appId, appName, seconds }, ... }, -- ≤5 rows, glanceable
--     currentApp = "firefox",     -- appId or nil
--     currentAppName = "Firefox", -- display name or ""
--     updatedAtMs = 1720000000000,
--   }
--   wdid_sessions = { sessions = {...}, rev = n }  -- bump rev to signal UI
--   wdid_command = { op = "pause" | "resume" | "toggle" | "delete" | "refresh" }
--
-- IPC (noctalia msg plugin alitura1/what-did-i-do:service all <event>):
--   pause | resume | toggle | delete | refresh

local tracker_mod = require("./lib/tracker.luau")
local exclusion = require("./lib/exclusion.luau")
local storage_mod = require("./lib/storage.luau")
local aggregation = require("./lib/aggregation.luau")
local timeutil = require("./lib/timeutil.luau")
local hyprland_mod = require("./providers/hyprland.luau")
local capability = require("./providers/capability.luau")

-- ── settings ─────────────────────────────────────────────────────────────────

local function getSettings()
  return {
    trackingEnabled = noctalia.getConfig("tracking_enabled") ~= false,
    trackTitles = noctalia.getConfig("track_window_titles") == true,
    retentionDays = math.max(1, math.min(3650, tonumber(noctalia.getConfig("history_retention_days")) or 30)),
    pollSeconds = math.max(1, math.min(60, tonumber(noctalia.getConfig("poll_interval")) or 2)),
    idleAfterSeconds = math.max(10, math.min(600, tonumber(noctalia.getConfig("idle_after_seconds")) or 120)),
    persistEverySeconds = math.max(5, math.min(600, tonumber(noctalia.getConfig("persist_every_seconds")) or 30)),
  }
end

local settings = getSettings()

-- Provider selection: detect the compositor from the session environment,
-- verify the required mechanism exists, and pick the provider. Selection can
-- never fail into a crash — every path yields a usable provider object.
local function resolveProvider(name)
  if name == "hyprland" then
    return hyprland_mod.newProvider({ idleAfterSeconds = settings.idleAfterSeconds })
  end
  -- Phase 1 ships exactly one concrete provider; niri/sway/none select the
  -- built-in fallback inside the selector.
  return nil
end

local provider, detectedCompositor = capability.newSelector({
  resolve = resolveProvider,
}).select({ idleAfterSeconds = settings.idleAfterSeconds })

-- Capability-level truth for the UI: a selected provider that matches its
-- detection actually implements tracking. (The provider's own `available`
-- field is momentary poll health for real providers, not capability.)
local trackingAvailable = detectedCompositor ~= "none" and provider.name == detectedCompositor

function onConfigChanged()
  settings = getSettings()
  provider.idleAfterSeconds = settings.idleAfterSeconds
  noctalia.log("what-did-i-do: settings updated")
end

-- ── tracker ──────────────────────────────────────────────────────────────────

local function dateKeyFor(ms)
  return timeutil.dateKeyOf(ms / 1000, 0)
end

local trk = tracker_mod.newTracker({
  dateKeyFn = dateKeyFor,
  maxGapMs = 120000,
})

-- ── storage ──────────────────────────────────────────────────────────────────

local store = storage_mod.newStorage()

local loadOk, loadErr = store:load()
if not loadOk then
  noctalia.log("what-did-i-do: history load failed (" .. tostring(loadErr) .. "); starting fresh")
end

-- Adopt persisted sessions, including the open session (if any) left behind by
-- a crash or restart. The open one is closed at "now" so no wall-clock time is
-- invented for it (spec §17: undercount rather than fabricate).
local recovered = 0
if type(store.sessions) == "table" then
  for _, s in ipairs(store.sessions) do
    if type(s) == "table" and s.id and s.startedAtMs
      and not exclusion.isExcludedApplication(s) then
      if s.open then
        local nowMs = noctalia.nowMs()
        s.open = nil
        s.endedAtMs = nowMs
        s.durationSeconds = math.max(0, math.floor((nowMs - s.startedAtMs) / 1000))
      end
      table.insert(trk.sessions, s)
      recovered = recovered + 1
    end
  end
  if recovered > 0 then
    noctalia.log("what-did-i-do: recovered " .. recovered .. " session(s) from storage")
  end
end

local allSessions = trk.sessions

-- ── pause state ──────────────────────────────────────────────────────────────

local paused = false

-- ── persistence ──────────────────────────────────────────────────────────────

local lastPersistMs = 0
local dirty = true

local function snapshotAllSessions()
  -- Closed sessions + the open one, so an in-progress session survives a
  -- crash and is recovered (closed at restart time) on next load.
  local out = {}
  for i, s in ipairs(trk.sessions) do
    out[i] = s
  end
  if trk.open then
    out[#out + 1] = trk.open
  end
  return out
end

local function persistNow()
  local ok, err = store:save(snapshotAllSessions())
  if not ok then
    noctalia.log("what-did-i-do: save failed: " .. tostring(err))
    return
  end
  dirty = false
  lastPersistMs = noctalia.nowMs()
end

local function persistIfDue(nowMs)
  if dirty and (nowMs - lastPersistMs) >= settings.persistEverySeconds * 1000 then
    persistNow()
  end
end

-- ── retention ────────────────────────────────────────────────────────────────

local lastPruneKey = nil

local function pruneIfNeeded(todayKey)
  if lastPruneKey == todayKey then
    return
  end
  lastPruneKey = todayKey
  local kept, removed = tracker_mod.pruneSessions(trk.sessions, todayKey, settings.retentionDays)
  if removed > 0 then
    trk.sessions = kept
    allSessions = trk.sessions
    dirty = true
    noctalia.log("what-did-i-do: retention removed " .. removed .. " session(s)")
  end
end

-- ── state publishing ─────────────────────────────────────────────────────────

local sessionsRev = 0
local lastPublishedOpenId = nil
local lastPublishedOpenTitle = nil
local sessionsEverPublished = false -- ship the list at least once on startup

local function publish()
  local nowMs = noctalia.nowMs()
  local todayKey = dateKeyFor(nowMs)
  local today = aggregation.daySummary(trk.sessions, todayKey, 5)
  local current = trk.open

  -- Include the live open session in the displayed total so the widget ticks
  -- up in real time. The open session's elapsed time is provisional; it is
  -- reconciled into the closed session list when it ends.
  local liveTotal = today.total
  if current then
    liveTotal = liveTotal + math.max(0, math.floor((nowMs - current.startedAtMs) / 1000))
  end

  noctalia.state.set("wdid_state", {
    schema = 1,
    provider = detectedCompositor,
    trackingAvailable = trackingAvailable,
    tracking = settings.trackingEnabled and not paused,
    paused = paused,
    todayTotal = liveTotal,
    todayApps = today.appCount,
    todayTopApps = today.topApps, -- glanceable rows for the desktop widget
    currentApp = current and current.appId or nil,
    currentAppName = current and current.appName or "",
    currentAppSinceMs = current and current.startedAtMs or nil,
    updatedAtMs = nowMs,
  })

  -- Ship the full session list only when its identity actually changed (an
  -- open session that merely accumulates time must not cross entries each
  -- tick). The open session's *identity* still matters to the panel, so its
  -- id and title are included in the snapshot the panel recomputes from.
  if not sessionsEverPublished or lastPublishedOpenId ~= (current and current.id or nil) then
    sessionsEverPublished = true
    sessionsRev = sessionsRev + 1
    lastPublishedOpenId = current and current.id or nil
    lastPublishedOpenTitle = current and current.title or nil
    noctalia.state.set("wdid_sessions", { sessions = trk.sessions, rev = sessionsRev })
  elseif current and current.title ~= lastPublishedOpenTitle then
    lastPublishedOpenTitle = current.title
    sessionsRev = sessionsRev + 1
    noctalia.state.set("wdid_sessions", { sessions = trk.sessions, rev = sessionsRev })
  end
end

-- ── provider events ──────────────────────────────────────────────────────────

local function handleProviderEvent(kind)
  local nowMs = noctalia.nowMs()
  if kind == "idle" then
    trk:consume({ type = "idle" }, nowMs)
  elseif kind == "active" then
    trk:consume({ type = "resume" }, nowMs)
    -- the next poll() sample reopens a session with the current app
  elseif kind == "lock" then
    trk:consume({ type = "close" }, nowMs)
  elseif kind == "unlock" then
    -- nothing: next sample opens a new session
  elseif kind == "suspend" then
    trk:consume({ type = "suspend" }, nowMs)
  elseif kind == "resume" then
    trk:consume({ type = "resume" }, nowMs)
  end
  dirty = true
  publish()
  persistIfDue(nowMs)
end

provider.onEvent = handleProviderEvent

-- ── main loop ────────────────────────────────────────────────────────────────

function update()
  noctalia.setUpdateInterval(settings.pollSeconds * 1000)

  local nowMs = noctalia.nowMs()

  if not settings.trackingEnabled or paused then
    trk:consume({ type = "pause" }, nowMs)
    publish()
    persistIfDue(nowMs)
    return
  end

  pruneIfNeeded(dateKeyFor(nowMs))

  provider.activeWindow(function(app)
    if not settings.trackingEnabled or paused then
      return
    end
    -- Strip the title at the service boundary unless title tracking is on:
    -- nothing private reaches storage or other entries by accident.
    if app and not settings.trackTitles and type(app) == "table" then
      app.title = nil
    end
    trk:consume({ type = "sample", app = app, trackTitle = settings.trackTitles }, noctalia.nowMs())
    dirty = true
    publish()
    persistIfDue(noctalia.nowMs())
  end)
end

-- ── pause / resume ───────────────────────────────────────────────────────────

local function setPaused(value, notifyUser)
  if paused == value then
    return
  end
  paused = value
  if value then
    trk:consume({ type = "pause" }, noctalia.nowMs())
  else
    trk:consume({ type = "resume" }, noctalia.nowMs())
  end
  if notifyUser then
    if value then
      noctalia.notify(noctalia.tr("notifications.paused"))
    else
      noctalia.notify(noctalia.tr("notifications.resumed"))
    end
  end
  publish()
  dirty = true
  persistNow()
end

-- ── history deletion ─────────────────────────────────────────────────────────

local function deleteHistory()
  -- Close whatever is open, drop everything, clear disk.
  trk:consume({ type = "pause" }, noctalia.nowMs())
  trk.sessions = {}
  trk.open = nil
  allSessions = trk.sessions
  store:clear()
  sessionsRev = sessionsRev + 1
  noctalia.state.set("wdid_sessions", { sessions = trk.sessions, rev = sessionsRev })
  lastPublishedOpenId = nil
  lastPublishedOpenTitle = nil
  publish()
  dirty = false
  noctalia.notify(noctalia.tr("notifications.delete_done"), noctalia.tr("notifications.delete_done_body"))
  noctalia.log("what-did-i-do: all history deleted by user")
end

-- ── shared-state command channel (UI entries -> service) ────────────────────

noctalia.state.watch("wdid_command", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "pause" then
    setPaused(true, true)
  elseif op == "resume" then
    setPaused(false, true)
  elseif op == "toggle" then
    setPaused(not paused, true)
  elseif op == "delete" then
    deleteHistory()
  elseif op == "refresh" then
    publish()
  end
  -- Clear the command so the same op can be sent again later.
  noctalia.state.set("wdid_command", nil)
end)

-- ── IPC ──────────────────────────────────────────────────────────────────────

function onIpc(event, _payload)
  if event == "pause" then
    setPaused(true, true)
  elseif event == "resume" then
    setPaused(false, true)
  elseif event == "toggle" then
    setPaused(not paused, true)
  elseif event == "delete" then
    deleteHistory()
  elseif event == "refresh" then
    publish()
  end
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

function onExit(_signal, _reason)
  persistNow()
end

provider.start(handleProviderEvent)

-- Startup: adopt persisted state, prune, publish, and flush once.
pruneIfNeeded(dateKeyFor(noctalia.nowMs()))
publish()
persistNow()
