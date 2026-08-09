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

-- Reject path traversal after expand. Volume paths are user-chosen (often absolute);
-- symlinks are followed by design. Empty paths, NUL, and ".." segments are refused.
local function isSafeFsPath(path)
  path = expand(path)
  if path == "" then
    return false, "empty path"
  end
  if path:find("\0", 1, true) then
    return false, "invalid path"
  end
  -- Reject .. as a path segment (//foo/../bar, /tmp/../etc, relative ../x, etc.)
  for seg in (path:gsub("\\", "/") .. "/"):gmatch("([^/]*)/") do
    if seg == ".." then
      return false, "path must not contain .."
    end
  end
  return true, path
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
  local useKeyring = raw.useKeyring == true or raw.use_keyring == true
  local autoMount = raw.autoMount
  if autoMount == nil then
    autoMount = raw.auto_mount
  end
  if autoMount == nil then
    -- default: auto-mount when keyring or passfile is configured
    autoMount = useKeyring or passfile ~= ""
  else
    autoMount = autoMount == true
  end
  return {
    id = trim(raw.id) ~= "" and trim(raw.id) or newVolumeId(),
    name = name,
    cipherDir = cipherDir,
    mountPoint = mountPoint,
    passfile = passfile,
    useKeyring = useKeyring,
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
      useKeyring = vol.useKeyring == true,
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
          if vol.autoMount and not vol.mounted
            and (vol.useKeyring == true or trim(vol.passfile) ~= "")
          then
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
  local okPath, resolved = isSafeFsPath(path)
  if not okPath then
    return false, resolved or "unsafe path"
  end
  path = resolved
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
  local okPath, resolved = isSafeFsPath(path)
  if not okPath then
    return false, resolved or "unsafe path"
  end
  path = resolved
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

-- Short-lived password material on tmpfs when possible (never long-term secret storage).
local function tempPassPath(suffix)
  local base = "/dev/shm"
  if not noctalia.fileExists(base) then
    base = noctalia.pluginDataDir() or "/tmp"
  end
  return base .. "/noctalia-gocryptfs-" .. tostring(suffix)
end

local function writeSecurePassfile(path, password)
  local written, werr = noctalia.writeFile(path, password .. "\n")
  if not written then
    return false, werr or "write failed"
  end
  noctalia.runAsync(shellCommand({ "chmod", "600", path }))
  return true
end

-- Kernel user-keyring description (session cache; payload does not survive reboot).
local function keyringDesc(volumeId)
  return "noctalia-gocryptfs:" .. tostring(volumeId or "")
end

-- Freedesktop Secret Service attributes (GNOME Keyring / KeePassXC / etc.).
local SECRET_SERVICE = "noctalia-gocryptfs"

local function keyctlAvailable()
  return noctalia.commandExists("keyctl")
end

local function secretToolAvailable()
  return noctalia.commandExists("secret-tool")
end

-- Store password in @u keyring (replaces any prior key with same description).
-- Password is written only to a tmpfs temp file, then loaded via keyctl padd stdin.
local function storeSessionKeyring(volumeId, password, callback)
  if type(callback) ~= "function" then
    callback = function() end
  end
  if not keyctlAvailable() then
    callback(false, "keyctl not found")
    return
  end
  local desc = keyringDesc(volumeId)
  if desc == "noctalia-gocryptfs:" or password == nil or password == "" then
    callback(false, "invalid keyring store")
    return
  end
  local tmp = tempPassPath("kr-" .. tostring(volumeId) .. "-" .. tostring(os.time()))
  local written, werr = noctalia.writeFile(tmp, password)
  if not written then
    callback(false, werr or "temp write failed")
    return
  end
  noctalia.runAsync(shellCommand({ "chmod", "600", tmp }), function()
    local cmd = "OLD=$(keyctl search @u user "
      .. shellQuote(desc)
      .. " 2>/dev/null); "
      .. "[ -n \"$OLD\" ] && keyctl unlink \"$OLD\" @u 2>/dev/null; "
      .. "keyctl padd user "
      .. shellQuote(desc)
      .. " @u < "
      .. shellQuote(tmp)
      .. "; EC=$?; rm -f "
      .. shellQuote(tmp)
      .. "; exit $EC"
    noctalia.runAsync(cmd, function(result)
      removePassfile(tmp)
      local ok = result ~= nil and result.exitCode == 0 and not result.timedOut
      if ok then
        callback(true, nil)
      else
        local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or "keyctl padd failed")
        callback(false, err)
      end
    end, 10000)
  end)
end

-- Persist password via libsecret (secret-tool → desktop keyring). Survives reboot
-- once the login keyring is unlocked.
local function storePersistentPassword(volumeId, password, callback)
  if type(callback) ~= "function" then
    callback = function() end
  end
  if not secretToolAvailable() then
    callback(false, "secret-tool not found")
    return
  end
  local vid = tostring(volumeId or "")
  if vid == "" or password == nil or password == "" then
    callback(false, "invalid persistent store")
    return
  end
  local tmp = tempPassPath("sec-" .. vid .. "-" .. tostring(os.time()))
  local written, werr = noctalia.writeFile(tmp, password)
  if not written then
    callback(false, werr or "temp write failed")
    return
  end
  local label = "noctalia-gocryptfs:" .. vid
  noctalia.runAsync(shellCommand({ "chmod", "600", tmp }), function()
    -- Clear any previous entry first so store does not leave duplicates.
    local cmd = "secret-tool clear service "
      .. shellQuote(SECRET_SERVICE)
      .. " volume-id "
      .. shellQuote(vid)
      .. " 2>/dev/null; "
      .. "secret-tool store --label="
      .. shellQuote(label)
      .. " service "
      .. shellQuote(SECRET_SERVICE)
      .. " volume-id "
      .. shellQuote(vid)
      .. " < "
      .. shellQuote(tmp)
      .. "; EC=$?; rm -f "
      .. shellQuote(tmp)
      .. "; exit $EC"
    noctalia.runAsync(cmd, function(result)
      removePassfile(tmp)
      local ok = result ~= nil and result.exitCode == 0 and not result.timedOut
      if ok then
        callback(true, nil)
      else
        local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or "secret-tool store failed")
        callback(false, err)
      end
    end, 30000)
  end)
