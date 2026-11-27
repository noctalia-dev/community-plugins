-- Actual service in system Lua; mock transport/processes, never real credentials.
dofile("tests/test_runtime.lua")
local watchers, requests, config, latest, launches = {}, {}, {}, nil, 0
local notices, lastLaunch = {}, nil
local function copy(t)
  if type(t) ~= "table" then
    return t
  end
  local c = {}
  for k, v in pairs(t) do
    c[k] = copy(v)
  end
  return c
end
noctalia = {
  getConfig = function(k)
    return config[k]
  end,
  readFile = function()
    return { token = string.rep("a", 64), port = 12345 }
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
    watch = function(k, cb)
      watchers[k] = cb
    end,
    set = function(_, v)
      latest = copy(v)
    end,
  },
  http = function(req, cb)
    table.insert(requests, { req = req, cb = cb })
    return true
  end,
  runAsync = function(argv)
    launches = launches + 1
    lastLaunch = argv
    return true
  end,
  notifyError = function(_, message)
    table.insert(notices, message)
  end,
  setUpdateInterval = function() end,
}
dofile("service.luau")
local function respond(path, data, ok, status)
  for i, job in ipairs(requests) do
    if job.req.url:find(path, 1, true) then
      table.remove(requests, i)
      job.cb({ ok = ok ~= false, status = status or (ok == false and 500 or 200), body = data })
      return job.req
    end
  end
  error("missing request " .. path)
end
local function command(action, device, value)
  watchers["nl.command"]({ action = action, device = device, value = value })
