--!nonstrict
-- Sonolith service: the only entry that talks to Sonolith.
--
-- It runs bridge/sonolith-bridge.py as a daemon through runStream, turns the daemon's stdout lines into
-- noctalia.state (keys in lib/state.luau), and runs the UI entries' commands (cmd:<entry>) through the
-- bridge's `call` mode, answering on res:<entry>. The bar and panels only read state and send commands.
--
-- The bridge runs from a copy in pluginDataDir(): Sonolith binds our token to the script's path, and the
-- plugin directory of a git-installed plugin is rewritten on every update.
--
-- IPC: noctalia msg plugin opecko/sonolith:service all <event>
--   toggle | next | previous | like | volume-up | volume-down | open | library | connect | disconnect

local S = require("./lib/state.luau")
local art = require("./lib/art.luau")
local format = require("./lib/format.luau")

local SILENCE_MS = 15000 -- the daemon prints a heartbeat every 5 s
local QUEUE_DEBOUNCE_MS = 300
local QUEUE_PREVIEW = 20
local TOAST_GAP_MS = 10000
local UI_ENTRIES = { "bar", "nowplaying", "library" }

local function log(msg)
  noctalia.log("[sonolith] " .. msg)
end

local function shellQuote(s)
  return "'" .. (string.gsub(s, "'", "'\\''")) .. "'"
end

local function now()
  return noctalia.nowMs()
end

---- State publishing

local rev = 0

local function put(key, value)
  noctalia.state.set(key, value)
  rev += 1
  noctalia.state.set(S.REV, rev)
end

local conn = { state = "starting" }
local scopes = {}
local player = nil
local track = nil
local queueSummary = nil
local lyricsLines = nil
local lyrics = nil

local function hasScope(scope)
  return table.find(scopes, scope) ~= nil
end

local function clearSession()
  player, track, queueSummary, lyricsLines, lyrics = nil, nil, nil, nil, nil
  put(S.PLAYER, nil)
  put(S.TRACK, { item = nil })
  put(S.POSITION, nil)
  put(S.QUEUE, nil)
  put(S.LYRICS, nil)
end

local function setConn(state, info)
  local next = { state = state }
  for k, v in pairs(info or {}) do
    next[k] = v
  end
  if state ~= S.CONNECTED and conn.state == S.CONNECTED then
    clearSession()
  end
  conn = next
  put(S.CONN, conn)
end

---- Timers (update() runs every 250 ms)

local timers = {}

local function after(ms, fn)
  table.insert(timers, { at = now() + ms, fn = fn })
end

local function runTimers()
  local t = now()
  local due = {}
  for i = #timers, 1, -1 do
    if timers[i].at <= t then
      table.insert(due, table.remove(timers, i))
    end
  end
  for _, timer in ipairs(due) do
    timer.fn()
  end
end

---- Bridge files

local pluginDir = noctalia.pluginDir()
local dataDir = noctalia.pluginDataDir()
local bridgePath = dataDir and (dataDir .. "/sonolith-bridge.py")

-- Copies the bundled bridge next to our data when it differs, through a rename so a running `call` never
-- reads half a file.
local function installBridge()
  local src, err = noctalia.readFile(pluginDir .. "/bridge/sonolith-bridge.py")
  if not src then
    log(`cannot read the bundled bridge: {err}`)
    return false
  end
  if noctalia.readFile(bridgePath) == src then
    return true
  end
  local tmp = bridgePath .. ".new"
  local ok, werr = noctalia.writeFile(tmp, src)
  if ok then
    ok, werr = noctalia.renameFile(tmp, bridgePath)
  end
  if not ok then
    log(`cannot install the bridge: {werr}`)
  end
  return ok
end

---- Bridge calls

local lastToastAt = -TOAST_GAP_MS

local function toast(title, body)
  if now() - lastToastAt >= TOAST_GAP_MS then
    lastToastAt = now()
    noctalia.notifyError(title, body)
  end
end

local function callBridge(method, params, cb)
  local payload = noctalia.json.encode(params or {}) or "{}"
  local started = noctalia.runAsync({ "python3", "-I", bridgePath, "call", method, payload }, function(r)
    local res = r.exitCode == 0 and noctalia.json.decode(r.stdout) or nil
    if type(res) ~= "table" then
      res = { ok = false, error = { name = "BridgeDown", reason = r.timedOut and "timeout" or noctalia.string.trim(r.stderr) } }
    end
    cb(res)
  end, 40000)
  if not started then
    cb({ ok = false, error = { name = "BridgeDown", reason = "spawnFailed" } })
  end
end

