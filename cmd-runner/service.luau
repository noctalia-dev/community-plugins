--!nonstrict
-- Service entry for Command Runner plugin

local function trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- System keyring attributes used to scope all secrets to this plugin
local KR_PLUGIN = "noctalia-plugin"
local KR_PLUGIN_VAL = "nocode-96/cmd-runner"
local KR_ID = "cmd-id"

local function keyringLabel(cmdName)
  return "Noctalia Command Runner: " .. tostring(cmdName or "")
end

-- Store a password in the system keyring (secret-tool / libsecret)
-- The password is piped via stdin; it never appears in /proc/cmdline of secret-tool.
-- Note: printf's argv briefly contains the password – acknowledged as transient.
local function storePassword(cmdId, cmdName, pass, callback)
  if not pass or pass == "" then
    if callback then callback(false) end
    return
  end
  local label = keyringLabel(cmdName)
  local cmd = "printf '%s' " .. shellQuote(pass) ..
    " | secret-tool store --label " .. shellQuote(label) ..
    " " .. KR_PLUGIN .. " " .. shellQuote(KR_PLUGIN_VAL) ..
    " " .. KR_ID .. " " .. shellQuote(cmdId)
  noctalia.runAsync(cmd, function(result)
    if callback then callback(result and result.exitCode == 0) end
  end, 5000)
end

-- Remove a stored password from the system keyring
local function clearPassword(cmdId, callback)
  local cmd = "secret-tool clear " ..
    KR_PLUGIN .. " " .. shellQuote(KR_PLUGIN_VAL) ..
    " " .. KR_ID .. " " .. shellQuote(cmdId)
  noctalia.runAsync(cmd, function(_)
    if callback then callback() end
  end, 5000)
end

-- Check whether the keyring holds a secret for a given command
local function hasPasswordInKeyring(cmdId, callback)
  local cmd = "secret-tool lookup " ..
    KR_PLUGIN .. " " .. shellQuote(KR_PLUGIN_VAL) ..
    " " .. KR_ID .. " " .. shellQuote(cmdId)
  noctalia.runAsync(cmd, function(result)
    local has = result and result.exitCode == 0 and
      type(result.stdout) == "string" and result.stdout ~= ""
    callback(has == true)
  end, 5000)
end

-- Default demo command (no sudo, no stored password)
local defaultCommands = {
  {
    id = "cmd_demo_1",
    name = "System Update Check",
    command = "echo 'Checking system updates...' && sleep 1 && echo 'System is up to date'",
    icon = "refresh",
    isSudo = false
  }
}

-- User data lives in pluginDataDir, not pluginDir.
-- pluginDir is a managed checkout that may be re-materialised on update.
local function commandsFilePath()
  local dir = noctalia.pluginDataDir()
  if not dir or dir == "" then return nil end
  return dir .. "/commands.json"
end

local function loadCommands()
  local path = commandsFilePath()
  if not path then return defaultCommands end

  local content = noctalia.readFile(path)
  if content and trim(content) ~= "" then
    local decoded = noctalia.json.decode(content)
    if type(decoded) == "table" then
      -- Strip any legacy sudoPassword fields that may have been written by older versions
      for _, c in ipairs(decoded) do
        c.sudoPassword = nil
      end
      return decoded
    end
  end
  return defaultCommands
end

local function saveCommands(list)
  local path = commandsFilePath()
  if not path then return end

  local saved = {}
  for _, c in ipairs(list) do
    local copy = {}
    for k, v in pairs(c) do
      -- sudoPassword must never be persisted to disk; passwords live in the keyring only
      if k ~= "sudoPassword" then copy[k] = v end
    end
    table.insert(saved, copy)
  end

  local encoded = noctalia.json.encode(saved)
  if encoded then noctalia.writeFile(path, encoded) end
end

local currentCommands = loadCommands()
local runningMap    = {}
local outputMap     = {}
local exitCodeMap   = {}
local hasPasswordMap = {}

-- Refresh which commands have a password stored in the keyring, then publish state
local function refreshPasswordFlags(callback)
  local pending = 0
  for _, cmd in ipairs(currentCommands) do
    if cmd.isSudo then
      pending = pending + 1
    end
  end
  if pending == 0 then
    if callback then callback() end
    return
  end
  local done = 0
  for _, cmd in ipairs(currentCommands) do
    if cmd.isSudo then
      local id = cmd.id
      hasPasswordInKeyring(id, function(has)
        hasPasswordMap[id] = has
        done = done + 1
        if done >= pending and callback then callback() end
      end)
    end
  end
