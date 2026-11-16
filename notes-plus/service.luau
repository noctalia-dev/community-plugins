--!nonstrict
-- Sync service between the notes panel on the computer and the
-- phone.
--
-- The `faminec/notes` plugin takes care of the notes; this one is the bridge:
--
-- * Watches the `notes-mobile` server and publishes its state in
-- `noctalia.state` ("notes_sync") so the widget and the panel can paint it.
-- Queues messages for the phone (push) through the server API.
-- * Exposes a stable IPC contract, with a JSON payload, so other
-- tools (or the phone itself) can drive the notes panel.
--
-- Contrato IPC:
--
--   noctalia msg plugin faminec/notes-plus:service all refresh
--   noctalia msg plugin faminec/notes-plus:service all cmd '{"op":"status"}'
--   noctalia msg plugin faminec/notes-plus:service all cmd '{"op":"open-notes"}'
-- noctalia msg plugin faminec/notes-plus:service all cmd '{"op":"open-note","name":"my note.md"}'
--   noctalia msg plugin faminec/notes-plus:service all cmd '{"op":"send-current"}'
-- noctalia msg plugin faminec/notes-plus:service all cmd '{"op":"push","text":"hello"}'
--
-- The state the service publishes:
--
--   noctalia.state "notes_sync" = {
--     serverUp = bool, phoneConnected = bool, pending = number,
--     notes = number, lastSeen = number, url = string,
--     checkedAt = "HH:MM:SS", error = string,
--   }

local dirs = require("./dirs.luau")
local channel = require("./channel.luau")

local MAX_IN_FLIGHT = 4 -- the host accepts 8; some margin is left for other actions
-- If the server hangs (it accepts the connection but never answers),
-- requests stay in flight and the queue grows without limit. Old polls are
-- useless (the state is requested again) and, worse, they push the user's
-- actions (the ones that matter) to the back of the queue. So the
-- queue has a cap.
local MAX_QUEUE = 30
-- What can be dropped and what cannot. Every request declares its priority and
-- there is a single rule: when the queue is full, the most disposable thing is
-- dropped (a poll first, a check after). The user's message is NEVER
-- dropped: if the queue holds only messages, the new one is rejected (the
-- user is told) and the previous ones are kept for when the server
-- comes back.
local PRIO_SONDEO = 1 -- the state is requested again: losing it does not matter
local PRIO_COMPROBACION = 2 -- a check: it is done again
local PRIO_MENSAJE = 3 -- the user's message: never dropped

local inFlight = 0
local queue = {}
local fullStateTick = 0

local function tr(key, params)
  if params ~= nil then
    return noctalia.tr(key, params)
  end
  return noctalia.tr(key)
end

-- ------------------------------------------------------------------ settings

local function notesPluginId()
  -- The merged plugin is always notes-plus; the old
  -- `notes_plugin` key no longer exists and raised an undeclared setting warning.
  return "faminec/notes-plus"
end

local function notesPanelId()
  return notesPluginId() .. ":panel"
end

local function serverUrl()
  local url = noctalia.getConfig("server_url")
  if type(url) ~= "string" or url == "" then
    url = "http://127.0.0.1:8787"
  end
  -- No trailing slash: paths are concatenated as they are.
  return (url:gsub("/+$", ""))
end

-- The token can be left empty in the settings: if so, it is read from the
-- server's config.json (where it lives by default).
local function serverToken()
  local token = noctalia.getConfig("token")
  if type(token) == "string" and token ~= "" then
    return token
  end
  local path = noctalia.expandPath("~/notes-mobile/config.json")
  local raw = noctalia.readFile(path)
  if raw == nil then
    return ""
  end
  local ok, decoded = pcall(noctalia.json.decode, raw)
  if ok and type(decoded) == "table" and type(decoded.token) == "string" then
    return decoded.token
  end
  return ""
end

local function pollIntervalMs()
  local secs = tonumber(noctalia.getConfig("poll_interval"))
  if secs == nil or secs <= 0 then
    return 10000
  end
  return math.min(secs, 600) * 1000
end

-- --------------------------------------------------------------------- HTTP
--
-- The host accepts at most eight simultaneous requests per script: going over
-- that rejects the call without any warning. That is why everything is queued.

