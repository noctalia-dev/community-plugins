--!nonstrict
-- Docker & Podman Shipyard Service
-- Singleton backend managing container runtimes, event streaming,
-- compose stack discovery, asset lifecycles, and Podman-specific features.

local KEY_SNAPSHOT   = "shipyard_snapshot"
local KEY_COMMAND    = "shipyard_command"
local KEY_PANEL_OPEN = "shipyard_panel_open"

local activeDaemon       = "docker"
local isDaemonAvailable  = false
local isDaemonActive     = false
local isBusy             = false
local scanDirs           = {}
local refreshIntervalSec = 3
local confirmDestructive = true

local snapshot = {
  daemon             = "docker",
  available          = false,
  active             = false,
  busy               = false,
  error              = "",
  globalStats        = { cpu = "0%", ram = "0B", rawCpu = 0, rawRamMb = 0 },
  stacks             = {},
  containers         = {},
  images             = {},
  volumes            = {},
  networks           = {},
  pods               = {},
  lastUpdated        = 0,
  confirmDestructive = true,
  logsOutput         = nil,
  logsTarget         = nil,
  generateOutput     = nil,
  generateTitle      = nil,
  activeTask         = nil,
  onlineSearchResults = nil,
  onlineSearchQuery   = "",
  onlineSearching     = false,
  onlineSearchError   = nil,
  isScanning          = false,
  scanningStacks      = false,
  scanMessage         = nil,
  scanError           = nil,
  scanDirsList        = {},
  lastScanTime        = 0,
  isPodmanRootless    = false,
}

local currentActiveTask        = nil
local activeTaskPid            = nil
local activeTaskIsGroup        = false
local activeTaskCancelling     = false
local eventListenerRunning     = false
local tickCounter              = 0
local isRefreshing             = false
local isRefreshingContainers   = false
local refreshQueued            = false
local currentRefreshGen        = 0
local refreshWatchdogDeadline  = 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function trim(val)
  return noctalia.string.trim(tostring(val or ""))
end

local function shellQuote(val)
  return "'" .. tostring(val):gsub("'", "'\\''") .. "'"
end

local function daemonCmd()
  return activeDaemon == "podman" and "podman" or "docker"
end

local function splitCommandLine(cmdStr)
  local args = {}
  local p = 1
  local len = #cmdStr
  while p <= len do
    while p <= len and cmdStr:sub(p, p):match("%s") do
      p = p + 1
    end
    if p > len then break end
    local arg = ""
    while p <= len and not cmdStr:sub(p, p):match("%s") do
      local ch = cmdStr:sub(p, p)
      if ch == "'" then
        p = p + 1
        while p <= len and cmdStr:sub(p, p) ~= "'" do
          arg = arg .. cmdStr:sub(p, p)
          p = p + 1
        end
        if p <= len then p = p + 1 end
      elseif ch == '"' then
        p = p + 1
        while p <= len and cmdStr:sub(p, p) ~= '"' do
          arg = arg .. cmdStr:sub(p, p)
          p = p + 1
        end
        if p <= len then p = p + 1 end
      else
        arg = arg .. ch
        p = p + 1
      end
    end
    if arg ~= "" then
      table.insert(args, arg)
    end
  end
  return args
end

local function formatBytes(bytes)
  local b = tonumber(bytes) or 0
  if b < 1024 then return string.format("%dB", b) end
  if b < 1024 * 1024 then return string.format("%.1fKB", b / 1024) end
  if b < 1024 * 1024 * 1024 then return string.format("%.1fMB", b / (1024 * 1024)) end
  return string.format("%.2fGB", b / (1024 * 1024 * 1024))
end

local function formatTimeAgo(ts)
  local t = tonumber(ts)
  if not t or t <= 0 then return "" end
  local diff = math.max(0, os.time() - t)
  if diff < 60 then return "just now" end
  if diff < 3600 then return string.format("%d minutes ago", math.floor(diff / 60)) end
  if diff < 86400 then return string.format("%d hours ago", math.floor(diff / 3600)) end
  if diff < 86400 * 30 then return string.format("%d days ago", math.floor(diff / 86400)) end
  if diff < 86400 * 365 then return string.format("%d months ago", math.floor(diff / (86400 * 30))) end
  return string.format("%d years ago", math.floor(diff / (86400 * 365)))
end

local function getSettingsFilePath()
  local dir = noctalia.pluginDataDir and noctalia.pluginDataDir() or ""
  if dir == "" then return nil end
  return dir .. "/state.json"
end

local function loadPersistedState()
  local path = getSettingsFilePath()
  if not path or not noctalia.readFile then return {} end
  local ok, content = pcall(noctalia.readFile, path)
  if not ok or not content or content == "" then return {} end
  local parseOk, data = pcall(noctalia.json.decode, content)
  if parseOk and type(data) == "table" then return data end
  return {}
end

local function savePersistedState(updates)
  local path = getSettingsFilePath()
  if not path or not noctalia.writeFile then return false end
  local current = loadPersistedState()
  for k, v in pairs(updates) do
    current[k] = v
  end
  local encodeOk, encoded = pcall(noctalia.json.encode, current)
  if encodeOk and encoded then
    pcall(noctalia.writeFile, path, encoded)
    return true
  end
  return false
end

local cachedHomeDir = nil

local function getHomeDir()
  if cachedHomeDir and cachedHomeDir ~= "" then
    return cachedHomeDir
  end
  pcall(function()
    local h = os.getenv("HOME")
    if type(h) == "string" and h ~= "" then
      cachedHomeDir = h
    end
  end)
  if cachedHomeDir and cachedHomeDir ~= "" then
    return cachedHomeDir
  end
  if type(noctalia.getenv) == "function" then
    local h = noctalia.getenv("HOME")
    if type(h) == "string" and h ~= "" then
      cachedHomeDir = h
      return cachedHomeDir
    end
  end
  if type(noctalia.expandPath) == "function" then
    local ok, res = pcall(noctalia.expandPath, "~")
    if ok and type(res) == "string" and res ~= "" and not res:find("^~") then
      cachedHomeDir = res
      return cachedHomeDir
    end
  end
  return nil
end

local function expandPath(p)
  local pathStr = tostring(p or "")
  if pathStr:find("^~") then
    if type(noctalia.expandPath) == "function" then
      local ok, res = pcall(noctalia.expandPath, pathStr)
      if ok and type(res) == "string" and res ~= "" and not res:find("^~") then
        return res
      end
    end
    local home = getHomeDir()
    if home and home ~= "" then
      return home .. pathStr:sub(2)
    end
    return pathStr
  end
  return pathStr
end

-- Validation Helpers
local function isValidIdentifier(str)
  if type(str) ~= "string" or str == "" or #str > 256 then return false end
  -- Reject flag injection and path traversal
  if str:sub(1, 1) == "-" or str:find("%.%.") or str:find("/") then return false end
  return str:match("^[a-zA-Z0-9_.-]+$") ~= nil
end

local function isValidImageRef(str)
  if type(str) ~= "string" or str == "" or #str > 256 then return false end
  -- Reject flag injection and path traversal
  if str:sub(1, 1) == "-" or str:find("%.%.") then return false end
  return str:match("^[a-zA-Z0-9_.:/@%%-]+$") ~= nil
end

local function isValidPath(str)
  if type(str) ~= "string" or str == "" or #str > 1024 then return false end
  -- Reject shell meta-characters
  return str:find("[;&|`$\n\r]") == nil
end

