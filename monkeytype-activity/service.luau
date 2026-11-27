--!nonstrict

-- Sync service: fetches MonkeyType stats with the native HTTP client and
-- publishes one compact payload for the widget and the panel.
--
-- Requests are adaptive. `/users/streak` is cheap and tells us whether
-- anything happened since the previous poll; the heavier endpoints run only
-- after a new test or a manual refresh. Callbacks from stale refresh
-- generations are ignored so account/key switches cannot be polluted by
-- in-flight responses from the previous account.

local Monkeytype = require("./lib/monkeytype.luau")
local Activity = require("./lib/activity.luau")
local Settings = require("./lib/settings.luau")

local MAX_BACKOFF_MS = 3600000
local MANUAL_REFRESH_DEBOUNCE_MS = 10000

local data = nil
local lastManualMs = 0
local failures = 0
local retryAtMs = 0
local rateLimitedUntilMs = 0
local rateLimitedFingerprint = ""
local inFlight = false
local activeKey = ""
local generation = 0

local function refreshIntervalMs()
  return Settings.refreshIntervalMs(noctalia.getConfig("refresh_interval_minutes"))
end

-- Exponential backoff over the refresh interval, capped at one hour.
local function backoffMs()
  local interval = refreshIntervalMs()
  local factor = 2 ^ math.min(failures, 4)
  local wait = interval * factor
  if wait > MAX_BACKOFF_MS then
    wait = MAX_BACKOFF_MS
  end
  return wait
end

local function cachePath()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  return dir .. "/activity.json"
end

local function persist(payload)
  local path = cachePath()
  if path == nil then
    return
  end

  local ok, encoded = pcall(noctalia.json.encode, payload)
  if not ok or type(encoded) ~= "string" then
    return
  end

  noctalia.writeFile(path, encoded)
end

local function publish(status)
  noctalia.state.set("status", status)
  noctalia.state.set("data", data)
end

local function invalidate(clearData, key)
  generation = generation + 1
  inFlight = false
  failures = 0
  retryAtMs = 0
  if key ~= nil and key ~= "" and Monkeytype.fingerprint(key) ~= rateLimitedFingerprint then
    -- Only another account gets a fresh request budget: clearing the key, or
    -- typing the same one back, keeps an active rate-limit deadline.
    rateLimitedUntilMs = 0
  end
  if clearData then
    data = nil
    noctalia.state.set("stale", false)
    -- Another account must not keep reading the previous one's numbers: the
    -- next request rewrites the cache from scratch.
    local path = cachePath()
    if path ~= nil then
      pcall(noctalia.removeFile, path)
    end
  end
end

local function succeed(payload, gen)
  if gen ~= generation then
    return
  end

  inFlight = false
  failures = 0
  retryAtMs = 0
  rateLimitedUntilMs = 0
  rateLimitedFingerprint = ""
  data = payload
  persist(payload)
  noctalia.state.set("stale", false)
  publish("ready")
end

local function failure(status, gen)
  if gen ~= generation then
    return
  end

  inFlight = false
  failures = failures + 1

  retryAtMs = noctalia.nowMs() + backoffMs()
  if status == Monkeytype.STATUS.RATE_LIMITED then
    -- A 429 deadline is not a generic backoff: a manual refresh must not
    -- reset it and burn the account's request budget.
    rateLimitedUntilMs = retryAtMs
    rateLimitedFingerprint = Monkeytype.fingerprint(activeKey)
  end

  noctalia.state.set("stale", data ~= nil)
  publish(status)
end

local function request(path, key, onDone)
  local accepted = noctalia.http(Monkeytype.request(path, key), onDone)
  if not accepted then
    onDone(nil)
  end
end

local function canReuseForLightRefresh(streak, fingerprint)
  if data == nil or data.accountKey ~= fingerprint then
    return false
  end
  if data.todayDate ~= Activity.utcDate(os.time()) then
    return false
  end
  local lastSeen = Activity.toSeconds(streak.lastResultTimestamp) or 0
  return data.lastResultTimestamp == lastSeen
end

