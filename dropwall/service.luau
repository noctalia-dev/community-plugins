--!nonstrict
-- DropWall service: owns one long-lived helper supervisor stream and applies
-- dropped images as wallpapers.
--
-- The supervisor owns a GTK3 + gtk-layer-shell worker with one transparent
-- surface per monitor. Paths are percent-encoded on its stdout protocol, then
-- decoded here before going through noctalia.setWallpaper().

-- Same whitelist as the host wallpaper scanner (wallpaper.cpp).
local VALID_EXT = { jpg = true, jpeg = true, png = true, webp = true, bmp = true, gif = true }
local HELPER_ERROR_COOLDOWN = 300
local helperErrorNotified = false
local lastHelperErrorAt = 0
local busyLogged = false
local busyCount = 0
local copyInProgress = false
local pendingCopy = nil
local helperStreamStarted = false

local function cfg(key)
  return noctalia.getConfig(key)
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function now()
  return tonumber(noctalia.formatTime("%s")) or 0
end

local function reportHelperError(message)
  noctalia.log("dropwall helper: " .. message)
  local stamp = now()
  if not helperErrorNotified or (stamp > 0 and stamp - lastHelperErrorAt >= HELPER_ERROR_COOLDOWN) then
    helperErrorNotified = true
    lastHelperErrorAt = stamp
    noctalia.notifyError(noctalia.tr("notify.helper_error_title"), message)
  end
end

