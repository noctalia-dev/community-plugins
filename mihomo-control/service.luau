--!nonstrict
-- Mihomo Control — background service.
--
-- This entry owns every request to the Mihomo external controller
-- (http(s)://host:port) and publishes the results as shared "mihomo.*" state.
-- The widget, panel and shortcut never touch the network; to make the service
-- act they write a command table to "mihomo.command":
--
--   { op = "select", group = "<group>", proxy = "<proxy>" }
--   { op = "mode", mode = "rule" | "global" | "direct" }
--   { op = "delay_test", group = "<group>" }
--   { op = "reorder_group", group = "<group>", index = <insertion index> }
--   { op = "restart" }                           POST /restart (core re-execs)
--   { op = "close_connections" }
--   { op = "refresh" }
--
-- Endpoints used (MetaCubeX/Meta-Docs "API" reference):
--   GET    /version /configs /connections /proxies      polling
--   GET    /traffic                                     streamed (httpStream)
--   PATCH  /configs  {"mode": ...}                      switch proxy mode
--   PUT    /proxies/<group> {"name": ...}               select group member
--   GET    /group/<group>/delay?url=..&timeout=..       latency test
--   DELETE /connections                                 close all connections

local MODES = { rule = true, global = true, direct = true }
local DEFAULT_TEST_URL = "https://www.gstatic.com/generate_204"
local GROUPS_REFRESH_EVERY = 5 -- every Nth tick, re-fetch /proxies
local STREAM_RETRY_EVERY = 5 -- ticks between traffic-stream retry attempts

-- ── Settings ────────────────────────────────────────────────────────────────

local settings = {
  host = "127.0.0.1",
  port = 9090,
  secret = "",
  use_https = false,
  insecure = false,
  test_url = "",
  interval = 2,
}

local function reload_settings()
  local host = noctalia.getConfig("host")
  local port = noctalia.getConfig("port")
  local secret = noctalia.getConfig("secret")
  local test_url = noctalia.getConfig("test_url")
  local interval = tonumber(noctalia.getConfig("refresh_interval")) or 2

  settings.host = type(host) == "string" and host ~= "" and host or "127.0.0.1"
  local port_number = tonumber(port)
  settings.port = (type(port_number) == "number" and port_number >= 1 and port_number <= 65535)
      and math.floor(port_number)
    or 9090
  settings.secret = type(secret) == "string" and secret or ""
  settings.use_https = noctalia.getConfig("use_https") == true
  settings.insecure = noctalia.getConfig("allow_insecure_tls") == true
  settings.test_url = type(test_url) == "string" and noctalia.string.trim(test_url) or ""
  settings.interval = math.max(1, math.min(60, interval))
end

local function base_url()
  local scheme = settings.use_https and "https" or "http"
  return `{scheme}://{settings.host}:{settings.port}`
end

local function auth_headers()
  if settings.secret == "" then
    return {}
  end
  return { `Authorization: Bearer {settings.secret}` }
end

local function json_headers()
  local headers = { "Content-Type: application/json" }
  for _, header in auth_headers() do
    table.insert(headers, header)
  end
  return headers
end

-- ── Shared state ────────────────────────────────────────────────────────────

local state = {
  connection = {
    status = "connecting", -- connecting | online | offline
    host = settings.host,
    port = settings.port,
    version = "",
    meta = false,
    error = "",
  },
  config = { mode = "rule", mixedPort = 0, port = 0, socksPort = 0, allowLan = false, ipv6 = false },
  traffic = { up = 0, down = 0, upTotal = 0, downTotal = 0 },
  connections = { count = 0, downloadTotal = 0, uploadTotal = 0, memory = 0 },
  groups = {},
  delay = {},
}

-- Mihomo's /proxies response is a map and therefore has no stable user-facing
-- group order. Keep the panel's preferred order in the plugin data directory;
-- newly discovered groups that are not in this list are appended alphabetically.
local group_order = {}
local data_path = nil

local function resolve_data_path()
  if data_path ~= nil then
    return data_path
  end
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  data_path = dir .. "/state.json"
  return data_path
end

local function load_group_order()
  local path = resolve_data_path()
  if path == nil then
    return
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return
  end
  local ok, decoded = pcall(noctalia.json.decode, raw)
  if not ok or type(decoded) ~= "table" or type(decoded.groupOrder) ~= "table" then
    return
  end

  local seen = {}
  for _, name in ipairs(decoded.groupOrder) do
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(group_order, name)
    end
  end
end

local function save_group_order()
  local path = resolve_data_path()
  if path == nil then
    return
  end
  local ok, encoded = pcall(noctalia.json.encode, { groupOrder = group_order })
  if not ok or type(encoded) ~= "string" then
    noctalia.log("[mihomo-control] failed to encode proxy-group order")
    return
  end
  local written, err = noctalia.writeFile(path, encoded)
  if not written then
    noctalia.log("[mihomo-control] failed to save proxy-group order: " .. tostring(err or "unknown error"))
  end
end

local function apply_group_order(groups)
  local rank = {}
  for index, name in ipairs(group_order) do
    rank[name] = index
  end
  table.sort(groups, function(a, b)
    local a_rank = rank[a.name]
    local b_rank = rank[b.name]
    if a_rank ~= nil and b_rank ~= nil then
      return a_rank < b_rank
    end
    if a_rank ~= nil then
      return true
    end
    if b_rank ~= nil then
      return false
    end
    return a.name < b.name
  end)
end

local function publish(key)
  noctalia.state.set("mihomo." .. key, state[key])
end

local function set_online()
  state.connection.status = "online"
  state.connection.error = ""
  publish("connection")
end

local function set_offline(err)
  state.connection.status = "offline"
  state.connection.error = err or ""
  publish("connection")
end

-- ── HTTP helpers ────────────────────────────────────────────────────────────

local function request(method, path, headers, body, on_done)
  local req = {
    url = base_url() .. path,
    method = method,
    headers = headers,
  }
  if body ~= nil then
    req.body = noctalia.json.encode(body)
  end
  if settings.insecure then
    req.allow_insecure_tls = true
  end
  noctalia.http(req, function(res)
    on_done(res)
  end)
end

local function success(res)
  return res.ok and res.status >= 200 and res.status < 300
end

local function decode(body)
  local ok, data = pcall(noctalia.json.decode, body)
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

-- ── Polling ─────────────────────────────────────────────────────────────────

local function poll_version()
  request("GET", "/version", auth_headers(), nil, function(res)
    if not success(res) then
      local reason
      if res.status == 401 then
        reason = "unauthorized"
      elseif not res.ok then
        reason = "connection failed"
      else
        reason = `HTTP {res.status}`
      end
      set_offline(reason)
      return
    end
    local data = decode(res.body)
    if data then
      -- Some builds report "v1.19.0", others "1.19.0"; normalize so the UI
      -- never shows a doubled or forced "v".
      state.connection.version = tostring(data.version or ""):gsub("^v", "")
      state.connection.meta = data.meta == true
      set_online()
    end
  end)
end

local function poll_configs()
  request("GET", "/configs", auth_headers(), nil, function(res)
    if not success(res) then
      return
    end
    local data = decode(res.body)
    if data then
      state.config.mode = type(data.mode) == "string" and data.mode or state.config.mode
      state.config.mixedPort = tonumber(data["mixed-port"]) or 0
      state.config.port = tonumber(data.port) or 0
      state.config.socksPort = tonumber(data["socks-port"]) or 0
      state.config.allowLan = data["allow-lan"] == true
      state.config.ipv6 = data.ipv6 == true
      publish("config")
    end
  end)
end

local function poll_connections()
  request("GET", "/connections", auth_headers(), nil, function(res)
    if not success(res) then
      return
    end
    local data = decode(res.body)
    if data then
      state.connections.count = type(data.connections) == "table" and #data.connections or 0
      state.connections.downloadTotal = tonumber(data.downloadTotal) or 0
      state.connections.uploadTotal = tonumber(data.uploadTotal) or 0
      state.connections.memory = tonumber(data.memory) or 0
      publish("connections")
    end
  end)
end

-- ── Proxy groups ────────────────────────────────────────────────────────────

local function merge_delays(group_name)
  local delays = state.delay[group_name]
  if type(delays) ~= "table" or type(delays.byName) ~= "table" then
    return
  end
  for _, group in state.groups do
    if group.name == group_name then
      for _, member in group.members do
        local delay = delays.byName[member.name]
        if delay ~= nil then
          member.delay = delay
        end
      end
    end
  end
end

local function poll_proxies()
  request("GET", "/proxies", auth_headers(), nil, function(res)
    if not success(res) then
      return
    end
    local data = decode(res.body)
    if not data or type(data.proxies) ~= "table" then
      return
    end

    -- Every proxy (and nested group) carries a `history` array with the last
    -- known delay from mihomo's health checks; 0 means the last probe failed.
    -- Use the newest entry as each proxy's latency so the panel can show
    -- per-node latencies without waiting for a manual test.
    local proxy_delays = {}
    for name, info in data.proxies do
      if type(info) == "table" and type(info.history) == "table" and #info.history > 0 then
        local last = info.history[#info.history]
        if type(last) == "table" and last.delay ~= nil then
          proxy_delays[tostring(name)] = tonumber(last.delay) or 0
        end
      end
    end

    local groups = {}
    for name, info in data.proxies do
      -- Any entry with an `all` list is a proxy group (Selector, URLTest,
      -- Fallback, LoadBalance, and Relay on forks that still ship it).
      -- Filtering by type would silently drop group kinds we did not think of.
      if type(info) == "table" and type(info.all) == "table" then
        local members = {}
        for _, member_name in info.all do
          table.insert(members, {
            name = tostring(member_name),
            delay = proxy_delays[tostring(member_name)],
          })
        end
        table.insert(groups, {
          name = tostring(name),
          type = tostring(info.type),
          now = info.now ~= nil and tostring(info.now) or nil,
          hidden = info.hidden == true,
          testUrl = type(info.testUrl) == "string" and info.testUrl or DEFAULT_TEST_URL,
          members = members,
        })
      end
    end
    apply_group_order(groups)
    state.groups = groups
    for _, group in groups do
      merge_delays(group.name)
    end
    publish("groups")
  end)
end

-- ── Traffic stream ──────────────────────────────────────────────────────────

local traffic_stream = nil
local stream_attempt_tick = -100

local function start_traffic_stream()
  if traffic_stream ~= nil then
    return
  end
  traffic_stream = noctalia.httpStream(
    {
      url = base_url() .. "/traffic",
      headers = auth_headers(),
      allow_insecure_tls = settings.insecure,
    },
    function(line)
      if line == "" then
        return
      end
      local data = decode(line)
      if data then
        state.traffic.up = tonumber(data.up) or state.traffic.up
        state.traffic.down = tonumber(data.down) or state.traffic.down
        state.traffic.upTotal = tonumber(data.upTotal) or state.traffic.upTotal
        state.traffic.downTotal = tonumber(data.downTotal) or state.traffic.downTotal
        publish("traffic")
      end
    end,
    function(result)
      traffic_stream = nil
      if result and not result.ok then
        stream_attempt_tick = -1 -- retry soon
      end
    end
  )
  if traffic_stream == nil then
    stream_attempt_tick = -1 -- could not start; retry later
  end
end

-- ── Commands ────────────────────────────────────────────────────────────────

local last_cmd_seq = 0

local function run_delay_test(group_name, opts)
  local silent = opts ~= nil and opts.silent == true
  local on_done = opts ~= nil and opts.on_done
  local function finish()
    if on_done then
      on_done()
    end
  end

  local group = nil
  for _, candidate in state.groups do
    if candidate.name == group_name then
      group = candidate
    end
  end
  local test_url = settings.test_url ~= ""
      and settings.test_url
    or (group and group.testUrl or DEFAULT_TEST_URL)
  local path = "/group/"
    .. noctalia.string.urlEncode(group_name)
    .. "/delay?url="
    .. noctalia.string.urlEncode(test_url)
    .. "&timeout=5000"

  request("GET", path, auth_headers(), nil, function(res)
    if res.status == 504 then
      -- mihomo reports a failed group latency test as HTTP 504 Gateway Timeout
      -- (every node timed out or errored). That is a test result, not a
      -- request failure, so surface it as such and drop stale latencies.
      state.delay[group_name] = { tested = 0, timedOut = true, byName = {}, at = os.time() }
      for _, candidate in state.groups do
        if candidate.name == group_name then
          for _, member in candidate.members do
            member.delay = 0 -- every member failed, show as timeout
          end
        end
      end
      publish("groups")
      publish("delay")
      if not silent then
        noctalia.notify(noctalia.tr("notify.delay_done"), noctalia.tr("notify.delay_timeout"))
      end
      finish()
      return
    end
    if not success(res) then
      if not silent then
        noctalia.notifyError(noctalia.tr("notify.request_failed"), `HTTP {res.status}`)
      end
      finish()
      return
    end
    local data = decode(res.body)
    if not data then
      finish()
      return
    end

    local count = 0
    local by_name = {}
    for name, delay in data do
      count += 1
      by_name[tostring(name)] = tonumber(delay)
    end

    local selected_delay = nil
    local selected = group and group.now
    if selected and by_name[selected] ~= nil then
      selected_delay = by_name[selected]
    end

    state.delay[group_name] = {
      tested = count,
      selectedDelay = selected_delay,
      byName = by_name,
      at = os.time(),
    }
    merge_delays(group_name)
    publish("groups")
    publish("delay")

    local message = selected_delay ~= nil
      and noctalia.tr("notify.delay_body", { count = count, delay = selected_delay })
      or noctalia.tr("notify.delay_body_no_selection", { count = count })
    if not silent then
      noctalia.notify(noctalia.tr("notify.delay_done"), message)
    end
    finish()
  end)
end

-- Run latency tests for every group, one at a time, with a single summary
-- notification at the end.
local function test_all_groups()
  local queue = {}
  for _, group in state.groups do
    table.insert(queue, group.name)
  end
  if #queue == 0 then
    return
  end

  local index = 1
  local function next_test()
    if index > #queue then
      noctalia.notify(noctalia.tr("notify.delay_all_done"))
      return
    end
    local name = queue[index]
    index += 1
    run_delay_test(name, { silent = true, on_done = next_test })
  end
  next_test()
end

-- Move one group to an insertion gap in the currently published order. Gaps
-- are numbered 1..#groups+1; removing an item shifts later gaps down by one.
local function reorder_group(group_name, insertion_index)
  local from_index = nil
  for index, group in ipairs(state.groups) do
    if group.name == group_name then
      from_index = index
      break
    end
  end

  local insert_at = tonumber(insertion_index)
  if from_index == nil or insert_at == nil then
    return
  end

  insert_at = math.floor(insert_at)
  local moved = table.remove(state.groups, from_index)
  if from_index < insert_at then
    insert_at -= 1
  end
  insert_at = math.max(1, math.min(insert_at, #state.groups + 1))
  table.insert(state.groups, insert_at, moved)

  group_order = {}
  for _, group in ipairs(state.groups) do
    table.insert(group_order, group.name)
  end
  save_group_order()
  publish("groups")
end

local function handle_command(cmd)
  local op = cmd.op
  if op == "refresh" then
    poll_version()
    poll_configs()
    poll_connections()
    poll_proxies()
    return
  end
  if op == "mode" then
    local mode = cmd.mode
    if MODES[mode] then
      request("PATCH", "/configs", json_headers(), { mode = mode }, function(res)
        if success(res) then
          state.config.mode = mode
          publish("config")
          noctalia.notify(
            noctalia.tr("notify.mode_changed"),
            noctalia.tr("panel.mode_" .. mode)
          )
        else
          noctalia.notifyError(noctalia.tr("notify.request_failed"), `HTTP {res.status}`)
        end
      end)
    end
    return
  end
  if op == "select" then
    local group = tostring(cmd.group or "")
    local proxy = tostring(cmd.proxy or "")
    if group ~= "" and proxy ~= "" then
      local path = "/proxies/" .. noctalia.string.urlEncode(group)
      request("PUT", path, json_headers(), { name = proxy }, function(res)
        if success(res) then
          for _, candidate in state.groups do
            if candidate.name == group then
              candidate.now = proxy
            end
          end
          publish("groups")
          noctalia.notify(
            noctalia.tr("notify.proxy_selected"),
            noctalia.tr("notify.proxy_selected_body", { group = group, proxy = proxy })
          )
        else
          noctalia.notifyError(noctalia.tr("notify.request_failed"), `HTTP {res.status}`)
        end
      end)
    end
    return
  end
  if op == "reorder_group" then
    local group = tostring(cmd.group or "")
    if group ~= "" then
      reorder_group(group, cmd.index)
    end
    return
  end
  if op == "delay_test_all" then
    test_all_groups()
    return
  end
  if op == "delay_test" then
    local group = tostring(cmd.group or "")
    if group ~= "" then
      run_delay_test(group)
    end
    return
  end
  if op == "restart" then
    state.connection.status = "connecting"
    state.connection.error = ""
    publish("connection")
    noctalia.notify(noctalia.tr("notify.restarting"))
    request("POST", "/restart", auth_headers(), nil, function(res)
      -- The core re-execs and drops the connection mid-response; a transport
      -- failure with no status is the expected outcome, anything else is an error.
      if success(res) or (not res.ok and res.status == 0) then
        return
      end
      noctalia.notifyError(noctalia.tr("notify.request_failed"), `HTTP {res.status}`)
    end)
    return
  end
  if op == "close_connections" then
    request("DELETE", "/connections", auth_headers(), nil, function(res)
      if success(res) then
        state.connections.count = 0
        publish("connections")
        noctalia.notify(noctalia.tr("notify.connections_closed"))
      else
        noctalia.notifyError(noctalia.tr("notify.request_failed"), `HTTP {res.status}`)
      end
    end)
  end
end

noctalia.state.watch("mihomo.command", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local seq = tonumber(cmd.seq) or 0
  if seq <= last_cmd_seq then
    return
  end
  last_cmd_seq = seq
  handle_command(cmd)
end)

-- ── Entry-point callbacks ───────────────────────────────────────────────────

local tick = 0

function update()
  tick += 1
  noctalia.setUpdateInterval(settings.interval * 1000)

  poll_version()
  poll_configs()
  poll_connections()
  if tick % GROUPS_REFRESH_EVERY == 1 then
    poll_proxies()
  end

  if traffic_stream == nil and tick - stream_attempt_tick >= STREAM_RETRY_EVERY then
    stream_attempt_tick = tick
    start_traffic_stream()
  end
end

function onConfigChanged()
  reload_settings()
  state.connection.host = settings.host
  state.connection.port = settings.port
  publish("connection")

  if traffic_stream ~= nil then
    traffic_stream.stop()
    traffic_stream = nil
  end
  stream_attempt_tick = -1

  poll_version()
  poll_configs()
  poll_connections()
  poll_proxies()
end

function onIpc(event, payload)
  if event == "refresh" then
    poll_version()
    poll_configs()
    poll_connections()
    poll_proxies()
  elseif event == "cmd" and payload then
    local ok, cmd = pcall(noctalia.json.decode, payload)
    if ok and type(cmd) == "table" then
      handle_command(cmd)
    end
  end
end

-- ── Init ────────────────────────────────────────────────────────────────────

reload_settings()
load_group_order()
state.connection.host = settings.host
state.connection.port = settings.port
publish("connection")
publish("config")
publish("traffic")
publish("connections")
publish("groups")
publish("delay")

poll_version()
poll_configs()
poll_connections()
poll_proxies()
start_traffic_stream()
