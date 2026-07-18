--!nonstrict

local haUrlRaw = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local MANAGED_ENTITIES_FILE = "managed_entities.json"

local function getCleanUrl()
  if type(haUrlRaw) ~= "string" then return "" end
  return (haUrlRaw:gsub("/$", ""))
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
local CONNECTED_POLL_INTERVAL_MS = 30000
local RECONNECT_POLL_INTERVAL_MS = 1000
local retryCount = 0
local maxRetriesNotified = false
local suspended = false
local connectionRequestInFlight = false

local function getCleanToken()
  if type(haToken) ~= "string" then return "" end
  return noctalia.string.trim(haToken)
end

local function syncUpdateInterval()
  if status == "connected" and sseActive then
    noctalia.setUpdateInterval(CONNECTED_POLL_INTERVAL_MS)
  else
    noctalia.setUpdateInterval(RECONNECT_POLL_INTERVAL_MS)
  end
end

local function isConfigured()
  local url = getCleanUrl()
  return url and url ~= "" and getCleanToken() ~= ""
end

local function haRequest(endpoint, method, body, callback)
  if not isConfigured() then return false end

  local url = getCleanUrl() .. endpoint
  local cleanToken = getCleanToken()

  local jsonBody
  if body then
    jsonBody = noctalia.json.encode(body)
  end

  local launched = noctalia.http({
      url = url,
      method = method,
      body = jsonBody,
      headers = {
        "Authorization: Bearer " .. cleanToken,
        "Content-Type: application/json",
      }
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

  return launched

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

local function updateEntity(entityId, newState)
  if #entities > 0 then
    local found = false
    for _, id in ipairs(entities) do
      if id == entityId then
        found = true
        break
      end
    end
    if not found then return end
  end

  local processed = processEntity(newState)
  if processed then
    entityStates[entityId] = processed
    noctalia.state.set("entities", entityStates)

    local count = 0
    for _ in pairs(entityStates) do
      count = count + 1
    end
    noctalia.state.set("entity_count", count)
  end
end

-- HA embeds event_type inside the data JSON rather than a separate SSE "event:" field
local currentEvent = {
    data = "",
    event = "",
}

local function tryDispatch()
  if not currentEvent.data then return end
  local parsed = noctalia.json.decode(currentEvent.data)
  if not parsed then return end
  local evType = currentEvent.event or parsed.event_type
  if evType ~= "state_changed" then return end
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
      local evType = currentEvent.event or parsed.event_type
      if evType == "state_changed" then
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

local function fetchInitialStates()
  if not isConfigured() or suspended or connectionRequestInFlight then return end
  connectionRequestInFlight = true
  local launched = haRequest("/api/states", "GET", nil, function(res)
    connectionRequestInFlight = false

    if not res.body or res.body == "" then
      noctalia.log("Empty response body from /api/states")
      status = "disconnected"
      noctalia.state.set("connection_status", status)
      syncUpdateInterval()
      return
    end

    if not res.ok or res.status == 401 or res.body:match("^401") or res.body:match("Unauthorized") then
      status = "auth_failed"
      noctalia.log("Authentication failed - check your token")
      noctalia.notifyError(noctalia.tr("notifications.auth_failed"))
      noctalia.state.set("connection_status", status)
      syncUpdateInterval()
      return
    end

    if not res.ok or (res.status and res.status >= 400) then
      status = "disconnected"
      noctalia.log("HTTP request failed: status " .. (res.status or "unknown"))
      noctalia.state.set("connection_status", status)
      syncUpdateInterval()
      return
    end

    local allStates, err = noctalia.json.decode(res.body)
    if not allStates then
      noctalia.log("Failed to parse states: " .. (err or "unknown error"))
      status = "disconnected"
      noctalia.state.set("connection_status", status)
      syncUpdateInterval()
      return
    end

    status = "connected"
    noctalia.state.set("connection_status", status)
    retryCount = 0
    maxRetriesNotified = false
    suspended = false

    entityStates = {}
    local count = 0

    for _, state in ipairs(allStates) do
      if #entities == 0 then break end
      for _, entityId in ipairs(entities) do
        if state.entity_id == entityId then
          entityStates[entityId] = processEntity(state)
          count = count + 1
          break
        end
      end
    end

    noctalia.state.set("entities", entityStates)
    noctalia.state.set("entity_count", count)

    if status == "connected" then
      if not startSSEStream() then
        status = "disconnected"
        noctalia.state.set("connection_status", status)
        syncUpdateInterval()
      else
        syncUpdateInterval()
      end
    end
  end)

  if not launched then
    connectionRequestInFlight = false
    status = "disconnected"
    noctalia.state.set("connection_status", status)
    syncUpdateInterval()
  end
end

function startSSEStream()
  if suspended then return false end
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

    if suspended then return end

    if result and result.ok and result.status == 401 then
      status = "auth_failed"
      noctalia.log("Authentication failed - check your token")
      noctalia.notifyError(noctalia.tr("notifications.auth_failed"))
      noctalia.state.set("connection_status", status)
      syncUpdateInterval()
      return
    end

    status = "disconnected"
    noctalia.log("SSE stream closed")
    noctalia.state.set("connection_status", status)
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
    -- Just refetch a fresh snapshot over HTTP. Do NOT touch sseActive here:
    -- the running stream (if any) is untouched by this, and forcing the
    -- flag false would bypass startSSEStream()'s duplicate guard and spawn
    -- a second stream on top of one that's still alive.
    fetchInitialStates()
  elseif cmd == "reload_entities" then
    local override = noctalia.state.get("entities_override")
    if type(override) == "table" then
      entities = override
    else
      entities = loadManagedEntities()
    end
    -- Entity filtering happens client-side in updateEntity(), so the
    -- existing stream keeps working for the new entity list as-is.
    -- The initial snapshot needs refetching, though, to account for any
    -- entities that were removed from the filter. See the note above for why
    -- sseActive must not be forced here.
    fetchInitialStates()
  end
end)

noctalia.state.watch("panel_open_signal", function(value)
  if value then
    retryCount = 0
    maxRetriesNotified = false
    suspended = false
  end
end)

function update()
  syncUpdateInterval()

  if not isConfigured() then
    status = "unconfigured"
    noctalia.state.set("connection_status", status)
    sseActive = false
    return
  end

  if suspended then
    return
  end

  if status == "disconnected" then
    retryCount = retryCount + 1
    if retryCount >= MAX_RECONNECT_RETRIES then
      if not maxRetriesNotified then
        maxRetriesNotified = true
        noctalia.notifyError(noctalia.tr("notifications.reconnect_failed", { count = MAX_RECONNECT_RETRIES }))
      end
        suspended = true
        status = "disconnected"
        noctalia.state.set("connection_status", status)
        return
      end

    status = "connecting"
    noctalia.state.set("connection_status", status)
    fetchInitialStates()
  end
end

function onExit()
  if streamHandle then
    streamHandle.stop()
    streamHandle = nil
  end
  sseActive = false
end

noctalia.state.set("connection_status", status)
noctalia.state.set("entity_count", 0)
noctalia.state.set("entities", {})

if isConfigured() then
  status = "connecting"
  noctalia.state.set("connection_status", status)
  fetchInitialStates()
end
