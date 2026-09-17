--!nonstrict
-- real sources are bundled beside this test by test_service_launcher.py.
local sources = require("./service-launcher-sources")
local scenario = ...
local function clone(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end

local on_rename
local now = 1000000
local values, watchers, files, encoded = {}, {}, {}, {}
local requests, pending_http, commands, action_history, queued_intents, async_runs = {}, {}, {}, {}, {}, {}
local sync_http, queue_intents, deny_http = false, false, false
local query, cleared = "", 0
local timer_id, fail_refresh, omit_timer_task = nil, false, false
local config = { launch_method = "native", bridge_dir = "/fixture/bridge", sound_on_complete = false }
local process_probes, running_commands = {}, { superproductivity = true }
local installed_flatpak = false
local file_reads, directory_scans, snapshots, notifications = {}, 0, 0, {}
local task_data = {}
local function encode(value)
  local key = "json-" .. tostring(#encoded + 1)
  table.insert(encoded, clone(value))
  return key
end
local function decode(value)
  local index = tonumber(tostring(value):match("^json%-(%d+)$"))
  return index and clone(encoded[index]) or nil
end
local function write_metadata(name, value)
  files["/fixture/bridge/" .. name] = { text = encode(value), mtime = now }
end
local function heartbeat(status, timestamp)
  write_metadata("connection.json", {
    schemaVersion = 1, protocolVersion = 2, companionVersion = "2.0.0",
    status = status or "ready", updatedAt = timestamp or now,
  })
end
heartbeat()
write_metadata("change.json", {
  schemaVersion = 1, protocolVersion = 2, companionVersion = "2.0.0",
  sequence = 1, changedAt = now, reason = "ready",
})
local function deliver(key, value)
  for _, callback in ipairs(watchers[key] or {}) do callback(clone(value)) end
end
local function http_response(item)
  local request = item.request
  if fail_refresh and request.method == "GET" then
    item.callback({ ok = false, error = "confirmation unavailable" })
    return
  end
  local data, status = {}, 200
  if request.method == "GET" and request.url:find("/tasks", 1, true) then data = task_data end
  if request.url:find("/status", 1, true) then data = { taskCount = 0, currentTaskId = timer_id, currentTask = not omit_timer_task and timer_id and { id = timer_id, title = "Timer", isDone = false } or nil } end
  if request.url:find("/start", 1, true) then
    data = { currentTaskId = "task-1" }
  elseif request.url:find("/task-control/stop", 1, true) then
    data = {}
  elseif request.method == "PATCH" then
    data = { id = "task-1", title = "Due task", isDone = decode(request.body).isDone }
  elseif request.method == "POST" then
    data = { id = "captured", title = "Task", isDone = false }
    status = 201
  end
  item.callback({ ok = true, status = status, body = encode({ ok = true, data = data }) })
end
local runtime = {
  pluginDir = function() return "/fixture/plugin" end,
  nowMs = function() return now end,
  getConfig = function(key)
    return config[key]
  end,
  getenv = function(key) return key == "XDG_CONFIG_HOME" and "/fixture/config" or "/fixture/data" end,
  expandPath = function(value) return value:gsub("^~", "/fixture/home") end,
  flatpakAppInstalled = function() return installed_flatpak end,
  readFile = function(file)
    file_reads[file] = (file_reads[file] or 0) + 1
    if file == "/fixture/config/superProductivity/local-rest-api-token" then return string.rep("A", 32) end
    return files[file] and files[file].text or nil
  end,
  fileInfo = function(file)
    local value = files[file]
    return value and { mtime = value.mtime, size = #value.text, isDir = false } or nil
  end,
  fileExists = function(file) return files[file] ~= nil end,
  mkdirAll = function() return true end,
  writeFile = function(file, text) files[file] = { text = text, mtime = now }; return true end,
  renameFile = function(source, target)
    files[target], files[source] = files[source], nil
    table.insert(commands, decode(files[target].text))
    if on_rename then on_rename() end
    return true
  end,
  removeFile = function(file) files[file] = nil; return true end,
  listDir = function(directory)
    directory_scans += 1
    local names = {}
    for file in pairs(files) do
      if file:sub(1, #directory + 1) == directory .. "/" then table.insert(names, file:sub(#directory + 2)) end
    end
    return names
  end,
  commandExists = function() return true end,
  processMatches = function(callback, ...)
    local arguments = { ... }
    table.insert(process_probes, arguments)
    callback(running_commands[arguments[1]] == true)
    return true
  end,
  runAsync = function(spec, callback, timeout)
    table.insert(async_runs, { spec = clone(spec), callback = callback, timeout = timeout })
    return true
  end,
  setUpdateInterval = function() end,
  sound = { load = function(_, _, callback) callback(true); return true end, play = function() end },
  log = function() end,
  notify = function(title, body) table.insert(notifications, { title = title, body = body }) end,
  notifyError = function() end,
  tr = function(key) return key end,
  string = { trim = function(value) return value:match("^%s*(.-)%s*$") end },
  json = { encode = encode, decode = decode },
  state = {
    get = function(key) return clone(values[key]) end,
    set = function(key, value)
      if key == "super-productivity.snapshot" then snapshots += 1 end
      values[key] = clone(value)
      if key == "super-productivity.action" then table.insert(action_history, clone(value)) end
      if queue_intents and key == "super-productivity.intent" then
        table.insert(queued_intents, clone(value))
      else
        deliver(key, value)
      end
    end,
    watch = function(key, callback)
      watchers[key] = watchers[key] or {}
      table.insert(watchers[key], callback)
    end,
  },
  http = function(request, callback)
    table.insert(requests, clone(request))
    if deny_http then return false end
    local item = { request = request, callback = callback }
    if sync_http then http_response(item) else table.insert(pending_http, item) end
    return true
  end,
}
local cache = {}
local function load_source(name, extra)
  local env = setmetatable({ noctalia = runtime }, { __index = getfenv() })
  for key, value in pairs(extra or {}) do env[key] = value end
  env.require = function(path)
    local module = path:gsub("^%./", ""):gsub("%.luau$", "")
    if cache[module] == nil then cache[module] = load_source(module) end
    return cache[module]
  end
  local chunk = assert(loadstring(sources[name], "@" .. name .. ".luau"))
  setfenv(chunk, env)
  return chunk(), env
end
local _, service = load_source("service")
local _, launcher = load_source("launcher", {
  launcher = {
    setResults = function() end,
    setQuery = function(value) query = value; cleared += 1 end,
  },
})
local panel_tree
local fake_ui = setmetatable({}, { __index = function(_, kind)
  return function(props, children) return { kind = kind, props = props, children = children or {} } end
end })
local _, panel_env = load_source("panel", {
  ui = fake_ui,
  panel = { render = function(tree) panel_tree = tree end, setNeedsFrameTick = function() end },
})
local function capture_input(node)
  if node.kind == "input" then return node.props end
  for _, child in ipairs(node.children) do
    local found = capture_input(child)
    if found then return found end
  end
end
local common = cache.common
local function action() return runtime.state.get(common.ACTION_KEY) end
local function snapshot() return runtime.state.get(common.SNAPSHOT_KEY) end
local function finish_http()
  local count = 0
  while #pending_http > 0 do
    count += 1
    assert(count <= 20, "unexpected REST replay")
    http_response(table.remove(pending_http, 1))
  end
end
local function capture(text)
  query = text
  launcher.onQuery(text)
  launcher.onActivate("add")
end
local function additions()
  local count = 0
  for _, request in ipairs(requests) do if request.method == "POST" then count += 1 end end
  return count
end
finish_http()
service.update()
finish_http()
assert(snapshot().restStatus == "ready" and snapshot().bridgeStatus == "ready")
assert(snapshot().appRunning == true)

if scenario:sub(1, 6) == "panel-" then
  panel_env.onOpen()
  panel_env.onCaptureChanged("keep draft")
  if scenario == "panel-success" then
    sync_http = true
    panel_env.onCaptureAdd()
    assert(capture_input(panel_tree).value == "" and additions() == 1)
    panel_env.onCaptureChanged("second")
    panel_env.onCaptureSubmit("second")
    assert(capture_input(panel_tree).value == "" and additions() == 2)
  elseif scenario == "panel-error" then
    sync_http, deny_http = true, true
    panel_env.onCaptureAdd()
    assert(capture_input(panel_tree).value == "keep draft" and additions() == 1)
    deny_http = false
    panel_env.onCaptureAdd()
    assert(capture_input(panel_tree).value == "" and additions() == 2)
  elseif scenario == "panel-rejection" then
    queue_intents = true
    local owner = common.send_intent("refresh")
    panel_env.onCaptureAdd()
    queue_intents = false
    for _, intent in ipairs(queued_intents) do deliver(common.INTENT_KEY, intent) end
    assert(action().requestId == owner and action().rejectedRequestId ~= nil)
    assert(capture_input(panel_tree).value == "keep draft" and not capture_input(panel_tree).enabled)
    panel_env.onCaptureSubmit("keep draft")
    assert(additions() == 0)
    finish_http()
    assert(capture_input(panel_tree).value == "keep draft" and capture_input(panel_tree).enabled)
    panel_env.onCaptureAdd()
    finish_http()
    assert(capture_input(panel_tree).value == "" and additions() == 1)
  else error("unknown panel scenario") end
elseif scenario == "idle-ticks" then
  local before, reads, requests_before = snapshots, file_reads["/fixture/bridge/change.json"], #requests
  for _ = 1, 20 do
    now += 1000
    service.update()
  end
  assert(snapshots == before, "idle ticks and unchanged process probes must not publish")
  assert(directory_scans == 0, "idle ticks must not scan responses")
  assert(file_reads["/fixture/bridge/change.json"] == reads, "unchanged change metadata must not be read")
  assert(#requests == requests_before, "idle ticks must not refresh REST")
  now += 2000
  write_metadata("change.json", {
    schemaVersion = 1, protocolVersion = 2, companionVersion = "2.0.0",
    sequence = 2, changedAt = now, reason = "test",
  })
  service.update()
  finish_http()
  assert(file_reads["/fixture/bridge/change.json"] == reads + 1)
  assert(#requests == requests_before + 4 and snapshot().changeSequence == 2)
  local saved = files["/fixture/bridge/change.json"]
  files["/fixture/bridge/change.json"] = nil
  now += 2000
  service.update()
  assert(snapshot().hookStatus == "waiting")
  files["/fixture/bridge/change.json"] = saved
  now += 2000
  service.update()
  assert(file_reads["/fixture/bridge/change.json"] == reads + 2, "reappearing metadata must be read again")
  assert(snapshot().hookStatus == "ready")
elseif scenario == "change-clock-skew" then
  local requests_before = #requests
  local changed_at = now + 10000
  write_metadata("change.json", {
    schemaVersion = 1, protocolVersion = 2, companionVersion = "2.0.0",
    sequence = 2, changedAt = changed_at, reason = "test",
  })
  now += 2000
  service.update()
  assert(snapshot().hookStatus == "error" and snapshot().changeSequence == 1)
  assert(#requests == requests_before, "future metadata must not refresh REST")
  now = changed_at
  service.update()
  finish_http()
  assert(snapshot().hookStatus == "ready" and snapshot().hookError == "")
  assert(snapshot().changeSequence == 2 and snapshot().changedAt == changed_at)
  assert(#requests == requests_before + 4, "unchanged metadata must refresh REST once the clock catches up")
  local reads = file_reads["/fixture/bridge/change.json"]
  now += 2000
  service.update()
  assert(file_reads["/fixture/bridge/change.json"] == reads, "valid metadata must remain cached")
  assert(#requests == requests_before + 4, "recovered metadata must not repeat the refresh")
elseif scenario == "terminal-refresh-reentrancy" then
  local terminals = 0
  runtime.state.watch(common.ACTION_KEY, function(value)
    if value.status == "error" and value.type == "add" then
      terminals += 1
      sync_http = true
      common.send_intent("refresh", {})
      assert(action().status == "success" and action().type == "refresh")
    end
  end)
  common.send_intent("add", { input = "Failure" })
  local failed = table.remove(pending_http, 1)
  failed.callback({ ok = true, status = 200, body = "" })
  assert(terminals == 1)
  assert(snapshot().restStatus == "ready", "old failure must not overwrite the reentrant refresh")
elseif scenario == "selection-synchronous" then
  now += 123
  on_rename = function()
    local command = commands[#commands]
    write_metadata("responses/" .. command.id .. ".json", {
      schemaVersion = 1, protocolVersion = 2, id = command.id, action = "select", ok = true,
    })
    service.update()
  end
  runtime.state.watch(common.ACTION_KEY, function(value)
    if value.status == "success" and value.type == "select" then
      sync_http = true
      common.send_intent("refresh", {})
      assert(snapshot().lastCommandAt == now and snapshot().lastResponseAt == now)
    end
  end)
  common.send_intent("open", { taskId = "task-1" })
  assert(action().status == "success" and action().type == "refresh")
  assert(snapshot().lastCommandAt == now and snapshot().lastResponseAt == now)
elseif scenario == "selection-pinning" then
  common.send_intent("open", { taskId = "task-1" })
  config.bridge_dir = "/fixture/other"
  service.onConfigChanged()
  assert(snapshot().bridgeDir == "/fixture/bridge")
  local command = commands[#commands]
  write_metadata("responses/" .. command.id .. ".json", {
    schemaVersion = 1, protocolVersion = 2, id = command.id, action = "select", ok = true,
  })
  service.update()
  assert(action().status == "success")
  service.onConfigChanged()
  assert(snapshot().bridgeDir == "/fixture/other")
elseif scenario == "confirmation-timeout" then
  common.send_intent("timer_toggle", { taskId = "task-1" })
  http_response(table.remove(pending_http, 1))
  assert(action().status == "working" and #pending_http == 4)
  now += 16000
  service.update()
  assert(action().status == "unknown" and action().error == "error.timer_confirmation_unknown")
  local before = #action_history
  finish_http()
  assert(#action_history == before, "late refresh responses cannot repeat terminal publication")
elseif scenario == "response-scanning" then
  write_metadata("responses/orphan.json", { ok = true })
  service.update()
  assert(directory_scans == 0 and files["/fixture/bridge/responses/orphan.json"] ~= nil)
  common.send_intent("open", { taskId = "task-1" })
  now += 1000
  service.update()
  assert(directory_scans == 1 and action().status == "working")
  local command = commands[#commands]
  write_metadata("responses/" .. command.id .. ".json", {
    schemaVersion = 1, protocolVersion = 2, id = command.id, action = "select", ok = true,
  })
  service.update()
  assert(directory_scans == 2 and action().status == "success")
  service.update()
  assert(directory_scans == 2, "completed selection must stop scanning")
  common.send_intent("open", { taskId = "task-1" })
  now += 12001
  service.update()
  assert(action().status == "error" and action().error == "error.command_timeout")
  assert(snapshot().lastError == "error.command_timeout")
  local scans = directory_scans
  service.update()
  assert(directory_scans == scans, "expired selection must stop scanning")
elseif scenario == "time-publication" then
  task_data = { { id = "task-1", title = "Due task", isDone = false, dueWithTime = now + 1000 } }
  config.notify_due = true
  common.send_intent("refresh")
  finish_http()
  assert(snapshot().view.task.id == "task-1")
  local before = snapshots
  now += 1000
  service.update()
  assert(#notifications == 1 and notifications[1].body == "Due task", "due notifications retain second-level checks")
  assert(snapshots == before, "due notification alone does not change the snapshot")
  now = math.floor(now / 60000) * 60000 + 59000
  service.update()
  assert(snapshots == before)
  now += 1000
  service.update()
  assert(snapshots == before + 1, "minute rollover must refresh relative due text")
  service.update()
  assert(snapshots == before + 1 and #notifications == 1)
  common.send_intent("complete", { taskId = "task-1" })
  finish_http()
  local expiry = snapshot().undo.expiresAt
  now = expiry - 1
  service.update()
  assert(snapshot().undo ~= nil)
  before = snapshots
  now = expiry
  service.update()
  assert(snapshot().undo == nil and snapshots == before + 1, "undo expiry must publish removed fields immediately")
elseif scenario == "rest-timeout-ticks" then
  common.send_intent("add", { input = "timeout" })
  now += 16000
  service.update()
  assert(action().status == "unknown" and snapshot().restStatus == "timeout", "idle-loop optimization must preserve REST timeouts")
elseif scenario:sub(1, 7) == "launch-" then
  local command = "custom-productivity"
  if scenario == "launch-path" or scenario == "launch-missing-path" then
    command = "/fixture/My Apps/Custom Productivity"
    if scenario == "launch-path" then files[command] = { text = "executable", mtime = now } end
  elseif scenario == "launch-invalid" then
    command = "custom-productivity --flag"
  elseif scenario == "launch-default" then
    command = "superproductivity"
  end
  config.native_command = command
  local flatpak = scenario == "launch-flatpak" or scenario == "launch-auto-flatpak"
  if flatpak then
    config.launch_method = scenario == "launch-flatpak" and "flatpak" or "auto"
    installed_flatpak = true
    config.bridge_dir = ""
    service.onConfigChanged()
    finish_http()
  end
  local unavailable = scenario == "launch-missing-path" or scenario == "launch-invalid"
  local fallback = scenario == "launch-wrapper" or scenario == "launch-stopped"
  local probe_command = (flatpak or scenario == "launch-invalid") and "superproductivity" or command
  running_commands = {}
  if not fallback and not unavailable then running_commands[probe_command] = true end
  if scenario == "launch-wrapper" then running_commands.superproductivity = true end
  process_probes = {}
  now += 10000
  service.update()
  assert(#process_probes[1] == 1 and process_probes[1][1] == probe_command, "probe must use the resolved executable")
  local needs_fallback = (fallback or unavailable) and probe_command ~= "superproductivity"
  assert(#process_probes == (needs_fallback and 2 or 1))
  if needs_fallback then
    assert(#process_probes[2] == 1 and process_probes[2][1] == "superproductivity", "wrappers retain the standard-process fallback")
  end
  assert(snapshot().appRunning == (scenario ~= "launch-stopped" and not unavailable))
  assert(snapshot().appAvailable == not unavailable)
  assert(snapshot().launchMethod == (flatpak and "flatpak" or "native"))
  local before = #async_runs
  common.send_intent("launch")
  assert(#async_runs == before + (unavailable and 0 or 1))
  if not unavailable then
    local argv = async_runs[#async_runs].spec
    if flatpak then
      assert(#argv == 3 and argv[1] == "flatpak" and argv[2] == "run" and argv[3] == cache.rest.FLATPAK_ID)
    else
      assert(#argv == 1 and argv[1] == command, "native paths must remain one argv item")
    end
  end
elseif scenario:sub(1, 6) == "timer-" then
  local stopping = scenario:find("stop", 1, true) ~= nil
  local queued = scenario:find("queued", 1, true) ~= nil
  if stopping then
    timer_id = "task-1"
    common.send_intent("refresh")
    finish_http()
    assert(snapshot().currentTask.id == "task-1")
  end
  if queued then
    now += 2000
    write_metadata("change.json", {
      schemaVersion = 1, protocolVersion = 2, companionVersion = "2.0.0",
      sequence = 2, changedAt = now, reason = "test",
    })
    service.update()
    assert(#pending_http == 4)
  end
  local before = additions()
  local request_id = common.send_intent("timer_toggle", { taskId = "task-1" })
  assert(action().status == "working")
  -- Finish the mutation before any older refresh to exercise waiter ownership.
  http_response(table.remove(pending_http, queued and 5 or 1))
  assert(action().status == "working", "acknowledgement alone must not report success")
  if queued then
    for _ = 1, 4 do http_response(table.remove(pending_http, 1)) end
    assert(action().status == "working", "the older refresh cannot confirm a timer action")
    assert(#pending_http == 4, "confirmation must get its own queued refresh")
  end
  local expected = "success"
  if scenario:find("failed", 1, true) then
    fail_refresh = true
    expected = "unknown"
  elseif scenario:find("contradictory", 1, true) then
    timer_id = stopping and "task-1" or "other-task"
    expected = "error"
  elseif scenario:find("unresolved", 1, true) then
    timer_id, omit_timer_task = "other-task", true
    expected = "error"
  elseif scenario:find("missing", 1, true) then
    timer_id = nil
    expected = "error"
  else
    timer_id = if stopping then nil else "task-1"
  end
  finish_http()
  assert(action().status == expected and action().requestId == request_id)
  if expected ~= "success" then
    assert(action().error ~= nil and snapshot().lastError == action().error)
  end
  assert(additions() == before + 1, "timer changes must never replay")
  fail_refresh = false
  local refresh_id = common.send_intent("refresh")
  assert(action().status == "working" and action().requestId == refresh_id, "confirmation must release action ownership")
  finish_http()
  assert(action().status == "success")
elseif scenario == "busy-select" then
  local original_id = common.send_intent("open", { taskId = "task-1" })
  assert(action().status == "working" and action().requestId == original_id)
  local before = additions()
  capture("keep for retry")
  assert(runtime.state.get(common.INTENT_KEY).requestId == original_id, "published busy state must gate capture dispatch")
  assert(additions() == before and query == "keep for retry" and cleared == 0)
  assert(action().status == "working" and action().requestId == original_id, "capture cannot replace active ownership")
  local command = commands[#commands]
  assert(command and command.action == "select")
  write_metadata("responses/" .. command.id .. ".json", {
    schemaVersion = 1, protocolVersion = 2, id = command.id, action = "select", ok = true,
  })
  service.update()
  assert(action().status == "success" and action().requestId == original_id)
  launcher.onActivate("add")
  assert(additions() == before + 1, "capture must be retryable after the original action completes")
  launcher.onActivate("add")
  assert(additions() == before + 1, "pending capture must not dispatch twice")
  finish_http()
  assert(query == "" and cleared == 1)
elseif scenario == "queued-rejection" then
  queue_intents = true
  local original_id = common.send_intent("refresh")
  capture("queued capture")
  queue_intents = false
  for _, intent in ipairs(queued_intents) do deliver(common.INTENT_KEY, intent) end
  assert(additions() == 0 and query == "queued capture")
  for _, published in ipairs(action_history) do
    if published.requestId == original_id then assert(published.status == "working") end
  end
  assert(action().requestId == original_id and action().status == "working", "rejection preserves the active action")
  finish_http()
  assert(action().requestId == original_id and action().status == "success")
  launcher.onActivate("add")
  assert(additions() == 1, "a busy rejection after the launcher gate must release pending capture")
  finish_http()
  assert(query == "" and cleared == 1)
elseif scenario == "sync-success" then
  sync_http = true
  capture("synchronous capture")
  assert(additions() == 1 and query == "" and cleared == 1, "early success must clear the captured query")
  capture("another capture")
  assert(additions() == 2 and cleared == 2, "early success must release pending capture")
elseif scenario == "sync-error" then
  sync_http, deny_http = true, true
  capture("retry after error")
  assert(additions() == 1 and query == "retry after error" and cleared == 0)
  deny_http = false
  launcher.onActivate("add")
  assert(additions() == 2 and query == "" and cleared == 1, "early error must release pending capture without losing text")
elseif scenario == "package-build" then
  common.send_intent("package_build")
  assert(snapshot().packageStatus == "running", "package build intent must update visible state")
  assert(#async_runs == 1, "package build intent must start the packaging command")
  assert(async_runs[1].spec[1] == "python3")
  assert(async_runs[1].spec[2] == "/fixture/plugin/scripts/package-companion.py")
  assert(async_runs[1].spec[3] == "--machine-readable")
elseif scenario == "expiry" then
  local before = #requests
  for _ = 1, 4 do
    now += 10000
    heartbeat()
    service.update()
    assert(snapshot().hookStatus == "ready", "idle change metadata must not expire with fresh heartbeats")
  end
  assert(#requests == before, "heartbeats must not poll REST")
  now += 32000
  service.update()
  assert(snapshot().bridgeStatus == "stale" and snapshot().hookStatus == "stale", "unchanged ready files must age without an open request")
  assert(snapshot().appRunning == true and snapshot().restStatus == "ready" and #requests == before)
  now += 2000
  heartbeat()
  service.update()
  assert(snapshot().bridgeStatus == "ready" and snapshot().hookStatus == "ready")
  now += 30000
  service.update()
  assert(snapshot().bridgeStatus == "ready", "the heartbeat has a conservative 30s grace")
  now += 1
  common.send_intent("open", { taskId = "task-1" })
  assert(#commands == 0, "exact-task opening must check freshness even between file polls")
  now += 2000
  service.update()
  assert(snapshot().bridgeStatus ~= "ready", "unchanged connection metadata must expire")
  assert(snapshot().hookStatus ~= "ready", "stale companion hooks must not report ready")
  assert(snapshot().restStatus == "ready" and snapshot().status == "ready" and #requests == before)
  heartbeat()
  now += 2000
  service.update()
  assert(snapshot().bridgeStatus == "ready" and snapshot().hookStatus == "ready", "fresh heartbeat restores readiness")
  assert(#commands == 1, "waiting exact-task open dispatches once after recovery")
  local command = commands[1]
  write_metadata("responses/" .. command.id .. ".json", {
    schemaVersion = 1, protocolVersion = 2, id = command.id, action = "select", ok = true,
  })
  service.update()
  now += 2000
  heartbeat("unloaded")
  service.update()
  assert(snapshot().bridgeStatus == "offline" and snapshot().hookStatus ~= "ready", "unloaded companions are unavailable")
  assert(snapshot().restStatus == "ready" and snapshot().status == "ready")
  capture("REST without companion")
  finish_http()
  assert(additions() == 1 and cleared == 1, "REST actions remain usable without the companion")
  common.send_intent("open", { taskId = "task-1" })
  assert(#commands == 1, "unloaded companions must not receive selection commands")
else
  error("unknown scenario: " .. tostring(scenario))
end
print(scenario .. " passed")
