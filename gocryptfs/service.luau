--!nonstrict
-- Gocryptfs backend. Owns volume config, mount status, init, and mount/unmount.
-- Other entries talk to this service through noctalia.state only.

local VOLUMES_FILE = "volumes.json"
local STATE_KEY = "gocrypt_snapshot"
local COMMAND_KEY = "gocrypt_command"
local RESULT_KEY = "gocrypt_action_result"

local snapshot = {
  available = false,
  loading = true,
  busy = false,
  volumes = {},
  mountedCount = 0,
  totalCount = 0,
  error = "",
  updatedAt = 0,
  revision = 0,
}

local refreshGeneration = 0
local refreshPending = false
local refreshAgain = false
local actionBusy = false
local dataSignature = ""
local volumes = {} -- array of volume tables
local nextId = 1
local autoMountScheduled = false
local autoMountQueue = {}

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

local function volumesPath()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return nil
  end
  return dir .. "/" .. VOLUMES_FILE
end

local function passfilesDir()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return nil
  end
  local path = dir .. "/passfiles"
  noctalia.mkdirAll(path)
  return path
end

local function newVolumeId()
  local id = "vol-" .. tostring(os.time()) .. "-" .. tostring(nextId)
  nextId += 1
  return id
end

local function normalizeVolume(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local name = trim(raw.name)
  local cipherDir = trim(raw.cipherDir or raw.cipher_dir)
  local mountPoint = trim(raw.mountPoint or raw.mount_point)
  if name == "" or cipherDir == "" or mountPoint == "" then
    return nil
  end
  local passfile = trim(raw.passfile)
  local autoMount = raw.autoMount
  if autoMount == nil then
    autoMount = raw.auto_mount
  end
  if autoMount == nil then
    -- default: auto-mount when a passfile is configured
    autoMount = passfile ~= ""
  else
    autoMount = autoMount == true
  end
  return {
    id = trim(raw.id) ~= "" and trim(raw.id) or newVolumeId(),
    name = name,
    cipherDir = cipherDir,
    mountPoint = mountPoint,
    passfile = passfile,
    allowOther = raw.allowOther == true or raw.allow_other == true,
    readOnly = raw.readOnly == true or raw.read_only == true,
    autoMount = autoMount,
  }
end

local function loadVolumes()
  local path = volumesPath()
  volumes = {}
  if not path then
    return
  end
  local raw = noctalia.readFile(path)
  if not raw or raw == "" then
    return
  end
  local decoded, err = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    noctalia.log(`gocryptfs: could not parse volumes.json: {err or "unknown"}`)
    return
  end
  local list = decoded.volumes
  if type(list) ~= "table" then
    return
  end
  for _, item in ipairs(list) do
    local vol = normalizeVolume(item)
    if vol then
      table.insert(volumes, vol)
    end
  end
end

local function saveVolumes()
  local path = volumesPath()
  if not path then
    return false, "no plugin data dir"
  end
  local payload = { volumes = volumes }
  local encoded, err = noctalia.json.encode(payload, true)
  if not encoded then
    return false, err or "encode failed"
  end
  local ok, writeErr = noctalia.writeFile(path, encoded)
  if not ok then
    return false, writeErr or "write failed"
  end
  return true
end

local function findVolume(id)
  id = trim(id)
  for _, vol in ipairs(volumes) do
    if vol.id == id then
      return vol
    end
  end
  return nil
end

local function pathEqual(a, b)
  a = expand(a)
  b = expand(b)
  a = a:gsub("/+$", "")
  b = b:gsub("/+$", "")
  if a == "" then a = "/" end
  if b == "" then b = "/" end
  return a == b
end

local function parseMounts(stdout)
  local mounts = {}
  for line in (tostring(stdout or "") .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" then
      local source, target, fstype = line:match("^(%S+)%s+(%S+)%s+(%S+)")
      if fstype and (fstype == "fuse.gocryptfs" or fstype:find("gocryptfs", 1, true)) then
        local function unescape(s)
          return (s:gsub("\\(%d%d%d)", function(oct)
            return string.char(tonumber(oct, 8))
          end))
        end
        mounts[unescape(target)] = unescape(source)
      end
    end
  end
  return mounts
end

local function isMounted(vol, mounts)
  local mp = expand(vol.mountPoint)
  mp = mp:gsub("/+$", "")
  if mp == "" then mp = "/" end
  if mounts[mp] then
    return true
  end
  for target, _ in pairs(mounts) do
    if pathEqual(target, vol.mountPoint) then
      return true
    end
  end
  return false
end

local function publishSnapshot()
  snapshot.busy = actionBusy
  snapshot.totalCount = #volumes
  snapshot.volumes = {}
  local mounted = 0
  for _, vol in ipairs(volumes) do
    local entry = {
      id = vol.id,
      name = vol.name,
      cipherDir = vol.cipherDir,
      mountPoint = vol.mountPoint,
      passfile = vol.passfile,
      allowOther = vol.allowOther,
      readOnly = vol.readOnly,
      autoMount = vol.autoMount == true,
      mounted = vol.mounted == true,
      cipherExists = vol.cipherExists == true,
      initialized = vol.initialized == true,
    }
    if entry.mounted then
      mounted += 1
    end
    table.insert(snapshot.volumes, entry)
  end
  snapshot.mountedCount = mounted
  noctalia.state.set(STATE_KEY, snapshot)
end

local function updateRevision(signature)
  if signature ~= dataSignature then
    dataSignature = signature
    snapshot.revision += 1
  end
end

local function refreshIntervalMs()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 3
  seconds = math.max(1, math.min(60, math.floor(seconds)))
  return seconds * 1000
end

local function shouldNotify()
  return noctalia.getConfig("notify_on_action") ~= false
end

local function autoMountEnabled()
  return noctalia.getConfig("auto_mount") ~= false
end

local refreshAll
local mountVolume
local kickAutoMount

local refreshStartedAt = 0

refreshAll = function()
  -- Recover if an in-flight /proc/mounts callback never completed.
  if refreshPending and refreshStartedAt > 0 and (os.time() - refreshStartedAt) >= 15 then
    noctalia.log("gocryptfs: forcing stuck refresh reset")
    refreshPending = false
    refreshStartedAt = 0
    snapshot.loading = false
  end

  if refreshPending then
    refreshAgain = true
    return
  end
  refreshPending = true
  refreshAgain = false
  refreshStartedAt = os.time()
  refreshGeneration += 1
  local generation = refreshGeneration

  if not noctalia.commandExists("gocryptfs") then
    snapshot.available = false
    snapshot.loading = false
    snapshot.error = noctalia.tr("result.gocryptfs_missing")
    for _, vol in ipairs(volumes) do
      vol.mounted = false
      vol.cipherExists = noctalia.fileExists(expand(vol.cipherDir))
      vol.initialized = noctalia.fileExists(expand(vol.cipherDir) .. "/gocryptfs.conf")
    end
    refreshPending = false
    refreshStartedAt = 0
    updateRevision("gocryptfs-missing")
    publishSnapshot()
    return
  end

  snapshot.available = true
  -- Avoid flashing "Checking mounts…" on every poll when we already have data.
  if (snapshot.updatedAt or 0) == 0 then
    snapshot.loading = true
    publishSnapshot()
  end

  local started = noctalia.runAsync("cat /proc/mounts", function(result)
    if generation ~= refreshGeneration then
      return
    end
    local mounts = {}
    if result and result.exitCode == 0 then
      mounts = parseMounts(result.stdout)
      snapshot.error = ""
    else
      snapshot.error = trim(result and result.stderr)
      if snapshot.error == "" then
        snapshot.error = "could not read /proc/mounts"
      end
    end

    local sigParts = {}
    for _, vol in ipairs(volumes) do
      vol.mounted = isMounted(vol, mounts)
      local cipher = expand(vol.cipherDir)
      vol.cipherExists = noctalia.fileExists(cipher)
      vol.initialized = noctalia.fileExists(cipher .. "/gocryptfs.conf")
      table.insert(sigParts, vol.id .. ":" .. tostring(vol.mounted) .. ":" .. vol.mountPoint)
    end

    snapshot.loading = false
    snapshot.updatedAt = os.time()
    refreshPending = false
    refreshStartedAt = 0
    updateRevision(table.concat(sigParts, "|") .. "|" .. tostring(#volumes))
    publishSnapshot()

    if not autoMountScheduled then
      autoMountScheduled = true
      if autoMountEnabled() then
        for _, vol in ipairs(volumes) do
          if vol.autoMount and trim(vol.passfile) ~= "" and not vol.mounted then
            table.insert(autoMountQueue, vol.id)
          end
        end
        if #autoMountQueue > 0 then
          noctalia.log(`gocryptfs: auto-mount queue has {#autoMountQueue} volume(s)`)
          kickAutoMount()
        end
      end
    end

    if refreshAgain then
      refreshAgain = false
      refreshAll()
    end
  end)

  if not started then
    snapshot.loading = false
    snapshot.error = "could not start status check"
    refreshPending = false
    refreshStartedAt = 0
    publishSnapshot()
  end
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

local function notifyOk(message)
  if shouldNotify() then
    noctalia.notify(noctalia.tr("title"), message)
  end
end

local function notifyErr(message)
  noctalia.notifyError(noctalia.tr("title"), message)
end

local function unmountBinary()
  if noctalia.commandExists("fusermount3") then
    return "fusermount3"
  end
  if noctalia.commandExists("fusermount") then
    return "fusermount"
  end
  return nil
end

local function finishAction(command, ok, message)
  actionBusy = false
  local silent = command and command.silent == true
  actionResult(command, ok, message)
  if not silent then
    if ok then
      notifyOk(message)
    else
      notifyErr(message)
    end
  elseif not ok then
    -- still surface auto-mount failures
    notifyErr(message)
  end
  -- Always bump revision so panel/widget re-render even if mount flags
  -- were updated optimistically to the same shape as a prior sample.
  updateRevision(
    "action:"
      .. tostring(command and command.action or "")
      .. ":"
      .. tostring(command and command.id or "")
      .. ":"
      .. tostring(ok)
      .. ":"
      .. tostring(os.time())
      .. ":"
      .. tostring(snapshot.mountedCount)
  )
  publishSnapshot()
  -- Confirm against /proc/mounts (may be briefly stale; optimistic flags already set).
  refreshPending = false
  refreshAgain = false
  refreshAll()
  if #autoMountQueue > 0 then
    kickAutoMount()
  end
end

local function ensureDir(path)
  path = expand(path)
  if noctalia.fileExists(path) then
    local info = noctalia.fileInfo(path)
    if info and info.isDir then
      return true
    end
    return false, "not a directory"
  end
  local ok, err = noctalia.mkdirAll(path)
  if not ok then
    return false, err or "mkdir failed"
  end
  return true
end

local function ensureMountPoint(path)
  path = expand(path)
  if noctalia.fileExists(path) then
    local info = noctalia.fileInfo(path)
    if info and info.isDir then
      return true
    end
    return false, "not a directory"
  end
  if noctalia.getConfig("create_mountpoint") == false then
    return false, "does not exist"
  end
  return ensureDir(path)
end

local function removePassfile(path)
  if path and path ~= "" then
    noctalia.removeFile(path)
  end
end

local function writeSecurePassfile(path, password)
  local written, werr = noctalia.writeFile(path, password .. "\n")
  if not written then
    return false, werr or "write failed"
  end
  noctalia.runAsync(shellCommand({ "chmod", "600", path }))
  return true
end

local function defaultPassfilePath(volumeId)
  local dir = passfilesDir()
  if not dir then
    return nil
  end
  return dir .. "/" .. volumeId .. ".pass"
end

mountVolume = function(command)
  local vol = findVolume(command.id)
  if not vol then
    actionResult(command, false, noctalia.tr("result.not_found"))
    kickAutoMount()
    return
  end
  if vol.mounted then
    actionResult(command, false, noctalia.tr("result.already_mounted", { name = vol.name }))
    kickAutoMount()
    return
  end

  local cipher = expand(vol.cipherDir)
  local mount = expand(vol.mountPoint)

  if not noctalia.fileExists(cipher) then
    local msg = noctalia.tr("result.cipher_missing", { path = cipher })
    actionResult(command, false, msg)
    if command.silent ~= true then
      notifyErr(msg)
    else
      notifyErr(msg)
    end
    kickAutoMount()
    return
  end

  local okMp, mpErr = ensureMountPoint(mount)
  if not okMp then
    local msg = noctalia.tr("result.mount_create_failed", { path = mount }) .. " (" .. tostring(mpErr) .. ")"
    actionResult(command, false, msg)
    notifyErr(msg)
    kickAutoMount()
    return
  end

  local args = { "gocryptfs", "-q" }
  if vol.readOnly then
    table.insert(args, "-ro")
  end
  if vol.allowOther then
    table.insert(args, "-allow_other")
  end

  local tempPassfile = nil
  local passfile = trim(vol.passfile)
  local password = type(command.password) == "string" and command.password or ""

  if passfile ~= "" then
    local pf = expand(passfile)
    if not noctalia.fileExists(pf) then
      local msg = noctalia.tr("result.failed", { error = "passfile not found: " .. pf })
      actionResult(command, false, msg)
      notifyErr(msg)
      kickAutoMount()
      return
    end
    table.insert(args, "-passfile")
    table.insert(args, pf)
  elseif password ~= "" then
    local dir = noctalia.pluginDataDir()
    if not dir then
      actionResult(command, false, noctalia.tr("result.failed", { error = "no plugin data dir" }))
      kickAutoMount()
      return
    end
    tempPassfile = dir .. "/.pass-" .. vol.id .. "-" .. tostring(os.time())
    local written, werr = writeSecurePassfile(tempPassfile, password)
    if not written then
      actionResult(command, false, noctalia.tr("result.failed", { error = werr or "could not write passfile" }))
      kickAutoMount()
      return
    end
    table.insert(args, "-passfile")
    table.insert(args, tempPassfile)
  else
    actionResult(command, false, noctalia.tr("panel.password_required"))
    kickAutoMount()
    return
  end

  table.insert(args, cipher)
  table.insert(args, mount)

  actionBusy = true
  publishSnapshot()

  local launched = noctalia.runAsync(shellCommand(args), function(result)
    removePassfile(tempPassfile)
    local ok = result ~= nil and result.exitCode == 0 and not result.timedOut
    local message
    if ok then
      -- Optimistic: UI must flip immediately; refreshAll confirms via /proc/mounts.
      vol.mounted = true
      message = noctalia.tr("result.mounted", { name = vol.name })
    else
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout))
      if err == "" then
        err = result and result.timedOut and "timed out" or "unknown error"
      end
      message = noctalia.tr("result.failed", { error = err })
    end
    finishAction(command, ok, message)
  end, 60000)

  if not launched then
    removePassfile(tempPassfile)
    actionBusy = false
    actionResult(command, false, noctalia.tr("result.failed", { error = "could not start gocryptfs" }))
    publishSnapshot()
    kickAutoMount()
  end
end

kickAutoMount = function()
  if actionBusy then
    return
  end
  if #autoMountQueue == 0 then
    return
  end
  local id = table.remove(autoMountQueue, 1)
  local vol = findVolume(id)
  if not vol or vol.mounted or trim(vol.passfile) == "" then
    kickAutoMount()
    return
  end
  noctalia.log(`gocryptfs: auto-mounting {vol.name}`)
  mountVolume({
    action = "mount",
    id = id,
    requestId = "auto-" .. id,
    silent = true,
  })
end

local function unmountVolume(command)
  local vol = findVolume(command.id)
  if not vol then
    actionResult(command, false, noctalia.tr("result.not_found"))
    return
  end
  if not vol.mounted then
    actionResult(command, false, noctalia.tr("result.not_mounted", { name = vol.name }))
    return
  end

  local bin = unmountBinary()
  if not bin then
    actionResult(command, false, noctalia.tr("result.failed", { error = "fusermount not found" }))
    return
  end

  local mount = expand(vol.mountPoint)
  local args = { bin, "-u", mount }

  actionBusy = true
  publishSnapshot()

  local launched = noctalia.runAsync(shellCommand(args), function(result)
    local ok = result ~= nil and result.exitCode == 0 and not result.timedOut
    local message
    if ok then
      -- Optimistic: list must show unmounted even if the follow-up
      -- /proc/mounts refresh is delayed or coalesced with an in-flight poll.
      vol.mounted = false
      message = noctalia.tr("result.unmounted", { name = vol.name })
    else
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout))
      if err == "" then
        err = "unknown error"
      end
      message = noctalia.tr("result.failed", { error = err })
    end
    finishAction(command, ok, message)
  end, 30000)

  if not launched then
    actionBusy = false
    actionResult(command, false, noctalia.tr("result.failed", { error = "could not start fusermount" }))
    publishSnapshot()
  end
