-- One bounded Home warmup after connection; mocked HTTP only, no actions.
dofile("tests/test_runtime.lua")
local watchers, latest, reads = {}, {}, {}
local devices = { { id = "one", online = true } }
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
  state = {
    watch = function(k, cb)
      watchers[k] = cb
    end,
    set = function(_, v)
      latest = v
    end,
  },
  http = function(req, cb)
    assert(req.method == "GET", "warmup must be read-only")
    local path = req.url:match("/v1/[^?]+")
    reads[path] = (reads[path] or 0) + 1
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
print("PASS: bounded pre-open Home warmup; zero action requests and no hidden polling loop")
