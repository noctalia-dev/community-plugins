--!nonstrict
-- headless owner of super productivity REST state and companion notifications.

local common = require("./common.luau")
local rest = require("./rest.luau")
local rest_state = require("./rest_state.luau")
local operation = require("./operation.luau")

local FLATPAK_ID = rest.FLATPAK_ID
local BRIDGE_NAME = "noctalia-super-productivity"
local PACKAGE_ARCHIVE_NAME = "noctalia-super-productivity.zip"
local PACKAGE_METADATA_NAME = "companion-package.json"
local PLUGIN_DIR = tostring(noctalia.pluginDir() or "")
local SCHEMA_VERSION = 1
local BRIDGE_PROTOCOL_VERSION = common.PROTOCOL_VERSION
local MAX_FUTURE_SKEW_MS = 5000
local MAX_CHANGE_REASON = 120
local SOUND_NAME = "task-complete"
local BRIDGE_POLL_MS = 2000
local CONNECTION_GRACE_MS = 30000

local state = {
  status = "starting",
  restStatus = "starting",
  restError = "",
  bridgeStatus = "starting",
  bridgeError = "",
  hookStatus = "starting",
  hookError = "",
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
  connectionUpdatedAt = 0,
  changeSequence = nil,
  changedAt = 0,
  changeReason = "",
  undo = nil,
}

local bridge_dir = ""
local selected_bridge_method = ""
local connection_path = ""
local change_path = ""
local bridge_error_path = ""
local command_dir = ""
local response_dir = ""
local connection_signature = nil
local change_signature = nil
local bridge_error_signature = nil
local last_change_sequence = nil
local browse_index = 1
local last_file_poll_ms = 0
local last_bridge_search_ms = 0
local last_process_check_ms = 0
local last_due_check_ms = noctalia.nowMs()
local service_started_at = last_due_check_ms
local auto_start_attempted = false
local reset_view_on_refresh = false
local sound_ready = false
local refresh_running = false
local refresh_again = false
local refresh_waiters = {}
local queued_refresh_waiters = {}
local rest_client = rest.new(noctalia)
local request_rest_state
local operations
local published_state = nil
local published_minute = nil

local function trim(value)
  return common.trim(value)
end

local without_trailing_slash = common.without_trailing_slash


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

local function file_mtime(path)
  local info = noctalia.fileInfo(path)
  return type(info) == "table" and tonumber(info.mtime) or 0
end

local function bridge_timestamp(value)
  local timestamp = tonumber(value)
  if timestamp == nil or timestamp <= 0 or timestamp > noctalia.nowMs() + MAX_FUTURE_SKEW_MS then return nil end
  return timestamp
end

local function compatible_bridge_file(value)
  return type(value) == "table"
    and tonumber(value.schemaVersion) == SCHEMA_VERSION
    and tonumber(value.protocolVersion) == BRIDGE_PROTOCOL_VERSION
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
  return PLUGIN_DIR ~= "" and PLUGIN_DIR .. "/scripts/package-companion.py" or "scripts/package-companion.py"
end

local function refresh_package_state(force)
  if (state.packageStatus == "running" or state.packageStatus == "checking") and force ~= true then return end
  if state.packageStatus == "error" and force ~= true then return end
  local manifest_path = PLUGIN_DIR ~= "" and PLUGIN_DIR .. "/companion/manifest.json" or "companion/manifest.json"
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

local function update_overall_status()
  if state.restStatus == "ready" or (state.restStatus == "checking" and state.generatedAt > 0) then
    state.status = "ready"
  elseif state.restStatus == "starting" or state.restStatus == "checking" then
    state.status = "starting"
  else
    state.status = "offline"
  end
  state.error = state.restError
end

local function publish()
  local installed_version = trim(state.companionVersion)
  local required_version = trim(state.requiredCompanionVersion)
  state.companionUpdateRequired = installed_version ~= "" and required_version ~= ""
    and installed_version ~= required_version
  update_overall_status()
  local minute = math.floor(noctalia.nowMs() / 60000)
  local changed = published_state == nil
    or (state.view ~= nil and minute ~= published_minute)
  -- nested state records are replaced, so identity detects their changes without
  -- traversing task data on idle ticks. nil fields need the reverse comparison.
  if not changed then
    for key, value in pairs(state) do
      if published_state[key] ~= value then changed = true; break end
    end
    if not changed then
      for key, value in pairs(published_state) do
        if state[key] ~= value then changed = true; break end
      end
    end
  end
  if not changed then return end
  published_state = table.clone(state)
  published_minute = minute
  -- bridge availability masks hook diagnostics only in the published snapshot,
  -- so a fresh heartbeat can restore cached change metadata without rereading it.
  local snapshot = table.clone(state)
  if state.bridgeStatus ~= "ready" then
    snapshot.hookStatus = state.bridgeStatus
    snapshot.hookError = state.bridgeError
  end
  noctalia.state.set(common.SNAPSHOT_KEY, snapshot)
