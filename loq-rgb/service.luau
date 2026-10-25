--!nonstrict
-- LOQ RGB: service (no UI). Owns the profile and talks to the keyboard through helper/lamparray.py.
--   * panel and widget send requests through noctalia.state; the service reacts to them (no polling)
--   * it computes the colours, writes DATA_DIR/command.txt and the helper animates the transition
--   * it saves the profile as JSON in noctalia.pluginDataDir() and publishes status for the UI
local P = require("./lib/profile.luau")

local IDLE_MS = 500                  -- palette / heartbeat / save checks when nothing is pending
local BUSY_MS = 33                   -- only while a command write waits for the rate limit
local MIN_WRITE_GAP_MS = 33          -- at most ~30 commands per second while dragging a slider
local DRAG_GAP_MS = 220              -- requests closer than this count as a drag (short fades)
local HEARTBEAT_TIMEOUT_MS = 20000
local SAVE_DEBOUNCE_MS = 1500

local dataDir = noctalia.pluginDataDir()
local profile = P.defaults()
local status = { state = "starting" }
local cmdSeq = noctalia.nowMs()
local lastReqMs = 0
local lastWriteMs = 0
local pendingMs = nil                -- transition (ms) of a command waiting to be written; last request wins
local dirtySince = nil
local lastBeat = 0
local helperStarted = false
local paletteSig = ""
local lastPaletteMs = 0
local interval = 0

local function setInterval(ms)
  if ms ~= interval then
    interval = ms
    noctalia.setUpdateInterval(ms)
  end
end

local function transitionMs()
  local v = noctalia.getConfig("transition_ms")
  if type(v) ~= "number" then
    return 350
  end
  return math.max(0, math.min(2000, v))
end

local function publishProfile()
  noctalia.state.set("kb_profile", profile)
end

local function setStatus(obj)
  status = obj
  noctalia.state.set("kb_status", status)
end

-- ---------------------------------------------------------------- persistence
local function loadProfile()
  if not dataDir then
    return
  end
  local raw = noctalia.readFile(dataDir .. "/profile.json")
  if raw then
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      profile = P.sanitize(decoded)
    end
  end
end

local function saveProfile()
  if not dataDir then
    return
  end
  local encoded = noctalia.json.encode(profile)
  if encoded then
    noctalia.writeFile(dataDir .. "/profile.json", encoded)
  end
end

-- ---------------------------------------------------------------- helper commands
-- Written atomically (tmp + rename) so the helper never reads a half-written file.
local function writeCommand(ms)
  if status.state ~= "ready" or type(status.zones) ~= "number" or not dataDir then
    return
  end
  local mode, colors = "rgb", ""
  if not profile.on then
    mode = "off"
  elseif profile.mode == "firmware" then
    mode = "auto"
  else
    local cols = P.colors(profile, status.zones)
    if not cols then
      return
    end
    colors = table.concat(cols, ",")
    paletteSig = P.paletteSignature(profile)
  end
  cmdSeq = cmdSeq + 1
  local text = string.format("seq=%.0f\nmode=%s\nbr=%.0f\nms=%.0f\ncolors=%s\nEND\n", cmdSeq, mode, profile.br, ms, colors)
  local path, tmp = dataDir .. "/command.txt", dataDir .. "/command.tmp"
  if not (noctalia.writeFile(tmp, text) and noctalia.renameFile(tmp, path)) then
    noctalia.writeFile(path, text)
  end
  lastWriteMs = noctalia.nowMs()
end

local function flush(now)
  if pendingMs ~= nil and now - lastWriteMs >= MIN_WRITE_GAP_MS then
    local ms = pendingMs
    pendingMs = nil
    writeCommand(ms)
  end
end

local function requestSend(ms)
  pendingMs = ms
  flush(noctalia.nowMs())
  if pendingMs ~= nil then
    setInterval(BUSY_MS)
  end
end

local function markDirty()
  dirtySince = noctalia.nowMs()
