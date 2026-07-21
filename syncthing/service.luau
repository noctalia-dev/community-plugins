--!nonstrict
-- Syncthing poller — the headless [[service]] entry.
--
-- Talks to the Syncthing REST API directly with noctalia.http (no external
-- helper). Resolves the GUI URL and API key from the plugin settings, falling
-- back to Syncthing's config.xml. Publishes one JSON snapshot to
-- noctalia.state under "st.snapshot" and executes commands sent by the UI
-- entries through "st.cmd" (refresh, pause/resume all, per-folder
-- pause/resume/rescan).

local DEFAULT_CONFIG_PATHS = {
  "~/.local/state/syncthing/config.xml",
  "~/.config/syncthing/config.xml",
}

local ACTIVE_FOLDER_STATES = {
  ["cleaning"] = true,
  ["scan-waiting"] = true,
  ["scanning"] = true,
  ["sync-preparing"] = true,
  ["syncing"] = true,
}

local cfg = {
  baseUrl = "",
  apiKey = "",
  insecure = false,
  pollMs = 10000,
  monitored = {}, -- set of folder ids; empty = all
  monitoredCount = 0,
  sources = { configPath = "", urlSource = "none", apiKeySource = "none" },
}

local busy = false
local pendingPoll = false
-- Previous published snapshot, for event notifications (state transitions).
local prevSnapshot = nil
-- Last connection totals, for transfer-rate computation between polls.
local lastTotals = nil

-- ── Config resolution ────────────────────────────────────────────────────────

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function normalizeBaseUrl(value, defaultScheme)
  local url = trim(value)
  if url == "" then
    return ""
  end
  if not url:match("^https?://") then
    url = `{defaultScheme}://{url}`
  end
  url = url:gsub("/+$", "")
  url = url:gsub("/rest$", "")
  return url
end

local function parseConfigXml()
  local explicit = trim(noctalia.getConfig("config_path"))
  local candidates = explicit ~= "" and { explicit } or DEFAULT_CONFIG_PATHS
  for _, candidate in candidates do
    local xml = noctalia.readFile(candidate)
    if xml then
      local guiAttrs = xml:match("<gui([^>]*)>") or ""
      local guiBlock = xml:match("<gui[^>]*>(.-)</gui>") or ""
      return {
        path = noctalia.expandPath(candidate),
        enabled = guiAttrs:match('enabled%s*=%s*"false"') == nil,
        tls = guiAttrs:match('tls%s*=%s*"true"') ~= nil,
        address = trim(guiBlock:match("<address>([^<]*)</address>")),
        apiKey = trim(guiBlock:match("<apikey>([^<]*)</apikey>")),
      }
    end
  end
  return nil
end

local function resolveConfig()
  local xml = parseConfigXml()
  local scheme = (xml and xml.tls) and "https" or "http"

  local url = normalizeBaseUrl(noctalia.getConfig("url"), scheme)
  local urlSource = "manual"
  if url == "" then
    if xml and xml.address ~= "" and xml.enabled then
      url = normalizeBaseUrl(xml.address, scheme)
      urlSource = "config"
    else
      urlSource = "none"
    end
  end

  local apiKey = trim(noctalia.getConfig("api_key"))
  local apiKeySource = "manual"
  if apiKey == "" then
    apiKey = xml and xml.apiKey or ""
    apiKeySource = apiKey ~= "" and "config" or "none"
  end

  cfg.baseUrl = url
  cfg.apiKey = apiKey
  cfg.insecure = noctalia.getConfig("insecure_tls") == true
  local seconds = tonumber(noctalia.getConfig("poll_interval")) or 10
  cfg.pollMs = math.clamp(seconds, 2, 300) * 1000
  cfg.monitored = {}
  cfg.monitoredCount = 0
  for _, id in (noctalia.getConfig("folders") or {}) do
    id = trim(id)
    if id ~= "" then
      cfg.monitored[id] = true
      cfg.monitoredCount += 1
    end
  end
  cfg.sources = {
    configPath = xml and xml.path or "",
    urlSource = urlSource,
    apiKeySource = apiKeySource,
  }
end

-- ── HTTP ─────────────────────────────────────────────────────────────────────

