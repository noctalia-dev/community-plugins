--!nonstrict
-- Finds Flatpak apps that are running but have no window in niri, and stops them.
--
-- Windows come from `niri msg -j event-stream` and are kept in memory, so
-- opening or closing a window updates the list right away. Running Flatpak
-- instances are read from $XDG_RUNTIME_DIR/.flatpak on every update tick,
-- which needs no extra process. If the event stream is unavailable, the
-- service falls back to polling `niri msg -j windows`.
--
-- Published state:
--   "bg_apps"     list of { id, name, icon }, sorted by name
--   "bg_error"    true when the last scan failed (the list is then the last good one)
--   "bg_stopping" map of app id -> true while a stop is in progress
-- Read state:
--   "refresh"        any change asks for a new scan
--   "stop_requests"  list of { id, seq }; every seq above the last handled one is stopped

local APP_ID_PATTERN = "^[%w_%-]+%.[%w_%-%.]+$"
local ICON_SIZE = 32
-- An app needs this long to open its first window before it counts as background
local STARTUP_GRACE_MS = 5000
-- Printed after the event stream ends, since runStream has no exit callback
local STREAM_END = "__flatpak_bg_stream_end__"
local STREAM_RESTART_SECONDS = 3

local function isAppId(s)
  return type(s) == "string" and s:match(APP_ID_PATTERN) ~= nil
end

local function firstEnv(...)
  for _, name in ipairs({ ... }) do
    local value = noctalia.getenv(name)
    if value and value ~= "" then return value end
  end
  return ""
end

local function decodeJson(text)
  local ok, value = pcall(noctalia.json.decode, text or "")
  if ok then return value end
  return nil
end

---------------------------------------------------------------------------
-- Desktop file metadata
---------------------------------------------------------------------------

-- Filled by loadInstallations() before the first scan
local desktopDirs = {}

local function userInstallation()
  local dataHome = firstEnv("XDG_DATA_HOME")
  if dataHome == "" then dataHome = "~/.local/share" end
  return noctalia.expandPath(dataHome) .. "/flatpak"
end

local function setInstallations(paths)
  desktopDirs = {}
  local seen = {}
  for _, base in ipairs(paths) do
    base = base:gsub("/+$", "")
    if base ~= "" and not seen[base] then
      seen[base] = true
      table.insert(desktopDirs, base .. "/exports/share/applications/")
    end
  end
end

-- User installation first, then every system installation flatpak knows about
-- (including custom ones from /etc/flatpak/installations.d)
local function loadInstallations(done)
  local paths = { userInstallation() }
  local started = noctalia.runAsync({ "flatpak", "--installations" }, function(res)
    local any = false
    if res.exitCode == 0 then
      for line in (res.stdout or ""):gmatch("[^\n]+") do
        local path = noctalia.string.trim(line)
        if path ~= "" then
          table.insert(paths, path)
          any = true
        end
      end
    end
    if not any then table.insert(paths, "/var/lib/flatpak") end
    setInstallations(paths)
    done()
  end)
  if not started then
    table.insert(paths, "/var/lib/flatpak")
    setInstallations(paths)
    done()
  end
end

-- Desktop file keys to try for the app name, most specific first
local function buildNameKeys()
  local keys = {}
  local locale = firstEnv("LC_ALL", "LC_MESSAGES", "LANG"):match("^[^.@]+") or ""
  if locale ~= "" and locale ~= "C" and locale ~= "POSIX" then
    table.insert(keys, "Name[" .. locale .. "]")
    local lang = locale:match("^(%a+)_")
    if lang then table.insert(keys, "Name[" .. lang .. "]") end
  end
  table.insert(keys, "Name")
  return keys
end

local NAME_KEYS = buildNameKeys()

-- Returns the [Desktop Entry] fields of the app's desktop file, or nil
local function readDesktopEntry(id)
  for _, dir in ipairs(desktopDirs) do
    local text = noctalia.readFile(dir .. id .. ".desktop")
    if text then
      local section = text:match("%[Desktop Entry%][^\n]*\n(.-)\n%[")
        or text:match("%[Desktop Entry%][^\n]*\n(.*)")
        or ""
      local fields = {}
      for line in section:gmatch("[^\n]+") do
        local key, value = line:match("^%s*([^=#]-)%s*=%s*(.-)%s*$")
        if key and fields[key] == nil then fields[key] = value end
      end
      return fields
    end
  end
  return nil
end

-- Found entries are cached for good. Misses are retried after a while,
-- since a desktop file or icon may not be readable yet right after install.
local MISS_RETRY_MS = 30000
local entryCache, entryMiss = {}, {}
local iconCache, iconMiss = {}, {}

