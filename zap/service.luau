--!nonstrict
-- Owns the noctalia-zapd process. Reads its JSON events (one per line) and
-- publishes the result to noctalia.state for the bar widget and the panel.
-- Message text is never logged.

local common = require("./lib/common.luau")

local MAX_CHATS = 300 -- chats published to the panel, not counting archived ones
local MAX_ARCHIVED = 100
local MAX_RECENT = 40 -- live messages kept in shared state for the panel
local WATCHDOG_MS = 10000
local RESTART_GRACE_MS = 15000
local NOTIFY_GAP_MS = 3000 -- at most one notification per chat in this window

local dataDir, dataError = noctalia.pluginDataDir()
local binary = nil
local lastStart = 0
local failures = 0
local restartPending = false
local pendingChats = nil -- chat pages being assembled
local runningConfig = nil -- configKey() the daemon was started with
local chatNames = {} -- jid -> name, from the last chat list
local archivedChats = {} -- jid -> true
local recent = {} -- last live messages, each with a sequence number
local seq = 0
-- Changes on every load, so the panel can tell that seq started over.
local epoch = noctalia.nowMs()
local lastNotify = {} -- jid -> nowMs of the last notification

local function shellQuote(value: string): string
  return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

local function setStatus(state: string, detail: string?)
  noctalia.state.set(common.KEY_STATUS, { state = state, detail = detail or "" })
  if state ~= "qr" then
    noctalia.state.set(common.KEY_QR, nil)
  end
end

-- The binary comes from the setting, then PATH, then ~/.local/bin.
local function resolveBinary(): string?
  local configured = noctalia.getConfig("daemon_path")
  if type(configured) == "string" and configured ~= "" then
    local path = noctalia.expandPath(configured)
    if noctalia.fileExists(path) then
      return path
    end
    return nil
  end
  if noctalia.commandExists("noctalia-zapd") then
    return "noctalia-zapd"
  end
  local fallback = noctalia.expandPath("~/.local/bin/noctalia-zapd")
  if noctalia.fileExists(fallback) then
    return fallback
  end
  return nil
end

local function onChats(items)
  if type(items) ~= "table" then
    return
  end
  local chats = {}
  local unread = 0
  local kept, keptArchived = 0, 0
  for _, c in items do
    if type(c) == "table" and type(c.jid) == "string" then
      local n = tonumber(c.unread) or 0
      local archived = c.archived == true
      -- Archived chats stay out of the bar count, like WhatsApp with
      -- "Keep chats archived". Every other chat counts, even past the cut.
      if not archived then
        unread += n
      end
      if archived then
        keptArchived += 1
        if keptArchived > MAX_ARCHIVED then
          continue
        end
      else
        kept += 1
        if kept > MAX_CHATS then
          continue
        end
      end
      table.insert(chats, {
        archived = archived,
        pinned = c.pinned == true,
        avatar = if type(c.avatar) == "string" then c.avatar else nil,
        jid = c.jid,
        name = if type(c.name) == "string" and c.name ~= "" then c.name else noctalia.tr("panel.chat.unknown"),
        unread = n,
        last = c.last or "",
        lastKind = c.last_kind or "",
        ts = tonumber(c.ts) or 0,
      })
    end
  end
  local names, archivedSet = {}, {}
  for _, c in items do
    if type(c) == "table" and type(c.jid) == "string" then
      names[c.jid] = c.name or ""
      if c.archived == true then
        archivedSet[c.jid] = true
      end
    end
  end
  chatNames = names
  archivedChats = archivedSet
  noctalia.state.set(common.KEY_CHATS, chats)
  noctalia.state.set(common.KEY_UNREAD, unread)
end

