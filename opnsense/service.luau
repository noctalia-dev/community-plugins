--!nonstrict
-- OPNsense API backend: system status, interfaces, gateways, services.

local STATE_KEY = "opn_snapshot"
local COMMAND_KEY = "opn_command"
local RESULT_KEY = "opn_action_result"

-- Tail this many firewall log events when the Logs tab asks for them.
local LOG_LIMIT = 100
-- If any HTTP callback aborts (CPU budget), clear loading after this.
local STUCK_REFRESH_SEC = 12
local STUCK_LOGS_SEC = 35

-- Published state. `instances` holds one entry per firewall; the top-level
-- counters are the aggregate the bar widget shows.
local snapshot = {
  available = false,
  configured = false,
  loading = true,
  logsLoading = false,
  busy = false,
  host = "",
  error = "",
  instances = {},
  issueCount = 0,
  okCount = 0,
  updatedAt = 0,
  revision = 0,
}

-- One entry per firewall: config + runtime bookkeeping (`pending`, `generation`,
-- `startedAt`, `logsPending`, `prevIssues`) + `data` (what gets published).
-- Rebuilt only when the settings change.
local instances = {}
local configGeneration = 0
local configSignature = ""
local configError = ""
local actionBusy = false
local dataSignature = ""

local function newInstanceData()
  return {
    available = false,
    loading = true,
    logsLoading = false,
    error = "",
    widgets = {},
    interfaces = {},
    gateways = {},
    services = {},
    rules = {},
    logs = {},
    info = {},
    resources = {},
    issueCount = 0,
    okCount = 0,
    blockLogCount = 0,
    updatedAt = 0,
  }
end

local function trim(value)
  return noctalia.string.trim(tostring(value or ""))
end

local function lower(s)
  return string.lower(tostring(s or ""))
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

local function refreshIntervalMs()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or 20
  seconds = math.max(5, math.min(300, math.floor(seconds)))
  return seconds * 1000
end

local function updateRevision(signature)
  if signature ~= dataSignature then
    dataSignature = signature
    snapshot.revision += 1
  end
end

local function instanceOutput(inst)
  local data = inst.data
  return {
    id = inst.id,
    name = inst.name,
    host = inst.host,
    url = inst.url,
    webUi = inst.webUi,
    available = data.available,
    loading = data.loading,
    logsLoading = data.logsLoading,
    error = data.error,
    widgets = data.widgets,
    interfaces = data.interfaces,
    gateways = data.gateways,
    services = data.services,
    rules = data.rules,
    logs = data.logs,
    info = data.info,
    resources = data.resources,
    issueCount = data.issueCount,
    okCount = data.okCount,
    blockLogCount = data.blockLogCount,
    updatedAt = data.updatedAt,
  }
end

