--!nonstrict
-- Handy service. Handy exposes no control socket: recording state comes from
-- its log and PipeWire record stream, history from its SQLite database, and
-- every mutation goes through the `handy` CLI. Publishing one snapshot keeps
-- the widget and panel consistent.

local SNAPSHOT_KEY = "snapshot"
local COMMAND_KEY = "command"

local LOG_LINES = 120
local MAX_ERROR_CHARS = 180

local snapshot = {
  available = false,
  running = false,
  state = "idle",
  dataDir = "",
  recordingsDir = "",
  history = {},
  latest = nil,
  models = {},
  activeModel = nil,
  error = nil,
  updatedAt = 0,
}

local handyCommand = "handy"
local commandName = "handy"

local dataDir = ""
local dbPath = ""
local logPath = ""
local recordingsDir = ""

local historyCache = {}
local dbStamp = nil
local lastFingerprint = nil
local lastCommandNonce = nil
local lastLoggedError = nil
local lastLogState = nil
local lastLogStateAt = 0
local deletingTranscript = false
local modelsPending = false
local lastModelFetch = 0
local modelRefreshAt = 0
local publish
local poll

local polling = false
local pollId = 0

local function log(message)
  noctalia.log("[Handy] " .. tostring(message))
end

local function translated(key, fallback, subst)
  local value = noctalia.tr(key, subst)
  if value == nil or value == key then
    return fallback
  end
  return value
end

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function elide(value)
  local text = trim(value):gsub("%s+", " ")
  if #text > MAX_ERROR_CHARS then
    return text:sub(1, MAX_ERROR_CHARS - 1) .. "…"
  end
  return text
end

local function clampInt(value, fallback, minimum, maximum)
  local number = math.floor(tonumber(value) or fallback)
  if number < minimum then
    number = minimum
  end
  if number > maximum then
    number = maximum
  end
  return number
end

local function refreshIntervalMs()
  return clampInt(noctalia.getConfig("refresh_seconds"), 1, 1, 10) * 1000
end

local function modelRefreshSeconds()
  return clampInt(noctalia.getConfig("model_refresh_seconds"), 10, 5, 60)
end

local function commandAvailable(command)
  if string.find(command, "/", 1, true) ~= nil then
    return noctalia.fileExists(command)
  end
  return noctalia.commandExists(command)
end

local function resolveCommand()
  local configured = noctalia.getConfig("handy_command")
  if type(configured) == "string" then
    configured = trim(configured)
  else
    configured = ""
  end
  if configured == "" then
    configured = "handy"
  end
  if string.sub(configured, 1, 1) == "~" or string.sub(configured, 1, 1) == "/" then
    configured = noctalia.expandPath(configured)
  end
  handyCommand = configured
  commandName = string.match(configured, "([^/]+)$") or configured
end

local function resolvePaths()
  local configured = noctalia.getConfig("data_dir")
  if type(configured) == "string" and configured ~= "" then
    dataDir = noctalia.expandPath(configured)
  else
    local candidates = {}
    local xdg = noctalia.getenv("XDG_DATA_HOME")
    if type(xdg) == "string" and xdg ~= "" then
      table.insert(candidates, xdg .. "/com.pais.handy")
    end
    table.insert(candidates, "~/.local/share/com.pais.handy")
    table.insert(candidates, "~/Library/Application Support/com.pais.handy")

    dataDir = nil
    for _, candidate in ipairs(candidates) do
      local path = noctalia.expandPath(candidate)
      if noctalia.fileExists(path) then
        dataDir = path
        break
      end
    end
    if dataDir == nil then
      dataDir = noctalia.expandPath("~/.local/share/com.pais.handy")
    end
  end

  dbPath = dataDir .. "/history.db"
  logPath = dataDir .. "/logs/handy.log"
  recordingsDir = dataDir .. "/recordings"
end

