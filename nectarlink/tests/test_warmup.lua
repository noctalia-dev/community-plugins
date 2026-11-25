-- One bounded Home warmup after connection; mocked HTTP only, no actions.
dofile("tests/test_runtime.lua")
local watchers, latest, reads = {}, {}, {}
local devices = { { id = "one", online = true } }
local v2, time = false, 0
local jobs, pages = {}, {}
noctalia = {
  getConfig = function()
    return nil
  end,
  readFile = function()
    return { token = string.rep("a", 64), port = 12345 }
  end,
  json = {
    encode = function(v)
      return v
    end,
    decode = function(v)
      return v
    end,
  },
  setUpdateInterval = function() end,
  nowMs = function() return time end,
  state = {
    watch = function(k, cb)
      watchers[k] = cb
    end,
    set = function(_, v)
      latest = v
    end,
  },
  http = function(req, cb)
    local path = req.url:match("/v1/[^?]+")
    if path == "/v1/page" then
      assert(v2 and req.method == "POST", "only upgraded page reads may be warmed")
      jobs[#jobs + 1] = cb
      pages[#pages + 1] = req.body
      return true
    end
    assert(req.method == "GET", "warmup must never dispatch actions")
    reads[path] = (reads[path] or 0) + 1
    local data = path == "/v1/devices" and {
      devices = devices, pageCacheV2 = v2, privateMessages = true, localMessageThreads = true,
    }
      or (
        path == "/v1/sessions" and { devices = {} }
        or (path == "/v1/notifications" and { notifications = {} } or { items = {} })
      )
    cb({ ok = true, status = 200, body = data })
    return true
  end,
}
dofile("service.luau")
update()
update()
assert(
  reads["/v1/timeline"] == 1 and reads["/v1/notifications"] == 1 and reads["/v1/sessions"] == 1
)
assert(
  latest.timelineState == "ready"
    and latest.notificationsState == "ready"
    and latest.sessionsState == "ready"
)
for _ = 1, 40 do
  update()
end
assert(
  reads["/v1/timeline"] == 1 and reads["/v1/notifications"] == 1 and reads["/v1/sessions"] == 1,
  "no recurring hidden Home polling"
)
assert(not reads["/v1/page"])

local function command(action, device, value)
  watchers["nl.command"]({ action = action, device = device, value = value })
end
local function advance(ms)
  time = time + ms
  update()
end
local function finish(data)
  local cb = assert(table.remove(jobs, 1))
  cb({ ok = true, status = 200, body = data })
end

v2 = true
devices = { { id = "one", online = true }, { id = "two", online = true } }
command("visible", "two", false)
advance(0)
advance(8000)
assert(#pages == 0, "wait for a stable connection")
advance(2000)
advance(2000)
assert(#pages == 1 and pages[1].device == "two" and pages[1].thread_index)
command("page", "two", { page = "messages", key = "list", limit = 7 })
command("page", "two", { page = "messages", key = "list", limit = 7 })
assert(#pages == 2 and pages[2].local_only, "joining warmup allows one local preview, not another phone read")
table.remove(jobs, 2)({ ok = true, status = 200, body = { items = { { id = "chat:local" } } } })
assert(latest.page.partial and latest.page.data.items[1].id == "chat:local")
finish({ items = { { id = "sms" } } })
assert(latest.page.key == "list" and latest.page.data.items[1].id == "sms")
advance(1000)
assert(#pages == 2, "warmup yields to an open panel")
command("visible", "two", false)
advance(1000)
assert(#pages == 3 and pages[3].photo_rows_only)
finish({ items = { { id = "photo", thumbnailPath = "/cached/photo" } }, albums = {} })
advance(2000)
assert(#pages == 4 and pages[4].page == "apps" and pages[4].limit > 0)
-- A failed warmup is not retried while the panel is closed.
table.remove(jobs, 1)({ ok = false, status = 409, body = { ok = false, error = "timeout" } })
devices[1].online, devices[2].online = false, false
command("refresh")
advance(2000)
devices[1].online, devices[2].online = true, true
command("refresh")
advance(0)
advance(10000)
assert(#pages == 4, "a short reconnect must not start the queue again")
assert(
  reads["/v1/timeline"] == 1 and reads["/v1/notifications"] == 1 and reads["/v1/sessions"] == 1,
  "Home is not warmed twice after an offline/online transition"
)
for _ = 1, 20 do advance(2000) end
assert(#pages == 4, "no frequently recurring hidden page requests")
for _ = 1, 15 do advance(120000) end
advance(1900000)
assert(#pages == 4, "neither a visited section nor a failed warmup starts hidden polling")

-- A permission transition is observable in the normal devices read. Do not
-- probe a known denial in the background; grant queues one read only.
devices[2].appWindowsAllowed = false
command("refresh")
advance(2000)
assert(#pages == 4)
devices[2].appWindowsAllowed = true
command("refresh")
advance(2000)
assert(#pages == 5 and pages[5].page == "apps" and pages[5].device == "two")
finish({ items = { { id = "available-app" } } })
for _ = 1, 30 do advance(2000) end
assert(#pages == 5, "unchanged permission doesn't rearm the queue again")
print("PASS: bounded Home and page warmup, live reads join in-flight work, reconnect preserves cache, no actions")
