--!nonstrict
-- Tailscale poller — the headless [[service]] entry.
--
-- Polls `tailscale status --json` and `tailscale debug prefs`, normalizes the
-- result into a compact snapshot (self + sorted peer list with online state +
-- daemon health + preference flags), and publishes it JSON-encoded to
-- noctalia.state under "tn.snapshot". Executes commands sent by the UI entries
-- through "tn.cmd": refresh, up, down, exit-node set/clear, preference
-- toggles, ping, SSH, Taildrop receive.

-- A poll spans several subprocesses, so a callback that never fires would
-- otherwise wedge the poller forever. Every poll carries a generation number:
-- callbacks from a superseded generation are dropped, and a poll still pending
-- after this long is considered lost, letting the next one take over.
local STUCK_MS = 20000

local pollGeneration = 0
local pollPending = false
local pollStartedAt = 0
local pollAgain = false
local installed = nil -- nil = unknown, checked on first poll

local function trim(s)
  return noctalia.string.trim(s or "")
end

-- The runtime only takes a command *line*, so every dynamic argument has to be
-- shell-quoted by hand: wrap in single quotes and escape embedded ones.
local function shq(value)
  local quoted = tostring(value or ""):gsub("'", "'\\''")
  return `'{quoted}'`
end

-- The tailscale binary, shell-quoted and ready to prefix a command line. The
-- setting exists for installs that keep it off PATH (nix profiles, /opt, the
-- macOS app bundle).
local function tsBin()
  local configured = trim(noctalia.getConfig("tailscale_bin"))
  return configured ~= "" and shq(noctalia.expandPath(configured)) or "tailscale"
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
    checkedAt = noctalia.formatTime("%H:%M:%S"),
    authUrl = "",
    self = { name = "", ip = "", dnsName = "" },
    peers = {},
    online = 0,
    total = 0,
    exitNode = nil,
    health = {},
    prefs = nil, -- filled in once `tailscale debug prefs` answers
  }
end

local function publish(snapshot, generation)
  -- A late callback from a poll that was already given up on must not clobber
  -- the snapshot a newer poll published.
  if generation and generation ~= pollGeneration then
    return
  end
  pollPending = false
  pollStartedAt = 0
  local encoded = noctalia.json.encode(snapshot)
  if encoded then
    noctalia.state.set("tn.snapshot", encoded)
  end
  if pollAgain then
    pollAgain = false
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

  -- The daemon's own warnings (expiring key, unreachable relay, no route to a
  -- subnet router…). Worth surfacing: they explain most "it is connected but
  -- nothing works" situations.
  for _, warning in (data.Health or {}) do
    local text = trim(warning)
    if text ~= "" then
      table.insert(snapshot.health, text)
    end
  end

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

-- `tailscale debug prefs` is the only place the toggles are readable, and its
-- output also carries the node's private key. Nothing but these booleans is
-- kept: the decoded table goes out of scope with this function, and the
-- snapshot never sees the rest.
local function readPrefs(snapshot, generation, done)
  local launched = noctalia.runAsync(`{tsBin()} debug prefs`, function(result)
    if generation ~= pollGeneration then
      return
    end
    local data = result.exitCode == 0 and not result.stdoutTruncated
      and noctalia.json.decode(result.stdout) or nil
    if data then
      -- Advertising as an exit node is stored as the default routes, not as a
      -- flag; Self.ExitNodeOption in `status` is often stale.
      local advertises = false
      for _, route in (data.AdvertiseRoutes or {}) do
        if route == "0.0.0.0/0" or route == "::/0" then
          advertises = true
          break
        end
      end
      snapshot.prefs = {
        shieldsUp = data.ShieldsUp == true,
        acceptRoutes = data.RouteAll == true,
        runSSH = data.RunSSH == true,
        advertiseExitNode = advertises,
        allowLanAccess = data.ExitNodeAllowLANAccess == true,
      }
    end
    done()
  end, 10000)
  if not launched then
    done()
  end
end

function poll()
  if pollPending then
    -- Still waiting on a poll that has not timed out: coalesce into it.
    if noctalia.nowMs() - pollStartedAt < STUCK_MS then
      pollAgain = true
      return
    end
    -- Otherwise the poll is lost. Bumping the generation below makes its
    -- callbacks no-ops if they ever do arrive.
  end
  pollPending = true
  pollStartedAt = noctalia.nowMs()
  pollGeneration += 1
  local generation = pollGeneration

  if installed == nil then
    local configured = trim(noctalia.getConfig("tailscale_bin"))
    installed = configured ~= ""
      and noctalia.fileExists(noctalia.expandPath(configured))
      or noctalia.commandExists("tailscale")
  end
  if not installed then
    publish(emptySnapshot("not-installed"), generation)
    return
  end

  local launched = noctalia.runAsync(`{tsBin()} status --json`, function(result)
    if generation ~= pollGeneration then
      return
    end
    if result.exitCode ~= 0 or result.timedOut then
      publish(emptySnapshot("stopped", trim(result.stderr)), generation)
      return
    end
    if result.stdoutTruncated then
      publish(emptySnapshot("error", "status output truncated"), generation)
      return
    end
    local data = noctalia.json.decode(result.stdout)
    if not data then
      publish(emptySnapshot("error", "invalid status JSON"), generation)
      return
    end
    local snapshot = buildSnapshot(data)
    if snapshot.state ~= "running" then
      publish(snapshot, generation)
      return
    end
    readPrefs(snapshot, generation, function()
      publish(snapshot, generation)
    end)
  end, 10000)
  if not launched then
    publish(emptySnapshot("error", "failed to run tailscale"), generation)
  end