end

-- ---------------------------------------------------------------- helper process
local function onHelperLine(line)
  local tag, body = string.match(line, "^(%u+)%s*(.*)$")
  if tag == "BEAT" then
    lastBeat = noctalia.nowMs()
  elseif tag == "STATE" then
    local obj = noctalia.json.decode(body)
    if type(obj) == "table" then
      lastBeat = noctalia.nowMs()
      setStatus(obj)
      if obj.state == "ready" then
        writeCommand(0)
      end
    end
  end
end

local function startHelper()
  if not dataDir or not noctalia.pluginDir() then
    setStatus({ state = "error", message = "no plugin directory" })
    return
  end
  if not noctalia.commandExists("python3") then
    setStatus({ state = "needs_python" })
    return
  end
  local script = noctalia.pluginDir() .. "/helper/lamparray.py"
  lastBeat = noctalia.nowMs()
  -- "exec" so that stopping the stream signals Python directly (it then hands the keyboard back)
  helperStarted = noctalia.runStream("exec python3 -u " .. P.shellQuote(script) .. " " .. P.shellQuote(dataDir), onHelperLine)
  if not helperStarted then
    setStatus({ state = "error", message = "could not start the helper" })
  end
end

-- ---------------------------------------------------------------- requests from the panel / widget
noctalia.state.watch("kb_req_profile", function(req)
  if type(req) ~= "table" or type(req.profile) ~= "table" then
    return
  end
  local now = noctalia.nowMs()
  local dragging = now - lastReqMs < DRAG_GAP_MS
  lastReqMs = now
  profile = P.sanitize(req.profile)
  markDirty()
  local ms = transitionMs()
  if dragging then
    ms = math.min(ms, 80)
  end
  requestSend(ms)
  publishProfile()
end)

noctalia.state.watch("kb_req_widget", function(req)
  if type(req) ~= "table" then
    return
  end
  if req.name == "set" and (req.arg == "on" or req.arg == "off") then
    profile.on = (req.arg == "on")
  elseif req.name == "bright" and type(req.arg) == "number" then
    profile.br = math.floor(math.max(0, math.min(100, req.arg)) + 0.5)
  else
    return
  end
  markDirty()
  requestSend(transitionMs())
  publishProfile()
end)

-- ---------------------------------------------------------------- periodic work (cheap, 2 Hz when idle)
function update()
  local now = noctalia.nowMs()
  flush(now)

  -- follow the Noctalia palette (wallpaper / theme changes): a slower, gentler fade
  if profile.on and profile.mode == "palette" and now - lastPaletteMs >= IDLE_MS then
    lastPaletteMs = now
    if P.paletteSignature(profile) ~= paletteSig and status.state == "ready" then
      requestSend(math.floor(transitionMs() * 2))
    end
  end

  if dirtySince and now - dirtySince >= SAVE_DEBOUNCE_MS then
    dirtySince = nil
    saveProfile()
  end

  -- the helper prints a heartbeat every few seconds; restart it if it went silent (crash, suspend)
  if helperStarted and now - lastBeat > HEARTBEAT_TIMEOUT_MS then
    noctalia.log("loq-rgb: helper silent, restarting it")
    startHelper()
  end

  if pendingMs ~= nil then
    setInterval(BUSY_MS)
  elseif dirtySince then
    setInterval(250)
  else
    setInterval(IDLE_MS)
  end
end

-- Best effort: on disable, ask the helper to give the keyboard back to its firmware effects.
function onExit(_signal, reason)
  if dataDir and (reason == "disable" or reason == "uninstall") then
    cmdSeq = cmdSeq + 1
    noctalia.writeFile(dataDir .. "/command.txt", string.format("seq=%.0f\nmode=auto\nbr=100\nms=0\nEND\n", cmdSeq))
  end
end

loadProfile()
publishProfile()
setStatus(status)
startHelper()
setInterval(IDLE_MS)