end

-- Store in session keyctl and, when available, desktop Secret Service.
-- Succeeds if at least one backend works (prefer both).
local function storeKeyringPassword(volumeId, password, callback)
  if type(callback) ~= "function" then
    callback = function() end
  end
  local desc = keyringDesc(volumeId)
  if desc == "noctalia-gocryptfs:" or password == nil or password == "" then
    callback(false, "invalid keyring store")
    return
  end
  if not keyctlAvailable() and not secretToolAvailable() then
    callback(false, "neither keyctl nor secret-tool found")
    return
  end

  local sessionDone = false
  local persistDone = false
  local sessionOk, sessionErr = false, nil
  local persistOk, persistErr = false, nil

  local function maybeFinish()
    if not sessionDone or not persistDone then
      return
    end
    if sessionOk or persistOk then
      if not persistOk and secretToolAvailable() and persistErr then
        noctalia.log(`gocryptfs: secret-tool store failed (session key still set): {persistErr}`)
      end
      if not sessionOk and keyctlAvailable() and sessionErr then
        noctalia.log(`gocryptfs: keyctl store failed (persistent secret still set): {sessionErr}`)
      end
      callback(true, nil)
    else
      callback(false, sessionErr or persistErr or "keyring store failed")
    end
  end

  if keyctlAvailable() then
    storeSessionKeyring(volumeId, password, function(ok, err)
      sessionOk = ok
      sessionErr = err
      sessionDone = true
      maybeFinish()
    end)
  else
    sessionDone = true
    maybeFinish()
  end

  if secretToolAvailable() then
    storePersistentPassword(volumeId, password, function(ok, err)
      persistOk = ok
      persistErr = err
      persistDone = true
      maybeFinish()
    end)
  else
    persistDone = true
    maybeFinish()
  end
end

local function unlinkSessionKeyring(volumeId, callback)
  if type(callback) ~= "function" then
    callback = function() end
  end
  if not keyctlAvailable() then
    callback(true)
    return
  end
  local desc = keyringDesc(volumeId)
  local cmd = "OLD=$(keyctl search @u user "
    .. shellQuote(desc)
    .. " 2>/dev/null); "
    .. "[ -n \"$OLD\" ] && keyctl unlink \"$OLD\" @u 2>/dev/null; exit 0"
  noctalia.runAsync(cmd, function()
    callback(true)
  end, 5000)
end

local function clearPersistentPassword(volumeId, callback)
  if type(callback) ~= "function" then
    callback = function() end
  end
  if not secretToolAvailable() then
    callback(true)
    return
  end
  local vid = tostring(volumeId or "")
  if vid == "" then
    callback(true)
    return
  end
  local cmd = "secret-tool clear service "
    .. shellQuote(SECRET_SERVICE)
    .. " volume-id "
    .. shellQuote(vid)
    .. " 2>/dev/null; exit 0"
  noctalia.runAsync(cmd, function()
    callback(true)
  end, 15000)
