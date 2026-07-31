local M = {}
M.conversation = {}
M.pendingResponses = {}
M.pendingToolResults = {}
M.pendingToolApproval = nil

local TOOLS = {
  {
    type = "function",
    ["function"] = {
      name = "run_command",
      description = "Execute a shell command on the user's system",
      parameters = {
        type = "object",
        properties = {
          command = {
            type = "string",
            description = "The shell command to run",
          },
          description = {
            type = "string",
            description = "Brief description of what this command does",
          },
        },
        required = { "command", "description" },
      },
    },
  },
}

local function loadApiKey()
  local key = noctalia.getConfig("api_key") or ""
  if key ~= "" then return key end
  local endpoint = noctalia.getConfig("api_endpoint") or "https://opencode.ai/zen/go/v1"
  if not endpoint:find("opencode", 1, true) then return "" end
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
    toolPermission = noctalia.getConfig("tool_permission") or "ask",
    toolBlocklist = noctalia.getConfig("tool_blocklist") or "sudo,su,passwd,chown,chmod,mount,umount,dd,mkfs,fsck,reboot,shutdown,poweroff,init,halt",
    maxHistory = noctalia.getConfig("max_history") or 50,
  }
end

local function isBlocked(command)
  local trimmed = command:match("^%s*(.-)%s*$")
  if not trimmed then return false end
  local first = trimmed:match("^(%S+)")
  if not first then return false end
  first = first:lower()
  local blocklist = loadConfig().toolBlocklist
  for item in blocklist:gmatch("[^,]+") do
    local b = item:match("^%s*(.-)%s*$")
    if b and b ~= "" and b:lower() == first then
      return true
    end
  end
  return false
end

local function setStatus(s)
  M.status = s
  noctalia.state.set("mimir.status", s)
end

local function addMessage(role, content, extra)
  local msg = { role = role, content = content }
  if extra then
    for k, v in pairs(extra) do msg[k] = v end
  end
  table.insert(M.conversation, msg)
  local copy = {}
  for _, v in ipairs(M.conversation) do
    table.insert(copy, v)
  end
  noctalia.state.set("mimir.messages", copy)
end

local function think(input)
  setStatus("thinking")
  local config = loadConfig()

  if #M.conversation > config.maxHistory then
    local trimmed = {}
    for i = #M.conversation - config.maxHistory + 1, #M.conversation do
      table.insert(trimmed, M.conversation[i])
    end
    M.conversation = trimmed
    local copy = {}
    for _, m in ipairs(M.conversation) do table.insert(copy, m) end
    noctalia.state.set("mimir.messages", copy)
  end

  local model = noctalia.state.get("mimir.model") or "deepseek-v4-flash"

  local msgs = {
    { role = "system", content = "You are Mimir, a helpful AI assistant running on the user's desktop. You can run shell commands to accomplish tasks. When you need to run a command, use the run_command tool." },
  }
  for _, m in ipairs(M.conversation) do
    table.insert(msgs, m)
  end
  if input then
    table.insert(msgs, { role = "user", content = input })
  end

  local body = { model = model, messages = msgs }
  if config.toolPermission ~= "off" then
    body.tools = TOOLS
  end

  local encoded = noctalia.json.encode(body)
  if not encoded then
    setStatus("idle")
    if input then addMessage("assistant", "Error: failed to encode request") end
    return
  end

  local url = config.endpoint .. "/chat/completions"

  local headers = { "Content-Type: application/json" }
  if config.apiKey ~= "" then
    table.insert(headers, "Authorization: Bearer " .. config.apiKey)
  end

  noctalia.http({
    url = url,
    method = "POST",
    headers = headers,
    body = encoded,
  }, function(res)
    table.insert(M.pendingResponses, res)
  end)
end

local function runCommand(tool_call, command)
  setStatus("running_tool")

  noctalia.runAsync(command, function(result)
    local output = ""
    local parts = {}
    if result.stdout and result.stdout ~= "" then table.insert(parts, result.stdout) end
    if result.stderr and result.stderr ~= "" then table.insert(parts, result.stderr) end
    output = table.concat(parts, "\n")
    if output == "" then
      output = "(exit code " .. tostring(result.status) .. ", no output)"
    end
    table.insert(M.pendingToolResults, { tool_call_id = tool_call.id, output = output })
  end)
end

local function executeTool(tool_call)
  local okArgs, args = pcall(noctalia.json.decode, tool_call["function"].arguments)
  if not okArgs or type(args) ~= "table" or not args.command then
    addMessage("assistant", "Error: model generated invalid tool arguments")
    setStatus("idle")
    return
  end

  if isBlocked(args.command) then
    addMessage("tool", "Command blocked by user settings: " .. args.command, { tool_call_id = tool_call.id })
    think(nil)
    return
  end

  local config = loadConfig()

  if config.toolPermission == "off" then
    addMessage("tool", "Tools are disabled in settings. Enable them to run commands.", { tool_call_id = tool_call.id })
    think(nil)
    return
  end

  if config.toolPermission == "ask" then
    M.pendingToolApproval = {
      id = tool_call.id,
      command = args.command,
      description = args.description or "",
    }
    noctalia.state.set("mimir.pending_tool", { command = args.command, description = args.description or "" })
    setStatus("idle")
    return
  end

  runCommand(tool_call, args.command)
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
    if not data or not data.choices then
      local snippet = (res.body or ""):sub(1, 200)
      setStatus("idle")
      addMessage("assistant", "Invalid API response: " .. snippet)
      return
    end

    local choice = data.choices[1]
    local message = choice.message

    if choice.finish_reason == "tool_calls" and message.tool_calls then
      addMessage("assistant", message.content, { tool_calls = message.tool_calls })
      for _, tc in ipairs(message.tool_calls) do
        if tc.type == "function" and tc["function"].name == "run_command" then
          executeTool(tc)
          break
        end
      end
    else
      local content = message.content or ""
      if content ~= "" then
        addMessage("assistant", content)
      end
      setStatus("idle")
    end
  end

  for i, result in ipairs(M.pendingToolResults) do
    M.pendingToolResults[i] = nil
    addMessage("tool", result.output, { tool_call_id = result.tool_call_id })
    think(nil)
  end

  local pending = M.pendingToolApproval
  if pending then
    local approved = noctalia.state.get("mimir.tool_approved")
    if approved then
      noctalia.state.set("mimir.tool_approved", false)
      noctalia.state.set("mimir.pending_tool", false)
      local cmd = type(approved) == "string" and approved or pending.command
      local tc = pending
      M.pendingToolApproval = nil
      runCommand({ id = tc.id }, cmd)
      return
    end

    local denied = noctalia.state.get("mimir.tool_denied")
    if denied then
      noctalia.state.set("mimir.tool_denied", false)
      noctalia.state.set("mimir.pending_tool", false)
      addMessage("tool", "Command was cancelled by the user.", { tool_call_id = pending.id })
      M.pendingToolApproval = nil
      think(nil)
      return
    end
  end
end

noctalia.state.watch("mimir.input", function(input)
  if input and input ~= "" then
    if M.pendingToolApproval then
      addMessage("assistant", "Please approve or deny the pending command first.")
      return
    end
    addMessage("user", input)
    think(nil)
  end
end)

noctalia.state.watch("mimir.clear", function(v)
  if v then
    M.conversation = {}
    M.pendingToolApproval = nil
    noctalia.state.set("mimir.messages", {})
    noctalia.state.set("mimir.pending_tool", false)
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
