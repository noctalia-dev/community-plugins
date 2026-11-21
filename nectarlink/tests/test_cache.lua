-- Actual service with delayed mock HTTP. No credentials/phone/PC actions.
dofile("tests/test_runtime.lua")
local watch, latest = {}, nil
local jobs, reads, actions, publishes = {}, 0, 0, 0
local gets = {}
local token = string.rep("a", 64)
local missing = {}
local devices = { { id = "one", name = "Phone", online = true } }
local function copy(v)
  if type(v) ~= "table" then
    return v
  end
  local o = {}
  for k, x in pairs(v) do
    o[k] = copy(x)
  end
  return o
end
noctalia = {
  readFile = function()
    return { token = token, port = 12345 }
  end,
  getConfig = function()
    return nil
  end,
  setUpdateInterval = function() end,
  fileExists = function(path)
    return not missing[path]
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
    watch = function(k, fn)
      watch[k] = fn
    end,
    set = function(_, v)
      latest = copy(v)
      publishes = publishes + 1
    end,
  },
  notifyError = function() end,
  runAsync = function()
    error("No processes allowed")
  end,
  http = function(req, cb)
    if req.url:find("/v1/page-action", 1, true) then
      actions = actions + 1
      table.insert(jobs, { req = req, cb = cb })
      return true
    end
    if req.url:find("/v1/page", 1, true) then
      reads = reads + 1
      table.insert(jobs, { req = req, cb = cb })
      return true
    end
    local path = req.url:match("/v1/[^?]+")
    gets[path] = (gets[path] or 0) + 1
    local data = path == "/v1/devices" and { devices = devices }
      or (
        path == "/v1/sessions" and { devices = {} }
        or (path == "/v1/notifications" and { notifications = {} } or { items = {} })
      )
    cb({ ok = true, status = 200, body = data })
    return true
  end,
}
dofile("service.luau")
local function command(action, value)
  watch["nl.command"]({ action = action, device = "one", value = value })
end
local function page(kind, key, extra)
  local v = { page = kind, key = key }
  for k, x in pairs(extra or {}) do
    v[k] = x
  end
  command("page", v)
end
local function reply(kind, data, status)
  for i, job in ipairs(jobs) do
    if job.req.body.page == kind then
      table.remove(jobs, i)
      job.cb({ ok = not status or status == 200, status = status or 200, body = data })
      return job.req
    end
  end
  error("No request for " .. kind)
end
update()
page("messages", "m1", { limit = 7 })
assert(reads == 1 and latest.page.status == "loading")
page("messages", "m2", { limit = 7 })
assert(reads == 1) -- Deduplicate an in-flight read even when UI key changes.
local req = reply("messages", { items = { { id = "a", title = "A" } }, more = true })
assert(req.body.limit == 7 and latest.page.key == "m2" and latest.page.status == "ready")
command("page_leave", "home")
page("messages", "m3", { limit = 7 })
assert(reads == 1 and latest.page.data.items[1].id == "a")
command("visible", false)
assert(
  latest.page and latest.page.status == "ready",
  "completed view must survive close for immediate paint"
)
page("messages", "m4", { limit = 7 })
assert(reads == 1 and latest.page.status == "ready") -- Warm reopen has no page request.
local before = publishes
for _ = 1, 20 do
  update()
  assert(latest.page.status == "ready" and latest.page.data.items[1].id == "a")