-- fetch(path, opts, cb) → cb(ok, status, body). opts: method, body, noauth.
-- With insecure_tls on an https URL we shell out to curl -k, because
-- noctalia.http has no way to skip certificate verification.
local function fetch(path, opts, cb)
  local url = cfg.baseUrl .. path

  if cfg.insecure and cfg.baseUrl:match("^https://") then
    local parts = { "curl", "-ksS", "-m", "5", "-w", "'\\n%{http_code}'" }
    if not opts.noauth and cfg.apiKey ~= "" then
      table.insert(parts, `-H "X-API-Key: {cfg.apiKey}"`)
    end
    if opts.method and opts.method ~= "GET" then
      table.insert(parts, `-X {opts.method}`)
    end
    if opts.body then
      table.insert(parts, `-H "Content-Type: application/json" --data-raw '{opts.body}'`)
    end
    table.insert(parts, `"{url}"`)
    local launched = noctalia.runAsync(table.concat(parts, " "), function(result)
      if result.exitCode ~= 0 or result.timedOut then
        cb(false, 0, "")
        return
      end
      local body, code = result.stdout:match("^(.*)\n(%d+)%s*$")
      cb(true, tonumber(code) or 0, body or "")
    end, 8000)
    if not launched then
      cb(false, 0, "")
    end
    return
  end

  local headers = nil
  if not opts.noauth and cfg.apiKey ~= "" then
    headers = { `X-API-Key: {cfg.apiKey}` }
  end
  local started = noctalia.http({
    url = url,
    method = opts.method,
    headers = headers,
    body = opts.body,
  }, function(res)
    cb(res.ok, res.status, res.body)
  end)
  if not started then
    cb(false, 0, "")
  end
end

-- ── Snapshot building ────────────────────────────────────────────────────────

local function emptySnapshot(state, detail)
  return {
    state = state,
    detail = detail or "",
    checkedAt = noctalia.formatTime("hh:mm:ss"),
    sources = {
      configPath = cfg.sources.configPath,
      urlSource = cfg.sources.urlSource,
      apiKeySource = cfg.sources.apiKeySource,
      resolvedUrl = cfg.baseUrl,
    },
    devices = { configured = 0, connected = 0, paused = 0 },
    totals = {
      monitoredFolders = 0, pausedFolders = 0, syncingFolders = 0,
      erroredFolders = 0, needItems = 0, needBytes = 0,
    },
    folders = {},
    devicesList = {},
    recentErrors = {},
    syncPercent = -1, -- overall completion while syncing; -1 = not applicable
    rateIn = 0, -- bytes/sec since previous poll
    rateOut = 0,
  }
end

-- Desktop notifications on meaningful transitions (folder done/error, device
-- connect/disconnect). Only between two healthy snapshots, so a Syncthing
-- restart or plugin reload doesn't spray stale events.
local function notifyTransitions(old, new)
  if noctalia.getConfig("notify_events") == false then
    return
  end
  if not old then
    return
  end
  local healthy = { idle = true, syncing = true, paused = true, disconnected = true, error = true }
  if not healthy[old.state] or not healthy[new.state] then
    return
  end

  local oldFolders = {}
  for _, f in old.folders do
    oldFolders[f.id] = f
  end
  for _, f in new.folders do
    local prev = oldFolders[f.id]
    if prev then
      if prev.state == "syncing" and f.state == "idle" then
        noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("notify.folder-done", { label = f.label }))
      elseif f.state == "error" and prev.state ~= "error" then
        noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("notify.folder-error", { label = f.label }))
      end
    end
  end

  local oldDevices = {}
  for _, d in old.devicesList do
    oldDevices[d.id] = d
  end
  for _, d in new.devicesList do
    local prev = oldDevices[d.id]
    if prev and prev.connected ~= d.connected then
      local key = d.connected and "notify.device-connected" or "notify.device-disconnected"
      noctalia.notify(noctalia.tr("toast.title"), noctalia.tr(key, { name = d.name }))
    end
  end
end

