--!nonstrict

local haUrlRaw = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local MANAGED_ENTITIES_FILE = "managed_entities.json"

local function getCleanUrl()
  if type(haUrlRaw) ~= "string" then return "" end
  return (haUrlRaw:gsub("/$", ""))
end

local function getCleanToken()
  if type(haToken) ~= "string" then return "" end
  return noctalia.string.trim(haToken)
end

local function isConfigured()
  return getCleanUrl() ~= "" and getCleanToken() ~= ""
end

local function loadManagedEntities()
  local dataDir, dirErr = noctalia.pluginDataDir()
  if not dataDir then
    noctalia.log("Cannot resolve plugin data dir: " .. (dirErr or "unknown"))
    return {}
  end

  local data = noctalia.readFile(dataDir .. "/" .. MANAGED_ENTITIES_FILE)
  if data and data ~= "" then
    local parsed = noctalia.json.decode(data)
    if type(parsed) == "table" then return parsed end
  end
  return {}
end

local entities = loadManagedEntities()

local status = "unconfigured"
local entityStates = {}
local sseActive = false
local streamHandle = nil

local MAX_RECONNECT_RETRIES = 10
local CONNECTED_POLL_INTERVAL_MS = 1000
local RECONNECT_POLL_INTERVAL_MS = 1000
local BACKOFF_POLL_INTERVAL_MS = 60000
-- The host caps an async request at 30s transfer + 10s connect, so a callback still
-- missing after 35s is genuinely lost rather than slow.
local REQUEST_TIMEOUT_SECONDS = 35
-- The host allows 8 async HTTP callbacks per runtime; leave headroom.
local MAX_SNAPSHOT_REQUESTS_IN_FLIGHT = 4
local ENTITY_FLUSH_INTERVAL_SECONDS = 0.2

local retryCount = 0
local maxRetriesNotified = false
local authFailureNotified = false
local backoff = false
local connectionRequestInFlight = false
local requestStartedAt = nil

local entitiesDirty = false
local lastEntityFlush = 0

-- Initial-snapshot bookkeeping. A round is identified by snapshotToken so late
-- callbacks from a superseded round are ignored instead of corrupting the new one.
local snapshotToken = 0
local snapshotActive = false
local snapshotStartedAt = 0
local snapshotQueue = {}
local snapshotPending = {}
local snapshotInFlight = 0

local function syncUpdateInterval()
  if status == "connected" and sseActive then
    noctalia.setUpdateInterval(CONNECTED_POLL_INTERVAL_MS)
  elseif backoff then
    noctalia.setUpdateInterval(BACKOFF_POLL_INTERVAL_MS)
  else
    noctalia.setUpdateInterval(RECONNECT_POLL_INTERVAL_MS)
  end
end

-- The single place `status` changes: every transition is published and logged here,
-- so the service can never sit in a state nothing knows how to leave.
local function setStatus(next, reason)
  if status == next then return end
  status = next
  noctalia.state.set("connection_status", status)
  noctalia.log("connection status -> " .. status .. (reason and (" (" .. reason .. ")") or ""))

  -- Reconnect attempts keep running while the token is bad, so the notification is
  -- tied to discovering the failure, not to every attempt that rediscovers it.
  if status == "connected" then
    authFailureNotified = false
  elseif status == "auth_failed" and not authFailureNotified then
    authFailureNotified = true
    noctalia.notifyError(noctalia.tr("notifications.auth_failed"))
  end

  syncUpdateInterval()
end

local function haRequest(endpoint, method, body, callback)
  if not isConfigured() then return false end

  local url = getCleanUrl() .. endpoint
  local cleanToken = getCleanToken()

  local jsonBody
  if body then
    jsonBody = noctalia.json.encode(body)
  end

  local headers = {
    "Authorization: Bearer " .. cleanToken,
  }
  -- Only advertise a JSON body when we actually send one.
  if jsonBody then
    table.insert(headers, "Content-Type: application/json")
  end

  return noctalia.http({
      url = url,
      method = method,
      body = jsonBody,
      headers = headers,
  }, function(response: HttpResponse)
      if not response then
        callback({ ok = false, status = 0, body = "No response" })
        return
      end

      callback({
        ok = response.status >= 200 and response.status < 300,
        status = response.status,
        body = response.body
      })
  end)
end

local function supportsColorMode(modes, targets)
  if type(modes) ~= "table" then return false end
  for _, mode in ipairs(modes) do
    for _, target in ipairs(targets) do
      if mode == target then return true end
    end
  end
  return false
end