end

local function set_bridge_dir(path)
  path = without_trailing_slash(path)
  if path == bridge_dir then return end
  bridge_dir = path
  selected_bridge_method = path == flatpak_bridge_path() and "flatpak" or "native"
  connection_path = path .. "/connection.json"
  change_path = path .. "/change.json"
  bridge_error_path = path .. "/bridge-error.json"
  command_dir = path .. "/commands"
  response_dir = path .. "/responses"
  state.bridgeDir = path
  state.bridgeStatus = "starting"
  state.bridgeError = ""
  state.hookStatus = "starting"
  state.hookError = ""
  state.connectionUpdatedAt = 0
  state.changeSequence = nil
  state.changedAt = 0
  state.changeReason = ""
  connection_signature = nil
  change_signature = nil
  bridge_error_signature = nil
  last_change_sequence = nil
end

local function discover_bridge_dir()
  if operations ~= nil and operations:bridge_pinned() and bridge_dir ~= "" then return end
  local override = trim(noctalia.getConfig("bridge_dir"))
  if override ~= "" then
    set_bridge_dir(without_trailing_slash(noctalia.expandPath(override)))
    return
  end
  local candidates = bridge_candidates()
  local selected, best_score = candidates[1], -1
  for _, candidate in ipairs(candidates) do
    local score = math.max(
      file_mtime(candidate .. "/connection.json"),
      file_mtime(candidate .. "/change.json")
    )
    if score > best_score then
      selected = candidate
      best_score = score
    end
  end
  if selected ~= nil then set_bridge_dir(selected) end
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
      if task.id == preferred_id then
        browse_index = index
        break
      end
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

local function rest_failure_message(result)
  if type(result) ~= "table" then return "The Super Productivity REST API returned no response." end
  if result.kind == "auth_required" then return "Super Productivity REST API authentication failed." end
  if result.kind == "timeout" then return "The Super Productivity REST API request timed out." end
  if result.kind == "transport_error" then return "The Super Productivity REST API is unavailable." end
  if result.kind == "invalid_response" then return "The Super Productivity REST API returned an invalid response." end
  if type(result.message) == "string" and result.message ~= "" then return result.message end
  if result.status ~= nil then return "Super Productivity REST API request failed (HTTP " .. tostring(result.status) .. ")." end
  return "Super Productivity REST API request failed."
end

local function rest_status_for_failure(result)
  if result.kind == "auth_required" then return "auth_required" end
  if result.kind == "timeout" then return "timeout" end
  if result.kind == "transport_error" then return "offline" end
  return "error"
end

local function complete_refresh(results)
  refresh_running = false
  local failure = nil
  for _, name in ipairs({ "tasks", "projects", "tags", "status" }) do
    local result = results[name]
    if type(result) ~= "table" or result.ok ~= true then
      failure = result or { kind = "invalid_response" }
      break
    end
  end

  if failure == nil and (type(results.tasks.data) ~= "table"
    or type(results.projects.data) ~= "table"
    or type(results.tags.data) ~= "table"
    or type(results.status.data) ~= "table") then
    failure = { kind = "invalid_response" }
  end

  local confirmation
  if failure == nil then
    local now_ms = noctalia.nowMs()
    local previous_id = if reset_view_on_refresh then nil else state.view and state.view.task.id or nil
    local normalized = rest_state.normalize(
      results.tasks.data,
      results.projects.data,
      results.tags.data,
      results.status.data,
      now_ms
    )
    confirmation = table.freeze({
      currentTask = normalized.currentTask and table.freeze({ id = normalized.currentTask.id }) or nil,
      currentTaskId = results.status.data.currentTaskId,
    })
    state.currentTask = normalized.currentTask
    state.upcoming = normalized.upcoming
    state.counts = normalized.counts
    state.generatedAt = now_ms
    state.receivedAt = now_ms
    state.restStatus = "ready"
    state.restError = ""
    if reset_view_on_refresh then browse_index = 1 end
    rebuild_view(previous_id)
    reset_view_on_refresh = false
  else
    local message = rest_failure_message(failure)
    state.restStatus = rest_status_for_failure(failure)
    state.restError = message
    state.lastError = message
  end

  local waiters = refresh_waiters
  refresh_waiters = {}
  for _, callback in ipairs(waiters) do callback(failure == nil, failure, confirmation) end
  publish()

  if refresh_again then
    refresh_again = false
    refresh_waiters = queued_refresh_waiters
    queued_refresh_waiters = {}
    request_rest_state()
  end
