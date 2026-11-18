--!nonstrict
-- Claude Operator service: the only entry that reads Claude Code's files or the network.
-- The widget, panel and launcher render what it publishes (shapes in docs/DESIGN.md).
--
-- Every account is a Claude config dir (~/.claude, or whatever CLAUDE_CONFIG_DIR points
-- at). Claude Code writes <dir>/sessions/<pid>.json per running session (status
-- busy|idle|waiting, waitingFor, bridgeSessionId while Remote Control is on). Those are
-- read here every 2 s without spawning anything; everything heavier runs as a script
-- only when its input changed or its interval came round.
--
-- Each source lives in its own service-*.luau module (accounts, limits, usage, remote,
-- sessions, index), on the common ground in service-core.luau. This file owns the tick
-- that drives them, the panel's commands and the entry points noctalia calls.
--
-- Account discovery, notifications, limits and Remote Control are derived from
-- claude-sessions (lfdominguez, MIT); the pid-reuse check from claude-cockpit
-- (nightwatch75, MIT).
--
-- Force a refresh: noctalia msg plugin edward/claude-operator:service all refresh

local core = require("./service-core.luau")
local acc = require("./service-accounts.luau")
local limits = require("./service-limits.luau")
local usage = require("./service-usage.luau")
local remote = require("./service-remote.luau")
local live = require("./service-sessions.luau")
local index = require("./service-index.luau")
local accounts = core.accounts
local cfg, minutes, publish = core.cfg, core.minutes, core.publish
local DATA, INDEX_MS, TICK_MS, SLOW_MS, RANK, HOUR_MS = core.DATA, core.INDEX_MS, core.TICK_MS, core.SLOW_MS, core.RANK, core.HOUR_MS

local lastSlow = -math.huge

-- ── Tick ────────────────────────────────────────────────────────────────────

local function poll()
  local now = noctalia.nowMs()
  local slow = now - lastSlow >= SLOW_MS
  if slow then lastSlow = now; acc.discoverAccounts() end

  local sessions = {}
  for _, a in pairs(accounts) do
    live.readSessions(a, sessions)
    if now - a.limitsAt >= minutes("limits_refresh_minutes", 5) then limits.fetchLimits(a) end
    if cfg("show_elsewhere", true) and now - a.remote.at >= SLOW_MS then remote.fetchRemote(a) end
  end
  if now - usage.usageAt >= minutes("limits_refresh_minutes", 5) then usage.refreshUsage() end

  -- A session started from inside another one (a hook running claude through the Agent
  -- SDK, say) is that session's helper, not a line of its own: it is counted on its
  -- parent and gets no card, lamp or notification.
  local byPid, own = {}, {}
  for _, s in ipairs(sessions) do byPid[s.pid] = s end
  for _, s in ipairs(sessions) do
    local parent
    for _, a in ipairs(live.ancestorsOf(s.pid)) do
      if byPid[a] then parent = byPid[a] break end
    end
    if parent then parent.helpers = (parent.helpers or 0) + 1 else own[#own + 1] = s end
  end
  sessions = own

  core.localBridges = {}
  for _, s in ipairs(sessions) do
    if s.remote then core.localBridges[string.match(s.remote, "[^/]+$")] = true end
  end
  local gone = live.track(sessions)

  local hideMs = (tonumber(cfg("hide_idle_hours", 0)) or 0) * HOUR_MS
  local shown = {}
  for _, s in ipairs(sessions) do
    if not (hideMs > 0 and s.status == "idle" and now - s.since > hideMs) then shown[#shown + 1] = s end
  end
  table.sort(shown, function(x, y)
    if RANK[x.status] ~= RANK[y.status] then return RANK[x.status] < RANK[y.status] end
    return x.since > y.since
  end)
  core.current = shown
  for _, s in ipairs(sessions) do live.refreshDetails(s) end
  acc.publishAccounts()
  live.publishSessions()
  remote.publishElsewhere()
  if gone or slow then live.refreshRecent() end
  if gone or now - index.indexAt >= INDEX_MS then index.refreshIndex() end
end

-- Refresh everything that runs on a timer, now.
-- The refresh button and IPC. Plan limits only when the last try is over MIN_GAP_MS old
-- (a rate-limit hold still applies): the other sources are local or cheap.
local function refreshAll()
  lastSlow, usage.usageAt, index.indexAt = -math.huge, -math.huge, -math.huge
  local now = noctalia.nowMs()
  for _, a in pairs(accounts) do
    if now - a.limitsAt >= limits.MIN_GAP_MS then a.limitsAt = -math.huge end
    a.remote.at = -math.huge
  end
  poll()
end

-- "refresh": the panel's refresh button. "open": the panel opened, so re-check the cheap,
-- fast-moving sources (Remote Control, Recent) without spending a plan-limits request.
noctalia.state.watch("command", function(v)
  if type(v) ~= "table" then return end
  if v.action == "refresh" then
    refreshAll()
  elseif v.action == "reindex" then
    index.refreshIndex()
  elseif v.action == "pin" then
    index.togglePin(v.cwd)
  elseif v.action == "open" then
    lastSlow = -math.huge
    for _, a in pairs(accounts) do a.remote.at = -math.huge end
    poll()
  end
end)
function update() poll() end
function onIpc(event) if event == "refresh" then refreshAll() end end
-- A settings change re-reads local sources only; no setting changes what the plan
-- limits are, and toggling several settings must not burn through the rate limit.
function onConfigChanged()
  lastSlow, usage.usageAt, index.indexAt = -math.huge, -math.huge, -math.huge
  poll()
end

noctalia.mkdirAll(DATA)
usage.publishPricing()
publish("pins", index.pins)
noctalia.setUpdateInterval(TICK_MS)
poll()
