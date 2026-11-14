--!nonstrict
-- LogonBox service - the only entry that runs processes, reads files and publishes.
--
--   noctalia.state.set("logonbox.state", snapshot)     bar and panel render this
--   noctalia.state.watch("logonbox.request", handler)  actions from bar/panel
--   noctalia msg plugin 3dprogramin/logonbox:service all request '<json>'   same, over IPC
--
-- State comes from one coalesced refresh pass (only one runs at a time; triggers
-- during a pass run one more pass after it):
--   1. `gdbus call ... NameHasOwner com.logonbox.vpn`: false means the service is
--      down and nothing else runs; no answer (gdbus missing or failed) goes on.
--   2. `logonbox-vpn-cli show .*` (one JVM start, ~1.6 s CPU in the CLI, not here).
--      Output that does not parse keeps the previous connections (error.read).
--      An empty list right after a non-empty one is read once more before it is
--      believed, so a glitch never reads as "no connections, sign in".
--   3. Finished inFlight entries and row errors are cleared, then one publish.
-- Passes run at start, on {action="refresh"}, after every action, on each stream
-- `refresh` event, and on a 60 s poll. The CLI is looked up again on every pass, so
-- installing the client later is picked up.
--
-- `gdbus monitor --system --dest com.logonbox.vpn` (runStream) gives instant
-- updates: Connecting/Disconnecting set the row's in-between state at once, every
-- other LogonBox signal triggers a pass. runStream has no exit callback, so each
-- poll asks processMatches whether it still runs and restarts it if not.
--
-- One action (connect/disconnect) at a time: another one while busy is refused with
-- error.busy. refresh, dismiss_error and the detached launches (open_gui,
-- open_download) run any time. A watchdog clears busy if the action's callback
-- never arrives. `requestSeq` goes up by one when a request has been fully handled;
-- `serviceBootId` is unique per service start (a hot reload resets requestSeq).
--
-- inFlight: an entry the plugin's own action set is settled by the action. One set
-- by the stream (a connect started in the LogonBox app) is settled by the first
-- read that started after it: CONNECTING/DISCONNECTING keep it, anything else
-- clears it, so a failed outside connect never pins the tile on "…".
-- Row errors: a connect error stays until the user acts on that row again or the
-- row reads CONNECTED; a disconnect error until the next action or DISCONNECTED.
--
-- Privacy: hosts, accounts, DNS and raw CLI output never reach noctalia.log or a
-- notification. Row error details are parse.scrubDetail()ed (no URL, e-mail, host
-- or IP). Logs carry translation keys only.
--
-- Files in <pluginDataDir>:
--   simulate    (read on every pass) a mode name that replaces the real state with
--               fake data, for live checks and screenshots; actions are refused.
--   debug       marker: while it exists every publish also writes state.json, a
--               copy of the snapshot without host, account and DNS.
-- Outside the data dir only the kernel check reads: /proc/sys/kernel/osrelease,
-- /sys/module/wireguard and /usr/lib/modules/<release>/ (after a failed connect,
-- and on each pass while "reboot needed" is shown).

local parse = require("./parse.luau")
local model = require("./model.luau")
local commands = require("./commands.luau")

local TICK_MS = 1000
local POLL_TICKS = 60
-- A callback that never arrives must not wedge the service: busy is cleared this
-- long after the action's own timeout.
local WATCHDOG_SLACK_MS = 5000
-- A pass older than this (a lost callback) no longer blocks a new one.
local REFRESH_STALE_MS = 120000
-- A stream started this recently may not be visible in the process list yet.
local STREAM_SETTLE_MS = 5000
-- Minimum gap between passes the stream triggers; a held trigger runs once it has passed.
local STREAM_GAP_MS = 2000
local STATE_KEY = "logonbox.state"
local REQUEST_KEY = "logonbox.request"
local CLI_NAME = "logonbox-vpn-cli"
local GUI_NAME = "logonbox-vpn-gui"
local OPT_DIR = "/opt/logonbox-vpn-client/"
local OSRELEASE = "/proc/sys/kernel/osrelease"
local WG_LOADED = "/sys/module/wireguard"
local DEBUG_MARKER = "debug"
local DEBUG_FILE = "state.json"
local SIMULATE_FILE = "simulate"
local TIMEOUT_KEYS = { connect = "error.connect_timeout", disconnect = "error.disconnect_timeout" }
local LAUNCH_FAILED_KEYS = { open_gui = "error.open_gui_failed", open_download = "error.open_download_failed" }