local function notify(m)
  if noctalia.getConfig("notifications") == false then
    return
  end
  if m.me or m.backlog or m.muted or archivedChats[m.chat] then
    return
  end
  if noctalia.state.get(common.KEY_ACTIVE_CHAT) == m.chat then
    return -- the user is looking at this chat
  end
  local now = noctalia.nowMs()
  if lastNotify[m.chat] and now - lastNotify[m.chat] < NOTIFY_GAP_MS then
    return
  end
  lastNotify[m.chat] = now

  local chatName = chatNames[m.chat]
  if chatName == nil or chatName == "" then
    chatName = m.name or ""
  end
  local title = chatName
  if common.isGroup(m.chat) and m.name and m.name ~= "" then
    title = noctalia.tr("notify.group_title", { sender = m.name, chat = chatName })
  end
  local body
  if noctalia.getConfig("notify_private") == true then
    body = noctalia.tr("notify.hidden")
  else
    body = common.preview(m.text, m.kind)
  end
  noctalia.notify(title, body, {
    actions = { { id = "reply", label = noctalia.tr("notify.reply") } },
    onAction = "onNotifyAction",
    context = m.chat,
  })
end

local function pushRecent(item)
  seq += 1
  item.seq = seq
  table.insert(recent, item)
  while #recent > MAX_RECENT do
    table.remove(recent, 1)
  end
  noctalia.state.set(common.KEY_MESSAGES, { epoch = epoch, seq = seq, items = recent })
end

local function onMessage(event)
  if type(event.chat) ~= "string" then
    return
  end
  if event.backlog == true then
    -- Offline sync can bring hundreds at once. They are not published one by
    -- one: the panel reloads the open chat when the chat list shows it changed.
    return
  end
  local m = common.normalizeMessage(event)
  m.backlog = false
  m.muted = event.muted == true
  pushRecent(m)
  notify(m)
end

-- Notification button or body click: open the panel on that chat.
function onNotifyAction(_id, context)
  if type(context) ~= "string" or context == "" then
    return
  end
  noctalia.state.set(common.KEY_OPEN_CHAT, { jid = context, at = noctalia.nowMs() })
  if noctalia.state.get(common.KEY_PANEL_OPEN) ~= true then
    noctalia.togglePanel(common.panelId())
  end
end

local function onLine(line: string)
  local event = noctalia.json.decode(line)
  if type(event) ~= "table" then
    noctalia.log(`zap: dropped an undecodable event ({#line} bytes)`)
    return
  end
  if event.type == "status" then
    setStatus(event.state or "error", event.detail)
    if event.state == "error" and event.detail == "socket" then
      -- A daemon from an earlier load still owns the socket: stop it and start again.
      noctalia.runAsync({ binary, "ctl", "quit" }, function(_r)
        restartPending = true
      end)
    end
  elseif event.type == "qr" then
    noctalia.state.set(common.KEY_QR, event.png)
  elseif event.type == "chats" then
    -- The list arrives in pages (long lines get split by the host). Publish it
    -- once the last page is in.
    local page = tonumber(event.page) or 0
    local pages = tonumber(event.pages) or 1
    if page == 0 then
      pendingChats = {}
    end
    if pendingChats ~= nil and type(event.items) == "table" then
      for _, c in event.items do
        table.insert(pendingChats, c)
      end
    end
    if page >= pages - 1 and pendingChats ~= nil then
      onChats(pendingChats)
      pendingChats = nil
    end
  elseif event.type == "message" then
    onMessage(event)
  elseif event.type == "update" then
    -- A stored message changed (reaction, edit, deleted): the panel replaces it.
    local m = common.normalizeMessage(event.message)
    if m and m.chat ~= "" then
      m.update = true
      m.truncated = m.truncated or event.truncated == true
      pushRecent(m)
    end
  elseif event.type == "receipt" then
    if type(event.chat) == "string" and type(event.ids) == "table" then
      pushRecent({ receipt = true, chat = event.chat, ids = event.ids, ack = event.ack or "" })
    end
  elseif event.type == "typing" then
    noctalia.state.set(common.KEY_TYPING, {
      chat = event.chat or "",
      from = event.from or "",
      name = event.name or "",
      state = event.state or "paused",
      at = noctalia.nowMs(),
    })
  elseif event.type == "backfill" then
    noctalia.state.set(common.KEY_BACKFILL, {
      chat = event.chat or "",
      older = event.older == true,
      thumbs = event.thumbs == true,
      at = noctalia.nowMs(),
    })
  elseif event.type == "playback" then
    noctalia.state.set(common.KEY_PLAYBACK, {
      chat = event.chat or "",
      id = event.id or "",
      playing = event.state == "playing",
      started_ms = tonumber(event.started_ms) or 0,
      seconds = tonumber(event.seconds) or 0,
    })
  elseif event.type == "picked" then
    noctalia.state.set(common.KEY_PICKED, {
      path = if type(event.path) == "string" then event.path else nil,
      cancelled = event.cancelled == true,
      at = noctalia.nowMs(),
    })
  elseif event.type == "recording" then
    noctalia.state.set(common.KEY_RECORDING, {
      recording = event.state == "recording",
      started_ms = (tonumber(event.started) or noctalia.nowMs() / 1000) * 1000,
      path = if type(event.path) == "string" then event.path else nil,
      at = noctalia.nowMs(),
    })
  elseif event.type == "send_failed" then
    noctalia.state.set(common.KEY_SEND_FAILED, {
      chat = event.chat or "",
      error = if type(event.error) == "string" then event.error else "",
      at = noctalia.nowMs(),
    })
  end
