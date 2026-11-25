-- UI responses are deliberately delayed: a warm service alone cannot hide IPC latency.
-- No real profile, network, process or phone commands are used.
dofile("tests/test_runtime.lua")
local watchers, commands, tree = {}, {}, nil
local firstFrame, recordFirst, now = nil, false, 0
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
    if recordFirst and not firstFrame then firstFrame = value end
    tree = value
  end,
}
noctalia = {
  nowMs = function() return now end,
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
local function reopenFromMemory(ms, ...)
  onClose()
  fixture.page, fixture.threads = nil, nil
  now = now + ms
  firstFrame, recordFirst = nil, true
  onOpen()
  local finalTree = tree
  tree = assert(firstFrame, "opening must render before an IPC reply")
  for _, id in ipairs({ ... }) do assert(key(id), "missing from first render: " .. id) end
  noLoading()
  tree, recordFirst = finalTree, false
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
reopenFromMemory(600000, "page-item-camera-page2")
assert(last("page").value.offset == offset and key("page-item-camera-page2"))

-- The two message panes retain separate cursors and use one IPC command.
onNavigate("messages")
respond({ items = { { id = "first", title = "First page", kind = "sms" } }, more = true })
key("threads-pager-next").props.onClick()
assert(last("page").value.thread == nil and last("page").value.offset == 1)
respond({ items = { { id = "thread", title = "Alice", kind = "sms" } } })
local leftKey = last("page").value.key
local oldLeftClick = key("thread-item-thread").props.onClick
oldLeftClick()
assert(last("page").value.thread == "thread" and last("page").value.offset == 0 and key("thread-item-thread"))
respond({ items = { { id = "older", title = "Older", date = 20 } }, more = true })
key("pager-next").props.onClick()
assert(last("page").value.before == 20 and last("page").value.before_id == "older")
respond({ items = { { id = "sms", title = "Message", subtitle = "Retained message" } } })
onNavigate("apps")
onNavigate("messages")
assert(last("page").value.thread == "thread" and last("page").value.before == 20)
assert(key("threads-pager-prev") and key("thread-item-thread") and key("page-item-sms"))
noLoading()
key("refresh-page").props.onClick()
local refresh = last("page").value
assert(refresh.force and refresh.thread == "thread" and refresh.before == 20)
assert(refresh.threads.key == leftKey and refresh.threads.offset == 1)
assert(key("thread-item-thread") and key("page-item-sms"), "refresh must not blank either pane")

fixture.threads = { key = leftKey, status = "ready", kind = "messages", thread = "", device = "one",
  data = { items = { { id = "updated-left", kind = "sms" } } } }
watchers["nl.snapshot"](fixture)
reopenFromMemory(300000, "thread-item-updated-left", "page-item-sms")
assert(key("thread-item-updated-left") and key("page-item-sms"), "reopen uses the latest left pane")

-- Returning to a section must not replay an action or revive an old click.
key("back-to-threads").props.onClick()
assert(last("page").value.key == leftKey and last("page").value.offset == 1)
respond({ items = { { id = "thread", title = "Alice", kind = "sms" } } })
onNavigate("calls")
respond({
  items = { { id = "call", title = "Caller", number = "123", date = 1 } }, dial = true,
  active = { id = "incoming", state = "ringing" }, control = true,
})
local oldAnswer = key("active-answer").props.onClick
assert(not last("page_action"))
onNavigate("apps")
onNavigate("calls")
oldAnswer()
assert(key("active-answer") and not last("page_action"))

-- Switching phones must not borrow One's search, cursor or response for Two.
onNavigate("home")
local chooser = find(function(n)
  return n.kind == "comboBox" or n.kind == "select"
end)
assert(chooser, "phone selector must exist")
chooser.props.onChange(1)
onNavigate("messages")
assert(last("page").device == "two" and not key("thread-item-thread") and not key("page-item-sms"))
local beforeOldList = #commands
oldLeftClick()
assert(#commands == beforeOldList, "an old callback must not read a thread from another phone")
onNavigate("calls")
respond({ items = {}, active = { id = "incoming", state = "ringing" }, control = true })
local beforeAbandoned = #commands
oldAnswer()
assert(#commands == beforeAbandoned, "an old call button must not act on either phone")
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
reopenFromMemory(600000, "page-item-photo2")
assert(last("page").value.album == "camera-album" and last("page").value.before_id == "photo1")
onNavigate("apps")
fixture.messagesDenied = true
watchers["nl.snapshot"](fixture)
onNavigate("photos")
assert(key("page-item-photo2"), "a messages permission change must not evict photos")
assert(last("page").value.before_id == "photo1")
onNavigate("messages")
fixture.messagesDenied = nil
respond({ items = { { id = "before-revocation", title = "Cached chat", kind = "chat" } } })
onClose()
-- The panel missed the revoked state while hidden; the revision still clears old data.
fixture = { state = "ready", cacheEpoch = 0, devices = fixture.devices, pageRevocations = { messages = 1 } }
onOpen()
assert(not key("thread-item-before-revocation"))
onNavigate("photos")
assert(key("page-item-photo2"), "an unseen Messages revocation must not invalidate photos")
onNavigate("messages")
respond({ items = { { id = "private-sms", kind = "sms" }, { id = "chat:keep", kind = "chat" } } })
key("thread-item-private-sms").props.onClick()
respond({ items = { { id = "private-history", title = "Private history" } } })
assert(key("page-item-private-history"))
onClose()
fixture = {
  state = "ready", cacheEpoch = 0, devices = fixture.devices,
  pageRevocations = { messages = 1, ["sms:one"] = 1 }, smsDenied = { one = true },
}
onOpen()
assert(last("page").value.thread == nil and not key("page-item-private-history"))
assert(not key("thread-item-private-sms") and key("thread-item-chat:keep"))
assert(not key("new-sms").props.onClick)
onNavigate("photos")
assert(key("page-item-photo2"), "an SMS-only revocation must not invalidate photos")
onNavigate("messages")
respond({ items = { { id = "chat:keep", kind = "chat" } } })
key("thread-item-chat:keep").props.onClick()
respond({ items = { { id = "chat-body", subtitle = "Fixture body" } } })
key("page-item-chat-body").props.onClick()
assert(key("message-detail"))
fixture.page = { key = last("page").value.key, status = "failed", kind = "messages",
  thread = "chat:keep", device = "one", error = "chat_unavailable" }
watchers["nl.snapshot"](fixture)
assert(not key("message-detail") and key("message-state"))
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

onNavigate("messages")
local scope, keep = string.rep("a", 64), string.rep("b", 64)
local policy = { instance = string.rep("c", 64), revision = "1", hidden = {} }
fixture.notificationPolicy = policy
fixture.smsDenied = nil
watchers["nl.snapshot"](fixture)
local listKey = last("page").value.key
fixture.page = { key = listKey, status = "ready", kind = "messages", thread = "", device = "one", data = { items = {
  { id = "chat:hide", kind = "chat", appScope = scope },
  { id = "chat:keep", kind = "chat", appScope = keep },
  { id = "test-sms", kind = "sms" },
} } }
watchers["nl.snapshot"](fixture)
key("thread-item-chat:hide").props.onClick()
respond({ items = { { id = "open-text", subtitle = "Fixture" } }, appScope = scope })
key("page-item-open-text").props.onClick()
assert(key("message-detail"))
onClose()
fixture = {
  state = "ready", cacheEpoch = 1, devices = fixture.devices, pageRevocations = fixture.pageRevocations,
  notificationPolicy = { instance = policy.instance, revision = "2", hidden = { [scope] = true } },
}
onOpen()
assert(not key("message-detail") and not key("thread-item-chat:hide"))
assert(key("thread-item-chat:keep") and key("thread-item-test-sms"))
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
local visibility = { open = true }
local snapshot = {}
local pages = require("./service/pages.luau").new(
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
  { pageCacheLimit = 24, pageCacheBytes = 10000, updateIntervalMs = 2000, pageRetryTicks = 15 }
)
local requestedPages = {}
for i = 1, 3 do
  local cmd =
    { device = "one", value = { key = "service" .. i, page = "apps", search = tostring(i) } }
  requestedPages[i] = cmd
  visibility.activePage = cmd
  pages.read(cmd)
  pending(true, 200, { items = { { id = "item", title = string.rep("x", 4000) } } })
end
assert(not pages.hasCachedPage(requestedPages[1]))
assert(pages.hasCachedPage(requestedPages[2]) and pages.hasCachedPage(requestedPages[3]))
assert(snapshot.page.data.items[1].title == string.rep("x", 4000))
local cmd = { device = "one", value = { key = "oversize", page = "apps", search = "oversize" } }
visibility.activePage = cmd
pages.read(cmd)
pending(true, 200, { items = { { id = "item", title = string.rep("x", 11000) } } })
assert(not pages.hasCachedPage(cmd) and snapshot.page.status == "ready")
print(
  "PASS: service byte-budget eviction; oversized successful responses remain displayable without caching"
)