end

request_rest_state = function(callback)
  if refresh_running then
    refresh_again = true
    if type(callback) == "function" then table.insert(queued_refresh_waiters, callback) end
    return true
  end
  if type(callback) == "function" then table.insert(refresh_waiters, callback) end

  refresh_running = true
  state.restStatus = "checking"
  state.restError = ""
  publish()
  local results = {}
  local remaining = 4
  local function receive(name, result)
    results[name] = result
    remaining -= 1
    if remaining == 0 then complete_refresh(results) end
  end
  rest_client:tasks(function(result) receive("tasks", result) end)
  rest_client:projects(function(result) receive("projects", result) end)
  rest_client:tags(function(result) receive("tags", result) end)
  rest_client:status(function(result) receive("status", result) end)
  return true
end

local function connection_is_fresh()
  return state.connectionUpdatedAt > 0
    and noctalia.nowMs() - state.connectionUpdatedAt <= CONNECTION_GRACE_MS
end

local function refresh_connection_file()
  if connection_path == "" then return end
  local signature = file_signature(connection_path)
  if signature == nil then
    connection_signature = nil
    state.bridgeStatus = state.appRunning and "companion_missing" or "offline"
    return
  end
  if signature == connection_signature then
    if state.bridgeStatus == "ready" and not connection_is_fresh() then state.bridgeStatus = "stale" end
    return
  end
  connection_signature = signature
  local connection = decode_file(connection_path)
  if type(connection) ~= "table" then
    state.bridgeStatus = "error"
    state.bridgeError = "The companion connection metadata is invalid."
    state.lastError = state.bridgeError
    return
  end
  if tonumber(connection.schemaVersion) ~= SCHEMA_VERSION
    or tonumber(connection.protocolVersion) ~= BRIDGE_PROTOCOL_VERSION then
    state.bridgeStatus = "protocol_mismatch"
    state.bridgeError = noctalia.tr("error.protocol_mismatch")
    state.protocolVersion = tonumber(connection.protocolVersion)
    state.lastError = state.bridgeError
    return
  end

  state.companionVersion = tostring(connection.companionVersion or "")
  state.protocolVersion = BRIDGE_PROTOCOL_VERSION
  state.connectionUpdatedAt = bridge_timestamp(connection.updatedAt) or 0
  state.bridgeError = trim(connection.error)
  local status = trim(connection.status)
  if state.bridgeError ~= "" or status == "error" then
    state.bridgeStatus = "error"
    if state.bridgeError == "" then state.bridgeError = "The companion reported an error." end
    state.lastError = state.bridgeError
  elseif status == "ready" then
    state.bridgeStatus = connection_is_fresh() and "ready" or "stale"
  elseif status == "offline" or status == "stopped" or status == "unloaded" then
    state.bridgeStatus = "offline"
  else
    state.bridgeStatus = "starting"
  end
end

local function valid_change(change)
  if not compatible_bridge_file(change) then return false end
  local sequence = tonumber(change.sequence)
  return sequence ~= nil and sequence >= 0 and sequence % 1 == 0
    and bridge_timestamp(change.changedAt) ~= nil
    and type(change.companionVersion) == "string"
    and type(change.reason) == "string"
    and #change.reason <= MAX_CHANGE_REASON
end

