--!nonstrict
-- Tailscale poller — the headless [[service]] entry.
--
-- Polls `tailscale status --json`, normalizes the result into a compact
-- snapshot (self + sorted peer list with online state), and publishes it
-- JSON-encoded to noctalia.state under "ts.snapshot". Executes commands sent
-- by the UI entries through "ts.cmd": refresh, up, down, exit-node set/clear.

local busy = false
local pendingPoll = false
local installed = nil -- nil = unknown, checked on first poll

local function trim(s)
  return noctalia.string.trim(s or "")
end

-- Tailscale short name: first label of the DNS name ("pc-work.tail1234.ts.net." → "pc-work").
-- This is what tailscale ssh / file cp expect as a target.
local function shortName(dnsName)
  return trim(dnsName):match("^([^%.]+)") or ""
end

-- Some devices (e.g. Android) report "localhost" as HostName; fall back to the
-- DNS short name in that case.
local function displayName(hostName, dnsName)
  hostName = trim(hostName)
  if hostName ~= "" and hostName:lower() ~= "localhost" then
    return hostName
  end
  local label = shortName(dnsName)
  return label ~= "" and label or hostName
end

local function firstIPv4(ips)
  for _, ip in (ips or {}) do
    if ip:match("^100%.") then
      return ip
    end
  end
  return (ips or {})[1] or ""
end

local function emptySnapshot(state, detail)
  return {
    state = state, -- running | stopped | needs-login | not-installed | error
    detail = detail or "",
    checkedAt = noctalia.formatTime("hh:mm:ss"),
    authUrl = "",
    self = { name = "", ip = "", dnsName = "" },
    peers = {},
    online = 0,
    total = 0,
    exitNode = nil,
  }
end

local function publish(snapshot)
  busy = false
  local encoded = noctalia.json.encode(snapshot)
  if encoded then
    noctalia.state.set("ts.snapshot", encoded)
  end
  if pendingPoll then
    pendingPoll = false
    poll()
  end
end

local function buildSnapshot(data)
  local snapshot = emptySnapshot("running")
  local backend = data.BackendState or ""

  if backend == "NeedsLogin" then
    snapshot.state = "needs-login"
    snapshot.authUrl = trim(data.AuthURL)
    return snapshot
  end
  if backend ~= "Running" then
    snapshot.state = "stopped"
    return snapshot
  end

  local selfNode = data.Self or {}
  snapshot.self = {
    name = displayName(selfNode.HostName, selfNode.DNSName),
    ip = firstIPv4(selfNode.TailscaleIPs),
    dnsName = shortName(selfNode.DNSName),
  }

  local hideMullvad = noctalia.getConfig("hide_mullvad") ~= false
  local hideOffline = noctalia.getConfig("hide_offline") == true

  for _, peer in (data.Peer or {}) do
    local dns = trim(peer.DNSName)
    if hideMullvad and dns:find(".mullvad.ts.net", 1, true) then
      continue
    end
    local online = peer.Online == true
    if hideOffline and not online then
      continue
    end
    -- Last-seen timestamp for offline peers (skip Go zero dates).
    local lastSeen = trim(peer.LastSeen)
    if lastSeen ~= "" and lastSeen:sub(1, 4) ~= "0001" then
      lastSeen = lastSeen:sub(1, 16):gsub("T", " ")
    else
      lastSeen = ""
    end
    table.insert(snapshot.peers, {
      name = displayName(peer.HostName, dns),
      shortName = shortName(dns),
      ip = firstIPv4(peer.TailscaleIPs),
      online = online,
      os = trim(peer.OS),
      lastSeen = lastSeen,
      exitNodeOption = peer.ExitNodeOption == true,
      exitNode = peer.ExitNode == true,
    })
    snapshot.total += 1
    if online then
      snapshot.online += 1
    end
  end

  -- Two nodes can share a HostName (e.g. two "NAS"); fall back to the unique
  -- Tailscale short name for duplicates so the lists stay unambiguous.
  local nameCount = {}
  for _, peer in snapshot.peers do
    nameCount[peer.name] = (nameCount[peer.name] or 0) + 1
  end
  for _, peer in snapshot.peers do
    if nameCount[peer.name] > 1 and peer.shortName ~= "" then
      peer.name = peer.shortName
    end
  end

  -- Online hosts first, then alphabetical.
  table.sort(snapshot.peers, function(a, b)
    if a.online ~= b.online then
      return a.online
    end
    return a.name:lower() < b.name:lower()
  end)

  local exitStatus = data.ExitNodeStatus
  if exitStatus then
    local exitIp = firstIPv4(exitStatus.TailscaleIPs)
    local exitName = exitIp
    for _, peer in snapshot.peers do
      if peer.exitNode then
        exitName = peer.name
        break
      end
    end
    snapshot.exitNode = { name = exitName, ip = exitIp, online = exitStatus.Online == true }
  end

  return snapshot
end