end

local function openMount(command)
  local vol = findVolume(command.id)
  if not vol then
    actionResult(command, false, noctalia.tr("result.not_found"))
    return
  end
  local path = expand(vol.mountPoint)
  if not vol.mounted then
    if not noctalia.fileExists(path) then
      actionResult(command, false, noctalia.tr("result.not_mounted", { name = vol.name }))
      return
    end
  end
  noctalia.runAsync(shellCommand({ "xdg-open", path }))
  actionResult(command, true, noctalia.tr("result.success"))
end

local function conflictsWith(vol, excludeId)
  for _, other in ipairs(volumes) do
    if other.id ~= excludeId then
      if pathEqual(other.cipherDir, vol.cipherDir) or pathEqual(other.mountPoint, vol.mountPoint) then
        return true
      end
    end
  end
  return false
end

local function addOrUpdateVolume(command, isUpdate)
  local raw = {
    id = isUpdate and command.id or nil,
    name = command.name,
    cipherDir = command.cipherDir,
    mountPoint = command.mountPoint,
    passfile = command.passfile,
    allowOther = command.allowOther == true,
    readOnly = command.readOnly == true,
    autoMount = command.autoMount,
  }
  if command.autoMount == nil and not isUpdate then
    raw.autoMount = trim(command.passfile or "") ~= ""
  end
  local vol = normalizeVolume(raw)
  if not vol then
    actionResult(command, false, noctalia.tr("panel.field.required"))
    return
  end

  if isUpdate then
    local existing = findVolume(command.id)
    if not existing then
      actionResult(command, false, noctalia.tr("result.not_found"))
      return
    end
    if conflictsWith(vol, existing.id) then
      actionResult(command, false, noctalia.tr("panel.field.duplicate"))
      return
    end
    existing.name = vol.name
    existing.cipherDir = vol.cipherDir
    existing.mountPoint = vol.mountPoint
    existing.passfile = vol.passfile
    existing.allowOther = vol.allowOther
    existing.readOnly = vol.readOnly
    existing.autoMount = vol.autoMount
  else
    if conflictsWith(vol, nil) then
      actionResult(command, false, noctalia.tr("panel.field.duplicate"))
      return
    end
    table.insert(volumes, vol)
  end

  local ok, err = saveVolumes()
  if not ok then
    actionResult(command, false, noctalia.tr("result.failed", { error = err or "save failed" }))
    return
  end
  actionResult(command, true, noctalia.tr("result.saved", { name = vol.name }))
  updateRevision("volumes-changed-" .. tostring(os.time()))
  publishSnapshot()
  refreshAll()