end
assert(reads == 2 and publishes == before, "quiet refresh/unchanged metadata must not redraw")
assert(not gets["/v1/notifications"] and not gets["/v1/sessions"] and not gets["/v1/timeline"])
reply("messages", { items = { { id = "b", title = "B" } }, more = true })
assert(latest.page.data.items[1].id == "b" and publishes == before + 1)
page("messages", "forced", { limit = 7, force = true })
assert(reads == 3 and latest.page.status == "ready" and latest.page.refreshing)
page("messages", "forced-again", { limit = 7, force = true })
assert(reads == 3)
reply("messages", {}, 500)
assert(latest.page.status == "ready" and latest.page.stale and latest.page.data.items[1].id == "b")
local failedReads = reads
page("messages", "failed-reopen", { limit = 7 })
assert(
  latest.page.status == "ready" and latest.page.stale and reads == failedReads,
  "failure must remain visibly stale and back off"
)
page("photos", "photos", { album = "camera" })
page("apps", "apps", { search = "Camera" })
local count = reads
reply("photos", { items = { { id = "p", title = "Photo", thumbnailPath = "/private/a.jpg" } } })
assert(latest.page.key == "apps" and latest.page.status == "loading")
page("photos", "photos-return", { album = "camera" })
assert(reads == count and latest.page.data.items[1].id == "p")
reply("apps", { items = { { id = "app", title = "App" } } })
assert(latest.page.key == "photos-return")
page("apps", "apps-return", { search = "Camera" })
assert(reads == count and latest.page.data.items[1].id == "app")
missing["/private/a.jpg"] = true
page("photos", "missing-preview", { album = "camera" })
assert(
  reads == count + 1
    and latest.page.status == "ready"
    and latest.page.data.items[1].thumbnailPath == nil
)
reply("photos", { items = { { id = "p", thumbnailPath = "/private/b.jpg" } } })
page("photos", "close-pending", { album = "late" })
command("visible", false)
reply("photos", { items = { { id = "late-photo" } } })
assert(latest.page == nil)
count = reads
page("photos", "reopen-completed", { album = "late" })
assert(
  reads == count and latest.page.data.items[1].id == "late-photo",
  "closed read should warm only its own cache"
)
token = string.rep("b", 64)
count = reads
page("messages", "new-auth", { limit = 7 })
assert(
  reads == count and latest.state == "offline" and #latest.devices == 0,
  "new credentials must not reuse the old device authorization"
)
command("refresh") -- Validate the new device connection before reading its pages.
page("messages", "new-auth", { limit = 7 })
assert(reads == count + 1 and latest.page.status == "loading" and latest.page.data == nil)
req = reply("messages", {}, 401)
assert(
  req.headers[1] == "Authorization: Bearer " .. token
    and latest.state == "unauthorized"
    and latest.page == nil
)
update()
update() -- Restore the mocked device snapshot.
for i = 1, 26 do
  page("messages", "lru-" .. i, { thread = "chat:app:" .. i, limit = 6 })
  reply("messages", { items = { { id = tostring(i) } } })
end
count = reads
page("messages", "evicted", { thread = "chat:app:1", limit = 6 })
assert(reads == count + 1, "old entries must be evicted at the cache cap")
reply("messages", { items = { { id = "1" } } })
command("page_leave", "home")
for _ = 1, 10 do
  update()
end
assert(gets["/v1/notifications"] and gets["/v1/sessions"] and gets["/v1/timeline"])
before = publishes
for _ = 1, 10 do
  update()
end
assert(publishes == before, "identical home snapshots must not be republished")
devices = {}
update()
update()
assert(latest.page == nil)
devices = { { id = "one", online = true } }
update()
update()
count = reads
page("messages", "after-removal", { thread = "chat:app:26", limit = 6 })
assert(
  reads == count + 1 and latest.page.status == "loading",
  "removed peer must invalidate old data"
)
reply("messages", { items = { { id = "new" } } })
count = reads
onConfigChanged()
assert(reads == count + 1 and latest.page.data == nil)
req = reply("messages", { items = { { id = "refreshed" } } })
assert(req.body.force == true and latest.page.data.items[1].id == "refreshed")
page("apps", "labelled", { limit = 40 })
req = reply("apps", { items = { { id = "app" } } })
assert(req.body.limit == 40)
count = reads
onConfigChanged()
assert(reads == count and latest.page == nil, "settings must not send the previous app geometry")
page("apps", "icons", { limit = 70 })
assert(reads == count + 1)
req = reply("apps", { items = { { id = "app" } } })
assert(req.body.limit == 70)
count = reads
page("apps", "icons-reopen", { limit = 70 })
assert(reads == count)
page("apps", "labelled-again", { limit = 40 })
assert(reads == count + 1, "different limits must not alias")
reply("apps", { items = { { id = "app" } } })
assert(actions == 0, "reads/cache/navigation must never dispatch actions")
print(
  "PASS: warm reads=0 HTTP, single-flight, stale-while-refresh, quiet redraw suppression, auth invalidation, missing previews, LRU and lazy Home polling"
)