local function pump()
  while inFlight < MAX_IN_FLIGHT and #queue > 0 do
    local job = table.remove(queue, 1)
    inFlight += 1
    local started = noctalia.http(job.req, function(res)
      inFlight -= 1
      job.cb(res)
      pump()
    end)
    if not started then
      inFlight -= 1
      job.cb(nil)
    end
  end
end

local function request(path, method, body, cb, priority)
  local headers = {}
  local token = serverToken()
  if token ~= "" then
    table.insert(headers, "Authorization: Bearer " .. token)
  end
  if body ~= nil then
    table.insert(headers, "Content-Type: application/json")
  end
  -- Queue full: the most disposable thing is dropped and the caller is told, so
  -- it does not wait forever for a server that never answers.
  if #queue >= MAX_QUEUE then
    local dropped = nil
    for _, p in ipairs({ PRIO_SONDEO, PRIO_COMPROBACION }) do
      for i, job in ipairs(queue) do
        if job.priority == p then
          dropped = table.remove(queue, i)
          break
        end
      end
      if dropped ~= nil then
        break
      end
    end
    if dropped == nil then
      -- The queue holds only user messages: none is dropped. The new one is
      -- rejected (and the user is told) and the previous ones are
      -- kept for when the server comes back.
      cb(nil, tr("errors.queue_full"))
      return
    end
    dropped.cb(nil)
  end
  table.insert(queue, {
    req = {
      url = serverUrl() .. path,
      method = method or "GET",
      headers = headers,
      body = body,
    },
    cb = cb,
    priority = priority or PRIO_MENSAJE,
  })
  pump()
end

local function jsonRequest(path, method, payload, cb, priority)
  local encoded = nil
  if payload ~= nil then
    local ok, res = pcall(noctalia.json.encode, payload)
    if not ok or res == nil then
      cb(nil, "no se pudo codificar la peticion")
      return
    end
    encoded = res
  end
  request(path, method, encoded, function(res, forceError)
    if forceError ~= nil then
      cb(nil, forceError)
      return
    end
    if res == nil then
      cb(nil, "sin respuesta del servidor")
      return
    end
    -- `res.ok` means the request completed, NOT that it succeeded:
    -- a 404 or a 500 also arrive with `ok = true`. What tells a failure apart is
    -- the status code (checked with a probe against the
    -- server).
    if not res.ok then
      cb(nil, "sin respuesta del servidor")
      return
    end
    local status = tonumber(res.status) or 0
    if status >= 400 then
      cb(nil, "HTTP " .. tostring(status))
      return
    end
    if res.body == nil or res.body == "" then
      cb({}, nil)
      return
    end
    local ok, decoded = pcall(noctalia.json.decode, res.body)
    if not ok or type(decoded) ~= "table" then
      cb(nil, "respuesta ilegible")
      return
    end
    -- The server answers failures with {"error": "..."}: if that key shows up
    -- it is a failure even when the status code did not reveal it.
    if decoded.error ~= nil then
      cb(nil, tostring(decoded.error))
      return
    end
    cb(decoded, nil)
  end, priority)
end

-- ------------------------------------------------- open note (another plugin)
--
-- `noctalia.state` is isolated per plugin: the keys the editor publishes
-- are not visible from here. The channel between plugins is the `.current.json`
-- file the editor writes INSIDE the notes folder: that works even when the
-- editor and the bridge are different plugins (or different repos), because the
-- notes folder is already the meeting point between the computer and the
-- phone. Precedent: the official plugin keeps `.pinned.json` there.
--
-- The folder is resolved with the same module the editor uses (dirs.luau)
-- so the panel and the bridge point at the same place.

local function notesDir()
  return dirs.resolveNotesDir()
end

-- Returns {name, content, open} of the last note worked on in
-- the notes panel, or nil. `open` says whether that note is open right now.
local function readCurrentNote()
  local current = channel.read(notesDir())
  -- An empty channel (blank name) is the same as no note at all.
  if current == nil or current.name == "" then
    return nil
  end
  return current
end

-- ------------------------------------------------------------------ state

local snapshot = {
  serverUp = false,
  phoneConnected = false,
  pending = 0,
  notes = 0,
  lastSeen = 0,
  url = "",
  checkedAt = "",
  error = "",
  currentNote = "",
  currentOpen = false,
}

