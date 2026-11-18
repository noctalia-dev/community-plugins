--!nonstrict
-- Thunderbird Companion — background owner of bridge files and commands.
--
-- The bundled Thunderbird MailExtension talks to the bundled native host. The
-- host writes mailbox metadata to a private state directory; this service
-- publishes that snapshot for the widget/panel and writes validated commands.

local STALE_AFTER_MS = 150000
local CONNECTION_STALE_AFTER_SECONDS = 15
local MAX_SEEN_MESSAGES = 500
local BRIDGE_DATA_DIR_NAME = "noctalia-thunderbird-companion"
local BRIDGE_STATE_RELATIVE_PATH = "noctalia/thunderbird-companion"
local NATIVE_HOST_NAME = "dev.noctalia.thunderbird_companion"
local EXTENSION_ID = "thunderbird-companion@mdj2812.github.io"

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function without_trailing_slash(path)
  return tostring(path or ""):gsub("/+$", "")
end

local function state_home()
  local configured = trim(noctalia.getenv("XDG_STATE_HOME"))
  if configured ~= "" then
    return without_trailing_slash(configured)
  end
  return without_trailing_slash(noctalia.expandPath("~/.local/state"))
end

local function data_home()
  local configured = trim(noctalia.getenv("XDG_DATA_HOME"))
  if configured ~= "" then
    return without_trailing_slash(configured)
  end
  return without_trailing_slash(noctalia.expandPath("~/.local/share"))
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local BRIDGE_DIR = state_home() .. "/" .. BRIDGE_STATE_RELATIVE_PATH
local BRIDGE_DATA_DIR = data_home() .. "/" .. BRIDGE_DATA_DIR_NAME
local SNAPSHOT_PATH = BRIDGE_DIR .. "/snapshot.json"
local CONNECTION_PATH = BRIDGE_DIR .. "/connection.json"
local COMMAND_DIR = BRIDGE_DIR .. "/commands"
local ACTION_RESULT_PATH = BRIDGE_DIR .. "/action-result.json"
local BRIDGE_ERROR_PATH = BRIDGE_DIR .. "/bridge-error.json"
local PLUGIN_DIR = tostring(noctalia.pluginDir() or "")
local BRIDGE_VERSION_PATH = PLUGIN_DIR .. "/bridge-version.json"
local INSTALLED_HOST_PATH = BRIDGE_DATA_DIR .. "/host.py"
local INSTALLED_VERSION_PATH = BRIDGE_DATA_DIR .. "/installed-bridge.json"
local HOST_MANIFEST_PATH =
  noctalia.expandPath("~/.mozilla/native-messaging-hosts/" .. NATIVE_HOST_NAME .. ".json")
local DEFAULT_XPI_PATH = BRIDGE_DATA_DIR .. "/thunderbird-companion.xpi"

local state = {
  status = "starting",
  bridgeInstalled = false,
  bridgeDetected = false,
  bridgeConnected = false,
  bridgeVersion = "",
  requiredBridgeVersion = "",
  thunderbirdAvailable = false,
  unreadCount = 0,
  messages = {},
  accounts = {},
  generatedAt = 0,
  receivedAt = 0,
  error = "",
  setupStatus = "idle",
  setupError = "",
  xpiPath = "",
}

local raw_snapshot = nil
local snapshot_signature = nil
local action_signature = nil
local bridge_error_signature = nil
local initial_snapshot_seen = false
local last_command_seq = nil
local generated_command_seq = 0
local queued_file_seq = 0
local seen_messages = {}
local seen_order = {}

local function now_ms()
  return os.time() * 1000
end

local function max_messages()
  local value = tonumber(noctalia.getConfig("max_messages")) or 20
  return math.max(5, math.min(50, math.floor(value)))
end

local function thunderbird_command()
  local value = trim(noctalia.getConfig("thunderbird_command"))
  return value ~= "" and value or "thunderbird"
end

local function command_available()
  local command = thunderbird_command()
  if command == "thunderbird" then
    return noctalia.commandExists("thunderbird")
  end
  -- Custom values may include wrappers and arguments, which commandExists
  -- intentionally does not parse. Treat an explicit override as available.
  return true
end

local function decode_file(path)
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local ok, decoded = pcall(noctalia.json.decode, raw)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function file_signature(path)
  local info = noctalia.fileInfo(path)
  if type(info) ~= "table" then
    return nil
  end
  return tostring(info.mtime or "") .. ":" .. tostring(info.size or "")
end