local function refresh_change_file()
  if change_path == "" then return end
  local signature = file_signature(change_path)
  if signature == nil then
    change_signature = nil
    if state.bridgeStatus == "ready" then state.hookStatus = "waiting" end
    return
  end
  if signature == change_signature then return end
  local change = decode_file(change_path)
  if not valid_change(change) then
    state.hookStatus = type(change) == "table"
      and tonumber(change.protocolVersion) ~= BRIDGE_PROTOCOL_VERSION
      and "protocol_mismatch" or "error"
    state.hookError = state.hookStatus == "protocol_mismatch"
      and noctalia.tr("error.protocol_mismatch") or "The companion change notification is invalid."
    state.lastError = state.hookError
    return
  end

  local sequence = tonumber(change.sequence)
  if last_change_sequence ~= nil and sequence < last_change_sequence then
    state.hookStatus = "error"
    state.hookError = "The companion change sequence moved backwards."
    state.lastError = state.hookError
    return
  end

  change_signature = signature
  state.companionVersion = tostring(change.companionVersion)
  state.protocolVersion = BRIDGE_PROTOCOL_VERSION
  state.hookStatus = "ready"
  state.hookError = ""
  state.changeSequence = sequence
  state.changedAt = tonumber(change.changedAt)
  state.changeReason = tostring(change.reason or "")
  if last_change_sequence == nil or sequence > last_change_sequence then
    request_rest_state()
  end
  last_change_sequence = sequence
end

local function refresh_bridge_error()
  if bridge_error_path == "" then return end
  local signature = file_signature(bridge_error_path)
  if signature == nil then
    bridge_error_signature = nil
    return
  end
  if signature == bridge_error_signature then return end
  bridge_error_signature = signature
  local result = decode_file(bridge_error_path)
  if type(result) == "table" then
    local message = trim(result.error)
    if message ~= "" then
      state.bridgeStatus = "error"
      state.bridgeError = message
      state.lastError = message
    end
  end
end

local function resolve_launch()
  local method = trim(noctalia.getConfig("launch_method"))
  if method == "" then method = "auto" end
  if method == "auto" then
    if state.bridgeStatus == "ready" and selected_bridge_method ~= "" then
      method = selected_bridge_method
    else
      method = noctalia.flatpakAppInstalled(FLATPAK_ID) and "flatpak" or "native"
    end
  end
  if method == "flatpak" then
    local available = noctalia.flatpakAppInstalled(FLATPAK_ID)
    return {
      spec = { "flatpak", "run", FLATPAK_ID },
      processCommand = "superproductivity",
      method = "flatpak",
      available = available,
      error = if available then nil else noctalia.tr("error.app_unavailable"),
    }
  end

  local command = trim(noctalia.getConfig("native_command"))
  if command == "" then command = "superproductivity" end
  if command:sub(1, 1) ~= "/" and command:find("%s") then
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
    processCommand = command,
    method = "native",
    available = available,
    error = if available then nil else noctalia.tr("error.app_unavailable"),
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
    state.bridgeError = resolved.error or noctalia.tr("error.app_unavailable")
    state.lastError = state.bridgeError
    publish()
    return false
  end
  local started = noctalia.runAsync(resolved.spec)
  if not started then
    state.bridgeError = noctalia.tr("error.launch_failed")
    state.lastError = state.bridgeError
  end
  publish()
  return started
end

local function probe_process()
  local resolved = resolve_launch()
  local command = resolved.processCommand or "superproductivity"
  local function complete(matched)
    state.appRunning = matched == true
    apply_launch_diagnostics(resolved)
    if not state.appRunning and state.bridgeStatus == "ready" then state.bridgeStatus = "offline" end
    publish()
  end
  noctalia.processMatches(function(matched)
    if matched ~= true and command ~= "superproductivity" then
      -- wrappers can exec the standard process after launch.
      noctalia.processMatches(complete, "superproductivity")
    else
      complete(matched)
    end
  end, command)
end

local function play_completion_sound()
  if noctalia.getConfig("sound_on_complete") == false then return end
  if sound_ready then noctalia.sound.play(SOUND_NAME) end
end
local function clear_rest_task_state()
  state.currentTask = nil
  state.upcoming = {}
  state.view = nil
  state.counts = { active = 0, due = 0, overdue = 0 }
  state.generatedAt = 0
  browse_index = 1
end

