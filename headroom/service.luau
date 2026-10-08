--!nonstrict
-- Headroom poller: the one entry that talks to the network.
--
-- Every tick it walks the provider registry, fetches whatever the scheduler says
-- is due, and publishes one normalized report to noctalia.state for the bar and
-- panel to draw. The last good snapshots are cached on disk so the bar shows
-- numbers immediately after login instead of an empty state (stale-while-
-- revalidate), and threshold notifications fire from here exactly once per crossing.
--
-- Side effects, for review:
--   network  each signed-in provider's usage endpoint (see providers/*)
--   reads    each provider's saved sign-in (read-only); see providers/*
--   spawns   only what adapters declare (Antigravity: secret-tool, agy)
--   writes   <pluginDataDir>/cache.json (snapshots only, never credentials)

local registry = require("./providers/registry.luau")
local model = require("./lib/model.luau")
local scheduler = require("./lib/scheduler.luau")
local context = require("./lib/context.luau")
local state = require("./lib/state.luau")
local time = require("./lib/time.luau")
local notify = require("./lib/notify.luau")
local fs = require("./lib/fs.luau")

local E = model.ErrorCode
local TICK_MS = 5000
-- How often to notice a sign-in or sign-out. Local file checks, but some
-- providers scan PATH, so not on every tick.
local SIGN_IN_CHECK_SECONDS = 30

local ctx = context.new(noctalia, `headroom-noctalia/{state.VERSION}`)

-- ── Per-provider runtime state ─────────────────────────────────────────────

type Runtime = {
  schedule: scheduler.Entry,
  configured: boolean,
  checkedAt: number, -- last isConfigured() check
  snapshot: model.Snapshot?,
  error: model.ProviderError?,
  stale: boolean, -- snapshot is from the disk cache, or older than the current error
  notified: { [string]: number }, -- window id -> resetsAt we already warned about
}

local runtimes: { [string]: Runtime } = {}
for _, p in registry do
  runtimes[p.id] = {
    schedule = scheduler.new(),
    configured = false,
    checkedAt = -math.huge,
    snapshot = nil,
    error = nil,
    stale = false,
    notified = {},
  }
end

local lastRefreshAt: number? = nil

local function isOff(id: string): boolean
  return state.providerMode(id) == "off"
end

local function intervalSeconds(): number
  return math.clamp(state.config("refresh_minutes", 5), 1, 120) * 60
end

-- ── Cache ──────────────────────────────────────────────────────────────────

local function cachePath(): string?
  local dir = noctalia.pluginDataDir()
  return if dir then `{dir}/cache.json` else nil
end

local function saveCache()
  local path = cachePath()
  if path == nil then
    return
  end
  local doc = { version = 1, providers = {} }
  for id, rt in runtimes do
    if rt.snapshot then
      doc.providers[id] = { snapshot = rt.snapshot, notified = rt.notified }
    end
  end
  local text = noctalia.json.encode(doc)
  if text then
    fs.writeAtomic(path, text)
  end
end

local function loadCache()
  local path = cachePath()
  if path == nil or not noctalia.fileExists(path) then
    return
  end
  local doc = ctx.readJson(path)
  if type(doc) ~= "table" or doc.version ~= 1 or type(doc.providers) ~= "table" then
    return
  end
  for id, entry in doc.providers do
    local rt = runtimes[id]
    if rt and type(entry) == "table" and type(entry.snapshot) == "table" and type(entry.snapshot.windows) == "table" then
      rt.snapshot = entry.snapshot
      rt.stale = true
      rt.notified = if type(entry.notified) == "table" then entry.notified else {}
    end
  end
end

-- ── Publishing ─────────────────────────────────────────────────────────────

local function statusOf(rt: Runtime): string
  if not rt.configured then
    return "absent"
  elseif rt.error ~= nil then
    return "error"
  elseif rt.snapshot == nil then
    return "loading"
  end
  return "ok"
end

local function publish()
  local now = ctx.now()
  local views = {}
  for _, p in registry do
    if not isOff(p.id) then
      local rt = runtimes[p.id]
      table.insert(views, {
        id = p.id,
        name = p.name,
        brand = p.brand,
        hint = p.signInHint(ctx),
        status = statusOf(rt),
        snapshot = rt.snapshot,
        error = rt.error,
        stale = rt.stale,
        busy = scheduler.isBusy(rt.schedule, now),
      })
    end
  end
  noctalia.state.set(state.REPORT, { lastRefreshAt = lastRefreshAt, providers = views })
