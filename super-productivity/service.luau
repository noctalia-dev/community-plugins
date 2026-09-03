--!nonstrict
-- headless owner of the super productivity companion protocol.

local common = require("./common.luau")

local FLATPAK_ID = "com.super_productivity.SuperProductivity"
local BRIDGE_NAME = "noctalia-super-productivity"
local PACKAGE_ARCHIVE_NAME = "noctalia-super-productivity.zip"
local PACKAGE_METADATA_NAME = "companion-package.json"
local PLUGIN_DIR = tostring(noctalia.pluginDir() or "")
local SCHEMA_VERSION = 1
local SNAPSHOT_STALE_MS = 30000
local MAX_FUTURE_SKEW_MS = 5000
local COMMAND_TIMEOUT_MS = 12000
local OPEN_TIMEOUT_MS = 30000
local UNDO_WINDOW_MS = 30000
local SOUND_NAME = "task-complete"

local state = {
  status = "starting",
  bridgeDir = "",
  companionVersion = "",
  protocolVersion = nil,
  requiredCompanionVersion = "",
  companionUpdateRequired = false,
  packageStatus = "missing",
  packageError = "",
  packagePath = "",
  generatedAt = 0,
  receivedAt = 0,
  currentTask = nil,
  upcoming = {},
  view = nil,
  counts = { active = 0, due = 0, overdue = 0 },
  appRunning = false,
  appAvailable = false,
  launchMethod = "",
  error = "",
  lastError = "",
  lastCommandAt = 0,
  lastResponseAt = 0,
  undo = nil,
}

local action = { status = "idle" }
local bridge_dir = ""
local selected_bridge_method = ""
local snapshot_path = ""
local connection_path = ""
local error_path = ""
local command_dir = ""
local response_dir = ""
local snapshot_signature = nil
local connection_signature = nil
local bridge_error_signature = nil
local queued = {}
local snapshot_incompatible = false
local pending = {}
local expired = {}
local expired_order = {}
local command_sequence = 0
local browse_index = 1
local last_poll_ms = 0
local last_bridge_search_ms = 0
local last_process_check_ms = 0
local last_due_check_ms = noctalia.nowMs()
local service_started_at = last_due_check_ms
local auto_start_attempted = false
local pending_open_request = nil
local reset_view_on_snapshot = false
local sound_ready = false

local function trim(value)
  return common.trim(value)
end

local without_trailing_slash = common.without_trailing_slash

local function configured_poll_ms()
  local seconds = tonumber(noctalia.getConfig("poll_seconds")) or 2
  return math.max(1, math.min(30, math.floor(seconds))) * 1000
end

local function max_upcoming()
  local value = tonumber(noctalia.getConfig("max_upcoming")) or 30
  return math.max(5, math.min(50, math.floor(value)))
end

local function decode_file(path)
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then return nil end
  local decoded, decode_error = noctalia.json.decode(raw)
  if type(decoded) == "table" then return decoded end
  noctalia.log("super-productivity: invalid JSON in " .. path .. ": " .. tostring(decode_error or "unknown error"))
  return nil
end

local function file_signature(path)
  local info = noctalia.fileInfo(path)
  if type(info) ~= "table" then return nil end
  return tostring(info.mtime or "") .. ":" .. tostring(info.size or "")
end

local function data_home()
  local configured = trim(noctalia.getenv("XDG_DATA_HOME"))
  if configured ~= "" then return without_trailing_slash(configured) end
  return without_trailing_slash(noctalia.expandPath("~/.local/share"))
end
local function package_directory()
  return data_home() .. "/" .. BRIDGE_NAME
end

local function package_path()
  return package_directory() .. "/" .. PACKAGE_ARCHIVE_NAME
end

local function package_metadata_path()
  return package_directory() .. "/" .. PACKAGE_METADATA_NAME
end

local function package_script_path()
  return PLUGIN_DIR ~= "" and PLUGIN_DIR .. "/scripts/package-companion.py"
    or "scripts/package-companion.py"
end