operations = operation.new({
  schema = SCHEMA_VERSION,
  protocol = common.PROTOCOL_VERSION,
  now = noctalia.nowMs,
  tr = noctalia.tr,
  rest = rest_client,
  refresh = request_rest_state,
  publish_action = function(value) noctalia.state.set(common.ACTION_KEY, value) end,
  publish = publish,
  failure_message = rest_failure_message,
  rest_failure = function(result, message)
    state.lastError = message
    if result.kind == "auth_required" or result.kind == "timeout"
      or result.kind == "transport_error" or result.kind == "invalid_response" then
      state.restStatus = rest_status_for_failure(result)
      state.restError = message
    end
  end,
  set_error = function(message, bridge)
    state.lastError = message
    if bridge then state.bridgeError = message end
  end,
  notify_error = function(message) noctalia.notifyError(noctalia.tr("notify.command_failed_title"), message) end,
  notify_added = function(input) noctalia.notify(noctalia.tr("notify.added_title"), input) end,
  complete = function(task, now_ms)
    if type(task) == "table" then state.undo = { task = task, expiresAt = now_ms + 30000 } end
    browse_index = 1
    reset_view_on_refresh = true
    play_completion_sound()
  end,
  restore = function() state.undo = nil end,
  clear_tasks = clear_rest_task_state,
  connection = function()
    refresh_connection_file()
    return state.bridgeStatus == "ready", state.connectionUpdatedAt
  end,
  launch = function() return launch_app(), state.bridgeError end,
  bridge_paths = function()
    if bridge_dir == "" then discover_bridge_dir() end
    return command_dir, response_dir
  end,
  command_sent = function(now_ms) state.lastCommandAt = now_ms end,
  response_received = function(now_ms) state.lastResponseAt = now_ms end,
  mkdir = noctalia.mkdirAll,
  encode = noctalia.json.encode,
  write = noctalia.writeFile,
  rename = noctalia.renameFile,
  remove = noctalia.removeFile,
  list = noctalia.listDir,
  decode_file = decode_file,
})

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

  state.packageStatus = "running"
  state.packageError = ""
  publish()
  local started = noctalia.runAsync(
    { "python3", package_script_path(), "--machine-readable" },
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
  elseif kind == "launch" then
    launch_app()
  elseif kind == "refresh" then
    operations:submit({ type = "refresh", requestId = request_id })
  elseif kind == "open" and task_id ~= "" then
    operations:submit({ type = "open", taskId = task_id, requestId = request_id })
  elseif kind == "complete" and task_id ~= "" then
    local task = state.view and state.view.task or nil
    if type(task) ~= "table" or task.id ~= task_id then
      state.lastError = noctalia.tr("error.task_changed")
      publish()
      return
    end
    operations:submit({ type = "complete", taskId = task_id, requestId = request_id, task = task })
  elseif kind == "add" then
    local input = type(intent.input) == "string" and intent.input or ""
    if trim(input) ~= "" then
      operations:submit({ type = "add", requestId = request_id, input = input, source = intent.source })
    end
  elseif kind == "timer_toggle" and task_id ~= "" then
    local is_current = type(state.currentTask) == "table" and state.currentTask.id == task_id
    operations:submit({ type = is_current and "timer_stop" or "timer_start", taskId = task_id, requestId = request_id })
  elseif kind == "snooze" and task_id ~= "" then
    operations:submit({ type = "snooze", taskId = task_id, requestId = request_id, mode = tostring(intent.mode or "") })
  elseif kind == "undo" then
    local undo = state.undo
    if type(undo) == "table" and undo.expiresAt > noctalia.nowMs() then
      operations:submit({ type = "restore", taskId = undo.task.id, requestId = request_id })
    end
  end
end

noctalia.state.watch(common.INTENT_KEY, handle_intent)

function update()
  local now_ms = noctalia.nowMs()
  rest_client:update(now_ms)

  if now_ms - last_bridge_search_ms >= 10000 then
    last_bridge_search_ms = now_ms
    discover_bridge_dir()
  end
  if now_ms - last_process_check_ms >= 10000 then
    last_process_check_ms = now_ms
    probe_process()
  end
  if now_ms - last_file_poll_ms >= BRIDGE_POLL_MS then
    last_file_poll_ms = now_ms
    refresh_connection_file()
    refresh_change_file()
    refresh_bridge_error()
  end
  operations:update(now_ms)
  due_notifications(now_ms)

  if type(state.undo) == "table" and state.undo.expiresAt <= now_ms then state.undo = nil end

  if noctalia.getConfig("auto_start") == true and not auto_start_attempted
    and not state.appRunning and now_ms - service_started_at > 1500 and state.restStatus ~= "ready" then
    auto_start_attempted = true
    launch_app()
  end
  publish()
end

function onConfigChanged()
  auto_start_attempted = false
  discover_bridge_dir()
  rest_client:invalidate_for_config()
  rebuild_view(state.view and state.view.task.id or nil)
  request_rest_state()
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
publish()
request_rest_state()