end

-- Clear session key + desktop keyring entry.
local function unlinkKeyringPassword(volumeId, callback)
  if type(callback) ~= "function" then
    callback = function() end
  end
  local left = 2
  local function done()
    left -= 1
    if left <= 0 then
      callback(true)
    end
  end
  unlinkSessionKeyring(volumeId, done)
  clearPersistentPassword(volumeId, done)
end

-- Shell prelude: ensure session key exists, hydrating from secret-tool when needed.
-- Sets shell var K to key id, or exits 2 if no password material is available.
local function ensureSessionKeyShell(volumeId)
  local desc = keyringDesc(volumeId)
  local vid = tostring(volumeId or "")
  return "K=$(keyctl search @u user "
    .. shellQuote(desc)
    .. " 2>/dev/null) || true; "
    .. "if [ -z \"$K\" ] && command -v secret-tool >/dev/null 2>&1 && command -v keyctl >/dev/null 2>&1; then "
    .. "secret-tool lookup service "
    .. shellQuote(SECRET_SERVICE)
    .. " volume-id "
    .. shellQuote(vid)
    .. " 2>/dev/null | keyctl padd user "
    .. shellQuote(desc)
    .. " @u >/dev/null 2>&1 || true; "
    .. "K=$(keyctl search @u user "
    .. shellQuote(desc)
    .. " 2>/dev/null) || true; "
    .. "fi; "
    .. "if [ -z \"$K\" ]; then exit 2; fi; "
end

-- Legacy managed plaintext path (no longer created; still cleaned on remove).
local function defaultPassfilePath(volumeId)
  local dir = passfilesDir()
  if not dir then
    return nil
  end
  return dir .. "/" .. volumeId .. ".pass"
end