local function refresh_package_state(force)
  if (state.packageStatus == "running" or state.packageStatus == "checking") and force ~= true then return end
  if state.packageStatus == "error" and force ~= true then return end
  local manifest_path = PLUGIN_DIR ~= "" and PLUGIN_DIR .. "/companion/manifest.json"
    or "companion/manifest.json"
  local manifest = decode_file(manifest_path)
  local required_version = type(manifest) == "table" and trim(manifest.version) or ""
  local path = package_path()
  local info = noctalia.fileInfo(path)
  local metadata = decode_file(package_metadata_path())
  state.requiredCompanionVersion = required_version
  state.packagePath = path

  local current = type(info) == "table"
    and info.isDir ~= true
    and type(metadata) == "table"
    and tonumber(metadata.schemaVersion) == 1
    and trim(metadata.companionVersion) == required_version
    and tonumber(metadata.archiveSize) == tonumber(info.size)
    and trim(metadata.archivePath) == path
  if current then
    state.packageStatus = "ready"
    state.packageError = ""
  elseif type(info) == "table" or type(metadata) == "table" then
    state.packageStatus = "stale"
  else
    state.packageStatus = "missing"
  end
end


local function flatpak_bridge_path()
  return without_trailing_slash(noctalia.expandPath(
    "~/.var/app/" .. FLATPAK_ID .. "/data/" .. BRIDGE_NAME
  ))
end

local function bridge_candidates()
  local flatpak_path = flatpak_bridge_path()
  local native_paths = {
    data_home() .. "/" .. BRIDGE_NAME,
    without_trailing_slash(noctalia.expandPath("~/.local/share/" .. BRIDGE_NAME)),
  }
  local method = trim(noctalia.getConfig("launch_method"))
  local candidates = method == "flatpak" and { flatpak_path } or native_paths
  if method == "" or method == "auto" then table.insert(candidates, 1, flatpak_path) end

  local unique, seen = {}, {}
  for _, candidate in ipairs(candidates) do
    if candidate ~= "" and not seen[candidate] then
      seen[candidate] = true
      table.insert(unique, candidate)
    end
  end
  return unique
end

local function compatible_bridge_file(value)
  return type(value) == "table"
    and tonumber(value.schemaVersion) == SCHEMA_VERSION
    and tonumber(value.protocolVersion) == common.PROTOCOL_VERSION
end

local function bridge_timestamp(value)
  local timestamp = tonumber(value)
  if timestamp == nil or timestamp <= 0
    or timestamp > noctalia.nowMs() + MAX_FUTURE_SKEW_MS then return nil end
  return timestamp
end

local function candidate_score(path, now_ms)
  local priority, score = 0, 0
  local snapshot = decode_file(path .. "/snapshot.json")
  if compatible_bridge_file(snapshot) then
    local generated_at = bridge_timestamp(snapshot.generatedAt)
    if generated_at ~= nil then
      priority = now_ms - generated_at <= SNAPSHOT_STALE_MS and 3 or 1
      score = generated_at
    end
  end
  local connection = decode_file(path .. "/connection.json")
  if compatible_bridge_file(connection) then
    local updated_at = bridge_timestamp(connection.updatedAt)
    if updated_at ~= nil and now_ms - updated_at <= SNAPSHOT_STALE_MS
      and (priority < 2 or (priority == 2 and updated_at > score)) then
      priority = 2
      score = updated_at
    end
  end
  return priority, score
end

local function clear_snapshot_state()
  state.status = "starting"
  state.companionVersion = ""
  state.protocolVersion = nil
  state.generatedAt = 0
  state.receivedAt = 0
  state.currentTask = nil
  state.upcoming = {}
  state.view = nil
  state.counts = { active = 0, due = 0, overdue = 0 }
  state.error = ""
  state.undo = nil
  browse_index = 1
  pending_open_request = nil
  reset_view_on_snapshot = false
  snapshot_incompatible = false
end

