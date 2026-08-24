--!nonstrict
-- Service entry for Command Runner plugin

local SALT = "noctalia_cmd_runner_salt_5f8a"

local function trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Helper functions for base64 encoding and encryption/decryption
local function base64Encode(data)
  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  return ((data:gsub('.', function(x) 
    local r,b_val='',x:byte()
    for i=8,1,-1 do r=r..(b_val%2^i-b_val%2^(i-1)>0 and '1' or '0') end
    return r;
  end)..'0000'):gsub('%d%d%d%d%d%d', function(x)
    if (#x < 6) then return '' end
    local c=0
    for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
    return b:sub(c+1,c+1)
  end)..({ '', '==', '=' })[#data%3+1])
end

local function base64Decode(data)
  local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  data = string.gsub(data, '[^'..b..'=]', '')
  return (data:gsub('.', function(x)
    if (x == '=') then return '' end
    local r,f='',(b:find(x)-1)
    for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
    return r;
  end):gsub('%d%d%d%d%d%d%d%d', function(x)
    local c=0
    for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
    return string.char(c)
  end))
end

local function encryptPassword(pass)
  if not pass or pass == "" then return "" end
  if pass:sub(1, 4) == "enc:" then return pass end -- already encrypted
  
  local result = {}
  for i = 1, #pass do
    local p_byte = pass:byte(i)
    local s_byte = SALT:byte(((i - 1) % #SALT) + 1)
    local enc_byte = (p_byte + s_byte) % 256
    table.insert(result, string.char(enc_byte))
  end
  return "enc:" .. base64Encode(table.concat(result))
end

local function decryptPassword(enc)
  if not enc or enc == "" then return "" end
  if enc:sub(1, 4) ~= "enc:" then return enc end -- plain text fallback
  
  local raw_enc = enc:sub(5)
  local decoded = base64Decode(raw_enc)
  local result = {}
  for i = 1, #decoded do
    local d_byte = decoded:byte(i)
    local s_byte = SALT:byte(((i - 1) % #SALT) + 1)
    local dec_byte = (d_byte - s_byte) % 256
    table.insert(result, string.char(dec_byte))
  end
  return table.concat(result)
end

local defaultCommands = {
  {
    id = "cmd_demo_1",
    name = "System Update Check",
    command = "echo 'Checking system updates...' && sleep 1 && echo 'System is up to date'",
    icon = "refresh",
    isSudo = false,
    sudoPassword = ""
  }
}

local commandsFile = (noctalia.pluginDir() or "") .. "/commands.json"

local function loadCommands()
  local content = noctalia.readFile(commandsFile)
  if content and trim(content) ~= "" then
    local decoded, err = noctalia.json.decode(content)
    if type(decoded) == "table" and #decoded >= 0 then
      -- Auto-encrypt passwords on load if they are stored in plain text
      local changed = false
      for _, c in ipairs(decoded) do
        if c.sudoPassword and c.sudoPassword ~= "" and c.sudoPassword:sub(1, 4) ~= "enc:" then
          c.sudoPassword = encryptPassword(c.sudoPassword)
          changed = true
        end
      end
      if changed then
        local encoded = noctalia.json.encode(decoded)
        if encoded then
          noctalia.writeFile(commandsFile, encoded)
        end
      end
      return decoded
    end
  end
  return defaultCommands
end

local function saveCommands(list)
  local savedList = {}
  for _, c in ipairs(list) do
    local copy = {}
    for k, v in pairs(c) do
      copy[k] = v
    end
    if copy.sudoPassword then
      copy.sudoPassword = encryptPassword(copy.sudoPassword)
    end
    table.insert(savedList, copy)
  end

  local encoded, err = noctalia.json.encode(savedList)
  if encoded then
    noctalia.writeFile(commandsFile, encoded)
  end
end

local currentCommands = loadCommands()
local runningMap = {}
local outputMap = {}
local exitCodeMap = {}

local function publishState()
  -- Scrub actual passwords from public state for security
  local publicCommands = {}
  for _, c in ipairs(currentCommands) do
    local copy = {}
    for k, v in pairs(c) do
      if k ~= "sudoPassword" then
        copy[k] = v
      else
        copy.hasPassword = (v ~= nil and v ~= "")
      end
    end
    table.insert(publicCommands, copy)
  end

  noctalia.state.set("cmd_runner_state", {
    commands = publicCommands,
    runningMap = runningMap,
    outputMap = outputMap,
    exitCodeMap = exitCodeMap,
    updatedAt = os.time()
  })
end

publishState()

local function executeCommand(cmdId)
  local targetCmd = nil
  for _, c in ipairs(currentCommands) do
    if c.id == cmdId then
      targetCmd = c
      break
    end
  end

  if not targetCmd or trim(targetCmd.command) == "" then
    return
  end

  runningMap[cmdId] = true
  publishState()

  local fullCmd = ""
  if targetCmd.isSudo then
    local pass = decryptPassword(targetCmd.sudoPassword)
    fullCmd = "printf '%s\\n' " .. shellQuote(pass) .. " | sudo -S -p '' -- " .. targetCmd.command
  else
    fullCmd = targetCmd.command
  end

  noctalia.runAsync(fullCmd, function(result)
    runningMap[cmdId] = false
    local code = (result and type(result.exitCode) == "number") and result.exitCode or -1
    local outText = trim((result and result.stdout or "") .. "\n" .. (result and result.stderr or ""))
    exitCodeMap[cmdId] = code
    outputMap[cmdId] = outText
    publishState()

    local showToast = noctalia.getConfig("show_toast") ~= false
    if showToast then
      if code == 0 then
        noctalia.notify(noctalia.tr("title"), noctalia.tr("notify.success", { name = targetCmd.name }))
      else
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notify.error", { name = targetCmd.name, code = code }))
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
    item.sudoPassword = encryptPassword(item.sudoPassword or "")
    table.insert(currentCommands, item)
    saveCommands(currentCommands)
    publishState()
  elseif act == "update" and actionData.item then
    for i, c in ipairs(currentCommands) do
      if c.id == actionData.item.id then
        local newPass = actionData.item.sudoPassword or ""
        -- If the updated command keeps sudo but the sent password is empty and we had a password, keep it
        if newPass == "" and c.sudoPassword and c.sudoPassword ~= "" and actionData.item.isSudo then
          newPass = c.sudoPassword
        else
          newPass = encryptPassword(newPass)
        end
        
        local updatedItem = {
          id = actionData.item.id,
          name = actionData.item.name,
          command = actionData.item.command,
          icon = actionData.item.icon,
          isSudo = actionData.item.isSudo,
          sudoPassword = newPass
        }
        currentCommands[i] = updatedItem
        break
      end
    end
    saveCommands(currentCommands)
    publishState()
  elseif act == "delete" and actionData.id then
    local newList = {}
    for _, c in ipairs(currentCommands) do
      if c.id ~= actionData.id then
        table.insert(newList, c)
      end
    end
    currentCommands = newList
    saveCommands(currentCommands)
    publishState()
  end
end

noctalia.state.watch("cmd_runner_action", handleCommandAction)
