--!nonstrict
local M = {}
local token = nil

local function setting(key)
  return noctalia.string.trim(tostring(noctalia.getConfig(key) or ""))
end

local function apiRoot()
  return (setting("api_url"):gsub("/+$", ""))
end

function M.isConfigured()
  return setting("api_key") ~= "" or (setting("username") ~= "" and setting("password") ~= "")
end

function M.logout()
  token = nil
end

-- Older Umami releases wrap each stat as { value, prev } and report active visitors as { x }.
function M.count(value)
  return tonumber(type(value) == "table" and value.value or value) or 0
end

function M.websitePath(id)
  return `/websites/{noctalia.string.urlEncode(id)}`
end

function M.dashboardUrl(path)
  local root = apiRoot()
  if root:match("^https?://api%.umami%.is") then
    return "https://cloud.umami.is" .. path
  end
  return (root:gsub("/api$", "")) .. path
end

local function withAccessHeaders(request)
  local id, secret = setting("cf_access_client_id"), setting("cf_access_client_secret")
  if id ~= "" and secret ~= "" then
    local headers = table.clone(request.headers or {})
    table.insert(headers, `CF-Access-Client-Id: {id}`)
    table.insert(headers, `CF-Access-Client-Secret: {secret}`)
    request.headers = headers
  end
  return request
end

local function call(request, onBody, onFail)
  local started = noctalia.http(withAccessHeaders(request), function(res)
    if not res.ok then
      onFail("error.network")
    elseif res.status == 401 then
      token = nil
      onFail("error.unauthorized")
    elseif res.status == 302 then
      onFail("error.access_redirect")
    elseif res.status ~= 200 then
      onFail("error.http_status", { status = res.status })
    else
      local body = noctalia.json.decode(res.body)
      if type(body) == "table" then
        onBody(body)
      else
        onFail("error.bad_json")
      end
    end
  end)
  if not started then
    onFail("error.not_started")
  end
end

function M.get(auth, path, onBody, onFail)
  call({ url = apiRoot() .. path, headers = { auth } }, onBody, onFail)
end

function M.auth(onHeader, onFail)
  local apiKey = setting("api_key")
  -- Self-hosted keys carry the umami_ prefix and go in Authorization; Umami Cloud reads x-umami-api-key.
  if apiKey:sub(1, 6) == "umami_" then
    onHeader(`Authorization: Bearer {apiKey}`)
  elseif apiKey ~= "" then
    onHeader(`x-umami-api-key: {apiKey}`)
  elseif token ~= nil then
    onHeader(`Authorization: Bearer {token}`)
  else
    call({
      url = apiRoot() .. "/auth/login",
      method = "POST",
      headers = { "Content-Type: application/json" },
      body = noctalia.json.encode({ username = setting("username"), password = setting("password") }),
    }, function(body)
      if type(body.token) ~= "string" then
        onFail(body.requiresTwoFactor and "error.two_factor" or "error.bad_json")
        return
      end
      token = body.token
      onHeader(`Authorization: Bearer {token}`)
    end, onFail)
  end
end

return M