end

local function removeVolume(command)
  local id = trim(command.id)
  local index = nil
  local name = ""
  local passfile = ""
  for i, vol in ipairs(volumes) do
    if vol.id == id then
      index = i
      name = vol.name
      passfile = vol.passfile
      if vol.mounted then
        actionResult(command, false, noctalia.tr("result.failed", { error = "unmount before removing" }))
        return
      end
      break
    end
  end
  if not index then
    actionResult(command, false, noctalia.tr("result.not_found"))
    return
  end
  table.remove(volumes, index)

  -- remove managed passfile if it lives under our passfiles dir
  local managed = defaultPassfilePath(id)
  if managed and passfile ~= "" and pathEqual(passfile, managed) then
    noctalia.removeFile(expand(managed))
  end

  local ok, err = saveVolumes()
  if not ok then
    actionResult(command, false, noctalia.tr("result.failed", { error = err or "save failed" }))
    return
  end
  actionResult(command, true, noctalia.tr("result.removed", { name = name }))
  updateRevision("volumes-removed-" .. tostring(os.time()))
  publishSnapshot()
  refreshAll()
end

local function initVolume(command)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end

  local name = trim(command.name)
  local cipherDir = trim(command.cipherDir)
  local mountPoint = trim(command.mountPoint)
  local password = type(command.password) == "string" and command.password or ""
  local plaintextNames = command.plaintextNames == true
  local aesSiv = command.aesSiv == true
  local savePassfile = command.savePassfile == true
  local autoMount = command.autoMount == true
  local allowOther = command.allowOther == true
  local readOnly = command.readOnly == true

  if name == "" or cipherDir == "" or mountPoint == "" then
    actionResult(command, false, noctalia.tr("panel.field.required"))
    return
  end
  if password == "" then
    actionResult(command, false, noctalia.tr("panel.password_required"))
    return
  end

  local vol = normalizeVolume({
    name = name,
    cipherDir = cipherDir,
    mountPoint = mountPoint,
    passfile = "",
    allowOther = allowOther,
    readOnly = readOnly,
    autoMount = autoMount and savePassfile,
  })
  if not vol then
    actionResult(command, false, noctalia.tr("panel.field.required"))
    return
  end
  if conflictsWith(vol, nil) then
    actionResult(command, false, noctalia.tr("panel.field.duplicate"))
    return
  end

  local cipher = expand(vol.cipherDir)
  if noctalia.fileExists(cipher .. "/gocryptfs.conf") then
    actionResult(command, false, noctalia.tr("result.already_initialized", { path = cipher }))
    return
  end

  local okDir, dirErr = ensureDir(cipher)
  if not okDir then
    actionResult(command, false, noctalia.tr("result.failed", { error = "cipher dir: " .. tostring(dirErr) }))
    return
  end

  local dir = noctalia.pluginDataDir()
  if not dir then
    actionResult(command, false, noctalia.tr("result.failed", { error = "no plugin data dir" }))
    return
  end

  local tempPassfile = dir .. "/.init-pass-" .. vol.id .. "-" .. tostring(os.time())
  local written, werr = writeSecurePassfile(tempPassfile, password)
  if not written then
    actionResult(command, false, noctalia.tr("result.failed", { error = werr or "could not write passfile" }))
    return
  end

  local args = { "gocryptfs", "-init", "-q", "-passfile", tempPassfile }
  if plaintextNames then
    table.insert(args, "-plaintextnames")
  end
  if aesSiv then
    table.insert(args, "-aessiv")
  end
  table.insert(args, cipher)

  actionBusy = true
  publishSnapshot()

  local launched = noctalia.runAsync(shellCommand(args), function(result)
    removePassfile(tempPassfile)
    local ok = result ~= nil and result.exitCode == 0 and not result.timedOut
    if not ok then
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout))
      if err == "" then
        err = result and result.timedOut and "timed out" or "unknown error"
      end
      finishAction(command, false, noctalia.tr("result.failed", { error = err }))
      return
    end

    if savePassfile then
      local pf = defaultPassfilePath(vol.id)
      if pf then
        local okPf, pfErr = writeSecurePassfile(pf, password)
        if okPf then
          vol.passfile = pf
          vol.autoMount = autoMount
        else
          noctalia.log(`gocryptfs: could not save passfile: {pfErr}`)
        end
      end
    end

    table.insert(volumes, vol)
    local saved, saveErr = saveVolumes()
    if not saved then
      finishAction(command, false, noctalia.tr("result.failed", { error = saveErr or "save failed" }))
      return
    end

    finishAction(command, true, noctalia.tr("result.initialized", { name = vol.name }))
  end, 120000)

  if not launched then
    removePassfile(tempPassfile)
    actionBusy = false
    actionResult(command, false, noctalia.tr("result.failed", { error = "could not start gocryptfs -init" }))
    publishSnapshot()
  end
