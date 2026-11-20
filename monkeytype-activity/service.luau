--!nonstrict

-- Sync service: fetches MonkeyType stats with the native HTTP client and
-- publishes one compact payload for the widget and the panel.
--
-- Requests are adaptive. `/users/streak` is cheap and tells us whether
-- anything happened since the last fetch (a new result or a new UTC day), so
-- the two heavier calls only run when they can return something new. The
-- results endpoint is never polled: it is limited to 30 requests per day with
-- an Ape Key.

local Activity = require("./lib/activity.luau")
local Monkeytype = require("./lib/monkeytype.luau")
local Settings = require("./lib/settings.luau")

-- Manual refreshes are debounced so repeated clicks cannot burn the shared
-- 30 requests-per-minute budget.
local MANUAL_REFRESH_DEBOUNCE_MS = 10 * 1000
local MAX_BACKOFF_MS = 60 * 60 * 1000

local cachePath = nil
local inFlight = false
local failures = 0
local retryAtMs = 0
local lastManualMs = 0
local activeKey = nil
local data = nil

local function publish(status)
  noctalia.state.set("status", status)
end

local function publishData(payload, stale)
  noctalia.state.set("data", payload)
  noctalia.state.set("stale", stale)
  publish(stale and "stale" or "ready")
end

local function initialiseCache()
  -- `noctalia.state` outlives a service restart, so a payload published by a
  -- previous run must not survive as if it were the current cache.
  noctalia.state.set("data", nil)
  noctalia.state.set("stale", false)

  local dataDir = noctalia.pluginDataDir()
  if dataDir == nil then
    noctalia.log("MonkeyType Activity could not create its data directory")
    return
  end

  cachePath = dataDir .. "/activity.json"
  -- A missing file on the first run is not an error worth a log line.
  if not noctalia.fileExists(cachePath) then
    return
  end

  local contents, readError = noctalia.readFile(cachePath)
  if contents == nil then
    noctalia.log("MonkeyType Activity cache is unreadable: " .. tostring(readError))
    return
  end

  local cached, decodeError = noctalia.json.decode(contents)
  if not Activity.isValidCache(cached) then
    noctalia.log("MonkeyType Activity ignored an invalid cache: " .. tostring(decodeError or "unexpected data"))
    return
  end

  -- The cached calendar is rendered immediately, before any request finishes.
  data = cached
  noctalia.state.set("data", cached)
  noctalia.state.set("stale", true)
  publish("stale")
end

local function persist(payload)
  if cachePath == nil then
    return
  end

  local encoded, encodeError = noctalia.json.encode(payload)
  if encoded == nil then
    noctalia.log("MonkeyType Activity could not encode its cache: " .. tostring(encodeError))
    return
  end

  local ok, writeError = noctalia.writeFile(cachePath, encoded)
  if not ok then
    noctalia.log("MonkeyType Activity could not write its cache: " .. tostring(writeError))
  end
end

local function succeed(payload)
  inFlight = false
  failures = 0
  retryAtMs = 0
  data = payload
  publishData(payload, false)
  persist(payload)
end

local function failure(status)
  inFlight = false
  failures = failures + 1
  noctalia.state.set("stale", data ~= nil)
  publish(status)

  -- Back off only when the server asked us to: retrying a rate limit at the
  -- normal cadence would keep the key blocked.
  if status == Monkeytype.STATUS.RATE_LIMITED then
    local interval = Settings.refreshIntervalMs(noctalia.getConfig("refresh_interval_minutes"))
    local factor = 2 ^ math.min(failures, 4)
    local wait = interval * factor
    if wait > MAX_BACKOFF_MS then
      wait = MAX_BACKOFF_MS
    end
    retryAtMs = noctalia.nowMs() + wait
  end
end

local function request(path, key, onDone)
  local accepted = noctalia.http(Monkeytype.request(path, key), onDone)
  if not accepted then
    onDone(nil)
  end
end