local function lightRefresh(fingerprint, streak, gen)
  -- Nothing new since the last fetch: rebuild the payload from the stored
  -- series so `fetchedAt` (and the UI's freshness) moves forward.
  local payload = Activity.normalize({
    counts = data.counts,
    lastTimestamp = data.lastTimestamp,
    streak = streak,
    lastResult = data.lastResult,
    accountKey = fingerprint,
    now = os.time(),
  })

  if Activity.isValidCache(payload) then
    succeed(payload, gen)
  else
    failure(Monkeytype.STATUS.RESPONSE, gen)
  end
end

local function fullRefresh(key, fingerprint, streak, gen)
  local collected = { streak = streak }
  local pending = 2
  local failed = false
  local rateLimited = false

  local function step()
    if failed or gen ~= generation then
      return
    end

    pending = pending - 1
    if pending > 0 then
      return
    end

    if collected.counts == nil or collected.lastDay == nil then
      failure(Monkeytype.STATUS.RESPONSE, gen)
      return
    end

    local payload = Activity.normalize({
      counts = collected.counts,
      lastTimestamp = collected.lastDay,
      streak = streak,
      lastResult = collected.lastResult,
      accountKey = fingerprint,
      now = os.time(),
    })

    if Activity.isValidCache(payload) then
      succeed(payload, gen)
      if rateLimited then
        -- The optional last-result call was rate limited: keep the calendar
        -- that did arrive, but stop requesting until the deadline passes.
        failures = 1
        retryAtMs = noctalia.nowMs() + backoffMs()
        rateLimitedUntilMs = retryAtMs
        rateLimitedFingerprint = fingerprint
      end
    else
      failure(Monkeytype.STATUS.RESPONSE, gen)
    end
  end

  local function fail(status)
    if failed or gen ~= generation then
      return
    end
    failed = true
    failure(status, gen)
  end

  request("/users/currentTestActivity", key, function(response)
    local payload, status = Monkeytype.payload(response, noctalia.json.decode)
    if status ~= nil then
      fail(status)
      return
    end

    local days = payload and payload.testsByDays
    local lastDay = payload and payload.lastDay
    if type(days) ~= "table" or Activity.toSeconds(lastDay) == nil then
      fail(Monkeytype.STATUS.RESPONSE)
      return
    end

    -- Count the window from the raw body so trailing null days survive; fall
    -- back to the decoded length if the body cannot be scanned.
    local count = Monkeytype.arrayLength(response.body or "", "testsByDays") or #days
    local counts = {}
    local any = false
    for index = 1, count do
      local value = days[index]
      if type(value) == "number" and value >= 0 then
        counts[index] = math.floor(value)
        any = true
      else
        counts[index] = 0
      end
    end
    if count == 0 and next(days) ~= nil then
      fail(Monkeytype.STATUS.RESPONSE)
      return
    end

    collected.counts = counts
    collected.lastDay = lastDay
    collected.hasAny = any
    step()
  end)

  -- The last test is optional: a 5xx here must not hide the calendar that
  -- the activity and streak responses already delivered.
  request("/results/last", key, function(response)
    local lastResult, status = Monkeytype.payload(response, noctalia.json.decode)
    if gen ~= generation then
      return
    end
    if status == Monkeytype.STATUS.RATE_LIMITED then
      rateLimited = true
    elseif status == nil and type(lastResult) == "table" then
      collected.lastResult = lastResult
    end
    step()
  end)
end

local function refresh(force)
  if inFlight then
    return
  end

  local now = noctalia.nowMs()
  -- A rate-limit deadline is absolute: even a forced refresh waits it out.
  if now < rateLimitedUntilMs then
    return
  end
  if not force and now < retryAtMs then
    return
  end

  local key = Settings.apeKey(noctalia.getConfig("ape_key"))
  if key == "" then
    invalidate(false)
    activeKey = ""
    noctalia.state.set("stale", data ~= nil)
    publish("no_key")
    return
  end

  if not Monkeytype.isValidKey(key) then
    invalidate(false)
    activeKey = key
    noctalia.state.set("stale", data ~= nil)
    publish(Monkeytype.STATUS.INVALID_KEY)
    return
  end

  activeKey = key
  local fingerprint = Monkeytype.fingerprint(key)
  inFlight = true
  local gen = generation
  publish(data == nil and "loading" or "refreshing")

  request("/users/streak", key, function(response)
    local streak, status = Monkeytype.payload(response, noctalia.json.decode)
    if gen ~= generation then
      return
    end
    if status ~= nil then
      failure(status, gen)
      return
    end
    if type(streak) ~= "table" then
      failure(Monkeytype.STATUS.RESPONSE, gen)
      return
    end

    if not force and canReuseForLightRefresh(streak, fingerprint) then
      lightRefresh(fingerprint, streak, gen)
      return
    end

    fullRefresh(key, fingerprint, streak, gen)
  end)
end

local function initialiseCache()
  local path = cachePath()
  if path == nil then
    return
  end

  local key = Settings.apeKey(noctalia.getConfig("ape_key"))
  if not noctalia.fileExists(path) then
    return
  end

  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then
    return
  end

  local ok, decoded = pcall(noctalia.json.decode, raw)
  if not ok or not Activity.isValidCache(decoded) then
    -- Nothing here can be used, and a legacy cache may still hold the raw
    -- key: drop the file instead of leaving it on disk.
    pcall(noctalia.removeFile, path)
    return
  end

  local fingerprint = Monkeytype.fingerprint(key)
  local stored = decoded.accountKey
  if fingerprint == "" then
    -- Without a key nothing can be bound; a legacy cache that still holds the
    -- plaintext credential is dropped rather than left on disk.
    if type(stored) == "string" and string.match(stored, "^fp:") == nil then
      pcall(noctalia.removeFile, path)
    end
    return
  end

  if stored == key then
    -- Cache from a previous version: it stored the raw Ape Key. Rewrite it
    -- with the fingerprint so the plaintext copy disappears immediately.
    decoded.accountKey = fingerprint
    persist(decoded)
  elseif stored ~= fingerprint then
    -- The data cannot be proven to belong to this key (an older cache may
    -- even hold another account's raw key): drop the file instead of
    -- leaving a credential, or someone else's numbers, on disk.
    pcall(noctalia.removeFile, path)
    return
  end

  data = decoded
  -- The cache predates this run: show it, but mark it stale until the first
  -- refresh confirms it is still current.
  noctalia.state.set("stale", true)
  publish("stale")
end

function update()
  refresh(false)
end

function manualRefresh()
  if inFlight then
    return
  end

  -- Debounce repeated clicks so they cannot burn the request budget.
  local now = noctalia.nowMs()
  if now - lastManualMs < MANUAL_REFRESH_DEBOUNCE_MS then
    return
  end
  -- A click inside a rate-limit window changes nothing: do not consume the
  -- debounce and do not restart the failure counter. A generic backoff is
  -- still bypassed below, because the click is an explicit retry.
  if now < rateLimitedUntilMs then
    return
  end
  if Settings.apeKey(noctalia.getConfig("ape_key")) == "" then
    return
  end

  lastManualMs = now
  failures = 0
  refresh(true)
end

function onConfigChanged()
  noctalia.setUpdateInterval(refreshIntervalMs())

  local key = Settings.apeKey(noctalia.getConfig("ape_key"))
  if key ~= activeKey then
    -- A different key belongs to a different account: drop any in-flight
    -- responses and cached state so the new account starts clean.
    invalidate(true, key)
    activeKey = key
    publish(key == "" and "no_key" or "loading")
    refresh(true)
    return
  end

  refresh(false)
end

noctalia.state.watch("refresh_request", function()
  manualRefresh()
end)

function onIpc(event, _payload)
  if event == "refresh" then
    manualRefresh()
  end
end

-- Load-time initialization: the host runs the entry chunk when the plugin
-- starts, and there is no onLoad callback for services.
noctalia.setUpdateInterval(refreshIntervalMs())
initialiseCache()
refresh(false)
