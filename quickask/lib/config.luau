--!nonstrict
-- Non-secret connection settings only. Credentials remain in Secret Service.
local M = {}

local function endpointAuthority(endpoint)
  if type(endpoint) ~= "string" or #endpoint > 2048
    or endpoint:find("[%c%s\\?#]") then return nil end
  local authority, path = endpoint:match("^https://([^/]+)(/.*)$")
  if not authority or not path:match("/chat/completions$") then return nil end

  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^(%[[%x:%.]+%]):(%d+)$")
    if not host then host = authority:match("^(%[[%x:%.]+%])$") end
    if not host or not host:find(":", 1, true) then return nil end
  else
    host, port = authority:match("^([%w%.%-]+):(%d+)$")
    if not host then host = authority:match("^([%w%.%-]+)$") end
    if not host or host:find("..", 1, true) or host:sub(1, 1) == "."
      or host:sub(-1) == "." then return nil end
    for label in host:gmatch("[^.]+") do
      if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then return nil end
    end
  end
  if port and (tonumber(port) < 1 or tonumber(port) > 65535) then return nil end
  return authority
end

function M.read()
  local provider = noctalia.getConfig("provider")
  if provider == "opencode-go" then
    return {
      provider = provider,
      endpoint = "https://opencode.ai/inference/go/openai/v1/chat/completions",
      model = "deepseek-v4.1-flash",
      authority = "OpenCode Go",
    }
  elseif provider ~= "openai-compatible" then
    return nil, noctalia.tr("config.provider-error")
  end

  local endpoint = noctalia.getConfig("endpoint")
  local authority = endpointAuthority(endpoint)
  if not authority then return nil, noctalia.tr("config.endpoint-error") end
  local model = noctalia.getConfig("model")
  if type(model) ~= "string" or #model > 256 or model:find("%c") then
    return nil, noctalia.tr("config.model-error")
  end
  model = model:match("^%s*(.-)%s*$")
  if model == "" then return nil, noctalia.tr("config.model-error") end
  return { provider = provider, endpoint = endpoint, model = model, authority = authority }
end

return M
