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
  local env = setmetatable({ noctalia = mock.noctalia, require = pluginRequire }, { __index = _G })
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

section("a quiet tick only asks for the streak")
do
  local mock = coldMockInstance
  local before = mock.state.data.fetchedAt
  mock.clock = mock.clock + 60000
  coldService.update()
  check("one request", 4, #mock.requests)
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
  mock.clock = mock.clock + 61 * 60 * 1000
  route(mock, "/users/streak", { lastResultTimestamp = NOW - 600, length = 3, maxLength = 7 })
  service.update()
  check("tick after the backoff window retries", true, #mock.requests > before)
  check("status recovers", "ready", mock.state.status)
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

print(string.format("\n%d passed, %d failed", PASSED, FAILED))
os.exit(FAILED == 0 and 0 or 1)