end

local function publishState()
  local publicCommands = {}
  for _, c in ipairs(currentCommands) do
    local copy = {}
    for k, v in pairs(c) do
      if k ~= "sudoPassword" then copy[k] = v end
    end
    copy.hasPassword = hasPasswordMap[c.id] == true
    table.insert(publicCommands, copy)
  end

  noctalia.state.set("cmd_runner_state", {
    commands    = publicCommands,
    runningMap  = runningMap,
    outputMap   = outputMap,
    exitCodeMap = exitCodeMap,
    updatedAt   = os.time()
  })
end

-- Initial state publish after async keyring checks
refreshPasswordFlags(function() publishState() end)

local function executeCommand(cmdId)
  local targetCmd = nil
  for _, c in ipairs(currentCommands) do
    if c.id == cmdId then targetCmd = c; break end
  end
  if not targetCmd or trim(targetCmd.command) == "" then return end

  runningMap[cmdId] = true
  publishState()

  local fullCmd
  if targetCmd.isSudo then
    -- Retrieve the password from the system keyring via stdout and pipe directly to
    -- sudo -S.  The password never appears in any process's argv, so it is not
    -- visible in /proc/<pid>/cmdline.
    fullCmd = "secret-tool lookup " ..
      KR_PLUGIN .. " " .. shellQuote(KR_PLUGIN_VAL) ..
      " " .. KR_ID .. " " .. shellQuote(cmdId) ..
      " | sudo -S -p '' -- " .. targetCmd.command
  else
    fullCmd = targetCmd.command
  end

  noctalia.runAsync(fullCmd, function(result)
    runningMap[cmdId] = false
    local code = (result and type(result.exitCode) == "number") and result.exitCode or -1
    local out = trim((result and result.stdout or "") .. "\n" .. (result and result.stderr or ""))
    exitCodeMap[cmdId] = code
    outputMap[cmdId]   = out
    publishState()

    if noctalia.getConfig("show_toast") ~= false then
      if code == 0 then
        noctalia.notify(
          noctalia.tr("title"),
          noctalia.tr("notify.success", { name = targetCmd.name }))
      else
        noctalia.notifyError(
          noctalia.tr("title"),
          noctalia.tr("notify.error", { name = targetCmd.name, code = code }))
      end
    end
  end, 120000)
end

local function handleCommandAction(actionData)
  if type(actionData) ~= "table" then return end
  local act = actionData.action

  if act == "run" and actionData.id then
    executeCommand(actionData.id)

  elseif act == "add" and actionData.item then
    local item = actionData.item
    local pass = item.sudoPassword or ""
    item.sudoPassword = nil
    table.insert(currentCommands, item)
    saveCommands(currentCommands)
    if item.isSudo and pass ~= "" then
      storePassword(item.id, item.name, pass, function(ok)
        hasPasswordMap[item.id] = ok
        publishState()
      end)
    else
      publishState()
    end

  elseif act == "update" and actionData.item then
    local incoming = actionData.item
    local newPass = incoming.sudoPassword or ""
    incoming.sudoPassword = nil
    for i, c in ipairs(currentCommands) do
      if c.id == incoming.id then
        currentCommands[i] = {
          id      = incoming.id,
          name    = incoming.name,
          command = incoming.command,
          icon    = incoming.icon,
          isSudo  = incoming.isSudo,
        }
        if incoming.isSudo and newPass ~= "" then
          -- New password provided: update keyring entry
          storePassword(incoming.id, incoming.name, newPass, function(ok)
            hasPasswordMap[incoming.id] = ok
            saveCommands(currentCommands)
            publishState()
          end)
        elseif not incoming.isSudo then
          -- Sudo disabled: remove any keyring entry
          clearPassword(incoming.id, function()
            hasPasswordMap[incoming.id] = false
            saveCommands(currentCommands)
            publishState()
          end)
        else
          -- Sudo still enabled but no new password entered: keep existing keyring entry
          saveCommands(currentCommands)
          publishState()
        end
        break
      end
    end

  elseif act == "delete" and actionData.id then
    local newList = {}
    for _, c in ipairs(currentCommands) do
      if c.id ~= actionData.id then table.insert(newList, c) end
    end
    clearPassword(actionData.id, function()
      hasPasswordMap[actionData.id] = nil
    end)
    currentCommands = newList
    saveCommands(currentCommands)
    publishState()
  end
end

noctalia.state.watch("cmd_runner_action", handleCommandAction)
