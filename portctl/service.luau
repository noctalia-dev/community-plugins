--!nonstrict
-- portctl — headless scanner service.
-- Owns all port data. Widget and panel consume via noctalia.state.
--
-- Published state:
--   portctl_data   { ports: PortEntry[], error: string?, last_updated: number }
--   portctl_stats  { count: number }
--
-- Consumed state:
--   portctl_command  { action: "kill", pid: number }
--   portctl_refresh  any → triggers immediate scan
--
-- PortEntry = { port, proto, name, pid, category }

-- ── Category detection ────────────────────────────────────────────────────

local CATEGORIES = {
  { name = "Development", patterns = {
      "node", "vite", "webpack", "next", "nuxt", "expo", "tsx", "ts%-node",
      "nodemon", "bun", "deno", "storybook", "esbuild", "rollup", "gatsby",
      "parcel", "turbo", "jest", "vitest", "remix", "svelte", "pm2",
  }},
  { name = "Databases", patterns = {
      "postgres", "postmaster", "mysqld", "mariadbd", "mongod", "redis%-server",
      "memcached", "elasticsearch", "influxd", "prometheus", "clickhouse",
      "cassandra", "couchdb", "rethinkdb", "valkey",
  }},
  { name = "Containers", patterns = {
      "dockerd", "docker%-proxy", "containerd", "podman", "kubelet",
      "kube%-proxy", "buildkitd", "nerdctl", "crio",
      "rootlessport", "rootlesskit", "slirp4netns",
  }},
  { name = "Servers", patterns = {
      "nginx", "apache2", "httpd", "caddy", "traefik", "haproxy", "sshd",
      "lighttpd", "envoy", "squid", "gunicorn", "uvicorn", "puma", "unicorn",
  }},
  { name = "Cloud", patterns = {
      "cloudflared", "tailscaled", "openvpn", "wg", "wireguard",
      "ngrok", "bore", "frpc", "frps",
  }},
}

local function detectCategory(name)
  local lower = name:lower()
  for _, cat in ipairs(CATEGORIES) do
    for _, pat in ipairs(cat.patterns) do
      if lower:find(pat) then return cat.name end
    end
  end
  return "Other"
end

-- ── Ignore list ───────────────────────────────────────────────────────────
-- Comma-separated substrings matched case-insensitively against process name.
-- Example config value: "discord,chrome,steam,spotify"

local function buildIgnorePatterns()
  local raw = noctalia.getConfig("ignore_list") or ""
  local patterns = {}
  for entry in raw:gmatch("[^,]+") do
    local pat = entry:match("^%s*(.-)%s*$"):lower()
    if pat ~= "" then table.insert(patterns, pat) end
  end
  return patterns
end

local function buildIgnorePorts()
  local raw = noctalia.getConfig("ignore_ports") or ""
  local ports = {}
  for entry in raw:gmatch("[^,]+") do
    local n = tonumber(entry:match("^%s*(.-)%s*$"))
    if n then ports[n] = true end
  end
  return ports
end

local function isIgnored(name, patterns)
  if #patterns == 0 then return false end
  local lower = name:lower()
  for _, pat in ipairs(patterns) do
    if lower:find(pat, 1, true) then return true end
  end
  return false
end

-- ── SsProvider ────────────────────────────────────────────────────────────
-- Implements PortProvider contract: scan(callback(ports, error?))
--
-- Handles both iproute2 output formats:
--   Old:  State  Recv-Q Send-Q  LocalAddr:Port  PeerAddr:Port  [users:(...)]
--   New:  Netid  State  Recv-Q  Send-Q  LocalAddr:Port  PeerAddr:Port  [users:(...)]

