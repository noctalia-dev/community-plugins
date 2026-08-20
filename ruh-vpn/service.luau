--!nonstrict
-- service.luau — headless supervisor for the Python VPN backend.
--
-- Responsibilities:
--   * Probe the backend HTTP control port. If a backend is already running
--     (e.g. the user's active proxy), ATTACH to it (poll only, never spawn a
--     duplicate). Otherwise SPAWN it via runStream and consume its stdout
--     event stream.
--   * Bridge: backend stdout events  → noctalia.state.set(...)
--             UI commands (state "cmd") → HTTP POST /rpc
--   * Poll GetStatus / GetHealth / GetTrafficStats on the update() tick, plus
--     GetLogs while attached (an attached backend sends us no events).
--
-- Cross-VM contract (all plain values through noctalia.state):
--   state "status"        : { running, activeServerId, mode, proxyMode, ... }
--   state "health"        : { latency_ms, jitter_ms, down_mbps, ... }
--   state "traffic"       : { bytes_sent, bytes_received, uptime_seconds, ... }
--   state "servers"       : [ { id, name, protocol, host, ... } ]
--   state "rules"         : [ ... ]
--   state "subscriptions" : [ ... ]
--   state "presets"       : [ { key, name, flag, enabled } ]
--   state "killswitch"    : { enabled, active }
--   state "logs"          : [ { level, message } ]  (ring, last 200)
--   state "backend"       : { ready, owns, error? }
--   state "cmd"           : { method, args, nonce }   (written by UI)
--   state "cmd_result"    : { nonce, method, result, error }

local PORT        = tonumber(noctalia.getConfig("control_port")) or 11090
local PY          = noctalia.getConfig("backend_python") or "python3"
local PROJDIR     = noctalia.pluginDir() or "."
local DATA_DIR    = noctalia.pluginDataDir() or noctalia.expandPath("~/.local/state/ruh-vpn")
local RUNTIME_DIR = DATA_DIR .. "/runtime"
local PIDFILE     = RUNTIME_DIR .. "/ruh-vpn-backend.pid"
local TOKENFILE   = RUNTIME_DIR .. "/ruh-vpn-control.token"
local BASE        = "http://127.0.0.1:" .. tostring(PORT)

local AUTO    = noctalia.getConfig("auto_start") == true
local GEOIP   = noctalia.getConfig("geoip_country") ~= false

local ownsBackend = false
local ready       = false
local autoStarted = false
local lastNonce   = nil
local failures    = 0     -- consecutive failed polls; 3 in a row = backend gone
local spawning    = false -- preflight or backend start in flight
local lastSpawnError = nil -- dedupes notifyError across spawn retries

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- ── control token ───────────────────────────────────────────────
-- The backend generates a per-launch token and writes it to TOKENFILE (0600)
-- once its port is bound; every /rpc call must present it. /healthz is open,
-- so the attach probe still works before the token is read.
local TOKEN = nil

local function readToken()
  local contents = noctalia.readFile(TOKENFILE)
  local t = contents and contents:match("%S+") or nil
  if t then TOKEN = t end
  return t ~= nil
end

