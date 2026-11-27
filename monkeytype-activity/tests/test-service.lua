-- Behaviour tests for the sync service, driven through a mock of the Noctalia
-- runtime. Nothing here touches the network or the real shell.
--
--   lua5.4 tests/test-service.lua
--
-- The mock reproduces the two details that shape the service: `noctalia.http`
-- delivers `{ ok, status, body }` to a callback, and `noctalia.json.decode`
-- turns a JSON `null` into a missing table value (which truncates an array).

local function scriptDir()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    return source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
  end
  return "."
end

-- The tests live in `tests/`, so the plugin root is the directory above them.
local function pluginRoot()
  local dir = scriptDir()
  local parent = dir:match("^(.*)[/\\]tests$")
  if parent and parent ~= "" then
    return parent
  end
  if dir == "tests" or parent == "" then
    return "."
  end
  return dir
end

local DIR = pluginRoot()
local loaded = {}
local function pluginRequire(path)
  local relative = path:gsub("^%./", "")
  if loaded[relative] == nil then
    loaded[relative] = assert(loadfile(DIR .. "/" .. relative))()
  end
  return loaded[relative]
end

local Activity = pluginRequire("lib/activity.luau")
local Monkeytype = pluginRequire("lib/monkeytype.luau")

local FAILED = 0
local PASSED = 0
local function check(name, expected, actual)
  if expected == actual then
    PASSED = PASSED + 1
    print(string.format("  ok    %-58s %s", name, tostring(actual)))
  else
    FAILED = FAILED + 1
    print(string.format("  FAIL  %-58s expected=%s actual=%s", name, tostring(expected), tostring(actual)))
  end
end

local function section(name)
  print("\n== " .. name)
end

local function containsValue(value, needle)
  if type(value) == "string" then
    return string.find(value, needle, 1, true) ~= nil
  end
  if type(value) == "table" then
    for _, item in pairs(value) do
      if containsValue(item, needle) then
        return true
      end
    end
  end
  return false
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = deepCopy(item)
  end
  return copy
end

local NOW = os.time()
local TODAY = NOW - NOW % 86400
local YESTERDAY = TODAY - 86400

-- ------------------------------------------------------------------- mock

local function newMock()
  local mock = {
    responses = {},
    bodies = {},
    encoded = {},
    encodedCount = 0,
    requests = {},
    pendingHttp = {},
    deferHttp = false,
    state = {},
    watchers = {},
    statusHistory = {},
    config = {
      ape_key = "APEKEY",
      refresh_interval_minutes = "30",
      profile_username = "",
    },
    logs = {},
    clock = 1800000000000,
    updateIntervalMs = 0,
    files = {},
    dataDir = "/tmp/monkeytype-activity-test-" .. tostring(math.random(100000, 999999)),
  }

  local noctalia = {}

  noctalia.getConfig = function(key)
    return mock.config[key]
  end

  noctalia.log = function(message)
    table.insert(mock.logs, tostring(message))
  end

  noctalia.nowMs = function()
    return mock.clock
  end

  noctalia.setUpdateInterval = function(ms)
    mock.updateIntervalMs = ms
  end

  noctalia.pluginDataDir = function()
    return mock.dataDir
  end

  noctalia.fileExists = function(path)
    return mock.files[path] ~= nil
  end

  noctalia.readFile = function(path)
    local contents = mock.files[path]
    if contents == nil then
      return nil, "not found"
    end
    return contents
  end

  noctalia.writeFile = function(path, contents)
    mock.files[path] = contents
    return true
  end

  noctalia.removeFile = function(path)
    mock.files[path] = nil
    return true
  end

  noctalia.state = {}

  noctalia.state.set = function(key, value)
    local copy = deepCopy(value)
    mock.state[key] = copy
    if key == "status" then
      table.insert(mock.statusHistory, copy)
    end
    local watchers = mock.watchers[key]
    if watchers ~= nil then
      for _, watcher in ipairs(watchers) do
        watcher(deepCopy(copy))
      end
    end
  end

  noctalia.state.get = function(key)
    return deepCopy(mock.state[key])
  end

  noctalia.state.watch = function(key, callback)
    mock.watchers[key] = mock.watchers[key] or {}
    table.insert(mock.watchers[key], callback)
  end

  noctalia.json = {
    decode = function(body)
      if mock.bodies[body] ~= nil then
        return deepCopy(mock.bodies[body])
      end
      local index = string.match(tostring(body), "^@cache:(%d+)$")
      if index ~= nil and mock.encoded[tonumber(index)] ~= nil then
        return deepCopy(mock.encoded[tonumber(index)])
      end
      return nil, "cannot decode"
    end,
    encode = function(value)
      mock.encodedCount = mock.encodedCount + 1
      mock.encoded[mock.encodedCount] = deepCopy(value)
      return "@cache:" .. tostring(mock.encodedCount)
    end,
  }

  noctalia.http = function(request, callback)
    local path = string.gsub(request.url, "https://api.monkeytype.com", "")
    table.insert(mock.requests, path)
    if mock.deferHttp then
      table.insert(mock.pendingHttp, { path = path, callback = callback })
      return true
    end
    local response = mock.responses[path]
    if response == nil then
      response = { ok = false, status = 0, body = "" }
    end
    callback(deepCopy(response))
    return true
  end

  mock.noctalia = noctalia
  return mock