local function publishSnapshot()
  local out = {}
  local signature = {}
  local issues, oks, updated = 0, 0, 0
  local loading, logsLoading, available = false, false, false
  local firstError = ""

  for _, inst in ipairs(instances) do
    local entry = instanceOutput(inst)
    table.insert(out, entry)
    issues += entry.issueCount
    oks += entry.okCount
    updated = math.max(updated, entry.updatedAt)
    loading = loading or entry.loading
    logsLoading = logsLoading or entry.logsLoading
    available = available or entry.available
    if firstError == "" and entry.error ~= "" and not entry.available then
      firstError = #instances > 1 and (entry.name .. ": " .. entry.error) or entry.error
    end
    table.insert(signature, table.concat({
      entry.id,
      tostring(entry.issueCount),
      tostring(#entry.interfaces),
      tostring(#entry.gateways),
      tostring(#entry.services),
      tostring(#entry.rules),
      tostring(#entry.logs),
    }, ":"))
  end
  updateRevision(table.concat(signature, "|"))

  local configured = #instances > 0
  snapshot.instances = out
  snapshot.configured = configured
  snapshot.available = available
  snapshot.loading = loading
  snapshot.logsLoading = logsLoading
  snapshot.busy = actionBusy
  snapshot.issueCount = issues
  snapshot.okCount = oks
  snapshot.updatedAt = updated
  snapshot.host = configured
    and (#instances == 1 and instances[1].host or noctalia.tr("panel.host_count", { n = #instances }))
    or ""
  snapshot.error = configured and firstError
    or (configError ~= "" and configError or noctalia.tr("result.not_configured"))
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

local function normalizeUrl(value)
  local url = trim(value)
  url = url:gsub("/+$", "")
  url = url:gsub("/api$", "")
  return url
end

local function hostOf(url)
  return url:match("^https?://([^/:]+)") or url
end

-- Global fallback for instances that do not set `insecure` themselves.
local function defaultInsecure()
  return noctalia.getConfig("allow_insecure_tls") ~= false
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

local function shellQuote(v)
  return "'" .. tostring(v):gsub("'", "'\\''") .. "'"
end

local function findInstance(idOrName)
  local want = lower(trim(idOrName))
  if want == "" then
    return nil
  end
  for _, inst in ipairs(instances) do
    if lower(inst.id) == want or lower(inst.name) == want or lower(inst.host) == want then
      return inst
    end
  end
  return nil
end

-- `instances` is a JSON array of { name, url, api_key, api_secret, insecure, web_ui_url }.
-- When it is empty the single-firewall settings below the array are used instead.
local function parseInstanceConfig()
  local raw = trim(noctalia.getConfig("instances"))
  local out = {}
  local problem = ""

  if raw ~= "" then
    local decoded, decodeError = noctalia.json.decode(raw)
    if type(decoded) == "table" and type(decoded.url) == "string" then
      decoded = { decoded } -- tolerate a lone object instead of an array
    end
    if type(decoded) ~= "table" then
      problem = noctalia.tr("result.instances_invalid", { error = tostring(decodeError or "not a JSON array") })
    else
      for _, entry in ipairs(decoded) do
        if type(entry) == "table" then
          local url = normalizeUrl(asString(entry.url))
          local key = asString(entry.api_key)
          local secret = asString(entry.api_secret)
          if url == "" or key == "" or secret == "" then
            noctalia.log("opnsense: skipping instance without url/api_key/api_secret: " .. noctalia.json.encode(entry))
          else
            local name = trim(asString(entry.name))
            if name == "" then
              name = hostOf(url)
            end
            local insecure = entry.insecure
            if type(insecure) ~= "boolean" then
              insecure = defaultInsecure()
            end
            local webUi = normalizeUrl(asString(entry.web_ui_url))
            table.insert(out, {
              id = name,
              name = name,
              url = url,
              key = key,
              secret = secret,
              insecure = insecure,
              webUi = webUi ~= "" and webUi or url,
              host = hostOf(url),
            })
          end
        end
      end
      if #out == 0 then
        problem = noctalia.tr("result.instances_invalid", { error = "no usable entries" })
      end
    end
  else
    local url = normalizeUrl(noctalia.getConfig("base_url"))
    local key = trim(noctalia.getConfig("api_key"))
    local secret = trim(noctalia.getConfig("api_secret"))
    if url ~= "" and key ~= "" and secret ~= "" then
      local webUi = normalizeUrl(noctalia.getConfig("web_ui_url"))
      table.insert(out, {
        id = hostOf(url),
        name = hostOf(url),
        url = url,
        key = key,
        secret = secret,
        insecure = defaultInsecure(),
        webUi = webUi ~= "" and webUi or url,
        host = hostOf(url),
      })
    end
  end

  -- Ids address instances (widget target, panel selection, service actions),
  -- so two firewalls with the same name still need distinct ids.
  local seen = {}
  for _, inst in ipairs(out) do
    local id = inst.id
    if seen[id] then
      local n = 2
      while seen[id .. " (" .. n .. ")"] do
        n += 1
      end
      id = id .. " (" .. n .. ")"
      inst.id = id
    end
    seen[id] = true
  end
  return out, problem
end

-- Rebuilds the instance list when the settings change; keeps the collected
-- data of instances that were not edited.
local function syncInstances()
  local parsed, problem = parseInstanceConfig()
  configError = problem

  local parts = {}
  for _, inst in ipairs(parsed) do
    table.insert(parts, table.concat({
      inst.id, inst.url, inst.key, inst.secret, tostring(inst.insecure), inst.webUi,
    }, "\1"))
  end
  local signature = table.concat(parts, "\2")
  if signature == configSignature then
    return
  end
  configSignature = signature
  configGeneration += 1

  local previous = {}
  for _, inst in ipairs(instances) do
    previous[inst.id] = inst
  end
  for _, inst in ipairs(parsed) do
    local old = previous[inst.id]
    if old ~= nil and old.url == inst.url and old.key == inst.key and old.secret == inst.secret then
      inst.data = old.data
      inst.prevIssues = old.prevIssues or {}
    else
      inst.data = newInstanceData()
      inst.prevIssues = {}
    end
    -- Reset bookkeeping: requests in flight for the old list check `configGeneration`.
    inst.pending = 0
    inst.generation = 0
    inst.refreshAgain = false
    inst.startedAt = 0
    inst.logsPending = false
    inst.logsStartedAt = 0
  end
  instances = parsed
  noctalia.log(`opnsense: {#instances} firewall(s) configured`)
end

local function apiRequest(inst, method, path, body, callback)
  local url = inst.url .. "/api/" .. path:gsub("^/+", "")

  local req = {
    url = url,
    method = method or "GET",
    basic_username = inst.key,
    basic_password = inst.secret,
    allow_insecure_tls = inst.insecure,
    headers = { "Accept: application/json" },
  }
  if body ~= nil then
    local encoded = noctalia.json.encode(body)
    req.body = encoded or ""
    table.insert(req.headers, "Content-Type: application/json")
  end

  -- If the user callback throws (or hits CPU budget as an error), still
  -- invoke it via pcall so callers can put cleanup (finish()) outside work.
  local function safeCb(res)
    if type(callback) ~= "function" then
      return
    end
    local okCall, errCall = pcall(callback, res)
    if not okCall then
      noctalia.log(`opnsense: api callback error on {path}: {tostring(errCall)}`)
    end
  end

  local ok = noctalia.http(req, safeCb)
  if not ok then
    safeCb({ ok = false, status = 0, body = "http queue full" })
  end
  return ok
end

local function decodeBody(res)
  if type(res) ~= "table" then
    return nil, "no response"
  end
  if not res.ok and (res.status == 0 or res.status == nil) then
    return nil, trim(res.body) ~= "" and trim(res.body) or "network error"
  end
  if res.status == 401 or res.status == 403 then
    return nil, "auth failed (" .. tostring(res.status) .. ") — check API key and secret"
  end
  if res.status and res.status >= 400 then
    return nil, "HTTP " .. tostring(res.status)
  end
  local body = res.body
  if type(body) ~= "string" or body == "" then
    return {}, nil
  end
  local data, err = noctalia.json.decode(body)
  if data == nil then
    return nil, err or "invalid JSON"
  end
  return data, nil
end

local function isOkStatus(status)
  local s = lower(status)
  if s == "" or s == "ok" or s == "online" or s == "up" or s == "none"
    or s == "running" or s == "active" then
    return true
  end
  if s:find("error", 1, true) or s:find("down", 1, true) or s:find("offline", 1, true)
    or s:find("fail", 1, true) or s:find("crit", 1, true) or s:find("warn", 1, true)
  then
    return false
  end
  return true
end

local function pushWidget(widgets, name, info)
  if type(info) ~= "table" then
    return
  end
  local status = asString(info.status)
  local code = tonumber(info.statusCode or info.status)
  local ok = true
  if type(info.status) == "number" or info.statusCode ~= nil then
    -- OPNsense dashboard: 2 = OK
    ok = (code or 0) == 2
    if status == tostring(code) or status == "" then
      status = ok and "OK" or "Issue"
    end
  else
    ok = isOkStatus(status)
  end
  local title = asString(info.title)
  if title == "" then
    title = tostring(name)
  end
  table.insert(widgets, {
    id = tostring(name),
    name = title,
    status = status ~= "" and status or (ok and "OK" or "Issue"),
    message = asString(info.message),
    statusCode = code,
    ok = ok,
  })
end

local function parseSystemStatus(data)
  local widgets = {}
  if type(data) ~= "table" then
    return widgets
  end
  -- OPNsense 26+: { metadata = { system = { status, message, title }, subsystems = [...] } }
  if type(data.metadata) == "table" then
    local meta = data.metadata
    if type(meta.system) == "table" then
      pushWidget(widgets, "System", meta.system)
    end
    if type(meta.subsystems) == "table" then
      for i, sub in ipairs(meta.subsystems) do
        if type(sub) == "table" then
          pushWidget(widgets, asString(sub.name or sub.title or ("sub-" .. i)), sub)
        end
      end
    end
    -- other metadata keys that look like widgets
    for name, info in pairs(meta) do
      if name ~= "system" and name ~= "subsystems" and name ~= "translations" and type(info) == "table" then
        if info.status ~= nil or info.message ~= nil or info.statusCode ~= nil then
          pushWidget(widgets, name, info)
        end
      end
    end
  else
    -- older shape: top-level named widgets
    for name, info in pairs(data) do
      if type(info) == "table" and (info.status ~= nil or info.message ~= nil or info.statusCode ~= nil) then
        pushWidget(widgets, name, info)
      end
    end
  end
  table.sort(widgets, function(a, b)
    if a.ok ~= b.ok then
      return not a.ok
    end
    return a.name < b.name
  end)
  return widgets
end

local function formatBytes(n)
  n = tonumber(n) or 0
  if n >= 1e12 then return string.format("%.1fT", n / 1e12) end
  if n >= 1e9 then return string.format("%.1fG", n / 1e9) end
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
  return tostring(math.floor(n))
end

local function parseInterfaces(statsData, namesData)
  local nameMap = {}
  if type(namesData) == "table" then
    for k, v in pairs(namesData) do
      if type(v) == "string" then
        nameMap[tostring(k)] = v
      elseif type(v) == "table" then
        nameMap[tostring(k)] = asString(v.descr or v.description or v.name or k)
      end
    end
  end

  local list = {}
  local stats = statsData
  if type(statsData) == "table" and type(statsData.statistics) == "table" then
    stats = statsData.statistics
  end
  if type(stats) ~= "table" then
    return list
  end

  -- Aggregate rows that share the same interface device (OPNsense emits one row per address).
  local byDev = {}
  for label, row in pairs(stats) do
    if type(row) == "table" then
      local dev = asString(row.name)
      if dev == "" then
        dev = tostring(label)
      end
      local entry = byDev[dev]
      if not entry then
        local flags = asString(row.flags)
        -- FreeBSD IFF_UP is 0x1
        local flagNum = tonumber(flags) or tonumber(flags:match("0x(%x+)"), 16) or 0
        local up = (flagNum % 2 == 1) or lower(flags):find("up", 1, true) ~= nil
        -- Prefer friendly label from statistics key: "[WAN] (vtnet0) / …"
        local descr = tostring(label):match("^%[(.-)%]") or nameMap[dev] or ""
        entry = {
          id = dev,
          name = dev,
          description = descr,
          status = up and "up" or "down",
          ok = up,
          ipv4 = "",
          ipv6 = "",
          inBytesRaw = 0,
          outBytesRaw = 0,
        }
        byDev[dev] = entry
      end
      local addr = asString(row.address)
      if addr:match("^%d+%.%d+%.%d+%.%d+$") and entry.ipv4 == "" then
        entry.ipv4 = addr
      elseif addr:find(":", 1, true) and not addr:find("^%d+%.%d+") and entry.ipv6 == "" and not lower(addr):find("fe80", 1, true) then
        entry.ipv6 = addr
      end
      -- Prefer link-level counters (largest) when present
      local rin = tonumber(row["received-bytes"] or row["bytes received"] or row.bytes_received or row.inbytes) or 0
      local rout = tonumber(row["sent-bytes"] or row["bytes transmitted"] or row.bytes_transmitted or row.outbytes) or 0
      if rin > entry.inBytesRaw then entry.inBytesRaw = rin end
      if rout > entry.outBytesRaw then entry.outBytesRaw = rout end
    end
  end

  for _, entry in pairs(byDev) do
    entry.inBytes = formatBytes(entry.inBytesRaw)
    entry.outBytes = formatBytes(entry.outBytesRaw)
    entry.inBytesRaw = nil
    entry.outBytesRaw = nil
    table.insert(list, entry)
  end
  table.sort(list, function(a, b)
    if a.ok ~= b.ok then return not a.ok end
    return a.name < b.name
  end)
  return list
end

local function parseGateways(data)
  local list = {}
  local rows = data
  if type(data) == "table" and type(data.items) == "table" then
    rows = data.items
  elseif type(data) == "table" and type(data.gateways) == "table" then
    rows = data.gateways
  end
  if type(rows) ~= "table" then
    return list
  end

  local function addGw(name, row)
    if type(row) ~= "table" then return end
    local status = asString(row.status_translated or row.status or "")
    local ok = true
    if status ~= "" then
      local st = lower(status)
      ok = st == "online" or st == "none" or st == "ok"
    end
    table.insert(list, {
      id = tostring(name),
      name = tostring(name),
      status = status ~= "" and status or (ok and "online" or "down"),
      ok = ok,
      address = asString(row.address or row.gateway or ""),
      monitor = asString(row.monitor or ""),
      rtt = asString(row.delay or row.rtt or ""),
      loss = asString(row.loss or ""),
    })
  end

  if rows[1] ~= nil then
    for _, row in ipairs(rows) do
      addGw(asString(row.name or row.gateway or "gateway"), row)
    end
  else
    for name, row in pairs(rows) do
      addGw(name, row)
    end
  end
  table.sort(list, function(a, b)
    if a.ok ~= b.ok then return not a.ok end
    return a.name < b.name
  end)
  return list
end

local function parseServices(data)
  local list = {}
  local rows = data
  if type(data) == "table" and type(data.rows) == "table" then
    rows = data.rows
  end
  if type(rows) ~= "table" then
    return list
  end
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local name = asString(row.name or row.id)
      local running = row.running == true or row.running == 1 or asString(row.running) == "1"
        or lower(asString(row.status)) == "running"
      table.insert(list, {
        id = name,
        name = name,
        running = running,
        status = running and "running" or "stopped",
        ok = true,
        description = asString(row.description or row.desc or ""),
      })
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local function parseInfo(infoData, resData, timeData)
  local info = {}
  if type(infoData) == "table" then
    info.hostname = asString(infoData.name or infoData.hostname)
    if type(infoData.versions) == "table" and infoData.versions[1] then
      info.version = asString(infoData.versions[1])
    else
      info.version = asString(infoData.version or infoData.product_version)
    end
    info.updates = asString(infoData.updates or "")
    info.uptime = asString(infoData.uptime or "")
  end
  if type(timeData) == "table" then
    if info.uptime == "" then info.uptime = asString(timeData.uptime) end
    info.datetime = asString(timeData.datetime or timeData.date)
  end
  local resources = {}
  if type(resData) == "table" then
    resources.load = asString(resData.loadavg or resData.load or "")
    if resources.load == "" and type(resData.cpu) == "table" then
      resources.load = asString(resData.cpu.load or resData.cpu.usage)
    end
    if type(resData.memory) == "table" then
      local used = resData.memory.used_frmt or resData.memory.used
      local total = resData.memory.total_frmt or resData.memory.total
      resources.memoryUsed = asString(used)
      resources.memoryTotal = asString(total)
      if resources.load == "" and resData.memory.used and resData.memory.total then
        local u = tonumber(resData.memory.used) or 0
        local t = tonumber(resData.memory.total) or 1
        resources.load = string.format("mem %.0f%%", (u / t) * 100)
      end
    end
  end
  return info, resources
end

local function countIssues(widgets, gateways)
  local n, ok = 0, 0
  for _, w in ipairs(widgets) do
    if w.ok then ok += 1 else n += 1 end
  end
  for _, g in ipairs(gateways) do
    if not g.ok then n += 1 end
  end
  return n, ok
end

local function parseRules(data)
  local list = {}
  local rows = data
  if type(data) == "table" and type(data.rows) == "table" then
    rows = data.rows
  end
  if type(rows) ~= "table" then
    return list
  end
  for i, row in ipairs(rows) do
    if type(row) == "table" then
      local action = asString(row["%action"] or row.action)
      local direction = asString(row["%direction"] or row.direction)
      local enabled = asString(row.enabled) == "1" or row.enabled == true or row.enabled == 1
      local descr = asString(row.description)
      local src = asString(row.source_net)
      local dst = asString(row.destination_net)
      local sport = asString(row.source_port)
      local dport = asString(row.destination_port)
      local proto = asString(row["%protocol"] or row.protocol)
      local iface = asString(row.interface)
      local automatic = row.is_automatic == true or row.legacy == true
      local uuid = asString(row.uuid)
      if uuid == "" then
        uuid = "rule-" .. tostring(i)
      end
      local srcText = src
      if sport ~= "" then srcText = srcText .. ":" .. sport end
      local dstText = dst
      if dport ~= "" then dstText = dstText .. ":" .. dport end
      table.insert(list, {
        id = uuid,
        description = descr ~= "" and descr or ("Rule " .. uuid:sub(1, 8)),
        action = action,
        direction = direction,
        enabled = enabled,
        source = srcText,
        destination = dstText,
        protocol = proto,
        interface = iface,
        automatic = automatic,
        packets = tonumber(row.packets) or 0,
        bytes = tonumber(row.bytes) or 0,
        evaluations = tonumber(row.evaluations) or 0,
        ok = lower(action) ~= "block" or not enabled, -- visual only; blocks aren't "issues"
      })
    end
  end
  return list
end

local function parseLogs(data)
  local list = {}
  if type(data) ~= "table" then
    return list, 0
  end
  -- API may return array directly or { rows = ... }
  local rows = data
  if data.rows then
    rows = data.rows
  end
  if type(rows) ~= "table" then
    return list, 0
  end

  local blockCount = 0
  local start = 1
  local finish = #rows
  -- Prefer newest: if timestamps look chronological ascending, reverse
  if #rows >= 2 then
    local t1 = asString(rows[1]["__timestamp__"] or "")
    local t2 = asString(rows[#rows]["__timestamp__"] or "")
    if t1 ~= "" and t2 ~= "" and t1 < t2 then
      -- oldest first -> iterate reverse
      local rev = {}
      for i = #rows, 1, -1 do
        table.insert(rev, rows[i])
      end
      rows = rev
    end
  end

  local n = 0
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local action = asString(row.action)
      if lower(action) == "block" then
        blockCount += 1
      end
      n += 1
      if n <= LOG_LIMIT then
        local src = asString(row.src)
        local dst = asString(row.dst)
        local sport = asString(row.srcport)
        local dport = asString(row.dstport)
        if sport ~= "" then src = src .. ":" .. sport end
        if dport ~= "" then dst = dst .. ":" .. dport end
        local ts = asString(row["__timestamp__"])
        -- shorten timestamp display
        local tsShort = ts:match("T(%d+:%d+:%d+)") or ts
        local datePart = ts:match("^(%d+-%d+-%d+)") or ""
        table.insert(list, {
          id = asString(row["__digest__"] or row.id or (ts .. src .. dst)),
          action = action,
          direction = asString(row.dir),
          interface = asString(row.interface),
          protocol = asString(row.protoname),
          src = src,
          dst = dst,
          label = asString(row.label),
          timestamp = ts,
          time = (datePart ~= "" and (datePart .. " " .. tsShort) or tsShort),
          blocked = lower(action) == "block",
        })
      end
    end
  end
  return list, blockCount
end

local function notifyNewIssues(inst, widgets, gateways)
  if noctalia.getConfig("notify_on_issue") == false then
    return
  end
  local current = {}
  local function consider(name, ok, status)
    if not ok then
      current[name] = true
      if not inst.prevIssues[name] then
        notifyErr(noctalia.tr("result.issue", {
          name = #instances > 1 and (inst.name .. " · " .. name) or name,
          status = status,
        }))
      end
    end
  end
  for _, w in ipairs(widgets) do
    consider(w.name, w.ok, w.status)
  end
  for _, g in ipairs(gateways) do
    consider("gw:" .. g.name, g.ok, g.status)
  end
  inst.prevIssues = current
end

local refreshAll
local fetchLogs

-- Applies one firewall's answers to its own data block.
local function applyInstanceData(inst, bag, errors)
  local data = inst.data
  local widgets, interfaces, gateways, services, rules = {}, {}, {}, {}, {}
  local info, resources = {}, {}

  local okParse, errParse = pcall(function()
    widgets = parseSystemStatus(bag.status)
    interfaces = parseInterfaces(bag.ifstats, bag.ifnames)
    gateways = parseGateways(bag.gateways)
    services = parseServices(bag.services)
    rules = parseRules(bag.rules)
    info, resources = parseInfo(bag.info, bag.resources, bag.time)
  end)
  if not okParse then
    noctalia.log(`opnsense: parse error on {inst.name}: {tostring(errParse)}`)
    table.insert(errors, "parse: " .. tostring(errParse))
  end

  local issues, oks = countIssues(widgets, gateways)
  pcall(notifyNewIssues, inst, widgets, gateways)

  local available = #widgets > 0 or #interfaces > 0 or #services > 0
    or #gateways > 0 or #rules > 0 or #(data.logs or {}) > 0
  data.available = available
  data.loading = false
  data.error = available and "" or (errors[1] or "no data")
  data.widgets = widgets
  data.interfaces = interfaces
  data.gateways = gateways
  data.services = services
  data.rules = rules
  -- keep previous logs unless fetchLogs updates them
  data.info = info
  data.resources = resources
  data.issueCount = issues
  data.okCount = oks
  data.updatedAt = nowSec()
  publishSnapshot()
end

-- A refresh or log fetch that never called back (CPU budget abort, hung
-- request) must not leave a firewall spinning forever.
local function recoverStuck()
  for _, inst in ipairs(instances) do
    local data = inst.data
    if inst.pending > 0 and inst.startedAt > 0 and (nowSec() - inst.startedAt) >= STUCK_REFRESH_SEC then
      noctalia.log(`opnsense: {inst.name} refresh timed out`)
      inst.pending = 0
      inst.startedAt = 0
      data.loading = false
      if data.error == "" then
        data.error = "refresh timed out"
      end
    end
    if inst.logsPending and inst.logsStartedAt > 0 and (nowSec() - inst.logsStartedAt) >= STUCK_LOGS_SEC then
      noctalia.log(`opnsense: {inst.name} log fetch timed out`)
      inst.logsPending = false
      inst.logsStartedAt = 0
      data.logsLoading = false
    end
  end
end

local function instancePending()
  for _, inst in ipairs(instances) do
    if inst.pending > 0 then
      return true
    end
  end
  return false
end

-- The host rejects requests beyond its HTTP queue (`http queue full`), so only
-- one firewall is polled at a time: its 8 calls are the same burst a single
-- firewall always produced. Queue: 4 firewalls then take ~4x a poll to sweep.
local refreshQueue = {}
local refreshActive = false
local pumpRefreshQueue

local function refreshInstance(inst, onDone)
  if inst.pending > 0 then
    inst.refreshAgain = true
    if onDone ~= nil then
      onDone()
    end
    return
  end

  inst.refreshAgain = false
  inst.startedAt = nowSec()
  inst.generation += 1
  local generation = inst.generation
  local confGeneration = configGeneration
  local data = inst.data

  -- Only show "Querying API…" on first load; background polls stay quiet.
  if not data.available then
    data.loading = true
  end

  -- Lean core set — no firewall log dump (on-demand via fetchLogs).
  local paths = {
    { path = "core/system/status", key = "status" },
    { path = "diagnostics/interface/get_interface_statistics", key = "ifstats" },
    { path = "diagnostics/interface/get_interface_names", key = "ifnames" },
    { path = "diagnostics/system/system_information", key = "info" },
    { path = "diagnostics/system/system_resources", key = "resources" },
    { path = "routes/gateway/status", key = "gateways" },
  }

  -- GETs + rules POST + services POST
  local pending = #paths + 2
  inst.pending = pending
  local bag = {}
  local errors = {}
  local finished = false

  local function stale()
    return confGeneration ~= configGeneration or generation ~= inst.generation
  end

  local function finish()
    if stale() then
      -- The instance list was replaced under us; release the pump so the new
      -- list still gets polled.
      if confGeneration ~= configGeneration then
        inst.pending = 0
        if onDone ~= nil then
          onDone()
        end
      end
      return
    end
    pending -= 1
    inst.pending = pending
    if pending > 0 or finished then
      return
    end
    finished = true
    inst.pending = 0
    inst.startedAt = 0

    local okApply, errApply = pcall(applyInstanceData, inst, bag, errors)
    if not okApply then
      noctalia.log(`opnsense: apply snapshot failed on {inst.name}: {tostring(errApply)}`)
      data.loading = false
      if not data.available then
        data.error = "refresh failed: " .. tostring(errApply)
      end
      publishSnapshot()
    end

    if inst.refreshAgain then
      -- Queued at the back: a firewall asking for an immediate re-poll must not
      -- starve the ones behind it in this sweep.
      inst.refreshAgain = false
      table.insert(refreshQueue, inst)
    end
    if onDone ~= nil then
      onDone()
    end
  end

  -- Decode + bag store inside pcall; finish() ALWAYS runs so one bad
  -- response cannot leave loading stuck.
  local function onGet(item, res)
    if stale() then
      return
    end
    local okInner, errInner = pcall(function()
      local decoded, err = decodeBody(res)
      if decoded ~= nil then
        bag[item.key] = decoded
      else
        table.insert(errors, item.path .. ": " .. tostring(err))
      end
    end)
    if not okInner then
      table.insert(errors, item.path .. ": " .. tostring(errInner))
    end
    finish()
  end

  local function onPost(key, label, res)
    if stale() then
      return
    end
    local okInner, errInner = pcall(function()
      local decoded, err = decodeBody(res)
      if decoded ~= nil then
        bag[key] = decoded
      else
        table.insert(errors, label .. ": " .. tostring(err))
      end
    end)
    if not okInner then
      table.insert(errors, label .. ": " .. tostring(errInner))
    end
    finish()
  end

  for _, item in ipairs(paths) do
    local captured = item
    apiRequest(inst, "GET", captured.path, nil, function(res)
      onGet(captured, res)
    end)
  end

  apiRequest(inst, "POST", "firewall/filter/search_rule", {
    current = 1,
    rowCount = 100,
    sort = {},
    searchPhrase = "",
    show_all = 1,
  }, function(res)
    onPost("rules", "rules", res)
  end)

  apiRequest(inst, "POST", "core/service/search", {
    current = 1,
    rowCount = 50,
    sort = {},
    searchPhrase = "",
  }, function(res)
    onPost("services", "services", res)
  end)
end

local function queued(inst)
  for _, candidate in ipairs(refreshQueue) do
    if candidate == inst then
      return true
    end
  end
  return false
end

pumpRefreshQueue = function()
  if refreshActive then
    return
  end
  local inst = table.remove(refreshQueue, 1)
  while inst ~= nil and inst.pending > 0 do
    inst = table.remove(refreshQueue, 1)
  end
  if inst == nil then
    -- Sweep drained: back to the configured cadence (the fast tick is only for
    -- recovering stuck requests).
    if not instancePending() then
      noctalia.setUpdateInterval(refreshIntervalMs())
    end
    return
  end
  refreshActive = true
  refreshInstance(inst, function()
    refreshActive = false
    pumpRefreshQueue()
  end)
end

-- `force` marks a refresh someone asked for (panel, launcher, CLI, settings
-- change) as opposed to the plain timer tick. A tick that lands while a sweep
-- is running must be ignored - honouring it would re-pull the firewall it found
-- in flight, and with the fast recovery tick that never ends. An explicit
-- refresh is always queued.
refreshAll = function(force)
  syncInstances()
  recoverStuck()

  if #instances == 0 then
    publishSnapshot()
    noctalia.setUpdateInterval(refreshIntervalMs())
    return
  end

  local sweeping = refreshActive or #refreshQueue > 0 or instancePending()
  for _, inst in ipairs(instances) do
    if inst.pending > 0 then
      if force then
        inst.refreshAgain = true
      end
    elseif (force or not sweeping) and not queued(inst) then
      table.insert(refreshQueue, inst)
    end
  end
  pumpRefreshQueue()
  publishSnapshot()
  sweeping = refreshActive or #refreshQueue > 0 or instancePending()
  -- Tick fast only while a sweep is in flight, so stuck recovery stays prompt.
  noctalia.setUpdateInterval(sweeping and 1000 or refreshIntervalMs())
end

-- Firewall log JSON is huge (~800KB+). Decoding it in an http callback exceeds
-- the Luau CPU budget and aborts the callback before finish(), so logs are
-- on-demand: GET ?limit=N piped through jq, which keeps Luau seeing ~KB.
local function fetchInstanceLogs(inst, command, quiet)
  if inst.logsPending then
    if not quiet then
      actionResult(command, false, noctalia.tr("result.busy"))
    end
    return
  end

  inst.logsPending = true
  inst.logsStartedAt = nowSec()
  inst.data.logsLoading = true
  publishSnapshot()

  local url = inst.url .. "/api/diagnostics/firewall/log?limit=" .. tostring(LOG_LIMIT)
  local curlArgs = { "curl", "-sS", "--max-time", "20", "-H", "Accept: application/json" }
  if inst.insecure then
    table.insert(curlArgs, "-k")
  end
  table.insert(curlArgs, "-u")
  table.insert(curlArgs, inst.key .. ":" .. inst.secret)
  table.insert(curlArgs, url)

  local parts = {}
  for _, a in ipairs(curlArgs) do
    table.insert(parts, shellQuote(a))
  end
  -- Project only UI fields so decode stays well under the CPU budget.
  local cmd = table.concat(parts, " ")
    .. " | jq -c 'if type==\"array\" then [.[] | {action,dir,interface,protoname,src,dst,srcport,dstport,label,__timestamp__,__digest__}] else . end'"

  local confGeneration = configGeneration

  local function doneLogs()
    inst.logsPending = false
    inst.logsStartedAt = 0
    inst.data.logsLoading = false
  end

  local function fail(message)
    doneLogs()
    publishSnapshot()
    if not quiet then
      actionResult(command, false, noctalia.tr("result.failed", { error = message }))
    end
  end

  local accepted = noctalia.runAsync(cmd, function(result)
    local data = inst.data
    local okAll, errAll = pcall(function()
      if confGeneration ~= configGeneration then
        doneLogs()
        return
      end
      if not result or result.exitCode ~= 0 then
        local err = trim(result and (result.stderr ~= "" and result.stderr or result.stdout) or "log fetch failed")
        if err == "" then err = "log fetch failed" end
        if not data.available then
          data.error = err
        end
        fail(err)
        return
      end

      local parsed = noctalia.json.decode(result.stdout or "")
      if parsed == nil then
        fail("log parse failed")
        return
      end

      local logs, blockLogs = parseLogs(parsed)
      data.logs = logs
      data.blockLogCount = blockLogs
      if data.error:find("log", 1, true) or data.error:find("timed out", 1, true) then
        data.error = ""
      end
      data.updatedAt = nowSec()
      doneLogs()
      publishSnapshot()
      if not quiet then
        actionResult(command, true, noctalia.tr("result.logs_loaded", { n = #logs }))
      end
    end)
    if not okAll then
      noctalia.log(`opnsense: log fetch failed on {inst.name}: {tostring(errAll)}`)
      fail("log parse failed")
    end
  end, 30000)

  if not accepted then
    fail("could not start log fetch")
  end
end

fetchLogs = function(command)
  if #instances == 0 then
    actionResult(command, false, noctalia.tr("result.not_configured"))
    return
  end

  local target = trim(command and command.instance or "")
  if target == "" then
    -- No firewall named (IPC): fetch every instance and report once.
    local many = #instances > 1
    for _, inst in ipairs(instances) do
      fetchInstanceLogs(inst, command, many)
    end
    if many then
      actionResult(command, true, noctalia.tr("result.success"))
    end
    return
  end

  local inst = findInstance(target)
  if inst == nil then
    actionResult(command, false, noctalia.tr("result.failed", { error = "unknown firewall: " .. target }))
    return
  end
  fetchInstanceLogs(inst, command, false)
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
  refreshAll(true)
end

-- Resolves the firewall a command targets: an explicit `instance`, or the only
-- configured one. Returns nil when the command is ambiguous.
local function commandInstance(command)
  local target = trim(command and command.instance or "")
  if target ~= "" then
    return findInstance(target)
  end
  if #instances == 1 then
    return instances[1]
  end
  return nil
end

local function serviceControl(command, verb)
  if actionBusy then
    actionResult(command, false, noctalia.tr("result.busy"))
    return
  end
  local inst = commandInstance(command)
  if inst == nil then
    actionResult(command, false, noctalia.tr(#instances == 0 and "result.not_configured" or "result.no_instance"))
    return
  end
  local name = trim(command.name or command.id)
  if name == "" then
    actionResult(command, false, noctalia.tr("result.failed", { error = "missing service" }))
    return
  end
  actionBusy = true
  publishSnapshot()
  apiRequest(inst, "POST", "core/service/" .. verb .. "/" .. noctalia.string.urlEncode(name), {}, function(res)
    local data, err = decodeBody(res)
    local ok = data ~= nil and (res.status == nil or res.status < 400)
    if type(data) == "table" and data.result ~= nil then
      ok = asString(data.result) == "ok" or data.result == true
    end
    if ok then
      local msgKey = verb == "restart" and "result.restarted"
        or (verb == "start" and "result.started" or "result.stopped")
      finishAction(command, true, noctalia.tr(msgKey, { name = name }))
    else
      finishAction(command, false, noctalia.tr("result.failed", { error = err or "service action failed" }))
    end
  end)
end

local function openUi(command)
  local inst = commandInstance(command) or instances[1]
  if inst == nil then
    actionResult(command, false, noctalia.tr("result.not_configured"))
    return
  end
  noctalia.runAsync("xdg-open " .. shellQuote(inst.webUi))
  actionResult(command, true, noctalia.tr("result.success"))
end

local function executeAction(command)
  if type(command) ~= "table" or type(command.action) ~= "string" then
    return
  end
  if command.action == "refresh" then
    refreshAll(true)
    return
  end
  if command.action == "fetch_logs" then
    fetchLogs(command)
    return
  end
  if command.action == "open_ui" then
    openUi(command)
    return
  end
  if command.action == "restart_service" then
    serviceControl(command, "restart")
    return
  end
  if command.action == "start_service" then
    serviceControl(command, "start")
    return
  end
  if command.action == "stop_service" then
    serviceControl(command, "stop")
    return
  end
  if command.action == "copy" then
    local text = trim(command.text or command.name)
    if text ~= "" then
      noctalia.copyToClipboard(text, "text/plain")
      actionResult(command, true, noctalia.tr("result.copied", { name = text }))
      notifyOk(noctalia.tr("result.copied", { name = text }))
    end
    return
  end
  actionResult(command, false, "Unknown action: " .. command.action)
end

noctalia.state.watch(COMMAND_KEY, executeAction)
noctalia.setUpdateInterval(refreshIntervalMs())
refreshAll()

function update()
  -- Stuck recovery runs at the top of refreshAll (1s cadence while in flight).
  refreshAll()
end

function onConfigChanged()
  -- Settings changed: drop in-flight bookkeeping, rebuild the list, poll again.
  for _, inst in ipairs(instances) do
    inst.pending = 0
    inst.startedAt = 0
    inst.logsPending = false
    inst.logsStartedAt = 0
    inst.data.logsLoading = false
  end
  noctalia.setUpdateInterval(refreshIntervalMs())
  refreshAll(true)
end

function onIpc(event, _payload)
  if event == "refresh" then
    for _, inst in ipairs(instances) do
      inst.pending = 0
      inst.startedAt = 0
    end
    refreshAll(true)
  elseif event == "logs" then
    fetchLogs({ action = "fetch_logs", requestId = "ipc-logs" })
  end
end