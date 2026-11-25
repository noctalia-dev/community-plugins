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
local inFlight = false
local activeKey = ""
local generation = 0

local function refreshIntervalMs()
  return Settings.refreshIntervalMs(noctalia.getConfig("refresh_interval_minutes"))
end

local function persist(payload)
  local dir = noctalia.pluginDataDir()
  local path = dir .. "/activity.json"

  local ok, encoded = pcall(noctalia.json.encode, payload)
  if not ok or type(encoded) ~= "string" then
    return
  end

  noctalia.writeFile(path, encoded)
end

local function publish(status)
  noctalia.state.set("status", status)
  noctalia.state.set("data", data)
  noctalia.state.set("fetched_at", data and data.fetchedAt or 0)
end

local function invalidate(clearData)
  generation = generation + 1
  inFlight = false
  failures = 0
  retryAtMs = 0
  if clearData then
    data = nil
    noctalia.state.set("stale", false)
  end
end

local function succeed(payload, gen)
  if gen ~= generation then
    return
  end

  inFlight = false
  failures = 0
  retryAtMs = 0
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

  local interval = refreshIntervalMs()
  local factor = 2 ^ math.min(failures, 4)
  local wait = interval * factor
  if wait > MAX_BACKOFF_MS then
    wait = MAX_BACKOFF_MS
  end
  retryAtMs = noctalia.nowMs() + wait

  noctalia.state.set("stale", data ~= nil)
  publish(status)
end

local function request(path, key, onDone)
  local accepted = noctalia.http(Monkeytype.request(path, key), onDone)
  if not accepted then
    onDone(nil)
  end
end

local function canReuseForLightRefresh(streak)
  if data == nil or data.accountKey ~= activeKey then
    return false
  end
  if data.todayDate ~= Activity.utcDate(os.time()) then
    return false
  end
  local lastSeen = Activity.toSeconds(streak.lastResultTimestamp) or 0
  return data.lastResultTimestamp == lastSeen
end

local function lightRefresh(key, streak, gen)
  -- Nothing new since the last fetch: rebuild the payload from the stored
  -- series so `fetchedAt` (and the UI's freshness) moves forward.
  local payload = Activity.normalize({
    counts = data.counts,
    lastTimestamp = data.lastTimestamp,
    streak = streak,
    lastResult = data.lastResult,
    accountKey = key,
    now = os.time(),
  })

  if Activity.isValidCache(payload) then
    succeed(payload, gen)
  else
    failure(Monkeytype.STATUS.RESPONSE, gen)
  end
end

local function fullRefresh(key, streak, gen)
  local collected = { streak = streak }
  local pending = 2
  local failed = false

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
      accountKey = key,
      now = os.time(),
    })

    if Activity.isValidCache(payload) then
      succeed(payload, gen)
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

    local count = Monkeytype.arrayLength(response.body or "", "testsByDays")
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

  request("/results/last", key, function(response)
    local lastResult, status = Monkeytype.payload(response, noctalia.json.decode)
    if status ~= nil and status ~= "no_activity" then
      fail(status)
      return
    end
    if type(lastResult) == "table" then
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

    if not force and canReuseForLightRefresh(streak) then
      lightRefresh(key, streak, gen)
      return
    end

    fullRefresh(key, streak, gen)
  end)
end

local function initialiseCache()
  local key = Settings.apeKey(noctalia.getConfig("ape_key"))
  local dir = noctalia.pluginDataDir()
  local path = dir .. "/activity.json"

  if not noctalia.fileExists(path) then
    return
  end

  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then
    return
  end

  local ok, decoded = pcall(noctalia.json.decode, raw)
  if not ok or not Activity.isValidCache(decoded) then
    return
  end

  if decoded.accountKey ~= key then
    return
  end

  data = decoded
  -- The cache predates this run: show it, but mark it stale until the first
  -- refresh confirms it is still current.
  noctalia.state.set("stale", true)
  publish("stale")
end

function onLoad()
  noctalia.setUpdateInterval(refreshIntervalMs())
  initialiseCache()
  refresh(true)
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
  lastManualMs = now

  failures = 0
  retryAtMs = 0
  refresh(true)
end

function onConfigChanged()
  noctalia.setUpdateInterval(refreshIntervalMs())

  local key = Settings.apeKey(noctalia.getConfig("ape_key"))
  if key ~= activeKey then
    -- A different key belongs to a different account: drop any in-flight
    -- responses and cached state so the new account starts clean.
    invalidate(true)
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

-- Top-level initialization (mirrors HEAD behaviour)
noctalia.setUpdateInterval(refreshIntervalMs())
initialiseCache()
refresh(false)