local function message_key(message)
  local header_id = trim(message.headerMessageId)
  if header_id ~= "" then
    return "header:" .. header_id
  end
  return table.concat({
    "session",
    tostring(message.accountId or ""),
    tostring(message.folderPath or ""),
    tostring(message.id or ""),
  }, ":")
end

local function remember_message(key)
  if key == "" or seen_messages[key] then
    return false
  end
  seen_messages[key] = true
  table.insert(seen_order, key)
  while #seen_order > MAX_SEEN_MESSAGES do
    local oldest = table.remove(seen_order, 1)
    seen_messages[oldest] = nil
  end
  return true
end

local function notify_new_messages(messages)
  local should_notify = noctalia.getConfig("notify_new") == true and initial_snapshot_seen
  local notified = 0
  for _, message in ipairs(messages) do
    local is_new = remember_message(message_key(message))
    if is_new and should_notify and notified < 3 then
      local sender = trim(message.author)
      local subject = trim(message.subject)
      noctalia.notify(
        noctalia.tr("notify.new_mail"),
        noctalia.tr("notify.new_mail_body", {
          sender = sender ~= "" and sender or noctalia.tr("panel.unknown_sender"),
          subject = subject ~= "" and subject or noctalia.tr("panel.no_subject"),
        })
      )
      notified += 1
    end
  end
  initial_snapshot_seen = true
end

local function apply_snapshot(snapshot)
  if type(snapshot) ~= "table" or tonumber(snapshot.schemaVersion) ~= 1 then
    return false
  end

  local source_messages = {}
  for _, message in ipairs(type(snapshot.messages) == "table" and snapshot.messages or {}) do
    if type(message) == "table" and tonumber(message.id) ~= nil then
      table.insert(source_messages, message)
    end
  end
  notify_new_messages(source_messages)

  local messages = {}
  local limit = max_messages()
  for index, message in ipairs(source_messages) do
    if index > limit then
      break
    end
    table.insert(messages, message)
  end

  raw_snapshot = snapshot
  state.unreadCount = math.max(0, math.floor(tonumber(snapshot.unreadCount) or 0))
  state.messages = messages
  state.accounts = type(snapshot.accounts) == "table" and snapshot.accounts or {}
  state.generatedAt = tonumber(snapshot.generatedAt) or 0
  state.receivedAt = tonumber(snapshot.receivedAt) or state.generatedAt
  state.error = ""
  return true
end

local function refresh_snapshot_file()
  local signature = file_signature(SNAPSHOT_PATH)
  if signature == nil or signature == snapshot_signature then
    return
  end
  local decoded = decode_file(SNAPSHOT_PATH)
  if apply_snapshot(decoded) then
    snapshot_signature = signature
  end
end

local function refresh_action_result()
  local signature = file_signature(ACTION_RESULT_PATH)
  if signature == nil or signature == action_signature then
    return
  end
  action_signature = signature
  local result = decode_file(ACTION_RESULT_PATH)
  if type(result) == "table" and result.ok == false then
    local message = trim(result.error)
    state.error = message
    noctalia.notifyError(
      noctalia.tr("notify.command_failed"),
      message ~= "" and message or tostring(result.op or "")
    )
  elseif type(result) == "table" and result.ok == true then
    state.error = ""
  end
end

local function refresh_bridge_error()
  local signature = file_signature(BRIDGE_ERROR_PATH)
  if signature == nil then
    bridge_error_signature = nil
    return
  end
  if signature == bridge_error_signature then
    return
  end
  bridge_error_signature = signature
  local result = decode_file(BRIDGE_ERROR_PATH)
  if type(result) == "table" then
    state.error = trim(result.error)
  end
end

local function bridge_version_status()
  local required = decode_file(BRIDGE_VERSION_PATH)
  local installed = decode_file(INSTALLED_VERSION_PATH)
  local required_version = type(required) == "table" and trim(required.version) or ""
  local installed_version = type(installed) == "table" and trim(installed.version) or ""
  local required_protocol = type(required) == "table" and tonumber(required.bridgeProtocol) or nil
  local installed_protocol = type(installed) == "table" and tonumber(installed.bridgeProtocol) or nil
  local required_extension_id = type(required) == "table" and trim(required.extensionId) or ""
  local installed_extension_id = type(installed) == "table" and trim(installed.extensionId) or ""
  local required_host_name = type(required) == "table" and trim(required.nativeHostName) or ""
  local installed_host_name = type(installed) == "table" and trim(installed.nativeHostName) or ""
  local manifest_exists = noctalia.fileExists(HOST_MANIFEST_PATH)
  local host_exists = noctalia.fileExists(INSTALLED_HOST_PATH)
  local detected = host_exists or installed_version ~= ""
  local compatible = manifest_exists
    and host_exists
    and required_version ~= ""
    and required_version == installed_version
    and required_protocol ~= nil
    and required_protocol == installed_protocol
    and required_extension_id == EXTENSION_ID
    and required_extension_id == installed_extension_id
    and required_host_name == NATIVE_HOST_NAME
    and required_host_name == installed_host_name
  return compatible, detected, installed_version, required_version