local function processEntity(state)
  if not state then return nil end

  local attrs = state.attributes or {}
  local modes = attrs.supported_color_modes or {}

  -- stored as mireds for the panel slider
  local colorTemp = -1
  if attrs.color_temp_kelvin and attrs.color_temp_kelvin > 0 then
    colorTemp = math.floor(1000000 / attrs.color_temp_kelvin + 0.5)
  elseif attrs.color_temp and attrs.color_temp > 0 then
    colorTemp = attrs.color_temp
  end

  local currentColor = ""
  if type(attrs.rgb_color) == "table" and #attrs.rgb_color == 3 then
    currentColor = attrs.rgb_color[1] .. "," .. attrs.rgb_color[2] .. "," .. attrs.rgb_color[3]
  end

  return {
    entity_id = state.entity_id,
    state = state.state,
    friendly_name = attrs.friendly_name or state.entity_id,
    domain = state.entity_id:match("^([^.]+)"),
    unit = attrs.unit_of_measurement or "",
    brightness = attrs.brightness or -1,
    color_temp = colorTemp,
    hue = (type(attrs.hs_color) == "table") and (attrs.hs_color[1] or 0) or 0,
    current_color = currentColor,
    supports_brightness = supportsColorMode(modes, {"brightness","color_temp","hs","xy","rgb","rgbw","rgbww"}),
    supports_color_temp = supportsColorMode(modes, {"color_temp"}),
    supports_rgb = supportsColorMode(modes, {"hs","xy","rgb","rgbw","rgbww"}),
  }
end

local function publishEntities()
  local count = 0
  for _ in pairs(entityStates) do
    count = count + 1
  end
  noctalia.state.set("entities", entityStates)
  noctalia.state.set("entity_count", count)
  entitiesDirty = false
  lastEntityFlush = os.clock()
end

-- Every publish re-encodes the whole map here and is re-decoded by each watcher
-- (panel, widget, four shortcuts), so a burst of events is coalesced into one push
-- per ENTITY_FLUSH_INTERVAL_SECONDS; update() flushes whatever is left over.
local function markEntitiesDirty()
  entitiesDirty = true
  if (os.clock() - lastEntityFlush) >= ENTITY_FLUSH_INTERVAL_SECONDS then
    publishEntities()
  end
end

local function isManaged(entityId)
  for _, id in ipairs(entities) do
    if id == entityId then return true end
  end
  return false
end

local function updateEntity(entityId, newState)
  -- An empty managed list means nothing is monitored: keeping every entity HA
  -- reports would grow this map without bound and re-encode it on every event.
  if not isManaged(entityId) then return end

  local processed = processEntity(newState)
  if not processed then return end

  entityStates[entityId] = processed
  if snapshotActive then
    -- keep an in-flight snapshot round from overwriting fresher live data
    snapshotPending[entityId] = processed
  end
  markEntitiesDirty()
end

-- HA embeds event_type inside the data JSON rather than a separate SSE "event:" field
local currentEvent = {
    data = "",
    event = "",
}

-- The SSE "event:" field, or HA's embedded event_type when there is none. An empty
-- string is truthy in Luau, so it has to be rejected explicitly - otherwise the
-- freshly initialised currentEvent.event masks event_type and the first event of
-- every stream is dropped.
local function eventTypeOf(parsed)
  if currentEvent.event and currentEvent.event ~= "" then
    return currentEvent.event
  end
  return parsed.event_type
end

local function tryDispatch()
  if not currentEvent.data then return end
  local parsed = noctalia.json.decode(currentEvent.data)
  if not parsed then return end
  if eventTypeOf(parsed) ~= "state_changed" then return end
  local inner = parsed.data or {}
  if inner.entity_id and inner.new_state then
    updateEntity(inner.entity_id, inner.new_state)
  end
end

local function processSSELine(line)
  if line == "" then
    tryDispatch()
    currentEvent = {}
  elseif line:match("^event:") then
    if currentEvent.data then tryDispatch() end
    currentEvent = { event = line:match("^event:%s*(.+)") or "" }
  elseif line:match("^data:") then
    local data = line:match("^data:%s*(.+)") or ""
    local parsed = noctalia.json.decode(data)
    if parsed then
      if eventTypeOf(parsed) == "state_changed" then
        local inner = parsed.data or {}
        if inner.entity_id and inner.new_state then
          updateEntity(inner.entity_id, inner.new_state)
          currentEvent = {}
          return
        end
      end
    end
    if currentEvent.data and currentEvent.data ~= "" then
      currentEvent.data = currentEvent.data .. "\n" .. data
    else
      currentEvent.data = data
    end
  end
end

local pumpSnapshot
local finishSnapshot
local fetchSnapshot
local startSSEStream
local connect