local function publish(snapshot)
  busy = false
  notifyTransitions(prevSnapshot, snapshot)
  prevSnapshot = snapshot
  local encoded = noctalia.json.encode(snapshot)
  if encoded then
    noctalia.state.set("st.snapshot", encoded)
  end
  if pendingPoll then
    pendingPoll = false
    poll(true)
  end
end

local function summarizeFolder(folder, status)
  local rawState = trim(status.state or "unknown")
  if rawState == "" then rawState = "unknown" end
  local needItems = tonumber(status.needTotalItems) or 0
  local needBytes = tonumber(status.needBytes) or 0
  local globalBytes = tonumber(status.globalBytes) or 0
  local pullErrors = tonumber(status.pullErrors) or 0
  local errorCount = tonumber(status.errors) or 0
  local watchError = trim(status.watchError)
  local hardError = trim(status.error)

  local state
  if folder.paused then
    state = "paused"
  elseif hardError ~= "" or watchError ~= "" or pullErrors > 0 or errorCount > 0 then
    state = "error"
  elseif ACTIVE_FOLDER_STATES[rawState] or needItems > 0 or needBytes > 0 then
    state = "syncing"
  else
    state = "idle"
  end

  return {
    id = folder.id,
    label = folder.label,
    paused = folder.paused == true,
    state = state,
    rawState = rawState,
    needItems = needItems,
    needBytes = needBytes,
    globalBytes = globalBytes,
    -- Sync completion in percent, derived from db/status byte counters.
    completion = globalBytes > 0 and math.floor(100 * (globalBytes - needBytes) / globalBytes) or 100,
    lastActivity = folder.lastActivity or "",
    detail = watchError ~= "" and watchError or hardError,
  }
end

local function classify(snapshot)
  local totals = snapshot.totals
  local devices = snapshot.devices

  if #snapshot.folders == 0 then
    snapshot.state = "unconfigured"
    if snapshot.detail == "" then
      snapshot.detail = "no-folders"
    end
  elseif totals.pausedFolders == totals.monitoredFolders then
    snapshot.state = "paused"
  elseif totals.erroredFolders > 0 then
    snapshot.state = "error"
  elseif totals.syncingFolders > 0 or totals.needItems > 0 or totals.needBytes > 0 then
    snapshot.state = "syncing"
  elseif devices.configured > 0 and devices.connected == 0 and devices.paused < devices.configured then
    snapshot.state = "disconnected"
  else
    snapshot.state = "idle"
  end
  return snapshot
end

-- Third stage: per-folder db status, joined, then classify + publish.
local function fetchFolderStatuses(snapshot, monitoredFolders)
  local remaining = 0
  local summaries = {}

  local function finalize()
    for _, s in summaries do
      table.insert(snapshot.folders, s)
      local t = snapshot.totals
      t.monitoredFolders += 1
      if s.state == "paused" then t.pausedFolders += 1 end
      if s.state == "syncing" then t.syncingFolders += 1 end
      if s.state == "error" then t.erroredFolders += 1 end
      t.needItems += s.needItems
      t.needBytes += s.needBytes
    end
    if #snapshot.recentErrors > 0 and snapshot.totals.erroredFolders == 0 and snapshot.detail == "" then
      snapshot.detail = snapshot.recentErrors[1].message
    end
    -- Overall completion while syncing, weighted by bytes.
    if snapshot.totals.syncingFolders > 0 then
      local globalB, needB = 0, 0
      for _, s in snapshot.folders do
        globalB += s.globalBytes
        needB += s.needBytes
      end
      if globalB > 0 then
        snapshot.syncPercent = math.floor(100 * (globalB - needB) / globalB)
      end
    end
    publish(classify(snapshot))
  end

  for index, folder in monitoredFolders do
    if folder.paused then
      summaries[index] = summarizeFolder(folder, { state = "paused" })
    else
      remaining += 1
    end
  end
  if remaining == 0 then
    finalize()
    return
  end

  for index, folder in monitoredFolders do
    if folder.paused then
      continue
    end
    fetch(`/rest/db/status?folder={noctalia.string.urlEncode(folder.id)}`, {}, function(ok, status, body)
      local parsed = ok and status < 400 and noctalia.json.decode(body) or nil
      summaries[index] = summarizeFolder(folder, parsed or { state = "error", error = `folder status HTTP {status}` })
      remaining -= 1
      if remaining == 0 then
        finalize()
      end
    end)
  end