end

local function bridge_connection_active()
  local connection = decode_file(CONNECTION_PATH)
  if type(connection) ~= "table" or tonumber(connection.schemaVersion) ~= 1 then
    return false
  end
  local heartbeat_at = tonumber(connection.heartbeatAt) or 0
  local heartbeat_seconds = math.floor(heartbeat_at / 1000)
  local age_seconds = os.time() - heartbeat_seconds
  return heartbeat_seconds > 0
    and age_seconds >= 0
    and age_seconds <= CONNECTION_STALE_AFTER_SECONDS
end

local function update_status()
  local compatible, detected, installed_version, required_version = bridge_version_status()
  state.bridgeInstalled = compatible
  state.bridgeDetected = detected
  state.bridgeConnected = bridge_connection_active()
  state.bridgeVersion = installed_version
  state.requiredBridgeVersion = required_version
  state.thunderbirdAvailable = command_available()
  if state.xpiPath == "" and noctalia.fileExists(DEFAULT_XPI_PATH) then
    state.xpiPath = DEFAULT_XPI_PATH
  end
  if state.bridgeInstalled and state.xpiPath ~= "" and state.setupStatus == "idle" then
    state.setupStatus = "ready"
  elseif not state.bridgeInstalled and state.setupStatus == "ready" then
    state.setupStatus = "idle"
  end

  local last_seen = tonumber(state.receivedAt) or 0
  local fresh = last_seen > 0 and now_ms() - last_seen <= STALE_AFTER_MS
  if not state.thunderbirdAvailable then
    state.status = "thunderbird_missing"
  elseif not state.bridgeInstalled then
    state.status = state.bridgeDetected and "bridge_incompatible" or "setup_required"
  elseif state.bridgeConnected and fresh then
    state.status = "online"
  elseif state.bridgeConnected and last_seen > 0 then
    state.status = "stale"
  else
    state.status = "offline"
  end
end

local function publish()
  noctalia.state.set("thunderbird.snapshot", state)
end

local function refresh()
  refresh_snapshot_file()
  refresh_action_result()
  refresh_bridge_error()
  update_status()
  publish()
end

local function next_command_seq()
  generated_command_seq += 1
  return tostring(os.time()) .. "-" .. tostring(generated_command_seq)
end

local function queue_bridge_command(command)
  local allowed = {
    open_message = true,
    mark_read = true,
    mark_all_read = true,
    archive = true,
    compose = true,
    reply = true,
    refresh = true,
  }
  if type(command) ~= "table" or not allowed[command.op] then
    return false, "unsupported command"
  end

  local encoded_command = {
    op = command.op,
    seq = command.seq or next_command_seq(),
  }
  if command.op == "open_message"
    or command.op == "mark_read"
    or command.op == "archive"
    or command.op == "reply"
  then
    local id = tonumber(command.id)
    if id == nil or id < 0 then
      return false, "invalid message id"
    end
    encoded_command.id = math.floor(id)
  end

  local ok, encoded = pcall(noctalia.json.encode, encoded_command)
  if not ok or type(encoded) ~= "string" then
    return false, "could not encode command"
  end

  queued_file_seq += 1
  local suffix = tostring(os.time())
    .. "-"
    .. tostring(math.floor(os.clock() * 1000000))
    .. "-"
    .. tostring(queued_file_seq)
  local path = COMMAND_DIR .. "/command-" .. suffix .. ".json"
  local temporary = path .. ".tmp"
  local written, write_error = noctalia.writeFile(temporary, encoded)
  if not written then
    return false, tostring(write_error or "could not write command")
  end
  local renamed, rename_error = noctalia.renameFile(temporary, path)
  if not renamed then
    noctalia.removeFile(temporary)
    return false, tostring(rename_error or "could not queue command")
  end
  return true
end

local function launch_thunderbird(compose)
  if not command_available() then
    noctalia.notifyError(noctalia.tr("notify.launch_failed"))
    return false
  end
  local command = thunderbird_command()
  if compose then
    command = command .. " -compose"
  end
  local started = noctalia.runAsync(command)
  if not started then
    noctalia.notifyError(noctalia.tr("notify.launch_failed"))
  end
  return started
