--!nonstrict
-- service.luau
-- Headless service: keeps the host list (IP, hostname or link — each with
-- an optional label), pings every entry, measures latency, and notifies
-- on the up -> down transition (and, when enabled, down -> up).
--
-- Persistence: pluginDataDir()/state.json ({ ips = { {ip=, label=}, ... } })
-- State: link_ip_monitor.statuses   = { {ip=, label=, status=, latency_ms=}, ... }
--        link_ip_monitor.down_count = number
-- Panel commands: ip_monitor.cmd =
--   { op = "add"|"remove"|"refresh"|"reorder", ip = "...", label? = "...", index? = N }

local ipList      = {} -- { {ip=, label=}, ... } — "ip" here is the already-normalized host (no scheme/port/path)
local hostState   = {} -- host -> true (up) / false (down) / nil (not checked yet)
local hostLatency = {} -- host -> latency in ms (number) / nil
local dataPath    = nil

local function trim(s)
  return noctalia.string.trim(s or "")
end

-- Validates IPv4 in N.N.N.N form, each octet between 0 and 255.
local function isValidIPv4(host)
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return false
  end
  for _, n in ipairs({ a, b, c, d }) do
    local num = tonumber(n)
    if num == nil or num < 0 or num > 255 then
      return false
    end
  end
  return true
end

-- Validates a hostname (dot-separated labels, letters/digits/hyphen, no
-- leading/trailing hyphen per label).
local function isValidHostname(host)
  if host == "" or #host > 253 then
    return false
  end
  local labelCount = 0
  for label in host:gmatch("[^%.]+") do
    labelCount = labelCount + 1
    if #label == 0 or #label > 63 then
      return false
    end
    if not label:match("^%w[%w%-]*%w$") and not label:match("^%w$") then
      return false
    end
  end
  return labelCount > 0
end

