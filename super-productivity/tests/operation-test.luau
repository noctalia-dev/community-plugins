--!nonstrict
local operation = require("./operation")
local function fixture(schema)
  local f = { now = 1000, history = {}, callbacks = {}, refreshes = {}, files = {},
    ready = false, launch = true, writes = true,
    sounds = 0, undo = 0, added = 0, errors = 0, cleared = 0, removed = {}, sent = 0 }
  local function dispatch(_, ...)
    local args = { ... }
    local callback = args[#args]
    table.insert(f.callbacks, callback)
    if f.sync then callback(f.sync) end
  end
  f.api = operation.new({
    protocol = 2, schema = schema or 1,
    now = function() return f.now end, tr = function(key) return key end,
    rest = { add_task = dispatch, set_done = dispatch, start_task = dispatch, stop_task = dispatch, reschedule_task = dispatch },
    refresh = function(callback)
      table.insert(f.refreshes, callback)
      if f.sync_refresh ~= nil then callback(f.sync_refresh, { message = "refresh failed" }) end
    end,
    publish_action = function(value)
      table.insert(f.history, value)
      f.action = value
      if f.on_action then f.on_action(value) end
    end,
    publish = function() end,
    failure_message = function(result) return result.message or result.kind end,
    rest_failure = function(_, message) f.error = message end,
    set_error = function(message) f.error = message end,
    notify_error = function() f.errors += 1; if f.on_notify then f.on_notify() end end,
    notify_added = function() f.added += 1 end,
    complete = function() f.sounds += 1; f.undo += 1 end,
    restore = function() f.undo = 0 end,
    clear_tasks = function() f.cleared += 1 end,
    connection = function() return f.ready, f.now end,
    launch = function() return f.launch, "launch failed" end,
    bridge_paths = function() return "/commands", "/responses" end,
    command_sent = function(at) f.sent += 1; f.lastCommandAt = at end,
    response_received = function() end,
    mkdir = function() return true end,
    encode = function(command) f.command = command; return "encoded" end,
    write = function(path, value) f.files[path] = value; return true end,
    rename = function(source, target)
      if not f.writes then return false, "write failed" end
      f.files[target], f.files[source] = f.files[source], nil
      if f.on_publish then f.on_publish() end
      return true
    end,
    remove = function(path) f.files[path] = nil; table.insert(f.removed, path) end,
    list = function() if f.invalid_list then return "unavailable" end; return f.response and { f.response_name or f.command.id .. ".json" } or {} end,
    decode_file = function() return f.response end,
  })
  function f:submit(kind)
    return self.api:submit({ type = kind, requestId = "same-id", taskId = "task", task = { id = "task" }, input = "input", source = "launcher" })
  end
  function f:reject()
    local before = self.action
    assert(not self.api:submit({ type = "add", requestId = "rejected" }))
    assert(self.action.status == "working" and self.action.requestId == before.requestId)
    assert(self.action.type == before.type and self.action.rejectedRequestId == "rejected")
  end
  function f:respond(ok)
    self.response = { schemaVersion = schema or 1, protocolVersion = 2, id = self.command.id, action = "select", ok = ok, data = { selected = true } }
  end
  return f
end

-- every active phase rejects overlap without transferring ownership.
for _, kind in ipairs({ "add", "refresh", "open" }) do
  local f = fixture()
  assert(f.action.status == "idle")
  f:submit(kind)
  f:reject()
  if kind == "add" then
    f.callbacks[1]({ ok = true, data = { id = "new" } })
    f:reject()
    f.refreshes[1](true)
  elseif kind == "refresh" then f.refreshes[1](true)
  else
    f.ready = true
    f.api:update(f.now)
    assert(f.api:bridge_pinned())
    f:reject()
    f:respond(true)
    f.api:update(f.now)
  end
  assert(f.action.status == "success" and f.action.rejectedRequestId == nil)
  assert(f:submit("refresh"))
  f.refreshes[#f.refreshes](false, { message = "failed" })
  assert(f.action.status == "error" and f.action.error == "failed")
  assert(f:submit("refresh"))
end

for _, result in ipairs({ { ok = true, data = { id = "new" } }, { ok = false, kind = "denied" },
  { ok = false, kind = "timeout", dispatched = true }, { ok = false, kind = "transport_error", dispatched = true } }) do
  local f = fixture()
  f.sync, f.sync_refresh = result, true
  f:submit("add")
  assert(f.action.status == (result.ok and "success" or result.dispatched and "unknown" or "error"))
  local count = #f.history
  f.callbacks[1](result)
  assert(#f.history == count and f.added == (result.ok and 1 or 0))
  f.sync, f.sync_refresh = nil, nil
  f:submit("add")
  f.callbacks[1]({ ok = true })
  assert(f.action.status == "working" and #f.refreshes == (result.ok and 1 or 0))
end

local f = fixture()
f:submit("complete")
f.callbacks[1]({ ok = true, data = { id = "task" } })
f.callbacks[1]({ ok = true })
assert(f.sounds == 1 and f.undo == 1 and #f.refreshes == 1)
f.refreshes[1](false)
assert(f.action.status == "success" and f.action.canUndo and f.cleared == 1)
local count = #f.history
f.refreshes[1](true)
assert(#f.history == count and f.sounds == 1)
f:submit("restore")
f.callbacks[2]({ ok = true })
f.refreshes[1](true)
assert(f.action.status == "working" and f.undo == 0)
f.refreshes[2](true)
assert(f.action.status == "success" and f.action.canUndo == nil)

for _, kind in ipairs({ "timer_start", "timer_stop" }) do
  for _, expected in ipairs({ "success", "error", "unknown" }) do
    f = fixture()
    f:submit(kind)
    f.callbacks[1]({ ok = true })
    assert(f.action.status == "working")
    local current = if (kind == "timer_start") == (expected == "success") then table.freeze({ id = "task" }) else nil
    f.refreshes[1](expected ~= "unknown", nil, table.freeze({ currentTask = current, currentTaskId = current and current.id }))
    assert(f.action.status == expected)
    assert(f.errors == (expected == "success" and 0 or 1))
  end
end

f = fixture()
f.launch = false
f:submit("open")
assert(f.action.status == "error" and f.action.error == "launch failed")
f = fixture()
f:submit("open")
f.now += 30000
f.api:update(f.now)
assert(f.action.status == "error" and f.action.error == "error.launch_failed")

for _, outcome in ipairs({ "valid", "malformed", "timeout", "negative", "synchronous" }) do
  f = fixture()
  f.ready, f.writes = true, false
  f:submit("open")
  assert(f.action.status == "working" and not f.api:bridge_pinned() and f.sent == 0)
  assert(#f.removed == 1)
  f.writes = true
  if outcome == "synchronous" then
    f.on_publish = function() f:respond(true); f.api:update(f.now) end
  end
  f.api:update(f.now)
  local path = "/commands/" .. f.command.id .. ".json"
  if outcome ~= "synchronous" then
    assert(f.api:bridge_pinned() and f.sent == 1)
    if outcome == "valid" then f:respond(true)
    elseif outcome == "malformed" then f.response = { ok = true }
    elseif outcome == "negative" then f:respond(false) end
    if outcome == "timeout" then f.invalid_list = true end
    f.now += 12001
    f.api:update(f.now)
  end
  assert(f.action.status == ((outcome == "valid" or outcome == "synchronous") and "success" or "error"))
  assert(f.files[path] == nil and not f.api:bridge_pinned())
  assert(f.sent == 1 and f.lastCommandAt == 1000, "publication metadata must be recorded exactly once")
  local terminal_count = #f.history
  f.api:update(f.now)
  assert(#f.history == terminal_count and f.sent == 1)
  local old_id = f.command.id
  f.on_publish = nil
  f.invalid_list = false
  f:submit("open")
  f.response_name = old_id .. ".json"
  f:respond(true)
  f.api:update(f.now)
  assert(f.action.status == "working", "late response must not finish a new selection")
end
-- terminal observers can complete a newer refresh without stale diagnostics.
for _, kind in ipairs({ "add", "timer_start" }) do
  f = fixture()
  local terminals = 0
  f.on_action = function(value)
    if value.status ~= "error" then return end
    terminals += 1
    assert(f.error == value.error and f.errors == 0)
    f.sync_refresh = true
    f:submit("refresh")
    f.error = "new refresh"
  end
  f:submit(kind)
  if kind == "add" then f.callbacks[1]({ ok = false, kind = "invalid_response" })
  else
    f.callbacks[1]({ ok = true })
    f.refreshes[1](true, nil, table.freeze({}))
  end
  assert(f.action.status == "success" and f.action.type == "refresh")
  assert(f.error == "new refresh" and terminals == 1 and f.errors == 1)
end

-- notification callbacks cannot suppress an older terminal publication or replace a newer action.
f = fixture()
f.on_notify = function()
  f.sync_refresh = true
  f:submit("refresh")
end
f:submit("add")
f.callbacks[1]({ ok = false, kind = "invalid_response" })
local failed_adds = 0
for _, value in ipairs(f.history) do
  if value.status == "error" and value.type == "add" then failed_adds += 1 end
end
assert(failed_adds == 1 and f.action.status == "success" and f.action.type == "refresh")

-- the status ID must prevent stop confirmation without task details.
f = fixture()
f:submit("timer_stop")
f.callbacks[1]({ ok = true })
f.refreshes[1](true, nil, table.freeze({ currentTaskId = "other-task" }))
assert(f.action.status == "error")

-- both command encoding and response validation use the injected schema.
for _, response_schema in ipairs({ 7, 1 }) do
  f = fixture(7)
  f.ready = true
  f:submit("open")
  assert(f.command.schemaVersion == 7)
  f:respond(true)
  f.response.schemaVersion = response_schema
  f.api:update(f.now)
  assert(f.action.status == (response_schema == 7 and "success" or "error"))
end
print("operation tests passed")
