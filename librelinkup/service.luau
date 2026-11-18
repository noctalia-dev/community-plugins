--!nonstrict

local VERSION = "4.16.0"
local BASE_URL = "https://api.libreview.io"
local STATE_KEY = "librelinkup_status"
local COMMAND_KEY = "librelinkup_command"

local busy = false
local refreshAgain = false
local session = {
  baseUrl = BASE_URL,
  token = "",
  accountId = "",
}

local status = {
  loading = false,
  error = "",
  glucose = nil,
  arrow = "",
  timestamp = "",
  lowThreshold = 70,
  highThreshold = 180,
}

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function publish()
  status.lowThreshold = tonumber(noctalia.getConfig("low_threshold")) or 70
  status.highThreshold = tonumber(noctalia.getConfig("high_threshold")) or 180
  noctalia.state.set(STATE_KEY, status)
end

local function setError(message)
  status.error = message or ""
  status.loading = false
  publish()
end

local function jsonString(value)
  local text = tostring(value)
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\r", "\\r")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\t", "\\t")
  return '"' .. text .. '"'
end

local function encodeLoginBody(email, password)
  return "{" .. '"email":' .. jsonString(email) .. ',"password":' .. jsonString(password) .. "}"
end

local function credentials()
  return trim(noctalia.getConfig("email")), tostring(noctalia.getConfig("password") or "")
end

local function apiHeaders(extra)
  local headers = {
    "User-Agent: LibreLinkUp/" .. VERSION .. " (Android)",
    "product: llu.android",
    "version: " .. VERSION,
    "cache-control: no-cache",
    "pragma: no-cache",
  }
  if type(extra) == "table" then
    for _, header in ipairs(extra) do
      table.insert(headers, header)
    end
  end
  return headers
end

local function decodeJson(body)
  local payload, decodeError = noctalia.json.decode(body or "")
  if payload == nil then
    return nil, decodeError or noctalia.tr("error.parse_failed")
  end
  return payload
end

local function httpSuccess(response)
  if type(response) ~= "table" or response.ok ~= true then
    return false
  end
  local code = tonumber(response.status) or 0
  return code >= 200 and code < 300
end

local function apiMessage(payload, fallback, httpCode)
  if type(payload) == "table" then
    if type(payload.message) == "string" and payload.message ~= "" then
      return payload.message
    end
    if type(payload.error) == "table" and type(payload.error.message) == "string" then
      return payload.error.message
    end
  end
  return fallback .. " (HTTP " .. tostring(httpCode or 0) .. ")"
end

local function parseApiResponse(response, fallback)
  local httpCode = tonumber(response.status) or 0
  if not httpSuccess(response) then
    local payload = decodeJson(response.body)
    return nil, apiMessage(payload, fallback, httpCode), httpCode
  end

  local payload, decodeError = decodeJson(response.body)
  if payload == nil then
    return nil, decodeError, httpCode
  end
  if tonumber(payload.status) ~= 0 then
    return nil, apiMessage(payload, fallback, httpCode), httpCode
  end
  return payload, nil, httpCode
end

local function isAuthError(httpCode)
  return httpCode == 401 or httpCode == 403
end

local function field(tableValue, ...)
  if type(tableValue) ~= "table" then
    return nil
  end
  for index = 1, select("#", ...) do
    local key = select(index, ...)
    local value = tableValue[key]
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function firstEntry(data)
  if type(data) ~= "table" then
    return nil
  end
  if type(data[1]) == "table" then
    return data[1]
  end
  for _, entry in pairs(data) do
    if type(entry) == "table" then
      return entry
    end
  end
  return nil
end

local function trendArrow(trend)
  if trend == 1 then return "↓" end
  if trend == 2 then return "↘" end
  if trend == 3 then return "→" end
  if trend == 4 then return "↗" end
  if trend == 5 then return "↑" end
  return "?"
end

local function resetSession()
  session.baseUrl = BASE_URL
  session.token = ""
  session.accountId = ""
end

local function httpRequest(options, callback)
  local accepted = noctalia.http(options, callback)
  if not accepted then
    callback({ ok = false, status = 0, body = "" })
  end
end