local function retryDue(misses, id, now)
  local last = misses[id]
  return last == nil or now - last >= MISS_RETRY_MS
end

local function appMeta(id)
  local now = noctalia.nowMs()
  local entry = entryCache[id]
  if not entry and retryDue(entryMiss, id, now) then
    local fields = readDesktopEntry(id)
    if not fields then entryMiss[id] = now end
    if fields then
      local name
      for _, key in ipairs(NAME_KEYS) do
        if fields[key] and fields[key] ~= "" then
          name = fields[key]
          break
        end
      end
      entry = { name = name or id, wmClass = fields["StartupWMClass"] or "" }
      entryCache[id] = entry
    end
  end

  local icon = iconCache[id]
  if not icon then
    icon = ""
    if retryDue(iconMiss, id, now) then
      icon = noctalia.appIconPath(id, ICON_SIZE) or ""
      if icon ~= "" then iconCache[id] = icon else iconMiss[id] = now end
    end
  end

  return {
    name = entry and entry.name or id,
    wmClass = entry and entry.wmClass or "",
    icon = icon,
  }
end

---------------------------------------------------------------------------
-- Flatpak instances, read from $XDG_RUNTIME_DIR/.flatpak/<instance-id>/
---------------------------------------------------------------------------

local INSTANCE_DIR = (function()
  local runtimeDir = firstEnv("XDG_RUNTIME_DIR")
  if runtimeDir == "" then return nil end
  return runtimeDir .. "/.flatpak/"
end)()

-- instance-id -> { id = app id, pid = child pid }. The info and bwrapinfo
-- files never change for an instance, so they are read only once.
local instanceCache = {}

local function readInstance(instance)
  local cached = instanceCache[instance]
  if cached then return cached end

  local base = INSTANCE_DIR .. instance .. "/"
  local info = noctalia.readFile(base .. "info")
  local bwrap = noctalia.readFile(base .. "bwrapinfo.json")
  if not info or not bwrap then return nil end  -- still starting up

  local id = info:match("%[Application%][^%[]-\nname=([^\n]+)")
  local data = decodeJson(bwrap)
  local pid = type(data) == "table" and tonumber(data["child-pid"]) or nil
  if not isAppId(id) or not pid then return nil end

  cached = { id = id, pid = tostring(math.floor(pid)) }
  instanceCache[instance] = cached
  return cached
end

-- Instance dirs are only removed the next time flatpak cleans up, so check
-- that the sandboxed process still exists and still belongs to this instance
local function instanceAlive(instance, pid)
  local info = noctalia.readFile("/proc/" .. pid .. "/root/.flatpak-info")
  return info ~= nil and info:find("\ninstance-id=" .. instance .. "\n", 1, true) ~= nil
end

-- Returns running (app id -> true) and pids (app id -> { pid, ... }),
-- or nil and an error message
local function readInstances()
  if not INSTANCE_DIR then return nil, nil, "XDG_RUNTIME_DIR is not set" end

  local running, pids = {}, {}
  local names, err = noctalia.listDir(INSTANCE_DIR)
  if not names then
    -- No Flatpak app has run in this session yet
    if not noctalia.fileExists(INSTANCE_DIR) then return running, pids end
    return nil, nil, "could not list " .. INSTANCE_DIR .. ": " .. tostring(err)
  end

  local present = {}
  for _, name in ipairs(names) do
    if name:match("^%d+$") then
      present[name] = true
      local inst = readInstance(name)
      if inst and instanceAlive(name, inst.pid) then
        running[inst.id] = true
        pids[inst.id] = pids[inst.id] or {}
        table.insert(pids[inst.id], inst.pid)
      end
    end
  end
  for name in pairs(instanceCache) do
    if not present[name] then instanceCache[name] = nil end
  end
  return running, pids
end

---------------------------------------------------------------------------
-- Windows
---------------------------------------------------------------------------

-- niri window id -> { appId = lowercased app_id or "", flatpakId = id or nil }
local windows = {}
local windowsKnown = false

local function flatpakIdOfPid(pid)
  local info = noctalia.readFile("/proc/" .. pid .. "/root/.flatpak-info")
  local id = info and info:match("%[Application%][^%[]-\nname=([^\n]+)") or nil
  if isAppId(id) then return id end
  return nil
end

-- The sandbox lookup is done once per window, when niri reports it
local function windowRecord(w, previous)
  local appId = type(w.app_id) == "string" and w.app_id:lower() or ""
  local pid = type(w.pid) == "number" and math.floor(w.pid) or nil
  if previous and previous.pid == pid then
    previous.appId = appId
    return previous
  end
  return { appId = appId, pid = pid, flatpakId = pid and flatpakIdOfPid(pid) or nil }