end

-- Second stage: the four core endpoints in parallel, joined.
local function fetchCore()
  local endpoints = {
    system = "/rest/system/status",
    config = "/rest/config",
    connections = "/rest/system/connections",
    errors = "/rest/system/error",
    fstats = "/rest/stats/folder",
  }
  local results = {}
  local remaining = 0
  local failedStatus = nil

  for key in endpoints do
    remaining += 1
  end

  local function done()
    if failedStatus then
      if failedStatus == 401 or failedStatus == 403 then
        publish(emptySnapshot("unauthorized"))
      elseif failedStatus == 0 then
        publish(emptySnapshot("offline"))
      else
        publish(emptySnapshot("error", `HTTP {failedStatus}`))
      end
      return
    end

    local snapshot = emptySnapshot("unknown")

    -- Transfer rates from the delta of total in/out bytes between two polls.
    local totals = (results.connections or {}).total or {}
    local nowClock = os.clock()
    local inB = tonumber(totals.inBytesTotal) or 0
    local outB = tonumber(totals.outBytesTotal) or 0
    if lastTotals and nowClock > lastTotals.t and inB >= lastTotals.inB then
      local dt = nowClock - lastTotals.t
      snapshot.rateIn = math.max(0, (inB - lastTotals.inB) / dt)
      snapshot.rateOut = math.max(0, (outB - lastTotals.outB) / dt)
    end
    lastTotals = { inB = inB, outB = outB, t = nowClock }

    -- Devices: remote only, split by connection state, plus the full list for
    -- the panel's Devices tab.
    local myID = trim(results.system.myID)
    local connMap = (results.connections or {}).connections or {}
    for _, device in (results.config.devices or {}) do
      local id = trim(device.deviceID)
      if id ~= "" and id ~= myID then
        snapshot.devices.configured += 1
        local info = connMap[id] or {}
        local paused = device.paused == true or info.paused == true
        if info.paused then
          snapshot.devices.paused += 1
        elseif info.connected then
          snapshot.devices.connected += 1
        end
        table.insert(snapshot.devicesList, {
          name = trim(device.name) ~= "" and trim(device.name) or id:sub(1, 7),
          id = id,
          shortId = id:sub(1, 7),
          paused = paused,
          connected = info.connected == true,
          address = trim(info.address),
          version = trim(info.clientVersion),
        })
      end
    end
    table.sort(snapshot.devicesList, function(a, b)
      if a.connected ~= b.connected then
        return a.connected
      end
      return a.name:lower() < b.name:lower()
    end)

    -- Recent errors (last 5).
    for _, item in ((results.errors or {}).errors or {}) do
      local message = trim(item.message)
      if message ~= "" and #snapshot.recentErrors < 5 then
        table.insert(snapshot.recentErrors, { when = trim(item.when), message = message })
      end
    end

    -- Folder list from config, filtered by the monitored set.
    local monitoredFolders = {}
    for _, folder in (results.config.folders or {}) do
      local id = trim(folder.id)
      if id == "" then
        continue
      end
      if cfg.monitoredCount > 0 and not cfg.monitored[id] then
        continue
      end
      -- Last activity from folder stats: prefer the last synced file's
      -- timestamp, fall back to the last scan (skip Go zero dates).
      local fs = (results.fstats or {})[id]
      local lastActivity = ""
      if fs then
        local at = trim((fs.lastFile or {}).at)
        if at == "" or at:sub(1, 4) == "0001" then
          at = trim(fs.lastScan)
        end
        if at ~= "" and at:sub(1, 4) ~= "0001" then
          lastActivity = at:sub(1, 16):gsub("T", " ")
        end
      end
      table.insert(monitoredFolders, {
        id = id,
        label = trim(folder.label) ~= "" and trim(folder.label) or id,
        paused = folder.paused == true,
        lastActivity = lastActivity,
      })
    end
    table.sort(monitoredFolders, function(a, b)
      return a.label:lower() < b.label:lower()
    end)

    fetchFolderStatuses(snapshot, monitoredFolders)
  end

  for key, path in endpoints do
    fetch(path, {}, function(ok, status, body)
      local parsed = ok and status < 400 and noctalia.json.decode(body) or nil
      if parsed then
        results[key] = parsed
      elseif not failedStatus then
        failedStatus = ok and status or 0
      end
      remaining -= 1
      if remaining == 0 then
        done()
      end
    end)
  end
