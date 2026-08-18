--!nonstrict
-- Headless service: owns the long-lived Python bridge and publishes each
-- complete Discord voice snapshot for the widget and panel.

local BRIDGE_STATE_KEY = "voice_snapshot"

local bridgePath = noctalia.pluginDir() .. "/discord_bridge.py"
local bridgeScript = "'" .. bridgePath:gsub("'", "'\\''") .. "'"

local function initialSnapshot(status, message)
  return {
    revision = 0,
    status = status,
    status_message = message,
    authenticated = false,
    user = {},
    channel = nil,
    recent_channels = {},
    favorite_channels = {},
    participants = {},
    voice = { mute = false, deaf = false, input_volume = 100 },
    connection = {
      state = "DISCONNECTED",
      hostname = "",
      average_ping = 0,
      last_ping = 0,
    },
    connected_since = nil,
  }
end

local function shallowCopy(value)
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = item
  end
  return copy
end

local lastLineAt = tonumber(noctalia.formatTime("%s")) or 0
local streamStarted = false
local restartInProgress = false
local nextRestartProbeAt = 0

local function nowSeconds()
  return tonumber(noctalia.formatTime("%s")) or 0
end

local function onBridgeLine(line)
  lastLineAt = nowSeconds()
  nextRestartProbeAt = 0
  local event, err = noctalia.json.decode(line)
  if type(event) ~= "table" then
    noctalia.log("discord-voice: ignored malformed bridge output: " .. tostring(err or "unknown error"))
    return
  end
  if event.type == "heartbeat" then
    return
  end
  if event.type ~= "snapshot" then
    return
  end
  event.type = nil
  noctalia.state.set(BRIDGE_STATE_KEY, event)
end

local function startBridge()
  if streamStarted then
    return
  end
  if not noctalia.commandExists("python3") then
    noctalia.state.set(BRIDGE_STATE_KEY, initialSnapshot("error", noctalia.tr("error.python_missing")))
    return
  end
  noctalia.state.set(BRIDGE_STATE_KEY, initialSnapshot("starting", ""))
  streamStarted = noctalia.runStream("python3 " .. bridgeScript .. " daemon", onBridgeLine)
  if streamStarted then
    lastLineAt = nowSeconds()
  else
    noctalia.state.set(BRIDGE_STATE_KEY, initialSnapshot("error", noctalia.tr("error.bridge_start")))
  end
end

local function markBridgeStalled()
  local current = noctalia.state.get(BRIDGE_STATE_KEY)
  local previous = type(current) == "table"
    and shallowCopy(current)
    or initialSnapshot("error", "")
  previous.status_message = noctalia.tr("error.bridge_stalled")
  noctalia.state.set(BRIDGE_STATE_KEY, previous)
end

local function restartBridge()
  if restartInProgress then
    return
  end
  restartInProgress = true
  markBridgeStalled()

  local started = noctalia.runAsync(
    "python3 " .. bridgeScript .. " command shutdown",
    function(result)
      restartInProgress = false
      local response = noctalia.json.decode(result.stdout or "")
      local bridgeAbsent = type(response) == "table" and response.bridge_state == "absent"
      if result.exitCode == 0 or bridgeAbsent then
        streamStarted = false
        nextRestartProbeAt = 0
        startBridge()
        return
      end

      -- A live but unresponsive helper may still own the control socket. Do
      -- not launch a duplicate; probe it again later in case it exits.
      nextRestartProbeAt = nowSeconds() + 30
      markBridgeStalled()
    end,
    10000
  )
  if not started then
    restartInProgress = false
    nextRestartProbeAt = nowSeconds() + 30
  end
end

noctalia.setUpdateInterval(5000)
startBridge()

function update()
  -- The bridge emits a heartbeat every five seconds. Surface a stalled helper
  -- and restart it. This also recovers from a helper that exits during a
  -- Noctalia hot-reload handoff.
  if not streamStarted then
    startBridge()
    return
  end
  local now = nowSeconds()
  if now - lastLineAt > 20 and now >= nextRestartProbeAt then
    restartBridge()
  end
end

function onIpc(event, _payload)
  if event == "authorize" then
    noctalia.runAsync("python3 " .. bridgeScript .. " command authorize")
  elseif event == "refresh" then
    noctalia.runAsync("python3 " .. bridgeScript .. " command refresh")
  elseif event == "hangup" then
    noctalia.runAsync("python3 " .. bridgeScript .. " command hang-up")
  elseif event == "dump" then
    local snapshot = noctalia.state.get(BRIDGE_STATE_KEY)
    local safe = {
      status = snapshot.status,
      authenticated = snapshot.authenticated,
      channel = snapshot.channel,
      recent_channels = snapshot.recent_channels,
      favorite_channels = snapshot.favorite_channels,
      participants = #snapshot.participants,
      voice = snapshot.voice,
      connection = snapshot.connection,
    }
    noctalia.log("discord-voice: " .. (noctalia.json.encode(safe) or "?"))
  end
end
