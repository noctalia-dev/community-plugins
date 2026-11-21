-- UI responses are deliberately delayed: a warm service alone cannot hide IPC latency.
-- No real profile, network, process or phone commands are used.
dofile("tests/test_runtime.lua")
local watchers, commands, tree = {}, {}, nil
local fixture = {
  state = "ready",
  cacheEpoch = 0,
  devices = {
    { id = "one", name = "One", online = true },
    { id = "two", name = "Two", online = true },
  },
}
ui = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      return { kind = kind, props = props, children = children or {} }
    end
  end,
})
panel = {
  render = function(value)
    tree = value
  end,
}
noctalia = {
  getConfig = function()
    return nil
  end,
  formatTime = function()
    return "12:00"
  end,
  json = {
    encode = function(v)
      return v
    end,
    decode = function(v)
      return v
    end,
  },
  state = {
    watch = function(k, cb)
      watchers[k] = cb
    end,
    get = function()
      return fixture
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
local function key(value)
  return find(function(n)
    return n.props.key == value
  end)
end
local function button(value)
  return find(function(n)
    return n.kind == "button" and n.props.text == value
  end)
end
local function last(action)
  for i = #commands, 1, -1 do
    if commands[i].action == action then
      return commands[i]
    end
  end
end
local function respond(data, status)
  fixture.page = { key = last("page").value.key, status = status or "ready", data = data }
  watchers["nl.snapshot"](fixture)
end
local function noLoading()
  assert(not find(function(n)
    return n.kind == "label" and (n.props.text or ""):find("Loading from phone", 1, true)
  end), "a remembered page must not flash a loading placeholder")
end
onOpen()
key("nav-apps").props.onClick()
respond({ items = { { id = "one-app", title = "One cached app" } } })
key("nav-calls").props.onClick()
respond({ items = { { id = "call", title = "Caller" } } })
local before = #commands
key("nav-apps").props.onClick()
assert(#commands == before + 1 and last("page").value.page == "apps")
assert(key("page-item-one-app"))
noLoading() -- No service response yet.
respond(nil, "failed")
assert(key("page-item-one-app"))
noLoading()
key("refresh-page").props.onClick()
assert(last("page").value.force == true and key("page-item-one-app"))

-- Search and pagination survive both click navigation and IPC navigation.
key("app-search").props.onChange("Camera")
button("Search").props.onClick()
local searched = last("page").value.key
respond({ items = { { id = "camera", title = "Camera" } }, more = true })
local nextButton = key("pager-next")
assert(nextButton, "pagination button must exist")
nextButton.props.onClick()
local offset = last("page").value.offset
assert(offset > 0)
respond({ items = { { id = "camera-page2", title = "Camera page 2" } } })
onNavigate("calls")
onNavigate("apps")
assert(last("page").value.search == "Camera" and last("page").value.offset == offset)
assert(last("page").value.key ~= searched and key("page-item-camera-page2"))
noLoading()
onClose()
onOpen()
assert(last("page").value.offset == offset and key("page-item-camera-page2"))

-- Returning to a dialog keeps its cursor rather than dropping to the thread list.
onNavigate("messages")
respond({ items = { { id = "thread", title = "Alice", kind = "sms" } } })
key("page-item-thread").props.onClick()
assert(last("page").value.thread == "thread")
respond({ items = { { id = "sms", title = "Message", text = "Retained message" } } })
onNavigate("apps")
onNavigate("messages")
assert(last("page").value.thread == "thread" and key("back-to-threads"))
assert(key("page-item-sms"))
noLoading()

-- A pending confirmation must never be restored along with a dialog.
key("back-to-threads").props.onClick()
respond({ items = { { id = "thread", title = "Alice", kind = "sms" } } })
onNavigate("calls")
respond({ items = { { id = "call", title = "Caller", number = "123", date = 1 } }, dial = true })
key("page-item-call").props.onClick()
button("Call").props.onClick()
assert(button("Confirm"))
local actions = 0
for _, command in ipairs(commands) do
  if command.action == "page_action" then
    actions = actions + 1
  end
end
onNavigate("apps")
onNavigate("calls")
assert(not button("Confirm"))
local afterActions = 0
for _, command in ipairs(commands) do
  if command.action == "page_action" then
    afterActions = afterActions + 1
  end
end
assert(actions == afterActions)

-- Switching phones must not borrow One's search, cursor or response for Two.
onNavigate("home")
local chooser = find(function(n)
  return n.kind == "comboBox" or n.kind == "select"
end)
assert(chooser, "phone selector must exist")
chooser.props.onChange(1)
onNavigate("apps")
assert(last("page").device == "two" and last("page").value.search == "")
assert(not key("page-item-one-app") and not key("page-item-camera-page2"))
respond({ items = { { id = "two-app", title = "Two cached app" } } })
onNavigate("home")
chooser = find(function(n)
  return n.kind == "comboBox" or n.kind == "select"
end)
chooser.props.onChange(0)
onNavigate("apps")
assert(last("page").device == "one" and last("page").value.search == "Camera")
assert(key("page-item-camera-page2") and not key("page-item-two-app"))
noLoading()

-- Album and timestamp+id cursors must be restored together (not just offset).
onNavigate("photos")
local albums = { { id = "camera-album", name = "Camera" } }
respond({ items = {}, albums = albums })
key("photo-album").props.onChange(1)
assert(last("page").value.album == "camera-album")
respond({ items = { { id = "photo1", title = "Photo", date = 123 } }, albums = albums, more = true })
key("pager-next").props.onClick()
assert(last("page").value.before == 123 and last("page").value.before_id == "photo1")
respond({ items = { { id = "photo2", title = "Next photo", date = 122 } }, albums = albums })
onNavigate("apps")
onNavigate("photos")
assert(last("page").value.album == "camera-album" and last("page").value.before_id == "photo1")
assert(key("page-item-photo2"))
noLoading()
onNavigate("apps")

-- Authentication epoch change discards BOTH data and navigation memory.
local devices = fixture.devices
fixture.state = "offline"
fixture.devices = {}
fixture.page = nil
watchers["nl.snapshot"](fixture)
onNavigate("calls")
onNavigate("apps")
assert(key("page-item-camera-page2"))
noLoading()
local beforeReconnect = #commands
fixture.state = "ready"
fixture.devices = devices
watchers["nl.snapshot"](fixture)
assert(#commands == beforeReconnect + 1 and last("page").device == "one")

fixture.cacheEpoch = 1
fixture.page = nil
watchers["nl.snapshot"](fixture)
assert(not key("page-item-camera-page2"))
assert(last("page").value.search == "" and last("page").value.offset == 0)
onNavigate("calls")
assert(not key("page-item-call"))
print(
  "PASS: immediate warm navigation, failed refresh retention, search/page/chat restore, phone/auth isolation, no restored actions"
)

-- LRU and byte budgets are tested directly with the actual presentation module.
local model = { cursors = {}, pageKey = "" }
local memory = require("./ui/page_memory.luau").new(model)
for i = 1, 24 do
  model.pageKey = tostring(i)
  memory.remember({
    key = model.pageKey,
    status = "ready",
    data = { items = { { title = "Row" } } },
  })
end
assert(memory.resolve("1", nil)) -- Touch entry 1 so entry 2 becomes the victim.
model.pageKey = "25"
memory.remember({ key = "25", status = "ready", data = { items = {} } })
assert(memory.resolve("1", nil) and not memory.resolve("2", nil))
model.pageKey = "oversize"
memory.remember({
  key = "oversize",
  status = "ready",
  data = {
    items = { { title = string.rep("x", 4 * 1024 * 1024) } },
  },
})
assert(not memory.resolve("oversize", nil))
memory.clear()
assert(not memory.resolve("1", nil))
for i = 1, 3 do
  model.pageKey = "large" .. i
  memory.remember({
    key = model.pageKey,
    status = "ready",
    data = { items = { { title = string.rep("x", 1500000) } } },
  })
end
assert(
  not memory.resolve("large1", nil)
    and memory.resolve("large2", nil)
    and memory.resolve("large3", nil)
)
print("PASS: presentation LRU, oversize rejection and complete invalidation")

-- The service uses the same byte estimator, but owns its own independent LRU.
local pending
local cache = { entries = {}, jobs = {}, retry = {}, epoch = 0, clock = 0 }
local visibility = { open = true }
local snapshot = {}
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
local pages = require("./service/pages.luau").new(
  cache,
  visibility,
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
  { pageCacheLimit = 24, pageCacheBytes = 10000, updateIntervalMs = 2000, pageRetryTicks = 15 }
)
for i = 1, 3 do
  local cmd =
    { device = "one", value = { key = "service" .. i, page = "apps", search = tostring(i) } }
  visibility.activePage = cmd
  pages.read(cmd)
  pending(true, 200, { items = { { id = "item", title = string.rep("x", 4000) } } })
end
local count = 0
for _ in pairs(cache.entries) do
  count = count + 1
end
assert(count == 2 and snapshot.page.data.items[1].title == string.rep("x", 4000))
local cmd = { device = "one", value = { key = "oversize", page = "apps", search = "oversize" } }
visibility.activePage = cmd
pages.read(cmd)
pending(true, 200, { items = { { id = "item", title = string.rep("x", 11000) } } })
assert(not cache.entries[pages.identity(cmd)] and snapshot.page.status == "ready")
print(
  "PASS: service byte-budget eviction; oversized successful responses remain displayable without caching"
)
