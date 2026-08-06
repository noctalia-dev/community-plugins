--!nonstrict
-- Tailscale backend: status, peers, exit nodes, preference toggles.

local STATE_KEY = "ts_snapshot"
local COMMAND_KEY = "ts_command"
local RESULT_KEY = "ts_action_result"

local MAX_PEERS = 200
local STUCK_SEC = 20

local snapshot = {
  available = false,
  loading = true,
  busy = false,
  installed = false,
  backendState = "",
  running = false,
  hostname = "",
  dnsName = "",
  ipv4 = "",
  ipv6 = "",
  tailnet = "",
  magicDNS = "",
  version = "",
  health = {},
  peers = {},
  exitNodes = {},
  onlineCount = 0,
  peerCount = 0,
  offlineCount = 0,
  exitNode = "",
  exitNodeOnline = false,
  shieldsUp = false,
  acceptRoutes = false,
  runSSH = false,
  acceptDNS = false,
  advertiseExitNode = false,
  exitNodeAllowLAN = false,
  operatorUser = "",
  error = "",
  updatedAt = 0,
  revision = 0,
}

local refreshGeneration = 0
local refreshPending = false
local refreshAgain = false
local refreshStartedAt = 0
local actionBusy = false
local dataSignature = ""
local prevOnline = {} -- id -> true

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

local function tsBin()
  local bin = trim(noctalia.getConfig("tailscale_bin"))
  if bin == "" then
    return "tailscale"
  end
  return bin
end

local function refreshIntervalMs()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 10
  seconds = math.max(3, math.min(120, math.floor(seconds)))
  return seconds * 1000
end

local function nowSec()
  if type(noctalia.nowMs) == "function" then
    local ms = noctalia.nowMs()
    if type(ms) == "number" and ms > 0 then
      return math.floor(ms / 1000)
    end
  end
  return os.time()
end

local function runTs(args, callback, timeoutMs)
  return noctalia.runAsync(shellCommand(args), callback, timeoutMs or 25000)
end

local function updateRevision(signature)
  if signature ~= dataSignature then
    dataSignature = signature
    snapshot.revision += 1
  end
end

local function publishSnapshot()
  snapshot.busy = actionBusy
  noctalia.state.set(STATE_KEY, snapshot)
end