local function canAutoMount(vol)
  if not vol or vol.mounted then
    return false
  end
  if not vol.autoMount then
    return false
  end
  return vol.useKeyring == true or trim(vol.passfile) ~= ""
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

  local okCipher, cipherOrErr = isSafeFsPath(vol.cipherDir)
  if not okCipher then
    local msg = noctalia.tr("result.failed", { error = cipherOrErr or "unsafe cipher path" })
    actionResult(command, false, msg)
    notifyErr(msg)
    kickAutoMount()
    return
  end
  local cipher = cipherOrErr
  local okMountPath, mountOrErr = isSafeFsPath(vol.mountPoint)
  if not okMountPath then
    local msg = noctalia.tr("result.failed", { error = mountOrErr or "unsafe mount path" })
    actionResult(command, false, msg)
    notifyErr(msg)
    kickAutoMount()
    return
  end
  local mount = mountOrErr

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
  local useKeyring = vol.useKeyring == true
  local storeKeyring = command.storeKeyring == true or useKeyring
  local mountCmd = nil -- full shell when using keyring (search + extpass)

  if password ~= "" then
    -- One-shot: password via tmpfs temp passfile (deleted after mount).
    tempPassfile = tempPassPath("pass-" .. vol.id .. "-" .. tostring(os.time()))
    local written, werr = writeSecurePassfile(tempPassfile, password)
    if not written then
      actionResult(command, false, noctalia.tr("result.failed", { error = werr or "could not write passfile" }))
      kickAutoMount()
      return
    end
    table.insert(args, "-passfile")
    table.insert(args, tempPassfile)
  elseif useKeyring then
    if not keyctlAvailable() and not secretToolAvailable() then
      local msg = noctalia.tr("result.failed", {
        error = "neither keyctl nor secret-tool found (install keyutils and/or libsecret)",
      })
      actionResult(command, false, msg)
      if command.silent ~= true then
        notifyErr(msg)
      end
      kickAutoMount()
      return
    end
    -- Prefer session keyctl (hydrated from secret-tool after reboot); else secret-tool -extpass.
    local gocryptParts = {}
    for _, a in ipairs(args) do
      table.insert(gocryptParts, shellQuote(a))
    end
    local cipherQ = shellQuote(cipher)
    local mountQ = shellQuote(mount)
    local vid = tostring(vol.id)
    if keyctlAvailable() then
      table.insert(gocryptParts, shellQuote("-extpass"))
      table.insert(gocryptParts, shellQuote("keyctl"))
      table.insert(gocryptParts, shellQuote("-extpass"))
      table.insert(gocryptParts, shellQuote("pipe"))
      table.insert(gocryptParts, shellQuote("-extpass"))
      table.insert(gocryptParts, "\"$K\"")
      table.insert(gocryptParts, cipherQ)
      table.insert(gocryptParts, mountQ)
      local keyctlMount = table.concat(gocryptParts, " ")
      if secretToolAvailable() then
        -- Fallback: secret-tool -extpass when session hydrate cannot produce K
        local secretParts = {}
        for _, a in ipairs(args) do
          table.insert(secretParts, shellQuote(a))
        end
        table.insert(secretParts, shellQuote("-extpass"))
        table.insert(secretParts, shellQuote("secret-tool"))
        table.insert(secretParts, shellQuote("-extpass"))
        table.insert(secretParts, shellQuote("lookup"))
        table.insert(secretParts, shellQuote("-extpass"))
        table.insert(secretParts, shellQuote("service"))
        table.insert(secretParts, shellQuote("-extpass"))
        table.insert(secretParts, shellQuote(SECRET_SERVICE))
        table.insert(secretParts, shellQuote("-extpass"))
        table.insert(secretParts, shellQuote("volume-id"))
        table.insert(secretParts, shellQuote("-extpass"))
        table.insert(secretParts, shellQuote(vid))
        table.insert(secretParts, cipherQ)
        table.insert(secretParts, mountQ)
        -- ensureSessionKeyShell exits 2 when no material; override to allow secret-tool path
        mountCmd = "K=$(keyctl search @u user "
          .. shellQuote(keyringDesc(vid))
          .. " 2>/dev/null) || true; "
          .. "if [ -z \"$K\" ] && command -v secret-tool >/dev/null 2>&1; then "
          .. "secret-tool lookup service "
          .. shellQuote(SECRET_SERVICE)
          .. " volume-id "
          .. shellQuote(vid)
          .. " 2>/dev/null | keyctl padd user "
          .. shellQuote(keyringDesc(vid))
          .. " @u >/dev/null 2>&1 || true; "
          .. "K=$(keyctl search @u user "
          .. shellQuote(keyringDesc(vid))
          .. " 2>/dev/null) || true; "
          .. "fi; "
          .. "if [ -n \"$K\" ]; then "
          .. keyctlMount
          .. "; else "
          .. table.concat(secretParts, " ")
          .. "; fi"
      else
        mountCmd = ensureSessionKeyShell(vid) .. keyctlMount
      end
    else
      -- No keyctl: mount directly via secret-tool
      table.insert(gocryptParts, shellQuote("-extpass"))
      table.insert(gocryptParts, shellQuote("secret-tool"))
      table.insert(gocryptParts, shellQuote("-extpass"))
      table.insert(gocryptParts, shellQuote("lookup"))
      table.insert(gocryptParts, shellQuote("-extpass"))
      table.insert(gocryptParts, shellQuote("service"))
      table.insert(gocryptParts, shellQuote("-extpass"))
      table.insert(gocryptParts, shellQuote(SECRET_SERVICE))
      table.insert(gocryptParts, shellQuote("-extpass"))
      table.insert(gocryptParts, shellQuote("volume-id"))
      table.insert(gocryptParts, shellQuote("-extpass"))
      table.insert(gocryptParts, shellQuote(vid))
      table.insert(gocryptParts, cipherQ)
      table.insert(gocryptParts, mountQ)
      mountCmd = table.concat(gocryptParts, " ")
    end
  elseif passfile ~= "" then
    -- Optional legacy/custom plaintext passfile path (user-managed).
    local okPf, pfOrErr = isSafeFsPath(passfile)
    if not okPf then
      local msg = noctalia.tr("result.failed", { error = pfOrErr or "unsafe passfile path" })
      actionResult(command, false, msg)
      notifyErr(msg)
      kickAutoMount()
      return
    end
    local pf = pfOrErr
    if not noctalia.fileExists(pf) then
      local msg = noctalia.tr("result.failed", { error = "passfile not found: " .. pf })
      actionResult(command, false, msg)
      notifyErr(msg)
      kickAutoMount()
      return
    end
    table.insert(args, "-passfile")
    table.insert(args, pf)
  else
    actionResult(command, false, noctalia.tr("panel.password_required"))
    kickAutoMount()
    return
  end

  if mountCmd == nil then
    table.insert(args, cipher)
    table.insert(args, mount)
    mountCmd = shellCommand(args)
  end

  actionBusy = true
  publishSnapshot()

  local launched = noctalia.runAsync(mountCmd, function(result)
    removePassfile(tempPassfile)
    local ok = result ~= nil and result.exitCode == 0 and not result.timedOut
    local message
    if ok then
      vol.mounted = true
      message = noctalia.tr("result.mounted", { name = vol.name })
      -- After a typed-password mount, keep password in keyring for this login session.
      if password ~= "" and storeKeyring then
        storeKeyringPassword(vol.id, password, function(krOk, krErr)
          if krOk then
            vol.useKeyring = true
            saveVolumes()
            publishSnapshot()
          else
            noctalia.log(`gocryptfs: keyring store failed: {krErr}`)
          end
        end)
      end
    else
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout))
      if err == "" then
        if result and result.exitCode == 2 and useKeyring and password == "" then
          err = "keyring password missing (Remember once, or unlock desktop keyring)"
        else
          err = result and result.timedOut and "timed out" or "unknown error"
        end
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
  if not canAutoMount(vol) then
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

  local okMountPath, mountOrErr = isSafeFsPath(vol.mountPoint)
  if not okMountPath then
    actionResult(command, false, noctalia.tr("result.failed", { error = mountOrErr or "unsafe mount path" }))
    return
  end
  local mount = mountOrErr
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
  local okPath, pathOrErr = isSafeFsPath(vol.mountPoint)
  if not okPath then
    actionResult(command, false, noctalia.tr("result.failed", { error = pathOrErr or "unsafe mount path" }))
    return
  end
  local path = pathOrErr
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
    useKeyring = command.useKeyring == true,
    allowOther = command.allowOther == true,
    readOnly = command.readOnly == true,
    autoMount = command.autoMount,
  }
  if command.autoMount == nil and not isUpdate then
    raw.autoMount = command.useKeyring == true or trim(command.passfile or "") ~= ""
  end
  local vol = normalizeVolume(raw)
  if not vol then
    actionResult(command, false, noctalia.tr("panel.field.required"))
    return
  end

  local okCipher, cipherOrErr = isSafeFsPath(vol.cipherDir)
  if not okCipher then
    actionResult(command, false, noctalia.tr("result.failed", { error = cipherOrErr or "unsafe cipher path" }))
    return
  end
  vol.cipherDir = cipherOrErr
  local okMountPath, mountOrErr = isSafeFsPath(vol.mountPoint)
  if not okMountPath then
    actionResult(command, false, noctalia.tr("result.failed", { error = mountOrErr or "unsafe mount path" }))
    return
  end
  vol.mountPoint = mountOrErr
  if trim(vol.passfile) ~= "" then
    local okPf, pfOrErr = isSafeFsPath(vol.passfile)
    if not okPf then
      actionResult(command, false, noctalia.tr("result.failed", { error = pfOrErr or "unsafe passfile path" }))
      return
    end
    vol.passfile = pfOrErr
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
    existing.useKeyring = vol.useKeyring
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
  local useKeyring = false
  for i, vol in ipairs(volumes) do
    if vol.id == id then
      index = i
      name = vol.name
      passfile = vol.passfile
      useKeyring = vol.useKeyring == true
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

  -- remove managed passfile if it lives under our passfiles dir (legacy)
  local managed = defaultPassfilePath(id)
  if managed and passfile ~= "" and pathEqual(passfile, managed) then
    noctalia.removeFile(expand(managed))
  end
  if useKeyring then
    unlinkKeyringPassword(id, function() end)
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
  -- "savePassfile" UI flag now means store in kernel keyring (no plaintext at rest).
  local saveKeyring = command.savePassfile == true or command.saveKeyring == true
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
  if saveKeyring and not keyctlAvailable() and not secretToolAvailable() then
    actionResult(command, false, noctalia.tr("result.failed", {
      error = "neither keyctl nor secret-tool found (install keyutils and/or libsecret)",
    }))
    return
  end

  local vol = normalizeVolume({
    name = name,
    cipherDir = cipherDir,
    mountPoint = mountPoint,
    passfile = "",
    useKeyring = saveKeyring,
    allowOther = allowOther,
    readOnly = readOnly,
    autoMount = autoMount and saveKeyring,
  })
  if not vol then
    actionResult(command, false, noctalia.tr("panel.field.required"))
    return
  end
  if conflictsWith(vol, nil) then
    actionResult(command, false, noctalia.tr("panel.field.duplicate"))
    return
  end

  local okCipher, cipherOrErr = isSafeFsPath(vol.cipherDir)
  if not okCipher then
    actionResult(command, false, noctalia.tr("result.failed", { error = cipherOrErr or "unsafe cipher path" }))
    return
  end
  local cipher = cipherOrErr
  local okMountPath, mountOrErr = isSafeFsPath(vol.mountPoint)
  if not okMountPath then
    actionResult(command, false, noctalia.tr("result.failed", { error = mountOrErr or "unsafe mount path" }))
    return
  end

  if noctalia.fileExists(cipher .. "/gocryptfs.conf") then
    actionResult(command, false, noctalia.tr("result.already_initialized", { path = cipher }))
    return
  end

  local okDir, dirErr = ensureDir(cipher)
  if not okDir then
    actionResult(command, false, noctalia.tr("result.failed", { error = "cipher dir: " .. tostring(dirErr) }))
    return
  end

  local tempPassfile = tempPassPath("init-" .. vol.id .. "-" .. tostring(os.time()))
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

    local function finishInit()
      table.insert(volumes, vol)
      local saved, saveErr = saveVolumes()
      if not saved then
        finishAction(command, false, noctalia.tr("result.failed", { error = saveErr or "save failed" }))
        return
      end
      finishAction(command, true, noctalia.tr("result.initialized", { name = vol.name }))
    end

    if saveKeyring then
      storeKeyringPassword(vol.id, password, function(krOk, krErr)
        if krOk then
          vol.useKeyring = true
          vol.autoMount = autoMount
        else
          noctalia.log(`gocryptfs: keyring store failed: {krErr}`)
          vol.useKeyring = false
          vol.autoMount = false
        end
        finishInit()
      end)
    else
      finishInit()
    end
  end, 120000)

  if not launched then
    removePassfile(tempPassfile)
    actionBusy = false
    actionResult(command, false, noctalia.tr("result.failed", { error = "could not start gocryptfs -init" }))
    publishSnapshot()
  end