local function loginRequest(callback)
  local email, password = credentials()
  if email == "" or password == "" then
    callback(nil, noctalia.tr("error.missing_credentials"))
    return
  end

  httpRequest({
    url = session.baseUrl .. "/llu/auth/login",
    method = "POST",
    headers = apiHeaders({ "Content-Type: application/json" }),
    body = encodeLoginBody(email, password),
  }, function(response)
    local payload, loginError, httpCode = parseApiResponse(response, noctalia.tr("error.login_failed"))
    if loginError ~= nil then
      callback(nil, loginError, httpCode)
      return
    end

    local data = payload.data
    if type(data) == "table" and (data.redirect == true or data.redirect == "true") and type(data.region) == "string" and data.region ~= "" then
      session.baseUrl = "https://api-" .. data.region:lower() .. ".libreview.io"
      loginRequest(callback)
      return
    end

    callback(payload)
  end)
end

local function computeAccountId(userId, callback)
  local quoted = "'" .. userId:gsub("'", "'\\''") .. "'"
  local started = noctalia.runAsync("printf '%s' " .. quoted .. " | sha256sum | cut -d' ' -f1", function(result)
    local accountId = trim(result and result.stdout or "")
    if result and result.exitCode == 0 and #accountId == 64 then
      callback(accountId)
      return
    end
    callback(nil)
  end)
  if not started then
    callback(nil)
  end
end

local function establishSession(callback)
  if session.token ~= "" and session.accountId ~= "" then
    callback(true)
    return
  end

  loginRequest(function(payload, loginError)
    if loginError ~= nil then
      callback(false, loginError)
      return
    end

    local data = type(payload) == "table" and payload.data or nil
    local tokenField = field(data, "authTicket")
    local token = type(tokenField) == "table" and tokenField.token or tokenField
    local userId = field(field(data, "user"), "id")
    token = trim(token)
    userId = trim(userId)

    if token == "" or userId == "" then
      callback(false, noctalia.tr("error.login_failed"))
      return
    end

    computeAccountId(userId, function(accountId)
      if accountId == nil or accountId == "" then
        callback(false, noctalia.tr("error.account_id"))
        return
      end
      session.token = token
      session.accountId = accountId
      callback(true)
    end)
  end)
end

local function fetchGlucose(callback)
  httpRequest({
    url = session.baseUrl .. "/llu/connections",
    headers = apiHeaders({
      "Authorization: Bearer " .. session.token,
      "Account-Id: " .. session.accountId,
    }),
  }, function(response)
    local payload, fetchError, httpCode = parseApiResponse(response, noctalia.tr("error.connections_failed"))
    if fetchError ~= nil then
      callback(nil, fetchError, httpCode)
      return
    end

    local entry = firstEntry(payload.data)
    local measurement = field(entry, "glucoseMeasurement", "glucoseItem")
    if type(measurement) ~= "table" then
      callback(nil, noctalia.tr("error.no_measurement"), httpCode)
      return
    end

    callback(measurement)
  end)
end

local function applyMeasurement(measurement)
  local glucose = tonumber(field(measurement, "Value", "ValueInMgPerDl"))
  if glucose == nil then
    setError(noctalia.tr("error.no_measurement"))
    return
  end

  local trend = tonumber(field(measurement, "TrendArrow")) or 3

  status.loading = false
  status.error = ""
  status.glucose = glucose
  status.arrow = trendArrow(trend)
  status.timestamp = trim(field(measurement, "Timestamp", "FactoryTimestamp") or "")
  publish()
end

local refresh

local function finishRefresh()
  busy = false
  status.loading = false
  if refreshAgain then
    refreshAgain = false
    refresh()
  end
end

refresh = function()
  if busy then
    refreshAgain = true
    return
  end

  busy = true
  status.loading = true
  status.error = ""
  publish()

  establishSession(function(ok, sessionError)
    if not ok then
      resetSession()
      setError(sessionError or noctalia.tr("error.login_failed"))
      finishRefresh()
      return
    end

    fetchGlucose(function(measurement, glucoseError, httpCode)
      if glucoseError ~= nil then
        if isAuthError(httpCode) then
          resetSession()
        end
        setError(glucoseError)
        finishRefresh()
        return
      end

      applyMeasurement(measurement)
      finishRefresh()
    end)
  end)
end

function update()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 300
  noctalia.setUpdateInterval(math.max(60, seconds) * 1000)
  if busy then
    refreshAgain = true
    return
  end
  refresh()
end

function onConfigChanged()
  resetSession()
  update()
end

function onIpc(event)
  if event == "refresh" then
    refresh()
  end
end

noctalia.state.watch(COMMAND_KEY, function(command)
  if type(command) == "table" and command.action == "refresh" then
    refresh()
  end
end)

publish()
refresh()