end

-- Settings that need a daemon restart when they change.
local function configKey(): string
  return table.concat({
    tostring(resolveBinary()),
    tostring(noctalia.getConfig("history_limit")),
    tostring(noctalia.getConfig("media_cache_mb")),
    tostring(noctalia.getConfig("download_dir")),
    tostring(noctalia.getConfig("demo") == true),
  }, "\0")
end

local function startDaemon()
  binary = resolveBinary()
  noctalia.state.set(common.KEY_DAEMON, binary)
  if binary == nil then
    setStatus("missing")
    return
  end
  if dataDir == nil then
    noctalia.log("zap: no data dir: " .. tostring(dataError))
    setStatus("error", "data_dir")
    return
  end
  local limit = tonumber(noctalia.getConfig("history_limit")) or 50
  local cacheMb = tonumber(noctalia.getConfig("media_cache_mb")) or 500
  local downloadDir = noctalia.getConfig("download_dir")
  local demo = noctalia.getConfig("demo") == true
  local runDir = dataDir
  if demo then
    -- Demo data lives apart from the real session.
    runDir = dataDir .. "/demo"
    noctalia.mkdirAll(runDir)
  end
  -- runStream only takes a shell string: only settings and the data dir go
  -- in, each quoted. Nothing from messages ever reaches a command line here.
  local cmd = "exec "
    .. shellQuote(binary)
    .. " run "
    .. (if demo then "-demo " else "")
    .. "-data "
    .. shellQuote(runDir)
    .. " -history-limit "
    .. tostring(math.floor(limit))
    .. " -media-cache-mb "
    .. tostring(math.floor(cacheMb))
  if type(downloadDir) == "string" and downloadDir ~= "" then
    cmd ..= " -download-dir " .. shellQuote(noctalia.expandPath(downloadDir))
  end
  runningConfig = configKey()
  lastStart = noctalia.nowMs()
  failures = 0
  setStatus("connecting")
  if not noctalia.runStream(cmd, onLine) then
    setStatus("error", "start_failed")
  end
end

-- runStream has no exit callback, so a slow tick checks that the daemon answers.
noctalia.setUpdateInterval(WATCHDOG_MS)

function update()
  if binary == nil then
    return
  end
  if restartPending then
    restartPending = false
    startDaemon()
    return
  end
  noctalia.runAsync({ binary, "ctl", "status" }, function(r)
    if r.exitCode == 0 then
      failures = 0
      return
    end
    failures += 1
    if failures >= 2 and noctalia.nowMs() - lastStart > RESTART_GRACE_MS then
      setStatus("error", "daemon_stopped")
      startDaemon()
    end
  end, 5000)
end

function onConfigChanged()
  -- Restart the daemon only when one of its own settings changed.
  if binary == nil then
    startDaemon()
  elseif configKey() ~= runningConfig then
    noctalia.runAsync({ binary, "ctl", "quit" }, function(_r)
      restartPending = true
    end)
  end
end

function onIpc(event, payload)
  if event == "toggle" then
    noctalia.togglePanel(common.panelId())
  elseif event == "open" and type(payload) == "string" and payload ~= "" then
    -- Opens the panel on a chat, like clicking a notification.
    onNotifyAction("open", payload)
  end
end

noctalia.state.set(common.KEY_CHATS, {})
noctalia.state.set(common.KEY_UNREAD, 0)
startDaemon()