-- ── RPC helper ──────────────────────────────────────────────────
local function rpc(method, args, cb)
  local headers = { "Content-Type: application/json" }
  if TOKEN then headers[#headers + 1] = "Authorization: Bearer " .. TOKEN end
  return noctalia.http({
    url     = BASE .. "/rpc",
    method  = "POST",
    headers = headers,
    body    = noctalia.json.encode({ method = method, args = args or {} }),
  }, function(resp)
    if not cb then return end
    if resp and resp.ok then
      local d = noctalia.json.decode(resp.body)
      if d then cb(d.result, d.error) else cb(nil, "bad json") end
    else
      cb(nil, resp and ("http " .. tostring(resp.status)) or "no response")
    end
  end)
end

-- ── list refreshers → state ─────────────────────────────────────
local function pub(key) return function(r) if r ~= nil then noctalia.state.set(key, r) end end end
local function refreshServers()  rpc("GetServers", {}, pub("servers")) end
local function refreshRules()    rpc("GetRoutingRules", {}, pub("rules")) end
local function refreshSubs()     rpc("GetSubscriptions", {}, pub("subscriptions")) end
local function refreshPresets()  rpc("GetPresets", {}, pub("presets")) end
local function refreshKill()     rpc("GetKillSwitchStatus", {}, pub("killswitch")) end

-- GetLogs returns preformatted lines ("<iso> [level] message"), while state
-- "logs" holds { level, message }. Split them so the panel can colour by level.
local function parseLogLine(line)
  local lvl, msg = tostring(line):match("^%S+%s+%[(%w+)%]%s+(.*)$")
  if not lvl then return { level = "info", message = tostring(line) } end
  return { level = lvl, message = msg }
end

-- Only the SPAWN path sees LogMessage events on stdout. When we attach to a
-- backend that outlived a previous shell there is no event stream at all, so
-- the logs view stayed empty; poll the backend's own ring buffer instead.
local function refreshLogs()
  rpc("GetLogs", {}, function(list)
    if type(list) ~= "table" then return end
    local logs = {}
    for _, line in ipairs(list) do logs[#logs + 1] = parseLogLine(line) end
    noctalia.state.set("logs", logs)
  end)
end

local function refreshLists()
  refreshServers(); refreshRules(); refreshSubs(); refreshPresets(); refreshKill(); refreshLogs()
end

-- auto-connect the active server once, if enabled and currently idle
local function maybeAutoStart()
  if not AUTO or autoStarted then return end
  autoStarted = true
  rpc("GetStatus", {}, function(st)
    if st and not st.running and st.activeServerId and st.activeServerId ~= "" then
      rpc("StartProxy", { st.activeServerId, st.mode or "rules", st.proxyMode or "system" })
    end
  end)
end

-- ── backend stdout event consumer ───────────────────────────────
local function onEvent(line)
  local ev = noctalia.json.decode(line)
  if type(ev) ~= "table" or ev.event == nil then return end
  local e = ev.event
  if e == "StatusChanged" then
    noctalia.state.set("status", ev.data or {})
  elseif e == "TrafficUpdate" then
    noctalia.state.set("traffic", ev.data or {})
  elseif e == "ServerListChanged" then
    refreshServers()
  elseif e == "LogMessage" then
    local logs = noctalia.state.get("logs") or {}
    table.insert(logs, ev.data or {})
    while #logs > 200 do table.remove(logs, 1) end
    noctalia.state.set("logs", logs)
  elseif e == "ready" then
    ready = true
    spawning = false
    failures = 0
    readToken() -- written before "ready" is emitted, so it is there by now
    noctalia.state.set("backend", { ready = true, owns = ownsBackend })
    refreshLists()
    maybeAutoStart()
  elseif e == "error" then
    spawning = false
    noctalia.state.set("backend", { ready = false, error = (ev.data and ev.data.message) or "error" })
  elseif e == "exit" then
    ready = false
    spawning = false
    noctalia.state.set("backend", { ready = false, owns = ownsBackend })
  end
end

-- ── spawn vs attach ─────────────────────────────────────────────
-- The backend needs third-party Python packages the plugin may not install
-- itself (community rules forbid fetching and running code automatically).
-- Probe the configured interpreter first, so a missing package surfaces as a
-- readable panel message instead of a stack trace in the event stream.
local function publishSpawnError(message)
  spawning = false
  noctalia.state.set("backend", { ready = false, error = message })
  if message ~= lastSpawnError then
    lastSpawnError = message
    noctalia.notifyError("Ruh VPN", message)
  end
end

local function doSpawn(py)
  ownsBackend = true
  local cmd = "cd " .. shellQuote(PROJDIR)
             .. " && RUH_VPN_CONTROL_PORT=" .. tostring(PORT)
             .. " RUH_VPN_GEOIP=" .. (GEOIP and "1" or "0")
             .. " RUH_VPN_DATA_DIR=" .. shellQuote(DATA_DIR)
             .. " RUH_VPN_RUNTIME_DIR=" .. shellQuote(RUNTIME_DIR)
             .. " exec " .. shellQuote(py) .. " -m backend.app"
  noctalia.runStream(cmd, onEvent)
end

local function spawnBackend()
  spawning = true
  local py = PY
  if py:sub(1, 1) == "~" then py = noctalia.expandPath(py) end
  local probe = "import importlib.util,sys;"
    .. "missing=[m for m in ('pydantic','aiofiles','aiohttp','aiohttp_socks') if importlib.util.find_spec(m) is None];"
    .. "print(','.join(missing));"
    .. "sys.exit(1 if missing else 0)"
  noctalia.runAsync(shellQuote(py) .. " -c " .. shellQuote(probe), function(res)
    if res.exitCode == 0 then
      lastSpawnError = nil
      doSpawn(py)
    elseif res.exitCode == 1 and res.stdout:match("%S") then
      local missing = res.stdout:match("%S+"):gsub(",", ", ")
      publishSpawnError("Python packages missing for " .. py .. ": " .. missing
        .. ". Install them and set backend_python (see README).")
    else
      publishSpawnError("Cannot run " .. py
        .. " (exit " .. tostring(res.exitCode) .. "). Check the backend_python setting.")
    end
  end, 30000)
end

local function attachOrSpawn()
  if spawning then return end
  noctalia.http({ url = BASE .. "/healthz" }, function(resp)
    if resp and resp.ok then
      -- Attach: a backend outlived a previous shell, and its proxy with it.
      ownsBackend = false
      ready = true
      failures = 0
      readToken() -- the running backend published its token at startup
      noctalia.state.set("backend", { ready = true, owns = false })
      refreshLists()
      maybeAutoStart()
    else
      spawnBackend()
    end
  end)
end

attachOrSpawn()

-- ── periodic polling ────────────────────────────────────────────
function update()
  if not ready then return end
  -- Watchdog. The probe above can attach to a backend that is already on its
  -- way out: reloading this file makes the old instance's onExit SIGTERM the
  -- backend while the new instance is probing, so /healthz answers once and
  -- then the process is gone. Without this the service stayed bound to a
  -- corpse forever, since attach-or-spawn only ran at startup.
  rpc("GetStatus", {}, function(st, err)
    if err then
      failures = failures + 1
      if failures >= 3 then
        failures = 0
        ready = false
        noctalia.state.set("backend", { ready = false, owns = ownsBackend })
        attachOrSpawn()
      end
      return
    end
    failures = 0
    if st ~= nil then noctalia.state.set("status", st) end
  end)
  rpc("GetHealth", {}, pub("health"))
  local st = noctalia.state.get("status")
  if st and st.running then
    rpc("GetTrafficStats", {}, pub("traffic"))
  end
  -- Attached: no stdout stream to feed logs, so keep pulling the ring buffer.
  -- When we own the backend, LogMessage events already deliver them live.
  if not ownsBackend then refreshLogs() end
end

-- ── UI command channel ──────────────────────────────────────────
noctalia.state.watch("cmd", function(c)
  if type(c) ~= "table" or c.nonce == nil or c.nonce == lastNonce then return end
  lastNonce = c.nonce
  local method = c.method
  rpc(method, c.args or {}, function(result, err)
    noctalia.state.set("cmd_result", { nonce = c.nonce, method = method, result = result, error = err })
    if err then noctalia.notifyError("VPN", tostring(err)) end
    if method == "RunSpeedTest" and result then noctalia.state.set("speedtest", result) end
    if method == "CheckDnsLeak" and result then noctalia.state.set("dnsleak", result) end
    if method == "ParseShareLink" and not err then refreshServers() end
    -- refresh affected lists after mutations
    if method == "AddServer" or method == "UpdateServer" or method == "RemoveServer" or method == "SwitchServer" then
      refreshServers()
    elseif method == "AddRoutingRule" or method == "RemoveRoutingRule" then
      refreshRules()
    elseif method == "TogglePreset" then
      refreshPresets()
    elseif method == "SetKillSwitch" then
      refreshKill()
    elseif method == "AddSubscription" or method == "RemoveSubscription" or method == "UpdateSubscription" then
      refreshSubs(); refreshServers()
    end
  end)
end)

-- ── settings changes ────────────────────────────────────────────
-- The interesting case: the user just pointed backend_python at an
-- interpreter that has the packages. Retry the spawn without a reload.
function onConfigChanged()
  PY    = noctalia.getConfig("backend_python") or "python3"
  AUTO  = noctalia.getConfig("auto_start") == true
  GEOIP = noctalia.getConfig("geoip_country") ~= false
  if not ready then attachOrSpawn() end
end

-- ── teardown: only kill the backend WE spawned ──────────────────
function onExit(sig)
  if ownsBackend then
    -- SIGTERM lets the backend tear down its proxy processes cleanly.
    -- The pidfile holds "<pid> <port>". Read and validate the first field
    -- before signalling it so the port can never be mistaken for a PID.
    local cmd = "if read pid rest < " .. shellQuote(PIDFILE)
                .. "; then case \"$pid\" in ''|*[!0-9]*) ;; *) kill \"$pid\" 2>/dev/null ;; esac; fi"
    noctalia.runAsync(cmd)
  end
end

noctalia.setUpdateInterval(2000)