-- Runs a command with the shared error policy; cb(res) gets { ok, result?, error? }.
local function run(method, params, cb, retried)
  callBridge(method, params, function(res)
    local err = res.error
    if not res.ok and type(err) == "table" then
      if err.name == "RateLimited" and not retried then
        after(math.max(err.retryAfterMs or 500, 100), function()
          run(method, params, cb, true)
        end)
        return
      elseif err.name == "Timeout" then
        toast(noctalia.tr("toast.timeout.title"), noctalia.tr("toast.timeout.body"))
      elseif err.name == "NotSignedIn" then
        toast(noctalia.tr("toast.signed_out.title"), noctalia.tr("toast.signed_out.body"))
      elseif err.name ~= "Unavailable" and err.name ~= "PermissionDenied" and err.name ~= "NotConnected" then
        log(`{method} failed: {err.name} {err.reason or ""}`)
      end
    end
    if cb then
      cb(res)
    end
  end)
end

for _, entry in ipairs(UI_ENTRIES) do
  noctalia.state.watch(S.cmdKey(entry), function(cmd)
    if type(cmd) ~= "table" or type(cmd.method) ~= "string" then
      return
    end
    run(cmd.method, cmd.params, function(res)
      noctalia.state.set(S.resKey(entry), { id = cmd.id, ok = res.ok, result = res.result, error = res.error })
    end)
  end)
end

---- Queue preview: queue.get after queue.changed, debounced

local queueFetchAt = nil

local function fetchQueue()
  if not hasScope("queue:read") or not queueSummary then
    return
  end
  local summary = queueSummary
  run("queue.get", { fromIndex = summary.currentIndex or 0, limit = QUEUE_PREVIEW }, function(res)
    if not res.ok or queueSummary ~= summary then
      return
    end
    local q = {}
    for k, v in pairs(res.result) do
      q[k] = v
    end
    put(S.QUEUE, q)
  end)
end

local function scheduleQueueFetch()
  queueFetchAt = now() + QUEUE_DEBOUNCE_MS
end

---- Sonolith events

local function publishLyrics()
  put(S.LYRICS, lyrics)
end

-- The previous art stays published while the new one downloads, so the bar never flashes empty.
local function fetchArt(item)
  if not item or not item.id then
    return
  end
  art.fetch(item.id, item.thumbnailUrl, function(full, thumb)
    if full and track and track.id == item.id then
      put(S.ART, { trackId = item.id, path = full, thumb = thumb })
    end
  end, true)
end

local function setTrack(item)
  local oldId = track and track.id
  track = item
  put(S.TRACK, { item = item })
  if item and item.id ~= oldId then
    fetchArt(item)
    if oldId and noctalia.getConfig("osd_on_track_change") then
      noctalia.osd.show("music", `{item.title} – {format.artists(item)}`)
    end
  end
  if (item and item.id) ~= oldId and lyrics and lyrics.trackId ~= (item and item.id) then
    lyrics, lyricsLines = nil, nil
    publishLyrics()
  end
end

local function setPosition(p)
  put(S.POSITION, {
    positionMs = p.positionMs,
    positionAt = p.positionAt,
    durationMs = p.durationMs,
    rate = p.rate,
    status = p.status,
  })
end

local events = {}

events["player.stateChanged"] = function(p)
  player = p
  put(S.PLAYER, p)
  setPosition(p)
  if (p.item and p.item.id) ~= (track and track.id) or (p.item and track and p.item.rating ~= track.rating) then
    setTrack(p.item)
  end
end

events["player.trackChanged"] = function(p)
  setTrack(p.item)
end

events["player.position"] = setPosition

events["player.volumeChanged"] = function(p)
  if player then
    player.volume, player.muted = p.volume, p.muted
    put(S.PLAYER, player)
  end
end

events["queue.changed"] = function(p)
  queueSummary = p
  scheduleQueueFetch()
end

events["lyrics.changed"] = function(p)
  lyricsLines = p.lyrics and p.lyrics.lines or nil
  lyrics = {
    trackId = p.trackId,
    status = p.status,
    tier = p.lyrics and p.lyrics.tier or nil,
    lineIndex = nil,
    line = nil,
    nextLine = lyricsLines and lyricsLines[1] and lyricsLines[1].text or nil,
  }
  publishLyrics()
end

events["lyrics.line"] = function(p)
  if not lyrics or lyrics.trackId ~= p.trackId then
    return
  end
  lyrics.lineIndex = p.lineIndex
  lyrics.line = p.text
  lyrics.words = nil
  local nextLine = nil
  if p.lineIndex then
    local current = lyricsLines and lyricsLines[p.lineIndex + 1] -- lineIndex is 0-based
    if lyrics.tier == "word" and current and current.words and #current.words > 0 then
      -- Word timings, so the panel can light the line up word by word without lyrics.word events.
      local words = {}
      for _, w in ipairs(current.words) do
        table.insert(words, { startMs = w.startMs, text = w.text })
      end
      lyrics.words = words
    end
    nextLine = lyricsLines and lyricsLines[p.lineIndex + 2]
  elseif lyricsLines and p.positionMs then
    -- A break (or before the first line, or right after a seek into one): the next line to start.
    for _, line in ipairs(lyricsLines) do
      if line.startMs and line.startMs > p.positionMs then
        nextLine = line
        break
      end
    end
  end
  lyrics.nextLine = nextLine and nextLine.text or nil
  publishLyrics()
