--!nonstrict
-- EncoBuds service — the only entry that talks to the earbuds.
--
-- Owns the single EncoBuds CLI process and publishes one snapshot for every
-- other entry. The CLI ships with the plugin in scripts/ (Python standard
-- library only), so nothing outside the plugin directory is required:
--
--   scripts/encobuds.py --json status
--
-- The bar widget and panel never spawn processes; they watch `encobuds.state`
-- and publish JSON commands on `encobuds.cmd`.
--
-- State channels:
--   encobuds.state  (service -> entries) snapshot + phase/busy/error
--   encobuds.cmd    (entries -> service) { n, action, ... }

local REFRESH_MS = 30000

local MODE_KEYS = {
  off = "off", close = "off",
  anc = "anc", nc = "anc",
  deep = "deep",
  mid = "mid", medium = "mid",
  light = "light",
  smart = "smart", auto = "smart",
  trans = "trans", transparency = "trans",
}

local state = {
  phase = "loading", -- loading | online | offline | error
  ok = false,
  mode = nil,
  battery = {},
  game = nil,
  volume = nil,
  devices = {},
  product = nil,
  firmware = nil,
  mac = nil,
  error = nil,
  busy = nil,
  ringing = false,
  updatedAt = nil,
}

local running = false
local ringProcess = false
local generation = 0
local pendingRefresh = false
local lastNonce = nil
local ringUntil = 0
local poll

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function trim(text)
  return noctalia.string.trim(text or "")
end

local function publish()
  noctalia.state.set("encobuds.state", noctalia.json.encode(state))
end



local function setError(message)
  state.phase = "error"
  state.ok = false
  state.error = message
  state.busy = nil
  publish()
end

-- ── CLI location ────────────────────────────────────────────────────────────

-- The CLI ships with the plugin in `scripts/`, so running it needs nothing
-- but the system Python.
local function argvFor(extra)
  local dir = noctalia.pluginDir()
  if dir == nil or dir == "" or not noctalia.commandExists("python3") then
    return nil
  end
  local bundled = dir .. "/scripts/encobuds.py"
  if not noctalia.fileExists(bundled) then
    return nil
  end

  -- -B: never write __pycache__ into the (often versioned) plugin directory.
  local argv = { "python3", "-B", bundled, "--json" }
  for _, value in ipairs(extra or {}) do
    table.insert(argv, tostring(value))
  end
  return argv
end

-- ── Process plumbing ─────────────────────────────────────────────────────────

-- Runs the CLI with extra args. cb(result) receives runAsync's result table.
-- Result callbacks from an older generation (settings changed meanwhile) are
-- discarded and replaced by a fresh poll.
local function start(extra, cb)
  if running then
    return false
  end
  local argv = argvFor(extra)
  if argv == nil then
    setError(tr("error.command_missing"))
    return false
  end

  running = true
  local current = generation
  local launched = noctalia.runAsync(argv, function(result)
    running = false
    if current ~= generation then
      if pendingRefresh then
        pendingRefresh = false
        poll()
      end
      return
    end
    cb(result)
  end)
  if not launched then
    running = false
    setError(tr("error.failed"))
    return false
  end
  return true
end

local function decode(result)
  local data = noctalia.json.decode(result.stdout or "")
  if type(data) ~= "table" then
    return nil
  end
  return data
end

local function applyData(data)
  state.phase = "online"
  state.ok = true
  state.error = nil
  state.mode = data.mode
  state.battery = type(data.battery) == "table" and data.battery or {}
  state.game = data.game
  state.volume = data.volume
  state.devices = type(data.devices) == "table" and data.devices or {}
  state.product = data.product
  state.firmware = data.firmware
  state.mac = data.mac
  state.updatedAt = noctalia.nowMs()
end