function poll()
  if busy then
    pendingPoll = true
    return
  end
  busy = true

  if installed == nil then
    installed = noctalia.commandExists("tailscale")
  end
  if not installed then
    publish(emptySnapshot("not-installed"))
    return
  end

  local launched = noctalia.runAsync("tailscale status --json", function(result)
    if result.exitCode ~= 0 or result.timedOut then
      publish(emptySnapshot("stopped", trim(result.stderr)))
      return
    end
    if result.stdoutTruncated then
      publish(emptySnapshot("error", "status output truncated"))
      return
    end
    local data = noctalia.json.decode(result.stdout)
    if not data then
      publish(emptySnapshot("error", "invalid status JSON"))
      return
    end
    publish(buildSnapshot(data))
  end, 10000)
  if not launched then
    publish(emptySnapshot("error", "failed to run tailscale"))
  end
end

-- ── Commands from UI entries ─────────────────────────────────────────────────

local function runThenRefresh(cmdline, okKey, failKey)
  noctalia.runAsync(cmdline, function(result)
    if result.exitCode == 0 then
      if okKey then
        noctalia.notify(noctalia.tr("toast.title"), noctalia.tr(okKey))
      end
    else
      noctalia.notifyError(noctalia.tr("toast.title"),
        trim(result.stderr) ~= "" and trim(result.stderr) or noctalia.tr(failKey or "toast.failed"))
    end
    poll()
  end, 30000)
end

-- Taildrop receive: snapshot the target dir, run `tailscale file get`, then
-- diff to list what actually arrived. Requires operator mode
-- (`sudo tailscale set --operator=$USER`) to run without root.
local function receiveTaildrop()
  local dir = trim(noctalia.getConfig("taildrop_dir"))

  local function go(target)
    local pre = {}
    for _, f in (noctalia.listDir(target) or {}) do
      pre[f] = true
    end
    noctalia.runAsync(`tailscale file get "{target}"`, function(result)
      if result.exitCode ~= 0 then
        local err = trim(result.stderr)
        noctalia.notifyError(noctalia.tr("toast.title"), err ~= "" and err or noctalia.tr("taildrop.failed"))
        return
      end
      local fresh = {}
      for _, f in (noctalia.listDir(target) or {}) do
        if not pre[f] then
          table.insert(fresh, f)
        end
      end
      if #fresh > 0 then
        noctalia.notify(noctalia.tr("toast.title"),
          `{noctalia.tr("taildrop.received", { count = #fresh, dir = target })}\n{table.concat(fresh, "\n")}`)
      else
        noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("taildrop.none"))
      end
    end, 60000)
  end

  if dir ~= "" then
    go(noctalia.expandPath(dir))
  else
    -- Default: the XDG download dir (locale-aware, e.g. ~/Scaricati).
    noctalia.runAsync("xdg-user-dir DOWNLOAD", function(result)
      local target = trim(result.stdout)
      go(target ~= "" and target or noctalia.expandPath("~/Downloads"))
    end, 5000)
  end
end

local function pingPeer(ip, name)
  noctalia.runAsync(`tailscale ping -c 3 {ip}`, function(result)
    local out = trim(result.stdout)
    local lastLine = out:match("([^\n]+)%s*$") or ""
    if result.exitCode == 0 and lastLine ~= "" then
      noctalia.notify(`Ping {name}`, lastLine)
    else
      local err = trim(result.stderr)
      noctalia.notifyError(`Ping {name}`, err ~= "" and err or noctalia.tr("toast.failed"))
    end
  end, 25000)
end

noctalia.state.watch("ts.cmd", function(raw)
  local cmd = raw and noctalia.json.decode(raw) or nil
  if not cmd or not cmd.action then
    return
  end

  if cmd.action == "refresh" then
    poll()
  elseif cmd.action == "up" then
    runThenRefresh("tailscale up", "toast.connected")
  elseif cmd.action == "down" then
    runThenRefresh("tailscale down", "toast.disconnected")
  elseif cmd.action == "exit_set" and cmd.ip then
    runThenRefresh(`tailscale set --exit-node={cmd.ip}`, "toast.exit-node-enabled")
  elseif cmd.action == "exit_clear" then
    runThenRefresh("tailscale set --exit-node=", "toast.exit-node-disabled")
  elseif cmd.action == "taildrop_get" then
    receiveTaildrop()
  elseif cmd.action == "ping" and cmd.ip then
    pingPeer(cmd.ip, cmd.name or cmd.ip)
  elseif cmd.action == "login" then
    -- Open the pending auth URL surfaced by the daemon (panel guards on it).
    -- gio, not xdg-open: see the syncthing plugin — xdg-open no-ops with
    -- XDG_CURRENT_DESKTOP=KDE outside a real KDE session.
    if cmd.url and cmd.url:match("^https?://") then
      noctalia.runAsync(`gio open "{cmd.url}" || xdg-open "{cmd.url}"`)
    end
  else
    noctalia.log(`[tailscale] unknown command: {cmd.action}`)
  end
end)

function onConfigChanged()
  poll()
end

function onIpc(event)
  if event == "refresh" then
    poll()
  elseif event == "up" then
    runThenRefresh("tailscale up", "toast.connected")
  elseif event == "down" then
    runThenRefresh("tailscale down", "toast.disconnected")
  end
end

function update()
  local seconds = tonumber(noctalia.getConfig("poll_interval")) or 5
  noctalia.setUpdateInterval(math.clamp(seconds, 1, 60) * 1000)
  poll()
end