end

local function setWindows(list)
  local old = windows
  windows = {}
  for _, w in ipairs(list) do
    if type(w) == "table" and w.id ~= nil then
      windows[w.id] = windowRecord(w, old[w.id])
    end
  end
  windowsKnown = true
end

-- Window app_ids (lowercased) that belong to each running app. X11 windows
-- through xwayland-satellite report the satellite's pid and a WM_CLASS such
-- as "steam", so the pid check alone misses them.
local function windowKeys(running)
  local keys = {}
  local function add(key, id)
    if key and key ~= "" then keys[key:lower()] = id end
  end
  for id in pairs(running) do
    add(id:match("[^.]+$"), id)
    add(appMeta(id).wmClass, id)
  end
  -- Full ids last so they win over a short name shared with another app
  for id in pairs(running) do add(id, id) end
  return keys
end

local function windowedApps(running)
  local keys = windowKeys(running)
  local windowed = {}
  for _, w in pairs(windows) do
    local id = keys[w.appId]
    if id then windowed[id] = true end
    if w.flatpakId then windowed[w.flatpakId] = true end
  end
  return windowed
end

---------------------------------------------------------------------------
-- Publishing
---------------------------------------------------------------------------

local ready = false
local running = {}
local runningPids = {}
local instancesOk = false
local lastPublished = nil
local lastError = nil
local firstSeenMs = {}  -- app id -> when it was first seen running
local initialScan = true

local function setError(failed)
  if failed ~= lastError then
    lastError = failed
    noctalia.state.set("bg_error", failed)
  end
end

-- Recomputes the list from what is already in memory. Cheap; called after
-- every instance poll and every window event.
local function recompute()
  if not ready or not instancesOk or not windowsKnown then return end

  local now = noctalia.nowMs()
  for id in pairs(firstSeenMs) do
    if not running[id] then firstSeenMs[id] = nil end
  end

  local windowed = next(running) and windowedApps(running) or {}
  local apps = {}
  for id in pairs(running) do
    if not firstSeenMs[id] then
      -- Apps already running when the plugin starts are not starting up
      firstSeenMs[id] = initialScan and (now - STARTUP_GRACE_MS) or now
    end
    if not windowed[id] and now - firstSeenMs[id] >= STARTUP_GRACE_MS then
      local meta = appMeta(id)
      table.insert(apps, { id = id, name = meta.name, icon = meta.icon })
    end
  end
  initialScan = false
  table.sort(apps, function(a, b) return a.name:lower() < b.name:lower() end)

  local encoded = noctalia.json.encode(apps)
  if encoded ~= lastPublished then
    lastPublished = encoded
    noctalia.state.set("bg_apps", apps)
  end
end

local function pollInstances()
  local r, p, err = readInstances()
  if r then
    running, runningPids, instancesOk = r, p, true
    return true
  end
  noctalia.log("flatpak-bg: " .. err)
  return false
end

---------------------------------------------------------------------------
-- niri event stream, with polling as fallback
---------------------------------------------------------------------------

local streamActive = false
local streamRestartPending = false
local pollingWindows = false
local windowsFailed = false

local function handleEvent(line)
  if line == STREAM_END then
    noctalia.log("flatpak-bg: niri event stream ended, falling back to polling")
    streamActive = false
    windowsKnown = false
    return
  end

  -- Only window events matter; skip the rest without decoding them
  if line:sub(1, 8) ~= '{"Window' then return end
  local event = decodeJson(line)
  if type(event) ~= "table" then return end

  if event.WindowsChanged then
    setWindows(event.WindowsChanged.windows or {})
  elseif event.WindowOpenedOrChanged then
    local w = event.WindowOpenedOrChanged.window
    if type(w) ~= "table" or w.id == nil then return end
    local old = windows[w.id]
    local appId = type(w.app_id) == "string" and w.app_id:lower() or ""
    local pid = type(w.pid) == "number" and math.floor(w.pid) or nil
    -- Title and focus changes also arrive here; they change nothing for us
    if old and old.appId == appId and old.pid == pid then return end
    windows[w.id] = windowRecord(w, old)
  elseif event.WindowClosed then
    windows[event.WindowClosed.id] = nil
  else
    return
  end
  windowsFailed = false
  -- Window changes use the last instance poll; new instances show up on the next tick
  recompute()
  setError(not instancesOk)
end