end

local function route(mock, path, data)
  local body = "body:" .. path .. ":" .. tostring(#mock.requests)
  mock.bodies[body] = { message = "ok", data = data }
  mock.responses[path] = { ok = true, status = 200, body = body }
end

local function routeFailure(mock, path, status)
  mock.responses[path] = { ok = false, status = status, body = "" }
end

-- The activity response keeps the JSON length in the body while the decoded
-- table loses its `null` days, exactly like the real runtime.
local function routeActivity(mock, lastDay, counts)
  local raw = {}
  local decoded = {}
  for index = 1, #counts do
    if counts[index] == nil then
      raw[index] = "null"
    else
      raw[index] = tostring(counts[index])
      decoded[index] = counts[index]
    end
  end

  local body = '{"message":"ok","data":{"testsByDays":['
    .. table.concat(raw, ",")
    .. '],"lastDay":'
    .. tostring(lastDay)
    .. "}}"
  mock.bodies[body] = { message = "ok", data = { testsByDays = decoded, lastDay = lastDay } }
  mock.responses["/users/currentTestActivity"] = { ok = true, status = 200, body = body }
end

local function loadService(mock)
  local env
  local function envRequire(name)
    if name == "noctalia" then
      return env.noctalia
    end
    local loaded = package.loaded[name]
    if loaded ~= nil then
      return loaded
    end
    local path = name
    if not string.match(path, "%.luau$") and not string.match(path, "%.lua$") then
      path = string.gsub(path, "%.", "/") .. ".luau"
    end
    local chunk = assert(loadfile(DIR .. "/" .. path, "t", env))
    local result = chunk()
    package.loaded[name] = result
    return result
  end

  env = setmetatable({ noctalia = deepCopy(mock.noctalia), require = envRequire }, { __index = _G })
  env._G = env
  -- reset module cache for service deps so each load is isolated where needed
  for name in pairs(package.loaded) do
    if string.match(name, "^lib%.") or name == "lib" then
      package.loaded[name] = nil
    end
  end
  local chunk = assert(loadfile(DIR .. "/service.luau", "t", env))
  chunk()
  return env
end

local function countRequests(mock, path)
  local total = 0
  for _, requested in ipairs(mock.requests) do
    if requested == path then
      total = total + 1
    end
  end
  return total
end

-- 372 days ending yesterday: three active days, nothing today.
local function quietCounts()
  local counts = {}
  for index = 1, 372 do
    counts[index] = 0
  end
  counts[370] = 4
  counts[371] = 2
  counts[372] = 3
  return counts
end

local function coldMock()
  local mock = newMock()
  route(mock, "/users/streak", {
    -- The API answers milliseconds; the payload stores seconds.
    lastResultTimestamp = (NOW - 600) * 1000,
    length = 3,
    maxLength = 7,
    hourOffset = 2,
  })
  routeActivity(mock, YESTERDAY, quietCounts())
  route(mock, "/results/last", { wpm = 95.6, acc = 97.2, timestamp = (NOW - 600) * 1000, mode = "time", mode2 = "15" })
  return mock
end

-- --------------------------------------------------------------- scenarios

section("no Ape Key yet")
do
  local mock = newMock()
  mock.config.ape_key = "   "
  loadService(mock)
  check("status", "no_key", mock.state.status)
  check("no requests", 0, #mock.requests)
end

section("cold start fetches everything")
local coldMockInstance = coldMock()
local coldService = loadService(coldMockInstance)
do
  local mock = coldMockInstance
  check("three requests", 3, #mock.requests)
  check("streak first", "/users/streak", mock.requests[1])
  check("activity second", "/users/currentTestActivity", mock.requests[2])
  check("last result third", "/results/last", mock.requests[3])
  check("no profile request", 0, countRequests(mock, "/users/profile"))
  check("status", "ready", mock.state.status)
  check("no error", false, (mock.state.error or "") ~= "")

  local data = mock.state.data
  check("payload is a valid cache", true, Activity.isValidCache(data))
  check("today is empty", 0, data.today)
  check("window total", 9, data.windowTotal)
  check("columns", 54, data.columns)
  check("current streak", 3, data.currentStreak)
  check("best streak", 7, data.bestStreak)
    check("last wpm rounded", 96, data.lastWpm)
  check("last accuracy rounded", 97, data.lastAcc)
  check("last mode", "time", data.lastMode)
  check("not stale", false, mock.state.stale)
  check("cache written", "string", type(mock.files[mock.dataDir .. "/activity.json"]))
  check("update interval", 1800000, mock.updateIntervalMs)
  check("no errors logged", 0, #mock.logs)
end

section("the Ape Key never reaches the cache or the published state")
do
  local mock = coldMock()
  loadService(mock)
  local raw = mock.files[mock.dataDir .. "/activity.json"]
  check("cache exists", "string", type(raw))
  local encoded = mock.encoded[tonumber(string.match(raw, "^@cache:(%d+)$"))]
  check("cache stores a fingerprint", Monkeytype.fingerprint("APEKEY"), encoded.accountKey)
  check("cache holds no raw key", false, containsValue(encoded, "APEKEY"))
  check("state holds no raw key", false, containsValue(mock.state.data, "APEKEY"))
end

section("a legacy cache holding the raw Ape Key is scrubbed")
do
  local mock = coldMock()
  loadService(mock)
  local path = mock.dataDir .. "/activity.json"

  local legacy = deepCopy(mock.state.data)
  legacy.accountKey = "APEKEY"
  mock.files[path] = mock.noctalia.json.encode(legacy)

  local reopened = newMock()
  reopened.files = mock.files
  reopened.encoded = mock.encoded
  reopened.encodedCount = mock.encodedCount
  reopened.dataDir = mock.dataDir
  loadService(reopened)

  local rewritten = reopened.encoded[tonumber(string.match(reopened.files[path], "^@cache:(%d+)$"))]
  check("legacy cache rewritten with a fingerprint", Monkeytype.fingerprint("APEKEY"), rewritten.accountKey)
  check("no raw key left in the cache", false, containsValue(rewritten, "APEKEY"))
end

section("a legacy cache is dropped when no key is configured")
do
  local mock = coldMock()
  loadService(mock)
  local path = mock.dataDir .. "/activity.json"

  local legacy = deepCopy(mock.state.data)
  legacy.accountKey = "APEKEY"
  mock.files[path] = mock.noctalia.json.encode(legacy)

  local reopened = newMock()
  reopened.files = mock.files
  reopened.encoded = mock.encoded
  reopened.encodedCount = mock.encodedCount
  reopened.dataDir = mock.dataDir
  reopened.config.ape_key = ""
  loadService(reopened)
  check("plaintext legacy cache removed without a key", nil, reopened.files[path])
  check("no key status", "no_key", reopened.state.status)
end

section("an unusable cache is removed instead of reused")
do
  local mock = coldMock()
  loadService(mock)
  local path = mock.dataDir .. "/activity.json"
  check("cache written", "string", type(mock.files[path]))

  -- A truncated legacy cache: still a plaintext key inside, but no longer
  -- usable. It must be deleted, not left for the next load.
  local partial = deepCopy(mock.state.data)
  partial.counts = nil
  partial.accountKey = "APEKEY"
  mock.files[path] = mock.noctalia.json.encode(partial)

  local reopened = newMock()
  reopened.dataDir = mock.dataDir
  reopened.files = mock.files
  reopened.encoded = mock.encoded
  reopened.encodedCount = mock.encodedCount
  loadService(reopened)
  check("incomplete cache deleted", nil, reopened.files[path])
  check("incomplete cache not published", nil, reopened.state.data)

  mock.files[path] = '{"accountKey":"APEKEY"'
  local broken = newMock()
  broken.dataDir = mock.dataDir
  broken.files = mock.files
  loadService(broken)
  check("undecodable cache deleted", nil, broken.files[path])
end

section("a cache bound to another key is dropped")
do
  local mock = coldMock()
  loadService(mock)
  local path = mock.dataDir .. "/activity.json"

  local foreign = deepCopy(mock.state.data)
  foreign.accountKey = Monkeytype.fingerprint("OTHERKEY")
  mock.files[path] = mock.noctalia.json.encode(foreign)

  local reopened = newMock()
  reopened.files = mock.files
  reopened.encoded = mock.encoded
  reopened.encodedCount = mock.encodedCount
  reopened.dataDir = mock.dataDir
  loadService(reopened)
  check("file removed", nil, reopened.files[path])
end

section("a quiet tick only asks for the streak")
do
  local mock = coldMockInstance
  local before = mock.state.data.fetchedAt
  mock.clock = mock.clock + 60000
  coldService.update()
  check("one more request", 4, #mock.requests)
  check("last request is the streak", "/users/streak", mock.requests[4])
  check("status", "ready", mock.state.status)
  check("fetchedAt refreshed", true, mock.state.data.fetchedAt >= before)
  check("calendar kept", true, #mock.state.data.rows[1] > 0)
end

section("a new result triggers a full refresh")
do
  local mock = coldMockInstance
  route(mock, "/users/streak", {
    lastResultTimestamp = (NOW - 30) * 1000,
    length = 4,
    maxLength = 8,
    hourOffset = 2,
  })
  coldService.update()
  check("three more requests", 7, #mock.requests)
  check("current streak", 4, mock.state.data.currentStreak)
  check("best streak", 8, mock.state.data.bestStreak)
end

section("manual refreshes are debounced")
do
  local mock = coldMockInstance
  local before = #mock.requests
  -- A manual refresh always refetches everything, so it costs three requests.
  mock.noctalia.state.set("refresh_request", 1)
  check("first click refreshes", before + 3, #mock.requests)
  coldService.onIpc("refresh")
  check("second click is dropped", before + 3, #mock.requests)
  mock.clock = mock.clock + 11000
  coldService.onIpc("refresh")
  check("later click refreshes again", before + 6, #mock.requests)
end

section("a disabled Ape Key is named, not called invalid")
do
  local mock = coldMock()
  routeFailure(mock, "/users/streak", 471)
  loadService(mock)
  check("status", "inactive_key", mock.state.status)
  check("no data published", nil, mock.state.data)
end

section("an invalid Ape Key is reported, not retried blindly")
do
  local mock = coldMock()
  routeFailure(mock, "/users/streak", 470)
  loadService(mock)
  check("status", "invalid_key", mock.state.status)
  check("no data published", nil, mock.state.data)
  check("no cache written", nil, mock.files[mock.dataDir .. "/activity.json"])
end

section("a rate limit backs off instead of hammering")
do
  local mock = coldMock()
  routeFailure(mock, "/users/streak", 429)
  local service = loadService(mock)
  check("status", "rate_limited", mock.state.status)
  local before = #mock.requests
  service.update()
  check("tick inside the backoff window is skipped", before, #mock.requests)
  service.onIpc("refresh")
  check("manual refresh also waits the rate limit", before, #mock.requests)
  mock.clock = mock.clock + 61 * 60 * 1000
  route(mock, "/users/streak", { lastResultTimestamp = NOW - 600, length = 3, maxLength = 7 })
  service.update()
  check("tick after the backoff window retries", true, #mock.requests > before)
  check("status recovers", "ready", mock.state.status)
end

section("a manual refresh still bypasses a generic backoff")
do
  local mock = coldMock()
  routeFailure(mock, "/users/streak", 500)
  local service = loadService(mock)
  check("first attempt failed", true, mock.state.status ~= "ready")
  local before = #mock.requests
  mock.clock = mock.clock + 60 * 1000
  route(mock, "/users/streak", { lastResultTimestamp = NOW - 600, length = 3, maxLength = 7 })
  service.manualRefresh()
  check("manual refresh retries during the backoff", before + 3, #mock.requests)
  check("manual refresh recovers", "ready", mock.state.status)
end

section("editing the key keeps an active rate limit")
do
  local mock = coldMock()
  routeFailure(mock, "/users/streak", 429)
  local service = loadService(mock)
  check("status", "rate_limited", mock.state.status)
  local before = #mock.requests

  mock.config.ape_key = ""
  service.onConfigChanged()
  mock.clock = mock.clock + 60 * 1000
  mock.config.ape_key = "APEKEY"
  service.onConfigChanged()
  check("retyping the same key still waits", before, #mock.requests)

  route(mock, "/users/streak", { lastResultTimestamp = NOW - 600, length = 3, maxLength = 7 })
  mock.config.ape_key = "OTHERKEY"
  service.onConfigChanged()
  check("another key fetches immediately", before + 3, #mock.requests)
  check("another key is ready", "ready", mock.state.status)
end

section("cached data is served before the first request finishes")
do
  local mock = coldMock()
  loadService(mock)
  check("cache exists", "string", type(mock.files[mock.dataDir .. "/activity.json"]))

  local offline = coldMock()
  offline.dataDir = mock.dataDir
  offline.files = mock.files
  offline.encoded = mock.encoded
  offline.encodedCount = mock.encodedCount
  offline.responses = {}
  local history = {}
  loadService(offline)
  history = offline.statusHistory
  check("first status is the cached one", "stale", history[1])
  check("then the failure is reported", "request_error", offline.state.status)
  check("cached payload still published", true, Activity.isValidCache(offline.state.data))
  check("marked stale", true, offline.state.stale)
end

section("an account without saved activity is a normal state")
do
  local mock = coldMock()
  route(mock, "/users/currentTestActivity", nil)
  loadService(mock)
  check("status", "no_activity", mock.state.status)
  check("no data", nil, mock.state.data)
end

section("an unexpected activity payload fails the refresh")
do
  local mock = coldMock()
  route(mock, "/users/currentTestActivity", { days = "nope", lastDay = "later" })
  loadService(mock)
  check("status", "invalid_response", mock.state.status)
end

section("a failing last result still publishes the calendar")
do
  local mock = coldMock()
  routeFailure(mock, "/results/last", 503)
  loadService(mock)
  check("status", "ready", mock.state.status)
  check("calendar published", "table", type(mock.state.data))
  check("streak still published", 3, mock.state.data.currentStreak)
  check("last wpm unavailable", nil, mock.state.data.lastWpm)
end

section("a rate limit on the optional last result keeps the calendar")
do
  local mock = coldMock()
  routeFailure(mock, "/results/last", 429)
  local service = loadService(mock)
  check("status", "ready", mock.state.status)
  check("calendar published", "table", type(mock.state.data))
  local before = #mock.requests
  mock.clock = mock.clock + 60 * 1000
  service.manualRefresh()
  check("manual refresh waits the optional rate limit", before, #mock.requests)
end

section("a different key forces a refetch")
do
  local mock = coldMock()
  local service = loadService(mock)
  local before = #mock.requests
  mock.config.ape_key = "ANOTHERKEY"
  service.onConfigChanged()
  check("full refresh", before + 3, #mock.requests)
  check("status", "ready", mock.state.status)
end

section("changing the ape key during an in-flight refresh ignores stale callbacks")
do
  local function flushAll(mock)
    local index = 1
    while index <= #mock.pendingHttp do
      local item = mock.pendingHttp[index]
      index = index + 1
      local response = mock.responses[item.path]
      if response == nil then
        response = { ok = false, status = 0, body = "" }
      end
      item.callback(deepCopy(response))
    end
    mock.pendingHttp = {}
  end

  local mock = newMock()
  mock.deferHttp = true
  route(mock, "/users/streak", {
    lastResultTimestamp = (NOW - 30) * 1000,
    length = 1,
    maxLength = 1,
  })
  local countsA = {}
  for i = 1, 372 do countsA[i] = 0 end
  countsA[372] = 5
  routeActivity(mock, TODAY, countsA)
  route(mock, "/results/last", {
    wpm = 50,
    acc = 90,
    mode = "time",
    mode2 = "15",
    timestamp = NOW * 1000,
  })

  local service = loadService(mock)
  check("initial refresh is in flight", 1, #mock.requests)
  check("no data published yet", nil, mock.state.data)

  mock.config.ape_key = "ANOTHERKEY"
  route(mock, "/users/streak", {
    lastResultTimestamp = (NOW - 30) * 1000,
    length = 2,
    maxLength = 3,
  })
  local countsB = {}
  for i = 1, 372 do countsB[i] = 0 end
  countsB[372] = 1
  routeActivity(mock, TODAY, countsB)
  route(mock, "/results/last", {
    wpm = 99,
    acc = 99,
    mode = "words",
    mode2 = "25",
    timestamp = NOW * 1000,
  })
  service.onConfigChanged()
  check("new key triggers its own streak request", "/users/streak", mock.requests[#mock.requests])

  flushAll(mock)

  local data = mock.state.data
  check("status ready after key switch", "ready", mock.state.status)
  check("data belongs to new account", 1, data.today)
  check("new account last wpm", 99, data.lastWpm)
  check("new account streak", 2, data.currentStreak)
  check("cache binds to a fingerprint", Monkeytype.fingerprint("ANOTHERKEY"), data.accountKey)
  check("cache holds no raw key", false, containsValue(data, "ANOTHERKEY"))
end

section("a missing data directory never blocks a refresh")
do
  local mock = coldMock()
  mock.dataDir = nil
  loadService(mock)
  check("status without a data dir", "ready", mock.state.status)
  check("data still published", true, mock.state.data ~= nil)
end

section("an unscannable activity body falls back to the decoded window")
do
  local mock = coldMock()
  mock.bodies["unscannable"] = {
    message = "ok",
    data = { testsByDays = { 1, 0, 2 }, lastDay = TODAY },
  }
  mock.responses["/users/currentTestActivity"] = {
    ok = true,
    status = 200,
    body = "unscannable",
  }
  loadService(mock)
  check("status with an unscannable body", "ready", mock.state.status)
  check("window total from the decoded table", 3, mock.state.data and mock.state.data.windowTotal)
end

print(string.format("\n%d passed, %d failed", PASSED, FAILED))
os.exit(FAILED == 0 and 0 or 1)