end

-- ── Notifications ──────────────────────────────────────────────────────────

local function sendNotifications(p, rt: Runtime, previous: model.Snapshot?)
  local enabled = state.config("notify", true)
  local _, critical = state.thresholds()
  local messages = notify.messages(p.name, previous, rt.snapshot, rt.notified, {
    critical = critical,
    low = enabled,
    reset = enabled,
    now = ctx.now(),
    tr = noctalia.tr,
    duration = time.duration,
  })
  for _, message in messages do
    noctalia.notify(message.title, message.body)
  end
end

-- ── Fetching ───────────────────────────────────────────────────────────────

local function withHint(p, err: model.ProviderError): model.ProviderError
  if err.code == E.NotConfigured or err.code == E.Expired or err.code == E.Auth then
    err.hint = p.signInHint(ctx)
  end
  return err
end

-- Starts a fetch; the reply publishes when it lands. The caller publishes the
-- "busy" state once for every fetch it started.
local function fetchProvider(p, rt: Runtime, now: number)
  local generation = scheduler.start(rt.schedule, now)
  local ok, thrown = pcall(p.fetch, ctx, function(snapshot, err)
    local finishedAt = ctx.now()
    if not scheduler.finish(rt.schedule, generation, finishedAt, intervalSeconds(), err) then
      return -- superseded by a newer request
    end
    lastRefreshAt = finishedAt
    if err then
      rt.error = withHint(p, err)
      rt.stale = rt.snapshot ~= nil
      noctalia.log(`[headroom] {p.id}: {err.code}{if err.detail then " (" .. err.detail .. ")" else ""}`)
    else
      local previous = rt.snapshot
      rt.snapshot = snapshot
      rt.error = nil
      rt.stale = false
      sendNotifications(p, rt, previous)
      saveCache()
    end
    publish()
  end)
  if not ok then
    -- A bug in an adapter must not take the other providers down with it.
    noctalia.log(`[headroom] {p.id}: adapter error: {thrown}`)
    rt.error = model.err(E.Parse, "adapter error")
    scheduler.finish(rt.schedule, generation, ctx.now(), intervalSeconds(), rt.error)
  end
end

local function tick(recheckSignIn: boolean?)
  local now = ctx.now()
  local changed = false
  for _, p in registry do
    local rt = runtimes[p.id]
    if isOff(p.id) then
      continue
    end
    if recheckSignIn or now - rt.checkedAt >= SIGN_IN_CHECK_SECONDS then
      rt.checkedAt = now
      local configured = p.isConfigured(ctx)
      if configured ~= rt.configured then
        rt.configured = configured
        changed = true
        if configured then
          scheduler.force(rt.schedule, now) -- signed in since the last check
        else
          rt.error = nil
        end
      end
    end
    if rt.configured and scheduler.isDue(rt.schedule, now) then
      fetchProvider(p, rt, now)
      changed = true
    end
  end
  if changed then
    publish()
  end
end

-- A refresh request. Without `maxAge` (refresh button, R, IPC) every provider
-- is fetched now. With it (opening the panel), only providers whose last good
-- data is older than `maxAge` are fetched, and a provider in backoff after a
-- failure keeps its backoff: opening the panel must not hammer a throttled API.
local function refresh(maxAge: number?)
  local now = ctx.now()
  for _, p in registry do
    local rt = runtimes[p.id]
    local wanted = maxAge == nil
      or (rt.error == nil and (rt.stale or rt.snapshot == nil or now - (rt.snapshot.fetchedAt or 0) >= maxAge))
    if wanted then
      scheduler.force(rt.schedule, now)
    end
  end
  tick(true)
end

-- ── Host callbacks ─────────────────────────────────────────────────────────

function update()
  tick()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  end
end

function onConfigChanged()
  -- A new interval applies from now on; reschedule so a shorter one takes effect.
  local now = ctx.now()
  for _, p in registry do
    local rt = runtimes[p.id]
    if rt.error == nil and rt.snapshot ~= nil then
      rt.schedule.nextAt = math.min(rt.schedule.nextAt, now + intervalSeconds())
    end
  end
  publish()
end

noctalia.state.watch(state.COMMAND, function(command)
  if type(command) == "table" and command.action == "refresh" then
    refresh(tonumber(command.maxAge))
  end
end)

loadCache()
noctalia.setUpdateInterval(TICK_MS)
tick()
publish() -- even with nothing signed in, so surfaces leave their "starting" state