-- Fake data for simulate=multi: a copy of tests/fixtures/show-multi.txt.
local SIM_MULTI = [[
Basic
 Connection: 0
 Name: 
 Uri: https://user%40example.com@vpn.example.com:8443/app
 Status: CONNECTED
 Mode: CLIENT
 Transient: No
 Authorized: Yes
 Shared: No
 Connect At Startup: No
 Stay Connected: Yes
 Owner: user
VPN
 Interface: wg0
 Address: 10.99.0.2
 Endpoint: vpn.example.com:51820
 DNS: 198.51.100.2,198.51.100.3
 Allowed IPs: 192.0.2.2/24,192.0.2.3/16
 Route All: No
 MTU: 0
 Persistent Keep Alive: 30

Basic
 Connection: 1
 Name: Lab
 Uri: https://user%40example.com@vpn2.example.org/app
 Status: DISCONNECTED
 Mode: CLIENT
 Transient: No
 Authorized: Yes
 Shared: No
 Connect At Startup: No
 Stay Connected: Yes
 Owner: user
VPN
 Interface: 
 Address: 10.99.0.3
 Endpoint: vpn2.example.org:51820
 DNS: 
 Allowed IPs: 192.0.2.2/24,192.0.2.3/16
 Route All: No
 MTU: 0
 Persistent Keep Alive: 30

Basic
 Connection: 2
 Name: Branch
 Uri: https://vpn2.example.org:8443/app
 Status: DISCONNECTED
 Mode: CLIENT
 Transient: No
 Authorized: No
 Shared: No
 Connect At Startup: No
 Stay Connected: Yes
 Owner: user
VPN
 Interface: 
 Address: 10.99.0.4
 Endpoint: https://vpn2.example.org:8443/app
 DNS: 
 Allowed IPs: 192.0.2.2/24,192.0.2.3/16
 Route All: No
 MTU: 0
 Persistent Keep Alive: 30

]]

-- ── state ────────────────────────────────────────────────────────────────────

local cli = nil -- the CLI path, or nil when not installed
local installed = true
local service = "unknown" -- "running" | "down" | "unknown"
local connections = {} -- the last good read; replaced, never changed in place
local lastGoodCount = 0
local inFlight = {} -- [id] = "connecting" | "disconnecting"
local inFlightMark = {} -- [id] = readCount when set; only a later read settles it
local inFlightOwned = {} -- [id] = true while the plugin's own action on the row runs
local rowErrors = {} -- [id] = { key, detail? }
local rowErrorFrom = {} -- [id] = "connect" | "disconnect"
local rebootNeeded = false
local kernelRelease = nil
local lastError = nil
local simulate = nil -- the active simulate mode
local simState = nil -- its fake fields
local simWarned = false
local seq = 0
local requestSeq = 0
-- Start time + a random part + a table address: unique even for two loads in one ms.
local serviceBootId = tostring(noctalia.nowMs()) .. "-" .. tostring(math.random(0, 16777215)) .. "-" .. (tostring({}):gsub("[^%w]", ""))

local busy = false
local busyAction = nil -- "connect" | "disconnect"
local busyRow = nil -- id string
local busyDeadlineMs = nil
local actionId = 0 -- bumped per action; a late callback of an older one is ignored

local streamStarted = false
local streamStartedAtMs = nil
local ticks = 0
local readCount = 0 -- bumped as each `show` starts

-- ── helpers ──────────────────────────────────────────────────────────────────

local function dataFile(name)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/" .. name
end

local function trim(text)
  return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

-- Only fixed text and translation keys are logged, never CLI output.
local function log(message)
  noctalia.log("logonbox: " .. message)
end

-- runAsync returns false and never calls back when the process cannot start.
local function run(argv, timeoutMs, onResult)
  if noctalia.runAsync(argv, onResult, timeoutMs) == false then
    onResult({
      exitCode = 127, stdout = "", stderr = "", timedOut = false,
      stdoutTruncated = false, stderrTruncated = false,
    })
  end
end

local function copyMap(map)
  local out = {}
  for k, v in pairs(map) do
    out[k] = v
  end
  return out
end

local function errorText(err)
  if err.detail ~= nil then
    return noctalia.tr(err.key, { detail = err.detail })
  end
  return noctalia.tr(err.key)
