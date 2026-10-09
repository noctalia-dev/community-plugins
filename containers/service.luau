--!nonstrict
-- Containers + host services.
--
-- Polls `docker ps`, `podman ps` and the host's own listening TCP sockets, turns
-- each published port into a link, and publishes one plain-data snapshot on
-- noctalia.state for the bar widget, the panel, and the control-center shortcut
-- to watch.
--
-- Nothing here is long lived: every refresh is a short detached command, so the
-- service is restartable at any time and never leaks a process.

local KEY_SNAPSHOT = "snapshot"
local KEY_REFRESH_NONCE = "refresh"

-- Order matters: it is the order the panel renders the runtimes in.
local RUNTIME_ORDER = { "docker", "podman", "host" }

local RUNTIMES = {
  docker = { id = "docker", labelKey = "panel.runtime.docker", glyph = "brand-docker", command = "docker" },
  podman = { id = "podman", labelKey = "panel.runtime.podman", glyph = "box", command = "podman" },
  -- Host services are named from systemd when possible and from the owning
  -- process otherwise; `ss` is what actually finds the ports.
  host = { id = "host", labelKey = "panel.runtime.host", glyph = "server", command = "ss", emptyKey = "panel.empty.host" },
}

local TICK_MS = 1000
local MAX_PORT_RANGE = 64 -- a published range wider than this is capped, not expanded

-- Addresses docker and podman publish "everywhere" on.
local WILDCARD_HOSTS = {
  [""] = true,
  ["0.0.0.0"] = true,
  ["::"] = true,
  ["::0"] = true,
  ["*"] = true,
}

local settings = {}
local snapshot = nil
local generation = 0
local outstanding = 0
local collected = {}
local runtimeErrors = {}
local tickCount = 0

-- Section separators of the single host probe command. The first section (the
-- sockets) is everything before MARKER_UNITS.
local MARKER_UNITS = "@@CONTAINERS_UNITS@@"
local MARKER_USER_UNITS = "@@CONTAINERS_USER_UNITS@@"
local MARKER_INTERNAL = "@@CONTAINERS_INTERNAL@@"

-- These processes exist only to forward a container port that the runtime
-- already reports, so listing them again under Host would duplicate it.
local HOST_SKIP_PROCESSES = {
  ["docker-proxy"] = true,
  ["conmon"] = true,
  ["podman"] = true,
  ["rootlessport"] = true,
  ["slirp4netns"] = true,
  ["pasta"] = true,
  ["ss"] = true,
  ["sh"] = true,
  ["bash"] = true,
  ["zsh"] = true,
}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return noctalia.string.trim(value)
end

local function numberOr(value, fallback)
  local parsed = tonumber(value)
  if parsed == nil then
    return fallback
  end
  return parsed
end

local function shellQuote(value)
  return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function readSettings()
  settings.refresh_seconds = math.max(1, math.floor(numberOr(noctalia.getConfig("refresh_seconds"), 5)))
  settings.show_stopped = noctalia.getConfig("show_stopped") == true
  settings.show_host = noctalia.getConfig("show_host_services") ~= false
  local openHost = trim(noctalia.getConfig("open_host"))
  settings.open_host = openHost == "" and "localhost" or openHost
  settings.command_prefix = trim(noctalia.getConfig("command_prefix"))
end

local function intervalTicks()
  return math.max(1, math.floor(settings.refresh_seconds))
end

-- The runtimes this refresh polls, and the order the panel renders them in.
local function activeRuntimes()
  if settings.show_host then
    return RUNTIME_ORDER
  end
  return { "docker", "podman" }
end

local function runtimeAvailable(runtimeId)
  if runtimeId == "host" then
    -- systemd only names what `ss` found, so ss is the real requirement.
    return noctalia.commandExists("ss")
  end
  return noctalia.commandExists(RUNTIMES[runtimeId].command)
end

-- Docker prints `127.0.0.1:8888->8888/tcp`, IPv6 uses brackets, and a
-- published range widens to `0.0.0.0:8000-8005->80/tcp`.
local function hostLiteral(host)
  if host:find(":", 1, true) then
    return "[" .. host .. "]"
  end
  return host
end

-- A binding on 0.0.0.0, :: or loopback is not a hostname the user can click:
-- those all become `open_host`.
local function localAddress(hostIp)
  return WILDCARD_HOSTS[hostIp] == true or hostIp == "127.0.0.1" or hostIp == "::1" or hostIp:lower() == "localhost"