local function publish()
  snapshot.url = serverUrl()
  snapshot.checkedAt = noctalia.formatTime("%H:%M:%S")
  local current = readCurrentNote()
  snapshot.currentNote = current and current.name or ""
  snapshot.currentOpen = current and current.open or false
  noctalia.state.set("notes_sync", snapshot)
end

-- The server writes ~/notes-mobile/state.json: when it is there, it is read as
-- a fallback while the server does not answer.
local function readStateFile()
  local path = noctalia.expandPath("~/notes-mobile/state.json")
  local raw = noctalia.readFile(path)
  if raw == nil then
    return nil
  end
  local ok, decoded = pcall(noctalia.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function applyHealth(data)
  snapshot.serverUp = true
  snapshot.error = ""
  snapshot.version = data.version or 0
  local phone = data.phone or {}
  snapshot.phoneConnected = phone.connected == true
  snapshot.lastSeen = tonumber(phone.lastSeen) or 0
  snapshot.pending = tonumber(data.pendingPush) or 0
  snapshot.notes = tonumber(data.notes) or snapshot.notes
end

local function applyStateFile(data)
  if type(data) ~= "table" then
    return
  end
  snapshot.version = tonumber(data.version) or snapshot.version
  local phone = data.phone or {}
  snapshot.phoneConnected = phone.connected == true
  snapshot.lastSeen = tonumber(phone.lastSeen) or snapshot.lastSeen
  local push = data.push
  if type(push) == "table" then
    snapshot.pending = #push
  end
end

local function refresh()
  jsonRequest("/api/health", "GET", nil, function(data, err)
    if data ~= nil then
      applyHealth(data)
    else
      snapshot.serverUp = false
      snapshot.error = err or "sin respuesta"
      local fromFile = readStateFile()
      if fromFile ~= nil then
        applyStateFile(fromFile)
      end
    end
    publish()
  end, PRIO_SONDEO)
end

-- The server state is also read to know how many notes there are.
local function refreshState()
  jsonRequest("/api/state", "GET", nil, function(data, err)
    if data ~= nil then
      snapshot.serverUp = true
      snapshot.error = ""
      snapshot.notes = #(data.notes or {})
      if data.phone ~= nil then
        snapshot.phoneConnected = data.phone.connected == true
        snapshot.lastSeen = tonumber(data.phone.lastSeen) or snapshot.lastSeen
      end
      if tonumber(data.version) ~= nil then
        snapshot.version = data.version
      end
    else
      snapshot.serverUp = false
      snapshot.error = err or "sin respuesta"
      local fromFile = readStateFile()
      if fromFile ~= nil then
        applyStateFile(fromFile)
      end
    end
    publish()
  end, PRIO_SONDEO)
end

-- ---------------------------------------------------------------- acciones

local function notifyOk(text)
  noctalia.notify(tr("title"), text)
end

local function notifyErr(text)
  noctalia.notifyError(tr("title"), text or "")
end

-- --------------------------------------------------- Noctalia commands
--
-- Note names come from the phone: they have to be quoted properly for the
-- shell. Single quotes, and single quotes inside are closed and
-- reopened ('\'').
local function shellQuote(text)
  local s = tostring(text)
  s = s:gsub("'", "'\\''")
  return "'" .. s .. "'"
end

-- Opens the notes panel of the `faminec/notes` plugin. `panel-open` is used (not
-- `toggle`) so an already open panel does not close.
local function openNotesPanel(noteName)
  if type(noteName) == "string" and noteName ~= "" then
    -- First the note is recorded in the open panel and in the service (which keeps
    -- it for when the panel opens), and then the panel is opened.
    noctalia.runAsync(
      "noctalia msg plugin "
        .. shellQuote(notesPanelId())
        .. " all open-note "
        .. shellQuote(noteName)
    )
    noctalia.runAsync(
      "noctalia msg plugin "
        .. shellQuote(notesPluginId() .. ":service")
        .. " all open-note "
        .. shellQuote(noteName)
    )
  end
  noctalia.runAsync("noctalia msg panel-open " .. shellQuote(notesPanelId()))
end

-- Encodes a text for a URL (note names can carry
-- spaces, accents or quotes).
local function urlEncode(text)
  local s = tostring(text)
  s = s:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return s
end

-- Does the note still exist? The server is asked (it is the one that sees the
-- disk). The second value is the error when it could not be known.
local function noteExists(name, cb)
  jsonRequest("/api/note/" .. urlEncode(name), "GET", nil, function(data, err)
    if data ~= nil then
      cb(true, nil)
      return
    end
    -- "HTTP 404" means it does not exist; anything else means it could not be
    -- asked (and that is not the same).
    if err ~= nil and err:match("^HTTP ") then
      cb(false, nil)
      return
    end
    cb(false, err or tr("errors.cannot_read"))
  end, PRIO_COMPROBACION)
end

-- Queues a message for the phone.
local function pushToPhone(text, title, cb)
  if type(text) ~= "string" or text == "" then
    notifyErr(tr("errors.empty"))
    if cb then cb(false) end
    return
  end
  jsonRequest("/api/push", "POST", { text = text, title = title or tr("push_title") }, function(data, err)
    if data == nil then
      notifyErr(err or tr("errors.push_failed"))
      if cb then cb(false) end
      return
    end
    snapshot.pending = tonumber(data.pending) or snapshot.pending
    publish()
    notifyOk(tr("push_sent"))
    if cb then cb(true) end
  end, PRIO_MENSAJE)
end

-- Sends the note open in the notes panel to the phone.
local function sendCurrentNote()
  local current = readCurrentNote()
  if current == nil then
    notifyErr(tr("errors.no_note_open"))
    return
  end
  if current.content == "" then
    notifyErr(tr("errors.cannot_read"))
    return
  end
  -- Before sending it, the note is checked to still exist: if it
  -- was deleted from the phone while the notes panel was closed, the channel
  -- keeps publishing its name (the panel does not watch while closed) and a
  -- note that is gone would be sent.
  noteExists(current.name, function(exists, err)
    if err ~= nil then
      notifyErr(err)
      return
    end
    if not exists then
      notifyErr(tr("errors.note_gone"))
      return
    end
    pushToPhone(current.content, current.name)
  end)
end

-- ------------------------------------------------------------------- IPC

local function handleCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "status" then
    refreshState()
  elseif op == "open-notes" then
    openNotesPanel(nil)
  elseif op == "open-note" then
    local name = cmd.name
    if type(name) ~= "string" or name == "" then
      notifyErr(tr("errors.bad_name"))
      return
    end
    openNotesPanel(name)
  elseif op == "send-current" then
    sendCurrentNote()
  elseif op == "push" then
    pushToPhone(cmd.text, cmd.title)
  elseif op == "refresh" then
    refreshState()
  else
    noctalia.log("[notes-sync] op desconocida: " .. tostring(op))
  end
end

function onIpc(event, payload)
  -- Notes: refresh the panel / open a note (compatibility with the old IPC).
  if event == "refresh" then
    refreshState()
    -- Bump notes_bump so the panel folds external changes in.
    local bump = noctalia.state.get("notes_bump")
    noctalia.state.set("notes_bump", (type(bump) == "number" and bump or 0) + 1)
    return
  end
  if event == "open-note" then
    if type(payload) == "string" and payload ~= "" then
      noctalia.state.set("open_note", payload)
      noctalia.state.set("open_home", false)
    end
    return
  end
  if event == "open-home" then
    noctalia.state.set("open_note", "")
    noctalia.state.set("open_home", true)
    return
  end
  if event == "cmd" and payload ~= nil then
    local ok, cmd = pcall(noctalia.json.decode, payload)
    if ok and type(cmd) == "table" then
      handleCommand(cmd)
    else
      noctalia.log("[notes-sync] payload IPC invalido")
    end
  end
end

-- ------------------------------------------------------------------ ciclo

-- How often the full state is requested (not the summary): the state carries
-- the note list, so it is not requested on every tick. The summary (health) is
-- light and is always requested.
local fullStateEvery = 6

function update()
  refresh()
  fullStateTick = (fullStateTick or 0) + 1
  if fullStateTick >= fullStateEvery then
    fullStateTick = 0
    refreshState()
  end
end

function onConfigChanged()
  refresh()
end

noctalia.setUpdateInterval(pollIntervalMs())
refreshState()
