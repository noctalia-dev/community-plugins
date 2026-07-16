--!nonstrict

local haUrl = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local function loadManagedEntities()
  local data = noctalia.readFile("managed_entities.json")
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

local MAX_RECONNECT_RETRIES = 10
local retryCount = 0
local maxRetriesNotified = false
local suspended = false

local function escapeShellArg(arg)
  return "'" .. arg:gsub("'", "'\\''" ) .. "'"
end

local function isConfigured()
  return haUrl and haUrl ~= "" and haToken and haToken ~= ""
end

local function haRequest(endpoint, method, body, callback)
  if not isConfigured() then return end

  if not noctalia.commandExists("curl") then
    noctalia.log("curl not found, cannot make HTTP requests")
    return
  end

  local url = haUrl .. endpoint
  local cleanToken = haToken:gsub("^%s+", ""):gsub("%s+$", "")

  local cmd = "curl -s -w '\nHTTP_STATUS:%{http_code}' -X " .. (method or "GET") ..
              " -H " .. escapeShellArg("Authorization: Bearer " .. cleanToken) ..
              " -H " .. escapeShellArg("Content-Type: application/json")

  if body then
    local jsonBody = noctalia.json.encode(body)
    cmd = cmd .. " -d " .. escapeShellArg(jsonBody)
  end

  cmd = cmd .. " " .. escapeShellArg(url)

  noctalia.runAsync(cmd, function(result)
    if not result then
      callback({ ok = false, status = 0, body = "No response" })
      return
    end

    local output = result.stdout or ""
    local statusMatch = output:match("HTTP_STATUS:(%d+)")
    local httpStatus = tonumber(statusMatch) or 0
    local body = output:gsub("\nHTTP_STATUS:%d+$", "")

    callback({
      ok = httpStatus >= 200 and httpStatus < 300,
      status = httpStatus,
      body = body
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
    currentEvent.data = (currentEvent.data or "") .. data
  elseif line:match("^id:") then
    lastEventId = line:match("^id:%s*(.+)") or ""
  end
end

local function fetchInitialStates()
  if suspended then return end
  haRequest("/api/states", "GET", nil, function(res)
    if not res.body or res.body == "" then
      noctalia.log("Empty response body from /api/states")
      status = "disconnected"
      noctalia.state.set("connection_status", status)
      return
    end

    if not res.ok or res.status == 401 or res.body:match("^401") or res.body:match("Unauthorized") then
      status = "auth_failed"
      noctalia.log("Authentication failed - check your token")
      noctalia.notifyError(noctalia.tr("notifications.auth_failed"))
      noctalia.state.set("connection_status", status)
      return
    end

    if not res.ok or (res.status and res.status >= 400) then
      status = "disconnected"
      noctalia.log("HTTP request failed: status " .. (res.status or "unknown"))
      noctalia.state.set("connection_status", status)
      return
    end

    local allStates, err = noctalia.json.decode(res.body)
    if not allStates then
      noctalia.log("Failed to parse states: " .. (err or "unknown error"))
      status = "disconnected"
      noctalia.state.set("connection_status", status)
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
      startSSEStream()
    end
  end)
end

function startSSEStream()
  if suspended then return end
  if sseActive then return end

  if not noctalia.commandExists("curl") then
    noctalia.log("curl not found, cannot use SSE")
    return
  end

  local url = haUrl .. "/api/stream?restrict=state_changed"
  local cmd = "curl -N -H " .. escapeShellArg("Authorization: Bearer " .. haToken) ..
              " -H " .. escapeShellArg("Accept: text/event-stream") ..
              " " .. escapeShellArg(url)

  noctalia.log("Starting SSE stream")
  sseActive = true

  noctalia.runStream(cmd, function(line)
    if line == nil then
      sseActive = false
      currentEvent = {}
      return
    end
    processSSELine(line)
  end)
end

noctalia.state.watch("command", function(cmd)
  if cmd == "refresh" then
    sseActive = false
    fetchInitialStates()
  elseif cmd == "reload_entities" then
    local override = noctalia.state.get("entities_override")
    if type(override) == "table" then
      entities = override
    else
      entities = loadManagedEntities()
    end
    sseActive = false
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
  noctalia.setUpdateInterval(30000)

  if not isConfigured() then
    status = "unconfigured"
    noctalia.state.set("connection_status", status)
    sseActive = false
    return
  end

  if suspended then
    return
  end

  if status ~= "connected" or not sseActive then
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

noctalia.state.set("connection_status", status)
noctalia.state.set("entity_count", 0)
noctalia.state.set("entities", {})

if isConfigured() then
  status = "connecting"
  noctalia.state.set("connection_status", status)
  fetchInitialStates()
end