local function fullRefresh(key, streak)
  local collected = { streak = streak }
  local activityError = nil
  local pending = 3

  local function step()
    pending = pending - 1
    if pending > 0 then
      return
    end

    if collected.activity == nil then
      -- `activityError` is the status of the failed call (`no_activity` for an
      -- empty account, `invalid_response` for a malformed payload).
      failure(activityError or Monkeytype.STATUS.RESPONSE)
      return
    end

    local payload = Activity.normalize({
      days = collected.activity.testsByDays,
      dayCount = collected.dayCount,
      lastDay = collected.activity.lastDay,
      streak = collected.streak,
      lastResult = collected.lastResult,
      username = collected.username,
      previous = data,
      now = os.time(),
    })

    if payload == nil then
      failure(Monkeytype.STATUS.RESPONSE)
      return
    end

    succeed(payload)
  end

  request("/users/currentTestActivity", key, function(response)
    local activity, parseError = Monkeytype.payload(response, noctalia.json.decode)
    if activity == nil then
      activityError = parseError
    else
      collected.activity = activity
      collected.dayCount = Monkeytype.arrayLength(response and response.body or "", "testsByDays")
    end
    step()
  end)

  -- The last result is an extra: a failure keeps the previous values instead of
  -- discarding the whole refresh.
  request("/results/last", key, function(response)
    local lastResult = Monkeytype.payload(response, noctalia.json.decode)
    if lastResult ~= nil then
      collected.lastResult = lastResult
    end
    step()
  end)

  -- Best-effort username: avoids asking the user to type it in settings.
  request("/users/profile", key, function(response)
    local profile = Monkeytype.payload(response, noctalia.json.decode)
    if profile ~= nil then
      local name = profile.name
      if type(name) ~= "string" or name == "" then
        name = profile.username
      end
      if type(name) == "string" and name ~= "" then
        collected.username = name
      end
    end
    step()
  end)
end

local function refresh(force)
  if inFlight then
    return
  end

  local key = Settings.apeKey(noctalia.getConfig("ape_key"))
  if key == "" then
    noctalia.state.set("stale", data ~= nil)
    publish("no_key")
    return
  end

  if not Monkeytype.isValidKey(key) then
    noctalia.state.set("stale", data ~= nil)
    publish(Monkeytype.STATUS.INVALID_KEY)
    return
  end

  activeKey = key
  -- A manual refresh never talks past a rate-limit backoff: that is exactly the
  -- click loop that would keep the key blocked.
  if noctalia.nowMs() < retryAtMs then
    return
  end

  inFlight = true
  publish("loading")

  request("/users/streak", key, function(response)
    local streak, parseError = Monkeytype.payload(response, noctalia.json.decode)
    if streak == nil then
      noctalia.log("MonkeyType Activity could not read the streak: " .. tostring(parseError))
      failure(parseError)
      return
    end

    -- A new result changes `lastResultTimestamp`; a new UTC day changes the
    -- day the heatmap ends on. Anything else can reuse the cached calendar.
    -- The payload stores it in seconds, the API answers in milliseconds.
    local today = os.date("!%Y-%m-%d")
    local lastSeen = Activity.toSeconds(streak.lastResultTimestamp) or 0

    local needsFull = force
      or data == nil
      or data.todayDate ~= today
      or data.lastResultTimestamp ~= lastSeen

    if not needsFull then
      local refreshed = {}
      for field, value in pairs(data) do
        refreshed[field] = value
      end
      refreshed.fetchedAt = os.time()
      succeed(refreshed)
      return
    end

    fullRefresh(key, streak)
  end)
end

local function manualRefresh()
  local now = noctalia.nowMs()
  if now - lastManualMs < MANUAL_REFRESH_DEBOUNCE_MS then
    return
  end
  lastManualMs = now
  refresh(true)
end

local function configureInterval()
  noctalia.setUpdateInterval(Settings.refreshIntervalMs(noctalia.getConfig("refresh_interval_minutes")))
end

configureInterval()
initialiseCache()
refresh(false)

noctalia.state.watch("refresh_request", function()
  manualRefresh()
end)

function update()
  refresh(false)
end

function onEnable()
  refresh(true)
end

function onConfigChanged()
  configureInterval()

  local key = Settings.apeKey(noctalia.getConfig("ape_key"))
  if key ~= activeKey then
    -- A different key belongs to a different account: refetch everything.
    refresh(true)
    return
  end

  refresh(false)
end

function onIpc(event, _payload)
  if event == "refresh" then
    manualRefresh()
  end
end
