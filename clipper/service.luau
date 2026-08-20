--!nonstrict
-- Clipper backend for Noctalia v5.
--
-- Shared-state contract:
--   clipper_snapshot   { revision, status, error, items, pinned, notes,
--                        watchers_running, total }
--   clipper_request    { request_id, operation, id?, paste? }
--   clipper_result     { request_id, operation, ok, error, id?, ... }
--   clipper_panel_open boolean
--
-- The service never decodes clipboard payloads into Lua. `cliphist list`
-- provides bounded metadata, image previews are decoded directly into a
-- plugin-owned cache, and activation streams bytes directly to wl-copy.

local SNAPSHOT_KEY = "clipper_snapshot"
local REQUEST_KEY = "clipper_request"
local RESULT_KEY = "clipper_result"
local PANEL_OPEN_KEY = "clipper_panel_open"

local DEFAULT_HISTORY_LIMIT = 100
local MIN_HISTORY_LIMIT = 1
local MAX_HISTORY_LIMIT = 2000
local PREVIEW_WIDTH = 240
local REFRESH_TIMEOUT_MS = 5000
local ACTION_TIMEOUT_MS = 5000
local ID_MAX_BYTES = 20
local REQUEST_ID_MAX_BYTES = 128
local IPC_PAYLOAD_MAX_BYTES = 512 * 1024
local MAX_PIN_TEXT_BYTES = 1024 * 1024
local MAX_PIN_IMAGE_BYTES = 10 * 1024 * 1024
local MAX_THUMBNAIL_BYTES = 25 * 1024 * 1024
local MAX_NOTES = 20
local MAX_NOTE_TITLE_BYTES = 200
local MAX_NOTE_CONTENT_BYTES = 256 * 1024
local MAX_NOTE_COORDINATE = 100000
local SELECTION_MENU_TTL_SECONDS = 30
local DATABASE_MODE_PRIVATE = "private"
local DATABASE_MODE_GLOBAL = "global"
local ipcRequestSequence = 0
local ipcRequestId

local dataDir, dataDirError = noctalia.pluginDataDir()
local privateDatabasePath = dataDir ~= nil and (dataDir .. "/cliphist.db") or nil
if dataDir == nil then
  -- The plugin data directory owns the private database, pins and notes. Its
  -- absence must never redirect private data to /tmp or the global database.
  noctalia.log("clipper: pluginDataDir unavailable: " .. tostring(dataDirError or "unknown"))
end

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function cfg(key)
  return noctalia.getConfig(key)
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function boundedString(value, maximum)
  if type(value) ~= "string" then return "" end
  if #value <= maximum then return value end
  return value:sub(1, maximum)
end

local function atomicWriteJson(path, value)
  if dataDir == nil then return false end
  local encoded = noctalia.json.encode(value, true)
  if type(encoded) ~= "string" then return false end
  local temporary = path .. ".tmp"
  local ok = noctalia.writeFile(temporary, encoded)
  if ok ~= true then return false end
  local renamed = noctalia.renameFile(temporary, path)
  if renamed ~= true then
    noctalia.removeFile(temporary)
    return false
  end
  return true
end

local function readJson(path)
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" or raw == "" then return nil end
  local ok, decoded = pcall(noctalia.json.decode, raw)
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

local function boundedInteger(value, fallback, minimum, maximum)
  local number = tonumber(value)
  if number == nil then return fallback end
  number = math.floor(number)
  return math.max(minimum, math.min(maximum, number))
end

local function noteCoordinate(value, fallback)
  local number = tonumber(value)
  if number == nil then return fallback end
  return math.max(0, math.min(MAX_NOTE_COORDINATE, math.floor(number + 0.5)))
end

local function historyLimit()
  return boundedInteger(cfg("history_limit"), DEFAULT_HISTORY_LIMIT, MIN_HISTORY_LIMIT, MAX_HISTORY_LIMIT)
end

local function databaseMode()
  return cfg("database_mode") == DATABASE_MODE_GLOBAL
    and DATABASE_MODE_GLOBAL or DATABASE_MODE_PRIVATE
end