end

local function findTool(name)
  if noctalia.commandExists(name) then
    return name
  end
  local path = OPT_DIR .. name
  if noctalia.fileExists(path) then
    return path
  end
  return nil
end

local function findRow(id)
  for _, c in ipairs(connections) do
    if c.id == id then
      return c
    end
  end
  return nil
end

local function setRowError(key, err, from)
  rowErrors[key] = err
  rowErrorFrom[key] = err and from or nil
end

local function clearInFlight(key)
  inFlight[key] = nil
  inFlightMark[key] = nil
  inFlightOwned[key] = nil
end

-- ── simulate ─────────────────────────────────────────────────────────────────

local function simConnection(authorized)
  return {
    id = 0, name = "", host = "vpn.example.com", account = "user@example.com",
    status = "DISCONNECTED", authorized = authorized, dns = {},
  }
end

local SIM_MODES = {
  not_installed = function()
    return { installed = false, service = "unknown", connections = {} }
  end,
  service_down = function()
    return { installed = true, service = "down", connections = {} }
  end,
  no_connections = function()
    return { installed = true, service = "running", connections = {} }
  end,
  needs_signin = function()
    return { installed = true, service = "running", connections = { simConnection(false) } }
  end,
  reboot_needed = function()
    return {
      installed = true, service = "running", connections = { simConnection(true) },
      rebootNeeded = true, rowErrors = { ["0"] = { key = "error.reboot_needed" } },
    }
  end,
  multi = function()
    return { installed = true, service = "running", connections = parse.show(SIM_MULTI) or {} }
  end,
}

local function readSimulate()
  local path = dataFile(SIMULATE_FILE)
  if path == nil or noctalia.fileExists(path) ~= true then
    return nil
  end
  local mode = trim(noctalia.readFile(path))
  if SIM_MODES[mode] == nil then
    if not simWarned then
      simWarned = true
      log("simulate file holds no known mode; ignored")
    end
    return nil
  end
  return mode
end

-- ── publish ──────────────────────────────────────────────────────────────────