end

-- ── Commands from UI entries ─────────────────────────────────────────────────

local function runThenRefresh(cmdline, okKey, failKey, subst)
  noctalia.runAsync(cmdline, function(result)
    if result.exitCode == 0 then
      if okKey then
        noctalia.notify(noctalia.tr("toast.title"), noctalia.tr(okKey, subst))
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
    noctalia.runAsync(`{tsBin()} file get {shq(target)}`, function(result)
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
  noctalia.runAsync(`{tsBin()} ping -c 3 {shq(ip)}`, function(result)
    local out = trim(result.stdout)
    local err = trim(result.stderr)
    -- A peer reachable only through a DERP relay still answers every ping, but
    -- `tailscale ping` then prints "direct connection not established" as its
    -- last line and exits non-zero. Report the last pong instead, and say the
    -- connection is relayed rather than calling the ping a failure.
    local pong = nil
    for line in out:gmatch("[^\n]+") do
      if line:match("^%s*pong") then
        pong = trim(line)
      end
    end
    if pong then
      local combined = `{out}\n{err}`
      local relayed = combined:find("direct connection not established", 1, true)
      noctalia.notify(`Ping {name}`, relayed and `{pong}\n{noctalia.tr("ping.relayed")}` or pong)
    else
      noctalia.notifyError(`Ping {name}`, err ~= "" and err or noctalia.tr("toast.failed"))
    end
  end, 25000)
end

-- gio, not xdg-open: see the syncthing plugin — xdg-open no-ops with
-- XDG_CURRENT_DESKTOP=KDE outside a real KDE session. The URL is checked
-- against a strict character set before it reaches the command line.
local function openUrl(url)
  if url and url:match("^https?://[%w%.%-%_%~%:%/%?%#%[%]%@%!%$%&%'%(%)%*%+%,%;%=%%]+$") then
    local quoted = shq(url)
    noctalia.runAsync(`gio open {quoted} || xdg-open {quoted}`)
  end
end

-- The five toggles `tailscale set` exposes, mapped to their flag. Turning one
-- off needs an explicit =false, so both directions pass the value.
-- `flag` is what `tailscale set --<flag>` wants; `label` is the translation key,
-- which en.json requires to be lowercase, so neither can be the field name.
local PREF_FLAGS = {
  shieldsUp = { flag = "shields-up", label = "shields-up" },
  acceptRoutes = { flag = "accept-routes", label = "accept-routes" },
  runSSH = { flag = "ssh", label = "run-ssh" },
  advertiseExitNode = { flag = "advertise-exit-node", label = "advertise-exit-node" },
  allowLanAccess = { flag = "exit-node-allow-lan-access", label = "allow-lan-access" },
}

noctalia.state.watch("tn.cmd", function(raw)
  local cmd = raw and noctalia.json.decode(raw) or nil
  if not cmd or not cmd.action then
    return
  end

  local bin = tsBin()
  if cmd.action == "refresh" then
    poll()
  elseif cmd.action == "up" then
    runThenRefresh(`{bin} up`, "toast.connected")
  elseif cmd.action == "down" then
    runThenRefresh(`{bin} down`, "toast.disconnected")
  elseif cmd.action == "exit_set" and cmd.ip then
    runThenRefresh(`{bin} set --exit-node={shq(cmd.ip)}`, "toast.exit-node-enabled")
  elseif cmd.action == "exit_clear" then
    runThenRefresh(`{bin} set --exit-node=`, "toast.exit-node-disabled")
  elseif cmd.action == "set_pref" then
    local pref = PREF_FLAGS[cmd.pref or ""]
    if pref then
      local on = cmd.enabled == true
      runThenRefresh(`{bin} set --{pref.flag}={on and "true" or "false"}`,
        on and "toast.pref-on" or "toast.pref-off", nil,
        { name = noctalia.tr(`pref.{pref.label}`) })
    end
  elseif cmd.action == "taildrop_get" then
    receiveTaildrop()
  elseif cmd.action == "ping" and cmd.ip then
    pingPeer(cmd.ip, cmd.name or cmd.ip)
  elseif cmd.action == "login" then
    -- The pending auth URL surfaced by the daemon (the panel guards on it).
    openUrl(cmd.url)
  elseif cmd.action == "open_admin" then
    local configured = trim(noctalia.getConfig("admin_url"))
    openUrl(configured ~= "" and configured or "https://login.tailscale.com/admin/machines")
  else
    noctalia.log(`[tailnet] unknown command: {cmd.action}`)
  end
end)

function onConfigChanged()
  -- tailscale_bin may have changed, so the cached lookup has to go.
  installed = nil
  poll()
end

function onIpc(event)
  if event == "refresh" then
    poll()
  elseif event == "up" then
    runThenRefresh(`{tsBin()} up`, "toast.connected")
  elseif event == "down" then
    runThenRefresh(`{tsBin()} down`, "toast.disconnected")
  end
end

function update()
  local seconds = tonumber(noctalia.getConfig("poll_interval")) or 5
  noctalia.setUpdateInterval(math.clamp(seconds, 1, 60) * 1000)
  poll()
end