local function cliphistEnvironment()
  local variables = {}
  if databaseMode() == DATABASE_MODE_PRIVATE then
    if privateDatabasePath == nil then return nil end
    variables[#variables + 1] = "CLIPHIST_DB_PATH=" .. shellQuote(privateDatabasePath)
  end
  variables[#variables + 1] = "CLIPHIST_MAX_ITEMS=" .. tostring(historyLimit())
  variables[#variables + 1] = "CLIPHIST_PREVIEW_WIDTH=" .. tostring(PREVIEW_WIDTH)
  return table.concat(variables, " ")
end

local function pasteDelayMs()
  return boundedInteger(cfg("auto_paste_delay"), 300, 0, 5000)
end

local function cleanPreview(value)
  if type(value) ~= "string" then return "" end
  -- cliphist already folds whitespace, but control bytes (for example a UTF-16
  -- clipboard preview containing NULs) must not be copied into shared state.
  return (value:gsub("%c", " "))
end

local IMAGE_MIMES = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  bmp = "image/bmp",
  tiff = "image/tiff",
}

local IMAGE_EXTENSIONS = {
  ["image/png"] = "png",
  ["image/jpeg"] = "jpg",
  ["image/gif"] = "gif",
  ["image/webp"] = "webp",
  ["image/bmp"] = "bmp",
  ["image/tiff"] = "tiff",
  ["image/*"] = "img",
}

local SAFE_MIMES = {
  ["text/plain"] = true,
  ["image/png"] = true,
  ["image/jpeg"] = true,
  ["image/gif"] = true,
  ["image/webp"] = true,
  ["image/bmp"] = true,
  ["image/tiff"] = true,
  ["image/*"] = true,
}
local SAFE_KINDS = {
  text = true, image = true, color = true, link = true, code = true, file = true,
}

local NOTE_COLORS = {
  "#FFD54F",
  "#F48FB1",
  "#90CAF9",
  "#A5D6A7",
  "#CE93D8",
}

local function opaqueNoteColor(value)
  if type(value) == "string" and value:match("^#%x%x%x%x%x%x%x%x$") then
    return value:sub(1, 7)
  end
  return value
end

local function validColor(value, fallback)
  if type(value) ~= "string" or #value > 64 then return fallback end
  if value:match("^#%x%x%x%x%x%x$") or value:match("^#%x%x%x%x%x%x%x%x$") then return value end
  local role, alpha = value:match("^([a-z_]+)(/[%d.]+)?$")
  local roles = {
    primary = true, secondary = true, tertiary = true, surface = true,
    surface_variant = true,
  }
  if role == nil or roles[role] ~= true then return fallback end
  if alpha ~= nil then
    local number = tonumber(alpha:sub(2))
    if number == nil or number < 0 or number > 1 then return fallback end
  end
  return value
end

local function classifyPreview(preview)
  local lower = preview:lower()
  if lower:find("[[ binary data ", 1, true) ~= 1 then
    if preview:match("^#%x%x%x%x%x%x$") or preview:match("^#%x%x%x$")
      or lower:match("^rgba?%s*%(") then
      return "color", false, "text/plain"
    end
    if lower:match("^https?://") then return "link", false, "text/plain" end
    if preview:match("^/") or preview:match("^~/") or lower:match("^file://") then
      return "file", false, "text/plain"
    end
    if lower:find("function", 1, true) or lower:find("import ", 1, true)
      or lower:find("const ", 1, true) or lower:find("class ", 1, true)
      or lower:find("def ", 1, true) then
      return "code", false, "text/plain"
    end
    return "text", false, "text/plain"
  end
  local format = lower:match("^%[%[ binary data .- ([%w+_.-]+) %d+x%d+ %]%]$")
  return "image", true, IMAGE_MIMES[format or ""] or "image/*"
end

local function parseList(output, limit)
  local items = {}
  local idSet = {}
  if type(output) ~= "string" then return items, idSet, false end

  local truncated = false
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local id, preview = line:match("^(%d+)\t(.*)$")
      if id ~= nil and #id <= ID_MAX_BYTES and not idSet[id] then
        if #items >= limit then
          truncated = true
          break
        end
        preview = cleanPreview(preview)
        local kind, isImage, mime = classifyPreview(preview)
        items[#items + 1] = {
          id = id,
          preview = preview,
          kind = kind,
          is_image = isImage,
          mime = mime,
        }
        idSet[id] = true
      end
    end
  end
  return items, idSet, truncated
end

local pinsDir = dataDir ~= nil and (dataDir .. "/pins") or nil
local thumbnailsDir = dataDir ~= nil and (dataDir .. "/thumbnails") or nil
local pinsFile = dataDir ~= nil and (dataDir .. "/pinned.json") or nil
local notesFile = dataDir ~= nil and (dataDir .. "/notes.json") or nil
local exportDir = noctalia.expandPath("~/Documents/Clipper")
local pinnedItems = {}
local notes = {}
local persistentCounter = 0

local function nextPersistentId(prefix)
  persistentCounter = persistentCounter + 1
  return prefix .. "-" .. tostring(os.time()) .. "-" .. tostring(persistentCounter)
end

local function validPersistentId(value, prefix)
  return type(value) == "string" and #value <= 64
    and value:match("^" .. prefix .. "%-%d+%-%d+$") ~= nil
end

local function pinPath(id)
  if pinsDir == nil or not validPersistentId(id, "pin") then return nil end
  return pinsDir .. "/" .. id .. ".bin"
end

local function savePinned()
  return pinsFile ~= nil and atomicWriteJson(pinsFile, { version = 1, items = pinnedItems })
end

local function saveNotes()
  return notesFile ~= nil and atomicWriteJson(notesFile, { version = 1, notes = notes })
end

local function loadPersistentData()
  if dataDir == nil then return end
  noctalia.mkdirAll(dataDir)
  noctalia.mkdirAll(pinsDir)

  local storedPins = readJson(pinsFile)
  if storedPins ~= nil and type(storedPins.items) == "table" then
    local maximum = boundedInteger(cfg("max_pinned"), 20, 1, 100)
    for _, item in ipairs(storedPins.items) do
      if #pinnedItems >= maximum then break end
      local id = type(item) == "table" and item.id or nil
      local path = pinPath(id)
      local mime = type(item) == "table" and item.mime or nil
      if path ~= nil and SAFE_MIMES[mime] == true and noctalia.fileExists(path) then
        local isImage = type(item.is_image) == "boolean" and item.is_image or mime:find("image/", 1, true) == 1
        pinnedItems[#pinnedItems + 1] = {
          id = id,
          preview = boundedString(item.preview, PREVIEW_WIDTH * 4),
          kind = SAFE_KINDS[item.kind] == true and item.kind or (isImage and "image" or "text"),
          mime = mime,
          is_image = isImage,
          image_path = isImage and path or "",
          pinned_at = tonumber(item.pinned_at) or 0,
        }
      end
    end
  end

  local storedNotes = readJson(notesFile)
  if storedNotes ~= nil and type(storedNotes.notes) == "table" then
    for _, note in ipairs(storedNotes.notes) do
      if #notes >= MAX_NOTES then break end
      if type(note) == "table" and validPersistentId(note.id, "note") then
        notes[#notes + 1] = {
          id = note.id,
          title = boundedString(note.title, MAX_NOTE_TITLE_BYTES),
          content = boundedString(note.content, MAX_NOTE_CONTENT_BYTES),
          color = opaqueNoteColor(validColor(note.color, "#FFD54F")),
          x = noteCoordinate(note.x, 24 + (#notes * 36)),
          y = noteCoordinate(note.y, 24 + (#notes * 28)),
          z = boundedInteger(note.z, #notes + 1, 1, MAX_NOTE_COORDINATE),
          created_at = tonumber(note.created_at) or 0,
          updated_at = tonumber(note.updated_at) or 0,
        }
      end
    end
  end
end

local revision = 0
local snapshotStatus = "idle"
local snapshotError = ""
local snapshotItems = {}
local snapshotIds = {}
local watchersRunning = false
local panelOpen = noctalia.state.get(PANEL_OPEN_KEY) == true
local snapshotDirty = true
local refreshInFlight = false
local refreshQueued = false
local actionBusy = false
local lastHandledRequestId = ""
local pendingPaste = nil
local pasteTarget = nil
local pasteCaptureGeneration = 0
local thumbnailQueue = {}
local thumbnailRunning = false
local thumbnailCache = {}
local thumbnailCleanupQueue = {}
local thumbnailUpdatesPending = false
local selectionMenuGeneration = 0
local pendingSelection = nil

local function environmentValue(key)
  if type(noctalia.getenv) ~= "function" then return "" end
  local value = noctalia.getenv(key)
  return type(value) == "string" and value or ""
end

local function decodeCommandJson(result)
  if result == nil or result.timedOut == true or result.exitCode ~= 0
    or type(result.stdout) ~= "string" or result.stdout == "" then
    return nil
  end
  local ok, decoded = pcall(noctalia.json.decode, result.stdout)
  return ok and type(decoded) == "table" and decoded or nil
end

local function capturePasteTarget()
  pasteCaptureGeneration = pasteCaptureGeneration + 1
  local generation = pasteCaptureGeneration
  pasteTarget = nil

  if environmentValue("HYPRLAND_INSTANCE_SIGNATURE") ~= ""
    and noctalia.commandExists("hyprctl") then
    noctalia.runAsync("hyprctl -j activewindow", function(result)
      if generation ~= pasteCaptureGeneration then return end
      local decoded = decodeCommandJson(result)
      local address = decoded ~= nil and decoded.address or nil
      if type(address) == "string" and address:match("^0x[%da-fA-F]+$") then
        pasteTarget = { compositor = "hyprland", id = address }
      end
    end, 2000)
    return
  end

  if environmentValue("NIRI_SOCKET") ~= "" and noctalia.commandExists("niri") then
    noctalia.runAsync("niri msg -j focused-window", function(result)
      if generation ~= pasteCaptureGeneration then return end
      local decoded = decodeCommandJson(result)
      local id = decoded ~= nil and tonumber(decoded.id) or nil
      if id ~= nil and id >= 0 and math.floor(id) == id then
        pasteTarget = { compositor = "niri", id = tostring(id) }
      end
    end, 2000)
    return
  end

  local mangoSocket = environmentValue("MANGO_INSTANCE_SIGNATURE")
  if mangoSocket ~= "" and noctalia.commandExists("nc") then
    local command = "printf '%s\\n' 'get all-clients' | nc -U " .. shellQuote(mangoSocket)
    noctalia.runAsync(command, function(result)
      if generation ~= pasteCaptureGeneration then return end
      local decoded = decodeCommandJson(result)
      local clients = decoded ~= nil and decoded.clients or nil
      if type(clients) ~= "table" then return end
      for _, client in ipairs(clients) do
        if type(client) == "table" and client.is_focused == true then
          local id = tostring(client.id or "")
          if id:match("^%d+$") then
            pasteTarget = { compositor = "mango", id = id }
            return
          end
        end
      end
    end, 2000)
  end
end

local function pasteFocusCommand()
  if type(pasteTarget) ~= "table" then return nil end
  local id = tostring(pasteTarget.id or "")
  if pasteTarget.compositor == "hyprland" and id:match("^0x[%da-fA-F]+$")
    and noctalia.commandExists("hyprctl") then
    local target = "address:" .. id
    local luaFocus = "hl.dsp.focus({window = \"" .. target .. "\"})"
    return "(hyprctl dispatch focuswindow " .. shellQuote(target)
      .. " || hyprctl eval " .. shellQuote(luaFocus) .. ")"
  end
  if pasteTarget.compositor == "niri" and id:match("^%d+$")
    and noctalia.commandExists("niri") then
    return "niri msg action focus-window --id " .. id
  end
  if pasteTarget.compositor == "mango" and id:match("^%d+$")
    and noctalia.commandExists("nc") then
    local mangoSocket = environmentValue("MANGO_INSTANCE_SIGNATURE")
    if mangoSocket ~= "" then
      return "printf '%s\\n' " .. shellQuote("dispatch focusid client," .. id)
        .. " | nc -U " .. shellQuote(mangoSocket)
    end
  end
  return nil
end

local function publishSnapshot(status, errorCode, items, ids)
  if status ~= nil then snapshotStatus = status end
  if errorCode ~= nil then snapshotError = errorCode end
  if items ~= nil then snapshotItems = items end
  if ids ~= nil then snapshotIds = ids end
  revision = revision + 1
  noctalia.state.set(SNAPSHOT_KEY, {
    revision = revision,
    status = snapshotStatus,
    error = snapshotError,
    items = snapshotItems,
    pinned = pinnedItems,
    notes = notes,
    watchers_running = watchersRunning,
    total = #snapshotItems,
  })
end

local function publishResult(requestId, operation, ok, errorCode, extra)
  local result = {
    request_id = requestId,
    operation = operation,
    ok = ok == true,
    error = errorCode or "",
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do result[key] = value end
  end
  noctalia.state.set(RESULT_KEY, result)
end

local function thumbnailPath(id, mime)
  if thumbnailsDir == nil then return nil end
  if type(id) ~= "string" or id:match("^%d+$") == nil then return nil end
  local extension = IMAGE_EXTENSIONS[mime] or "img"
  return thumbnailsDir .. "/" .. id .. "." .. extension
end

local function initializeThumbnailCache()
  if thumbnailsDir == nil or noctalia.mkdirAll(thumbnailsDir) ~= true
    or type(noctalia.listDir) ~= "function" then return end
  local entries = noctalia.listDir(thumbnailsDir)
  if type(entries) ~= "table" then return end
  for _, name in ipairs(entries) do
    local id = type(name) == "string" and name:match("^(%d+)%.[%w]+$") or nil
    local temporaryId = type(name) == "string" and name:match("^(%d+)%.[%w]+%.tmp$") or nil
    if temporaryId ~= nil then
      noctalia.removeFile(thumbnailsDir .. "/" .. name)
    elseif id ~= nil then
      thumbnailCache[id] = thumbnailsDir .. "/" .. name
    end
  end
end

local startNextThumbnail

startNextThumbnail = function()
  if thumbnailRunning then return end
  if #thumbnailQueue == 0 then
    if thumbnailUpdatesPending then
      thumbnailUpdatesPending = false
      publishSnapshot("ready", "")
    end
    return
  end
  local job = table.remove(thumbnailQueue, 1)
  local environment = cliphistEnvironment()
  if environment == nil then return end

  thumbnailRunning = true
  local temporaryPath = job.path .. ".tmp"
  local command = environment .. " cliphist decode " .. shellQuote(job.id)
    .. " > " .. shellQuote(temporaryPath)
  local started = noctalia.runAsync(command, function(result)
    thumbnailRunning = false
    local info = noctalia.fileInfo(temporaryPath)
    local valid = result ~= nil and result.timedOut ~= true and result.exitCode == 0
      and type(info) == "table" and tonumber(info.size) ~= nil
      and info.size > 0 and info.size <= MAX_THUMBNAIL_BYTES
    if valid and noctalia.renameFile(temporaryPath, job.path) == true then
      if snapshotIds[job.id] == true then
        thumbnailCache[job.id] = job.path
        for _, item in ipairs(snapshotItems) do
          if item.id == job.id and item.is_image == true then
            item.image_path = job.path
            thumbnailUpdatesPending = true
            break
          end
        end
      end
    else
      noctalia.removeFile(temporaryPath)
    end
    startNextThumbnail()
  end, ACTION_TIMEOUT_MS)
  if not started then
    thumbnailRunning = false
    noctalia.removeFile(temporaryPath)
    startNextThumbnail()
  end
end

local function prepareThumbnails(items, ids)
  thumbnailQueue = {}
  if thumbnailsDir == nil then return end
  for id, path in pairs(thumbnailCache) do
    if ids[id] ~= true then
      thumbnailCache[id] = nil
      thumbnailCleanupQueue[#thumbnailCleanupQueue + 1] = path
    end
  end
  for _, item in ipairs(items) do
    if item.is_image == true then
      local path = thumbnailPath(item.id, item.mime)
      local cachedPath = thumbnailCache[item.id]
      if cachedPath ~= nil then
        item.image_path = cachedPath
      elseif path ~= nil then
        thumbnailQueue[#thumbnailQueue + 1] = {
          id = item.id,
          path = path,
        }
      end
    end
  end
end

local function notifyError(key)
  noctalia.notifyError(tr("title"), tr("notifications." .. key))
end

local refreshHistory

local function finishRefresh()
  refreshInFlight = false
  if refreshQueued then
    refreshQueued = false
    refreshHistory()
  end
end

refreshHistory = function()
  if refreshInFlight then
    refreshQueued = true
    return
  end
  if not noctalia.commandExists("cliphist") then
    snapshotDirty = true
    publishSnapshot("error", "cliphist_unavailable")
    return
  end
  local environment = cliphistEnvironment()
  if environment == nil then
    snapshotDirty = true
    publishSnapshot("error", "data_dir_unavailable")
    return
  end

  local limit = historyLimit()
  -- One extra valid row lets the parser detect truncation while stdout remains
  -- bounded by (history_limit + 1) previews.
  local command = environment .. " cliphist list | head -n " .. tostring(limit + 1)
  refreshInFlight = true
  -- Keep an already rendered snapshot visible while refreshing. Publishing an
  -- otherwise identical loading snapshot rebuilds the full panel for a status
  -- label that usually lasts only a few milliseconds.
  if #snapshotItems == 0 then publishSnapshot("loading", "") end
  local started = noctalia.runAsync(command, function(result)
    local stderr = result ~= nil and tostring(result.stderr or "") or ""
    if result == nil or result.timedOut == true or result.exitCode ~= 0
      or stderr:match("%S") ~= nil then
      snapshotDirty = true
      publishSnapshot("error", result ~= nil and result.timedOut == true
        and "refresh_timeout" or "refresh_failed")
      finishRefresh()
      return
    end
    local items, ids = parseList(result.stdout or "", limit)
    snapshotDirty = false
    prepareThumbnails(items, ids)
    publishSnapshot("ready", "", items, ids)
    startNextThumbnail()
    finishRefresh()
  end, REFRESH_TIMEOUT_MS)
  if not started then
    refreshInFlight = false
    snapshotDirty = true
    publishSnapshot("error", "refresh_start_failed")
  end
end

local function validRequestId(value)
  if type(value) == "number" then value = tostring(value) end
  if type(value) ~= "string" or value == "" or #value > REQUEST_ID_MAX_BYTES
    or value:find("%c") ~= nil then
    return nil
  end
  return value
end

local function validCliphistId(value)
  if type(value) == "number" and value >= 0 and value % 1 == 0 then value = tostring(value) end
  if type(value) ~= "string" or value == "" or #value > ID_MAX_BYTES
    or value:match("^%d+$") == nil then
    return nil
  end
  return value
end

local function runAction(requestId, operation, id, command, onSuccess)
  actionBusy = true
  local started = noctalia.runAsync(command, function(result)
    actionBusy = false
    if result == nil or result.timedOut == true or result.exitCode ~= 0 then
      local errorCode = result ~= nil and result.timedOut == true
        and (operation .. "_timeout") or (operation .. "_failed")
      publishResult(requestId, operation, false, errorCode, { id = id })
      notifyError(errorCode)
      return
    end
    if onSuccess ~= nil then onSuccess() end
  end, ACTION_TIMEOUT_MS)
  if not started then
    actionBusy = false
    local errorCode = operation .. "_start_failed"
    publishResult(requestId, operation, false, errorCode, { id = id })
    notifyError(errorCode)
  end
end

local function schedulePaste(requestId, id)
  if pendingPaste ~= nil then return false, "paste_busy" end
  if not noctalia.commandExists("wtype") then
    notifyError("wtype_unavailable")
    return false, "wtype_unavailable"
  end
  local focusCommand = pasteFocusCommand()
  if focusCommand == nil then
    notifyError("focus_target_unavailable")
    return false, "focus_target_unavailable"
  end
  pendingPaste = {
    request_id = requestId,
    id = id,
    focus_command = focusCommand,
    deadline = os.clock() + pasteDelayMs() / 1000,
  }
  noctalia.setUpdateInterval(50)
  return true, ""
end

local function handleActivate(requestId, id, paste)
  if paste and pendingPaste ~= nil then
    publishResult(requestId, "activate", false, "paste_busy", { id = id })
    return
  end
  local command = cliphistEnvironment() .. " cliphist decode " .. shellQuote(id) .. " | wl-copy"
  runAction(requestId, "activate", id, command, function()
    local pasteScheduled = false
    local pasteError = ""
    if paste then
      pasteScheduled, pasteError = schedulePaste(requestId, id)
    end
    publishResult(requestId, "activate", true, "", {
      id = id,
      paste_requested = paste,
      paste_scheduled = pasteScheduled,
      paste_error = pasteError,
    })
    snapshotDirty = true
    if panelOpen then refreshHistory() end
  end)
end

local function findById(items, id)
  for index, item in ipairs(items) do
    if item.id == id then return item, index end
  end
  return nil, nil
end

local function handlePin(requestId, id)
  local source = nil
  for _, item in ipairs(snapshotItems) do
    if item.id == id then source = item break end
  end
  if source == nil then
    publishResult(requestId, "pin", false, "item_not_found", { id = id })
    return
  end
  local maximum = boundedInteger(cfg("max_pinned"), 20, 1, 100)
  if #pinnedItems >= maximum then
    publishResult(requestId, "pin", false, "max_pinned", { id = id })
    notifyError("max_pinned")
    return
  end
  if dataDir == nil then
    publishResult(requestId, "pin", false, "data_dir_unavailable", { id = id })
    notifyError("data_dir_unavailable")
    return
  end

  local pinnedId = nextPersistentId("pin")
  local path = pinPath(pinnedId)
  local command = cliphistEnvironment() .. " cliphist decode " .. shellQuote(id) .. " > " .. shellQuote(path)
  runAction(requestId, "pin", id, command, function()
    local info = noctalia.fileInfo(path)
    local maximumSize = source.is_image == true and MAX_PIN_IMAGE_BYTES or MAX_PIN_TEXT_BYTES
    if type(info) ~= "table" or tonumber(info.size) == nil or info.size <= 0 or info.size > maximumSize then
      noctalia.removeFile(path)
      publishResult(requestId, "pin", false, "pin_too_large", { id = id })
      notifyError("pin_too_large")
      return
    end
    local pinned = {
      id = pinnedId,
      preview = boundedString(source.preview, PREVIEW_WIDTH * 4),
      kind = source.kind,
      mime = SAFE_MIMES[source.mime] == true and source.mime or "text/plain",
      is_image = source.is_image == true,
      image_path = source.is_image == true and path or "",
      pinned_at = os.time(),
    }
    pinnedItems[#pinnedItems + 1] = pinned
    if not savePinned() then
      table.remove(pinnedItems, #pinnedItems)
      noctalia.removeFile(path)
      publishResult(requestId, "pin", false, "pin_save_failed", { id = id })
      notifyError("pin_save_failed")
      return
    end
    publishSnapshot("ready", "")
    publishResult(requestId, "pin", true, "", { id = id, pinned_id = pinnedId })
    noctalia.notify(tr("title"), tr("notifications.pinned"))
  end)
end

local function handleUnpin(requestId, id)
  local _, index = findById(pinnedItems, id)
  if index == nil then
    publishResult(requestId, "unpin", false, "item_not_found", { id = id })
    return
  end
  local removed = table.remove(pinnedItems, index)
  if not savePinned() then
    table.insert(pinnedItems, index, removed)
    publishResult(requestId, "unpin", false, "pin_save_failed", { id = id })
    notifyError("pin_save_failed")
    return
  end
  local path = pinPath(id)
  if path ~= nil then noctalia.removeFile(path) end
  publishSnapshot("ready", "")
  publishResult(requestId, "unpin", true, "", { id = id })
  noctalia.notify(tr("title"), tr("notifications.unpinned"))
end

local function handleCopyPinned(requestId, id, paste)
  local item = findById(pinnedItems, id)
  local path = pinPath(id)
  if item == nil or path == nil or not noctalia.fileExists(path) then
    publishResult(requestId, "copy_pinned", false, "item_not_found", { id = id })
    return
  end
  if paste and pendingPaste ~= nil then
    publishResult(requestId, "copy_pinned", false, "paste_busy", { id = id })
    return
  end
  local mime = SAFE_MIMES[item.mime] == true and item.mime or "text/plain"
  local command = "wl-copy --type " .. shellQuote(mime) .. " < " .. shellQuote(path)
  runAction(requestId, "copy_pinned", id, command, function()
    local pasteScheduled = false
    local pasteError = ""
    if paste then pasteScheduled, pasteError = schedulePaste(requestId, id) end
    publishResult(requestId, "copy_pinned", true, "", {
      id = id,
      paste_requested = paste,
      paste_scheduled = pasteScheduled,
      paste_error = pasteError,
    })
  end)
end

local function handleCreateNote(requestId, initialContent)
  if dataDir == nil then
    publishResult(requestId, "create_note", false, "data_dir_unavailable")
    notifyError("data_dir_unavailable")
    return
  end
  if #notes >= MAX_NOTES then
    publishResult(requestId, "create_note", false, "max_notes")
    notifyError("max_notes")
    return
  end
  local id = nextPersistentId("note")
  local now = os.time()
  local note = {
    id = id,
    title = "",
    content = boundedString(initialContent, MAX_NOTE_CONTENT_BYTES),
    color = opaqueNoteColor(validColor(cfg("notes_color"), "#FFD54F")),
    x = 24 + (#notes * 36),
    y = 24 + (#notes * 28),
    z = #notes + 1,
    created_at = now,
    updated_at = now,
  }
  notes[#notes + 1] = note
  if not saveNotes() then
    table.remove(notes, #notes)
    publishResult(requestId, "create_note", false, "note_save_failed")
    notifyError("note_save_failed")
    return
  end
  publishSnapshot("ready", "")
  publishResult(requestId, "create_note", true, "", { id = id })
end

local function handleAppendToNote(requestId, id, content)
  local note = findById(notes, id)
  if note == nil then
    publishResult(requestId, "append_note", false, "note_not_found", { id = id })
    return
  end

  local addition = boundedString(content, MAX_NOTE_CONTENT_BYTES)
  local separator = note.content ~= "" and "\n\n" or ""
  local available = MAX_NOTE_CONTENT_BYTES - #note.content
  if #separator >= available then separator = "" end
  addition = boundedString(addition, math.max(0, available - #separator))
  if addition == "" then
    publishResult(requestId, "append_note", false, "note_content_full", { id = id })
    notifyError("note_content_full")
    return
  end

  local oldContent, oldUpdated = note.content, note.updated_at
  note.content = note.content .. separator .. addition
  note.updated_at = os.time()
  if not saveNotes() then
    note.content, note.updated_at = oldContent, oldUpdated
    publishResult(requestId, "append_note", false, "note_save_failed", { id = id })
    notifyError("note_save_failed")
    return
  end
  publishSnapshot("ready", "")
  publishResult(requestId, "append_note", true, "", { id = id })
end

local function openSelectionMenu(content, generation)
  local items = {
    {
      id = "new",
      label = tr("selection.create_new"),
      enabled = #notes < MAX_NOTES,
    },
  }
  for _, note in ipairs(notes) do
    local title = note.title ~= "" and note.title or tr("panel.notes.untitled")
    items[#items + 1] = {
      id = "note:" .. note.id,
      label = tr("selection.add_to", { title = title }),
    }
  end

  pendingSelection = {
    content = content,
    generation = generation,
    expires_at = os.clock() + SELECTION_MENU_TTL_SECONDS,
  }
  local opened = type(service) == "table" and type(service.openContextMenu) == "function"
    and service.openContextMenu({
      items = items,
      maxVisible = 12,
      onActivate = "onSelectionContextAction",
      context = generation,
    }) == true
  if not opened then
    pendingSelection = nil
    notifyError("selection_menu_unavailable")
  end
end

local function requestSelectionMenu()
  selectionMenuGeneration = selectionMenuGeneration + 1
  local generation = selectionMenuGeneration
  pendingSelection = nil
  if not noctalia.commandExists("wl-paste") then
    notifyError("wl_paste_unavailable")
    return
  end

  local started = noctalia.runAsync("wl-paste --primary --no-newline --type text", function(result)
    if generation ~= selectionMenuGeneration then return end
    local content = result ~= nil and result.timedOut ~= true and result.exitCode == 0
      and boundedString(result.stdout, MAX_NOTE_CONTENT_BYTES) or ""
    if content == "" or content:find("%S") == nil then
      notifyError("selection_unavailable")
      return
    end
    openSelectionMenu(content, generation)
  end, ACTION_TIMEOUT_MS)
  if not started then notifyError("selection_unavailable") end
end

function onSelectionContextAction(actionId, generation)
  local selection = pendingSelection
  if selection == nil or tonumber(generation) ~= selection.generation
    or os.clock() >= selection.expires_at then
    return
  end
  pendingSelection = nil

  local requestId = ipcRequestId()
  if actionId == "new" then
    handleCreateNote(requestId, selection.content)
    return
  end
  local noteId = type(actionId) == "string" and actionId:match("^note:(.+)$") or nil
  if noteId ~= nil and validPersistentId(noteId, "note") then
    handleAppendToNote(requestId, noteId, selection.content)
  end
end

local function handleMoveNote(requestId, id, raw)
  local note = findById(notes, id)
  if note == nil then
    publishResult(requestId, "move_note", false, "note_not_found", { id = id })
    return
  end
  local oldX, oldY, oldZ = note.x, note.y, note.z
  local highestZ = 0
  for _, candidate in ipairs(notes) do highestZ = math.max(highestZ, tonumber(candidate.z) or 0) end
  note.x = noteCoordinate(raw.x, oldX or 0)
  note.y = noteCoordinate(raw.y, oldY or 0)
  note.z = math.min(MAX_NOTE_COORDINATE, highestZ + 1)
  if not saveNotes() then
    note.x, note.y, note.z = oldX, oldY, oldZ
    publishResult(requestId, "move_note", false, "note_save_failed", { id = id })
    notifyError("note_save_failed")
    return
  end
  publishSnapshot("ready", "")
  publishResult(requestId, "move_note", true, "", { id = id, x = note.x, y = note.y, z = note.z })
end

local function handleUpdateNote(requestId, id, raw)
  local note = findById(notes, id)
  if note == nil then
    publishResult(requestId, "update_note", false, "note_not_found", { id = id })
    return
  end
  local oldTitle, oldContent, oldUpdated = note.title, note.content, note.updated_at
  note.title = boundedString(raw.title, MAX_NOTE_TITLE_BYTES)
  note.content = boundedString(raw.content, MAX_NOTE_CONTENT_BYTES)
  note.updated_at = os.time()
  if not saveNotes() then
    note.title, note.content, note.updated_at = oldTitle, oldContent, oldUpdated
    publishResult(requestId, "update_note", false, "note_save_failed", { id = id })
    notifyError("note_save_failed")
    return
  end
  publishSnapshot("ready", "")
  publishResult(requestId, "update_note", true, "", { id = id })
end

local function handleDeleteNote(requestId, id)
  local _, index = findById(notes, id)
  if index == nil then
    publishResult(requestId, "delete_note", false, "note_not_found", { id = id })
    return
  end
  local removed = table.remove(notes, index)
  if not saveNotes() then
    table.insert(notes, index, removed)
    publishResult(requestId, "delete_note", false, "note_save_failed", { id = id })
    notifyError("note_save_failed")
    return
  end
  publishSnapshot("ready", "")
  publishResult(requestId, "delete_note", true, "", { id = id })
end

local function handleReorderNote(requestId, id, targetIndex)
  local note, sourceIndex = findById(notes, id)
  targetIndex = tonumber(targetIndex)
  if note == nil or targetIndex == nil then
    publishResult(requestId, "reorder_note", false, "note_not_found", { id = id })
    return
  end
  targetIndex = math.max(1, math.min(#notes, math.floor(targetIndex)))
  if sourceIndex ~= targetIndex then
    table.remove(notes, sourceIndex)
    table.insert(notes, targetIndex, note)
    if not saveNotes() then
      table.remove(notes, targetIndex)
      table.insert(notes, sourceIndex, note)
      publishResult(requestId, "reorder_note", false, "note_save_failed", { id = id })
      notifyError("note_save_failed")
      return
    end
  end
  publishSnapshot("ready", "")
  publishResult(requestId, "reorder_note", true, "", { id = id })
end

local function handleCycleNoteColor(requestId, id)
  local note = findById(notes, id)
  if note == nil then
    publishResult(requestId, "cycle_note_color", false, "note_not_found", { id = id })
    return
  end
  local current = 0
  for index, color in ipairs(NOTE_COLORS) do
    if note.color == color then current = index break end
  end
  local oldColor = note.color
  note.color = NOTE_COLORS[(current % #NOTE_COLORS) + 1]
  note.updated_at = os.time()
  if not saveNotes() then
    note.color = oldColor
    publishResult(requestId, "cycle_note_color", false, "note_save_failed", { id = id })
    notifyError("note_save_failed")
    return
  end
  publishSnapshot("ready", "")
  publishResult(requestId, "cycle_note_color", true, "", { id = id })
end

local function handleExportNote(requestId, id)
  local note = findById(notes, id)
  if note == nil then
    publishResult(requestId, "export_note", false, "note_not_found", { id = id })
    return
  end
  if type(exportDir) ~= "string" or exportDir == "" or noctalia.mkdirAll(exportDir) ~= true then
    publishResult(requestId, "export_note", false, "note_export_failed", { id = id })
    notifyError("note_export_failed")
    return
  end
  local fileName = "notecard-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. id .. ".txt"
  local path = exportDir .. "/" .. fileName
  if noctalia.writeFile(path, note.content) ~= true then
    publishResult(requestId, "export_note", false, "note_export_failed", { id = id })
    notifyError("note_export_failed")
    return
  end
  publishResult(requestId, "export_note", true, "", { id = id, path = path })
  noctalia.notify(tr("title"), tr("notifications.note_exported", { path = path }))
end

local function handleDelete(requestId, id)
  if snapshotIds[id] ~= true then
    publishResult(requestId, "delete", false, "item_not_found", { id = id })
    return
  end
  -- cliphist delete extracts only the numeric prefix from each stdin line; do
  -- not interpolate or pipe the user's preview/content back through the shell.
  local command = "printf '%s\\n' " .. shellQuote(id) .. " | " .. cliphistEnvironment() .. " cliphist delete"
  runAction(requestId, "delete", id, command, function()
    publishResult(requestId, "delete", true, "", { id = id })
    noctalia.notify(tr("title"), tr("notifications.deleted"))
    snapshotDirty = true
    refreshHistory()
  end)
end

local function handleWipe(requestId)
  runAction(requestId, "wipe", nil, cliphistEnvironment() .. " cliphist wipe", function()
    snapshotDirty = false
    snapshotItems = {}
    snapshotIds = {}
    publishSnapshot("ready", "", snapshotItems, snapshotIds)
    publishResult(requestId, "wipe", true, "")
    noctalia.notify(tr("title"), tr("notifications.wiped"))
  end)
end

local function handleRequest(raw)
  if type(raw) ~= "table" then return end
  local requestId = validRequestId(raw.request_id)
  local operation = type(raw.operation) == "string" and raw.operation or ""
  if requestId == nil then
    publishResult("", operation, false, "invalid_request_id")
    return
  end
  if requestId == lastHandledRequestId then return end
  lastHandledRequestId = requestId

  if operation == "refresh" then
    refreshHistory()
    publishResult(requestId, operation, true, "")
    return
  end
  local supported = {
    activate = true, delete = true, wipe = true, pin = true,
    unpin = true, copy_pinned = true,
    create_note = true, update_note = true, delete_note = true,
    reorder_note = true, move_note = true, cycle_note_color = true, export_note = true,
  }
  if supported[operation] ~= true then
    publishResult(requestId, operation, false, "invalid_operation")
    return
  end
  if operation == "wipe" and databaseMode() == DATABASE_MODE_GLOBAL then
    publishResult(requestId, operation, false, "global_wipe_disabled")
    notifyError("global_wipe_disabled")
    return
  end
  if actionBusy then
    publishResult(requestId, operation, false, "busy")
    return
  end

  if operation == "create_note" then
    handleCreateNote(requestId)
    return
  end
  if operation == "update_note" or operation == "delete_note"
    or operation == "reorder_note" or operation == "move_note" or operation == "cycle_note_color"
    or operation == "export_note" then
    local id = type(raw.id) == "string" and raw.id or ""
    if not validPersistentId(id, "note") then
      publishResult(requestId, operation, false, "note_not_found", { id = id })
      return
    end
    if operation == "update_note" then
      handleUpdateNote(requestId, id, raw)
    elseif operation == "delete_note" then
      handleDeleteNote(requestId, id)
    elseif operation == "reorder_note" then
      handleReorderNote(requestId, id, raw.target_index)
    elseif operation == "move_note" then
      handleMoveNote(requestId, id, raw)
    elseif operation == "cycle_note_color" then
      handleCycleNoteColor(requestId, id)
    else
      handleExportNote(requestId, id)
    end
    return
  end

  if operation == "unpin" or operation == "copy_pinned" then
    local id = type(raw.id) == "string" and raw.id or ""
    if not validPersistentId(id, "pin") then
      publishResult(requestId, operation, false, "item_not_found", { id = id })
      return
    end
    if operation == "unpin" then
      handleUnpin(requestId, id)
    else
      if not noctalia.commandExists("wl-copy") then
        publishResult(requestId, operation, false, "wl_copy_unavailable", { id = id })
        notifyError("wl_copy_unavailable")
        return
      end
      local paste = raw.paste == true
      handleCopyPinned(requestId, id, paste)
    end
    return
  end

  if cliphistEnvironment() == nil then
    publishResult(requestId, operation, false, "data_dir_unavailable")
    notifyError("data_dir_unavailable")
    return
  end
  if not noctalia.commandExists("cliphist") then
    publishResult(requestId, operation, false, "cliphist_unavailable")
    notifyError("cliphist_unavailable")
    return
  end
  if operation == "wipe" then
    handleWipe(requestId)
    return
  end

  local id = validCliphistId(raw.id)
  if id == nil then
    publishResult(requestId, operation, false, "invalid_id")
    notifyError("invalid_id")
    return
  end
  if operation == "activate" then
    if not noctalia.commandExists("wl-copy") then
      publishResult(requestId, operation, false, "wl_copy_unavailable", { id = id })
      notifyError("wl_copy_unavailable")
      return
    end
    local paste = raw.paste == true
    handleActivate(requestId, id, paste)
  elseif operation == "pin" then
    handlePin(requestId, id)
  else
    handleDelete(requestId, id)
  end
end

ipcRequestId = function()
  ipcRequestSequence = ipcRequestSequence + 1
  return "ipc-" .. tostring(os.time()) .. "-" .. tostring(ipcRequestSequence)
end

local function trimmedPayload(payload)
  if type(payload) ~= "string" then return "" end
  return payload:match("^%s*(.-)%s*$") or ""
end

local function decodeIpcObject(payload)
  payload = trimmedPayload(payload)
  if payload == "" or #payload > IPC_PAYLOAD_MAX_BYTES then return nil end
  local ok, decoded = pcall(noctalia.json.decode, payload)
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

local function dispatchIpcRequest(operation, fields)
  fields = type(fields) == "table" and fields or {}
  fields.request_id = ipcRequestId()
  fields.operation = operation
  handleRequest(fields)
end

-- Service IPC is intentionally a thin adapter over handleRequest. This keeps
-- CLI/automation calls subject to the same allowlist, ID validation, size
-- limits, dependency checks and busy-state handling as requests from the UI.
function onIpc(event, payload)
  if event == "selection-menu" then
    requestSelectionMenu()
    return
  end
  local noPayloadOperations = {
    refresh = "refresh",
    clear = "wipe",
    ["create-note"] = "create_note",
  }
  local idOperations = {
    copy = { operation = "activate", paste = false },
    paste = { operation = "activate", paste = true },
    pin = { operation = "pin" },
    delete = { operation = "delete" },
    unpin = { operation = "unpin" },
    ["copy-pinned"] = { operation = "copy_pinned", paste = false },
    ["paste-pinned"] = { operation = "copy_pinned", paste = true },
    ["delete-note"] = { operation = "delete_note" },
    ["cycle-note-color"] = { operation = "cycle_note_color" },
    ["export-note"] = { operation = "export_note" },
  }
  local jsonOperations = {
    ["update-note"] = "update_note",
    ["move-note"] = "move_note",
    ["reorder-note"] = "reorder_note",
  }

  if event == "request" then
    local request = decodeIpcObject(payload)
    if request == nil then
      dispatchIpcRequest("", {})
      return
    end
    -- Never accept an externally supplied request ID: the service owns IPC
    -- correlation IDs and therefore cannot accidentally deduplicate calls.
    local operation = type(request.operation) == "string" and request.operation or ""
    dispatchIpcRequest(operation, request)
    return
  end

  local operation = noPayloadOperations[event]
  if operation ~= nil then
    dispatchIpcRequest(operation, {})
    return
  end

  local idOperation = idOperations[event]
  if idOperation ~= nil then
    dispatchIpcRequest(idOperation.operation, {
      id = trimmedPayload(payload),
      paste = idOperation.paste == true,
    })
    return
  end

  operation = jsonOperations[event]
  if operation ~= nil then
    local request = decodeIpcObject(payload)
    if request == nil then
      dispatchIpcRequest(operation, {})
      return
    end
    dispatchIpcRequest(operation, request)
    return
  end

  dispatchIpcRequest("", {})
end

local function onWatcherLine(line)
  -- The wrapper emits one fixed marker after cliphist successfully stores a
  -- clipboard change. Never interpret process output as clipboard content.
  if line ~= "__clipper_changed__" then return end
  snapshotDirty = true
  if panelOpen then refreshHistory() end
end

local function startWatchers()
  -- Global mode consumes the database managed by the desktop session. Starting
  -- another pair of storing watchers would race and duplicate that ownership.
  if databaseMode() == DATABASE_MODE_GLOBAL then return end
  if cfg("manage_watchers") ~= true then return end
  if not noctalia.commandExists("cliphist") or not noctalia.commandExists("wl-paste") then
    notifyError("watchers_unavailable")
    return
  end

  local environment = cliphistEnvironment()
  if environment == nil then
    notifyError("data_dir_unavailable")
    return
  end
  local worker = shellQuote(environment .. " cliphist store && printf '%s\\n' __clipper_changed__")
  -- One lifecycle-owned stream supervises both MIME watchers. The host kills
  -- its process group on plugin reload/disable, and the trap also reaps both
  -- children on normal termination.
  local command = "text_pid=; image_pid=; "
    .. "wl-paste --type text --watch sh -c " .. worker .. " & text_pid=$!; "
    .. "wl-paste --type image --watch sh -c " .. worker .. " & image_pid=$!; "
    .. "trap 'kill $text_pid $image_pid 2>/dev/null; wait $text_pid $image_pid 2>/dev/null' EXIT HUP INT TERM; "
    .. "wait $text_pid $image_pid"
  watchersRunning = noctalia.runStream(command, onWatcherLine) == true
  if not watchersRunning then notifyError("watchers_start_failed") end
end

noctalia.state.watch(PANEL_OPEN_KEY, function(value)
  panelOpen = value == true
  if panelOpen then
    capturePasteTarget()
    -- Global mode is populated externally, so every reopen verifies the latest
    -- database. Private mode can trust its watcher-maintained dirty flag.
    if snapshotDirty or databaseMode() == DATABASE_MODE_GLOBAL then refreshHistory() end
  end
end)

noctalia.state.watch(REQUEST_KEY, handleRequest)

function update()
  if #thumbnailCleanupQueue > 0 then
    noctalia.removeFile(table.remove(thumbnailCleanupQueue, 1))
  end
  if pendingSelection ~= nil and os.clock() >= pendingSelection.expires_at then
    pendingSelection = nil
  end
  if pendingPaste == nil or os.clock() < pendingPaste.deadline then return end
  local paste = pendingPaste
  pendingPaste = nil
  noctalia.setUpdateInterval(1000)
  local command = paste.focus_command .. " || exit 70; sleep 0.05; wtype -M ctrl -M shift v"
  local started = noctalia.runAsync(command, function(result)
    if result == nil or result.exitCode ~= 0 or result.timedOut == true then
      local errorCode = result ~= nil and result.exitCode == 70
        and "focus_restore_failed"
        or (result ~= nil and result.timedOut == true and "paste_timeout" or "paste_failed")
      notifyError(errorCode)
    end
  end, ACTION_TIMEOUT_MS)
  if not started then notifyError("paste_start_failed") end
end

initializeThumbnailCache()
loadPersistentData()
startWatchers()
local initialError = databaseMode() == DATABASE_MODE_PRIVATE and dataDir == nil
  and "data_dir_unavailable" or ""
publishSnapshot(snapshotStatus, initialError)
if panelOpen then
  capturePasteTarget()
  refreshHistory()
end
