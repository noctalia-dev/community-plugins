local M = {}
M.conversation = {}
M.pendingResponses = {}

local function loadApiKey()
  local key = noctalia.getConfig("api_key") or ""
  if key ~= "" then return key end
  local ok, data = pcall(noctalia.readFile, noctalia.expandPath("~/.local/share/opencode/auth.json"))
  if ok and data then
    local parsed = noctalia.json.decode(data)
    if parsed and parsed["opencode-go"] and parsed["opencode-go"].key then
      return parsed["opencode-go"].key
    end
  end
  return ""
end

local function loadConfig()
  return {
    endpoint = noctalia.getConfig("api_endpoint") or "https://opencode.ai/zen/go/v1",
    apiKey = loadApiKey(),
  }
end

local function setStatus(s)
  M.status = s
  noctalia.state.set("mimir.status", s)
end

local function addMessage(role, content)
  table.insert(M.conversation, { role = role, content = content })
  local copy = {}
  for _, v in ipairs(M.conversation) do
    table.insert(copy, v)
  end
  noctalia.state.set("mimir.messages", copy)
end

local function think(input)
  setStatus("thinking")
  local model = noctalia.state.get("mimir.model") or "deepseek-v4-flash"
  local config = loadConfig()

  local msgs = {
    { role = "system", content = "You are Mimir, a helpful AI assistant." },
  }
  for _, m in ipairs(M.conversation) do
    table.insert(msgs, m)
  end
  table.insert(msgs, { role = "user", content = input })

  local body = noctalia.json.encode({ model = model, messages = msgs })
  if not body then
    setStatus("idle")
    addMessage("assistant", "Error: failed to encode request")
    return
  end

  local url = config.endpoint .. "/chat/completions"
  if config.apiKey == "" then
    setStatus("idle")
    addMessage("assistant", "Error: no API key configured")
    return
  end

  local headers = { "Content-Type: application/json", "Authorization: Bearer " .. config.apiKey }

  noctalia.http({
    url = url,
    method = "POST",
    headers = headers,
    body = body,
  }, function(res)
    table.insert(M.pendingResponses, res)
  end)
end

function update()
  for i, res in ipairs(M.pendingResponses) do
    M.pendingResponses[i] = nil

    if not res.ok then
      local err = res.body or "no body"
      if #err > 200 then err = err:sub(1, 200) .. "..." end
      setStatus("idle")
      addMessage("assistant", "HTTP " .. tostring(res.status) .. ": " .. err)
      return
    end

    local data = noctalia.json.decode(res.body)
    if not data then
      local snippet = (res.body or ""):sub(1, 200)
      setStatus("idle")
      addMessage("assistant", "Invalid API response: " .. snippet)
      return
    end

    local content = ""
    if data.choices and data.choices[1] and data.choices[1].message then
      content = data.choices[1].message.content or ""
    end
    if content == "" then content = "(no response)" end

    addMessage("assistant", content)
    setStatus("idle")
  end
end

noctalia.state.watch("mimir.input", function(input)
  if input and input ~= "" then
    addMessage("user", input)
    think(input)
  end
end)

noctalia.state.watch("mimir.clear", function(v)
  if v then
    M.conversation = {}
    noctalia.state.set("mimir.messages", {})
    setStatus("idle")
  end
end)

local function fetchModels()
  local config = loadConfig()
  if config.endpoint == "" then return end
  local url = config.endpoint .. "/models"
  noctalia.http({ url = url }, function(res)
    if not res.ok then return end
    local data = noctalia.json.decode(res.body)
    if not data or not data.data then return end
    local models = {}
    for _, m in ipairs(data.data) do
      if m.id then table.insert(models, m.id) end
    end
    noctalia.state.set("mimir.models", models)
  end)
end

noctalia.state.watch("mimir.refresh_models", function(v)
  if v then fetchModels() noctalia.state.set("mimir.refresh_models", false) end
end)

noctalia.setUpdateInterval(500)

fetchModels()
if noctalia.state.get("mimir.model") == nil then
  noctalia.state.set("mimir.model", "deepseek-v4-flash")
end
noctalia.state.set("mimir.status", "idle")
noctalia.state.set("mimir.messages", {})
