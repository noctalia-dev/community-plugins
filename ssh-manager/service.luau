--!nonstrict
-- SSH Manager backend: parse/write ~/.ssh/config, list/generate keys, agent control.
-- Never logs private key material.

local STATE_KEY = "ssh_snapshot"
local COMMAND_KEY = "ssh_command"
local RESULT_KEY = "ssh_action_result"

local snapshot = {
  available = false,
  loading = true,
  busy = false,
  configPath = "",
  sshDir = "",
  hosts = {},
  keys = {},
  agentKeys = 0,
  hostCount = 0,
  keyCount = 0,
  error = "",
  updatedAt = 0,
  revision = 0,
}

local refreshGeneration = 0
local refreshPending = false
local refreshAgain = false
local actionBusy = false
local dataSignature = ""

-- parsed config segments: host | raw
local segments = {}

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function shellCommand(args)
  local quoted = {}
  for _, value in ipairs(args) do
    table.insert(quoted, shellQuote(value))
  end
  return table.concat(quoted, " ")
end

local function expand(path)
  return noctalia.expandPath(trim(path))
end

local function configPath()
  local configured = noctalia.getConfig("config_path")
  if type(configured) == "string" and configured ~= "" then
    return expand(configured)
  end
  return expand("~/.ssh/config")
end

local function sshDir()
  local configured = noctalia.getConfig("ssh_dir")
  if type(configured) == "string" and configured ~= "" then
    return expand(configured)
  end
  return expand("~/.ssh")
end

local function shouldNotify()
  return noctalia.getConfig("notify_on_action") ~= false
end

local function refreshIntervalMs()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 5
  seconds = math.max(2, math.min(60, math.floor(seconds)))
  return seconds * 1000
end

local function notifyOk(message)
  if shouldNotify() then
    noctalia.notify(noctalia.tr("title"), message)
  end
end

local function notifyErr(message)
  noctalia.notifyError(noctalia.tr("title"), message)
end