function finishSnapshot()
  snapshotActive = false
  -- invalidate any straggler from this round
  snapshotToken = snapshotToken + 1

  -- Rebuild from the monitored list so entities dropped from it disappear, and fall
  -- back to what we already knew for any entity whose fetch failed this round.
  local merged = {}
  for _, id in ipairs(entities) do
    merged[id] = snapshotPending[id] or entityStates[id]
  end
  entityStates = merged
  snapshotPending = {}
  snapshotQueue = {}
  publishEntities()
end

function pumpSnapshot()
  if not snapshotActive then return end

  local token = snapshotToken

  while snapshotInFlight < MAX_SNAPSHOT_REQUESTS_IN_FLIGHT and #snapshotQueue > 0 do
    local entityId = snapshotQueue[1]
    snapshotInFlight = snapshotInFlight + 1

    -- One entity per request keeps every callback's decode tiny, regardless of how
    -- many entities the Home Assistant instance has.
    local launched = haRequest("/api/states/" .. entityId, "GET", nil, function(res)
      if token ~= snapshotToken then return end
      snapshotInFlight = snapshotInFlight - 1

      if res.status == 404 then
        noctalia.log("Entity not found in Home Assistant: " .. entityId)
      elseif res.ok and res.body and res.body ~= "" then
        local state = noctalia.json.decode(res.body)
        if type(state) == "table" and state.entity_id then
          snapshotPending[entityId] = processEntity(state)
        end
      end

      pumpSnapshot()
      if snapshotActive and snapshotInFlight == 0 and #snapshotQueue == 0 then
        finishSnapshot()
      end
    end)

    if not launched then
      -- Out of async slots (or unconfigured); retry from the next tick.
      snapshotInFlight = snapshotInFlight - 1
      return
    end

    table.remove(snapshotQueue, 1)
  end

  if snapshotInFlight == 0 and #snapshotQueue == 0 then
    finishSnapshot()
  end
end

function fetchSnapshot()
  snapshotToken = snapshotToken + 1
  snapshotActive = true
  snapshotStartedAt = os.clock()
  snapshotInFlight = 0
  snapshotPending = {}
  snapshotQueue = {}
  for _, id in ipairs(entities) do
    if type(id) == "string" and id ~= "" then
      table.insert(snapshotQueue, id)
    end
  end
  pumpSnapshot()
end