local function decodePath(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local decoded = noctalia.string.urlDecode(value)
  if type(decoded) ~= "string" or decoded == "" or decoded:find("%z") then
    return nil
  end
  return decoded
end

-- Resolve the connector of the monitor the image was dropped on by matching
-- the helper-reported logical geometry against the host's output list.
local function findConnector(x, y, w, h)
  local outputs = noctalia.outputs()
  local exact = nil
  local exactCount = 0
  for i = 1, #outputs do
    local o = outputs[i]
    if o.x == x and o.y == y and o.width == w and o.height == h then
      exact = o.name
      exactCount = exactCount + 1
    end
  end

  -- Mirrored outputs may share identical geometry. Refuse an ambiguous match
  -- instead of choosing one arbitrarily.
  if exactCount == 1 then
    return exact
  elseif exactCount > 1 then
    return nil
  end

  return nil
end

local function applyWallpaper(path, connector)
  if cfg("per_monitor") then
    if not connector then
      noctalia.notifyError(noctalia.tr("notify.output_error_title"), basename(path))
      return
    end
    noctalia.setWallpaper(connector, path)
  else
    -- The host applies its normal all-output wallpaper behavior.
    noctalia.setWallpaper(path)
  end
  if cfg("notify_on_set") then
    noctalia.notify(noctalia.tr("notify.set_title"), basename(path))
  end
end

local function applyOriginalAfterCopyError(path, connector, message)
  noctalia.log("dropwall copy: " .. message)
  noctalia.notifyError(noctalia.tr("notify.copy_dir_title"), noctalia.tr("notify.copy_failed"))
  applyWallpaper(path, connector)
end

local function copyAndApply(path, connector, leasePid)
  if copyInProgress then
    -- Bound copy concurrency to one process and retain only the latest queued
    -- drop. It will be copied as soon as the active one finishes.
    pendingCopy = { path = path, connector = connector, leasePid = leasePid }
    noctalia.log("dropwall copy: queued latest drop while a copy is active")
    return
  end

  -- This is theme-mode dependent, so resolve it for every drop rather than
  -- pinning the directory when the service starts.
  local wallpaperDir = noctalia.wallpaperDirectory()
  if type(wallpaperDir) ~= "string" or wallpaperDir == "" then
    noctalia.notifyError(noctalia.tr("notify.copy_dir_title"), noctalia.tr("notify.copy_dir_missing"))
    applyWallpaper(path, connector)
    return
  end

  local pluginDir = noctalia.pluginDir()
  if type(pluginDir) ~= "string" or pluginDir == "" then
    applyOriginalAfterCopyError(path, connector, "plugin directory is unavailable")
    return
  end
  local copier = pluginDir .. "/dropwall_copy.py"
  if not noctalia.fileExists(copier) then
    applyOriginalAfterCopyError(path, connector, "copy helper is missing")
    return
  end

  local cmd = "exec python3 -B " .. shellQuote(copier)
    .. " --lease-pid " .. shellQuote(leasePid)
    .. " " .. shellQuote(path) .. " " .. shellQuote(wallpaperDir)
  copyInProgress = true
  local accepted = noctalia.runAsync(cmd, function(result)
    copyInProgress = false
    if type(result) ~= "table" or result.exitCode ~= 0 or result.timedOut or result.stdoutTruncated then
      local detail = type(result) == "table" and noctalia.string.trim(result.stderr or "") or "no result"
      applyOriginalAfterCopyError(path, connector, detail ~= "" and detail or "copy process failed")
    else
      local output = noctalia.string.trim(result.stdout or "")
      local encoded = output:match("^COPIED\t([^\t\r\n]+)$")
      local copied = decodePath(encoded)
      local copiedInfo = copied and noctalia.fileInfo(copied) or nil
      if not copied or type(copiedInfo) ~= "table" or copiedInfo.isDir then
        applyOriginalAfterCopyError(path, connector, "copy helper returned an invalid destination")
      else
        applyWallpaper(copied, connector)
      end
    end

    local pending = pendingCopy
    pendingCopy = nil
    if pending then
      copyAndApply(pending.path, pending.connector, pending.leasePid)
    end
  end, 60000)

  if not accepted then
    copyInProgress = false
    applyOriginalAfterCopyError(path, connector, "Noctalia rejected the copy process")
  end
end

local function handleDrop(path, connector, leasePid)
  local ext = path:match("%.(%w+)$")
  if not ext or not VALID_EXT[ext:lower()] then
    noctalia.notifyError(noctalia.tr("notify.invalid_title"), basename(path))
    return
  end
  if not noctalia.fileExists(path) then
    noctalia.notifyError(noctalia.tr("notify.missing_title"), path)
    return
  end
  local info = noctalia.fileInfo(path)
  if type(info) ~= "table" or info.isDir then
    noctalia.notifyError(noctalia.tr("notify.missing_title"), path)
    return
  end

  if cfg("per_monitor") and not connector then
    noctalia.notifyError(noctalia.tr("notify.output_error_title"), basename(path))
    return
  end

  if cfg("copy_to_wallpaper_dir") then
    copyAndApply(path, connector, leasePid)
  else
    applyWallpaper(path, connector)
  end
end

local function onHelperLine(line)
  if line:sub(1, 5) == "DROP\t" then
    local x, y, w, h, pid, encoded = line:match("^DROP\t(-?%d+)\t(-?%d+)\t(%d+)\t(%d+)\t(%d+)\t([^\t]+)$")
    local path = decodePath(encoded)
    local leasePid = tonumber(pid)
    if path and leasePid and leasePid > 1 then
      handleDrop(path, findConnector(tonumber(x), tonumber(y), tonumber(w), tonumber(h)), leasePid)
    else
      noctalia.log("dropwall: malformed DROP line: " .. line)
    end
  elseif line:sub(1, 8) == "INVALID\t" then
    local path = decodePath(line:sub(9))
    noctalia.notifyError(noctalia.tr("notify.invalid_title"), path and basename(path) or "")
  elseif line:sub(1, 8) == "MISSING\t" then
    local path = decodePath(line:sub(9))
    noctalia.notifyError(noctalia.tr("notify.missing_title"), path or "")
  elseif line:sub(1, 4) == "ERR\t" then
    reportHelperError(line:sub(5))
  elseif line:sub(1, 5) == "BUSY\t" then
    busyCount = busyCount + 1
    if not busyLogged then
      noctalia.log("dropwall helper: " .. line:sub(6))
      busyLogged = true
    end
    if busyCount == 3 then
      reportHelperError(noctalia.tr("notify.helper_busy"))
    end
  elseif line:sub(1, 6) == "READY\t" then
    local count = tonumber(line:sub(7)) or 0
    if count > 0 then
      helperErrorNotified = false
      busyLogged = false
      busyCount = 0
    else
      reportHelperError(noctalia.tr("notify.no_outputs"))
    end
  elseif line:sub(1, 8) == "RESTART\t" then
    local exitCode = line:sub(9)
    if exitCode ~= "3" then
      noctalia.log("dropwall: helper exited (code " .. exitCode .. "); supervisor will restart it")
    end
  elseif line ~= "ALIVE" and line ~= "" then
    noctalia.log("dropwall helper output: " .. line)
  end
end

local function startHelper()
  if not noctalia.commandExists("python3") then
    reportHelperError(noctalia.tr("notify.python_missing"))
    return
  end

  local layer = tostring(cfg("layer") or "background")
  if layer ~= "background" and layer ~= "bottom" then
    layer = "background"
  end

  local pluginDir = noctalia.pluginDir()
  if type(pluginDir) ~= "string" or pluginDir == "" then
    reportHelperError(noctalia.tr("notify.plugin_dir_missing"))
    return
  end

  local script = pluginDir .. "/dropwall_supervisor.py"
  if not noctalia.fileExists(script) then
    reportHelperError(noctalia.tr("notify.helper_file_missing"))
    return
  end
  local cmd = "exec python3 -B " .. shellQuote(script) .. " --layer " .. shellQuote(layer)
  cmd = cmd .. " 2>&1"
  if noctalia.runStream(cmd, onHelperLine) then
    helperStreamStarted = true
  else
    reportHelperError(noctalia.tr("notify.helper_start_failed"))
  end
end

-- Boot.
startHelper()

-- If python3 was missing or the initial stream launch was rejected, retry
-- without ever opening more than the one long-lived supervisor stream.
function update()
  noctalia.setUpdateInterval(60000)
  if not helperStreamStarted then
    startHelper()
  end
end