end
local devices = {
  {
    id = "one",
    online = true,
    ringing = false,
    controls = {
      state = { dnd = false },
      allowed = { dnd = true, wifi = false },
    },
  },
}
update()
assert(#requests == 1)
respond("/v1/devices", { devices = devices })
assert(latest.state == "ready")
command("visible", nil, true)
local sessions = {
  {
    id = "one",
    pc_audio = "off",
    watch = "off",
    phone_audio = "off",
    screen = "off",
    webcam = "off",
    keyboard = "enabled",
    allowed = {
      pc_audio = true,
      watch = false,
      phone_audio = true,
      screen = true,
      webcam = true,
      keyboard = true,
    },
  },
}
respond("/v1/sessions", { devices = sessions })
respond("/v1/notifications", {
  notifications = {
    {
      deviceId = "one", key = "n", appName = "Test", title = "Test", text = "Example",
      timestamp = 1795339860000,
    },
  },
})
assert(latest.notificationsState == "ready" and #latest.notifications == 1)
assert(latest.notifications[1].timestamp == 1795339860000)
respond("/v1/timeline", {
  items = {
    {
      id = "x", deviceId = "one", title = "Event", detail = "PRIVATE", target = "PRIVATE",
      timestamp = 1795340700000,
    },
  },
})
assert(latest.timelineState == "ready" and #latest.timeline == 1)
assert(latest.timeline[1].detail == nil and latest.timeline[1].target == nil)
assert(latest.timeline[1].timestamp == 1795340700000)
respond("/v1/devices", { devices = devices })
command("camera", "missing")
assert(#requests == 0)
command("page", "one", { page = "photos", key = "photos-one" })
command("page", "one", { page = "apps", key = "apps-one", search = "Camera" })
respond("/v1/page", { ok = true, items = { { id = "stale-photo" } } })
assert(latest.page.key == "apps-one" and latest.page.status == "loading")
local pageReq = respond("/v1/page", { ok = true, items = { { id = "camera.pkg" } } })
assert(latest.page.status == "ready" and latest.page.data.items[1].id == "camera.pkg")
assert(pageReq.body.device == "one" and pageReq.body.search == "Camera" and not pageReq.body.key)
command(
  "page_action",
  "one",
  { action = "app", id = "camera.pkg", request_id = "mock-request-0001", confirm = false }
)
assert(#requests == 0)
command(
  "page_action",
  "one",
  { action = "app", id = "camera.pkg", request_id = "mock-request-0001", confirm = true }
)
command(
  "page_action",
  "one",
  { action = "app", id = "camera.pkg", request_id = "mock-request-0001", confirm = true }
)
assert(#requests == 1)
respond("/v1/page-action", { ok = true, accepted = true })
assert(not latest.pageActionBusy and latest.pageActionResult == nil)
local dial = { action = "dial", text = "2025550103", request_id = string.rep("a", 32), confirm = true }
command("page_action", "missing", dial)
assert(#requests == 0 and latest.pageActionRequestId == dial.request_id, "rejected dial still releases the UI lock")
dial.request_id = string.rep("b", 32)
command("page_action", "one", dial)
assert(latest.pageActionBusy and latest.pageActionRequestId == dial.request_id)
command("page_action", "one", dial)
assert(#requests == 1, "do not dispatch a second outgoing call while busy")
local dialReq = respond("/v1/page-action", { ok = true, accepted = true })
assert(dialReq.body.device == "one" and dialReq.body.text == dial.text and dialReq.body.confirm == true)
assert(not latest.pageActionBusy and latest.pageActionRequestId == dial.request_id, "keep the acknowledgement after completion")
command("page_action", "one", dial)
assert(#requests == 0)
local photo = { action = "photo", id = "demo-photo", request_id = string.rep("c", 32), confirm = true }
command("page_action", "one", photo)
assert(latest.pageActionBusy and latest.pageActionRequestId == photo.request_id)
assert(respond("/v1/page-action", { ok = true }).body.id == "demo-photo")
assert(not latest.pageActionBusy and latest.pageActionRequestId == photo.request_id)
command("page_leave")
assert(not latest.page)
command("session", "one", { kind = "watch", on = true })
assert(#requests == 0)
command("session", "one", { kind = "screen", on = true })
respond("/v1/session", { ok = false, error = "invalid_json" }, false, 400)
assert(notices[#notices]:find("format", 1, true) and not latest.sessionBusy)
respond("/v1/sessions", { devices = sessions })
command("session", "one", { kind = "screen", on = true })
command("session", "one", { kind = "screen", on = true })
assert(#requests == 1)
local start = respond("/v1/session", { ok = true, accepted = true })
assert(start.body.device == "one" and start.body.kind == "screen" and start.body.on == true)
assert(latest.sessionBusy and latest.sessions.one.screen == "off") -- Wait for real session state.
sessions[1].screen = "asking"
respond("/v1/sessions", { devices = sessions })
assert(not latest.sessionBusy and latest.sessions.one.screen == "asking")
command("type_text", "one", "example")
respond("/v1/type", { ok = false }, false)
assert(not latest.typeBusy and latest.typeSent == nil)
command("type_text", "one", "example")
respond("/v1/type", { ok = true, sent = true, confirmation = "transport_only" })
assert(latest.typeSent == nil and latest.typeDeliveryDevice == "one")
command("type_text", "one", "example") -- Only an explicit user action repeats text.
respond("/v1/type", { ok = true, acknowledged = true })
assert(latest.typeSent == 1 and latest.typeSentDevice == "one")
devices[1].controls.allowed.wifi = true
devices[1].controls.state.wifi = true
local wifi = { id = "wifi", on = false, request_id = string.rep("1", 32) }
command("phone_toggle", "one", wifi)
assert(#requests == 0 and latest.controlRequestId == wifi.request_id, "API disconnect guard still applies")
wifi.confirm_disconnect = true
wifi.request_id = string.rep("2", 32)
command("phone_toggle", "missing", wifi)
assert(#requests == 0 and latest.controlRequestId == wifi.request_id)
wifi.request_id = string.rep("3", 32)
command("phone_toggle", "one", wifi)
assert(latest.controlBusy and latest.controlRequestId == wifi.request_id)
command("phone_toggle", "one", wifi)
assert(#requests == 1)
local wifiRequest = respond("/v1/phone-toggle", { ok = true }).body
assert(wifiRequest.device == "one" and wifiRequest.on == false and wifiRequest.confirm_disconnect == true)
assert(wifiRequest.request_id == nil, "toggle receipt is internal, not part of the desktop API")
assert(latest.devices[1].controls.state.wifi == true and latest.controlBusy)
devices[1].controls.state.wifi = false
respond("/v1/devices", { devices = devices })
assert(latest.devices[1].controls.state.wifi == false and not latest.controlBusy)
command("phone_toggle", "one", { id = "dnd", on = true })
command("phone_toggle", "one", { id = "dnd", on = true })
assert(#requests == 1)
local control = respond("/v1/phone-toggle", { ok = true })
assert(control.body.device == "one" and control.body.id == "dnd" and control.body.on == true)
assert(latest.controlBusy)
respond("/v1/devices", { devices = devices })
assert(not latest.controlBusy)
assert(latest.devices[1].controls.state.dnd == false) -- Do not fabricate a changed state.
devices[1].controls.allowed.ringer = true
devices[1].controls.state.ringer = "vibrate"
for _, bad in ipairs({
  { id = "ringer", mode = "bad" },
  { id = "ringer", on = true },
  { id = "ringer", mode = "ring", on = false },
  { id = "dnd", on = true, mode = "silent" },
}) do
  command("phone_toggle", "one", bad)
  assert(#requests == 0)
end
for _, mode in ipairs({ "ring", "vibrate", "silent" }) do
  command("phone_toggle", "one", { id = "ringer", mode = mode })
  command("phone_toggle", "one", { id = "ringer", mode = mode })
  assert(#requests == 1)
  control = respond("/v1/phone-toggle", { ok = true })
  assert(control.body.id == "ringer" and control.body.mode == mode and control.body.on == nil)
  respond("/v1/devices", { devices = devices })
  assert(latest.devices[1].controls.state.ringer == "vibrate")
end
devices[1].controls.allowed.ringer = false
command("phone_toggle", "one", { id = "ringer", mode = "ring" })
assert(#requests == 0)
command("camera", "one")
command("camera", "one")
assert(#requests == 1)
local camera = respond("/v1/camera", { ok = true })
assert(camera.body.device == "one" and camera.body.mode == "photo")
assert(latest.cameraBusy == false)
command("ring", "one", false)
local ring = respond("/v1/ring", { ok = true })
assert(ring.body.on == false)
respond("/v1/devices", { devices = devices })
assert(not latest.ringBusy)
command("refresh") -- Leave a history response in flight while disabling it.
config.panel_timeline = false
config.panel_notifications = false
onConfigChanged()
assert(#latest.timeline == 0)
respond("/v1/timeline", { items = { { id = "late", deviceId = "one", title = "Stale event" } } })
assert(#latest.timeline == 0) -- Late callback cannot restore hidden history.
respond(
  "/v1/notifications",
  { notifications = { { deviceId = "one", key = "late", title = "Stale" } } }
)
assert(#latest.notifications == 0)
for _, job in ipairs(requests) do
  assert(not job.req.url:find("/v1/timeline", 1, true))
end
respond("/v1/devices", { devices = devices }) -- Discard stale pre-config poll.
respond("/v1/sessions", { devices = sessions }) -- Discard stale pre-config poll.
respond("/v1/sessions", { devices = sessions })
respond(
  "/v1/devices",
  { devices = { { id = "one", online = true }, { id = "two", online = true } } }
)
command("files_after_close", "one", false)
command("clipboard")
assert(launches == 0)
config.executable = "/fake/app"
command("timeline")
assert(launches == 1)
command("camera", "one")
for _ = 1, 16 do
  update()
end
assert(not latest.cameraBusy) -- Watchdog; no automatic camera retry.
command("session", "one", { kind = "pc_audio", on = true })
-- Current device fixture has two phones; restore a session view with a known
-- explicit recipient. The service does not choose a different phone itself.
if latest.sessionBusy then
  for _ = 1, 16 do
    update()
  end
  assert(not latest.sessionBusy)
end
command("page", "one", { page = "photos", key = "timeout-page", album = "uncached" })
for _ = 1, 16 do
  update()
end
assert(latest.page.status == "failed")
respond("/v1/page", { ok = true, items = { { id = "late" } } })
assert(latest.page.status == "failed")
command("page_action", "one", {
  action = "sms",
  text = "Mock only",
  recipients = { "123" },
  request_id = "timeout-action-0001",
  confirm = true,
})
for _ = 1, 16 do
  update()
end
assert(
  not latest.pageActionBusy
    and latest.pageActionResult == nil
    and notices[#notices]:find("No confirmation", 1, true)
)
local count = 0
for _, job in ipairs(requests) do
  if job.req.url:find("/v1/page-action", 1, true) then
    count = count + 1
  end
end
assert(count == 1) -- No automatic resend after an uncertain timeout.
respond("/v1/page-action", { ok = true, accepted = true })
assert(latest.pageActionResult == nil and notices[#notices]:find("No confirmation", 1, true))
for _, failure in ipairs({
  { "request_limit_restart_required", 409, "Restart the NectarLink app" },
  { "busy", 409, "still handling another action" },
  { "uncertain_check_phone", 409, "No confirmation" },
  { "timeout", 504, "No confirmation" },
}) do
  command("page_action", "one", {
    action = "app",
    id = "mock.app",
    request_id = "failure-action-" .. failure[1],
    confirm = true,
  })
  respond("/v1/page-action", { ok = false, error = failure[1] }, false, failure[2])
  assert(not latest.pageActionBusy and notices[#notices]:find(failure[3], 1, true))
end
command("page", "one", { page = "apps", key = "closed-page" })
command("visible", nil, false)
respond("/v1/page", { ok = true, items = { { id = "late" } } })
command("page_leave")
assert(not latest.page)
-- Simulate a host that coalesced onOpen's visible event: a page read must
-- still be accepted when it is the only command delivered after close.
command("page", "one", { page = "messages", key = "coalesced-open" })
respond("/v1/page", { ok = true, items = {} })
assert(latest.page.key == "coalesced-open" and latest.page.status == "ready")
command("visible", nil, false)

-- Fresh fixture for coordinated revocation and the file handoff.
requests = {}
config.panel_notifications, config.panel_timeline = true, false
dofile("service.luau")
local instance, hidden, kept = string.rep("a", 64), string.rep("b", 64), string.rep("c", 64)
local phone = { id = "one", online = true }
local function deviceResponse(revision, blocked, privateEpoch)
  respond("/v1/devices", {
    devices = { phone }, devicesReady = true, privateMessages = true,
    privateReadEpoch = privateEpoch or "1", pageCacheV2 = true,
    notificationPolicy = { instance = instance, revision = revision, hidden = blocked },
  })
end
command("refresh")
deviceResponse("1", {})
command("visible", "one", true)
local noticeRows = {
  { deviceId = "one", key = "fixture-hidden", appScope = hidden },
  { deviceId = "one", key = "fixture-kept", appScope = kept },
}
respond("/v1/notifications", { notifications = noticeRows })
respond("/v1/sessions", { devices = {} })
command("page", "one", { page = "messages", key = "full-list" })
local threads = { items = {
  { id = "chat:first", kind = "chat", appScope = hidden },
  { id = "test-sms", kind = "sms" },
  { id = "chat:second", kind = "chat", appScope = kept },
} }
respond("/v1/page", threads)
command("page", "one", { page = "messages", key = "reading-chat", thread = "chat:first",
  threads = { page = "messages", key = "full-list" } })
assert(latest.threads.data.items[1].id == "chat:first")
deviceResponse("2", { hidden }) -- The request began under the previous rules.
assert(#latest.notifications == 1 and latest.notifications[1].key == "fixture-kept")
assert(#latest.threads.data.items == 2 and latest.threads.data.items[2].id == "chat:second")
respond("/v1/page", { appScope = hidden, items = { { id = "old-detail" } } })
assert(not latest.page and latest.threads.data.items[1].id == "test-sms")

command("page", "one", { page = "messages", key = "reloaded-list" })
assert(#latest.page.data.items == 2) -- render immediately while the list is refreshed
respond("/v1/page", { items = { threads.items[2], threads.items[3] } })
command("refresh")
deviceResponse("2", { hidden }, "3") -- Disable/enable between polls.
assert(not latest.page and #latest.notifications == 0 and latest.pageRevocations.messages == 1)

local beforeHandoff = launches
command("files_after_close", "other", false)
assert(launches == beforeHandoff)
command("files_after_close", "one", false)
assert(launches == beforeHandoff + 1 and lastLaunch[3] == "send-files")
print(
  "PASS: service privacy/preferences, sessions, wire flags, action receipts, stale replies and no automatic retry"
)
