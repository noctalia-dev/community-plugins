-- Error paths use mocks only: never read a real token or launch an application/browser.
dofile("tests/test_runtime.lua")
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for k, v in pairs(value) do
    result[k] = copy(v)
  end
  return result
end

local raw, readThrows, callback = nil, false, nil
local token = string.rep("a", 64)
local reads = 0
noctalia = {
  readFile = function()
    reads = reads + 1
    if readThrows then
      error("PRIVATE local path")
    end
    return raw
  end,
  json = {
    encode = function(v)
      return v
    end,
    decode = function(v)
      if v == "broken" then
        error("PRIVATE raw JSON")
      end
      return v
    end,
  },
  http = function(_, cb)
    callback = cb
    return true
  end,
}
local api = require("./service/api.luau").new(function() end)
local cfg, reason = api.credentials()
assert(not cfg and reason == "credentials_missing")
readThrows = true
cfg, reason = api.credentials()
assert(not cfg and reason == "credentials_missing")
readThrows = false
raw = "broken"
cfg, reason = api.credentials()
assert(not cfg and reason == "credentials_invalid")
raw = { token = token, port = 1.5 }
cfg, reason = api.credentials()
assert(not cfg and reason == "credentials_invalid")
raw = { token = token, port = 12345 }
local last
local function request()
  api.request("/test", nil, function(ok, status, data, failure)
    last = { ok = ok, status = status, data = data, error = failure }
  end)
end
for status, expected in pairs({
  [0] = "api_unavailable",
  [401] = "unauthorized",
  [403] = "permission",
  [404] = "unsupported",
  [500] = "request_failed",
}) do
  request()
  callback({ ok = false, status = status, body = "PRIVATE response" })
  assert(last.error == expected and not last.ok)
end
request()
callback({ ok = true, status = 200, body = "broken" })
assert(last.error == "invalid_response" and not last.ok)
request()
callback(false)
assert(last.error == "invalid_response" and not last.ok)
request()
callback({ ok = true, status = 200, body = { devices = {} } })
assert(last.ok and last.error == nil)
print("PASS: credential/read exceptions, HTTP reasons, malformed JSON/callback and recovery")

-- Actual service: repeated read failures never generate notification/process spam.
local watchers, jobs, latest, notices, launches = {}, {}, nil, 0, 0
local launchSucceeds = true
raw = nil
noctalia.getConfig = function()
  return false