local function actionResult(command, ok, message, extra)
  local result = {
    requestId = command and command.requestId or "",
    action = command and command.action or "",
    ok = ok,
    message = message or "",
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      result[key] = value
    end
  end
  noctalia.state.set(RESULT_KEY, result)
end

local function updateRevision(signature)
  if signature ~= dataSignature then
    dataSignature = signature
    snapshot.revision += 1
  end
end

local function isValidAlias(alias)
  alias = trim(alias)
  if alias == "" or alias == "*" then
    return false
  end
  if alias:find("[*?]") then
    return false
  end
  return alias:match("^[%w._-]+$") ~= nil
end

local function isWildcardHost(aliases)
  for _, a in ipairs(aliases) do
    if a == "*" or a:find("[*?]") then
      return true
    end
  end
  return false
end

local function optionGet(options, key)
  key = key:lower()
  for _, opt in ipairs(options) do
    if opt.key:lower() == key then
      return opt.value
    end
  end
  return nil
end

local function optionSet(options, key, value)
  value = trim(value)
  local lower = key:lower()
  for i, opt in ipairs(options) do
    if opt.key:lower() == lower then
      if value == "" then
        table.remove(options, i)
      else
        opt.value = value
      end
      return
    end
  end
  if value ~= "" then
    table.insert(options, { key = key, value = value })
  end
end

local function parseHostLine(value)
  local aliases = {}
  for alias in value:gmatch("%S+") do
    table.insert(aliases, alias)
  end
  return aliases
end

local function isBlockStart(line)
  local trimmed = trim(line)
  if trimmed == "" or trimmed:match("^#") then
    return false
  end
  -- only unindented Host/Match start blocks
  if line:match("^[%s]") then
    return false
  end
  local key = trimmed:match("^(%S+)")
  if not key then
    return false
  end
  key = key:lower()
  return key == "host" or key == "match"
end

local function parseConfig(content)
  local segs = {}
  local current = nil

  local function flush()
    if current then
      table.insert(segs, current)
      current = nil
    end
  end

  for line in (tostring(content or "") .. "\n"):gmatch("(.-)\n") do
    if isBlockStart(line) then
      flush()
      local trimmed = trim(line)
      local key, value = trimmed:match("^(%S+)%s*(.*)$")
      key = key:lower()
      if key == "host" then
        local aliases = parseHostLine(value)
        current = {
          kind = "host",
          aliases = aliases,
          options = {},
          wildcard = isWildcardHost(aliases),
          rawLines = { line },
        }
      else
        current = {
          kind = "raw",
          rawLines = { line },
        }
      end
    else
      if not current then
        current = { kind = "raw", rawLines = {} }
      end
      table.insert(current.rawLines, line)
      if current.kind == "host" then
        local trimmed = trim(line)
        if trimmed ~= "" and not trimmed:match("^#") then
          local k, v = trimmed:match("^(%S+)%s+(.+)$")
          if k and v then
            table.insert(current.options, { key = k, value = trim(v) })
          end
        end
      end
    end
  end
  flush()
  return segs
end

local function renderHostSegment(seg)
  local lines = {}
  table.insert(lines, "Host " .. table.concat(seg.aliases, " "))
  for _, opt in ipairs(seg.options) do
    table.insert(lines, "    " .. opt.key .. " " .. opt.value)
  end
  return lines
end

local function renderConfig(segs)
  local lines = {}
  for i, seg in ipairs(segs) do
    local part
    if seg.kind == "host" and seg.dirty then
      part = renderHostSegment(seg)
    else
      part = seg.rawLines
    end
    for _, line in ipairs(part) do
      table.insert(lines, line)
    end
    -- ensure blank line between segments (except trailing)
    if i < #segs then
      local last = lines[#lines]
      if last ~= "" then
        table.insert(lines, "")
      end
    end
  end
  -- trim trailing empties then end with newline
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function hostId(seg)
  return table.concat(seg.aliases, " ")
end

local function hostSummary(seg)
  local id = hostId(seg)
  local alias = seg.aliases[1] or ""
  local hostname = optionGet(seg.options, "HostName") or optionGet(seg.options, "Hostname") or ""
  local user = optionGet(seg.options, "User") or ""
  local port = optionGet(seg.options, "Port") or "22"
  local identity = optionGet(seg.options, "IdentityFile") or ""
  local proxy = optionGet(seg.options, "ProxyJump") or optionGet(seg.options, "ProxyCommand") or ""
  local cert = optionGet(seg.options, "CertificateFile") or ""
  return {
    id = id,
    aliases = seg.aliases,
    alias = id, -- display / form field supports space-separated aliases
    hostname = hostname,
    user = user,
    port = port,
    identityFile = identity,
    proxyJump = proxy,
    certificateFile = cert,
    wildcard = seg.wildcard == true,
    options = seg.options,
  }
end

local function findHostSegment(idOrAlias)
  idOrAlias = trim(idOrAlias)
  for _, seg in ipairs(segments) do
    if seg.kind == "host" then
      if hostId(seg) == idOrAlias then
        return seg
      end
      for _, a in ipairs(seg.aliases) do
        if a == idOrAlias then
          return seg
        end
      end
    end
  end
  return nil
end

local function hostAliasTaken(alias, excludeSeg)
  alias = trim(alias)
  for _, seg in ipairs(segments) do
    if seg.kind == "host" and seg ~= excludeSeg then
      for _, a in ipairs(seg.aliases) do
        if a == alias then
          return true
        end
      end
    end
  end
  return false
end

local function skipKeyName(name)
  local lower = name:lower()
  if lower == "config" or lower == "known_hosts" or lower == "known_hosts.old" then
    return true
  end
  if lower == "authorized_keys" or lower == "authorized_keys2" then
    return true
  end
  if lower:match("%.backup") or lower:match("^config%-") or lower:match("^config%.") then
    return true
  end
  if lower:match("%.old$") or lower == "environment" then
    return true
  end
  if name:match("^%.") then
    return true
  end
  return false
end

local function publishSnapshot()
  snapshot.busy = actionBusy
  snapshot.configPath = configPath()
  snapshot.sshDir = sshDir()
  snapshot.hosts = {}
  local hostCount = 0
  for _, seg in ipairs(segments) do
    if seg.kind == "host" and not seg.wildcard then
      table.insert(snapshot.hosts, hostSummary(seg))
      hostCount += 1
    elseif seg.kind == "host" and seg.wildcard then
      local summary = hostSummary(seg)
      summary.id = table.concat(seg.aliases, " ")
      summary.alias = summary.id
      table.insert(snapshot.hosts, summary)
    end
  end
  snapshot.hostCount = hostCount
  snapshot.keyCount = #(snapshot.keys or {})
  noctalia.state.set(STATE_KEY, snapshot)
end

local function loadConfig()
  local path = configPath()
  if not noctalia.fileExists(path) then
    segments = {}
    snapshot.available = false
    snapshot.error = noctalia.tr("result.config_missing", { path = path })
    return false
  end
  local content = noctalia.readFile(path)
  if type(content) ~= "string" then
    segments = {}
    snapshot.available = false
    snapshot.error = noctalia.tr("result.config_missing", { path = path })
    return false
  end
  segments = parseConfig(content)
  snapshot.available = true
  snapshot.error = ""
  return true
end

local function backupConfig(path)
  if noctalia.getConfig("backup_on_write") == false then
    return true
  end
  local stamp = tostring(os.time())
  local dest = path .. ".bak." .. stamp
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" then
    return false, "could not read config for backup"
  end
  local ok, err = noctalia.writeFile(dest, raw)
  if not ok then
    return false, err or "backup write failed"
  end
  noctalia.runAsync(shellCommand({ "chmod", "600", dest }))
  return true
end

local function writeConfig()
  local path = configPath()
  local bakOk, bakErr = backupConfig(path)
  if not bakOk then
    return false, bakErr
  end
  local body = renderConfig(segments)
  local ok, err = noctalia.writeFile(path, body)
  if not ok then
    return false, err or "write failed"
  end
  noctalia.runAsync(shellCommand({ "chmod", "600", path }))
  -- clear dirty flags and refresh rawLines from rendered host segments
  for _, seg in ipairs(segments) do
    if seg.kind == "host" and seg.dirty then
      seg.rawLines = renderHostSegment(seg)
      seg.dirty = false
    end
  end
  return true
end

local function parseFingerprintLine(line)
  -- e.g. 256 SHA256:xxxx comment (ED25519)
  line = trim(line)
  local bits, fp, rest = line:match("^(%d+)%s+(%S+)%s+(.*)$")
  if not bits then
    return nil
  end
  local keyType = rest:match("%(([^)]+)%)$") or ""
  local comment = trim((rest:gsub("%s*%([^)]+%)$", "")))
  return {
    bits = bits,
    fingerprint = fp,
    comment = comment,
    keyType = keyType,
  }
end

local function listKeys(callback)
  local dir = sshDir()
  local names, err = noctalia.listDir(dir)
  if type(names) ~= "table" then
    callback({}, err or "listDir failed")
    return
  end

  local candidates = {}
  local seen = {}
  for _, name in ipairs(names) do
    if not skipKeyName(name) then
      local path = dir .. "/" .. name
      local info = noctalia.fileInfo(path)
      if info and not info.isDir then
        if name:match("%.pub$") then
          local base = name:gsub("%.pub$", "")
          if not seen[base] then
            seen[base] = true
            table.insert(candidates, base)
          end
        else
          -- private key if matching .pub exists or name looks like a key
          local looksLike = name:match("^id_") or name:match("_rsa") or name:match("_ed25519")
            or name:match("_ecdsa") or noctalia.fileExists(path .. ".pub")
          if looksLike and not seen[name] then
            seen[name] = true
            table.insert(candidates, name)
          end
        end
      end
    end
  end
  table.sort(candidates)

  local keys = {}
  local index = 1

  local function nextKey()
    if index > #candidates then
      callback(keys, nil)
      return
    end
    local base = candidates[index]
    index += 1
    local priv = dir .. "/" .. base
    local pub = priv .. ".pub"
    local hasPriv = noctalia.fileExists(priv)
    local hasPub = noctalia.fileExists(pub)
    if not hasPriv and not hasPub then
      nextKey()
      return
    end

    local entry = {
      id = base,
      name = base,
      privatePath = hasPriv and priv or "",
      publicPath = hasPub and pub or "",
      hasPrivate = hasPriv,
      hasPublic = hasPub,
      fingerprint = "",
      bits = "",
      keyType = "",
      comment = "",
      inAgent = false,
    }

    local fpSource = hasPub and pub or (hasPriv and priv or "")
    if fpSource == "" then
      table.insert(keys, entry)
      nextKey()
      return
    end

    noctalia.runAsync(shellCommand({ "ssh-keygen", "-lf", fpSource }), function(result)
      if result and result.exitCode == 0 then
        local parsed = parseFingerprintLine((result.stdout or ""):match("([^\n]+)"))
        if parsed then
          entry.fingerprint = parsed.fingerprint
          entry.bits = parsed.bits
          entry.keyType = parsed.keyType
          entry.comment = parsed.comment
        end
      end
      table.insert(keys, entry)
      nextKey()
    end)
  end

  nextKey()
end

local function listAgentFingerprints(callback)
  noctalia.runAsync("ssh-add -l 2>/dev/null", function(result)
    local fps = {}
    if not result or result.exitCode ~= 0 then
      callback(fps)
      return
    end
    for line in (tostring(result.stdout or "") .. "\n"):gmatch("(.-)\n") do
      local parsed = parseFingerprintLine(line)
      if parsed and parsed.fingerprint ~= "" then
        fps[parsed.fingerprint] = true
      end
    end
    callback(fps)
  end)
end

local refreshAll

refreshAll = function()
  if refreshPending then
    refreshAgain = true
    return
  end
  refreshPending = true
  refreshAgain = false
  refreshGeneration += 1
  local generation = refreshGeneration

  snapshot.loading = true
  publishSnapshot()

  loadConfig()

  listAgentFingerprints(function(agentFps)
    if generation ~= refreshGeneration then
      return
    end
    listKeys(function(keys, keyErr)
      if generation ~= refreshGeneration then
        return
      end
      local agentCount = 0
      for _, key in ipairs(keys) do
        if key.fingerprint ~= "" and agentFps[key.fingerprint] then
          key.inAgent = true
          agentCount += 1
        end
      end
      snapshot.keys = keys
      snapshot.agentKeys = agentCount
      if keyErr and snapshot.error == "" then
        snapshot.error = tostring(keyErr)
      end
      snapshot.loading = false
      snapshot.updatedAt = os.time()
      refreshPending = false

      local sig = snapshot.configPath .. "|" .. tostring(snapshot.hostCount) .. "|" .. tostring(#keys) .. "|" .. tostring(agentCount)
      for _, h in ipairs(snapshot.hosts) do
        sig ..= "|" .. h.alias
      end
      updateRevision(sig)
      publishSnapshot()

      if refreshAgain then
        refreshAll()
      end
    end)
  end)
end

local function finishAction(command, ok, message)
  actionBusy = false
  actionResult(command, ok, message)
  if ok then
    notifyOk(message)
  else
    notifyErr(message)
  end
  publishSnapshot()
  refreshAll()
end

local function parseAliasesField(text)
  local aliases = {}
  for alias in trim(text):gmatch("%S+") do
    table.insert(aliases, alias)
  end
  return aliases
end

local function applyHostFields(seg, command)
  local aliases = parseAliasesField(command.alias)
  seg.aliases = aliases
  seg.wildcard = isWildcardHost(aliases)
  local options = {}
  local function add(key, value)
    value = trim(value)
    if value ~= "" then
      table.insert(options, { key = key, value = value })
    end
  end
  add("HostName", command.hostname)
  add("User", command.user)
  add("Port", command.port)
  add("IdentityFile", command.identityFile)
  add("ProxyJump", command.proxyJump)
  add("CertificateFile", command.certificateFile)

  -- extra options: lines "Key value"
  local extra = tostring(command.extra or "")
  local reserved = {
    hostname = true, user = true, port = true,
    identityfile = true, proxyjump = true, certificatefile = true,
  }
  for line in (extra .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" and not line:match("^#") then
      local k, v = line:match("^(%S+)%s+(.+)$")
      if k and v and not reserved[k:lower()] then
        table.insert(options, { key = k, value = trim(v) })
      end
    end
  end
  seg.options = options
  seg.dirty = true
end

local function saveHost(command, isUpdate)
  local aliases = parseAliasesField(command.alias)
  if #aliases == 0 then
    actionResult(command, false, noctalia.tr("host.required"))
    return
  end
  for _, alias in ipairs(aliases) do
    if not isValidAlias(alias) then
      actionResult(command, false, noctalia.tr("host.invalid_alias"))
      return
    end
  end

  local displayName = table.concat(aliases, " ")

  if isUpdate then
    local seg = findHostSegment(command.id or aliases[1])
    if not seg then
      actionResult(command, false, noctalia.tr("result.failed", { error = "host not found" }))
      return
    end
    if seg.wildcard then
      actionResult(command, false, noctalia.tr("host.wildcard_readonly"))
      return
    end
    for _, alias in ipairs(aliases) do
      if hostAliasTaken(alias, seg) then
        actionResult(command, false, noctalia.tr("host.duplicate"))
        return
      end
    end
    applyHostFields(seg, command)
  else
    for _, alias in ipairs(aliases) do
      if hostAliasTaken(alias, nil) then
        actionResult(command, false, noctalia.tr("host.duplicate"))
        return
      end
    end
    local seg = {
      kind = "host",
      aliases = aliases,
      options = {},
      wildcard = false,
      rawLines = {},
      dirty = true,
    }
    applyHostFields(seg, command)
    table.insert(segments, seg)
  end

  local ok, err = writeConfig()
  if not ok then
    loadConfig()
    finishAction(command, false, noctalia.tr("result.failed", { error = err or "save failed" }))
    return
  end
  finishAction(command, true, noctalia.tr("result.config_saved", { name = displayName }))
end

local function removeHost(command)
  local alias = trim(command.id or command.alias)
  local index = nil
  for i, seg in ipairs(segments) do
    if seg.kind == "host" and not seg.wildcard then
      for _, a in ipairs(seg.aliases) do
        if a == alias then
          index = i
          break
        end
      end
    end
    if index then break end
  end
  if not index then
    actionResult(command, false, noctalia.tr("result.failed", { error = "host not found" }))
    return
  end
  table.remove(segments, index)
  local ok, err = writeConfig()
  if not ok then
    loadConfig()
    finishAction(command, false, noctalia.tr("result.failed", { error = err or "save failed" }))
    return
  end
  finishAction(command, true, noctalia.tr("result.config_removed", { name = alias }))
end

local function connectHost(command)
  local id = trim(command.id or command.alias)
  if id == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing host" }))
    return
  end
  -- Prefer first concrete alias for multi-alias Host lines
  local alias = id:match("^(%S+)") or id
  local extra = trim(command.extraArgs or "")
  local cmd = "ssh " .. (extra ~= "" and (extra .. " ") or "") .. shellQuote(alias)
  noctalia.runInTerminal(cmd)
  actionResult(command, true, noctalia.tr("result.connect_started", { name = alias }))
  if shouldNotify() then
    notifyOk(noctalia.tr("result.connect_started", { name = alias }))
  end
end

local function copyPublicKey(command)
  local name = trim(command.id or command.name)
  local dir = sshDir()
  local pub = dir .. "/" .. name .. ".pub"
  if not name:match("%.pub$") and not noctalia.fileExists(pub) then
    -- name might already include path base only
  end
  if not noctalia.fileExists(pub) then
    -- try exact
    local exact = dir .. "/" .. name
    if name:match("%.pub$") and noctalia.fileExists(exact) then
      pub = exact
    else
      actionResult(command, false, noctalia.tr("result.no_pubkey", { name = name }))
      notifyErr(noctalia.tr("result.no_pubkey", { name = name }))
      return
    end
  end
  local content = noctalia.readFile(pub)
  if type(content) ~= "string" or content == "" then
    actionResult(command, false, noctalia.tr("result.no_pubkey", { name = name }))
    return
  end
  content = trim(content)
  noctalia.copyToClipboard(content, "text/plain")
  actionResult(command, true, noctalia.tr("result.key_copied"))
  notifyOk(noctalia.tr("result.key_copied"))
end

local function generateKey(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  local name = trim(command.name)
  if name == "" then
    actionResult(command, false, noctalia.tr("key.required"))
    return
  end
  if name:find("[/\\]") or name:match("%.%.") then
    actionResult(command, false, noctalia.tr("key.invalid_name"))
    return
  end
  if not name:match("^[%w._@+-]+$") then
    actionResult(command, false, noctalia.tr("key.invalid_name"))
    return
  end

  local dir = sshDir()
  local path = dir .. "/" .. name
  if noctalia.fileExists(path) or noctalia.fileExists(path .. ".pub") then
    actionResult(command, false, noctalia.tr("key.exists"))
    return
  end

  local keyType = trim(command.keyType)
  if keyType == "" then
    keyType = tostring(noctalia.getConfig("default_key_type") or "ed25519")
  end
  local comment = trim(command.comment)
  local passphrase = type(command.passphrase) == "string" and command.passphrase or ""

  local args = { "ssh-keygen", "-t", keyType, "-f", path, "-q" }
  if keyType == "rsa" then
    local bits = tonumber(command.bits) or tonumber(noctalia.getConfig("rsa_bits")) or 4096
    table.insert(args, "-b")
    table.insert(args, tostring(math.floor(bits)))
  end
  if comment ~= "" then
    table.insert(args, "-C")
    table.insert(args, comment)
  end
  -- -N passphrase (empty string allowed)
  table.insert(args, "-N")
  table.insert(args, passphrase)

  actionBusy = true
  publishSnapshot()

  local launched = noctalia.runAsync(shellCommand(args), function(result)
    local ok = result ~= nil and result.exitCode == 0 and not result.timedOut
    if ok then
      noctalia.runAsync(shellCommand({ "chmod", "600", path }))
      noctalia.runAsync(shellCommand({ "chmod", "644", path .. ".pub" }))
      finishAction(command, true, noctalia.tr("result.key_generated", { name = name }))
    else
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout))
      if err == "" then
        err = "ssh-keygen failed"
      end
      -- never include passphrase in error paths
      finishAction(command, false, noctalia.tr("result.failed", { error = err }))
    end
  end, 120000)

  if not launched then
    actionBusy = false
    actionResult(command, false, noctalia.tr("result.failed", { error = "could not start ssh-keygen" }))
    publishSnapshot()
  end
end

local function agentAdd(command)
  local name = trim(command.id or command.name)
  local path = sshDir() .. "/" .. name
  if not noctalia.fileExists(path) then
    actionResult(command, false, noctalia.tr("result.failed", { error = "private key not found" }))
    return
  end
  actionBusy = true
  publishSnapshot()
  noctalia.runAsync(shellCommand({ "ssh-add", path }), function(result)
    local ok = result ~= nil and result.exitCode == 0
    local err = trim(result and result.stderr or "")
    if ok then
      finishAction(command, true, noctalia.tr("result.agent_added", { name = name }))
    else
      finishAction(command, false, noctalia.tr("result.failed", { error = err ~= "" and err or "ssh-add failed" }))
    end
  end, 60000)
end

local function agentRemove(command)
  local name = trim(command.id or command.name)
  local path = sshDir() .. "/" .. name
  if not noctalia.fileExists(path) then
    actionResult(command, false, noctalia.tr("result.failed", { error = "private key not found" }))
    return
  end
  actionBusy = true
  publishSnapshot()
  noctalia.runAsync(shellCommand({ "ssh-add", "-d", path }), function(result)
    local ok = result ~= nil and result.exitCode == 0
    local err = trim(result and result.stderr or "")
    if ok then
      finishAction(command, true, noctalia.tr("result.agent_removed", { name = name }))
    else
      finishAction(command, false, noctalia.tr("result.failed", { error = err ~= "" and err or "ssh-add -d failed" }))
    end
  end)
end

local function openSshDir()
  noctalia.runAsync(shellCommand({ "xdg-open", sshDir() }))
end

local function extraOptionsText(options)
  local reserved = {
    hostname = true, user = true, port = true,
    identityfile = true, proxyjump = true, certificatefile = true,
  }
  local lines = {}
  for _, opt in ipairs(options or {}) do
    if not reserved[opt.key:lower()] then
      table.insert(lines, opt.key .. " " .. opt.value)
    end
  end
  return table.concat(lines, "\n")
end

local function executeAction(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end

  if command.action == "refresh" then
    refreshAll()
    return
  end
  if command.action == "open_dir" then
    openSshDir()
    actionResult(command, true, noctalia.tr("result.success"))
    return
  end
  if command.action == "connect" then
    connectHost(command)
    return
  end
  if command.action == "copy_pub" then
    copyPublicKey(command)
    return
  end
  if command.action == "get_host_extra" then
    local seg = findHostSegment(command.id)
    local text = seg and extraOptionsText(seg.options) or ""
    actionResult(command, true, "", { extra = text })
    return
  end

  if command.action == "add_host" then
    saveHost(command, false)
    return
  end
  if command.action == "update_host" then
    saveHost(command, true)
    return
  end
  if command.action == "remove_host" then
    removeHost(command)
    return
  end
  if command.action == "generate_key" then
    generateKey(command)
    return
  end
  if command.action == "agent_add" then
    agentAdd(command)
    return
  end
  if command.action == "agent_remove" then
    agentRemove(command)
    return
  end

  actionResult(command, false, `Unknown action: {command.action}`)
end

-- boot
noctalia.state.watch(COMMAND_KEY, executeAction)
noctalia.setUpdateInterval(refreshIntervalMs())
refreshAll()

function update()
  refreshAll()
end

function onConfigChanged()
  noctalia.setUpdateInterval(refreshIntervalMs())
  refreshAll()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refreshAll()
  end
end
