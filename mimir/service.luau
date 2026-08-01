local M = {}
M.conversation = {}
M.pendingResponses = {}
M.pendingToolResults = {}
M.pendingToolCalls = {}
M.pendingApproval = nil
M.toolBatchActive = false
M.commandLog = {}

local TOOLS = {
  {
    type = "function",
    ["function"] = {
      name = "run_command",
      description = "Run a shell command on the user's system. Prefer the simplest standard utility that works (ls, find, grep, cat); fall back to a small script only when no utility fits",
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

local function isTrustedOpenCodeEndpoint(endpoint)
  local scheme, authority = endpoint:match("^(%a[%w+.-]*)://([^/%?#]+)")
  if not scheme or not authority then return false end
  local host, port = authority:match("^([^:]+):(%d+)$")
  if not host then host = authority end
  if scheme:lower() ~= "https" or host:lower() ~= "opencode.ai" then return false end
  return port == nil or port == "443"
end

local function loadApiKey()
  local key = noctalia.getConfig("api_key") or ""
  if key ~= "" then return key end
  local endpoint = noctalia.getConfig("api_endpoint") or "https://opencode.ai/zen/go/v1"
  if not isTrustedOpenCodeEndpoint(endpoint) then return "" end
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
    showCommands = noctalia.getConfig("show_commands") ~= false,
    toolBlocklist = noctalia.getConfig("tool_blocklist") or "sudo,su,passwd,rm,mv,shred,truncate,tee,install,chown,chmod,mount,umount,dd,mkfs,fsck,reboot,shutdown,poweroff,init,halt,curl,wget,nc,ncat,socat,env,find,xargs,sh,bash,zsh,fish,python,python3,perl,ruby,node,lua,luau,eval,source,busybox,make,cmake,just,task",
    maxHistory = noctalia.getConfig("max_history") or 50,
  }
end

local function isBlocked(command)
  local trimmed = command:match("^%s*(.-)%s*$")
  if not trimmed then return false end
  if trimmed == "" then return false end

  -- runAsync passes this string to /bin/sh -c, so do not allow shell syntax
  -- to combine commands or invoke a second interpreter.
  if trimmed:find("[;|&><`$\\\n\r]") then return true end

  local first = trimmed:match("^(%S+)")
  if not first then return false end
  first = first:gsub("^['\"]", ""):gsub("['\"]$", "")
  first = first:match("([^/]+)$"):lower()
  local blocklist = loadConfig().toolBlocklist
  for item in blocklist:gmatch("[^,]+") do
    local b = item:match("^%s*(.-)%s*$")
    if b and b ~= "" and b:lower():match("([^/]+)$") == first then
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
  local msg = { role = role, content = content or "" }
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
    { role = "system", content = "You are Mimir, an AI assistant running directly on the user's desktop with shell access. Your job: accomplish real tasks by running shell commands through the run_command tool, then report what actually happened. Choose the simplest, fastest command for the job. For local files and system state, standard utilities are ideal: ls, find, grep, cat, which, df, ps, head, wc. When a standard utility exists, prefer it over writing scripts — one-liners are faster, clearer, and less likely to need approvals. Reach for a script (python, etc.) only when no simple utility covers the task. Use your own knowledge to answer questions and explain things; you do not need to fetch web pages. When the task needs the user's input or a choice, ask instead of guessing. Never just give instructions — run the command and show the result. The user has already authorized command execution through the approval flow, so do not hesitate to use tools for legitimate tasks." },
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
    local config = loadConfig()
    if config.showCommands then
      table.insert(M.commandLog, { tool_call_id = tool_call.id, command = command })
      if #M.commandLog > 50 then table.remove(M.commandLog, 1) end
      local logCopy = {}
      for _, entry in ipairs(M.commandLog) do table.insert(logCopy, entry) end
      noctalia.state.set("mimir.command_log", logCopy)
    end
    table.insert(M.pendingToolResults, { tool_call_id = tool_call.id, output = output })
  end)
end

local function queueToolCalls(tool_calls)
  M.pendingToolCalls = {}
  M.pendingApproval = nil
  M.toolBatchActive = true
  for _, tc in ipairs(tool_calls) do
    if tc.type == "function" and tc["function"].name == "run_command" then
      local okArgs, args = pcall(noctalia.json.decode, tc["function"].arguments)
      table.insert(M.pendingToolCalls, {
        tc = tc,
        args = (okArgs and type(args) == "table") and args or nil,
        status = "waiting",
      })
    end
  end
end

local function allToolCallsDone()
  for _, call in ipairs(M.pendingToolCalls) do
    if call.status ~= "done" then return false end
  end
  return true
end

local function finishToolBatch()
  if not M.toolBatchActive then return end
  if not allToolCallsDone() then return end
  M.toolBatchActive = false
  M.pendingToolCalls = {}
  M.pendingApproval = nil
  think(nil)
end

local function processToolQueue()
  if #M.pendingToolCalls == 0 then
    M.toolBatchActive = false
    return
  end

  for _, call in ipairs(M.pendingToolCalls) do
    if call.status == "running" then return end
  end

  local config = loadConfig()

  for _, call in ipairs(M.pendingToolCalls) do
    if call.status == "waiting" then
      if call.args == nil or type(call.args.command) ~= "string" or call.args.command == "" then
        addMessage("tool", "Error: invalid tool arguments", { tool_call_id = call.tc.id })
        call.status = "done"
      elseif isBlocked(call.args.command) then
        addMessage("tool", "Command blocked by user settings: " .. call.args.command, { tool_call_id = call.tc.id })
        call.status = "done"
      elseif config.toolPermission == "off" then
        addMessage("tool", "Tools are disabled in settings. Enable them to run commands.", { tool_call_id = call.tc.id })
        call.status = "done"
      end
    end
  end

  local remaining = {}
  for _, call in ipairs(M.pendingToolCalls) do
    if call.status == "waiting" then table.insert(remaining, call) end
  end

  if config.toolPermission == "ask" and #remaining > 0 then
    M.pendingApproval = {}
    local commands = {}
    for _, call in ipairs(remaining) do
      table.insert(M.pendingApproval, { id = call.tc.id, command = call.args.command, description = call.args.description or "" })
      table.insert(commands, { command = call.args.command, description = call.args.description or "" })
    end
    noctalia.state.set("mimir.pending_tool", { commands = commands })
    setStatus("idle")
    return
  end

  if config.toolPermission == "allow" then
    for _, call in ipairs(remaining) do
      call.status = "running"
      runCommand(call.tc, call.args.command)
    end
    return
  end

  finishToolBatch()
end

function update()
  for i, res in ipairs(M.pendingResponses) do
    if M.toolBatchActive then break end
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
      local clean = {}
      for _, tc in ipairs(message.tool_calls) do
        local c = { id = tc.id, type = tc.type, ["function"] = tc["function"] }
        table.insert(clean, c)
      end
      addMessage("assistant", message.content, { tool_calls = clean })
      queueToolCalls(message.tool_calls)
      processToolQueue()
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
    for _, call in ipairs(M.pendingToolCalls) do
      if call.tc.id == result.tool_call_id then
        call.status = "done"
      end
    end
  end
  finishToolBatch()

  local approval = M.pendingApproval
  if approval then
    local approved = noctalia.state.get("mimir.tool_approved")
    if approved then
      noctalia.state.set("mimir.tool_approved", false)
      noctalia.state.set("mimir.pending_tool", false)
      M.pendingApproval = nil
      for _, call in ipairs(M.pendingToolCalls) do
        if call.status == "waiting" then
          call.status = "running"
          runCommand(call.tc, call.args.command)
        end
      end
      return
    end

    local denied = noctalia.state.get("mimir.tool_denied")
    if denied then
      noctalia.state.set("mimir.tool_denied", false)
      noctalia.state.set("mimir.pending_tool", false)
      M.pendingApproval = nil
      for _, call in ipairs(M.pendingToolCalls) do
        if call.status == "waiting" then
          addMessage("tool", "Command was cancelled by the user.", { tool_call_id = call.tc.id })
          call.status = "done"
        end
      end
      finishToolBatch()
      return
    end
  end
end

noctalia.state.watch("mimir.input", function(input)
  if input and input ~= "" then
    if M.pendingApproval then
      addMessage("assistant", "Please approve or deny the pending command first.")
      return
    end
    if M.toolBatchActive then
      addMessage("assistant", "Please wait for the running commands to finish.")
      return
    end
    addMessage("user", input)
    think(nil)
  end
end)

noctalia.state.watch("mimir.clear", function(v)
  if v then
    M.conversation = {}
    M.pendingToolCalls = {}
    M.pendingApproval = nil
    M.toolBatchActive = false
    M.commandLog = {}
    noctalia.state.set("mimir.messages", {})
    noctalia.state.set("mimir.command_log", {})
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
noctalia.state.set("mimir.command_log", {})