local function applyError(result)
  local data = decode(result)
  state.ok = false
  state.phase = (result.exitCode == 2 and not result.timedOut) and "offline" or "error"
  if result.timedOut then
    state.error = tr("error.timeout")
  elseif data ~= nil and data.error ~= nil then
    state.error = tostring(data.error)
  else
    local stderr = trim(result.stderr)
    state.error = stderr ~= "" and stderr or tr("error.failed")
  end
  if #state.error > 400 then
    state.error = state.error:sub(1, 400) .. "…"
  end
  if state.phase == "error" then
    noctalia.log("EncoBuds: " .. state.error)
  end
end

-- ── Find my earbuds ──────────────────────────────────────────────────────────
-- The tone only lasts while the RFCOMM link stays open, so `find on` is a
-- long-lived process that holds the link. A stop file lets the service end it
-- early without opening a second (rejected) link.

local function findStopPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil or dir == "" then
    dir = noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp"
  end
  return dir .. "/find.stop"
end

local function clearFindStop()
  noctalia.removeFile(findStopPath())
end

local function stopFindProcess()
  noctalia.writeFile(findStopPath(), "1")
end

local function stopRing()
  local was = state.ringing or ringProcess
  state.ringing = false
  ringUntil = 0
  if was then
    stopFindProcess()
  end
  publish()
end

local function startRing()
  if state.phase ~= "online" or state.ringing or ringProcess or running then
    return
  end
  clearFindStop()
  local argv = argvFor({
    "find", "on",
    "--hold", "20",
    "--stop-file", findStopPath(),
  })
  if argv == nil then
    setError(tr("error.command_missing"))
    return
  end

  local current = generation
  ringProcess = true
  state.ringing = true
  ringUntil = noctalia.nowMs() + 15000
  state.busy = "find"
  state.error = nil
  publish()

  local launched = noctalia.runAsync(argv, function(result)
    ringProcess = false
    if current ~= generation then
      if pendingRefresh then
        pendingRefresh = false
        poll()
      end
      return
    end

    state.busy = nil
    state.ringing = false
    ringUntil = 0
    if result.exitCode ~= 0 and not result.timedOut then
      local data = decode(result)
      state.error = data and data.error or trim(result.stderr) or tr("error.failed")
      if #state.error > 400 then
        state.error = state.error:sub(1, 400) .. "…"
      end
    end
    publish()
    if not running then
      poll()
    end
  end, 25000)

  if not launched then
    ringProcess = false
    state.ringing = false
    state.busy = nil
    ringUntil = 0
    setError(tr("error.failed"))
  end
end

-- Applies a mutating command's own JSON, then refreshes the full snapshot.
local function perform(action, extra, onSuccess)
  if running or ringProcess then
    return
  end
  state.busy = action
  state.error = nil
  publish()

  local started = start(extra, function(result)
    state.busy = nil
    local data = decode(result)
    if result.exitCode ~= 0 or data == nil or data.ok == false then
      applyError(result)
      publish()
      return
    end

    -- Apply the command's fields immediately so the UI reacts without waiting
    -- for the follow-up status round trip.
    if data.mode ~= nil then
      state.mode = data.mode
    end
    if data.game ~= nil then
      state.game = data.game
    end
    if data.volume ~= nil then
      state.volume = data.volume
    end
    if type(data.devices) == "table" then
      state.devices = data.devices
    end
    state.phase = "online"
    state.ok = true
    state.error = nil
    state.updatedAt = noctalia.nowMs()

    if onSuccess ~= nil then
      onSuccess(data)
    end
    publish()
    poll()
  end)

  if not started then
    state.busy = nil
    publish()
  end
end

poll = function()
  if ringProcess then
    return
  end
  start({ "status" }, function(result)
    local data = decode(result)
    if result.exitCode == 0 and data ~= nil and data.ok == true then
      applyData(data)
    else
      applyError(result)
    end
    publish()
  end)
end

-- ── Commands from the UI ─────────────────────────────────────────────────────

