-- Actual service with delayed mock HTTP. No credentials/phone/PC actions.
dofile("tests/test_runtime.lua")
local watch, latest = {}, nil
local jobs, reads, actions, publishes = {}, 0, 0, 0
local gets = {}
local delayedNotifications
local token = string.rep("a", 64)
local missing = {}
local devices = { { id = "one", name = "Phone", online = true } }
local localMessageThreads
local pageCacheV2, privateMessages, now, devicesReady
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
  nowMs = function() return now end,
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
    if path == "/v1/notifications" and delayedNotifications then
      delayedNotifications = cb
      return true
    end
    local data = path == "/v1/devices" and {
      devices = devices, localMessageThreads = localMessageThreads,
      pageCacheV2 = pageCacheV2, privateMessages = privateMessages, devicesReady = devicesReady,
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
page("messages", "before-restart", { thread = "chat:app:26", limit = 6, force = true })
reply("messages", { items = { { id = "26" } } })
devices = {}
command("refresh")
assert(latest.state ~= "ready" and not latest.pageRevocations, "first empty reply from older API is provisional")
devices = { { id = "one", online = true } }
command("refresh")
count = reads
page("messages", "restored-legacy", { thread = "chat:app:26", limit = 6 })
assert(reads == count and latest.page.status == "ready")
devices, devicesReady = {}, false
command("refresh")
command("refresh")
assert(latest.state ~= "ready" and not latest.pageRevocations, "startup remains provisional even after several polls")
devices, devicesReady = { { id = "one", online = true } }, true
command("refresh")
page("messages", "restored-ready", { thread = "chat:app:26", limit = 6 })
assert(reads == count and latest.page.status == "ready", "restart must not discard the existing view")
devices = {}
command("refresh")
assert(latest.page == nil)
assert(latest.pageRevocations["device:one"] == 1, "an authoritative empty list confirms removal")
devices = { { id = "one", online = true } }
command("refresh")
count = reads
page("messages", "after-removal", { thread = "chat:app:26", limit = 6 })
assert(
  reads == count + 1 and latest.page.status == "loading",
  "removed peer must invalidate old data"
)
reply("messages", { items = { { id = "new" } } })
count = reads
onConfigChanged()
assert(reads == count and latest.page.data.items[1].id == "new", "unrelated settings keep good pages")
page("apps", "labelled", { limit = 40 })
req = reply("apps", { items = { { id = "app" } } })
assert(req.body.limit == 40)
count = reads
onConfigChanged()
assert(reads == count, "settings must not send the previous app geometry")
page("apps", "icons", { limit = 70 })
assert(reads == count + 1)
req = reply("apps", { items = { { id = "app" } } })
assert(req.body.limit == 70)
count = reads
page("apps", "icons-reopen", { limit = 70 })
assert(reads == count)
page("apps", "labelled-again", { limit = 40 })
assert(reads == count and latest.page.key == "labelled-again", "each geometry keeps its own result")
assert(actions == 0, "reads/cache/navigation must never dispatch actions")

localMessageThreads = true
command("refresh")
count = reads
page("messages", "cold", { limit = 7 })
assert(reads == count + 2)
req = reply("messages", { items = { { id = "chat:local" } } })
assert(req.body.local_only == true and latest.page.partial and latest.page.refreshing)
assert(latest.page.data.items[1].id == "chat:local")
page("messages", "same-query", { limit = 7 })
assert(reads == count + 2 and latest.page.partial)
req = reply("messages", { items = { { id = "sms" }, { id = "chat:local" } } })
assert(not req.body.local_only and not latest.page.partial and latest.page.data.items[1].id == "sms")
page("messages", "warm", { limit = 7 })
assert(reads == count + 2 and latest.page.data.items[1].id == "sms")
page("messages", "denied", { limit = 7, force = true })
reply("messages", { error = "not_allowed" }, 403)
assert(latest.messagesDenied and latest.page.data == nil and latest.page.error == "private_api_disabled")
page("messages", "retry", { limit = 7, force = true })
reply("messages", { items = { { id = "new" } } })
assert(not latest.messagesDenied and latest.page.data.items[1].id == "new")

page("messages", "full-first", { limit = 5 })
local delayedPreview = table.remove(jobs, 1)
assert(delayedPreview.req.body.local_only)
reply("messages", { items = { { id = "full" } } })
delayedPreview.cb({ ok = true, status = 200, body = { items = { { id = "old" } } } })
assert(not latest.page.partial and latest.page.data.items[1].id == "full")
page("messages", "deny-before-full", { limit = 6 })
req = reply("messages", { error = "not_allowed" }, 403)
assert(req.body.local_only and latest.messagesDenied and latest.page.data == nil)
reply("messages", { items = { { id = "late-private" } } })
assert(latest.messagesDenied and latest.page.data == nil)
count = reads
page("messages", "older-page", { limit = 6, offset = 6 })
assert(reads == count + 1)
req = reply("messages", { items = {} })
assert(not req.body.local_only and not latest.messagesDenied)

pageCacheV2, privateMessages, now = true, true, 100000
command("refresh")
page("messages", "first", { limit = 7 })
req = reply("messages", { items = { { id = "chat:local" } } })
assert(req.body.local_only and req.body.thread_index and latest.page.partial)
local all = {}
for i = 1, 22 do all[i] = { id = "sms-" .. i } end
req = reply("messages", { items = all })
assert(req.body.thread_index and #latest.page.data.items == 7 and latest.page.data.more)
now = now + 120000
count = reads
page("messages", "second", { offset = 7, limit = 7 })
assert(reads == count and latest.page.data.items[1].id == "sms-8" and latest.page.stale)
page("messages", "third", { offset = 14, limit = 7 })
assert(reads == count and latest.page.data.items[1].id == "sms-15")
page("messages", "selected", {
  thread = "sms-15", force = true, threads = { page = "messages", key = "third", offset = 14, limit = 7 },
})
assert(reads == count + 2 and latest.threads.key == "third" and latest.threads.refreshing)
req = reply("messages", { items = {}, smsIncomplete = true })
assert(req.body.force and req.body.thread_index)
assert(latest.threads.error == "sms_unavailable" and latest.threads.data.items[1].id == "sms-15")
req = reply("messages", { items = { { id = "body" } } })
assert(req.body.thread == "sms-15" and req.body.force)
assert(latest.page.key == "selected" and latest.page.data.items[1].id == "body")
command("page_action", { action = "sms", text = "fixture", recipients = { "100" },
  request_id = string.rep("a", 32), confirm = true })
local receipt = table.remove(jobs, 1)
assert(receipt.req.url:match("/v1/page%-action$"))
receipt.cb({ ok = true, status = 200, body = { ok = true } })
assert(reply("messages", { items = { { id = "latest-body" } } }).body.thread == "sms-15")
assert(reply("messages", { items = all }).body.thread_index)
assert(latest.page.data.items[1].id == "latest-body" and latest.threads.data.items[1].id == "sms-15")

page("photos", "progressive")
req = reply("photos", { items = { { id = "a", thumbnailPath = "/cached/one" }, { id = "b" } } })
assert(req.body.photo_rows_only and latest.page.status == "ready" and latest.page.refreshing)
assert(#latest.page.data.items == 2 and latest.page.data.items[1].thumbnailPath == "/cached/one")
req = reply("photos", {
  items = { { id = "b", thumbnailPath = "/cached/two" }, { id = "unrelated", thumbnailPath = "/cached/other" } },
  albums = { { id = "album" } },
})
assert(#req.body.photo_ids == 1 and req.body.photo_ids[1] == "b")
assert(latest.page.data.items[2].thumbnailPath == "/cached/two" and not latest.page.refreshing)
assert(#latest.page.data.items == 2 and #latest.page.data.albums == 1)
now = now + 600000
command("page_leave", "home")
delayedNotifications = true
command("refresh")
assert(type(delayedNotifications) == "function")
local notificationJob = delayedNotifications
delayedNotifications = nil
notificationJob({ ok = true, status = 200, body = { notifications = { { deviceId = "one", key = "old" } } } })
assert(latest.notifications[1].key == "old")
delayedNotifications = true
command("refresh")
assert(type(delayedNotifications) == "function")
privateMessages = false
command("refresh")
assert(#latest.notifications == 0, "revocation clears already shown notifications")
delayedNotifications({ ok = true, status = 200, body = { notifications = { { deviceId = "one", key = "late" } } } })
assert(#latest.notifications == 0 and latest.notificationsState == "offline")
delayedNotifications = nil
command("visible", false)
page("photos", "return-after-denial")
assert(latest.page.status == "ready" and latest.page.data.items[2].id == "b")
reply("photos", {}, 500)
assert(latest.page.status == "ready" and latest.page.data.items[2].thumbnailPath == "/cached/two")
assert(latest.messagesDenied and actions == 1)

privateMessages = true
devices[1].smsAllowed = true
command("refresh")
page("messages", "mixed", { limit = 7, force = true })
reply("messages", { items = { { id = "chat:allowed", kind = "chat" } } })
local mixed = { items = { { id = "sms-kept", kind = "sms" }, { id = "chat:allowed", kind = "chat" } } }
reply("messages", mixed)
page("messages", "sms-open", { thread = "sms-kept" })
reply("messages", { items = { { id = "sms-history" } } })
devices[1].smsAllowed = nil
command("refresh")
assert(not (latest.smsDenied and latest.smsDenied.one) and latest.page.data.items[1].id == "sms-history")
page("messages", "sms-in-flight", { thread = "sms-kept", force = true,
  threads = { page = "messages", key = "mixed", limit = 7 } })
devices[1].smsAllowed = false
command("refresh")
assert(latest.smsDenied.one and latest.pageRevocations["sms:one"] == 1)
assert(not latest.page and latest.threads.data.items[1].id == "chat:allowed" and #latest.threads.data.items == 1)
reply("messages", mixed)
reply("messages", { items = { { id = "late-private-sms" } } })
assert(not latest.page and #latest.threads.data.items == 1, "late reads must not republish revoked rows")
count = reads
page("messages", "blocked-sms", { thread = "sms-kept", force = true })
assert(reads == count and latest.page.error == "sms_denied" and not latest.page.data)
page("messages", "chats-after-revocation", { limit = 7 })
assert(latest.page.data.items[1].id == "chat:allowed" and #latest.page.data.items == 1)
devices[1].smsAllowed = nil
command("refresh")
assert(latest.smsDenied.one, "unknown state is not a new grant")
devices[1].smsAllowed = true
command("refresh")
page("messages", "granted-sms", { thread = "sms-kept" })
assert(reads == count + 1 and latest.page.status == "loading", "grant must not revive revoked history")
reply("messages", { error = "sms_denied" }, 403)
assert(latest.smsDenied.one and latest.pageRevocations["sms:one"] == 2 and not latest.messagesDenied)
page("photos", "unchanged-photo")
assert(latest.page.data.items[2].id == "b", "SMS-only revocation must not clear other sections")

-- Start with a clean peer; the first chat preview must survive the failed SMS job.
devices = {}
command("refresh")
devices = { { id = "one", online = true, smsAllowed = true } }
command("refresh")
page("messages", "local-preview", { limit = 7 })
local chats = { items = { { id = "chat:early", kind = "chat" } } }
assert(reply("messages", chats).body.local_only)
reply("messages", { items = chats.items, smsIncomplete = true })
assert(latest.page.partial and latest.page.error == "sms_unavailable")
count = reads
page("messages", "open-local-chat", { thread = "chat:early",
  threads = { page = "messages", key = "local-preview", limit = 7 } })
assert(reads == count + 1 and latest.threads.partial and latest.threads.data.items[1].id == "chat:early")
reply("messages", { items = { { id = "chat-body" } } })

-- ↻ starts the list immediately and queues exactly one refresh of the busy dialog.
now = now + 120000
local opts = { thread = "chat:early", limit = 6,
  threads = { page = "messages", key = "local-preview", limit = 7 } }
page("messages", "refresh-both", opts)
count = reads
opts.force = true
page("messages", "refresh-both", opts)
page("messages", "refresh-both", opts)
assert(reads == count + 1)
assert(not reply("messages", { items = { { id = "chat-old" } } }).body.force)
assert(reads == count + 2)
assert(reply("messages", { items = { { id = "sms-new" } } }).body.force)
assert(reply("messages", { items = { { id = "chat-fresh" } } }).body.force)
assert(latest.threads.data.items[1].id == "sms-new" and latest.page.data.items[1].id == "chat-fresh")
assert(reads == count + 2)

-- Also cover a watchdog timeout (no HTTP callback), not just an incomplete reply.
page("messages", "hanging-chat", { thread = "chat:hanging" })
count = reads
page("messages", "hanging-chat", { thread = "chat:hanging", force = true })
for _ = 1, 16 do update() end
assert(reads == count + 1, "watchdog must release the single queued refresh")
assert(not reply("messages", { items = { { id = "late" } } }).body.force)
assert(latest.page.refreshing and not latest.page.data, "late reply cannot overwrite the newer read")
assert(reply("messages", { items = { { id = "after-watchdog" } } }).body.force)
assert(latest.page.data.items[1].id == "after-watchdog")

page("messages", "abandoned-chat", { thread = "chat:abandoned" })
page("messages", "abandoned-chat", { thread = "chat:abandoned", force = true })
command("page_leave", "guide")
count = reads
page("messages", "back-to-abandoned-chat", { thread = "chat:abandoned" })
reply("messages", { items = {} })
assert(reads == count and latest.page.key == "back-to-abandoned-chat", "leaving cancels its queued refresh even after returning")

-- A failed details fetch does not reload the photo rows or discard previews.
page("photos", "details-fail", { album = "broken-details" })
local rows = { items = { { id = "ready", thumbnailPath = "/cached/ready" }, { id = "missing" } } }
assert(reply("photos", rows).body.photo_rows_only)
reply("photos", {}, 500)
assert(latest.page.error == "photo_details_unavailable" and #latest.page.data.items == 2)
count = reads
page("photos", "details-backoff", { album = "broken-details" })
assert(reads == count and latest.page.data.items[1].thumbnailPath == "/cached/ready")
now = now + 30000
page("photos", "details-retry", { album = "broken-details" })
assert(reads == count + 1 and latest.page.refreshing)
req = reply("photos", { items = { { id = "missing", thumbnailPath = "/cached/missing" } }, albums = {} })
assert(not req.body.photo_rows_only and #req.body.photo_ids == 1 and req.body.photo_ids[1] == "missing")
assert(not latest.page.error and latest.page.data.items[2].thumbnailPath == "/cached/missing")

page("photos", "old-list", { album = "manual-refresh" })
reply("photos", { items = { { id = "old" } } })
reply("photos", {}, 500)
page("photos", "new-list", { album = "manual-refresh", force = true })
req = reply("photos", { items = { { id = "new" } } })
assert(req.body.photo_rows_only and req.body.force and latest.page.data.items[1].id == "new")
reply("photos", { items = { { id = "new", thumbnailPath = "/cached/new" } }, albums = {} })

page("messages", "one-hidden-chat", { thread = "chat:hidden", force = true,
  threads = { page = "messages", key = "local-preview", limit = 7 } })
reply("messages", { items = { { id = "still-here", kind = "sms" } } })
reply("messages", { error = "chat_unavailable" }, 404)
assert(latest.page.error == "chat_unavailable" and not latest.page.data)
assert(latest.threads.data.items[1].id == "still-here")
assert(not (latest.deniedPages and latest.deniedPages["messages:one"]))

page("apps", "needs-elevated", { force = true })
reply("apps", { error = "feature_denied", feature = "mirroring.app_windows",
  upgrade = { action = "raisePower", target = "elevated" } }, 403)
assert(latest.page.error == "apps_elevated" and latest.deniedPages["apps:one"])
assert(not (latest.deniedPages and latest.deniedPages["messages:one"]))
page("messages", "chat-db-retry", { limit = 7, force = true })
local complete = { items = { { id = "kept", kind = "chat" }, { id = "sms", kind = "sms" } } }
reply("messages", complete)
page("messages", "chat-db-unavailable", { limit = 7, force = true })
reply("messages", { items = { { id = "sms", kind = "sms" } }, localChatsIncomplete = true })
assert(latest.page.error == "local_chats_unavailable" and #latest.page.data.items == 2)
assert(latest.page.data.items[1].id == "kept")
print(
  "PASS: warm reads=0 HTTP, single-flight, stale-while-refresh, quiet redraw suppression, auth invalidation, missing previews, LRU and lazy Home polling"
)