function connect()
  if not isConfigured() or connectionRequestInFlight then return end

  requestStartedAt = os.clock()
  connectionRequestInFlight = true

  -- GET /api/ answers with {"message": "API running."}: enough to tell unreachable,
  -- unauthorized and healthy apart, and small enough that the callback stays well
  -- inside the host's per-callback CPU budget on any instance.
  local launched = haRequest("/api/", "GET", nil, function(res)
    connectionRequestInFlight = false
    requestStartedAt = nil

    -- status 0 = no HTTP response at all (couldn't connect / DNS / timeout): the
    -- server is unreachable, which is a distinct case from an auth or HTTP error.
    if res.status == 0 then
      noctalia.log("Cannot reach Home Assistant (connection failed)")
      setStatus("unreachable", "transport failure")
      return
    end

    if res.status == 401 or res.status == 403 then
      setStatus("auth_failed", "http " .. tostring(res.status))
      return
    end

    if not res.ok then
      noctalia.log("Home Assistant API probe failed: status " .. tostring(res.status))
      setStatus("disconnected", "http " .. tostring(res.status))
      return
    end

    retryCount = 0
    maxRetriesNotified = false
    backoff = false
    setStatus("connected", "api reachable")

    if not startSSEStream() then
      setStatus("disconnected", "stream failed to start")
      return
    end

    -- Entity states are pulled one by one after the connection is established, so a
    -- slow or failing snapshot can never hold the connection status hostage.
    fetchSnapshot()
    syncUpdateInterval()
  end)

  if not launched then
    connectionRequestInFlight = false
    requestStartedAt = nil
    setStatus("unreachable", "request not launched")
  end
end

function startSSEStream()
  if sseActive then return true end

  local cleanToken = getCleanToken()
  if cleanToken == "" then
    return false
  end

  local url = getCleanUrl() .. "/api/stream?restrict=state_changed"

  noctalia.log("Starting SSE stream")
  currentEvent = { data = "", event = "" }

  local handle
  handle = noctalia.httpStream({
    url = url,
    headers = {
      "Accept: text/event-stream",
      "Authorization: Bearer " .. cleanToken,
    },
  }, function(line)
    processSSELine(line)
  end, function(result)
    if streamHandle ~= handle then return end

    streamHandle = nil
    sseActive = false
    currentEvent = {}

    if result and (result.status == 401 or result.status == 403) then
      setStatus("auth_failed", "stream http " .. tostring(result.status))
      return
    end

    -- The status is worth logging: a stream that closes with 404 means this HA does
    -- not serve /api/stream, which looks the same from the outside as a flaky link.
    noctalia.log("SSE stream closed (status " .. tostring(result and result.status or 0) .. ")")
    setStatus("disconnected", "stream closed")
    syncUpdateInterval()
  end)

  if not handle then
    noctalia.log("Failed to start SSE stream")
    return false
  end

  streamHandle = handle
  sseActive = true
  syncUpdateInterval()
  return true
end

noctalia.state.watch("command", function(cmd)
  if cmd == "refresh" then
    -- Just re-probe and re-snapshot. Do NOT touch sseActive here: the running stream
    -- (if any) is untouched by this, and forcing the flag false would bypass
    -- startSSEStream()'s duplicate guard and spawn a second stream on top of one
    -- that's still alive.
    if status == "connected" then
      if not sseActive then startSSEStream() end
      fetchSnapshot()
    else
      connect()
    end
  elseif cmd == "reload_entities" then
    local override = noctalia.state.get("entities_override")
    if type(override) == "table" then
      entities = override
    else
      entities = loadManagedEntities()
    end
    -- Entity filtering happens client-side in updateEntity(), so the existing stream
    -- keeps working for the new entity list as-is. The snapshot needs refetching to
    -- pick up newly monitored entities and drop removed ones.
    if status == "connected" then
      fetchSnapshot()
    else
      connect()
    end
  end
end)

noctalia.state.watch("panel_open_signal", function(value)
  if value then
    retryCount = 0
    maxRetriesNotified = false
    backoff = false
    syncUpdateInterval()
  end
end)

function update()
  if not isConfigured() then
    setStatus("unconfigured", "no url or token")
    sseActive = false
    syncUpdateInterval()
    return
  end

  if entitiesDirty and (os.clock() - lastEntityFlush) >= ENTITY_FLUSH_INTERVAL_SECONDS then
    publishEntities()
  end

  -- Resume a snapshot round that ran out of async slots mid-flight, and close out one
  -- whose callback never came back so it can't wedge the round forever.
  if snapshotActive then
    if (os.clock() - snapshotStartedAt) > REQUEST_TIMEOUT_SECONDS then
      noctalia.log("Entity snapshot timed out; publishing what arrived")
      finishSnapshot()
    else
      pumpSnapshot()
    end
  end

  -- A callback the host dropped or aborted (an overrun CPU budget kills it between
  -- VM instructions) would otherwise leave the request flag stuck set forever. A
  -- missing timestamp counts as expired: erring towards one extra probe is always
  -- better than never probing again.
  if connectionRequestInFlight and (os.clock() - (requestStartedAt or 0)) > REQUEST_TIMEOUT_SECONDS then
    connectionRequestInFlight = false
    requestStartedAt = nil
    setStatus("disconnected", "request timed out")
  end

  -- "connected" means the probe answered AND the event stream is up. If a callback
  -- died between the two, this puts the service back on the reconnect path.
  if status == "connected" and not sseActive then
    setStatus("disconnected", "stream missing")
  end

  -- The store is what the panel, widget and shortcuts read, so let it converge on
  -- our status if a publish was ever dropped mid-callback.
  if noctalia.state.get("connection_status") ~= status then
    noctalia.state.set("connection_status", status)
  end

  -- Anything that is not a live connection is retried, including a "connecting" whose
  -- callback never completed. There is deliberately no state this can't leave.
  if status ~= "connected" and not connectionRequestInFlight then
    retryCount = retryCount + 1
    if retryCount >= MAX_RECONNECT_RETRIES and not backoff then
      -- After the initial burst of fast retries, fall back to a slow poll and keep
      -- trying, so the service reconnects on its own once HA is reachable again.
      backoff = true
      if not maxRetriesNotified then
        maxRetriesNotified = true
        -- A bad token already got its own, more accurate notification.
        if not authFailureNotified then
          noctalia.notifyError(noctalia.tr("notifications.reconnect_failed", { count = MAX_RECONNECT_RETRIES }))
        end
      end
    end

    setStatus("connecting", "attempt " .. tostring(retryCount))
    connect()
  end

  syncUpdateInterval()
end

function onExit()
  if streamHandle then
    streamHandle.stop()
    streamHandle = nil
  end
  sseActive = false
  snapshotActive = false
end

noctalia.state.set("connection_status", status)
noctalia.state.set("entity_count", 0)
noctalia.state.set("entities", {})

if isConfigured() then
  setStatus("connecting", "startup")
  connect()
end

syncUpdateInterval()