local function set_bridge_dir(path)
  path = without_trailing_slash(path)
  if path == bridge_dir then return end
  bridge_dir = path
  selected_bridge_method = path == flatpak_bridge_path() and "flatpak" or "native"
  snapshot_path = path .. "/snapshot.json"
  connection_path = path .. "/connection.json"
  error_path = path .. "/bridge-error.json"
  command_dir = path .. "/commands"
  response_dir = path .. "/responses"
  state.bridgeDir = path
  snapshot_signature = nil
  connection_signature = nil
  bridge_error_signature = nil
  clear_snapshot_state()
end

local function discover_bridge_dir()
  if next(pending) ~= nil and bridge_dir ~= "" then return end
  local override = trim(noctalia.getConfig("bridge_dir"))
  if override ~= "" then
    set_bridge_dir(without_trailing_slash(noctalia.expandPath(override)))
    return
  end
  local candidates = bridge_candidates()
  local selected, best_priority, best_score = candidates[1], -1, -1
  local now_ms = noctalia.nowMs()
  for _, candidate in ipairs(candidates) do
    local priority, score = candidate_score(candidate, now_ms)
    if priority > best_priority or (priority == best_priority and score > best_score) then
      selected = candidate
      best_priority = priority
      best_score = score
    end
  end
  if selected ~= nil then set_bridge_dir(selected) end
end

local function publish()
  state.receivedAt = state.receivedAt or 0
  noctalia.state.set(common.SNAPSHOT_KEY, state)
end

local function publish_action(next_action)
  action = next_action or { status = "idle" }
  noctalia.state.set(common.ACTION_KEY, action)
end

local function task_list()
  local list, seen = {}, {}
  if noctalia.getConfig("prefer_tracked_task") ~= false
    and type(state.currentTask) == "table"
    and state.currentTask.isDone ~= true then
    table.insert(list, state.currentTask)
    seen[state.currentTask.id] = true
  end
  local limit = max_upcoming()
  for _, task in ipairs(state.upcoming or {}) do
    if type(task) == "table" and task.id ~= nil and not seen[task.id] then
      table.insert(list, task)
      seen[task.id] = true
      if #list >= limit then break end
    end
  end
  return list
end