end
noctalia.state = {
  watch = function(k, cb)
    watchers[k] = cb
  end,
  set = function(_, v)
    latest = copy(v)
  end,
}
noctalia.http = function(req, cb)
  jobs[#jobs + 1] = { req = req, cb = cb }
  return true
end
noctalia.setUpdateInterval = function() end
noctalia.notifyError = function()
  notices = notices + 1
end
noctalia.runAsync = function(...)
  assert(select("#", ...) == 1)
  local argv = ...
  assert(
    argv[1] == "xdg-open"
      and argv[2] == "https://github.com/vladikchi/nectarlink-noctalia/tree/noctalia"
      and #argv == 2
  )
  launches = launches + 1
  return launchSucceeds
end
dofile("service.luau")
for _ = 1, 40 do
  update()
end
assert(latest.error == "credentials_missing" and notices == 0 and launches == 0)
raw = { token = token, port = 12345 }
local function refresh()
  watchers["nl.command"]({ action = "refresh" })
end
local function respondDevices(data, status, ok)
  for i, job in ipairs(jobs) do
    if job.req.url:find("/v1/devices", 1, true) then
      table.remove(jobs, i)
      job.cb({ ok = ok ~= false, status = status or 200, body = data })
      return
    end
  end
  error("no pending devices request")
end
refresh()
respondDevices({ devices = { false } })
assert(latest.error == "invalid_response" and latest.state == "offline")
refresh()
respondDevices({}, 401, false)
assert(latest.error == "unauthorized" and latest.state == "unauthorized")
local before = reads
raw = { token = string.rep("b", 64), port = 12345 }
refresh()
respondDevices({ devices = { { id = "one", online = true, name = "Phone" } } })
assert(reads > before and latest.state == "ready" and latest.error == nil)
assert(notices == 0 and launches == 0)
watchers["nl.command"]({ action = "open_fork" })
assert(launches == 1 and notices == 0)
launchSucceeds = false
watchers["nl.command"]({ action = "open_fork" })
assert(launches == 2 and notices == 1)
print(
  "PASS: service reason propagation, re-read auth, recovery, no read-error spam; fixed URL on explicit click only"
)

-- Actual page cache: errors remain scoped to a page and never poison valid data.
local cache = { entries = {}, jobs = {}, retry = {}, epoch = 0, clock = 0 }
local snapshot = { state = "ready" }
local visibility = { open = true }
local pending
local pages = require("./service/pages.luau").new(cache, visibility, { ticks = 0 }, snapshot, {
  credentials = function()
    return {}
  end,
  request = function(_, _, cb)
    pending = cb
  end,
}, function() end, function()
  return true
end, copy, { pageCacheLimit = 24, pageRetryTicks = 15, updateIntervalMs = 2000 })
local command = { device = "one", value = { key = "apps", page = "apps" } }
visibility.activePage = command
pages.read(command)
pending(true, 200, { items = { { id = "good", title = "Cached" } } })
pages.read(command, false, true)
pending(false, 403, nil, "permission")
assert(snapshot.state == "ready" and snapshot.page.error == "permission")
assert(
  snapshot.page.status == "ready"
    and snapshot.page.stale
    and snapshot.page.data.items[1].id == "good"
)
pages.read(command, false, true)
pending(true, 200, { items = { false } })
assert(snapshot.page.error == "invalid_response" and snapshot.page.data.items[1].id == "good")
local unsupported = { device = "one", value = { key = "photos", page = "photos" } }
visibility.activePage = unsupported
pages.read(unsupported)
pending(false, 404, nil, "unsupported")
assert(snapshot.page.status == "unsupported" and snapshot.page.error == "unsupported")
visibility.activePage = command
pages.read(command)
visibility.activePage = unsupported
pages.read(unsupported)
assert(
  snapshot.page.error == "unsupported",
  "cooldown must preserve the scoped reason across navigation"
)
visibility.activePage = command
pages.read(command, false, true)
pending(true, 200, { items = { { id = "recovered", title = "Recovered" } } })
assert(snapshot.page.error == nil and not snapshot.page.stale)
print(
  "PASS: page-local 403/404, cache retention, invalid item rejection, retry reason persistence and recovery"
)

-- UI: fixed geometry, readable instructions and a help action instead of a guessed cause.
local tree, uiWatcher, commands = nil, nil, {}
local fixture =
  { state = "unconfigured", error = "credentials_missing", devices = {}, cacheEpoch = 0 }
ui = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      return { kind = kind, props = props, children = children or {} }
    end
  end,
})
panel = {
  render = function(value)
    assert(value.props.width == 828 and value.props.height == 438)
    tree = value
  end,
}
noctalia = {
  getConfig = function()
    return nil
  end,
  json = {
    decode = function(v)
      return v
    end,
    encode = function(v)
      return v
    end,
  },
  state = {
    get = function()
      return fixture
    end,
    watch = function(_, cb)
      uiWatcher = cb
    end,
    set = function(_, v)
      commands[#commands + 1] = v
    end,
  },
}
dofile("panel.luau")
local function find(predicate)
  local function walk(node)
    if predicate(node) then
      return node
    end
    for _, child in ipairs(node.children) do
      local found = walk(child)
      if found then
        return found
      end
    end
  end
  return walk(tree)
end
local function key(k)
  return find(function(n)
    return n.props.key == k
  end)
end
onOpen()
assert(key("connection-error").props.text:find("API file unavailable", 1, true))
key("help-fork").props.onClick()
assert(commands[#commands].action == "open_fork")
fixture =
  { state = "ready", devices = { { id = "one", online = true, name = "Phone" } }, cacheEpoch = 0 }
uiWatcher(fixture)
onNavigate("apps")
local pageKey = commands[#commands].value.key
fixture.page = { key = pageKey, status = "unsupported", error = "unsupported" }
uiWatcher(fixture)
assert(find(function(n)
  return n.kind == "label" and n.props.text == "API feature unavailable"
end))
assert(key("help-fork"))
fixture.page =
  { key = pageKey, status = "ready", data = { items = { { id = "good", title = "Saved" } } } }
uiWatcher(fixture)
fixture.page = { key = pageKey, status = "failed", error = "invalid_response" }
uiWatcher(fixture)
assert(key("page-item-good"))
assert(find(function(n)
  return (n.props.tooltip or ""):find("Unexpected API response", 1, true)
end))
assert(key("help-fork"))
print(
  "PASS: visible setup help, page error instructions, retained UI rows with reason tooltip, fixed bounds and help dispatch"
)
