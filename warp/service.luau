--!nonstrict
-- Owns warp-cli access and shares one status with every UI entry.

local POLL_INTERVAL_MS = 10000
local CLI = "warp-cli --accept-tos --json --no-paginate --no-ansi"
local MODES = {
  warp = true,
  doh = true,
  ["warp+doh"] = true,
  dot = true,
  ["warp+dot"] = true,
  proxy = true,
  tunnel_only = true,
}

local status = {
  state = "checking",
  available = false,
  busy = false,
  message = "",
  mode = "",
  protocol = "",
  endpoint = "",
  colo = "",
  latencyMs = nil,
  loss = nil,
  bytesSent = nil,
  bytesReceived = nil,
  handshakeSecs = nil,
  tlsVersion = "",
  tlsCurve = "",
  postQuantum = false,
  alwaysOn = false,
  switchLocked = false,
  splitTunnelMode = "",
  splitTunnelCount = 0,
  statsAvailable = false,
}
local statusInFlight = false
local settingsInFlight = false
local statsInFlight = false
local actionInFlight = false
local lastPublished = ""
local refreshStatus

local function publish()
  local key = table.concat({
    status.state,
    tostring(status.available),
    tostring(status.busy),
    status.message,
    status.mode,
    status.protocol,
    status.endpoint,
    status.colo,
    tostring(status.latencyMs),
    tostring(status.loss),
    tostring(status.bytesSent),
    tostring(status.bytesReceived),
    tostring(status.handshakeSecs),
    status.tlsVersion,
    status.tlsCurve,
    tostring(status.postQuantum),
    tostring(status.alwaysOn),
    tostring(status.switchLocked),
    status.splitTunnelMode,
    tostring(status.splitTunnelCount),
    tostring(status.statsAvailable),
  }, "|")
  if key == lastPublished then
    return
  end

  lastPublished = key
  noctalia.state.set("warp.status", {
    state = status.state,
    available = status.available,
    busy = status.busy,
    message = status.message,
    mode = status.mode,
    protocol = status.protocol,
    endpoint = status.endpoint,
    colo = status.colo,
    latencyMs = status.latencyMs,
    loss = status.loss,
    bytesSent = status.bytesSent,
    bytesReceived = status.bytesReceived,
    handshakeSecs = status.handshakeSecs,
    tlsVersion = status.tlsVersion,
    tlsCurve = status.tlsCurve,
    postQuantum = status.postQuantum,
    alwaysOn = status.alwaysOn,
    switchLocked = status.switchLocked,
    splitTunnelMode = status.splitTunnelMode,
    splitTunnelCount = status.splitTunnelCount,
    statsAvailable = status.statsAvailable,
  })
end

local function patchStatus(values)
  for key, value in pairs(values) do
    status[key] = value
  end
  publish()
end

local function commandError(result, decoded)
  if type(decoded) == "table" then
    if type(decoded.error) == "string" and decoded.error ~= "" then
      return decoded.error
    end
    if type(decoded.code) == "string" and decoded.code ~= "" then
      return decoded.code
    end
  end

  if type(result.stderr) == "string" and result.stderr ~= "" then
    return result.stderr:gsub("%s+$", "")
  end
  return noctalia.tr("error.command-failed")
end

local function normalizedState(value)
  local raw = string.lower(tostring(value or ""))
  if raw == "connected" then
    return "connected"
  elseif raw == "connecting" then
    return "connecting"
  elseif raw == "disconnecting" then
    return "disconnecting"
  elseif raw == "disconnected" then
    return "disconnected"
  end
  return "error"
end

local function listCount(value)
  return if type(value) == "table" then #value else 0
end

local function refreshSettings()
  if settingsInFlight or not noctalia.commandExists("warp-cli") then
    return
  end

  settingsInFlight = true
  local accepted = noctalia.runAsync(`{CLI} settings list`, function(result)
    settingsInFlight = false
    if actionInFlight then
      return
    end
    local decoded = noctalia.json.decode(result.stdout or "")
    local settings = if type(decoded) == "table" then decoded.settings or decoded else nil
    if result.exitCode ~= 0 or type(settings) ~= "table" or settings.error ~= nil or settings.code ~= nil then
      return
    end

    patchStatus({
      mode = tostring(settings.operation_mode or settings.mode or ""),
      protocol = if status.protocol ~= "" then status.protocol else tostring(settings.warp_tunnel_protocol or ""),
      alwaysOn = settings.always_on == true,
      switchLocked = settings.switch_locked == true,
      splitTunnelMode = tostring(settings.split_tunnel_mode or ""),
      splitTunnelCount = listCount(settings.split_tunnel_ips) + listCount(settings.split_tunnel_hosts),
    })
  end, 8000)
  if not accepted then
    settingsInFlight = false
  end
end