local function startStream()
  if streamActive then return end
  -- `; echo` reports the end of the stream, e.g. when niri restarts
  local cmd = "niri msg -j event-stream; echo " .. STREAM_END
  streamActive = noctalia.runStream(cmd, handleEvent) == true
  if not streamActive then
    noctalia.log("flatpak-bg: could not start niri event stream, polling instead")
  end
end

local function scheduleStreamRestart()
  if streamActive or streamRestartPending then return end
  streamRestartPending = true
  local started = noctalia.runAsync({ "sleep", tostring(STREAM_RESTART_SECONDS) }, function()
    streamRestartPending = false
    startStream()
  end)
  if not started then streamRestartPending = false end
end

-- Used only while the event stream is down
local function pollWindows(done)
  if pollingWindows then return end
  pollingWindows = true
  local started = noctalia.runAsync({ "niri", "msg", "-j", "windows" }, function(res)
    pollingWindows = false
    local list = res.exitCode == 0 and decodeJson(res.stdout) or nil
    if type(list) == "table" and not streamActive then
      setWindows(list)
      windowsFailed = false
    elseif type(list) ~= "table" then
      noctalia.log("flatpak-bg: could not read niri windows")
      windowsFailed = true
    end
    done()
  end)
  if not started then
    pollingWindows = false
    windowsFailed = true
    done()
  end
end

local function scan()
  if not ready then return end
  local ok = pollInstances()
  if not ok then instancesOk = false end

  if streamActive then
    recompute()
    setError(not ok)
  else
    scheduleStreamRestart()
    pollWindows(function()
      recompute()
      setError(not instancesOk or windowsFailed)
    end)
  end
end

---------------------------------------------------------------------------
-- Stopping
---------------------------------------------------------------------------

local stopping = {}

local function publishStopping()
  local copy = {}
  for id in pairs(stopping) do copy[id] = true end
  noctalia.state.set("bg_stopping", copy)
end

local function stopDone(id, failed)
  stopping[id] = nil
  publishStopping()
  if failed then noctalia.notifyError(noctalia.tr("notify.stop_failed"), appMeta(id).name) end
  scan()
end

local function forceKill(id)
  local started = noctalia.runAsync({ "flatpak", "kill", id }, function(res)
    stopDone(id, res.exitCode ~= 0)
  end)
  if not started then stopDone(id, true) end
end

-- After the grace period, kill whatever is still running
local function forceKillIfRunning(id)
  local seconds = tostring(noctalia.getConfig("stop_timeout") or 5)
  local started = noctalia.runAsync({ "sleep", seconds }, function()
    local r = readInstances()
    if r and not r[id] then
      stopDone(id, false)
    else
      forceKill(id)
    end
  end)
  if not started then forceKill(id) end
end

-- Ask the app to quit with SIGTERM so it can save its state
local function stopApp(id)
  if not isAppId(id) or stopping[id] then return end
  stopping[id] = true
  publishStopping()

  local r, pids = readInstances()
  if not r then
    forceKill(id)
    return
  end
  local targets = pids[id]
  if not targets then
    stopDone(id, false)  -- already gone
    return
  end

  local argv = { "kill", "-TERM" }
  for _, pid in ipairs(targets) do table.insert(argv, pid) end
  local started = noctalia.runAsync(argv, function(res)
    if res.exitCode == 0 then forceKillIfRunning(id) else forceKill(id) end
  end)
  if not started then forceKill(id) end
end

local lastStopSeq = 0

local function handleStopRequests(requests)
  if type(requests) ~= "table" then return end
  local highest = lastStopSeq
  for _, req in ipairs(requests) do
    if type(req) == "table" and type(req.seq) == "number" and req.seq > lastStopSeq then
      stopApp(req.id)
      if req.seq > highest then highest = req.seq end
    end
  end
  lastStopSeq = highest
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

local function applyInterval()
  noctalia.setUpdateInterval(noctalia.getConfig("interval") * 1000)
end

function update()
  scan()
end

function onConfigChanged()
  applyInterval()
end

function onIpc(event)
  if event == "refresh" then scan() end
end

noctalia.state.watch("refresh", function()
  scan()
end)

noctalia.state.watch("stop_requests", handleStopRequests)

-- Requests left over from before this service started are not replayed
do
  local pending = noctalia.state.get("stop_requests")
  if type(pending) == "table" then
    for _, req in ipairs(pending) do
      if type(req) == "table" and type(req.seq) == "number" and req.seq > lastStopSeq then
        lastStopSeq = req.seq
      end
    end
  end
end

noctalia.state.set("bg_stopping", {})
applyInterval()
loadInstallations(function()
  ready = true
  startStream()
  scan()
end)