-- Accepts an IP, a plain hostname, or a link (http://..., https://...)
-- and returns just the host — scheme, port, path and query are dropped.
-- That clean host is what actually becomes the ping target (ping doesn't
-- understand a full URL).
local function extractHost(raw)
  local s = trim(raw)
  s = s:gsub("^%a[%w+.-]*://", "") -- strip a scheme like http:// or https://
  s = s:match("^([^/%?#]+)") or s  -- cut path/query/fragment
  s = s:match("^([^:]+)") or s     -- cut an explicit port (host:port)
  return s
end

local function normalizeHost(raw)
  local host = extractHost(raw)
  if host == "" then
    return nil
  end
  if isValidIPv4(host) or isValidHostname(host) then
    return host
  end
  return nil
end

local function indexOfIp(ip)
  for i, entry in ipairs(ipList) do
    if entry.ip == ip then
      return i
    end
  end
  return nil
end

local function loadState()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return
  end
  dataPath = dir .. "/state.json"

  local raw = noctalia.readFile(dataPath)
  if raw ~= nil then
    local ok, decoded = pcall(noctalia.json.decode, raw)
    if ok and type(decoded) == "table" and type(decoded.ips) == "table" then
      for _, entry in ipairs(decoded.ips) do
        if type(entry) == "table" and type(entry.ip) == "string" then
          table.insert(ipList, { ip = entry.ip, label = trim(entry.label) })
        elseif type(entry) == "string" then
          -- backward compatibility with the old format (list of plain strings, no label)
          table.insert(ipList, { ip = entry, label = "" })
        end
      end
    end
  end
  -- no file yet (first run): ipList stays empty until the user adds
  -- something from the panel.
end

local function saveState()
  if dataPath == nil then
    return
  end
  local ok, encoded = pcall(noctalia.json.encode, { ips = ipList })
  if ok and type(encoded) == "string" then
    pcall(noctalia.writeFile, dataPath, encoded)
  end
end

local function publishState()
  local statuses = {}
  local downCount = 0

  for _, entry in ipairs(ipList) do
    local up = hostState[entry.ip]
    local status
    if up == true then
      status = "up"
    elseif up == false then
      status = "down"
      downCount = downCount + 1
    else
      status = "checking"
    end

    table.insert(statuses, {
      ip         = entry.ip,
      label      = entry.label,
      status     = status,
      latency_ms = (status == "up") and hostLatency[entry.ip] or nil,
    })
  end

  noctalia.state.set("link_ip_monitor.statuses", statuses)
  noctalia.state.set("link_ip_monitor.down_count", downCount)
end

local function checkHost(entry)
  local ip = entry.ip
  local timeout = noctalia.getConfig("timeout_seconds") or 1
  -- -c 1: send 1 packet; -W: timeout in seconds (iputils/Linux). ping
  -- resolves a hostname via DNS normally, so a host like "example.com"
  -- (extracted from a link) works just like an IP.
  local cmd = string.format("ping -c 1 -W %d %s", timeout, ip)

  noctalia.runAsync(cmd, function(res)
    local success = res.exitCode == 0

    local latency = nil
    if success and type(res.stdout) == "string" then
      -- Ignores the word before "=" or "<" (time=, tempo=, temps=...) —
      -- ping's output changes with the system locale. Only looks for the
      -- number that comes right before "ms".
      local ms = res.stdout:match("[=<]%s*(%d+%.?%d*)%s*ms")
      latency = ms and tonumber(ms) or nil
    end

    local wasUp = hostState[ip]
    hostState[ip] = success
    hostLatency[ip] = latency

    if wasUp ~= success then
      local display = (entry.label ~= "" and entry.label) or ip
      if success == false then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notify.host_down", { host = display }))
      elseif wasUp == false and success == true and noctalia.getConfig("notify_on_recovery") then
        noctalia.notify(noctalia.tr("title"), noctalia.tr("notify.host_up", { host = display }))
      end
    end

    publishState()
  end, (timeout + 2) * 1000)
end

local function checkAll()
  for _, entry in ipairs(ipList) do
    checkHost(entry)
  end
end

local function applyInterval()
  local seconds = noctalia.getConfig("interval_seconds") or 30
  noctalia.setUpdateInterval(seconds * 1000)
end

-- Returns ok, reason ("invalid" | "duplicate") on failure.
local function addIp(raw, label)
  local host = normalizeHost(raw)
  if host == nil then
    return false, "invalid"
  end
  if indexOfIp(host) ~= nil then
    return false, "duplicate"
  end
  local entry = { ip = host, label = trim(label) }
  table.insert(ipList, entry)
  saveState()
  publishState()
  checkHost(entry)
  return true
end

local function removeIp(ip)
  local idx = indexOfIp(ip)
  if idx ~= nil then
    table.remove(ipList, idx)
  end
  hostState[ip] = nil
  hostLatency[ip] = nil
  saveState()
  publishState()
end

-- Moves `ip` to 1-based position `index` in the final list (drag and drop
-- in the panel) — same logic as the official world_clock's reorderZone().
local function reorderIp(ip, index)
  local fromIdx = indexOfIp(ip)
  if fromIdx == nil then
    return false
  end
  local insertAt = tonumber(index)
  if insertAt == nil then
    return false
  end
  local entry = table.remove(ipList, fromIdx)
  if fromIdx < insertAt then
    insertAt -= 1
  end
  insertAt = math.max(1, math.min(insertAt, #ipList + 1))
  table.insert(ipList, insertAt, entry)
  saveState()
  publishState()
  return true
end

-- ---------------------------------------------------------------------------
-- Commands coming from the panel, via noctalia.state (same pattern as the
-- official world_clock: the panel sets "ip_monitor.cmd", the service
-- watches it, processes it, and clears it back to nil).
-- ---------------------------------------------------------------------------

noctalia.state.watch("link_ip_monitor.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "add" then
    local ok, reason = addIp(cmd.ip, cmd.label)
    if not ok then
      local display = tostring(cmd.ip or "")
      if reason == "invalid" then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notify.invalid_host", { host = display }))
      elseif reason == "duplicate" then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("notify.duplicate_host", { host = display }))
      end
    end
  elseif op == "remove" then
    removeIp(cmd.ip)
  elseif op == "reorder" then
    reorderIp(cmd.ip, cmd.index)
  elseif op == "refresh" then
    checkAll()
  end
  noctalia.state.set("link_ip_monitor.cmd", nil)
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

loadState()
applyInterval()
publishState()
checkAll()

function update()
  checkAll()
end

function onConfigChanged()
  applyInterval()
end

-- Still works via CLI too, if needed:
--   noctalia msg plugin nilsonlinux/link-ip-monitor:monitor all refresh
function onIpc(event, payload)
  if event == "refresh" then
    checkAll()
  elseif event == "add" and payload then
    addIp(payload, "")
  elseif event == "remove" and payload then
    removeIp(payload)
  end
end