local function actionResult(command, ok, message, extra)
  local result = {
    requestId = command and command.requestId or "",
    action = command and command.action or "",
    ok = ok,
    message = message or "",
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      result[k] = v
    end
  end
  noctalia.state.set(RESULT_KEY, result)
end

local function notifyOk(msg)
  noctalia.notify(noctalia.tr("title"), msg)
end

local function notifyErr(msg)
  noctalia.notifyError(noctalia.tr("title"), msg)
end

local function asString(v)
  if v == nil then
    return ""
  end
  if type(v) == "boolean" then
    return v and "true" or "false"
  end
  return tostring(v)
end

local function firstIp(list)
  if type(list) ~= "table" then
    return "", ""
  end
  local v4, v6 = "", ""
  for _, ip in ipairs(list) do
    local s = asString(ip)
    if s:find(":", 1, true) then
      if v6 == "" then
        v6 = s
      end
    elseif s ~= "" and v4 == "" then
      v4 = s
    end
  end
  return v4, v6
end

local function shortDns(dns)
  dns = asString(dns):gsub("%.$", "")
  return dns
end

local function hostLabel(peer)
  local dns = shortDns(peer.DNSName or peer.dnsName or "")
  if dns ~= "" then
    local base = dns:match("^([^.]+)")
    if base and base ~= "" then
      return base
    end
    return dns
  end
  return asString(peer.HostName or peer.hostName or peer.id or "peer")
end

local function parseStatus(data)
  local peers = {}
  local onlineCount, offlineCount = 0, 0
  local selfInfo = type(data.Self) == "table" and data.Self or {}
  local ipv4, ipv6 = firstIp(data.TailscaleIPs or selfInfo.TailscaleIPs)
  if ipv4 == "" then
    ipv4, ipv6 = firstIp(selfInfo.TailscaleIPs)
  end

  local peerMap = data.Peer
  if type(peerMap) == "table" then
    for id, peer in pairs(peerMap) do
      if type(peer) == "table" and #peers < MAX_PEERS then
        local p4, p6 = firstIp(peer.TailscaleIPs)
        local online = peer.Online == true
        local active = peer.Active == true
        local exitOpt = peer.ExitNodeOption == true
        local isExit = peer.ExitNode == true
        local name = hostLabel(peer)
        local osName = asString(peer.OS)
        local relay = asString(peer.Relay)
        local lastSeen = asString(peer.LastSeen)
        if online then
          onlineCount += 1
        else
          offlineCount += 1
        end
        table.insert(peers, {
          id = asString(peer.ID or id),
          name = name,
          hostName = asString(peer.HostName),
          dnsName = shortDns(peer.DNSName),
          ipv4 = p4,
          ipv6 = p6,
          online = online,
          active = active,
          os = osName,
          relay = relay,
          exitNode = isExit,
          exitNodeOption = exitOpt,
          rxBytes = tonumber(peer.RxBytes) or 0,
          txBytes = tonumber(peer.TxBytes) or 0,
          lastSeen = lastSeen,
          ok = online,
        })
      end
    end
  end

  table.sort(peers, function(a, b)
    if a.online ~= b.online then
      return a.online
    end
    if a.active ~= b.active then
      return a.active
    end
    return a.name < b.name
  end)

  local health = {}
  if type(data.Health) == "table" then
    for _, h in ipairs(data.Health) do
      local s = trim(h)
      if s ~= "" then
        table.insert(health, s)
      end
    end
  end

  local tailnet = ""
  local magic = asString(data.MagicDNSSuffix)
  if type(data.CurrentTailnet) == "table" then
    tailnet = asString(data.CurrentTailnet.Name)
    if magic == "" then
      magic = asString(data.CurrentTailnet.MagicDNSSuffix)
    end
  end

  local exitNode = ""
  local exitOnline = false
  if type(data.ExitNodeStatus) == "table" then
    local ips = data.ExitNodeStatus.TailscaleIPs
    if type(ips) == "table" and ips[1] then
      exitNode = asString(ips[1]):gsub("/.*$", "")
    end
    exitOnline = data.ExitNodeStatus.Online == true
    -- resolve name from peers if possible
    local eid = asString(data.ExitNodeStatus.ID)
    if eid ~= "" then
      for _, p in ipairs(peers) do
        if p.id == eid then
          exitNode = p.name
          break
        end
      end
      if exitNode == "" or exitNode:match("^%d") then
        for _, p in ipairs(peers) do
          if p.id == eid then
            exitNode = p.name
            break
          end
        end
      end
    end
  end

  local backend = asString(data.BackendState)
  local running = backend == "Running"

  return {
    backendState = backend,
    running = running,
    hostname = asString(selfInfo.HostName),
    dnsName = shortDns(selfInfo.DNSName),
    ipv4 = ipv4,
    ipv6 = ipv6,
    tailnet = tailnet,
    magicDNS = magic,
    version = asString(data.Version),
    health = health,
    peers = peers,
    onlineCount = onlineCount,
    peerCount = #peers,
    offlineCount = offlineCount,
    exitNode = exitNode,
    exitNodeOnline = exitOnline,
    advertiseExitNode = selfInfo.ExitNodeOption == true,
  }
end

local function parseExitNodeList(stdout)
  local list = {}
  for line in (tostring(stdout or "") .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= ""
      and not line:match("^IP%s")
      and not line:match("^#")
      and not line:match("^To ")
      and not line:match("^%-%-")
    then
      -- columns: IP HOSTNAME COUNTRY CITY STATUS...
      local ip, host, rest = line:match("^(%S+)%s+(%S+)%s+(.*)$")
      if ip and host and ip:match("^%d+%.%d+") then
        local status = trim(rest)
        local selected = status:lower():find("selected", 1, true) ~= nil
        local offline = status:lower():find("offline", 1, true) ~= nil
        table.insert(list, {
          id = ip,
          ip = ip,
          name = host:match("^([^.]+)") or host,
          host = host,
          status = status,
          selected = selected,
          online = not offline,
          ok = not offline,
        })
      end
    end
  end
  table.sort(list, function(a, b)
    if a.selected ~= b.selected then
      return a.selected
    end
    if a.online ~= b.online then
      return a.online
    end
    return a.name < b.name
  end)
  return list
end

local function routesIncludeDefaultExit(routes)
  if type(routes) ~= "table" then
    return false
  end
  local hasV4, hasV6 = false, false
  for _, r in ipairs(routes) do
    local s = asString(r)
    if s == "0.0.0.0/0" then
      hasV4 = true
    elseif s == "::/0" then
      hasV6 = true
    end
  end
  -- Advertising as an exit node is stored as default routes, not ExitNodeOption.
  return hasV4 or hasV6
end

local function parsePrefs(data)
  if type(data) ~= "table" then
    return {}
  end
  return {
    shieldsUp = data.ShieldsUp == true,
    acceptRoutes = data.RouteAll == true,
    runSSH = data.RunSSH == true,
    acceptDNS = data.CorpDNS == true,
    exitNodeAllowLAN = data.ExitNodeAllowLANAccess == true,
    -- Authoritative for "advertise exit node" (status Self.ExitNodeOption is often stale).
    advertiseExitNode = routesIncludeDefaultExit(data.AdvertiseRoutes),
    operatorUser = asString(data.OperatorUser),
    wantRunning = data.WantRunning == true,
  }
end

local function notifyPeerChanges(peers)
  if noctalia.getConfig("notify_on_peer_change") == false then
    return
  end
  local current = {}
  for _, p in ipairs(peers) do
    current[p.id] = p.online
    local was = prevOnline[p.id]
    if was == true and not p.online then
      notifyErr(noctalia.tr("result.peer_offline", { name = p.name }))
    elseif was == false and p.online then
      notifyOk(noctalia.tr("result.peer_online", { name = p.name }))
    end
  end
  -- only seed after first successful sample
  if next(prevOnline) ~= nil or #peers > 0 then
    prevOnline = {}
    for id, online in pairs(current) do
      prevOnline[id] = online
    end
  end
end

local refreshAll

local function forceUnstick(reason)
  noctalia.log("tailscale: " .. reason)
  refreshPending = false
  refreshStartedAt = 0
  snapshot.loading = false
  if snapshot.error == "" then
    snapshot.error = reason
  end
  noctalia.setUpdateInterval(refreshIntervalMs())
  publishSnapshot()
end

local function applyBag(statusData, prefsData, exitStdout, errors)
  local st = {}
  local prefs = {}
  local exits = {}

  local okS, errS = pcall(function()
    st = parseStatus(statusData or {})
  end)
  if not okS then
    table.insert(errors, "status parse: " .. tostring(errS))
    st = {}
  end

  local okP, errP = pcall(function()
    prefs = parsePrefs(prefsData)
  end)
  if not okP then
    table.insert(errors, "prefs parse: " .. tostring(errP))
  end

  local okE, errE = pcall(function()
    exits = parseExitNodeList(exitStdout)
  end)
  if not okE then
    table.insert(errors, "exit list: " .. tostring(errE))
  end

  -- resolve exit node display from selected exit list entry
  local exitLabel = st.exitNode or ""
  for _, e in ipairs(exits) do
    if e.selected then
      exitLabel = e.name
      st.exitNodeOnline = e.online
      break
    end
  end

  pcall(notifyPeerChanges, st.peers or {})

  local available = snapshot.installed and (st.backendState ~= "" or #(st.peers or {}) > 0 or st.hostname ~= "")
  -- Even when Stopped, status JSON is valid.
  if st.backendState ~= "" then
    available = snapshot.installed
  end

  snapshot.available = available == true
  snapshot.loading = false
  snapshot.backendState = st.backendState or ""
  snapshot.running = st.running == true
  snapshot.hostname = st.hostname or ""
  snapshot.dnsName = st.dnsName or ""
  snapshot.ipv4 = st.ipv4 or ""
  snapshot.ipv6 = st.ipv6 or ""
  snapshot.tailnet = st.tailnet or ""
  snapshot.magicDNS = st.magicDNS or ""
  snapshot.version = st.version or ""
  snapshot.health = st.health or {}
  snapshot.peers = st.peers or {}
  snapshot.exitNodes = exits
  snapshot.onlineCount = st.onlineCount or 0
  snapshot.peerCount = st.peerCount or 0
  snapshot.offlineCount = st.offlineCount or 0
  snapshot.exitNode = exitLabel
  snapshot.exitNodeOnline = st.exitNodeOnline == true
  snapshot.shieldsUp = prefs.shieldsUp == true
  snapshot.acceptRoutes = prefs.acceptRoutes == true
  snapshot.runSSH = prefs.runSSH == true
  snapshot.acceptDNS = prefs.acceptDNS == true
  -- Prefer prefs (AdvertiseRoutes); fall back to status Self.ExitNodeOption.
  if prefs.advertiseExitNode ~= nil then
    snapshot.advertiseExitNode = prefs.advertiseExitNode == true
  else
    snapshot.advertiseExitNode = st.advertiseExitNode == true
  end
  snapshot.exitNodeAllowLAN = prefs.exitNodeAllowLAN == true
  snapshot.operatorUser = prefs.operatorUser or ""
  snapshot.error = available and "" or (errors[1] or "no data")
  if available and type(st.health) == "table" and #st.health > 0 and not st.running then
    -- keep health visible without treating as hard error when stopped intentionally
    if snapshot.error == "" and st.backendState == "Stopped" then
      snapshot.error = ""
    end
  end
  snapshot.updatedAt = nowSec()
  refreshPending = false
  refreshStartedAt = 0
  noctalia.setUpdateInterval(refreshIntervalMs())

  updateRevision(table.concat({
    snapshot.backendState,
    snapshot.ipv4,
    tostring(snapshot.onlineCount),
    tostring(snapshot.peerCount),
    snapshot.exitNode,
    asString(snapshot.shieldsUp),
    asString(snapshot.runSSH),
    asString(snapshot.advertiseExitNode),
  }, "|"))
  publishSnapshot()
end

refreshAll = function()
  if refreshPending and refreshStartedAt > 0 and (nowSec() - refreshStartedAt) >= STUCK_SEC then
    forceUnstick("refresh timed out")
  end
  if refreshPending then
    refreshAgain = true
    return
  end
  refreshPending = true
  refreshAgain = false
  refreshStartedAt = nowSec()
  refreshGeneration += 1
  local generation = refreshGeneration

  local bin = tsBin()
  snapshot.installed = noctalia.commandExists(bin) or noctalia.commandExists("tailscale")
  if not snapshot.installed then
    snapshot.available = false
    snapshot.loading = false
    snapshot.error = noctalia.tr("result.missing")
    snapshot.peers = {}
    snapshot.exitNodes = {}
    snapshot.onlineCount = 0
    snapshot.peerCount = 0
    refreshPending = false
    refreshStartedAt = 0
    updateRevision("missing")
    publishSnapshot()
    return
  end

  if not snapshot.available then
    snapshot.loading = true
    publishSnapshot()
  end
  noctalia.setUpdateInterval(1000)

  local pending = 3
  local bag = { status = nil, prefs = nil, exits = "" }
  local errors = {}
  local finished = false

  local function finish()
    if generation ~= refreshGeneration then
      return
    end
    pending -= 1
    if pending > 0 or finished then
      return
    end
    finished = true
    local okApply, errApply = pcall(applyBag, bag.status, bag.prefs, bag.exits, errors)
    if not okApply then
      noctalia.log(`tailscale: apply failed: {tostring(errApply)}`)
      snapshot.loading = false
      snapshot.error = "refresh failed: " .. tostring(errApply)
      refreshPending = false
      refreshStartedAt = 0
      noctalia.setUpdateInterval(refreshIntervalMs())
      publishSnapshot()
    end
    if refreshAgain then
      refreshAgain = false
      refreshAll()
    end
  end

  -- status --json (slim: only decode once; peer count is usually small)
  runTs({ bin, "status", "--json" }, function(result)
    if generation ~= refreshGeneration then
      return
    end
    local okInner, errInner = pcall(function()
      if not result or result.exitCode ~= 0 then
        local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or "status failed")
        table.insert(errors, err ~= "" and err or "status failed")
        return
      end
      local data = noctalia.json.decode(result.stdout or "")
      if data == nil then
        table.insert(errors, "invalid status JSON")
        return
      end
      bag.status = data
    end)
    if not okInner then
      table.insert(errors, "status: " .. tostring(errInner))
    end
    finish()
  end, 20000)

  -- prefs without secrets (jq projects safe fields only)
  local prefsCmd = shellCommand({ bin, "debug", "prefs" })
    .. " | jq -c '{WantRunning,ShieldsUp,RunSSH,RouteAll,ExitNodeID,ExitNodeAllowLANAccess,CorpDNS,AdvertiseRoutes,OperatorUser,AdvertiseTags}'"
  noctalia.runAsync(prefsCmd, function(result)
    if generation ~= refreshGeneration then
      return
    end
    local okInner, errInner = pcall(function()
      if result and result.exitCode == 0 and trim(result.stdout) ~= "" then
        bag.prefs = noctalia.json.decode(result.stdout)
      end
    end)
    if not okInner then
      table.insert(errors, "prefs: " .. tostring(errInner))
    end
    finish()
  end, 15000)

  runTs({ bin, "exit-node", "list" }, function(result)
    if generation ~= refreshGeneration then
      return
    end
    local okInner, errInner = pcall(function()
      if result and result.exitCode == 0 then
        bag.exits = result.stdout or ""
      end
    end)
    if not okInner then
      table.insert(errors, "exits: " .. tostring(errInner))
    end
    finish()
  end, 15000)
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

local function runAction(command, args, okMsg, failPrefix)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  if not snapshot.installed then
    actionResult(command, false, noctalia.tr("result.missing"))
    return
  end
  actionBusy = true
  publishSnapshot()
  local bin = tsBin()
  local full = { bin }
  for _, a in ipairs(args) do
    table.insert(full, a)
  end
  runTs(full, function(result)
    local ok = result and result.exitCode == 0
    if ok then
      finishAction(command, true, okMsg)
    else
      local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or failPrefix)
      if err == "" then
        err = failPrefix
      end
      finishAction(command, false, noctalia.tr("result.failed", { error = err }))
    end
  end, 60000)
end

local function setBoolFlag(command, flag, enabled, okMsg)
  -- tailscale set --flag / --flag=false (explicit false required to turn off)
  local arg
  if enabled then
    arg = "--" .. flag .. "=true"
  else
    arg = "--" .. flag .. "=false"
  end
  runAction(command, { "set", arg }, okMsg, "set failed")
end

local function openAdmin()
  local url = trim(noctalia.getConfig("admin_url"))
  if url == "" then
    url = "https://login.tailscale.com/admin/machines"
  end
  noctalia.runAsync("xdg-open " .. shellQuote(url))
end

local function executeAction(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end
  local action = command.action

  if action == "refresh" then
    refreshAll()
    return
  end
  if action == "up" then
    runAction(command, { "up" }, noctalia.tr("result.up"), "up failed")
    return
  end
  if action == "down" then
    runAction(command, { "down" }, noctalia.tr("result.down"), "down failed")
    return
  end
  if action == "set_exit_node" then
    local node = trim(command.node or command.ip or command.id)
    if node == "" then
      actionResult(command, false, noctalia.tr("result.failed", { error = "missing exit node" }))
      return
    end
    runAction(command, { "set", "--exit-node=" .. node }, noctalia.tr("result.exit_set", { name = node }), "exit node failed")
    return
  end
  if action == "clear_exit_node" then
    runAction(command, { "set", "--exit-node=" }, noctalia.tr("result.exit_cleared"), "clear exit failed")
    return
  end
  if action == "set_shields" then
    local on = command.enabled == true or command.enabled == "true"
    setBoolFlag(command, "shields-up", on, on and noctalia.tr("result.shields_on") or noctalia.tr("result.shields_off"))
    return
  end
  if action == "set_ssh" then
    local on = command.enabled == true or command.enabled == "true"
    setBoolFlag(command, "ssh", on, on and noctalia.tr("result.ssh_on") or noctalia.tr("result.ssh_off"))
    return
  end
  if action == "set_accept_routes" then
    local on = command.enabled == true or command.enabled == "true"
    setBoolFlag(command, "accept-routes", on, on and noctalia.tr("result.routes_on") or noctalia.tr("result.routes_off"))
    return
  end
  if action == "set_advertise_exit" then
    -- Accept bool, string "true"/"false", or missing (treat as toggle off only when false).
    local on = command.enabled == true or command.enabled == "true" or command.enabled == 1
    if command.enabled == false or command.enabled == "false" or command.enabled == 0 then
      on = false
    end
    setBoolFlag(
      command,
      "advertise-exit-node",
      on,
      on and noctalia.tr("result.advertise_on") or noctalia.tr("result.advertise_off")
    )
    return
  end
  if action == "set_allow_lan" then
    local on = command.enabled == true or command.enabled == "true"
    setBoolFlag(command, "exit-node-allow-lan-access", on, on and noctalia.tr("result.lan_on") or noctalia.tr("result.lan_off"))
    return
  end
  if action == "ping" then
    local host = trim(command.host or command.name or command.ip)
    if host == "" then
      actionResult(command, false, noctalia.tr("result.failed", { error = "missing host" }))
      return
    end
    local bin = tsBin()
    local cmd = shellCommand({ bin, "ping", "-c", "3", host })
    if type(noctalia.runInTerminal) == "function" then
      noctalia.runInTerminal(cmd)
    else
      noctalia.runAsync(cmd)
    end
    actionResult(command, true, noctalia.tr("result.ping_started", { name = host }))
    notifyOk(noctalia.tr("result.ping_started", { name = host }))
    return
  end
  if action == "ssh" then
    local host = trim(command.host or command.name or command.dnsName)
    if host == "" then
      actionResult(command, false, noctalia.tr("result.failed", { error = "missing host" }))
      return
    end
    local user = trim(command.user or noctalia.getConfig("ssh_user"))
    local target = user ~= "" and (user .. "@" .. host) or host
    local bin = tsBin()
    local cmd = shellCommand({ bin, "ssh", target })
    if type(noctalia.runInTerminal) == "function" then
      noctalia.runInTerminal(cmd)
    else
      noctalia.runAsync(cmd)
    end
    actionResult(command, true, noctalia.tr("result.ssh_started", { name = target }))
    notifyOk(noctalia.tr("result.ssh_started", { name = target }))
    return
  end
  if action == "copy" then
    local text = trim(command.text or command.name)
    if text ~= "" then
      noctalia.copyToClipboard(text, "text/plain")
      actionResult(command, true, noctalia.tr("result.copied", { name = text }))
      notifyOk(noctalia.tr("result.copied", { name = text }))
    end
    return
  end
  if action == "open_admin" then
    openAdmin()
    actionResult(command, true, noctalia.tr("result.admin_opened"))
    return
  end
  actionResult(command, false, "Unknown action: " .. action)
end

noctalia.state.watch(COMMAND_KEY, executeAction)
noctalia.setUpdateInterval(refreshIntervalMs())
refreshAll()

function update()
  refreshAll()
end

function onConfigChanged()
  noctalia.setUpdateInterval(refreshIntervalMs())
  refreshPending = false
  refreshStartedAt = 0
  refreshAll()
end

function onIpc(event, payload)
  if event == "refresh" then
    refreshPending = false
    refreshStartedAt = 0
    refreshAll()
  elseif event == "up" then
    executeAction({ action = "up", requestId = "ipc-up" })
  elseif event == "down" then
    executeAction({ action = "down", requestId = "ipc-down" })
  elseif event == "toggle" then
    if snapshot.running then
      executeAction({ action = "down", requestId = "ipc-toggle" })
    else
      executeAction({ action = "up", requestId = "ipc-toggle" })
    end
  elseif type(payload) == "table" and type(payload.action) == "string" then
    executeAction(payload)
  end
end
