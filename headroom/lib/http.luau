--!nonstrict
-- JSON-over-HTTP for provider adapters, with vendor-neutral error mapping.
--
-- Every adapter gets the same failure vocabulary (model.ErrorCode), so a 401
-- from one vendor and a 403 from another render the same "sign in again" state.
-- Response bodies are never copied into errors: they can echo account data.

local model = require("./model.luau")

local M = {}

local E = model.ErrorCode

-- Maps a transport result onto (data, nil) or (nil, ProviderError).
-- `classify(status, body)` lets an adapter recognise its vendor's own error
-- shapes (returning an ErrorCode) before the generic status mapping applies.
function M.interpret(response, decode, classify): (any, model.ProviderError?)
  if response == nil or not response.ok then
    return nil, model.err(E.Network)
  end
  local status = response.status or 0
  if classify and (status < 200 or status >= 300) then
    local code = classify(status, response.body or "")
    if code then
      return nil, model.err(code, `HTTP {status}`)
    end
  end
  if status == 401 or status == 403 then
    return nil, model.err(E.Auth, `HTTP {status}`)
  end
  if status == 429 then
    return nil, model.err(E.RateLimited, "HTTP 429")
  end
  if status < 200 or status >= 300 then
    return nil, model.err(E.Server, `HTTP {status}`)
  end
  local data, decodeErr = decode(response.body or "")
  if type(data) ~= "table" then
    return nil, model.err(E.Parse, decodeErr or "not a JSON object")
  end
  return data, nil
end

local function send(transport, decode, req, done, classify)
  local started = transport(req, function(response)
    done(M.interpret(response, decode, classify))
  end)
  if started == false then
    done(nil, model.err(E.Network, "request not started"))
  end
end

local function headerLines(headers: { [string]: string }): { string }
  local lines = { "Accept: application/json" }
  for name, value in headers do
    table.insert(lines, `{name}: {value}`)
  end
  table.sort(lines) -- deterministic order, for tests and for humans reading logs
  return lines
end

-- Builds the getJson(url, headers, done) function handed to adapters through
-- their context. `transport` is noctalia.http (or a fake in tests).
function M.client(transport, decode)
  return function(url: string, headers: { [string]: string }, done: (any, model.ProviderError?) -> ())
    send(transport, decode, { url = url, method = "GET", headers = headerLines(headers) }, done)
  end
end

-- postJson(url, headers, body, done, classify?): like getJson, with a JSON body.
function M.postClient(transport, decode)
  return function(url: string, headers: { [string]: string }, body: string, done: (any, model.ProviderError?) -> (), classify)
    local withType = table.clone(headers)
    withType["Content-Type"] = "application/json"
    send(transport, decode, { url = url, method = "POST", headers = headerLines(withType), body = body }, done, classify)
  end
end

return M