local function rebuild_view(preferred_id)
  local list = task_list()
  if #list == 0 then
    browse_index = 1
    state.view = nil
    return
  end

  if type(preferred_id) == "string" and preferred_id ~= "" then
    for index, task in ipairs(list) do
      if task.id == preferred_id then browse_index = index break end
    end
  end
  browse_index = math.max(1, math.min(#list, browse_index))
  state.view = { task = list[browse_index], index = browse_index, count = #list }
end

local function due_notifications(now_ms)
  if noctalia.getConfig("notify_due") ~= true then
    last_due_check_ms = now_ms
    return
  end
  for _, task in ipairs(task_list()) do
    local due_at = common.task_due_at(task)
    if due_at ~= nil and due_at > last_due_check_ms and due_at <= now_ms then
      noctalia.notify(noctalia.tr("notify.due_title"), task.title or noctalia.tr("task.untitled"))
    end
  end
  last_due_check_ms = now_ms
end

local function reject_snapshot(message, protocol_version)
  clear_snapshot_state()
  snapshot_incompatible = true
  state.status = "protocol_mismatch"
  state.error = message
  state.lastError = message
  state.protocolVersion = protocol_version
  return false
end

local function apply_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return reject_snapshot(noctalia.tr("error.invalid_snapshot"), nil)
  end
  if tonumber(snapshot.schemaVersion) ~= SCHEMA_VERSION then
    return reject_snapshot(noctalia.tr("error.schema_mismatch"), tonumber(snapshot.protocolVersion))
  end
  if tonumber(snapshot.protocolVersion) ~= common.PROTOCOL_VERSION then
    return reject_snapshot(noctalia.tr("error.protocol_mismatch"), tonumber(snapshot.protocolVersion))
  end

  local generated_at = bridge_timestamp(snapshot.generatedAt)
  if generated_at == nil then
    return reject_snapshot(noctalia.tr("error.invalid_snapshot"), tonumber(snapshot.protocolVersion))
  end

  local previous_id = reset_view_on_snapshot and nil or (state.view and state.view.task.id or nil)
  snapshot_incompatible = false
  state.protocolVersion = tonumber(snapshot.protocolVersion)
  state.companionVersion = tostring(snapshot.companionVersion or "")
  state.generatedAt = generated_at
  state.receivedAt = noctalia.nowMs()
  state.currentTask = type(snapshot.currentTask) == "table" and snapshot.currentTask or nil
  state.upcoming = type(snapshot.upcoming) == "table" and snapshot.upcoming or {}
  state.counts = type(snapshot.counts) == "table" and snapshot.counts or state.counts
  state.error = ""
  state.status = "ready"
  if reset_view_on_snapshot then browse_index = 1 end
  rebuild_view(previous_id)
  reset_view_on_snapshot = false
  return true
end

local function refresh_snapshot_file()
  if snapshot_path == "" then return end
  local signature = file_signature(snapshot_path)
  if signature == nil or signature == snapshot_signature then return end
  snapshot_signature = signature
  apply_snapshot(decode_file(snapshot_path))
end

local function refresh_connection_file()
  if connection_path == "" then return end
  local signature = file_signature(connection_path)
  if signature == nil or signature == connection_signature then return end
  connection_signature = signature
  local connection = decode_file(connection_path)
  if type(connection) == "table" then
    state.companionVersion = tostring(connection.companionVersion or state.companionVersion)
    state.protocolVersion = tonumber(connection.protocolVersion) or state.protocolVersion
  end
end

local function refresh_bridge_error()
  if error_path == "" then return end
  local signature = file_signature(error_path)
  if signature == nil then
    bridge_error_signature = nil
    return
  end
  if signature == bridge_error_signature then return end
  bridge_error_signature = signature
  local result = decode_file(error_path)
  if type(result) == "table" then
    state.lastError = trim(result.error)
    state.error = state.lastError
  end
end

local function update_status(now_ms)
  local installed_version = trim(state.companionVersion)
  local required_version = trim(state.requiredCompanionVersion)
  state.companionUpdateRequired = installed_version ~= "" and required_version ~= ""
    and installed_version ~= required_version
  if snapshot_incompatible
    or (state.protocolVersion ~= nil and state.protocolVersion ~= common.PROTOCOL_VERSION) then
    state.status = "protocol_mismatch"
    return
  end
  if state.generatedAt > 0 then
    if now_ms - state.generatedAt <= SNAPSHOT_STALE_MS then
      state.status = "ready"
    else
      state.status = "stale"
    end
  elseif state.appRunning then
    state.status = "companion_missing"
  else
    state.status = "offline"
  end
end

local function command_id()
  command_sequence += 1
  return "noctalia-" .. tostring(math.floor(noctalia.nowMs())) .. "-" .. tostring(command_sequence)
end

local function write_command(kind, payload, metadata)
  if bridge_dir == "" then discover_bridge_dir() end
  if bridge_dir == "" then return nil, noctalia.tr("error.bridge_unavailable") end
  local ok, mkdir_error = noctalia.mkdirAll(command_dir)
  if not ok then return nil, tostring(mkdir_error or noctalia.tr("error.bridge_unavailable")) end

  metadata = metadata or {}
  local id = command_id()
  local issued_at = noctalia.nowMs()
  local command = {
    schemaVersion = SCHEMA_VERSION,
    protocolVersion = common.PROTOCOL_VERSION,
    id = id,
    action = kind,
    issuedAt = issued_at,
    expiresAt = issued_at + COMMAND_TIMEOUT_MS,
    payload = payload or {},
  }
  local encoded, encode_error = noctalia.json.encode(command, true)
  if type(encoded) ~= "string" then return nil, tostring(encode_error or "JSON encode failed") end
  local final_path = command_dir .. "/" .. id .. ".json"
  local temp_path = final_path .. ".tmp"
  local wrote, write_error = noctalia.writeFile(temp_path, encoded)
  if not wrote then return nil, tostring(write_error or "Command write failed") end
  local renamed, rename_error = noctalia.renameFile(temp_path, final_path)
  if not renamed then
    noctalia.removeFile(temp_path)
    return nil, tostring(rename_error or "Command publish failed")
  end

  pending[id] = {
    id = id,
    requestId = metadata.requestId,
    action = kind,
    taskId = payload and payload.taskId or nil,
    startedAt = issued_at,
    commandPath = final_path,
    metadata = metadata,
  }
  state.lastCommandAt = issued_at
  publish_action({
    status = "working",
    commandId = id,
    requestId = metadata.requestId,
    type = kind,
    taskId = payload and payload.taskId or nil,
  })
  publish()
  return id
end

local MUTATING_ACTIONS = {
  add = true,
  complete = true,
  restore = true,
  timer_start = true,
  timer_stop = true,
  snooze = true,
}

local function play_completion_sound()
  if noctalia.getConfig("sound_on_complete") == false then return end
  if sound_ready then noctalia.sound.play(SOUND_NAME) end
end

local function finish_response(request, response)
  local now_ms = noctalia.nowMs()
  state.lastResponseAt = now_ms
  local owns_action = action.commandId == request.id
  if not owns_action then
    noctalia.log("super-productivity: ignored superseded response " .. request.id)
    return
  end

  local ok = response.ok == true
  if ok then
    local result = {
      status = "success",
      commandId = request.id,
      requestId = request.requestId,
      type = request.action,
      taskId = request.taskId,
      data = response.data,
      completedAt = now_ms,
    }
    if request.action == "complete" then
      local completed_task = request.metadata.task
      if type(completed_task) == "table" then
        state.undo = { task = completed_task, expiresAt = now_ms + UNDO_WINDOW_MS }
        result.canUndo = true
      end
      browse_index = 1
      reset_view_on_snapshot = true
      play_completion_sound()
    elseif request.action == "restore" then
      state.undo = nil
    elseif request.action == "add" and request.metadata.source == "launcher" then
      noctalia.notify(noctalia.tr("notify.added_title"), request.metadata.input or "")
    end
    publish_action(result)
  else
    local message = trim(response.error)
    if message == "" then message = noctalia.tr("error.command_failed") end
    local status = response.outcome == "unknown" and "unknown" or "error"
    state.error = message
    state.lastError = message
    publish_action({
      status = status,
      commandId = request.id,
      requestId = request.requestId,
      type = request.action,
      taskId = request.taskId,
      error = message,
      completedAt = now_ms,
    })
    if status == "error" then
      noctalia.notifyError(noctalia.tr("notify.command_failed_title"), message)
    end
  end
end

local function response_error(request, message)
  return {
    ok = false,
    outcome = MUTATING_ACTIONS[request.action] and "unknown" or "failed",
    error = message,
  }
end

local function valid_response(request, response, id)
  return type(response) == "table"
    and tonumber(response.schemaVersion) == SCHEMA_VERSION
    and tonumber(response.protocolVersion) == common.PROTOCOL_VERSION
    and response.id == id
    and response.action == request.action
    and type(response.ok) == "boolean"
end

-- every response is terminal bridge state. consume it even when the in-memory
-- request was lost to a timeout or service restart so responses cannot leak.
local function process_responses()
  if response_dir == "" then return end
  local entries = noctalia.listDir(response_dir)
  if type(entries) ~= "table" then return end
  for _, name in ipairs(entries) do
    local id = tostring(name):match("^(.-)%.json$")
    if id ~= nil then
      local path = response_dir .. "/" .. tostring(name)
      local request = pending[id] or expired[id]
      local response = decode_file(path)
      pending[id] = nil
      expired[id] = nil
      if request == nil then
        noctalia.log("super-productivity: discarded orphan response " .. id)
      elseif valid_response(request, response, id) then
        finish_response(request, response)
      else
        noctalia.log("super-productivity: rejected incompatible response " .. tostring(name))
        finish_response(request, response_error(request, noctalia.tr("error.protocol_mismatch")))
      end
      noctalia.removeFile(path)
    end
  end
end

local function expire_pending(now_ms)
  for id, request in pairs(pending) do
    if now_ms - request.startedAt > COMMAND_TIMEOUT_MS then
      pending[id] = nil
      if request.commandPath ~= nil and noctalia.fileExists(request.commandPath) then
        noctalia.removeFile(request.commandPath)
      end
      request.expiredAt = now_ms
      expired[id] = request
      table.insert(expired_order, id)
      while #expired_order > 100 do
        expired[table.remove(expired_order, 1)] = nil
      end
      if action.commandId == id then
        local uncertain = MUTATING_ACTIONS[request.action] == true
        local status = uncertain and "unknown" or "error"
        local message = uncertain and noctalia.tr("error.outcome_unknown") or noctalia.tr("error.command_timeout")
        state.error = message
        state.lastError = message
        publish_action({
          status = status,
          commandId = id,
          requestId = request.requestId,
          type = request.action,
          taskId = request.taskId,
          error = message,
          completedAt = now_ms,
        })
      end
    end
  end
  while #expired_order > 0 do
    local oldest_id = expired_order[1]
    local oldest = expired[oldest_id]
    if oldest == nil or now_ms - oldest.expiredAt > 300000 then
      table.remove(expired_order, 1)
      expired[oldest_id] = nil
    else
      break
    end
  end
end

local function resolve_launch()
  local method = trim(noctalia.getConfig("launch_method"))
  if method == "" then method = "auto" end
  if method == "auto" then
    local selected_is_live = state.status == "ready"
      and state.generatedAt > 0
      and noctalia.nowMs() - state.generatedAt <= SNAPSHOT_STALE_MS
    if selected_is_live and selected_bridge_method ~= "" then
      method = selected_bridge_method
    else
      method = noctalia.flatpakAppInstalled(FLATPAK_ID) and "flatpak" or "native"
    end
  end

  if method == "flatpak" then
    local available = noctalia.flatpakAppInstalled(FLATPAK_ID)
    return {
      spec = { "flatpak", "run", FLATPAK_ID },
      method = "flatpak",
      available = available,
      error = available and nil or noctalia.tr("error.app_unavailable"),
    }
  end

  local command = trim(noctalia.getConfig("native_command"))
  if command == "" then command = "superproductivity" end
  if command:find("%s") then
    return { method = "native", available = false, error = noctalia.tr("error.native_command_single") }
  end
  local available
  if command:sub(1, 1) == "/" then
    local info = noctalia.fileInfo(command)
    available = type(info) == "table" and info.isDir ~= true
  else
    available = noctalia.commandExists(command)
  end
  return {
    spec = { command },
    method = "native",
    available = available,
    error = available and nil or noctalia.tr("error.app_unavailable"),
  }
end

local function apply_launch_diagnostics(resolved)
  state.appAvailable = resolved.available == true
  state.launchMethod = tostring(resolved.method or "")
end

local function launch_app()
  local resolved = resolve_launch()
  apply_launch_diagnostics(resolved)
  if not resolved.available or resolved.spec == nil then
    state.error = resolved.error or noctalia.tr("error.app_unavailable")
    publish()
    return false
  end
  local started = noctalia.runAsync(resolved.spec)
  if not started then state.error = noctalia.tr("error.launch_failed") end
  publish()
  return started
end

local function probe_process()
  noctalia.processMatches(function(matched)
    state.appRunning = matched == true
    apply_launch_diagnostics(resolve_launch())
    publish()
  end, "superproductivity")
end

local function has_pending_request()
  return next(pending) ~= nil
end

local function request(kind, payload, metadata, request_id)
  metadata = metadata or {}
  metadata.requestId = request_id
  if has_pending_request() then
    table.insert(queued, { kind = kind, payload = payload, metadata = metadata, requestId = request_id })
    return true, "queued"
  end
  local id, request_error = write_command(kind, payload, metadata)
  if id == nil then
    state.error = request_error or noctalia.tr("error.bridge_unavailable")
    state.lastError = state.error
    publish_action({ status = "error", requestId = request_id, type = kind, error = state.error })
    publish()
    return false, state.error
  end
  return true, id
end

local function drain_queue()
  if has_pending_request() or #queued == 0 then return end
  local item = table.remove(queued, 1)
  request(item.kind, item.payload, item.metadata, item.requestId)
end

local function try_pending_open(now_ms)
  local pending_open = pending_open_request
  if type(pending_open) ~= "table" then return end
  if now_ms >= pending_open.expiresAt then
    pending_open_request = nil
    local message = noctalia.tr("error.launch_failed")
    publish_action({
      status = "error",
      requestId = pending_open.requestId,
      type = "select",
      taskId = pending_open.taskId,
      error = message,
      completedAt = now_ms,
    })
    return
  end
  local companion_ready = state.status == "ready"
    and (pending_open.readyAfter == 0 or state.generatedAt >= pending_open.readyAfter)
  if companion_ready
    and request("select", { taskId = pending_open.taskId }, nil, pending_open.requestId) then
    pending_open_request = nil
  end
end

-- selecting must happen after an explicit launch has made the companion ready;
-- retaining the request keeps middle-click exact even from a stopped app.
local function open_task(task_id, request_id)
  if trim(task_id) == "" then return end
  local now_ms = noctalia.nowMs()
  local already_ready = state.appRunning
    and state.status == "ready"
    and now_ms - state.generatedAt <= SNAPSHOT_STALE_MS
  pending_open_request = {
    taskId = task_id,
    requestId = request_id,
    readyAfter = already_ready and 0 or now_ms,
    expiresAt = now_ms + OPEN_TIMEOUT_MS,
  }
  if not launch_app() then
    pending_open_request = nil
    publish_action({
      status = "error",
      requestId = request_id,
      type = "select",
      taskId = task_id,
      error = state.error,
      completedAt = now_ms,
    })
    return
  end
  try_pending_open(now_ms)
end

-- existing package verification is read-only; generation stays behind an explicit user intent.
local function verify_companion_package()
  refresh_package_state(true)
  if state.packageStatus ~= "ready" then return end
  if not noctalia.commandExists("python3") then
    state.packageStatus = "error"
    state.packageError = noctalia.tr("error.python_unavailable")
    return
  end

  state.packageStatus = "checking"
  state.packageError = ""
  local started = noctalia.runAsync(
    { "python3", package_script_path(), "--verify", "--machine-readable" },
    function(result)
      if result.exitCode ~= 0 or result.timedOut then
        local message = trim(result.stderr)
        state.packageStatus = "stale"
        state.packageError = message ~= "" and message or noctalia.tr("error.package_verification_failed")
      else
        refresh_package_state(true)
      end
      publish()
    end,
    60000
  )
  if not started then
    state.packageStatus = "error"
    state.packageError = noctalia.tr("error.package_verification_failed")
  end
end

local function build_companion_package()
  if state.packageStatus == "running" or state.packageStatus == "checking" then return end
  if not noctalia.commandExists("python3") then
    state.packageStatus = "error"
    state.packageError = noctalia.tr("error.python_unavailable")
    publish()
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
    return
  end

  local script = package_script_path()
  state.packageStatus = "running"
  state.packageError = ""
  publish()

  local started = noctalia.runAsync(
    { "python3", script, "--machine-readable" },
    function(result)
      if result.exitCode ~= 0 or result.timedOut then
        local message = trim(result.stderr)
        state.packageStatus = "error"
        state.packageError = message ~= "" and message or noctalia.tr("error.package_build_failed")
        publish()
        noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
        return
      end

      local path = tostring(result.stdout or ""):match("ZIP_PATH=([^\r\n]+)")
      if path == nil or not noctalia.fileExists(path) then
        state.packageStatus = "error"
        state.packageError = noctalia.tr("error.package_missing")
        publish()
        noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
        return
      end

      refresh_package_state(true)
      if state.packageStatus ~= "ready" then
        state.packageStatus = "error"
        state.packageError = noctalia.tr("error.package_build_failed")
        noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
      end
      publish()
    end,
    60000
  )
  if not started then
    state.packageStatus = "error"
    state.packageError = noctalia.tr("error.package_build_failed")
    publish()
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), state.packageError)
  end
end

local function open_companion_package_directory()
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), noctalia.tr("error.xdg_open_unavailable"))
    return
  end
  if state.packageStatus ~= "ready" then
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), noctalia.tr("error.package_missing"))
    return
  end
  local started = noctalia.runAsync(
    { "xdg-open", package_directory() },
    function(result)
      if result.exitCode ~= 0 or result.timedOut then
        noctalia.notifyError(noctalia.tr("notify.package_failed_title"), noctalia.tr("error.open_package_failed"))
      end
    end,
    10000
  )
  if not started then
    noctalia.notifyError(noctalia.tr("notify.package_failed_title"), noctalia.tr("error.open_package_failed"))
  end