end

local function buildPort(hostIp, hostPort, containerPort, protocol)
  local host = localAddress(hostIp) and settings.open_host or hostIp
  local scheme = hostPort == 443 and "https" or "http"
  return {
    hostIp = hostIp,
    host = host,
    hostPort = hostPort,
    containerPort = containerPort,
    protocol = protocol,
    url = scheme .. "://" .. hostLiteral(host) .. ":" .. tostring(hostPort),
  }
end

local function addPortRange(out, hostIp, low, high, containerPort, protocol)
  if high < low then
    low, high = high, low
  end
  if high - low > MAX_PORT_RANGE then
    high = low + MAX_PORT_RANGE
  end
  for port = math.floor(low), math.floor(high) do
    out[#out + 1] = buildPort(hostIp, port, containerPort, protocol)
  end
end

-- Parses one entry of docker's `Ports` string into `out`. Returns nil for
-- entries that are not published on the host (`80/tcp`, `80/tcp -> ...`).
local function parsePortSpec(out, spec)
  spec = trim(spec)
  if spec == "" then
    return nil
  end
  local arrow = string.find(spec, "->", 1, true)
  if arrow == nil then
    return nil
  end

  local hostPart = trim(spec:sub(1, arrow - 1))
  local rest = trim(spec:sub(arrow + 2))

  -- `(.*)` is greedy, so this splits on the last colon followed by digits and
  -- keeps bracketed IPv6 addresses, and accepts `8000-8002` ranges, intact.
  local hostIp = ""
  local portText = hostPart
  local ip, port = hostPart:match("^(.*):(%d+[%-%d]*)$")
  if ip ~= nil then
    hostIp = ip
    portText = port
    if hostIp:sub(1, 1) == "[" and hostIp:sub(-1, -1) == "]" then
      hostIp = hostIp:sub(2, -2)
    end
  end

  local containerPort, protocol = rest:match("^(%d+)/(%a+)")
  containerPort = tonumber(containerPort)
  if containerPort == nil then
    return nil
  end
  protocol = protocol or "tcp"

  -- Only TCP ports can serve a web UI.
  if protocol ~= "tcp" then
    return nil
  end

  local low, high = portText:match("^(%d+)%-(%d+)$")
  if low ~= nil then
    addPortRange(out, hostIp, tonumber(low), tonumber(high), containerPort, protocol)
    return true
  end

  local single = tonumber(portText)
  if single == nil then
    return nil
  end
  out[#out + 1] = buildPort(hostIp, single, containerPort, protocol)
  return true
end

-- Docker reports ports as a comma separated string; podman reports an array of
-- mappings. Accept both, plus the Go and Pascal-cased field names.
local function normalizePorts(value, out)
  out = out or {}
  if type(value) == "string" then
    for spec in string.gmatch(value, "[^,]+") do
      parsePortSpec(out, spec)
    end
  elseif type(value) == "table" then
    for _, mapping in ipairs(value) do
      if type(mapping) == "table" then
        local hostPort = tonumber(mapping.host_port or mapping.hostPort)
        local containerPort = tonumber(mapping.container_port or mapping.containerPort)
        local protocol = tostring(mapping.protocol or "tcp")
        local hostIp = tostring(mapping.host_ip or mapping.hostIP or "")
        if hostPort ~= nil and containerPort ~= nil and protocol == "tcp" then
          out[#out + 1] = buildPort(hostIp, hostPort, containerPort, protocol)
        end
      end
    end
  end
  return out
end

local function firstString(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    for _, entry in ipairs(value) do
      if type(entry) == "string" then
        return entry
      end
    end
  end
  return ""
end

local function countPublished(ports)
  local count = 0
  for _, port in ipairs(ports) do
    if port.internal ~= true then
      count = count + 1
    end
  end
  return count
end

-- Prefer a host-published URL for the headline link, but fall back to a
-- container-local one: clicking the card should always open something.
local function firstPublishedUrl(ports)
  local fallback = ""
  for _, port in ipairs(ports) do
    if port.internal ~= true then
      return port.url
    end
    if fallback == "" then
      fallback = port.url
    end
  end
  return fallback
end

local function normalizeContainer(raw, runtimeId, internal)
  local id = tostring(raw.ID or raw.Id or "")
  local name = firstString(raw.Names or raw.Name or "")
  name = (name:gsub("^/+", ""))
  if name == "" then
    name = id
  end

  local state = string.lower(tostring(raw.State or raw.state or ""))
  local status = tostring(raw.Status or raw.status or "")
  if status == "" then
    status = state
  end

  local ports = normalizePorts(raw.Ports or raw.ports)

  -- Nothing published to the host does not mean nothing listening: fall back to
  -- the container's own namespace, addressed by its bridge IP. Those ports are
  -- marked internal so the panel can tell the user they are container-local.
  if #ports == 0 and internal ~= nil and state == "running" then
    local found = internal[name]
    if found ~= nil and found.ip ~= nil and found.ip ~= "" then
      for _, port in ipairs(found.ports) do
        ports[#ports + 1] = buildPort(found.ip, port, port, "tcp")
        ports[#ports].internal = true
      end
    end
  end

  local container = {
    key = runtimeId .. ":" .. name,
    id = id,
    name = name,
    image = tostring(raw.Image or raw.image or ""),
    state = state,
    status = status,
    runtime = runtimeId,
    running = state == "running",
    webCount = #ports,
    ports = ports,
    -- An internal port is a real web UI, but not a host-published one: it is
    -- listed and clickable yet kept out of the "with a web UI" headline.
    publishedCount = countPublished(ports),
    webUrl = firstPublishedUrl(ports),
  }

  table.insert(collected[runtimeId].containers, container)
end

-- ---------------------------------------------------------------------------
-- Command output
-- ---------------------------------------------------------------------------

-- docker emits newline-delimited JSON objects, podman emits one JSON array.
local function splitLines(text)
  local lines = {}
  local start = 1
  while start <= #text do
    local newline = string.find(text, "\n", start, true)
    if newline == nil then
      lines[#lines + 1] = text:sub(start)
      break
    end
    lines[#lines + 1] = text:sub(start, newline - 1)
    start = newline + 1
  end
  return lines
end

-- `ps` output, with the internal-port section split off: those lines follow the
-- marker and are not JSON.
local function splitInternal(text)
  local psText = ""
  local internal = {}
  local inInternal = false

  for _, line in ipairs(splitLines(text)) do
    if line == MARKER_INTERNAL then
      inInternal = true
    elseif inInternal then
      internal[#internal + 1] = line
    else
      psText = psText .. line .. "\n"
    end
  end
  return psText, internal
end

-- `name|ip|port,port,` -> name -> { ip, { ports } }
local function parseInternal(lines)
  local byName = {}
  for _, line in ipairs(lines) do
    local name, ip, ports = line:match("^([^|]*)|([^|]*)|(.*)$")
    if name ~= nil and name ~= "" and ports ~= nil and ports ~= "" then
      local list = {}
      for port in ports:gmatch("(%d+)") do
        list[#list + 1] = tonumber(port)
      end
      if #list > 0 then
        byName[name] = { ip = ip, ports = list }
      end
    end
  end
  return byName
end

local function parseOutput(text)
  local raws = {}
  local trimmed = trim(text)
  if trimmed == "" then
    return raws
  end

  if trimmed:sub(1, 1) == "[" then
    local decoded = noctalia.json.decode(trimmed)
    if type(decoded) == "table" then
      for _, raw in ipairs(decoded) do
        if type(raw) == "table" then
          raws[#raws + 1] = raw
        end
      end
    end
    return raws
  end

  for _, line in ipairs(splitLines(text)) do
    local candidate = trim(line)
    if candidate ~= "" then
      local decoded = noctalia.json.decode(candidate)
      if type(decoded) == "table" then
        raws[#raws + 1] = decoded
      end
    end
  end
  return raws
end

-- A container that publishes nothing (`docker ps` shows an empty `Ports`) still
-- runs a web UI: it listens inside its own network namespace, reachable from the
-- host on the container's bridge IP. That is invisible to `ps`, so read the
-- listening sockets out of the container's /proc/<pid>/net and pair each one with
-- the container IP. Only wildcard binds are reported: a bind on 127.0.0.1 inside
-- the namespace is not reachable from the host.
--
-- One `for` over the container ids, one inspect and two awk reads each, appended
-- after the ps output behind a marker so one command still fills the whole list.
local function internalProbe(cli)
  -- Long-bracket string so the shell and awk quoting survives verbatim. Every
  -- ' is literal here; the awk program is single-quoted for the shell.
  local script = [==[
for c in $(@@CLI@@ ps -q 2>/dev/null); do
  line=$(@@CLI@@ inspect -f '{{.State.Pid}}|{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}|{{.Name}}' "$c" 2>/dev/null) || continue
  pid=$(printf '%s' "$line" | cut -d'|' -f1)
  ip=$(printf '%s' "$line" | cut -d'|' -f2)
  name=$(printf '%s' "$line" | cut -d'|' -f3)
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  [ "$pid" -gt 0 ] 2>/dev/null || continue
  ports=$(awk 'FNR>1 && $4=="0A" {split($2,a,":"); if (a[1]=="00000000" || a[1]=="00000000000000000000000000000000") printf "%s,", strtonum("0x" a[2])}' "/proc/$pid/net/tcp" "/proc/$pid/net/tcp6" 2>/dev/null)
  [ -n "$ports" ] || continue
  echo "${name#/}|$ip|$ports"
done
]==]
  script = script:gsub("@@CLI@@", cli):gsub("@@MARK@@", MARKER_INTERNAL)
  return script
end

local function commandFor(runtimeId)
  local parts = {}
  if settings.command_prefix ~= "" then
    parts[#parts + 1] = settings.command_prefix
  end
  if runtimeId == "host" then
    -- One detached command, three sections: listening sockets, system units,
    -- user units. Sockets are optional because without root `ss` cannot name
    -- the owner of another user's sockets - the host list is then just the
    -- services it did manage to see.
    parts[#parts + 1] = table.concat({
      "{ ss -ltnpH 2>/dev/null || ss -ltnp 2>/dev/null; }; ",
      "echo '", MARKER_UNITS, "'; ",
      "systemctl show --no-pager --property=Id --property=Description --property=SubState --property=MainPID '*.service' 2>/dev/null; ",
      "echo '", MARKER_USER_UNITS, "'; ",
      "systemctl --user show --no-pager --property=Id --property=Description --property=SubState --property=MainPID '*.service' 2>/dev/null",
    }, "")
    return table.concat(parts, " ")
  end
  local cli = runtimeId == "podman" and "podman" or "docker"
  local probeCli = settings.command_prefix ~= "" and (settings.command_prefix .. " " .. cli) or cli
  parts[#parts + 1] = cli .. " ps"
  if runtimeId == "podman" then
    parts[#parts + 1] = "--format json"
  else
    parts[#parts + 1] = "--format '{{json .}}'"
  end
  if settings.show_stopped then
    parts[#parts + 1] = "-a"
  end
  -- One marker opens the internal section; the probe then emits bare
  -- name|ip|ports lines.
  parts[#parts + 1] = "&& { echo '" .. MARKER_INTERNAL .. "'; " .. internalProbe(probeCli) .. " }"
  return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Host services
-- ---------------------------------------------------------------------------

-- `ss -ltnpH` prints `LISTEN 0 0 127.0.0.1:8888 0.0.0.0:* users:(("web",pid=42,fd=7))`,
-- and `-ltnp` (the fallback) adds a header line, which the LISTEN test drops.
local function socketOwner(line)
  local users = line:match("users:%((.+)%)")
  if users == nil then
    return nil
  end
  local candidate = nil
  for name, pidStr in users:gmatch('%("([^"]*)",pid=(%d+)') do
    local pid = tonumber(pidStr)
    if pid ~= nil and not HOST_SKIP_PROCESSES[name] then
      if candidate == nil or pid < candidate.pid then
        candidate = { process = name, pid = pid }
      end
    end
  end
  return candidate
end

local function parseSockets(text)
  local sockets = {}
  for _, line in ipairs(splitLines(text)) do
    if line:sub(1, 7) == "LISTEN " then
      local address = line:match("^%S+%s+%S+%s+%S+%s+(%S+)")
      local hostIp, portText = address:match("^(.*):(%d+[%-%d]*)$")
      local port = tonumber(portText)
      local owner = socketOwner(line)
      -- Without the owning pid there is no way to name the service, and a
      -- link-local or zone scoped address is not something to open anyway.
      if port ~= nil and hostIp ~= nil and owner ~= nil then
        if hostIp:sub(1, 1) == "[" and hostIp:sub(-1, -1) == "]" then
          hostIp = hostIp:sub(2, -2)
        end
        if hostIp:sub(1, 4):lower() ~= "fe80" and hostIp:find("%", 1, true) == nil then
          sockets[#sockets + 1] = {
            hostIp = hostIp,
            hostPort = port,
            process = owner.process,
            pid = owner.pid,
          }
        end
      end
    end
  end
  return sockets
end

-- systemd prints one `key=value` per line, one blank line between units.
local function parseUnits(text)
  local byPid = {}
  local current = nil
  for _, line in ipairs(splitLines(text)) do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key == nil then
      current = nil
    elseif key == "Id" then
      current = { id = value, description = "", mainPid = 0 }
    elseif current ~= nil then
      if key == "Description" then
        current.description = value
      elseif key == "MainPID" then
        current.mainPid = tonumber(value) or 0
      elseif key == "SubState" and value ~= "running" then
        current = nil
      end
    end
    if current ~= nil and current.mainPid > 0 and byPid[current.mainPid] == nil then
      byPid[current.mainPid] = current
    end
  end
  return byPid
end

-- One row per listening process, not per socket: a service bound to several
-- addresses shows one card with one chip per port.
local function hostEntries(sockets, unitsByPid)
  local entries = {}
  local byPid = {}

  for _, socket in ipairs(sockets) do
    if not HOST_SKIP_PROCESSES[socket.process] then
      local entry = byPid[socket.pid]
      if entry == nil then
        entry = {
          pid = socket.pid,
          process = socket.process,
          bindings = {},
          byPort = {},
        }
        byPid[socket.pid] = entry
        entries[#entries + 1] = entry
      end
      local seen = entry.byPort[socket.hostPort]
      if seen == nil then
        entry.byPort[socket.hostPort] = socket.hostIp
        entry.bindings[#entry.bindings + 1] = { hostIp = socket.hostIp, hostPort = socket.hostPort }
      elseif localAddress(socket.hostIp) and not localAddress(seen) then
        -- Prefer a loopback or wildcard binding: it links through open_host.
        entry.byPort[socket.hostPort] = socket.hostIp
        for _, binding in ipairs(entry.bindings) do
          if binding.hostPort == socket.hostPort then
            binding.hostIp = socket.hostIp
          end
        end
      end
    end
  end

  table.sort(entries, function(a, b)
    return a.process:lower() < b.process:lower()
  end)

  local result = {}
  for _, entry in ipairs(entries) do
    table.sort(entry.bindings, function(a, b)
      return a.hostPort < b.hostPort
    end)

    local ports = {}
    for _, binding in ipairs(entry.bindings) do
      ports[#ports + 1] = buildPort(binding.hostIp, binding.hostPort, binding.hostPort, "tcp")
    end

    local unit = unitsByPid[entry.pid]
    local name = entry.process
    local description = ""
    if unit ~= nil then
      name = unit.id:gsub("%.service$", "")
      description = unit.description
    end
    name = name:gsub("^%.", "")
    if name == "" then
      name = "pid-" .. tostring(entry.pid)
    end

    result[#result + 1] = {
      pid = entry.pid,
      name = name,
      description = description,
      ports = ports,
    }
  end
  return result
end

local function addHostServices(text)
  local socketLines = {}
  local unitText = ""
  local userUnitText = ""
  local section = "sockets"

  for _, line in ipairs(splitLines(text)) do
    if line == MARKER_UNITS then
      section = "units"
    elseif line == MARKER_USER_UNITS then
      section = "user"
    elseif section == "sockets" then
      socketLines[#socketLines + 1] = line
    elseif section == "user" then
      userUnitText = userUnitText .. line .. "\n"
    else
      unitText = unitText .. line .. "\n"
    end
  end

  local units = parseUnits(unitText)
  -- User units name the same pids; system units win on a clash.
  for pid, unit in pairs(parseUnits(userUnitText)) do
    if units[pid] == nil then
      units[pid] = unit
    end
  end

  for _, entry in ipairs(hostEntries(parseSockets(table.concat(socketLines, "\n")), units)) do
    table.insert(collected.host.containers, {
      key = "host:" .. tostring(entry.pid) .. ":" .. entry.name,
      id = tostring(entry.pid),
      name = entry.name,
      -- The panel's second line: the unit description, or the pid when
      -- systemd does not know the process.
      image = entry.description ~= "" and entry.description or ("pid " .. tostring(entry.pid)),
      state = "running",
      -- Left empty on purpose: the panel falls back to the state, and the port
      -- chips already show how many there are.
      status = "",
      runtime = "host",
      running = true,
      webCount = #entry.ports,
      ports = entry.ports,
      webUrl = entry.ports[1] ~= nil and entry.ports[1].url or "",
    })
  end
end

local function handleResult(runtimeId, result)
  local info = collected[runtimeId]
  info.available = true

  if result == nil then
    runtimeErrors[runtimeId] = "panel.runtime.error"
    return
  end
  if result.timedOut == true then
    runtimeErrors[runtimeId] = "panel.runtime.error"
    return
  end
  if numberOr(result.exitCode, 1) ~= 0 then
    -- For a runtime this is almost always "no socket / permission denied".
    local stderr = trim(result.stderr)
    if stderr ~= "" then
      noctalia.log(string.format("containers: %s failed: %s", runtimeId, stderr))
    end
    runtimeErrors[runtimeId] = runtimeId == "host" and "panel.runtime.error" or "panel.runtime.nodaemon"
    return
  end

  if runtimeId == "host" then
    addHostServices(result.stdout or "")
    return
  end

  local psText, internalLines = splitInternal(result.stdout or "")
  local internal = parseInternal(internalLines)
  local raws = parseOutput(psText)
  for _, raw in ipairs(raws) do
    normalizeContainer(raw, runtimeId, internal)
  end
end

-- ---------------------------------------------------------------------------
-- Publishing
-- ---------------------------------------------------------------------------

local function publish()
  local runtimes = {}
  local total = 0
  local running = 0
  local web = 0

  for _, runtimeId in ipairs(activeRuntimes()) do
    local meta = RUNTIMES[runtimeId]
    local info = collected[runtimeId]
    if info ~= nil then
      local errorKey = runtimeErrors[runtimeId] or ""
      local containers = info.containers or {}

      table.sort(containers, function(a, b)
        if a.running ~= b.running then
          return a.running
        end
        return a.name:lower() < b.name:lower()
      end)

      local webCount = 0
      local runtimeRunning = 0
      for _, container in ipairs(containers) do
        total = total + 1
        if container.running then
          running = running + 1
          runtimeRunning = runtimeRunning + 1
        end
        -- A container-local-only UI is still a web UI the user can open, so it
        -- counts. publishedCount tracks the host-published subset separately.
        if container.running and container.webCount > 0 then
          webCount = webCount + 1
          web = web + 1
        end
      end

      runtimes[#runtimes + 1] = {
        id = runtimeId,
        label = noctalia.tr(meta.labelKey),
        glyph = meta.glyph,
        available = info.available ~= false,
        errorKey = errorKey,
        emptyKey = meta.emptyKey or "panel.empty.body",
        count = #containers,
        runningCount = runtimeRunning,
        webCount = webCount,
        containers = containers,
      }
    end
  end

  snapshot = {
    total = total,
    running = running,
    web = web,
    updatedAt = os.time(),
    runtimes = runtimes,
  }
  noctalia.state.set(KEY_SNAPSHOT, snapshot)
end

local function finish()
  outstanding = outstanding - 1
  if outstanding > 0 then
    return
  end
  outstanding = 0
  publish()
end

local function refresh()
  if outstanding > 0 then
    return
  end

  local runtimes = activeRuntimes()
  generation = generation + 1
  local mine = generation
  outstanding = #runtimes
  collected = {}
  runtimeErrors = {}

  for _, runtimeId in ipairs(runtimes) do
    collected[runtimeId] = { available = true, containers = {} }

    if runtimeAvailable(runtimeId) then
      noctalia.runAsync(commandFor(runtimeId), function(result)
        if mine ~= generation then
          return
        end
        handleResult(runtimeId, result)
        finish()
      end)
    else
      collected[runtimeId].available = false
      runtimeErrors[runtimeId] = "panel.runtime.missing"
      finish()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Entry lifecycle
-- ---------------------------------------------------------------------------

readSettings()
snapshot = noctalia.state.get(KEY_SNAPSHOT)
noctalia.setUpdateInterval(TICK_MS)

-- The widget and the panel ask for an immediate refresh by bumping a counter.
noctalia.state.watch(KEY_REFRESH_NONCE, function(_value)
  refresh()
end)

function update()
  tickCount = tickCount + 1
  if tickCount % intervalTicks() ~= 0 then
    return
  end
  refresh()
end

function onConfigChanged()
  readSettings()
  refresh()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  end
end

-- First refresh as soon as the runtime is live, so the panel is never empty
-- while the first interval elapses.
refresh()