local function refreshStats()
  if statsInFlight or not noctalia.commandExists("warp-cli") then
    return
  end

  statsInFlight = true
  local accepted = noctalia.runAsync(`{CLI} tunnel stats`, function(result)
    statsInFlight = false
    local decoded = noctalia.json.decode(result.stdout or "")
    local stats = if type(decoded) == "table" then decoded.stats or decoded else nil
    if result.exitCode ~= 0 or type(stats) ~= "table" or stats.error ~= nil or stats.code ~= nil then
      patchStatus({ statsAvailable = false })
      return
    end

    local tls = if type(stats.tls) == "table" then stats.tls else {}
    local edge = if type(stats.edge) == "table" then stats.edge else {}
    local endpoint = stats.v4_endpoint or stats.endpoint or stats.peer_endpoint or ""
    if endpoint == "" or endpoint == "::" then
      endpoint = stats.v6_endpoint or ""
    end

    patchStatus({
      protocol = tostring(stats.protocol or stats.tunnel_protocol or status.protocol or ""),
      endpoint = tostring(endpoint),
      colo = tostring(edge.colo or stats.colo or ""),
      latencyMs = tonumber(stats.estimated_latency_ms or stats.latency_ms or stats.latency),
      loss = tonumber(stats.estimated_loss or stats.loss),
      bytesSent = tonumber(stats.bytes_sent or stats.tx_bytes),
      bytesReceived = tonumber(stats.bytes_received or stats.rx_bytes),
      handshakeSecs = tonumber(stats.secs_since_last_handshake),
      tlsVersion = tostring(tls.version or ""),
      tlsCurve = tostring(tls.curve or ""),
      postQuantum = tls.post_quantum_enabled == true,
      statsAvailable = true,
    })
  end, 8000)
  if not accepted then
    statsInFlight = false
    patchStatus({ statsAvailable = false })
  end
end

local function refreshDetails()
  refreshSettings()
  refreshStats()
end

local function setMode(mode)
  if actionInFlight or type(mode) ~= "string" or not MODES[mode] then
    return
  end
  if not noctalia.commandExists("warp-cli") then
    refreshStatus()
    return
  end
  if status.switchLocked then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.mode-locked"))
    return
  end
  if mode == status.mode then
    return
  end

  actionInFlight = true
  patchStatus({ busy = true, mode = mode, message = "" })
  local accepted = noctalia.runAsync(`{CLI} mode {mode}`, function(result)
    actionInFlight = false
    local decoded = noctalia.json.decode(result.stdout or "")
    local failed = result.exitCode ~= 0 or (type(decoded) == "table" and (decoded.error ~= nil or decoded.code ~= nil))
    if failed then
      local message = commandError(result, decoded)
      patchStatus({ busy = false, message = message })
      noctalia.notifyError(noctalia.tr("title"), message)
      refreshStatus()
      refreshDetails()
      return
    end
    patchStatus({ busy = false })
    refreshStatus()
    refreshDetails()
  end, 15000)
  if not accepted then
    actionInFlight = false
    patchStatus({ busy = false, message = noctalia.tr("error.command-failed") })
    refreshStatus()
    refreshDetails()
  end
end

refreshStatus = function()
  if statusInFlight or actionInFlight then
    return
  end

  status.available = noctalia.commandExists("warp-cli")
  if not status.available then
    patchStatus({
      state = "unavailable",
      busy = false,
      message = noctalia.tr("error.cli-missing"),
    })
    return
  end

  statusInFlight = true
  local accepted = noctalia.runAsync(`{CLI} status`, function(result)
    statusInFlight = false
    local decoded = noctalia.json.decode(result.stdout or "")

    if result.exitCode == 0 and type(decoded) == "table" and type(decoded.status) == "string" then
      patchStatus({
        state = normalizedState(decoded.status),
        available = true,
        busy = false,
        message = "",
      })
      refreshDetails()
      return
    end

    patchStatus({
      state = "error",
      available = true,
      busy = false,
      message = commandError(result, decoded),
    })
  end, 8000)
  if not accepted then
    statusInFlight = false
    patchStatus({
      state = "error",
      busy = false,
      message = noctalia.tr("error.command-failed"),
    })
  end
end

local function toggle()
  if actionInFlight then
    return
  end
  if not noctalia.commandExists("warp-cli") then
    refreshStatus()
    refreshDetails()
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.cli-missing"))
    return
  end

  local command = if status.state == "connected" or status.state == "connecting" then "disconnect" else "connect"
  local pendingState = if command == "connect" then "connecting" else "disconnecting"

  actionInFlight = true
  patchStatus({
    state = pendingState,
    available = true,
    busy = true,
    message = "",
  })

  local accepted = noctalia.runAsync(`{CLI} {command}`, function(result)
    actionInFlight = false
    local decoded = noctalia.json.decode(result.stdout or "")
    local failed = result.exitCode ~= 0 or (type(decoded) == "table" and (decoded.error ~= nil or decoded.code ~= nil))

    if failed then
      local message = commandError(result, decoded)
      patchStatus({ state = "error", busy = false, message = message })
      noctalia.notifyError(noctalia.tr("title"), message)
      return
    end

    refreshStatus()
  end, 15000)
  if not accepted then
    actionInFlight = false
    patchStatus({
      state = "error",
      busy = false,
      message = noctalia.tr("error.command-failed"),
    })
  end
end

noctalia.setUpdateInterval(POLL_INTERVAL_MS)

noctalia.state.watch("warp.command", function(command)
  local action = if type(command) == "table" then command.action else command
  if action == "toggle" then
    toggle()
  elseif action == "refresh" then
    refreshStatus()
    refreshDetails()
  elseif action == "set-mode" and type(command) == "table" then
    setMode(command.mode)
  end
end)

function update()
  refreshStatus()
  refreshDetails()
end

function onIpc(event, _payload)
  if event == "toggle" then
    toggle()
  elseif event == "refresh" or event == "status" then
    refreshStatus()
    refreshDetails()
  elseif event == "set-mode" then
    setMode(_payload)
  end
end

refreshStatus()
refreshDetails()