end

-- Store password in kernel keyring for an existing volume (no mount required).
local function storeKeyringAction(command)
  local vol = findVolume(command.id)
  if not vol then
    actionResult(command, false, noctalia.tr("result.not_found"))
    return
  end
  local password = type(command.password) == "string" and command.password or ""
  if password == "" then
    actionResult(command, false, noctalia.tr("panel.password_required"))
    return
  end
  if not keyctlAvailable() and not secretToolAvailable() then
    actionResult(command, false, noctalia.tr("result.failed", {
      error = "neither keyctl nor secret-tool found (install keyutils and/or libsecret)",
    }))
    return
  end

  actionBusy = true
  publishSnapshot()

  storeKeyringPassword(vol.id, password, function(ok, err)
    actionBusy = false
    if not ok then
      local msg = noctalia.tr("result.failed", { error = err or "keyring store failed" })
      actionResult(command, false, msg)
      notifyErr(msg)
      publishSnapshot()
      return
    end
    vol.useKeyring = true
    if command.enableAutoMount == true then
      vol.autoMount = true
    end
    local saved, saveErr = saveVolumes()
    if not saved then
      local msg = noctalia.tr("result.failed", { error = saveErr or "save failed" })
      actionResult(command, false, msg)
      notifyErr(msg)
      publishSnapshot()
      return
    end
    local msg = noctalia.tr("result.keyring_saved", { name = vol.name })
    actionResult(command, true, msg)
    notifyOk(msg)
    publishSnapshot()
    refreshAll()
  end)
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
  if command.action == "store_keyring" then
    storeKeyringAction(command)
    return
  end

  if command.action == "forget_keyring" then
    local vol = findVolume(command.id)
    if not vol then
      actionResult(command, false, noctalia.tr("result.not_found"))
      return
    end
    actionBusy = true
    publishSnapshot()
    unlinkKeyringPassword(vol.id, function()
      vol.useKeyring = false
      -- Do not force autoMount off if user still has a passfile path
      if trim(vol.passfile) == "" then
        vol.autoMount = false
      end
      local saved, saveErr = saveVolumes()
      actionBusy = false
      if not saved then
        local msg = noctalia.tr("result.failed", { error = saveErr or "save failed" })
        actionResult(command, false, msg)
        notifyErr(msg)
        publishSnapshot()
        return
      end
      local msg = noctalia.tr("result.keyring_forgotten", { name = vol.name })
      actionResult(command, true, msg)
      notifyOk(msg)
      publishSnapshot()
      refreshAll()
    end)
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
      if canAutoMount(vol) then
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
