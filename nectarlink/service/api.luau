--!nonstrict
-- Auth and HTTP. Credentials stay in this module and request headers;
-- never publish them to UI state or pass them on a command line.
local M = {}

---@class NectarLinkCredentials
---@field token string
---@field port integer
---@field epoch integer

---@alias NectarLinkReply fun(ok: boolean, status: integer, data: table?, reason: string?)

local TOKEN_FILE = "~/.local/share/Nectarlink/api-token.json"
local statusErrors = { [0] = "api_unavailable", [401] = "unauthorized", [403] = "permission", [404] = "unsupported" }

local function loopbackIsDirect()
  if not noctalia.getenv then return true end
  local function present(name)
    local value = noctalia.getenv(name)
    return type(value) == "string" and value ~= "" and value or nil
  end
  -- Noctalia's libcurl HTTP binding uses the process proxy environment.
  -- It doesn't yet offer a request-local bypass. Never send the bearer
  -- token through an HTTP proxy; require a known matching NO_PROXY entry.
  if not (present("http_proxy") or present("all_proxy") or present("ALL_PROXY")) then return true end
  local bypass = present("no_proxy") or present("NO_PROXY") or ""
  if bypass == "*" then return true end
  for entry in bypass:gmatch("[^,]+") do
    local host = entry:match("^[ \t]*([^ \t]*)[ \t]*$")
    if not host then break end -- libcurl stops at whitespace not followed by a comma.
    if host == "127.0.0.1" or host == "127.0.0.0/8" then return true end
  end
  return false
end

local function canSendDirectly()
  local inspected, direct = pcall(loopbackIsDirect)
  return inspected and direct
end

local function decode(raw)
  if not raw then return nil end
  local ok, value = pcall(noctalia.json.decode, raw)
  return ok and value or nil
end

--- Report stable reasons rather than propagating errors containing local paths.
local function readTokenFile()
  if not canSendDirectly() then return nil, "loopback_proxy" end
  local readable, raw = pcall(noctalia.readFile, TOKEN_FILE)
  if not readable or raw == nil then return nil, "credentials_missing" end
  local cfg = decode(raw)
  if type(cfg) ~= "table" or type(cfg.token) ~= "string" or #cfg.token ~= 64 or not cfg.token:match("^%x+$")
    or type(cfg.port) ~= "number" or cfg.port < 1 or cfg.port > 65535 or cfg.port % 1 ~= 0
  then
    return nil, "credentials_invalid"
  end
  return cfg
end

local function encodeBody(path, body)
  local ok, encoded = pcall(noctalia.json.encode, body)
  if not ok or not encoded then return nil end
  if path == "/v1/page" and type(encoded) == "string" and type(body.photo_ids) == "table"
    and next(body.photo_ids) == nil
  then
    -- Noctalia encodes an empty Lua table as an object, not a JSON array.
    encoded = encoded:gsub('"photo_ids"%s*:%s*{%s*}', '"photo_ids":[]', 1)
  end
  return encoded
end

--- Keep synchronous host replies outside the transport's pcall as well.
local function dispatch(request, receive)
  local issuing, queued = true, nil
  local ok, started = pcall(noctalia.http, request, function(response)
    if issuing then
      queued = queued or { response }
    else
      receive(response)
    end
  end)
  issuing = false
  if queued then
    receive(queued[1])
    return true
  end
  return ok and started
end

---@param onCredentialsChanged fun(reason: string)
function M.new(onCredentialsChanged)
  local boundToken, boundPort = nil, nil
  local authEpoch = 0

  local function bindCredentials(token, port, reason)
    if boundToken == token and boundPort == port then return authEpoch end
    local wasBound = boundToken ~= nil
    boundToken, boundPort = token, port
    authEpoch = authEpoch + 1
    local epoch = authEpoch
    if wasBound then onCredentialsChanged(reason) end
    return epoch
  end

  --- Read and bind current credentials without exposing them in snapshots.
  ---@return NectarLinkCredentials?, string?
  local function credentials()
    local cfg, reason = readTokenFile()
    if not cfg then
      bindCredentials(nil, nil, reason)
      return nil, reason
    end
    local epoch = bindCredentials(cfg.token, cfg.port, "auth_changed")
    return { token = cfg.token, port = cfg.port, epoch = epoch }
  end

  --- Send a request at most once using credentials from its own auth epoch.
  ---@param path string
  ---@param body table?
  ---@param callback NectarLinkReply
  ---@param validatedCredentials NectarLinkCredentials?
  local function request(path, body, callback, validatedCredentials)
    local initialEpoch = authEpoch
    local wasBound = boundToken ~= nil
    local cfg, credentialError = validatedCredentials, nil
    if cfg and not canSendDirectly() then
      bindCredentials(nil, nil, "loopback_proxy")
      callback(false, 0, nil, "loopback_proxy")
      return
    elseif not cfg then
      cfg, credentialError = credentials()
    end
    if not cfg then
      callback(false, 0, nil, credentialError)
      return
    end
    -- Rotation must neither forward an old intent nor revive an A→B→A credential.
    if (wasBound and initialEpoch ~= authEpoch) or cfg.epoch ~= authEpoch
      or cfg.token ~= boundToken or cfg.port ~= boundPort
    then
      callback(false, 0, nil, "auth_changed")
      return
    end
    local requestEpoch = cfg.epoch
    local completed = false
    local function finish(ok, status, data, reason)
      if completed then
        return
      end
      completed = true
      if requestEpoch ~= authEpoch then
        return
      end
      callback(ok, status, data, reason)
    end
    local encoded = body and encodeBody(path, body)
    if body and not encoded then
      finish(false, 0, nil, "request_failed")
      return
    end
    local started = dispatch({
      url = "http://127.0.0.1:" .. tostring(cfg.port) .. path,
      method = body and "POST" or "GET",
      headers = { "Authorization: Bearer " .. cfg.token, "Content-Type: application/json" },
      body = encoded,
      follow_redirects = false,
    }, function(res)
      if completed or requestEpoch ~= authEpoch then
        completed = true
        return
      end
      if type(res) ~= "table" then
        finish(false, 0, nil, "invalid_response")
        return
      end
      local status = type(res.status) == "number" and res.status or 0
      local data = decode(res.body)
      local ok = res.ok == true and status == 200 and type(data) == "table"
      local reason
      if not ok then
        reason = (status == 200 and type(data) ~= "table") and "invalid_response"
          or statusErrors[status] or "request_failed"
      end
      finish(ok, status, data, reason)
    end)
    if not started then
      finish(false, 0, nil, "api_unavailable")
    end
  end
  return { decode = decode, credentials = credentials, request = request }
end
return M