local function isPathWithinScanDirs(targetPath)
  if type(targetPath) ~= "string" or targetPath == "" then return false end
  local normalizedTarget = expandPath(targetPath)
  if not normalizedTarget or normalizedTarget == "" then return false end

  for _, dir in ipairs(scanDirs or {}) do
    local exp = expandPath(dir)
    if exp and exp ~= "" then
      if normalizedTarget == exp or normalizedTarget:sub(1, #exp + 1) == exp .. "/" then
        return true
      end
    end
  end
  return false
end

local function isValidPortMapping(str)
  if type(str) ~= "string" or str == "" or #str > 64 then return false end
  return str:match("^%d+%.%d+%.%d+%.%d+:%d+:%d+$") ~= nil
    or str:match("^%d+%.%d+%.%d+%.%d+:%d+:%d+/%a+$") ~= nil
    or str:match("^%d+%.%d+%.%d+%.%d+::%d+$") ~= nil
    or str:match("^%d+:%d+$") ~= nil
    or str:match("^%d+$") ~= nil
    or str:match("^%d+:%d+/%a+$") ~= nil
    or str:match("^%d+/%a+$") ~= nil
end

local function isValidEnv(str)
  if type(str) ~= "string" or str == "" or #str > 1024 then return false end
  if str:find("[\r\n]") then return false end
  return str:match("^[a-zA-Z_][a-zA-Z0-9_]*=.*$") ~= nil
end

local function isValidLocalUrl(url)
  if type(url) ~= "string" or url == "" or #url > 256 then return false end
  return url:match("^https?://localhost:%d+") ~= nil
    or url:match("^https?://127%.0%.0%.1:%d+") ~= nil
end

local function qualifySearchQuery(query, daemon)
  if type(query) ~= "string" or query == "" then return query end
  if daemon == "podman" then
    local firstSegment = query:match("^([^/]+)")
    if not firstSegment or (not firstSegment:find(".", 1, true) and not firstSegment:find(":", 1, true)) then
      return "docker.io/" .. query
    end
  end
  return query
end

local function qualifyImageRef(ref, daemon)
  if type(ref) ~= "string" or ref == "" then return ref end
  if daemon == "podman" then
    local firstSegment = ref:match("^([^/]+)")
    if not firstSegment or (not firstSegment:find(".", 1, true) and not firstSegment:find(":", 1, true)) then
      if not ref:find("/", 1, true) then
        return "docker.io/library/" .. ref
      else
        return "docker.io/" .. ref
      end
    end
  end
  return ref
end

local function parsePorts(rawPorts)
  local list = {}
  local seen = {}

  if type(rawPorts) == "table" then
    for _, p in ipairs(rawPorts) do
      local hp = tonumber(p.host_port or p.hostPort or p.PublicPort)
      if hp and hp > 0 and not seen[hp] then
        seen[hp] = true
        local scheme = (hp == 443 or tostring(hp):match("443$")) and "https" or "http"
        table.insert(list, {
          port = hp,
          url  = `{scheme}://localhost:{hp}`,
          text = `:{hp}`,
        })
      end
    end
    table.sort(list, function(a, b) return a.port < b.port end)
    return list
  end

  local s = tostring(rawPorts or "")
  for hp in string.gmatch(s, ":(%d+)[^0-9]") do
    local portNum = tonumber(hp)
    if portNum and portNum > 0 and not seen[portNum] then
      seen[portNum] = true
      local scheme = (portNum == 443 or hp:match("443$")) and "https" or "http"
      table.insert(list, {
        port = portNum,
        url  = `{scheme}://localhost:{portNum}`,
        text = `:{portNum}`,
      })
    end
  end

  table.sort(list, function(a, b) return a.port < b.port end)
  return list
end

local function runCli(args, callback, timeoutMs)
  local parts = { daemonCmd() }
  for _, arg in ipairs(args) do
    table.insert(parts, shellQuote(arg))
  end
  local cmd = table.concat(parts, " ")
  local started = noctalia.runAsync(cmd, callback, timeoutMs or 30000)
  if not started and callback then
    callback({ exitCode = 1, stdout = "", stderr = "Failed to launch " .. daemonCmd() })
  end
  return started
end

local function runRaw(cmd, callback, timeoutMs)
  local started = noctalia.runAsync(cmd, callback, timeoutMs or 30000)
  if not started and callback then
    callback({ exitCode = 1, stdout = "", stderr = "Failed to launch command" })
  end
  return started
end

local function publishSnapshot()
  snapshot.daemon             = activeDaemon
  snapshot.available          = isDaemonAvailable
  snapshot.active             = isDaemonActive
  snapshot.busy               = isBusy
  snapshot.activeTask         = currentActiveTask
  snapshot.confirmDestructive = confirmDestructive
  snapshot.lastUpdated        = os.time()
  noctalia.state.set(KEY_SNAPSHOT, snapshot)
end

local function setBusyState(busy, title, action, targetId)
  isBusy = busy
  if busy then
    currentActiveTask = {
      id         = targetId or "task",
      name       = targetId or "Task",
      action     = action or "busy",
      title      = title or "Running operation…",
      stage      = title or "Processing…",
      lastLog    = "",
      recentLogs = {},
      progress   = 0.5,
      startTime  = os.time(),
    }
  else
    currentActiveTask = nil
  end
  publishSnapshot()
end

local function runStreamingTask(opts, onComplete)
  local taskPidMarker = "__SHIPYARD_TASK_PID__"
  local taskEndMarker = "__SHIPYARD_TASK_DONE__"
  -- Execute command in a dedicated process group without relying on shell job control (set -m).
  -- Use setsid when available and verify process group creation so cancellation and watchdog
  -- operations can reliably target the process group (-$PID) or fall back to the process PID ($PID).
  -- On exit or cancellation, terminate any remaining descendants before emitting the completion marker.
  local quotedCmd = shellQuote(opts.command)
  local cmd = string.format(
    "CMD=%s; if command -v setsid >/dev/null 2>&1; then setsid sh -c \"$CMD\" & else sh -c \"$CMD\" & fi; PID=$!; IS_GRP=0; for _i in 1 2 3 4 5; do if kill -0 -$PID 2>/dev/null; then IS_GRP=1; break; fi; kill -0 $PID 2>/dev/null || break; sleep 0.02; done; echo \"%s:$PID:$IS_GRP\"; wait $PID; CODE=$?; if [ \"$IS_GRP\" = \"1\" ] && kill -0 -$PID 2>/dev/null; then kill -TERM -$PID 2>/dev/null; for _i in 1 2 3 4 5; do kill -0 -$PID 2>/dev/null || break; sleep 0.1; done; if kill -0 -$PID 2>/dev/null; then kill -KILL -$PID 2>/dev/null; while kill -0 -$PID 2>/dev/null; do sleep 0.05; done; fi; elif kill -0 $PID 2>/dev/null; then kill -TERM $PID 2>/dev/null; for _i in 1 2 3 4 5; do kill -0 $PID 2>/dev/null || break; sleep 0.1; done; if kill -0 $PID 2>/dev/null; then kill -KILL $PID 2>/dev/null; while kill -0 $PID 2>/dev/null; do sleep 0.05; done; fi; fi; echo \"%s:$CODE\"",
    quotedCmd, taskPidMarker, taskEndMarker
  )

  isBusy = true
  activeTaskPid = nil
  activeTaskIsGroup = false
  activeTaskCancelling = false
  currentActiveTask = {
    id         = opts.id or opts.name or "task",
    name       = opts.name or "Task",
    action     = opts.action or "task",
    title      = opts.title or "Running operation…",
    stage      = opts.initialStage or "Starting…",
    lastLog    = "Initializing…",
    recentLogs = {},
    progress   = 0.1,
    startTime  = os.time(),
    cancelling = false,
  }
  publishSnapshot()

  local lastPublishSec = os.time()
  local collectedLogs = {}
  local isFinished = false

  local function finish(exitCode)
    if isFinished then return end
    isFinished = true
    isBusy = false
    local wasCancelling = activeTaskCancelling
    activeTaskPid = nil
    activeTaskIsGroup = false
    activeTaskCancelling = false
    currentActiveTask = nil
    publishSnapshot()
    if onComplete then
      onComplete(exitCode, collectedLogs, wasCancelling)
    end
  end

  local ok = noctalia.runStream(cmd, function(rawChunk)
    if isFinished then return end
    local chunk = tostring(rawChunk or "")

    for line in string.gmatch(chunk, "[^\r\n]+") do
      line = line:gsub("\27%[[0-9;]*[a-zA-Z]", "")
      line = trim(line)
      if line ~= "" then
        local pidStr, isGrpStr = line:match("^" .. taskPidMarker .. ":(%d+):?(%d*)")
        if pidStr then
          activeTaskPid = tonumber(pidStr)
          activeTaskIsGroup = (isGrpStr == "1")
        else
          local endCode = line:match("^" .. taskEndMarker .. ":(%d+)")
          if endCode then
            finish(tonumber(endCode) or 0)
            return
          end

          table.insert(collectedLogs, line)
          if #collectedLogs > 80 then
            table.remove(collectedLogs, 1)
          end

          if currentActiveTask and not activeTaskCancelling then
            currentActiveTask.lastLog = line
            table.insert(currentActiveTask.recentLogs, line)
            if #currentActiveTask.recentLogs > 5 then
              table.remove(currentActiveTask.recentLogs, 1)
            end

          local l = line:lower()
          if l:find("downloading", 1, true) or l:find("pulling fs layer", 1, true) then
            currentActiveTask.stage = "Downloading layers…"
            currentActiveTask.progress = math.max(currentActiveTask.progress, 0.35)
          elseif l:find("extracting", 1, true) then
            currentActiveTask.stage = "Extracting layers…"
            currentActiveTask.progress = math.max(currentActiveTask.progress, 0.60)
          elseif l:find("download complete", 1, true) or l:find("pulled", 1, true) or l:find("pull complete", 1, true) then
            currentActiveTask.stage = "Images downloaded"
            currentActiveTask.progress = math.max(currentActiveTask.progress, 0.75)
          elseif l:find("creating", 1, true) then
            currentActiveTask.stage = "Creating containers…"
            currentActiveTask.progress = math.max(currentActiveTask.progress, 0.85)
          elseif l:find("starting", 1, true) then
            currentActiveTask.stage = "Starting containers…"
            currentActiveTask.progress = math.max(currentActiveTask.progress, 0.92)
          elseif l:find("started", 1, true) then
            currentActiveTask.stage = "Containers started"
            currentActiveTask.progress = 0.98
          elseif l:find("stopping", 1, true) then
            currentActiveTask.stage = "Stopping containers…"
            currentActiveTask.progress = math.max(currentActiveTask.progress, 0.50)
          elseif l:find("stopped", 1, true) then
            currentActiveTask.stage = "Containers stopped"
            currentActiveTask.progress = 0.85
          end

          local pct = line:match("(%d+)%%")
          if pct then
            local p = tonumber(pct) / 100
            if p > currentActiveTask.progress then
              currentActiveTask.progress = math.min(0.99, p)
            end
          end

          local done, total = line:match("(%d+)/(%d+)")
          if done and total and tonumber(total) > 0 then
            local p = tonumber(done) / tonumber(total)
            if p > currentActiveTask.progress then
              currentActiveTask.progress = math.min(0.99, p)
            end
          end

          local now = os.time()
          if now ~= lastPublishSec then
            lastPublishSec = now
            publishSnapshot()
          end
        end
      end
    end
  end
end)

  if not ok then
    finish(1)
  end
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local function readConfig()
  local persisted = loadPersistedState()

  -- 1. Daemon type (persisted state overrides plugin setting)
  -- 1. Daemon Engine (persisted toggle or plugin setting)
  if persisted.daemon_type == "podman" or persisted.daemon_type == "docker" then
    activeDaemon = persisted.daemon_type
  else
    local d = noctalia.getConfig("daemon_type")
    if d == "podman" or d == "docker" then
      activeDaemon = d
    else
      activeDaemon = "docker"
    end
  end

  -- 2. Compose Scan Directories (from plugin settings)
  local defaultDirs = { "~/docker", "~/Projects", "~/compose", "~/Labs" }
  local sourceDirs = noctalia.getConfig("compose_scan_dirs")
  if type(sourceDirs) ~= "table" or #sourceDirs == 0 then
    if type(persisted.compose_scan_dirs) == "table" and #persisted.compose_scan_dirs > 0 then
      sourceDirs = persisted.compose_scan_dirs
    end
  end

  if type(sourceDirs) == "table" and #sourceDirs > 0 then
    local cleaned = {}
    for _, dir in ipairs(sourceDirs) do
      local s = tostring(dir or "")
      if s ~= "" and isValidPath(s) then
        table.insert(cleaned, s)
      end
    end
    scanDirs = (#cleaned > 0) and cleaned or defaultDirs
  else
    scanDirs = defaultDirs
  end
  snapshot.scanDirsList = scanDirs

  -- 3. Refresh Interval (from plugin settings)
  local iv = noctalia.getConfig("refresh_interval") or persisted.refresh_interval
  local ivNum = tonumber(iv)
  refreshIntervalSec = (ivNum and ivNum >= 1 and ivNum <= 60) and math.floor(ivNum) or 3

  -- 4. Confirm Destructive Actions (from plugin settings)
  local cfgConfirm = noctalia.getConfig("confirm_destructive")
  if cfgConfirm ~= nil then
    confirmDestructive = (cfgConfirm ~= false)
  elseif persisted.confirm_destructive ~= nil then
    confirmDestructive = (persisted.confirm_destructive ~= false)
  else
    confirmDestructive = true
  end
end

-- ---------------------------------------------------------------------------
-- Daemon Verification (Direct non-blocking ping)
-- ---------------------------------------------------------------------------

local function checkDaemonStatus(onComplete)
  local bin = daemonCmd()
  if not noctalia.commandExists(bin) then
    isDaemonAvailable = false
    isDaemonActive    = false
    snapshot.error    = `{bin} binary not found in PATH`
    snapshot.containers = {}
    snapshot.images = {}
    snapshot.stacks = {}
    snapshot.volumes = {}
    snapshot.networks = {}
    snapshot.pods = {}
    snapshot.globalStats = { cpu = "0%", ram = "0B", rawCpu = 0, rawRamMb = 0 }
    publishSnapshot()
    if onComplete then onComplete(false) end
    return
  end

  isDaemonAvailable = true

  -- Ping daemon with a fast query
  runCli({ "version", "--format", "{{json .Server.Version}}" }, function(result)
    local isUp = (result and result.exitCode == 0)
    if isUp then
      isDaemonActive = true
      snapshot.error = ""
      if activeDaemon == "podman" then
        if snapshot.isPodmanRootless == nil then
          runCli({ "info", "--format", "{{.Host.Security.Rootless}}" }, function(infoRes)
            if infoRes and infoRes.exitCode == 0 then
              snapshot.isPodmanRootless = (trim(infoRes.stdout):lower() == "true")
              publishSnapshot()
            end
          end, 5000)
        end
      else
        snapshot.isPodmanRootless = false
      end
      publishSnapshot()
      if onComplete then onComplete(true) end
      return
    end

    -- Fallback: try `ps -q` in case version JSON format differs
    runCli({ "ps", "-q" }, function(psRes)
      if psRes and psRes.exitCode == 0 then
        isDaemonActive = true
        snapshot.error = ""
        if activeDaemon == "podman" and snapshot.isPodmanRootless == nil then
          runCli({ "info", "--format", "{{.Host.Security.Rootless}}" }, function(infoRes)
            if infoRes and infoRes.exitCode == 0 then
              snapshot.isPodmanRootless = (trim(infoRes.stdout):lower() == "true")
              publishSnapshot()
            end
          end, 5000)
        else
          snapshot.isPodmanRootless = false
        end
      else
        isDaemonActive = false
        local err = trim(psRes and psRes.stderr)
        if err == "" then
          err = `{bin} daemon is not responding`
        end
        snapshot.error = err
        snapshot.containers = {}
        snapshot.images = {}
        snapshot.stacks = {}
        snapshot.volumes = {}
        snapshot.networks = {}
        snapshot.pods = {}
        snapshot.globalStats = { cpu = "0%", ram = "0B", rawCpu = 0, rawRamMb = 0 }
      end
      publishSnapshot()
      if onComplete then onComplete(isDaemonActive) end
    end, 5000)
  end, 5000)
end

-- ---------------------------------------------------------------------------
-- Containers & Stats
-- ---------------------------------------------------------------------------

local refreshContainerStats

local function refreshContainers(onComplete)
  if not isDaemonActive then
    snapshot.containers = {}
    publishSnapshot()
    if onComplete then onComplete() end
    return
  end

  if isRefreshingContainers then
    if onComplete then onComplete() end
    return
  end
  isRefreshingContainers = true

  runCli({ "ps", "-a", "--no-trunc", "--format", "{{json .}}" }, function(result)
    pcall(function()
      local containers = {}
      if result and result.exitCode == 0 then
        for line in string.gmatch(result.stdout or "", "[^\r\n]+") do
          line = trim(line)
          if line ~= "" then
            local ok, item = pcall(noctalia.json.decode, line)
            if ok and type(item) == "table" then
              local id = trim(item.ID or item.Id)

              local rawName = ""
              if type(item.Names) == "table" and item.Names[1] then
                rawName = item.Names[1]
              elseif type(item.Names) == "string" and item.Names ~= "" then
                rawName = item.Names
              elseif type(item.Name) == "string" and item.Name ~= "" then
                rawName = item.Name
              else
                rawName = item.ID or item.Id or "container"
              end
              local name = trim(rawName):gsub("^/", "")

              local state = trim(item.State or ""):lower()
              local status = trim(item.Status or "")
              if state == "" then
                local st = status:lower()
                if st:find("up", 1, true) then state = "running"
                elseif st:find("pause", 1, true) then state = "paused"
                else state = "exited" end
              end
              if status == "" then
                status = state:sub(1, 1):upper() .. state:sub(2)
              end

              local stack = nil
              local composeWorkingDir = nil
              local composeConfigFile = nil
              if type(item.Labels) == "table" then
                stack = item.Labels["com.docker.compose.project"] or item.Labels["io.podman.compose.project"]
                composeWorkingDir = item.Labels["com.docker.compose.project.working_dir"] or item.Labels["io.podman.compose.project.working_dir"]
                composeConfigFile = item.Labels["com.docker.compose.project.config_files"] or item.Labels["io.podman.compose.project.config_files"]
              elseif type(item.Labels) == "string" and item.Labels ~= "" then
                stack = item.Labels:match("com%.docker%.compose%.project=([^,]+)")
                     or item.Labels:match("io%.podman%.compose%.project=([^,]+)")
                composeWorkingDir = item.Labels:match("com%.docker%.compose%.project%.working_dir=([^,]+)")
                                 or item.Labels:match("io%.podman%.compose%.project%.working_dir=([^,]+)")
                composeConfigFile = item.Labels:match("com%.docker%.compose%.project%.config_files=([^,]+)")
                                 or item.Labels:match("io%.podman%.compose%.project%.config_files=([^,]+)")
              end

              local mountsList = {}
              if type(item.Mounts) == "table" then
                for _, m in ipairs(item.Mounts) do
                  if type(m) == "string" and m ~= "" then
                    table.insert(mountsList, m)
                  elseif type(m) == "table" then
                    local mn = m.Name or m.Source or m.Destination
                    if mn and mn ~= "" then table.insert(mountsList, tostring(mn)) end
                  end
                end
              elseif type(item.Mounts) == "string" and item.Mounts ~= "" then
                for m in string.gmatch(item.Mounts, "[^,;%s]+") do
                  table.insert(mountsList, m)
                end
              end

              local netsList = {}
              if type(item.Networks) == "table" then
                for _, n in ipairs(item.Networks) do
                  if type(n) == "string" and n ~= "" then
                    table.insert(netsList, n)
                  elseif type(n) == "table" then
                    local nn = n.Name or n.NetworkID
                    if nn and nn ~= "" then table.insert(netsList, tostring(nn)) end
                  end
                end
              elseif type(item.Networks) == "string" and item.Networks ~= "" then
                for n in string.gmatch(item.Networks, "[^,;%s]+") do
                  table.insert(netsList, n)
                end
              end

              local isRootless = false
              if activeDaemon == "podman" then
                if item.rootless ~= nil then
                  isRootless = (item.rootless == true or tostring(item.rootless) == "true")
                else
                  isRootless = (snapshot.isPodmanRootless == true)
                end
              end

              table.insert(containers, {
                id                = id,
                name              = name,
                image             = trim(item.Image or ""),
                imageID           = trim(item.ImageID or item.ImageId or ""),
                state             = state,
                status            = status,
                ports             = trim(type(item.Ports) == "string" and item.Ports or ""),
                portsList         = parsePorts(item.Ports) or {},
                created           = trim(item.CreatedAt or item.CreatedSince or ""),
                stack             = stack,
                composeWorkingDir = composeWorkingDir,
                composeConfigFile = composeConfigFile,
                networks          = table.concat(netsList, ", "),
                networksList      = netsList,
                mounts            = table.concat(mountsList, ", "),
                mountsList        = mountsList,
                cpu               = "0%",
                ram               = "0B",
                rootless          = isRootless,
              })
            end
          end
        end
      end

      snapshot.containers = containers
      publishSnapshot()
    end)

    isRefreshingContainers = false
    if onComplete then onComplete() end
    refreshContainerStats(nil)
  end, 15000)
end

refreshContainerStats = function(onComplete)
  local hasRunning = false
  for _, c in ipairs(snapshot.containers) do
    if c.state == "running" then
      hasRunning = true
      break
    end
  end

  if not hasRunning then
    snapshot.globalStats = { cpu = "0%", ram = "0B", rawCpu = 0, rawRamMb = 0 }
    publishSnapshot()
    if onComplete then onComplete() end
    return
  end

  runCli({ "stats", "--no-stream", "--format", "{{json .}}" }, function(result)
    pcall(function()
      if not result or result.exitCode ~= 0 then
        return
      end

      local statsMap   = {}
      local totalCpu   = 0.0
      local totalRamMb = 0.0

      for line in string.gmatch(result.stdout or "", "[^\r\n]+") do
        line = trim(line)
        if line ~= "" then
          local ok, entry = pcall(noctalia.json.decode, line)
          if ok and type(entry) == "table" then
            local fullId  = trim(entry.Container or entry.ContainerID or "")
            local shortId = trim(entry.ID or entry.Id or "")
            local name    = trim(entry.Name or "")

            local cpuVal = 0.0
            local cpuStr = "0%"
            if type(entry.CPU) == "number" then
              cpuVal = entry.CPU
              cpuStr = string.format("%.1f%%", cpuVal)
            elseif type(entry.CPUPerc) == "string" then
              local num = tonumber((entry.CPUPerc:gsub("%%", ""))) or 0
              cpuVal = num
              cpuStr = string.format("%s%%", math.floor(num + 0.5))
            elseif type(entry.CPU) == "string" then
              local num = tonumber((entry.CPU:gsub("%%", ""))) or 0
              cpuVal = num
              cpuStr = string.format("%s%%", math.floor(num + 0.5))
            end

            local ramBytes = 0
            local ramShort = "0B"
            if type(entry.MemUsage) == "number" then
              ramBytes = entry.MemUsage
              ramShort = formatBytes(ramBytes)
            elseif type(entry.MemUsage) == "string" then
              local raw = trim(entry.MemUsage)
              if not raw:find("^%-%-") and not raw:find("^0B%s*/") and raw ~= "" then
                local usedPart = raw:match("^([%d%.]+%s*%a+)") or raw
                ramShort = trim(usedPart)
                local num, unit = ramShort:match("([%d%.]+)%s*(%a+)")
                local rNum = tonumber(num) or 0
                if     unit == "GiB" or unit == "GB" then ramBytes = rNum * 1024 * 1024 * 1024
                elseif unit == "MiB" or unit == "MB" then ramBytes = rNum * 1024 * 1024
                elseif unit == "KiB" or unit == "KB" then ramBytes = rNum * 1024
                else ramBytes = rNum end
              end
            end

            local s = { cpu = cpuStr, ram = ramShort }
            if fullId ~= "" then statsMap[fullId] = s end
            if shortId ~= "" then statsMap[shortId] = s end
            if name ~= "" then statsMap[name] = s end

            totalCpu += cpuVal
            totalRamMb += (ramBytes / (1024 * 1024))
          end
        end
      end

      for _, c in ipairs(snapshot.containers) do
        local s = statsMap[c.id]
               or (c.id and #c.id >= 12 and statsMap[c.id:sub(1, 12)])
               or statsMap[c.name]
        if s then
          c.cpu = s.cpu
          c.ram = s.ram
        end
      end

      local ramFmt = totalRamMb >= 1024
        and string.format("%.1fGB", totalRamMb / 1024)
        or  string.format("%dMB",  math.floor(totalRamMb))

      snapshot.globalStats = {
        cpu      = string.format("%d%%", math.floor(totalCpu + 0.5)),
        ram      = ramFmt,
        rawCpu   = totalCpu,
        rawRamMb = totalRamMb,
      }
    end)

    publishSnapshot()
    if onComplete then onComplete() end
  end, 10000)
end

-- ---------------------------------------------------------------------------
-- Event-Stream Trigger
-- ---------------------------------------------------------------------------

local function triggerEventStreamCheck()
  if eventListenerRunning or not isDaemonActive then return end
  if noctalia.state.get(KEY_PANEL_OPEN) ~= true then return end
  eventListenerRunning = true
  runCli({ "events", "--since", "3s", "--until", "0s", "--format", "{{json .}}" }, function(result)
    eventListenerRunning = false
    if result and result.exitCode == 0 and trim(result.stdout) ~= "" then
      refreshContainers()
    end
  end, 8000)
end

-- ---------------------------------------------------------------------------
-- Stacks Tab: Compose Director
-- ---------------------------------------------------------------------------

local function scanComposeStacks(onComplete, notifyUser)
  snapshot.scanningStacks = true
  snapshot.scanError      = nil
  snapshot.scanDirsList   = scanDirs
  publishSnapshot()

  if #scanDirs == 0 then
    snapshot.stacks         = {}
    snapshot.scanningStacks = false
    snapshot.scanMessage    = "No scan directories configured. Add directories in Settings."
    publishSnapshot()
    if notifyUser then
      noctalia.notify(noctalia.tr("name"), "No compose scan directories configured")
    end
    if onComplete then onComplete() end
    return
  end

  local expandedDirs = {}
  for _, dir in ipairs(scanDirs) do
    local exp = expandPath(dir)
    table.insert(expandedDirs, shellQuote(exp))
  end

  local names = "\\( -name 'docker-compose.yml' -o -name 'docker-compose.yaml'"
       .. " -o -name 'compose.yml' -o -name 'compose.yaml'"
       .. " -o -name 'podman-compose.yml' -o -name 'podman-compose.yaml'"
       .. " -o -name 'container-compose.yml' -o -name 'container-compose.yaml' \\)"

  local dirsArgs = table.concat(expandedDirs, " ")
  local findScript = 'any_dir=0\n'
    .. 'for d in ' .. dirsArgs .. '; do\n'
    .. '  case "$d" in\n'
    .. '    "~"/*) d="$HOME/${d#\\~/}" ;;\n'
    .. '    "~")   d="$HOME" ;;\n'
    .. '  esac\n'
    .. '  if [ -d "$d" ]; then\n'
    .. '    any_dir=1\n'
    .. '    break\n'
    .. '  fi\n'
    .. 'done\n'
    .. 'if [ "$any_dir" -eq 0 ]; then\n'
    .. '  echo "__SHIPYARD_NO_DIRS__"\n'
    .. 'else\n'
    .. '  for d in ' .. dirsArgs .. '; do\n'
    .. '    case "$d" in\n'
    .. '      "~"/*) d="$HOME/${d#\\~/}" ;;\n'
    .. '      "~")   d="$HOME" ;;\n'
    .. '    esac\n'
    .. '    if [ -d "$d" ]; then\n'
    .. '      find "$d" -maxdepth 8 \\( -name .git -o -name node_modules \\) -prune -o -type f ' .. names .. ' -print 2>/dev/null\n'
    .. '    fi\n'
    .. '  done | head -n 120 | while IFS= read -r f; do\n'
    .. '    [ -f "$f" ] || continue\n'
    .. '    d="${f%/*}"\n'
    .. '    s="${d##*/}"\n'
    .. '    printf \'%s\\t%s\\t%s\\n\' "$s" "$d" "$f"\n'
    .. '  done\n'
    .. 'fi\n'

  runRaw(findScript, function(result)
    pcall(function()
      snapshot.scanningStacks = false

      local stdout = (result and result.stdout) or ""

      if stdout:find("__SHIPYARD_NO_DIRS__", 1, true) then
        snapshot.stacks = {}
        local msg = string.format("None of the configured directories exist on disk (%s)", table.concat(scanDirs, ", "))
        snapshot.scanMessage = msg
        snapshot.scanError   = msg
        publishSnapshot()
        if notifyUser then
          noctalia.notify(noctalia.tr("name"), noctalia.tr("notifications.scan_error", { error = "Directories not found on disk" }))
        end
        return
      end

      -- Pre-build lookup maps for containers to make stack matching O(1)
      local runningByFile  = {}
      local countByFile    = {}
      local runningByDir   = {}
      local countByDir     = {}
      local runningByStack = {}
      local countByStack   = {}

      for _, c in ipairs(snapshot.containers or {}) do
        local isRun = (c.state == "running")
        if c.composeConfigFile and c.composeConfigFile ~= "" then
          countByFile[c.composeConfigFile] = (countByFile[c.composeConfigFile] or 0) + 1
          if isRun then runningByFile[c.composeConfigFile] = true end
        end
        if c.composeWorkingDir and c.composeWorkingDir ~= "" then
          countByDir[c.composeWorkingDir] = (countByDir[c.composeWorkingDir] or 0) + 1
          if isRun then runningByDir[c.composeWorkingDir] = true end
        end
        if c.stack and c.stack ~= "" then
          countByStack[c.stack] = (countByStack[c.stack] or 0) + 1
          if isRun then runningByStack[c.stack] = true end
        end
      end

      local found = {}
      local seen  = {}

      for line in string.gmatch(stdout, "[^\r\n]+") do
        local stackName, dirPath, filePath = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
        if stackName and dirPath and filePath and not seen[dirPath] then
          seen[dirPath] = true

          local isRunning = (runningByFile[filePath] == true)
            or (runningByDir[dirPath] == true)
            or (runningByStack[stackName] == true)

          local matchedCount = countByFile[filePath]
            or countByDir[dirPath]
            or countByStack[stackName]
            or 0

          -- Fallback prefix matching if container doesn't have compose labels
          if matchedCount == 0 and stackName ~= "" then
            local prefixHyphen = stackName .. "-"
            local prefixUnder  = stackName .. "_"
            for _, c in ipairs(snapshot.containers or {}) do
              if c.name == stackName
                or c.name:sub(1, #prefixHyphen) == prefixHyphen
                or c.name:sub(1, #prefixUnder) == prefixUnder then
                matchedCount += 1
                if c.state == "running" then isRunning = true end
              end
            end
          end

          table.insert(found, {
            name           = stackName,
            path           = dirPath,
            file           = filePath,
            running        = isRunning,
            containerCount = matchedCount,
          })
        end
      end

      snapshot.stacks = found
      snapshot.lastScanTime = os.time()

      if #found > 0 then
        snapshot.scanMessage = string.format("Scan complete: found %d compose stack(s)", #found)
        snapshot.scanError   = nil
      else
        snapshot.scanMessage = string.format("No compose files found in configured scan directories (%s)", table.concat(scanDirs, ", "))
        snapshot.scanError   = nil
      end

      publishSnapshot()
    end)

    if onComplete then onComplete() end
  end, 15000)
end

-- ---------------------------------------------------------------------------
-- Images Tab
-- ---------------------------------------------------------------------------

local function refreshImages(onComplete)
  if not isDaemonActive then
    snapshot.images = {}
    publishSnapshot()
    if onComplete then onComplete() end
    return
  end

  runCli({ "images", "--format", "{{json .}}" }, function(result)
    pcall(function()
      local usedImageRefs = {}
      local usedImageIds  = {}
      for _, c in ipairs(snapshot.containers or {}) do
        if c.image and c.image ~= "" then
          usedImageRefs[c.image] = (usedImageRefs[c.image] or 0) + 1
        end
        local cImgId = (c.imageID or ""):gsub("^sha256:", "")
        if cImgId ~= "" then
          usedImageIds[cImgId] = true
          if #cImgId >= 12 then
            usedImageIds[cImgId:sub(1, 12)] = true
          end
        end
      end

      local images = {}
      if result and result.exitCode == 0 then
        for line in string.gmatch(result.stdout or "", "[^\r\n]+") do
          line = trim(line)
          if line ~= "" then
            local ok, item = pcall(noctalia.json.decode, line)
            if ok and type(item) == "table" then
              local repo = trim(item.Repository or item.repository or "")
              if repo == "" and type(item.RepoTags) == "table" and item.RepoTags[1] then
                repo = item.RepoTags[1]:match("^(.-):") or item.RepoTags[1]
              end
              if repo == "" and type(item.Names) == "table" and item.Names[1] then
                repo = item.Names[1]:match("^(.-):") or item.Names[1]
              end
              if repo == "" then repo = "<none>" end

              local tag = trim(item.Tag or item.tag or "")
              if tag == "" and type(item.RepoTags) == "table" and item.RepoTags[1] then
                tag = item.RepoTags[1]:match(":(.-)$") or ""
              end
              if tag == "" and type(item.Names) == "table" and item.Names[1] then
                tag = item.Names[1]:match(":(.-)$") or ""
              end
              if tag == "" then tag = "<none>" end

              local id = trim(item.ID or item.Id or item.id or "")

              local sizeStr = ""
              if type(item.Size) == "number" then
                sizeStr = formatBytes(item.Size)
              else
                sizeStr = trim(item.Size or "")
              end

              local createdStr = ""
              if type(item.Created) == "number" then
                createdStr = formatTimeAgo(item.Created)
              elseif type(item.CreatedAt) == "number" then
                createdStr = formatTimeAgo(item.CreatedAt)
              else
                createdStr = trim(item.CreatedSince or item.CreatedAt or item.Created or "")
              end

              local useCount = tonumber(item.Containers) or 0
              if useCount == 0 then
                local fullName = (tag ~= "<none>") and `{repo}:{tag}` or repo
                local shortId = (id ~= "") and id:gsub("^sha256:", ""):sub(1, 12) or ""

                if shortId ~= "" and usedImageIds[shortId] then
                  useCount = 1
                elseif repo ~= "<none>" and repo ~= "" then
                  if usedImageRefs[fullName] then
                    useCount = usedImageRefs[fullName]
                  elseif tag == "latest" and usedImageRefs[repo] then
                    useCount = usedImageRefs[repo]
                  elseif usedImageRefs[`docker.io/library/{fullName}`] or usedImageRefs[`docker.io/{fullName}`] then
                    useCount = 1
                  elseif tag == "latest" and (usedImageRefs[`docker.io/library/{repo}`] or usedImageRefs[`docker.io/{repo}`]) then
                    useCount = 1
                  end
                end
              end

              table.insert(images, {
                id         = id,
                repository = repo,
                tag        = tag,
                size       = sizeStr,
                created    = createdStr,
                inUseCount = useCount,
              })
            end
          end
        end
      end

      snapshot.images = images
      publishSnapshot()
    end)

    if onComplete then onComplete() end
  end, 15000)
end

-- ---------------------------------------------------------------------------
-- Infrastructure Tab: Volumes & Networks
-- ---------------------------------------------------------------------------

local function refreshInfrastructure(onComplete)
  if not isDaemonActive then
    snapshot.volumes  = {}
    snapshot.networks = {}
    publishSnapshot()
    if onComplete then onComplete() end
    return
  end

  local activeVolumes = {}
  local usedNets      = {}

  -- 1. Extract usage from active container inventory (mountsList and networksList)
  for _, c in ipairs(snapshot.containers or {}) do
    for _, n in ipairs(c.networksList or {}) do
      local nn = trim(n)
      if nn ~= "" then
        usedNets[nn] = true
        usedNets[nn:lower()] = true
      end
    end

    for _, m in ipairs(c.mountsList or {}) do
      local mn = trim(m)
      if mn ~= "" then
        activeVolumes[mn] = true
      end
    end
  end

  local cmd = daemonCmd()
  local script = string.format([[
    %s volume ls -f dangling=false --format 'VOL_INUSE	{{.Name}}' 2>/dev/null
    %s network ls -f dangling=false --format 'NET_INUSE	{{.Name}}	{{.ID}}' 2>/dev/null
    %s volume ls --format 'VOL_ALL	{{json .}}' 2>/dev/null
    %s network ls --format 'NET_ALL	{{json .}}' 2>/dev/null
  ]], cmd, cmd, cmd, cmd)

  runRaw(script, function(result)
    pcall(function()
      local volumes = {}
      local networks = {}
      if result and result.stdout then
        for line in string.gmatch(result.stdout, "[^\r\n]+") do
          local prefix, rest = line:match("^([A-Z_]+)\t(.*)$")
          if prefix == "VOL_INUSE" then
            local vn = trim(rest)
            if vn ~= "" then activeVolumes[vn] = true end
          elseif prefix == "NET_INUSE" then
            local netName, netId = rest:match("^([^\t]+)\t?(.*)$")
            if netName and netName ~= "" then
              local nn = trim(netName)
              usedNets[nn] = true
              usedNets[nn:lower()] = true
            end
            if netId and netId ~= "" then
              usedNets[trim(netId)] = true
            end
          elseif prefix == "VOL_ALL" then
            local jok, v = pcall(noctalia.json.decode, rest)
            if jok and type(v) == "table" then
              local vname = trim(v.Name or v.name or "")
              if vname ~= "" then
                table.insert(volumes, {
                  name       = vname,
                  driver     = trim(v.Driver or v.driver or "local"),
                  mountpoint = trim(v.Mountpoint or v.mountpoint or ""),
                  inUse      = (activeVolumes[vname] == true),
                })
              end
            end
          elseif prefix == "NET_ALL" then
            local jok, n = pcall(noctalia.json.decode, rest)
            if jok and type(n) == "table" then
              local nname    = trim(n.Name or n.name or "")
              local nid      = trim(n.ID or n.Id or n.id or "")
              local isSystem = (nname == "bridge" or nname == "host" or nname == "none" or nname == "podman")
              local inUse    = (usedNets[nname] == true)
                or (usedNets[nname:lower()] == true)
                or (nid ~= "" and usedNets[nid] == true)

              if nname ~= "" then
                table.insert(networks, {
                  id       = nid,
                  name     = nname,
                  driver   = trim(n.Driver or n.driver or "bridge"),
                  scope    = trim(n.Scope or n.scope or "local"),
                  isSystem = isSystem,
                  isOrphan = not isSystem and not inUse,
                })
              end
            end
          end
        end
      end
      snapshot.volumes = volumes
      snapshot.networks = networks
      publishSnapshot()
    end)

    if onComplete then onComplete() end
  end, 10000)
end

-- ---------------------------------------------------------------------------
-- Podman Pods Tab
-- ---------------------------------------------------------------------------

local function refreshPods(onComplete)
  if activeDaemon ~= "podman" or not isDaemonActive then
    snapshot.pods = {}
    publishSnapshot()
    if onComplete then onComplete() end
    return
  end

  runCli({ "pod", "ls", "--format", "{{json .}}" }, function(result)
    pcall(function()
      local pods = {}
      if result and result.exitCode == 0 then
        for line in string.gmatch(result.stdout or "", "[^\r\n]+") do
          line = trim(line)
          if line ~= "" then
            local ok, p = pcall(noctalia.json.decode, line)
            if ok and type(p) == "table" then
              table.insert(pods, {
                id             = trim(p.Id or p.ID or ""),
                name           = trim(p.Name or ""),
                status         = trim(p.Status or ""):lower(),
                containerCount = tonumber(p.NumberOfContainers or p.Containers or 0) or 0,
              })
            end
          end
        end
      end
      snapshot.pods = pods
      publishSnapshot()
    end)
    if onComplete then onComplete() end
  end, 10000)
end

-- ---------------------------------------------------------------------------
-- Refresh Cycle (Concurrent & Resilient)
-- ---------------------------------------------------------------------------

local function refreshAll(onDone)
  if isRefreshing then
    refreshQueued = true
    if onDone then onDone() end
    return
  end

  isRefreshing            = true
  currentRefreshGen      += 1
  local myGen             = currentRefreshGen
  refreshWatchdogDeadline = os.time() + 10
  snapshot.isScanning     = true
  publishSnapshot()

  checkDaemonStatus(function(active)
    if myGen ~= currentRefreshGen then return end

    if not active then
      isRefreshing        = false
      snapshot.isScanning = false
      publishSnapshot()
      if onDone then onDone() end
      if refreshQueued then
        refreshQueued = false
        refreshAll()
      end
      return
    end

    local pending = (activeDaemon == "podman") and 5 or 4
    local isFinished = false

    local function checkDone()
      if myGen ~= currentRefreshGen or isFinished then return end
      pending -= 1
      if pending <= 0 then
        isFinished          = true
        isRefreshing        = false
        snapshot.isScanning = false
        publishSnapshot()
        if onDone then onDone() end
        if refreshQueued then
          refreshQueued = false
          refreshAll()
        end
      end
    end

    refreshContainers(checkDone)
    refreshImages(checkDone)
    refreshInfrastructure(checkDone)
    scanComposeStacks(checkDone, false)
    if activeDaemon == "podman" then
      refreshPods(checkDone)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Command Dispatcher
-- ---------------------------------------------------------------------------

local ALLOWED_ACTIONS = {
  toggle_daemon          = true,
  refresh                = true,
  scan_now               = true,
  scan_stacks            = true,
  refresh_containers     = true,
  refresh_images         = true,
  refresh_infra          = true,
  refresh_pods           = true,
  save_config            = true,
  cancel_task            = true,
  container_logs         = true,
  clear_logs             = true,
  podman_generate_systemd = true,
  podman_generate_kube   = true,
  clear_generate         = true,
  clear_pending_confirm  = true,
  container_start        = true,
  container_stop         = true,
  container_restart      = true,
  container_remove       = true,
  compose_up             = true,
  compose_down           = true,
  compose_deploy_eject   = true,
  images_prune           = true,
  image_remove           = true,
  image_search_online    = true,
  image_pull             = true,
  container_run_image    = true,
  volume_remove          = true,
  network_remove         = true,
  pod_start              = true,
  pod_stop               = true,
  pod_remove             = true,
  open_url               = true,
}

local function onCommandReceived(cmd)
  if type(cmd) ~= "table" or not cmd.action then return end
  local action = cmd.action
  if not ALLOWED_ACTIONS[action] then return end

  -- Task cancellation with actual process group termination
  if action == "cancel_task" then
    if activeTaskPid and not activeTaskCancelling then
      activeTaskCancelling = true
      if currentActiveTask then
        currentActiveTask.stage = "Cancelling…"
        currentActiveTask.cancelling = true
        table.insert(currentActiveTask.recentLogs, "Cancellation requested: terminating process group…")
        publishSnapshot()
      end
      local pid = activeTaskPid
      local target = activeTaskIsGroup and string.format("-%d", pid) or tostring(pid)
      -- Terminate the entire process group (-$pid) if verified, or the process itself ($pid) with fallback.
      noctalia.runAsync(string.format(
        "kill -TERM %s 2>/dev/null || kill -TERM %d 2>/dev/null; for i in 1 2 3 4 5; do (kill -0 %s 2>/dev/null || kill -0 %d 2>/dev/null) || break; sleep 0.1; done; if kill -0 %s 2>/dev/null || kill -0 %d 2>/dev/null; then (kill -KILL %s 2>/dev/null || kill -KILL %d 2>/dev/null); while kill -0 %s 2>/dev/null || kill -0 %d 2>/dev/null; do sleep 0.05; done; fi",
        target, pid, target, pid, target, pid, target, pid, target, pid
      ))
    end
    return
  end

  -- Daemon switch with persistence
  if action == "toggle_daemon" then
    local target = cmd.target or ((activeDaemon == "docker") and "podman" or "docker")
    if target == activeDaemon then return end
    if not noctalia.commandExists(target) then
      noctalia.notify(
        noctalia.tr("name"),
        noctalia.tr("notifications.daemon_not_installed", { daemon = target })
      )
      return
    end

    -- Invalidate any pending or in-flight refresh from previous daemon
    currentRefreshGen += 1
    isRefreshing = false
    refreshQueued = false
    isRefreshingContainers = false

    activeDaemon = target
    savePersistedState({ daemon_type = target })

    -- Optimistic update: flip UI immediately
    snapshot.daemon              = target
    snapshot.containers          = {}
    snapshot.images              = {}
    snapshot.volumes             = {}
    snapshot.networks            = {}
    snapshot.pods                = {}
    snapshot.globalStats         = { cpu = "0%", ram = "0B", rawCpu = 0, rawRamMb = 0 }
    snapshot.onlineSearchResults = nil
    snapshot.onlineSearchQuery   = ""
    snapshot.onlineSearchError   = nil
    snapshot.onlineSearching     = false
    snapshot.isScanning          = true
    publishSnapshot()

    refreshAll()
    return
  end

  -- Manual Scan / Refresh
  if action == "refresh" or action == "scan_now" then
    currentRefreshGen += 1
    isRefreshing = false
    refreshQueued = false
    refreshAll()
    return
  end

  if action == "scan_stacks" then
    scanComposeStacks(nil, true)
    return
  end

  if action == "refresh_containers" then
    snapshot.isScanning = true
    publishSnapshot()
    refreshContainers(function()
      snapshot.isScanning = false
      publishSnapshot()
    end)
    return
  end

  if action == "refresh_images" then
    snapshot.isScanning = true
    publishSnapshot()
    refreshImages(function()
      snapshot.isScanning = false
      publishSnapshot()
    end)
    return
  end

  if action == "refresh_infra" then
    snapshot.isScanning = true
    publishSnapshot()
    refreshInfrastructure(function()
      snapshot.isScanning = false
      publishSnapshot()
    end)
    return
  end

  if action == "refresh_pods" then
    snapshot.isScanning = true
    publishSnapshot()
    refreshPods(function()
      snapshot.isScanning = false
      publishSnapshot()
    end)
    return
  end

  -- Save settings from inline panel
  if action == "save_config" then
    local updates = {}
    if type(cmd.scanDirs) == "table" then
      local validDirs = {}
      for _, dir in ipairs(cmd.scanDirs) do
        local s = tostring(dir or "")
        if s ~= "" and isValidPath(s) then
          table.insert(validDirs, s)
        end
      end
      scanDirs = validDirs
      snapshot.scanDirsList = scanDirs
      updates.compose_scan_dirs = scanDirs
    end
    if type(cmd.refreshInterval) == "number" then
      refreshIntervalSec = math.max(1, math.min(60, math.floor(cmd.refreshInterval)))
      updates.refresh_interval = refreshIntervalSec
    end
    if type(cmd.confirmDestructive) == "boolean" then
      confirmDestructive = cmd.confirmDestructive
      updates.confirm_destructive = confirmDestructive
    end
    savePersistedState(updates)
    refreshAll()
    return
  end

  -- Container Logs Viewer
  if action == "container_logs" and isValidIdentifier(cmd.id) then
    local tail = tonumber(cmd.tail) or 80
    if tail < 1 then tail = 80 end
    if tail > 5000 then tail = 5000 end
    runCli({ "logs", "--tail", tostring(math.floor(tail)), cmd.id }, function(result)
      local text = ""
      if result then
        text = trim((result.stdout or "") .. (result.stderr or ""))
      end
      snapshot.logsOutput = text
      snapshot.logsTarget = cmd.name or cmd.id
      publishSnapshot()
    end, 10000)
    return
  end

  if action == "clear_logs" then
    snapshot.logsOutput = nil
    snapshot.logsTarget = nil
    publishSnapshot()
    return
  end

  -- Podman Generate Actions
  if action == "podman_generate_systemd" and isValidIdentifier(cmd.id) then
    runCli({ "generate", "systemd", "--name", cmd.id }, function(result)
      snapshot.generateOutput = result and trim(result.stdout) or "Error generating unit"
      snapshot.generateTitle  = "systemd unit — " .. tostring(cmd.name or cmd.id)
      publishSnapshot()
    end, 10000)
    return
  end

  if action == "podman_generate_kube" and isValidIdentifier(cmd.id) then
    runCli({ "kube", "generate", cmd.id }, function(result)
      snapshot.generateOutput = result and trim(result.stdout) or "Error generating YAML"
      snapshot.generateTitle  = "Kubernetes YAML — " .. tostring(cmd.name or cmd.id)
      publishSnapshot()
    end, 10000)
    return
  end

  if action == "clear_generate" then
    snapshot.generateOutput = nil
    snapshot.generateTitle  = nil
    publishSnapshot()
    return
  end

  if action == "clear_pending_confirm" then
    publishSnapshot()
    return
  end

  -- Destructive-action confirmation gate
  local destructive = {
    container_remove = true,
    image_remove     = true,
    images_prune     = true,
    volume_remove    = true,
    network_remove   = true,
    pod_remove       = true,
    compose_down     = true,
  }

  if destructive[action] and confirmDestructive and cmd.confirmed ~= true then
    return
  end

  -- Exclusive mutating operation lock
  local mutating = {
    container_start      = true,
    container_stop       = true,
    container_restart    = true,
    container_remove     = true,
    compose_up           = true,
    compose_down         = true,
    compose_deploy_eject = true,
    images_prune         = true,
    image_remove         = true,
    image_pull           = true,
    container_run_image  = true,
    volume_remove        = true,
    network_remove       = true,
    pod_start            = true,
    pod_stop             = true,
    pod_remove           = true,
  }

  if mutating[action] and (isBusy or currentActiveTask ~= nil) then
    noctalia.notify(noctalia.tr("name"), "Another operation is in progress. Please wait.")
    return
  end

  -- Container Actions
  if action == "container_start" and isValidIdentifier(cmd.id) then
    setBusyState(true, string.format("Starting %s…", cmd.name or cmd.id), "container_start", cmd.id)
    runCli({ "start", cmd.id }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to start %s: %s", cmd.name or cmd.id, err))
      end
      refreshContainers()
    end)
  elseif action == "container_stop" and isValidIdentifier(cmd.id) then
    setBusyState(true, string.format("Stopping %s…", cmd.name or cmd.id), "container_stop", cmd.id)
    runCli({ "stop", cmd.id }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to stop %s: %s", cmd.name or cmd.id, err))
      end
      refreshContainers()
    end)
  elseif action == "container_restart" and isValidIdentifier(cmd.id) then
    setBusyState(true, string.format("Restarting %s…", cmd.name or cmd.id), "container_restart", cmd.id)
    runCli({ "restart", cmd.id }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to restart %s: %s", cmd.name or cmd.id, err))
      end
      refreshContainers()
    end)
  elseif action == "container_remove" and isValidIdentifier(cmd.id) then
    setBusyState(true, string.format("Removing %s…", cmd.name or cmd.id), "container_remove", cmd.id)
    runCli({ "rm", "-f", cmd.id }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to remove %s: %s", cmd.name or cmd.id, err))
      end
      refreshContainers()
    end)

  -- Compose Stack Actions
  elseif action == "compose_up" and isValidPath(cmd.path) and isPathWithinScanDirs(cmd.path) then
    local compCmd = (activeDaemon == "docker")
      and "docker compose --progress plain"
      or  "podman compose"

    runStreamingTask({
      action       = "compose_up",
      id           = cmd.path,
      name         = cmd.name or "Stack",
      title        = `Deploying {cmd.name or "stack"}…`,
      initialStage = "Preparing deployment…",
      command      = string.format("cd %s 2>&1 && %s up -d 2>&1", shellQuote(cmd.path), compCmd),
    }, function(exitCode, logs, wasCancelling)
      if wasCancelling then
        noctalia.notify(noctalia.tr("name"), `Deployment of {cmd.name or "stack"} was cancelled`)
      elseif exitCode ~= 0 then
        local errMsg = (#logs > 0 and logs[#logs]) or "Command failed"
        noctalia.notify(noctalia.tr("name"), `Failed to deploy {cmd.name or ""}: {errMsg}`)
      end
      refreshAll()
    end)

  elseif action == "compose_down" and isValidPath(cmd.path) and isPathWithinScanDirs(cmd.path) then
    local compCmd = (activeDaemon == "docker")
      and "docker compose"
      or  "podman compose"

    runStreamingTask({
      action       = "compose_down",
      id           = cmd.path,
      name         = cmd.name or "Stack",
      title        = `Stopping {cmd.name or "stack"}…`,
      initialStage = "Stopping services…",
      command      = string.format("cd %s 2>&1 && %s down 2>&1", shellQuote(cmd.path), compCmd),
    }, function(exitCode, logs, wasCancelling)
      if wasCancelling then
        noctalia.notify(noctalia.tr("name"), `Stopping of {cmd.name or "stack"} was cancelled`)
      elseif exitCode ~= 0 then
        local errMsg = (#logs > 0 and logs[#logs]) or "Command failed"
        noctalia.notify(noctalia.tr("name"), `Failed to stop {cmd.name or ""}: {errMsg}`)
      end
      refreshAll()
    end)

  elseif action == "compose_deploy_eject" and isValidPath(cmd.path) and isPathWithinScanDirs(cmd.path) then
    local compCmd = (activeDaemon == "docker")
      and "docker compose --progress plain"
      or  "podman compose"

    runStreamingTask({
      action       = "compose_deploy_eject",
      id           = cmd.path,
      name         = cmd.name or "Stack",
      title        = `Deploying & Ejecting {cmd.name or "stack"}…`,
      initialStage = "Preparing deployment…",
      command      = string.format("cd %s 2>&1 && %s up -d 2>&1", shellQuote(cmd.path), compCmd),
    }, function(exitCode, logs, wasCancelling)
      if wasCancelling then
        noctalia.notify(noctalia.tr("name"), `Deployment of {cmd.name or "stack"} was cancelled`)
      elseif exitCode ~= 0 then
        local errMsg = (#logs > 0 and logs[#logs]) or "Command failed"
        noctalia.notify(noctalia.tr("name"), `Failed to deploy {cmd.name or ""}: {errMsg}`)
      end
      refreshAll()
    end)

  -- Images Actions
  elseif action == "images_prune" then
    runStreamingTask({
      action       = "images_prune",
      name         = "Images",
      title        = "Pruning unused images…",
      initialStage = "Pruning images…",
      command      = string.format("%s image prune -a -f 2>&1", daemonCmd()),
    }, function(exitCode, logs, wasCancelling)
      if wasCancelling then
        noctalia.notify(noctalia.tr("name"), "Image pruning was cancelled")
      end
      refreshImages()
    end)
  elseif action == "image_remove" and isValidImageRef(cmd.id) then
    setBusyState(true, string.format("Removing image %s…", cmd.name or cmd.id), "image_remove", cmd.id)
    runCli({ "rmi", "-f", cmd.id }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to remove image %s: %s", cmd.name or cmd.id, err))
      end
      refreshImages()
    end)

  elseif action == "image_search_online" then
    local query = trim(cmd.query or "")
    if query == "" then
      snapshot.onlineSearchResults = nil
      snapshot.onlineSearchQuery = ""
      snapshot.onlineSearchError = nil
      snapshot.onlineSearching = false
      publishSnapshot()
      return
    end
    snapshot.onlineSearching = true
    snapshot.onlineSearchQuery = query
    snapshot.onlineSearchError = nil
    publishSnapshot()

    local searchQuery = qualifySearchQuery(query, activeDaemon)

    runCli({ "search", searchQuery, "--limit", "25", "--format", "{{json .}}" }, function(result)
      snapshot.onlineSearching = false
      if result.exitCode == 0 then
        local results = {}
        for line in string.gmatch(result.stdout, "[^\r\n]+") do
          line = trim(line)
          if line ~= "" and (line:sub(1, 1) == "{" or line:sub(1, 1) == "[") then
            local ok, item = pcall(noctalia.json.decode, line)
            if ok and type(item) == "table" then
              local name = trim(item.Name or item.name or "")
              if name ~= "" then
                local desc = trim(item.Description or item.description or "")
                local isOfficial = (item.IsOfficial == "true" or item.IsOfficial == true or item.Official == true or item.official == true or item.Official == "[OK]")
                local stars = tostring(item.StarCount or item.Stars or item.stars or "0")
                local displayName = name:gsub("^docker%.io/library/", ""):gsub("^docker%.io/", "")
                table.insert(results, {
                  name        = name,
                  displayName = displayName,
                  description = desc,
                  official    = isOfficial,
                  stars       = stars,
                })
              end
            end
          end
        end
        snapshot.onlineSearchResults = results
        snapshot.onlineSearchError = nil
        publishSnapshot()

        -- Asynchronously query registry for image download sizes (top 20 results in parallel)
        if noctalia.commandExists("curl") and #results > 0 then
          local fetchScripts = {}
          local countToFetch = math.min(#results, 20)
          for i = 1, countToFetch do
            local item = results[i]
            local rawName = item.name:gsub("^docker%.io/", "")
            local repo = rawName
            if not repo:find("/", 1, true) then
              repo = "library/" .. repo
            end
            if repo:match("^[a-zA-Z0-9_./-]+$") then
              table.insert(fetchScripts, string.format(
                '(s=$(curl -sSf --max-time 3 "https://hub.docker.com/v2/repositories/%s/tags/latest" 2>/dev/null | grep -o \'"full_size":[0-9]*\' | head -n 1 | cut -d: -f2); [ -n "$s" ] && echo "%d:$s") &',
                repo, i
              ))
            end
          end
          if #fetchScripts > 0 then
            local fetchCmd = table.concat(fetchScripts, "\n") .. "\nwait\n"
            local thisResultsRef = results
            noctalia.runAsync(fetchCmd, function(sizeRes)
              if sizeRes and sizeRes.stdout and snapshot.onlineSearchResults == thisResultsRef then
                local updated = false
                for line in string.gmatch(sizeRes.stdout, "[^\r\n]+") do
                  local idxStr, bytesStr = line:match("^(%d+):(%d+)$")
                  if idxStr and bytesStr then
                    local idx = tonumber(idxStr)
                    local bytes = tonumber(bytesStr)
                    if idx and bytes and thisResultsRef[idx] then
                      thisResultsRef[idx].size = bytes
                      thisResultsRef[idx].sizeStr = formatBytes(bytes)
                      updated = true
                    end
                  end
                end
                if updated then
                  publishSnapshot()
                end
              end
            end, 8000)
          end
        end
        return
      else
        snapshot.onlineSearchResults = {}
        local err = trim(result.stderr or "")
        snapshot.onlineSearchError = (err ~= "") and err or "Search query returned an error"
        publishSnapshot()
      end
    end, 20000)

  elseif action == "image_pull" and isValidImageRef(cmd.image) then
    local imgName = trim(cmd.image)
    local pullRef = qualifyImageRef(imgName, activeDaemon)
    runStreamingTask({
      action       = "image_pull",
      id           = imgName,
      name         = imgName,
      title        = `Pulling {imgName}…`,
      initialStage = "Pulling image layers…",
      command      = string.format("%s pull %s 2>&1", daemonCmd(), shellQuote(pullRef)),
    }, function(exitCode, logs, wasCancelling)
      if wasCancelling then
        noctalia.notify(noctalia.tr("name"), `Pull of {imgName} was cancelled`)
      elseif exitCode ~= 0 then
        local errMsg = (#logs > 0 and logs[#logs]) or "Failed to pull image"
        noctalia.notify(noctalia.tr("name"), `Failed to pull {imgName}: {errMsg}`)
      end
      refreshImages()
    end)

  elseif action == "container_run_image" and isValidImageRef(cmd.image) then
    local imgName = trim(cmd.image)
    local runRef = qualifyImageRef(imgName, activeDaemon)
    local flags = { "-d" }

    local cName = trim(cmd.name or "")
    if cName ~= "" and isValidIdentifier(cName) then
      table.insert(flags, "--name")
      table.insert(flags, shellQuote(cName))
    end

    local ports = trim(cmd.ports or "")
    local publishAll = cmd.publishAll == true or ports:upper() == "-P"
    if ports ~= "" and ports:upper() ~= "-P" then
      for p in string.gmatch(ports, "[^,;%s]+") do
        if isValidPortMapping(p) then
          table.insert(flags, "-p")
          table.insert(flags, shellQuote(p))
        end
      end
    elseif publishAll then
      table.insert(flags, "-P")
    end

    local env = trim(cmd.env or "")
    if env ~= "" then
      for e in string.gmatch(env, "[^,\n]+") do
        e = trim(e)
        if e ~= "" and isValidEnv(e) then
          table.insert(flags, "-e")
          table.insert(flags, shellQuote(e))
        end
      end
    end

    table.insert(flags, shellQuote(runRef))

    local runCmd = trim(cmd.command or "")
    if runCmd ~= "" then
      local parts = splitCommandLine(runCmd)
      for _, part in ipairs(parts) do
        table.insert(flags, shellQuote(part))
      end
    end

    local fullCmd = string.format("%s run %s 2>&1", daemonCmd(), table.concat(flags, " "))

    runStreamingTask({
      action       = "container_run_image",
      id           = cName ~= "" and cName or imgName,
      name         = cName ~= "" and cName or imgName,
      title        = `Starting container from {imgName}…`,
      initialStage = "Pulling image and starting container…",
      command      = fullCmd,
    }, function(exitCode, logs, wasCancelling)
      if wasCancelling then
        noctalia.notify(noctalia.tr("name"), `Container launch from {imgName} was cancelled`)
      elseif exitCode ~= 0 then
        local errMsg = (#logs > 0 and logs[#logs]) or "Failed to start container"
        noctalia.notify(noctalia.tr("name"), `Failed to run {imgName}: {errMsg}`)
      end
      refreshAll()
    end)

  -- Infrastructure Actions
  elseif action == "volume_remove" and isValidIdentifier(cmd.name) then
    setBusyState(true, string.format("Removing volume %s…", cmd.name), "volume_remove", cmd.name)
    runCli({ "volume", "rm", cmd.name }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to remove volume %s: %s", cmd.name, err))
      end
      refreshInfrastructure()
    end)
  elseif action == "network_remove" and isValidIdentifier(cmd.id) then
    setBusyState(true, string.format("Removing network %s…", cmd.name or cmd.id), "network_remove", cmd.id)
    runCli({ "network", "rm", cmd.id }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to remove network %s: %s", cmd.name or cmd.id, err))
      end
      refreshInfrastructure()
    end)

  -- Pod Actions (Podman only)
  elseif action == "pod_start" and isValidIdentifier(cmd.id) then
    setBusyState(true, string.format("Starting pod %s…", cmd.name or cmd.id), "pod_start", cmd.id)
    runCli({ "pod", "start", cmd.id }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to start pod %s: %s", cmd.name or cmd.id, err))
      end
      refreshPods()
    end)
  elseif action == "pod_stop" and isValidIdentifier(cmd.id) then
    setBusyState(true, string.format("Stopping pod %s…", cmd.name or cmd.id), "pod_stop", cmd.id)
    runCli({ "pod", "stop", cmd.id }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to stop pod %s: %s", cmd.name or cmd.id, err))
      end
      refreshPods()
    end)
  elseif action == "pod_remove" and isValidIdentifier(cmd.id) then
    setBusyState(true, string.format("Removing pod %s…", cmd.name or cmd.id), "pod_remove", cmd.id)
    runCli({ "pod", "rm", "-f", cmd.id }, function(res)
      setBusyState(false)
      if res and res.exitCode ~= 0 then
        local err = trim(res.stderr or res.stdout or "Command failed")
        noctalia.notify(noctalia.tr("name"), string.format("Failed to remove pod %s: %s", cmd.name or cmd.id, err))
      end
      refreshPods()
      refreshContainers()
    end)
  elseif action == "open_url" and isValidLocalUrl(cmd.url) then
    noctalia.runAsync(string.format("xdg-open %s", shellQuote(cmd.url)))
  end
end

-- ---------------------------------------------------------------------------
-- Service Lifecycle Hooks
-- ---------------------------------------------------------------------------

readConfig()
noctalia.state.watch(KEY_COMMAND, onCommandReceived)
noctalia.setUpdateInterval(1000)
refreshAll()

-- Resolve home directory asynchronously on startup
pcall(function()
  noctalia.runAsync("echo -n \"$HOME\"", function(res)
    if res and res.exitCode == 0 and trim(res.stdout) ~= "" then
      cachedHomeDir = trim(res.stdout)
    end
  end, 5000)
end)

function update()
  tickCounter += 1

  -- Finding 3: Refresh watchdog timeout
  if isRefreshing and os.time() > refreshWatchdogDeadline then
    isRefreshing        = false
    refreshQueued       = false
    snapshot.isScanning = false
    publishSnapshot()
  end

  -- Task watchdog: if a streaming task's process group has vanished from the OS, unlock the busy state
  if isBusy and activeTaskPid and not activeTaskCancelling then
    if tickCounter % 5 == 0 then
      local pidToCheck = activeTaskPid
      local checkCmd = string.format("kill -0 -%d 2>/dev/null || kill -0 %d 2>/dev/null", pidToCheck, pidToCheck)
      noctalia.runAsync(checkCmd, function(res)
        if res and res.exitCode ~= 0 and isBusy and activeTaskPid == pidToCheck and not activeTaskCancelling then
          isBusy = false
          activeTaskPid = nil
          activeTaskIsGroup = false
          currentActiveTask = nil
          publishSnapshot()
        end
      end)
    end
  end

  if tickCounter % 2 == 0 then
    triggerEventStreamCheck()
  end

  local isPanelOpen = noctalia.state.get(KEY_PANEL_OPEN) == true
  local targetTicks = isPanelOpen and refreshIntervalSec or (refreshIntervalSec * 4)

  if tickCounter >= targetTicks then
    tickCounter = 0
    if isPanelOpen then
      -- Finding 8: reconcile container state while panel is open
      refreshContainers()
    else
      checkDaemonStatus()
    end
  end
end

function onConfigChanged()
  readConfig()
  refreshAll()
end

function onIpc(event, _payload)
  if event == "refresh" or event == "scan" then
    refreshAll()
  elseif event == "toggle_daemon" then
    onCommandReceived({ action = "toggle_daemon" })
  end
end