end

events["account.changed"] = function(p)
  put(S.SIGNED_IN, p.signedIn == true)
end

events["registration.resolved"] = function(p)
  if p.kind == "scopes" then
    put(S.SCOPE_REQUEST, {
      status = p.status,
      retryAt = p.retryAfterMs and (now() + p.retryAfterMs) or nil,
    })
  end
end

---- The daemon

local generation = 0
local streamStartedAt = 0
local lastLineAt = 0
local restartDelay = 1000
local restartAt = nil

local function setScopes(list)
  scopes = list or {}
  put(S.SCOPES, scopes)
end

local function onLine(line)
  lastLineAt = now()
  if lastLineAt - streamStartedAt > 60000 then
    restartDelay = 1000
  end
  local msg = noctalia.json.decode(line)
  if type(msg) ~= "table" then
    return
  end
  local t = msg.t
  if t == "event" then
    local handler = events[msg.method]
    if handler and type(msg.params) == "table" then
      handler(msg.params)
    end
  elseif t == "status" then
    setConn(msg.state, msg.info)
  elseif t == "hello" then
    setScopes(msg.grantedScopes)
    put(S.SIGNED_IN, msg.signedIn == true)
    put(S.APP_VERSION, msg.appVersion)
  elseif t == "scopes" then
    setScopes(msg.grantedScopes)
  elseif t == "log" then
    log(`bridge {msg.level}: {msg.msg}`)
  end
end

local function startBridge()
  restartAt = nil
  generation += 1
  local gen = generation
  streamStartedAt = now()
  lastLineAt = streamStartedAt
  local cmd = `exec python3 -I {shellQuote(bridgePath)} daemon --data-dir {shellQuote(dataDir)}`
  local ok = noctalia.runStream(cmd, function(line)
    if gen == generation then
      onLine(line)
    end
  end)
  if not ok then
    log("could not start the bridge")
  end
end

local function scheduleRestart(why)
  log(`bridge {why}; restarting in {restartDelay} ms`)
  restartAt = now() + restartDelay
  restartDelay = math.min(restartDelay * 2, 30000)
  if conn.state ~= "unavailable" then
    setConn("unavailable", { message = "bridgeRestarting" })
  end
end

---- Startup

put(S.SCOPES, {})
put(S.TRACK, { item = nil })

if not noctalia.commandExists("python3") then
  setConn("error", { message = "noPython" })
elseif not bridgePath or not installBridge() then
  setConn("error", { message = "bridgeInstall" })
else
  setConn("starting")
  startBridge()
end

noctalia.setUpdateInterval(250)

function update()
  runTimers()
  if queueFetchAt and now() >= queueFetchAt then
    queueFetchAt = nil
    fetchQueue()
  end
  if generation == 0 then
    return
  end
  if restartAt then
    if now() >= restartAt then
      startBridge()
    end
  elseif now() - lastLineAt > SILENCE_MS then
    scheduleRestart("went silent")
  end
end

---- IPC

local function volumeStep()
  return noctalia.getConfig("volume_step") or 5
end

local ipc = {
  toggle = function()
    run("player.toggle")
  end,
  next = function()
    run("player.next")
  end,
  previous = function()
    run("player.previous")
  end,
  like = function()
    if track and track.id then
      local rating = track.rating == "like" and "none" or "like"
      run("rating.set", { item = { type = track.type, id = track.id }, rating = rating })
    end
  end,
  ["volume-up"] = function()
    if player then
      run("player.setVolume", { volume = math.clamp(player.volume + volumeStep(), 0, 100) })
    end
  end,
  ["volume-down"] = function()
    if player then
      run("player.setVolume", { volume = math.clamp(player.volume - volumeStep(), 0, 100) })
    end
  end,
  open = function()
    noctalia.togglePanel("opecko/sonolith:nowplaying")
  end,
  library = function()
    noctalia.togglePanel("opecko/sonolith:library")
  end,
  -- A keybind is a user action, so connecting from one is allowed.
  connect = function()
    run("bridge.register")
  end,
  disconnect = function()
    run("bridge.disconnect")
  end,
  dump = function()
    log(noctalia.json.encode({ conn = conn, scopes = scopes, track = track and track.title, rating = track and track.rating, signedIn = noctalia.state.get(S.SIGNED_IN), rev = rev }) or "?")
  end,
}

function onIpc(event, _payload)
  local handler = ipc[event]
  if handler then
    handler()
  else
    log(`unknown IPC event: {event}`)
  end
end

function onConfigChanged() end