end

function poll(force)
  if busy then
    pendingPoll = true
    return
  end
  busy = true
  resolveConfig()

  if cfg.baseUrl == "" then
    publish(emptySnapshot("unconfigured", "no-url"))
    return
  end

  fetch("/rest/noauth/health", { noauth = true }, function(ok, status)
    if not ok then
      publish(emptySnapshot("offline"))
      return
    end
    if status >= 400 and status ~= 404 then
      publish(emptySnapshot("offline", `HTTP {status}`))
      return
    end
    if cfg.apiKey == "" then
      publish(emptySnapshot("unconfigured", "no-api-key"))
      return
    end
    fetchCore()
  end)
end

-- ── Commands from UI entries ─────────────────────────────────────────────────

-- An action fires its request, then forces a fresh poll so the UI catches up.
local function actionThenRefresh(path, opts)
  fetch(path, opts, function()
    poll(true)
  end)
end

function openGui()
  noctalia.log(`[syncthing] openGui: url={cfg.baseUrl}`)
  if cfg.baseUrl == "" then
    noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("detail.no-url"))
    return
  end
  -- gio, not xdg-open: with XDG_CURRENT_DESKTOP=KDE (set for Qt theming under
  -- niri) but no KDE session, xdg-open takes the kfmclient path and no-ops
  -- with exit 0. gio resolves the x-scheme-handler/http default directly.
  noctalia.runAsync(`gio open "{cfg.baseUrl}" || xdg-open "{cfg.baseUrl}"`, function(result)
    noctalia.log(`[syncthing] openGui exit={result.exitCode} err={result.stderr}`)
    if result.exitCode ~= 0 then
      noctalia.notifyError(noctalia.tr("toast.title"), `open failed: {noctalia.string.trim(result.stderr)}`)
    end
  end, 10000)
end

noctalia.state.watch("st.cmd", function(raw)
  local cmd = raw and noctalia.json.decode(raw) or nil
  if not cmd or not cmd.action then
    return
  end
  local folder = cmd.folder and noctalia.string.urlEncode(cmd.folder) or ""

  if cmd.action == "refresh" then
    poll(true)
  elseif cmd.action == "pause_all" then
    actionThenRefresh("/rest/system/pause", { method = "POST" })
  elseif cmd.action == "resume_all" then
    actionThenRefresh("/rest/system/resume", { method = "POST" })
  elseif cmd.action == "folder_pause" then
    actionThenRefresh(`/rest/config/folders/{folder}`, { method = "PATCH", body = '{"paused":true}' })
  elseif cmd.action == "folder_resume" then
    actionThenRefresh(`/rest/config/folders/{folder}`, { method = "PATCH", body = '{"paused":false}' })
  elseif cmd.action == "device_pause" then
    actionThenRefresh(`/rest/config/devices/{folder}`, { method = "PATCH", body = '{"paused":true}' })
  elseif cmd.action == "device_resume" then
    actionThenRefresh(`/rest/config/devices/{folder}`, { method = "PATCH", body = '{"paused":false}' })
  elseif cmd.action == "rescan" then
    actionThenRefresh(`/rest/db/scan?folder={folder}`, { method = "POST" })
  elseif cmd.action == "open_gui" then
    openGui()
  else
    noctalia.log(`[syncthing] unknown command: {cmd.action}`)
  end
end)

function onConfigChanged()
  poll(true)
end

function onIpc(event)
  if event == "refresh" then
    poll(true)
  elseif event == "open" then
    openGui()
  elseif event == "pause" then
    actionThenRefresh("/rest/system/pause", { method = "POST" })
  elseif event == "resume" then
    actionThenRefresh("/rest/system/resume", { method = "POST" })
  end
end

function update()
  noctalia.setUpdateInterval(cfg.pollMs)
  poll(false)
end

resolveConfig()