local function parseLog(text)
  local state = nil

  for line in (text or ""):gmatch("[^\n]+") do
    if string.find(line, "tray apply:", 1, true) then
      if string.find(line, "icon=unchanged", 1, true) then
        if string.find(line, "busy=false", 1, true) then
          state = "idle"
        end
      elseif string.find(line, "recording", 1, true) then
        state = "recording"
      elseif string.find(line, "transcribing", 1, true) then
        state = "transcribing"
      elseif string.find(line, "busy=false", 1, true) then
        state = "idle"
      end
    elseif string.find(line, "recording stopped after", 1, true) then
      state = "transcribing"
    elseif string.find(line, "Starting async transcription task", 1, true) then
      state = "transcribing"
    elseif string.find(line, "Transcription completed", 1, true)
      or string.find(line, "Transcription failed", 1, true)
      or string.find(line, "Transcription operation cancelled", 1, true)
      or string.find(line, "Transcription cancelled", 1, true)
      or string.find(line, "Recording produced no audio samples", 1, true)
      or string.find(line, "Recording stop cancelled", 1, true) then
      state = "idle"
    end
  end

  return state
end

local function recordStreamPresent(stdout)
  for line in (stdout or ""):gmatch("[^\n]+") do
    if string.find(line, 'application.name = "cpal-pulseaudio-', 1, true) then
      return true
    end
  end
  return false
end

local function parseHistory(stdout)
  local text = trim(stdout)
  if text == "" then
    return {}
  end

  local decoded = noctalia.json.decode(text)
  if type(decoded) ~= "table" then
    return nil
  end

  local rows = {}
  for _, row in ipairs(decoded) do
    if type(row) == "table" then
      local original = tostring(row.transcription_text or "")
      local processed = row.post_processed_text
      local textValue = original
      if type(processed) == "string" and processed ~= "" then
        textValue = processed
      end

      local saved = row.saved == true or tonumber(row.saved) == 1
      table.insert(rows, {
        id = tonumber(row.id) or 0,
        file = tostring(row.file_name or ""),
        timestamp = tonumber(row.timestamp) or 0,
        saved = saved,
        title = tostring(row.title or ""),
        text = textValue,
        original = original,
        language = tostring(row.language or ""),
      })
    end
  end
  return rows
end

local function parseTrayModels(decoded)
  if type(decoded) ~= "table" or type(decoded.data) ~= "table" then
    return nil
  end
  local root = decoded.data[2]
  if type(root) ~= "table" or type(root[3]) ~= "table" then
    return nil
  end

  for _, item in ipairs(root[3]) do
    local data = item.data
    local props = data and data[2]
    local children = data and data[3]
    local display = props and props["children-display"] and props["children-display"].data
    if display == "submenu" and type(children) == "table" then
      -- tray.rs puts the model submenu first; the language submenu follows it.
      local models = {}
      local active = nil
      for _, modelItem in ipairs(children) do
        local modelData = modelItem.data
        local modelProps = modelData and modelData[2]
        local name = modelProps and modelProps.label and modelProps.label.data
        if type(name) == "string" and name ~= "" then
          local checked = modelProps["toggle-state"] and modelProps["toggle-state"].data == 1
          table.insert(models, { id = modelData[1], name = name, active = checked })
          if checked then
            active = name
          end
        end
      end
      return models, active
    end
  end

  return nil
end