end

local function executeAction(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end

  if command.action == "refresh" then
    refreshAll()
    return
  end

  if command.action == "reload_config" then
    loadVolumes()
    autoMountScheduled = false
    autoMountQueue = {}
    refreshAll()
    return
  end

  if command.action == "add_volume" then
    addOrUpdateVolume(command, false)
    return
  end
  if command.action == "update_volume" then
    addOrUpdateVolume(command, true)
    return
  end
  if command.action == "remove_volume" then
    removeVolume(command)
    return
  end
  if command.action == "open" then
    openMount(command)
    return
  end
  if command.action == "init_volume" then
    initVolume(command)
    return
  end

  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end

  if command.action == "mount" then
    mountVolume(command)
  elseif command.action == "unmount" then
    unmountVolume(command)
  else
    actionResult(command, false, `Unknown action: {command.action}`)
  end
end

-- boot
loadVolumes()
noctalia.state.watch(COMMAND_KEY, executeAction)
noctalia.setUpdateInterval(refreshIntervalMs())
refreshAll()

function update()
  refreshAll()
end

function onConfigChanged()
  noctalia.setUpdateInterval(refreshIntervalMs())
  -- re-run auto-mount if user turned it on
  if autoMountEnabled() and autoMountScheduled then
    for _, vol in ipairs(volumes) do
      if vol.autoMount and trim(vol.passfile) ~= "" and not vol.mounted then
        local already = false
        for _, id in ipairs(autoMountQueue) do
          if id == vol.id then
            already = true
            break
          end
        end
        if not already then
          table.insert(autoMountQueue, vol.id)
        end
      end
    end
    kickAutoMount()
  end
  refreshAll()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refreshAll()
  elseif event == "reload" then
    loadVolumes()
    autoMountScheduled = false
    autoMountQueue = {}
    refreshAll()
  elseif event == "automount" then
    autoMountScheduled = false
    autoMountQueue = {}
    refreshAll()
  end
end
