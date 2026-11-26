--!nonstrict
-- Beszel Desktop singleton service.
-- Bridges `beszel-ctl watch --raw --reconnect` into shared `noctalia.state`
-- so multiple bar widgets and the panel share one local Unix socket stream.

local STATE_KEY = "beszel.data"

local connection = {
  state = "connecting",
  since_ms = noctalia.nowMs(),
  reconnect_attempts = 0,
}
local systems = {}
local historyBySystem = {}
local historyCapacity = 60
local hubUrl = nil
local activeCommand = nil
local ctlMissing = false

local function shellQuote(str)
  return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

local function resolveCtlBinary()
  local configured = noctalia.string.trim(noctalia.getConfig("ctl_path") or "")
  if configured == "" then
    configured = "beszel-ctl"
  end
  if string.find(configured, "/", 1, true) ~= nil then
    local expanded = noctalia.expandPath(configured)
    return expanded, noctalia.fileExists(expanded)
  end
  if noctalia.commandExists(configured) then
    return configured, true
  end
  local localBin = noctalia.expandPath("~/.local/bin/" .. configured)
  if noctalia.fileExists(localBin) then
    return localBin, true
  end
  local cargoBin = noctalia.expandPath("~/.cargo/bin/" .. configured)
  if noctalia.fileExists(cargoBin) then
    return cargoBin, true
  end
  return configured, false
end

local function buildStreamCommand(binPath)
  local parts = { shellQuote(binPath) }
  local socketPath = noctalia.string.trim(noctalia.getConfig("socket_path") or "")
  if socketPath ~= "" then
    table.insert(parts, "--socket")
    table.insert(parts, shellQuote(noctalia.expandPath(socketPath)))
  end
  table.insert(parts, "watch")
  table.insert(parts, "--raw")
  table.insert(parts, "--reconnect")
  return table.concat(parts, " ")
end

local function publish()
  noctalia.state.set(STATE_KEY, {
    connection = connection,
    hubUrl = hubUrl,
    systems = systems,
    historyBySystem = historyBySystem,
    historyCapacity = historyCapacity,
    ctlMissing = ctlMissing,
    updatedAtMs = noctalia.nowMs(),
  })
end

local function applySnapshot(msg)
  connection = msg.connection or connection
  if type(msg.hub_url) == "string" and msg.hub_url ~= "" then
    hubUrl = msg.hub_url
  end
  local nextSystems = {}
  local nextHistory = {}
  local cap = historyCapacity

  if type(msg.systems) == "table" then
    for _, entry in ipairs(msg.systems) do
      if type(entry) == "table" and type(entry.system) == "table" then
        table.insert(nextSystems, entry.system)
        local samples = {}
        if type(entry.samples) == "table" then
          for _, s in ipairs(entry.samples) do
            table.insert(samples, s)
          end
        end
        nextHistory[entry.system.id] = samples
        if tonumber(entry.history_capacity) ~= nil then
          cap = math.max(1, math.floor(tonumber(entry.history_capacity) or 60))
        end
      end
    end
  end

  systems = nextSystems
  historyBySystem = nextHistory
  historyCapacity = cap
  publish()
end

local function applySample(systemId, sample)
  if type(systemId) ~= "string" or type(sample) ~= "table" then
    return
  end
  local list = historyBySystem[systemId]
  if type(list) ~= "table" then
    list = {}
    historyBySystem[systemId] = list
  end
  local prev = list[#list]
  if type(prev) == "table" then
    prev.cpu_cores = nil
    prev.containers = nil
    prev.unhealthy_pools = nil
    prev.extra_disks = nil
  end
  table.insert(list, sample)
  while #list > historyCapacity do
    table.remove(list, 1)
  end
  if type(connection) == "table" then
    connection.last_sample_ms = sample.timestamp_ms
  end
  publish()
end

local function onRelayLine(rawLine)
  local trimmed = noctalia.string.trim(rawLine or "")
  if trimmed == "" then
    return
  end
  local msg = noctalia.json.decode(trimmed)
  if type(msg) ~= "table" then
    return
  end

  if msg.type == "snapshot" then
    applySnapshot(msg)
  elseif msg.type == "sample" then
    applySample(msg.system_id, msg.sample)
  elseif msg.type == "connection" and type(msg.connection) == "table" then
    connection = msg.connection
    publish()
  elseif msg.type == "systems_changed" and type(msg.systems) == "table" then
    systems = msg.systems
    publish()
  end
end

local function startStream()
  local binPath, found = resolveCtlBinary()
  if not found then
    ctlMissing = true
    activeCommand = nil
    connection = {
      state = "disconnected",
      since_ms = noctalia.nowMs(),
      last_error = nil,
      reconnect_attempts = 0,
    }
    noctalia.setUpdateInterval(5000)
    publish()
    return
  end

  ctlMissing = false
  local cmd = buildStreamCommand(binPath)
  activeCommand = cmd
  noctalia.setUpdateInterval(60000)
  local ok = noctalia.runStream(cmd, onRelayLine)
  if not ok then
    connection = {
      state = "disconnected",
      since_ms = noctalia.nowMs(),
      last_error = "Failed to launch beszel-ctl",
      reconnect_attempts = 0,
    }
    publish()
  end
end

function update()
  if ctlMissing then
    local _, found = resolveCtlBinary()
    if found then
      startStream()
    end
  end
end

function onConfigChanged()
  local binPath, found = resolveCtlBinary()
  if not found then
    if not ctlMissing then
      startStream()
    end
    return
  end
  local nextCmd = buildStreamCommand(binPath)
  if ctlMissing or nextCmd ~= activeCommand then
    startStream()
  end
end

function onResume()
  -- beszel-relay handles wake reconnects over the Unix socket; refresh timestamp so
  -- widgets immediately reflect staleness until fresh post-wake samples arrive.
  publish()
end

publish()
startStream()