local function fetchTrayMenu(callback)
  local function fail(reason)
    callback(nil, reason)
  end

  local procAccepted = noctalia.runAsync({ "pgrep", "-x", commandName }, function(proc)
    local pid = trim(proc.stdout)
    if proc.exitCode ~= 0 or pid == "" then
      fail("handy is not running")
      return
    end

    local watcherAccepted = noctalia.runAsync({
      "busctl", "--user", "--json=short", "get-property",
      "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
      "org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems",
    }, function(watcher)
      local watcherDecoded = noctalia.json.decode(watcher.stdout or "")
      local items = type(watcherDecoded) == "table" and watcherDecoded.data or nil
      if watcher.exitCode ~= 0 or type(items) ~= "table" then
        fail("tray watcher unavailable")
        return
      end

      local matched = nil
      for _, item in ipairs(items) do
        if type(item) == "string" and string.find(item, "tray_app_" .. pid .. "_", 1, true) then
          matched = item
          break
        end
      end
      if matched == nil then
        for _, item in ipairs(items) do
          if type(item) == "string" and string.find(item, "/" .. pid .. "_", 1, true) then
            matched = item
            break
          end
        end
      end
      if matched == nil then
        fail("tray icon not found")
        return
      end

      local dest, path = string.match(matched, "^([^/]+)(/.*)$")
      if dest == nil then
        fail("invalid tray item")
        return
      end

      local propertyAccepted = noctalia.runAsync({
        "busctl", "--user", "--json=short", "get-property", dest, path,
        "org.kde.StatusNotifierItem", "Menu",
      }, function(menuProperty)
        local menuDecoded = noctalia.json.decode(menuProperty.stdout or "")
        local menuPath = menuDecoded and menuDecoded.data
        if menuProperty.exitCode ~= 0 or type(menuPath) ~= "string" then
          fail("tray menu unavailable")
          return
        end

        local layoutAccepted = noctalia.runAsync({
          "busctl", "--user", "--json=short", "call", dest, menuPath,
          "com.canonical.dbusmenu", "GetLayout", "iias", "0", "2", "0",
        }, function(layout)
          if layout.exitCode ~= 0 then
            fail("tray menu read failed")
            return
          end
          local layoutDecoded = noctalia.json.decode(layout.stdout or "")
          local models, active = parseTrayModels(layoutDecoded)
          if models == nil then
            fail("model menu unavailable")
            return
          end
          callback({ models = models, active = active, dest = dest, menuPath = menuPath })
        end)
        if not layoutAccepted then
          fail("tray menu read failed")
        end
      end)
      if not propertyAccepted then
        fail("tray menu unavailable")
      end
    end)
    if not watcherAccepted then
      fail("tray watcher unavailable")
    end
  end)
  if not procAccepted then
    fail("handy is not running")
  end
end

local function refreshModels()
  if modelsPending then
    return
  end
  modelsPending = true
  fetchTrayMenu(function(menu)
    modelsPending = false
    if menu == nil then
      return
    end
    snapshot.models = menu.models
    snapshot.activeModel = menu.active
    lastModelFetch = os.time()
    publish()
  end)
end

local function selectModel(name)
  fetchTrayMenu(function(menu)
    if menu == nil then
      noctalia.notifyError("Handy", translated("errors.tray_unavailable", "Handy tray menu is unavailable"))
      return
    end

    local target = nil
    for _, model in ipairs(menu.models) do
      if model.name == name then
        target = model
        break
      end
    end
    if target == nil then
      noctalia.notifyError("Handy", translated("errors.model_not_found", "Model not found in Handy's menu"))
      return
    end
    if target.active then
      return
    end
    local accepted = noctalia.runAsync({
      "dbus-send", "--session", "--dest=" .. menu.dest, "--type=method_call",
      menu.menuPath, "com.canonical.dbusmenu.Event",
      "int32:" .. tostring(target.id), "string:clicked", "variant:int32:0", "uint32:0",
    }, function(result)
      if result.exitCode ~= 0 then
        noctalia.notifyError("Handy", translated("errors.tray_unavailable", "Handy tray menu is unavailable"))
      end
      poll()
      modelRefreshAt = os.time() + 2
    end)
    if not accepted then
      noctalia.notifyError("Handy", translated("errors.tray_unavailable", "Handy tray menu is unavailable"))
      return
    end
    noctalia.notify("Handy", translated("notify.switching", "Switching model to {model}", { model = name }))
  end)
end

