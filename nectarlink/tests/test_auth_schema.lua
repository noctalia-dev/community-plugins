-- Regression tests for observed auth transitions and malformed page fields.
-- Real API/profile/processes are never used.
dofile("tests/test_runtime.lua")
local function copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, child in pairs(v) do
    out[k] = copy(child)
  end
  return out
end
local token, port, invalid = string.rep("a", 64), 12345, false
local jobs, callbacks, changes = {}, 0, 0
noctalia = {
  readFile = function()
    if not token then
      return nil
    end
    return { token = token, port = invalid and 0 or port }
  end,
  json = {
    decode = function(v)
      return v
    end,
    encode = function(v)
      return v
    end,
  },
  http = function(req, cb)
    jobs[#jobs + 1] = { req = req, cb = cb }
    return true
  end,
}
local api = require("./service/api.luau").new(function()
  changes = changes + 1
end)
local function start(body)
  api.request("/test", body, function()
    callbacks = callbacks + 1
  end)
  return jobs[#jobs]
end
local a = start(nil)
local commandA = start({ action = "mock" })
local cfgA = api.credentials()
token = string.rep("b", 64)
api.credentials()
a.cb({ ok = true, status = 200, body = { devices = { { id = "OLD" } } } })
commandA.cb({ ok = true, status = 200, body = { acknowledged = true } })
assert(callbacks == 0 and changes == 1)
local count = #jobs
local rejected
api.request("/test", {}, function(_, _, _, reason)
  rejected = reason
end, cfgA)
assert(
  #jobs == count and rejected == "auth_changed",
  "stale credentials must not send or retry a command"
)
local b = start(nil)
token = string.rep("a", 64)
api.credentials() -- A→B→A must not revive the first A.
a.cb({ ok = true, status = 200, body = {} })
b.cb({ ok = true, status = 200, body = {} })
assert(callbacks == 0)
local active = start(nil)
active.cb({ ok = true, status = 200, body = {} })
assert(callbacks == 1)
local beforeMissing = start(nil)
token = nil
api.credentials()
beforeMissing.cb({ ok = true, status = 200, body = {} })
token = string.rep("a", 64)
api.credentials()
beforeMissing.cb({ ok = true, status = 200, body = {} })
assert(callbacks == 1, "missing→same token must not revive an old request")
local beforeInvalid = start(nil)
invalid = true
api.credentials()
beforeInvalid.cb({ ok = true, status = 200, body = {} })
invalid = false
api.credentials()
local beforePort = start(nil)
port = 12346
api.credentials()
beforePort.cb({ ok = true, status = 200, body = {} })
assert(callbacks == 1)
local beforeSwitch = #jobs
token = string.rep("c", 64)
local transitionError
api.request("/test", { action = "mock" }, function(_, _, _, why)
  transitionError = why
end)
assert(
  #jobs == beforeSwitch and transitionError == "auth_changed",
  "a command composed for the old connection must not be forwarded to new credentials"
)
print(
  "PASS: global auth epoch, A/B/A, token loss/corruption, port rotation and rejected stale validated credentials"
)

-- Actual coordinator must release old busy/pending flags and clear old data.
local watchers, latest, publishes, notices = {}, nil, 0, 0
jobs = {}
token = string.rep("a", 64)
port = 12345
noctalia.getConfig = function()
  return false
end
noctalia.state = {
  watch = function(k, cb)
    watchers[k] = cb
  end,
  set = function(_, v)
    latest = copy(v)
    publishes = publishes + 1
  end,
}
noctalia.notifyError = function()
  notices = notices + 1
end
noctalia.setUpdateInterval = function() end
noctalia.runAsync = function()
  error("no processes")
end
dofile("service.luau")
local function cmd(action, value)
  watchers["nl.command"]({ action = action, device = "one", value = value })
end
local function take(path)
  for i, job in ipairs(jobs) do
    if job.req.url:find(path, 1, true) then
      table.remove(jobs, i)
      return job
    end
  end
  error("missing request " .. path)
end
local function reply(job, data)
  job.cb({ ok = true, status = 200, body = data })
end
local devices = { devices = { { id = "one", online = true, name = "Phone" } } }
local sessions =
  { devices = { { id = "one", keyboard = "enabled", allowed = { keyboard = true } } } }
update()
reply(take("/v1/devices"), devices)
cmd("visible", { open = true, page = "home" })
reply(take("/v1/sessions"), sessions)
local oldDevices = take("/v1/devices")
cmd("type_text", "mock text")
local oldType = take("/v1/type")
cmd("visible", { open = true, page = "home" })
local oldSessions = take("/v1/sessions")
assert(latest.typeBusy)
token = string.rep("b", 64)
cmd("page", { page = "deck", key = "new-auth" })
assert(#latest.devices == 0 and latest.sessions == nil and not latest.typeBusy and notices == 1)
local published = publishes
reply(oldDevices, { devices = { { id = "OLD", online = true } } })
reply(oldSessions, sessions)
reply(oldType, { acknowledged = true })
assert(publishes == published and latest.typeSent == nil)
cmd("visible", { open = true, page = "home" })
cmd("refresh") -- Must start a new devices request immediately, not after a 30s timeout.
reply(take("/v1/devices"), devices)
reply(take("/v1/sessions"), sessions)
cmd("type_text", "new explicit text")
local newType = take("/v1/type")
assert(latest.typeBusy)
reply(oldType, { acknowledged = true })
assert(latest.typeBusy and latest.typeSent == nil)
reply(newType, { acknowledged = true })
assert(not latest.typeBusy and latest.typeSent == 1 and notices == 1)
assert(
  #jobs == 1 and jobs[1].req.url:find("/v1/page", 1, true),
  "no action may be retried on auth change"
)
print(
  "PASS: stale devices/session/command callbacks cannot publish; new requests proceed and actions never replay"
)

-- Invalid fields must fail BEFORE caching and preserve the last valid result.
local cache = { entries = {}, jobs = {}, retry = {}, epoch = 0, clock = 0 }
local snapshot = {}
local command = { device = "one", value = { page = "calls", key = "calls" } }
local pending
local pages = require("./service/pages.luau").new(
  cache,
  { open = true, activePage = command },
  { ticks = 0 },
  snapshot,
  {
    credentials = function()
      return {}
    end,
    request = function(_, _, cb)
      pending = cb
    end,
  },
  function() end,
  function()
    return true
  end,
  copy,
  { updateIntervalMs = 2000, pageCacheLimit = 24, pageRetryTicks = 15 }
)
local good = {
  items = {
    {
      id = "good",
      title = "Call",
      duration = 2,
      date = 100,
      size = 10,
      addresses = {
        "123",
      },
    },
  },
}
pages.read(command)
pending(true, 200, copy(good))
local cases = {
  function(d)
    d.items[1].duration = "bad"
  end,
  function(d)
    d.items[1].duration = -1
  end,
  function(d)
    d.items[1].size = {}
  end,
  function(d)
    d.items[1].date = math.huge
  end,
  function(d)
    d.items[1].duration = 0 / 0
  end,
  function(d)
    d.items[1].title = false
  end,
  function(d)
    d.items[1].id = 3
  end,
  function(d)
    d.items[1].addresses = { true }
  end,
  function(d)
    d.items[1].thumbnailPath = {}
  end,
  function(d)
    d.items = { wrong = d.items[1] }
  end,
  function(d)
    d.items = { [2] = d.items[1] }
  end,
  function(d)
    d.notice = 42
  end,
  function(d)
    d.more = "true"
  end,
  function(d)
    d.active = { id = "call", state = true }
  end,
  function(d)
    d.active = { state = "ringing" }
  end,
  function(d)
    d.albums = { { id = "album", name = false } }
  end,
}
for _, bad in ipairs(cases) do
  local data = copy(good)
  bad(data)
  pages.read(command, false, true)
  pending(true, 200, data)
  assert(snapshot.page.error == "invalid_response" and snapshot.page.stale)
  assert(snapshot.page.data.items[1].duration == 2)
  assert(cache.entries[pages.identity(command)].data.items[1].duration == 2)
end
pages.read(command, false, true)
pending(true, 200, copy(good))
assert(snapshot.page.error == nil and not snapshot.page.stale)
print(
  "PASS: malformed numbers, strings, IDs, arrays, albums and active calls cannot replace a valid cache entry"
)

-- A legacy/bypassed snapshot also must not crash the renderer on bad scalar fields.
local watcher, tree, commands = nil, nil, {}
local fixture = { state = "ready", devices = { { id = "one", name = "Phone", online = true } } }
ui = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      return { kind = kind, props = props, children = children or {} }
    end
  end,
})
panel = {
  render = function(v)
    tree = v
  end,
}
noctalia = {
  getConfig = function() end,
  formatTime = function()
    return "12:00"
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
      watcher = cb
    end,
    set = function(_, v)
      commands[#commands + 1] = v
    end,
  },
}
dofile("panel.luau")
onOpen()
onNavigate("calls")
local key = commands[#commands].value.key
for _, bad in ipairs({
  {
    items = {
      {
        id = "x",
        title = {},
        duration = "bad",
        date = "bad",
        size = true,
        addresses = {
          true,
        },
      },
    },
    notice = 99,
  },
  { items = { false }, active = { state = false } },
  { items = { { id = "x", duration = math.huge, date = 0 / 0 } } },
}) do
  fixture.page = { key = key, status = "ready", data = bad }
  local ok, err = pcall(watcher, fixture)
  assert(ok, err)
end
assert(tree.props.height == 438 and tree.props.width == 828)
print("PASS: renderer survives legacy malformed scalar fields with unchanged panel bounds")