local function setMode(key)
  key = MODE_KEYS[string.lower(trim(key or ""))]
  if key == nil then
    return
  end
  perform("mode", { key }, nil)
end

local function cycleMode()
  perform("mode", { "cycle" }, nil)
end

local function setGame(value)
  value = string.lower(trim(value or ""))
  if value ~= "on" and value ~= "off" then
    return
  end
  perform("game", { "game", value }, nil)
end

local function setFind(value)
  value = string.lower(trim(value or ""))
  if value == "on" then
    startRing()
  elseif value == "off" then
    stopRing()
  end
end

local function setVolume(value)
  local level = tonumber(value)
  if level == nil then
    return
  end
  level = math.clamp(math.floor(level), 2, 10)
  perform("volume", { "volume", tostring(level) }, nil)
end

local function setDevice(verb, target)
  verb = string.lower(trim(verb or ""))
  target = trim(target or "")
  if (verb ~= "connect" and verb ~= "disconnect") or target == "" or #target > 120 then
    return
  end
  perform("device", { verb, target }, nil)
end

local function runCommand(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local action = cmd.action
  noctalia.log(`EncoBuds command {tostring(action)} {tostring(cmd.mode or cmd.value or cmd.verb or "")}`)
  if action == "set_mode" or action == "mode" then
    setMode(cmd.mode or cmd.value)
  elseif action == "cycle" then
    cycleMode()
  elseif action == "game" then
    setGame(cmd.value)
  elseif action == "find" then
    setFind(cmd.value)
  elseif action == "volume" then
    setVolume(cmd.value)
  elseif action == "device" then
    setDevice(cmd.verb, cmd.target)
  elseif action == "refresh" or action == "status" then
    poll()
  end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

publish()

noctalia.state.watch("encobuds.cmd", function(encoded)
  if encoded == nil then
    return
  end
  local cmd = noctalia.json.decode(encoded)
  if type(cmd) ~= "table" or cmd.n == nil or cmd.n == lastNonce then
    return
  end
  lastNonce = cmd.n
  runCommand(cmd)
end)

function update()
  -- While the earbuds are ringing, tick faster so the 15 s auto-stop is prompt.
  noctalia.setUpdateInterval(state.ringing and 1000 or REFRESH_MS)

  if state.ringing and ringUntil > 0 and noctalia.nowMs() >= ringUntil then
    stopRing()
    return
  end

  if not running and not ringProcess then
    poll()
  end
end

-- Settings changed: keep the runtime, drop stale results and poll once any
-- in-flight process finishes.
function onConfigChanged()
  if state.ringing or ringProcess then
    state.ringing = false
    ringUntil = 0
    stopFindProcess()
  end
  generation = generation + 1
  noctalia.setUpdateInterval(REFRESH_MS)
  state.phase = "loading"
  state.ok = false
  state.error = nil
  state.busy = nil
  publish()
  if running or ringProcess then
    pendingRefresh = true
  else
    poll()
  end
end

-- Stop a ring started from the panel when the plugin is disabled, removed or
-- reloaded; otherwise the earbuds keep beeping with no UI left to stop them.
function onExit(_signal, _reason)
  if state.ringing or ringProcess then
    stopFindProcess()
  end
end

-- noctalia msg plugin fish/encobuds:service all <event> [payload]
function onIpc(event, payload)
  if event == "status" or event == "refresh" then
    poll()
  elseif event == "mode" or event == "set_mode" or event == "set-mode" then
    setMode(payload)
  elseif event == "cycle" or event == "cycle-mode" then
    cycleMode()
  elseif event == "game" then
    setGame(payload)
  elseif event == "find" then
    setFind(payload)
  elseif event == "volume" then
    setVolume(payload)
  elseif event == "connect" or event == "disconnect" then
    setDevice(event, payload)
  else
    noctalia.log(`EncoBuds: unknown IPC event '{event}'`)
  end
end

-- Fetch a snapshot immediately on load instead of waiting for the first tick.
poll()