-- The debug copy keeps only what a live check needs: no host, account or DNS values
-- (dnsCount is a number, so a check can prove the DNS list was parsed).
local function debugCopy(snap)
  local out = copyMap(snap)
  local rows = {}
  for i, c in ipairs(snap.connections) do
    rows[i] = { id = c.id, name = c.name, status = c.status, authorized = c.authorized, dnsCount = #(c.dns or {}) }
  end
  out.connections = rows
  return out
end

local function publish()
  seq = seq + 1
  local snap = {
    seq = seq,
    requestSeq = requestSeq,
    serviceBootId = serviceBootId,
    installed = installed,
    service = service,
    connections = connections,
    inFlight = copyMap(inFlight),
    rowErrors = copyMap(rowErrors),
    rebootNeeded = rebootNeeded,
    busy = busy,
    lastError = lastError,
    simulate = simulate,
  }
  if simState ~= nil then
    snap.installed = simState.installed
    snap.service = simState.service
    snap.connections = simState.connections
    snap.inFlight = {}
    snap.rowErrors = simState.rowErrors or {}
    snap.rebootNeeded = simState.rebootNeeded == true
  end
  noctalia.state.set(STATE_KEY, snap)
  -- One stat per publish; checking every time means no write follows the marker's removal.
  local marker = dataFile(DEBUG_MARKER)
  local path = dataFile(DEBUG_FILE)
  if marker ~= nil and path ~= nil and noctalia.fileExists(marker) == true then
    local encoded = noctalia.json.encode(debugCopy(snap), true)
    if encoded ~= nil then
      noctalia.writeFile(path, encoded)
    end
  end
end

-- ── kernel check (spec §7.3) ─────────────────────────────────────────────────

-- File tests only; nil while the running kernel's release is unknown.
local function kernelFacts()
  if kernelRelease == nil then
    return nil
  end
  local base = "/usr/lib/modules/" .. kernelRelease
  return {
    wgLoaded = noctalia.fileExists(WG_LOADED) == true,
    moduleDirExists = noctalia.fileExists(base) == true,
    wgModuleFiles = noctalia.listDir(base .. "/kernel/drivers/net/wireguard") or {},
  }
end

-- done(needed). The release is read once (it cannot change without a reboot); an
-- unknown release never claims a reboot.
local function checkKernel(done)
  local function decide()
    local facts = kernelFacts()
    done(facts ~= nil and model.rebootNeeded(facts))
  end
  if kernelRelease ~= nil then
    return decide()
  end
  local started = noctalia.readFileAsync(OSRELEASE, function(text)
    local release = trim(text)
    if release ~= "" then
      kernelRelease = release
    end
    decide()
  end)
  if started ~= true then
    decide()
  end
end

-- While "reboot needed" is shown, every pass re-checks it and clears it (and the
-- row errors that say it) once WireGuard can be used.
local function clearRebootErrors()
  for key, err in pairs(copyMap(rowErrors)) do
    if err.key == "error.reboot_needed" then
      setRowError(key, nil)
    end
  end
end

local function recheckReboot()
  if not rebootNeeded then
    return
  end
  local facts = kernelFacts()
  if facts == nil or model.rebootNeeded(facts) then
    return
  end
  rebootNeeded = false
  clearRebootErrors()
end

-- ── stream ───────────────────────────────────────────────────────────────────

local refresh -- forward
local streamRefresh -- forward
local lastStreamPassMs = nil
local streamPending = false

local function onStreamLine(line)
  local ok, event = pcall(parse.monitorLine, line)
  if not ok or event == nil then
    return
  end
  if event.kind == "transition" then
    local key = tostring(event.id)
    inFlight[key] = event.to
    inFlightMark[key] = readCount
    publish()
  elseif event.kind == "refresh" then
    streamRefresh()
  end
end

local function ensureStream()
  if streamStarted or service == "down" then
    return
  end
  streamStarted = noctalia.runStream(commands.MONITOR_CMD, onStreamLine) == true
  streamStartedAtMs = noctalia.nowMs()
end

-- The stream dies silently (the service restarted, gdbus was killed). Each poll asks
-- the host whether the process is still there and restarts it if not.
local function checkStream()
  if not streamStarted then
    return
  end
  if streamStartedAtMs ~= nil and noctalia.nowMs() - streamStartedAtMs < STREAM_SETTLE_MS then
    return
  end
  noctalia.processMatches(function(running)
    if not running and streamStarted then
      log("monitor stream is gone; restarting it")
      streamStarted = false
      ensureStream()
    end
  end, commands.MONITOR_CMD)
end

-- ── refresh ──────────────────────────────────────────────────────────────────

local function markDown()
  service = "down"
  connections = {}
  for key in pairs(inFlight) do
    if not inFlightOwned[key] then
      clearInFlight(key)
    end
  end
  if lastError ~= nil and lastError.key == "error.read" then
    lastError = nil
  end
end

-- After a good read (number readNo): settle inFlight and row errors.
local function settleRows(readNo)
  local present = {}
  for _, c in ipairs(connections) do
    present[tostring(c.id)] = c
  end
  for key, flight in pairs(copyMap(inFlight)) do
    local c = present[key]
    if c == nil then
      clearInFlight(key)
    elseif (flight == "connecting" and c.status == "CONNECTED")
      or (flight == "disconnecting" and c.status == "DISCONNECTED") then
      clearInFlight(key)
    elseif not inFlightOwned[key] and readNo > (inFlightMark[key] or 0)
      and c.status ~= "CONNECTING" and c.status ~= "DISCONNECTING" then
      clearInFlight(key)
    end
  end
  for key in pairs(copyMap(rowErrors)) do
    local c = present[key]
    local from = rowErrorFrom[key]
    if c == nil
      or (from == "connect" and c.status == "CONNECTED")
      or (from == "disconnect" and c.status == "DISCONNECTED") then
      setRowError(key, nil)
    end
  end
end

local refreshingSinceMs = nil
local passId = 0
local again = false
local pendingAfters = {}

local startPass -- forward

local function endPass(id, afters)
  if id ~= passId then
    return
  end
  refreshingSinceMs = nil
  recheckReboot()
  for _, fn in ipairs(afters) do
    fn()
  end
  publish()
  if again then
    again = false
    local nextAfters = pendingAfters
    pendingAfters = {}
    startPass(nextAfters)
  end
end

local function readShow(id, afters, owner, retried)
  readCount = readCount + 1
  local readNo = readCount
  run(commands.show(cli), commands.READ_TIMEOUT_MS, function(result)
    if id ~= passId then
      return
    end
    if result.timedOut or result.exitCode ~= 0 then
      if owner == nil and not result.timedOut then
        markDown()
      else
        lastError = { key = "error.read" }
        log("show failed; keeping the last connections")
      end
      return endPass(id, afters)
    end
    local list = parse.show(result.stdout)
    if list == nil then
      lastError = { key = "error.read" }
      log("show output not understood; keeping the last connections")
      return endPass(id, afters)
    end
    if #list == 0 and lastGoodCount > 0 and not retried then
      return readShow(id, afters, owner, true)
    end
    local wasDown = service == "down"
    service = "running"
    connections = list
    lastGoodCount = #list
    if lastError ~= nil and lastError.key == "error.read" then
      lastError = nil
    end
    settleRows(readNo)
    local hadStream = streamStarted
    ensureStream()
    if wasDown and hadStream then
      -- The service is back: check the stream it had now, not at the next poll. A
      -- stream ensureStream() just started keeps its settle time (it may not be in
      -- the process list yet, and checking it would start a second one).
      streamStartedAtMs = nil
      checkStream()
    end
    endPass(id, afters)
  end)
end

startPass = function(afters)
  passId = passId + 1
  local id = passId
  refreshingSinceMs = noctalia.nowMs()
  -- Every pass restarts the poll count, so no poll follows right after an action's re-read.
  ticks = 0
  cli = findTool(CLI_NAME)
  installed = cli ~= nil
  simulate = readSimulate()
  if simulate ~= nil then
    simState = SIM_MODES[simulate]()
    return endPass(id, afters)
  end
  simState = nil
  if not installed then
    service = "unknown"
    connections = {}
    for key in pairs(copyMap(inFlight)) do
      clearInFlight(key)
    end
    return endPass(id, afters)
  end
  run(commands.NAME_OWNER_ARGV, commands.READ_TIMEOUT_MS, function(result)
    if id ~= passId then
      return
    end
    local owner = nil
    if result.exitCode == 0 and not result.timedOut then
      owner = parse.nameOwner(result.stdout)
    end
    if owner == false then
      markDown()
      return endPass(id, afters)
    end
    readShow(id, afters, owner, false)
  end)
end

-- after(), when given, runs just before the publish of a pass that started after
-- the call, so what it changes is published with freshly read state.
refresh = function(after)
  if refreshingSinceMs ~= nil and noctalia.nowMs() - refreshingSinceMs < REFRESH_STALE_MS then
    again = true
    if after ~= nil then
      pendingAfters[#pendingAfters + 1] = after
    end
    return
  end
  startPass(after and { after } or {})
end

-- Stream signals come in bursts (one per connection event): at most one pass per
-- STREAM_GAP_MS, and the last trigger is never dropped (update() runs the held one).
streamRefresh = function()
  local now = noctalia.nowMs()
  if lastStreamPassMs ~= nil and now - lastStreamPassMs < STREAM_GAP_MS then
    streamPending = true
    return
  end
  streamPending = false
  lastStreamPassMs = now
  refresh()
end

-- ── actions ──────────────────────────────────────────────────────────────────

local function handled()
  requestSeq = requestSeq + 1
end

local function refuse(err)
  lastError = err
  handled()
  publish()
end

local function finishAction(id, err)
  if id ~= actionId then
    return
  end
  local key, kind = busyRow, busyAction
  busy = false
  busyAction = nil
  busyRow = nil
  busyDeadlineMs = nil
  inFlightOwned[key] = nil
  if err ~= nil then
    clearInFlight(key)
    setRowError(key, err, kind)
    log(kind .. " failed: " .. err.key)
    -- Spec §7.4 (R9): a notification on connect failure only.
    if kind == "connect" then
      noctalia.notifyError(noctalia.tr("notify.connect_failed"), errorText(err))
    end
  else
    -- The re-read below settles the entry.
    inFlightMark[key] = readCount
  end
  refresh(handled)
end

local function rowAction(request, kind)
  if simulate ~= nil then
    return refuse({ key = "error.simulated" })
  end
  local id = cli and commands.validId(request.id, connections) or nil
  if id == nil then
    return refuse({ key = "error.invalid_id" })
  end
  local key = tostring(id)
  local row = findRow(id)
  if kind == "connect" and (row.authorized == false or row.status == "AUTHORIZING") then
    -- connect would start a device sign-in that waits for input (§5.3).
    -- The row says it; an unrelated global error stays.
    setRowError(key, { key = "error.needs_signin" }, "connect")
    handled()
    publish()
    return
  end

  actionId = actionId + 1
  local aid = actionId
  local timeoutMs = kind == "connect" and commands.CONNECT_TIMEOUT_MS or commands.DISCONNECT_TIMEOUT_MS
  busy = true
  busyAction = kind
  busyRow = key
  busyDeadlineMs = noctalia.nowMs() + timeoutMs + WATCHDOG_SLACK_MS
  lastError = nil
  setRowError(key, nil)
  inFlight[key] = kind == "connect" and "connecting" or "disconnecting"
  inFlightMark[key] = readCount
  inFlightOwned[key] = true
  publish()

  local argv = kind == "connect" and commands.connect(cli, id) or commands.disconnect(cli, id)
  run(argv, timeoutMs, function(result)
    if aid ~= actionId then
      return
    end
    local outcome
    if kind == "connect" then
      outcome = parse.connectOutcome(result)
    else
      outcome = parse.disconnectOutcome(result)
    end
    if outcome.ok then
      return finishAction(aid, nil)
    end
    outcome.detail = parse.scrubDetail(outcome.detail)
    if kind == "disconnect" then
      return finishAction(aid, model.disconnectError(outcome))
    end
    checkKernel(function(needed)
      if aid ~= actionId then
        return
      end
      rebootNeeded = needed
      if not needed then
        clearRebootErrors()
      end
      finishAction(aid, model.connectError(outcome, needed))
    end)
  end)
end

-- Starts a program without waiting for it. It touches no VPN state, so it runs
-- any time (busy, simulating, not installed) and nothing is re-read.
local function launchDetached(request)
  local argv = nil
  if request.action == "open_gui" then
    local gui = findTool(GUI_NAME)
    argv = gui and commands.openGui(gui) or nil
  else
    argv = commands.openDownload()
  end
  local failKey = LAUNCH_FAILED_KEYS[request.action]
  if argv == nil or noctalia.runAsync(argv) == false then
    lastError = { key = failKey }
    log(failKey)
  elseif lastError ~= nil and lastError.key == failKey then
    lastError = nil
  end
  handled()
  publish()
end

local function handleRequest(request)
  if type(request) ~= "table" then
    return
  end
  local action = request.action
  if action == "dismiss_error" then
    -- Clears the error the user saw (no key: whatever is shown), never a newer one.
    if lastError ~= nil and (request.key == nil or request.key == lastError.key) then
      lastError = nil
    end
    handled()
    publish()
  elseif commands.detached(action) then
    launchDetached(request)
  elseif action == "refresh" then
    -- Exempt from error.busy: the bar and panel send it on load. While busy it only
    -- re-publishes; the action's own re-read follows when it ends.
    if busy then
      handled()
      publish()
    else
      refresh(handled)
    end
  elseif action == "connect" or action == "disconnect" then
    if busy then
      return refuse({ key = "error.busy" })
    end
    rowAction(request, action)
  else
    refuse({ key = "error.unknown_action" })
  end
end

noctalia.state.watch(REQUEST_KEY, handleRequest)

function onIpc(event, payload)
  if event ~= "request" or type(payload) ~= "string" then
    return
  end
  local ok, value = pcall(noctalia.json.decode, payload)
  if ok and type(value) == "table" then
    handleRequest(value)
  end
end

function update()
  if busy and busyDeadlineMs ~= nil and noctalia.nowMs() > busyDeadlineMs then
    actionId = actionId + 1 -- orphan the lost callback
    local key, kind = busyRow, busyAction
    busy = false
    busyAction = nil
    busyRow = nil
    busyDeadlineMs = nil
    clearInFlight(key)
    local err = { key = TIMEOUT_KEYS[kind] }
    setRowError(key, err, kind)
    log("action callback never arrived; busy cleared")
    if kind == "connect" then
      noctalia.notifyError(noctalia.tr("notify.connect_failed"), errorText(err))
    end
    refresh(handled)
  end
  if streamPending then
    streamRefresh()
  end
  ticks = ticks + 1
  if ticks >= POLL_TICKS and not busy then
    ticks = 0
    checkStream()
    refresh()
  end
end

noctalia.setUpdateInterval(TICK_MS)

log("service started")
publish()
refresh()