publish = function()
  local latest = snapshot.latest
  local latestId = latest and tostring(latest.id) or ""
  local stamp = dbStamp and (tostring(dbStamp.mtime) .. ":" .. tostring(dbStamp.size)) or ""
  local modelNames = {}
  for _, model in ipairs(snapshot.models) do
    table.insert(modelNames, (model.active and "*" or "") .. model.name)
  end
  local fingerprint = table.concat({
    tostring(snapshot.available),
    tostring(snapshot.running),
    snapshot.state,
    snapshot.error or "",
    tostring(#snapshot.history),
    latestId,
    stamp,
    snapshot.activeModel or "",
    table.concat(modelNames, "|"),
  }, "|")

  if fingerprint == lastFingerprint then
    return
  end
  lastFingerprint = fingerprint
  noctalia.state.set(SNAPSHOT_KEY, snapshot)
end

local function apply(_id, result)
  local handyExists = commandAvailable(handyCommand)
  local dirExists = noctalia.fileExists(dataDir)

  snapshot.dataDir = dataDir
  snapshot.recordingsDir = recordingsDir
  snapshot.available = handyExists and dirExists
  snapshot.running = result.running
  snapshot.updatedAt = os.time()

  if result.history ~= nil then
    historyCache = result.history
    snapshot.history = historyCache
  else
    snapshot.history = historyCache
  end
  snapshot.latest = snapshot.history[1]

  if result.logState ~= nil and result.logState ~= lastLogState then
    lastLogState = result.logState
    lastLogStateAt = os.time()
  end

  -- Keep a state the log reported earlier: a quiet log between "recording
  -- stopped" and "Transcription completed" must not flicker back to idle.
  local logState = result.logState or lastLogState
  if logState == "transcribing" and os.time() - lastLogStateAt > 60 then
    logState = "idle"
  end

  local state = "idle"
  if result.running then
    if result.record then
      state = "recording"
    elseif logState ~= nil then
      if logState == "recording" then
        -- A stale log line after the stream ended must not pin the widget to
        -- "recording"; pactl is the authority when it is available.
        state = result.pactlOk and "idle" or "recording"
      else
        state = logState
      end
    end
  end
  snapshot.state = state

  if not handyExists then
    snapshot.error = translated("errors.handy_missing", "The handy command was not found")
  elseif result.historyError ~= nil then
    snapshot.error = result.historyError
  elseif not dirExists then
    snapshot.error = translated("errors.data_dir_missing", "Handy data directory not found")
  else
    snapshot.error = nil
  end

  if snapshot.error ~= nil and snapshot.error ~= lastLoggedError then
    log(snapshot.error)
  end
  lastLoggedError = snapshot.error

  publish()
end

poll = function()
  if polling then
    return
  end
  polling = true
  pollId += 1
  local current = pollId
  local result = {
    running = false,
    record = false,
    logState = nil,
    pactlOk = false,
  }
  local pending = 4

  local function finish()
    pending -= 1
    if pending > 0 then
      return
    end
    if current ~= pollId then
      polling = false
      return
    end
    polling = false
    apply(current, result)
  end

  -- Is the app running?
  local accepted = noctalia.runAsync({ "pgrep", "-x", commandName }, function(r)
    result.running = r.exitCode == 0
    finish()
  end)
  if not accepted then
    finish()
  end

  -- Is a capture stream open? cpal names PulseAudio streams cpal-pulseaudio-<pid>.
  if not noctalia.commandExists("pactl") then
    finish()
  else
    local streamAccepted = noctalia.runAsync({ "pactl", "list", "source-outputs" }, function(r)
      if r.exitCode == 0 then
        result.pactlOk = true
        result.record = recordStreamPresent(r.stdout)
      end
      finish()
    end)
    if not streamAccepted then
      finish()
    end
  end

  -- Recent log lines carry the tray icon state even without PipeWire.
  local logInfo = noctalia.fileInfo(logPath)
  if logInfo == nil or logInfo.isDir then
    finish()
  else
    local logAccepted = noctalia.runAsync({ "tail", "-n", tostring(LOG_LINES), logPath }, function(r)
      if r.exitCode == 0 then
        result.logState = parseLog(r.stdout)
      end
      finish()
    end)
    if not logAccepted then
      finish()
    end
  end

  -- History is only re-read when SQLite's file stamp changes.
  local dbInfo = noctalia.fileInfo(dbPath)
  if dbInfo == nil or dbInfo.isDir then
    dbStamp = nil
    result.history = {}
    finish()
  elseif not noctalia.commandExists("sqlite3") then
    result.historyError = translated("errors.sqlite_missing", "sqlite3 was not found")
    finish()
  elseif dbStamp ~= nil and dbStamp.mtime == dbInfo.mtime and dbStamp.size == dbInfo.size then
    finish()
  else
    local limit = math.floor(tonumber(noctalia.getConfig("history_limit")) or 30)
    limit = math.max(1, math.min(200, limit))
    local sql = string.format(
      "SELECT id, file_name, timestamp, saved, title, transcription_text, post_processed_text, language "
        .. "FROM transcription_history ORDER BY id DESC LIMIT %d",
      limit
    )

    local queryAccepted = noctalia.runAsync({ "sqlite3", "-json", dbPath, sql }, function(r)
      if r.exitCode ~= 0 then
        dbStamp = nil
        local details = elide(r.stderr)
        result.historyError = translated("errors.history", "Could not read Handy history")
          .. (details ~= "" and ": " .. details or "")
      else
        local rows = parseHistory(r.stdout)
        if rows == nil then
          dbStamp = nil
          result.historyError = translated("errors.history", "Could not read Handy history")
        else
          dbStamp = dbInfo
          result.history = rows
        end
      end
      finish()
    end)
    if not queryAccepted then
      finish()
    end
  end
end

local function runHandy(args, label)
  local accepted = noctalia.runAsync(args, function(r)
    if r.exitCode ~= 0 then
      local details = elide(r.stderr)
      local message = translated("errors.command_failed", "Handy command failed", { command = label })
      if details ~= "" then
        message = message .. ": " .. details
      end
      log(message)
      noctalia.notifyError("Handy", message)
    end
    poll()
  end)
  if not accepted then
    noctalia.notifyError("Handy", translated("errors.handy_missing", "The handy command was not found"))
  end
end

local function launchHandy()
  if not commandAvailable(handyCommand) then
    noctalia.notifyError("Handy", translated("errors.handy_missing", "The handy command was not found"))
    return
  end
  noctalia.runAsync({ handyCommand, "--start-hidden" })
end

local function recordingFilePath(fileName)
  if type(fileName) ~= "string" or fileName == "" then
    return nil
  end
  if string.find(fileName, "/", 1, true)
    or string.find(fileName, "\\", 1, true)
    or string.find(fileName, "..", 1, true) then
    return nil
  end
  return recordingsDir .. "/" .. fileName
end

local function deleteTranscript(id)
  if deletingTranscript then
    return
  end
  if not noctalia.commandExists("sqlite3") then
    noctalia.notifyError("Handy", translated("errors.sqlite_missing", "sqlite3 was not found"))
    return
  end
  if not noctalia.fileExists(dbPath) then
    noctalia.notifyError("Handy", translated("errors.delete_failed", "Could not delete transcript"))
    return
  end

  deletingTranscript = true
  local selectSql = string.format("SELECT file_name FROM transcription_history WHERE id = %d LIMIT 1", id)
  local accepted = noctalia.runAsync({ "sqlite3", "-json", dbPath, selectSql }, function(selectResult)
    if selectResult.exitCode ~= 0 then
      deletingTranscript = false
      local details = elide(selectResult.stderr)
      local message = translated("errors.delete_failed", "Could not delete transcript")
      if details ~= "" then
        message = message .. ": " .. details
      end
      log(message)
      noctalia.notifyError("Handy", message)
      return
    end

    local decoded = noctalia.json.decode(selectResult.stdout or "")
    local fileName = nil
    if type(decoded) == "table" and type(decoded[1]) == "table" then
      fileName = decoded[1].file_name
    end
    if type(fileName) ~= "string" or fileName == "" then
      deletingTranscript = false
      noctalia.notifyError("Handy", translated("errors.delete_failed", "Could not delete transcript"))
      return
    end

    local deleteSql = string.format(
      "PRAGMA busy_timeout=2000; DELETE FROM transcription_history WHERE id = %d",
      id
    )
    local deleteAccepted = noctalia.runAsync({ "sqlite3", dbPath, deleteSql }, function(deleteResult)
      deletingTranscript = false
      if deleteResult.exitCode ~= 0 then
        local details = elide(deleteResult.stderr)
        local message = translated("errors.delete_failed", "Could not delete transcript")
        if details ~= "" then
          message = message .. ": " .. details
        end
        log(message)
        noctalia.notifyError("Handy", message)
        return
      end

      local path = recordingFilePath(fileName)
      if path ~= nil and noctalia.fileExists(path) then
        local removed, removeError = noctalia.removeFile(path)
        if not removed then
          log("could not remove recording file: " .. tostring(removeError))
        end
      end

      dbStamp = nil
      poll()
    end)
    if not deleteAccepted then
      deletingTranscript = false
      noctalia.notifyError("Handy", translated("errors.delete_failed", "Could not delete transcript"))
    end
  end)
  if not accepted then
    deletingTranscript = false
    noctalia.notifyError("Handy", translated("errors.delete_failed", "Could not delete transcript"))
  end
end

local function handleCommand(command)
  local action = command.action
  if action == "toggle" then
    if not snapshot.running then
      launchHandy()
    else
      runHandy({ handyCommand, "--toggle-transcription" }, "toggle")
    end
  elseif action == "toggle_post_process" then
    if snapshot.running then
      runHandy({ handyCommand, "--toggle-post-process" }, "toggle post-processing")
    else
      noctalia.notifyError("Handy", translated("errors.not_running", "Handy is not running"))
    end
  elseif action == "cancel" then
    if snapshot.running then
      runHandy({ handyCommand, "--cancel" }, "cancel")
    end
  elseif action == "launch" then
    launchHandy()
  elseif action == "refresh" then
    poll()
    refreshModels()
  elseif action == "refresh_models" then
    refreshModels()
  elseif action == "select_model" then
    local name = command.model
    if type(name) == "string" and name ~= "" then
      selectModel(name)
    end
  elseif action == "delete_transcript" then
    local id = tonumber(command.id)
    if id ~= nil and id >= 1 and id == math.floor(id) then
      deleteTranscript(id)
    end
  elseif action == "copy_latest" then
    local latest = snapshot.latest
    if latest == nil then
      noctalia.notify("Handy", translated("panel.no_transcripts", "No transcripts yet"))
    else
      noctalia.copyToClipboard(latest.text, "text/plain")
    end
  elseif action == "open_recordings" then
    if not noctalia.commandExists("xdg-open") then
      noctalia.notifyError("Handy", translated("errors.open_folder", "Could not open the recordings folder"))
    else
      noctalia.runAsync({ "xdg-open", recordingsDir })
    end
  end
end

local function onCommand(value)
  if type(value) ~= "table" then
    return
  end
  local nonce = value.nonce
  if nonce ~= nil then
    if value.nonce == lastCommandNonce then
      return
    end
    lastCommandNonce = value.nonce
  end
  handleCommand(value)
end

resolveCommand()
resolvePaths()
noctalia.setUpdateInterval(refreshIntervalMs())
noctalia.state.watch(COMMAND_KEY, onCommand)
poll()

function update()
  poll()
  if modelRefreshAt > 0 and os.time() >= modelRefreshAt then
    modelRefreshAt = 0
    refreshModels()
  elseif snapshot.running and os.time() - lastModelFetch >= modelRefreshSeconds() then
    refreshModels()
  end
end

function onConfigChanged()
  resolveCommand()
  resolvePaths()
  noctalia.setUpdateInterval(refreshIntervalMs())
  dbStamp = nil
  historyCache = {}
  lastFingerprint = nil
  lastLogState = nil
  lastLogStateAt = 0
  lastModelFetch = 0
  snapshot.history = {}
  snapshot.latest = nil
  poll()
end

function onIpc(event, payload)
  if event == "delete_transcript" then
    local id = tonumber(payload)
    if id == nil and type(payload) == "table" then
      id = tonumber(payload[1])
    end
    if id ~= nil and id >= 1 and id == math.floor(id) then
      handleCommand({ action = "delete_transcript", id = id })
    end
    return
  end
  if event == "select_model" then
    local name = payload
    if type(name) == "table" then
      name = name[1]
    end
    if type(name) == "string" and name ~= "" then
      handleCommand({ action = "select_model", model = name })
    end
    return
  end
  if type(event) == "string" then
    handleCommand({ action = event })
  end
end