end

local function xpi_path()
  return trim(state.xpiPath) ~= "" and state.xpiPath or DEFAULT_XPI_PATH
end

local function xpi_directory()
  return xpi_path():match("^(.*)/[^/]+$") or data_home()
end

local function open_addons_manager()
  if not command_available() then
    noctalia.notifyError(noctalia.tr("notify.launch_failed"))
    return false
  end
  return noctalia.runAsync(thunderbird_command() .. " " .. shell_quote("about:addons"))
end

local function open_xpi_directory()
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(noctalia.tr("notify.setup_failed"), "xdg-open is unavailable")
    return false
  end
  return noctalia.runAsync("xdg-open " .. shell_quote(xpi_directory()))
end

local function copy_xpi_path()
  local path = xpi_path()
  if not noctalia.fileExists(path) then
    return false
  end
  return noctalia.copyToClipboard(path, "text/plain")
end

local function setup_bridge()
  if state.setupStatus == "running" then
    return
  end
  local plugin_dir = noctalia.pluginDir()
  local script = type(plugin_dir) == "string" and plugin_dir .. "/scripts/setup-bridge.py"
    or "scripts/setup-bridge.py"
  state.setupStatus = "running"
  state.setupError = ""
  publish()

  local started = noctalia.runAsync(
    "python3 " .. shell_quote(script) .. " --machine-readable",
    function(result)
      if result.exitCode ~= 0 or result.timedOut then
        local message = trim(result.stderr)
        state.setupStatus = "error"
        state.setupError = message ~= "" and message or "bridge setup failed"
        publish()
        noctalia.notifyError(noctalia.tr("notify.setup_failed"), state.setupError)
        return
      end

      local path = tostring(result.stdout or ""):match("XPI_PATH=([^\r\n]+)")
      if path == nil or not noctalia.fileExists(path) then
        state.setupStatus = "error"
        state.setupError = "setup did not produce the companion package"
        publish()
        noctalia.notifyError(noctalia.tr("notify.setup_failed"), state.setupError)
        return
      end

      state.setupStatus = "ready"
      state.setupError = ""
      state.xpiPath = path
      update_status()
      publish()
    end,
    60000
  )
  if not started then
    state.setupStatus = "error"
    state.setupError = "could not start setup script"
    publish()
    noctalia.notifyError(noctalia.tr("notify.setup_failed"), state.setupError)
  end
end

local function handle_command(command)
  if type(command) ~= "table" then
    return
  end
  local seq = tostring(command.seq or "")
  if seq ~= "" and seq == last_command_seq then
    return
  end
  if seq ~= "" then
    last_command_seq = seq
  end

  local op = command.op
  if op == "launch" then
    launch_thunderbird(false)
    return
  end
  if op == "setup" then
    setup_bridge()
    return
  end
  if op == "open_addons" then
    open_addons_manager()
    return
  end
  if op == "open_xpi_directory" then
    open_xpi_directory()
    return
  end
  if op == "copy_xpi_path" then
    copy_xpi_path()
    return
  end
  if op == "compose" and state.status ~= "online" then
    launch_thunderbird(true)
    return
  end

  local ok, err = queue_bridge_command(command)
  if not ok then
    noctalia.notifyError(noctalia.tr("notify.command_failed"), tostring(err or ""))
  end
end

noctalia.state.watch("thunderbird.command", handle_command)

function update()
  noctalia.setUpdateInterval(2000)
  refresh()
end

function onConfigChanged()
  snapshot_signature = nil
  if raw_snapshot ~= nil then
    apply_snapshot(raw_snapshot)
  end
  refresh()
end

function onIpc(event, payload)
  if event == "refresh" then
    handle_command({ op = "refresh", seq = next_command_seq() })
  elseif event == "compose" then
    handle_command({ op = "compose", seq = next_command_seq() })
  elseif event == "launch" then
    handle_command({ op = "launch", seq = next_command_seq() })
  elseif event == "setup" then
    handle_command({ op = "setup", seq = next_command_seq() })
  elseif event == "cmd" and payload then
    local ok, command = pcall(noctalia.json.decode, payload)
    if ok and type(command) == "table" then
      command.seq = command.seq or next_command_seq()
      handle_command(command)
    end
  end
end

noctalia.mkdirAll(BRIDGE_DIR)
noctalia.mkdirAll(COMMAND_DIR)
refresh()