end

local function handle_intent(intent)
  if type(intent) ~= "table" then return end
  local kind = tostring(intent.type or "")
  local task_id = trim(intent.taskId)
  local request_id = trim(intent.requestId)

  if kind == "package_build" then
    build_companion_package()
  elseif kind == "package_open_directory" then
    open_companion_package_directory()
  elseif kind == "browse" then
    local list = task_list()
    if #list == 0 then return end
    local delta = tonumber(intent.delta) or 0
    if delta == 0 then return end
    browse_index = ((browse_index - 1 + delta) % #list) + 1
    rebuild_view()
    publish()
  elseif kind == "refresh" then
    request("refresh", {}, nil, request_id)
  elseif kind == "launch" then
    launch_app()
  elseif kind == "open" then
    open_task(task_id, request_id)
  elseif kind == "complete" and task_id ~= "" then
    local task = state.view and state.view.task or nil
    if type(task) ~= "table" or task.id ~= task_id then
      state.error = noctalia.tr("error.task_changed")
      publish()
      return
    end
    request("complete", { taskId = task_id }, { task = task }, request_id)
  elseif kind == "add" then
    local input = trim(intent.input)
    if input ~= "" then
      request("add", { input = input }, { input = input, source = intent.source }, request_id)
    end
  elseif kind == "timer_toggle" and task_id ~= "" then
    local is_current = type(state.currentTask) == "table" and state.currentTask.id == task_id
    request(is_current and "timer_stop" or "timer_start", { taskId = task_id }, nil, request_id)
  elseif kind == "snooze" and task_id ~= "" then
    request("snooze", { taskId = task_id, mode = tostring(intent.mode or "") }, nil, request_id)
  elseif kind == "undo" then
    local undo = state.undo
    if type(undo) == "table" and undo.expiresAt > noctalia.nowMs() then
      request("restore", { taskId = undo.task.id }, nil, request_id)
    end
  end
end

noctalia.state.watch(common.INTENT_KEY, handle_intent)

function update()
  local now_ms = noctalia.nowMs()

  if now_ms - last_bridge_search_ms >= 10000 then
    last_bridge_search_ms = now_ms
    discover_bridge_dir()
  end
  if now_ms - last_process_check_ms >= 10000 then
    last_process_check_ms = now_ms
    probe_process()
  end
  if now_ms - last_poll_ms >= configured_poll_ms() then
    last_poll_ms = now_ms
    refresh_connection_file()
    refresh_snapshot_file()
    refresh_bridge_error()
  end
  process_responses()

  expire_pending(now_ms)
  drain_queue()
  update_status(now_ms)
  due_notifications(now_ms)

  if type(state.undo) == "table" and state.undo.expiresAt <= now_ms then
    state.undo = nil
  end

  try_pending_open(now_ms)

  if noctalia.getConfig("auto_start") == true and not auto_start_attempted
    and not state.appRunning and now_ms - service_started_at > 1500 and state.status ~= "ready" then
    auto_start_attempted = true
    launch_app()
  end

  publish()
end

function onConfigChanged()
  auto_start_attempted = false
  discover_bridge_dir()
  rebuild_view(state.view and state.view.task.id or nil)
  publish()
end

noctalia.setUpdateInterval(1000)
verify_companion_package()
discover_bridge_dir()
local accepted = noctalia.sound.load(SOUND_NAME, "sounds/ding-small-bell.mp3", function(ok, load_error)
  sound_ready = ok == true
  if not sound_ready and load_error ~= nil then noctalia.log("super-productivity: " .. tostring(load_error)) end
end)
if not accepted then noctalia.log("super-productivity: completion sound load was not accepted") end
publish_action(action)
publish()
