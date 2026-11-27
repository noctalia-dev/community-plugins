-- Regression counters use mocks only: no profile reads, processes or phone actions.
dofile("tests/test_runtime.lua")

local reads, completions, resets, pending = 0, 0, 0, nil
local token = string.rep("a", 64)
local mode = "async"
noctalia = {
  readFile = function()
    reads = reads + 1
    return { token = token, port = 12345 }
  end,
  json = {
    decode = function(v)
      return v
    end,
    encode = function(v)
      return v
    end,
  },
  http = function(request, callback)
    assert(request.headers[1] == "Authorization: Bearer " .. token)
    pending = callback
    if mode == "sync-failure" then
      callback({ ok = false, status = 0 })
      return false
    end
    return true
  end,
}
local api = require("./service/api.luau").new(function()
  resets = resets + 1
end)
local cfg = api.credentials()
api.request("/test", nil, function()
  completions = completions + 1
end, cfg)
assert(reads == 1)
pending({ ok = true, status = 200, body = {} })
pending({ ok = true, status = 200, body = {} })
assert(completions == 1, "duplicate completion escaped guard")
mode = "sync-failure"
api.request("/test", nil, function()
  completions = completions + 1
end)
assert(completions == 2, "sync callback plus false return completed twice")
token = string.rep("b", 64)
api.request("/test", nil, function() end)
assert(resets == 1 and reads == 3, "credentials must rotate, not persist across requests")

-- Inspect each cached preview once; sanitization must not destroy cache originals.
local checks, requests, reply = 0, 0, nil
local exists = true
noctalia.fileExists = function()
  checks = checks + 1
  return exists
end
local visibility = { open = true }
local snapshot, clock = {}, { ticks = 0 }
local command = { device = "one", value = { page = "photos", key = "photos", limit = 5 } }
visibility.activePage = command
local pages = require("./service/pages.luau").new(visibility, clock, snapshot, {
  credentials = function()
    return {}
  end,
  request = function(_, _, done)
    requests = requests + 1
    reply = done
  end,
}, function() end, function()
  return true
end, { updateIntervalMs = 2000, pageCacheLimit = 24, pageRetryTicks = 15 })
local original = { items = { { id = "one", thumbnailPath = "/mock/photo" }, { id = "two" } }, albums = {} }
pages.read(command)
reply(true, 200, original)
requests, checks = 0, 0
pages.read(command)
assert(checks == 1 and requests == 0 and snapshot.page.data == original)
exists = false
checks = 0
pages.read(command)
assert(checks == 1 and requests == 1)
assert(snapshot.page.data.items[1].thumbnailPath == nil)
assert(original.items[1].thumbnailPath == "/mock/photo")
assert(snapshot.page.data.items[1] ~= original.items[1])
assert(snapshot.page.data.items[2] == original.items[2] and snapshot.page.data.albums == original.albums)
exists = true
checks = 0
pages.read(command)
assert(checks == 1 and snapshot.page.data == original)

local pageData = require("./service/page_data.luau")
local apps = { items = { { id = "app", iconPath = "/mock/icon" } } }
local display, valid = pageData.previews(apps, "apps", function(path)
  assert(path == "/mock/icon")
  return false
end)
assert(not valid and display.items[1].iconPath == nil and apps.items[1].iconPath == "/mock/icon")

local merged, complete = pageData.mergePhotoDetails(original, {
  items = { { id = "two", thumbnailPath = "/mock/second" } },
})
assert(complete and merged.items[2].thumbnailPath == "/mock/second")
assert(original.items[2].thumbnailPath == nil and merged.items[2] ~= original.items[2])
assert(merged.items[1] == original.items[1] and merged.albums == original.albums)

-- A hidden panel decodes zero snapshots; opening accepts only the latest epoch.
local watcher, decodes, renders = nil, 0, 0
local fixture = { state = "ready", devices = {}, cacheEpoch = 1 }
ui = setmetatable({}, {
  __index = function(_, kind)
    return function(props, children)
      return { kind = kind, props = props, children = children or {} }
    end
  end,
})
panel = {
  render = function()
    renders = renders + 1
  end,
}
noctalia = {
  getConfig = function()
    return false
  end,
  json = {
    decode = function(v)
      decodes = decodes + 1
      return v
    end,
    encode = function(v)
      return v
    end,
  },
  state = {
    watch = function(_, cb)
      watcher = cb
    end,
    get = function()
      return fixture
    end,
    set = function() end,
  },
}
dofile("panel.luau")
for _ = 1, 100 do
  watcher(fixture)
end
assert(decodes == 0 and renders == 0)
fixture.cacheEpoch = 2
onOpen()
assert(decodes == 1 and renders == 1)
onClose()
for _ = 1, 100 do
  watcher(fixture)
end
assert(decodes == 1 and renders == 1)

-- Identical serialized snapshots reuse decode, but not layout/config checks.
local widgetWatcher, vertical = nil, false
decodes, renders = 0, 0
local raw = "valid"
barWidget = {
  render = function()
    renders = renders + 1
  end,
  setVisible = function() end,
  setTooltip = function() end,
  isVertical = function()
    return vertical
  end,
}
noctalia = {
  getConfig = function(k)
    return k == "show_name"
  end,
  setUpdateInterval = function() end,
  json = {
    decode = function(v)
      decodes = decodes + 1
      if v == "broken" then
        error("malformed JSON")
      end
      if type(v) == "table" then
        return v
      end
      return { devices = { { online = true, name = "Phone" } } }
    end,
  },
  state = {
    watch = function(_, cb)
      widgetWatcher = cb
    end,
    get = function()
      return raw
    end,
  },
}
dofile("widget.luau")
for _ = 1, 100 do
  update()
end
assert(decodes == 1 and renders == 1)
vertical = true
update()
assert(decodes == 1 and renders == 2)
widgetWatcher("broken")
widgetWatcher("broken")
assert(decodes == 2, "malformed repeated JSON must also be bounded")
local mutable = { devices = {} }
widgetWatcher(mutable)
mutable.devices = { { online = true, name = "Changed" } }
widgetWatcher(mutable)
assert(decodes == 4, "mutable fixtures must never use identity cache")
print(
  "PASS: exactly-once HTTP, credential rotation, preview copy/recovery, hidden-panel and widget decode counters"
)
print(
  "COUNTERS: hidden panel 100 updates = 0 decodes; widget 100 identical updates = 1 decode; valid preview = 1 filesystem check, 0 copies"
)