local function parseSsLine(line)
  local parts = {}
  for tok in line:gmatch("%S+") do table.insert(parts, tok) end
  if #parts < 5 then return nil end

  local state, addrIdx
  if parts[1] == "LISTEN" or parts[1] == "UNCONN" then
    state, addrIdx = parts[1], 4   -- old format
  elseif parts[2] == "LISTEN" or parts[2] == "UNCONN" then
    state, addrIdx = parts[2], 5   -- new format (Netid prepended)
  else
    return nil
  end
  if #parts < addrIdx then return nil end

  local port = tonumber((parts[addrIdx]):match(":(%d+)$"))
  if not port then return nil end

  local proto     = state == "UNCONN" and "udp" or "tcp"
  local procIdx   = addrIdx + 2  -- skip peer address column
  local procField = #parts >= procIdx and table.concat(parts, " ", procIdx) or ""

  local entries = {}
  for name, pidStr in procField:gmatch('"([^"]+)",pid=(%d+)') do
    local pid = tonumber(pidStr)
    if pid then
      table.insert(entries, { port = port, proto = proto, name = name, pid = pid })
    end
  end
  if #entries == 0 then
    -- Port visible but process info hidden (likely root-owned, no sudo)
    table.insert(entries, { port = port, proto = proto, name = "(unknown)", pid = 0 })
  end
  return entries
end

local SsProvider = {}

function SsProvider.parse(stdout)
  local ports = {}
  for line in stdout:gmatch("[^\n]+") do
    local entries = parseSsLine(line)
    if entries then
      for _, e in ipairs(entries) do table.insert(ports, e) end
    end
  end
  return ports
end

function SsProvider.scan(callback)
  local out       = { tcp = "", udp = "" }
  local remaining = 2

  local function finish(key, data)
    out[key]   = data
    remaining -= 1
    if remaining > 0 then return end
    callback(SsProvider.parse(out.tcp .. "\n" .. out.udp), nil)
  end

  if not noctalia.runAsync("ss -ltnp 2>/dev/null", function(r) finish("tcp", r.stdout or "") end) then
    finish("tcp", "")
  end
  if not noctalia.runAsync("ss -lunp 2>/dev/null", function(r) finish("udp", r.stdout or "") end) then
    finish("udp", "")
  end
end

-- ── Publishing ────────────────────────────────────────────────────────────

local function publish(ports, err)
  if ports and #ports > 0 then
    table.sort(ports, function(a, b) return a.port < b.port end)
  end
  local tcpCount = 0
  for _, p in ipairs(ports or {}) do
    if p.proto == "tcp" then tcpCount += 1 end
  end
  noctalia.state.set("portctl_data", {
    ports        = ports or {},
    error        = err,
    last_updated = os.time(),
  })
  noctalia.state.set("portctl_stats", {
    count     = ports and #ports or 0,
    count_tcp = tcpCount,
  })
end

-- ── Scan orchestrator ─────────────────────────────────────────────────────

local function runScan()
  if not noctalia.commandExists("ss") then
    publish(nil, noctalia.tr("service.ss_not_found"))
    return
  end

  local ignorePatterns = buildIgnorePatterns()
  local ignorePorts    = buildIgnorePorts()
  local hideSystem     = noctalia.getConfig("hide_system_ports")  == true
  local hideUnknown    = noctalia.getConfig("hide_unknown_ports") == true

  SsProvider.scan(function(ports, _err)
    local filtered = {}
    for _, p in ipairs(ports) do
      if hideSystem  and p.port < 1024   then continue end
      if hideUnknown and p.pid == 0      then continue end
      if ignorePorts[p.port]             then continue end
      if isIgnored(p.name, ignorePatterns) then continue end
      p.category = detectCategory(p.name)
      table.insert(filtered, p)
    end
    publish(filtered, nil)
  end)
end

-- ── Command handlers ──────────────────────────────────────────────────────

noctalia.state.watch("portctl_command", function(cmd)
  if type(cmd) ~= "table" or cmd.action ~= "kill" or not cmd.pid then return end
  local pid = tostring(cmd.pid)
  noctalia.runAsync("kill -15 " .. pid, function(r)
    if r.exitCode == 0 then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("service.terminated", { pid = pid }))
    else
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("service.kill_failed", { pid = pid }))
    end
    runScan()
  end)
end)

noctalia.state.watch("portctl_refresh", function()
  runScan()
end)

-- ── Lifecycle ─────────────────────────────────────────────────────────────

publish({}, nil)
runScan()

function update()
  noctalia.setUpdateInterval((noctalia.getConfig("refresh_interval") or 2) * 1000)
  runScan()
end

function onConfigChanged()
  noctalia.setUpdateInterval((noctalia.getConfig("refresh_interval") or 2) * 1000)
end
