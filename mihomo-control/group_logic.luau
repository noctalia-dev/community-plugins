-- Pure helpers shared by service.luau and Lua unit tests.
-- Plain Lua 5.x syntax so tests can loadfile() without a Luau runtime.

local M = {}

M.PROXIES_INLINE_DECODE_LIMIT = 65536
M.CONNECTIONS_INLINE_DECODE_LIMIT = 8192

function M.clamp_interval(seconds)
  local value = tonumber(seconds) or 2
  return math.max(1, math.min(60, value))
end

function M.normalize_group_order(raw_order)
  local order = {}
  if type(raw_order) ~= "table" then
    return order
  end
  local seen = {}
  for _, name in ipairs(raw_order) do
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(order, name)
    end
  end
  return order
end

function M.apply_group_order(groups, group_order)
  local rank = {}
  for index, name in ipairs(group_order or {}) do
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
  return groups
end

-- Gaps are numbered 1..#groups+1. Returns (groups, order) or nil when invalid.
function M.reorder_groups(groups, group_name, insertion_index)
  local from_index = nil
  for index, group in ipairs(groups) do
    if group.name == group_name then
      from_index = index
      break
    end
  end

  local insert_at = tonumber(insertion_index)
  if from_index == nil or insert_at == nil then
    return nil
  end

  local copy = {}
  for index, group in ipairs(groups) do
    copy[index] = group
  end

  insert_at = math.floor(insert_at)
  local moved = table.remove(copy, from_index)
  if from_index < insert_at then
    insert_at = insert_at - 1
  end
  insert_at = math.max(1, math.min(insert_at, #copy + 1))
  table.insert(copy, insert_at, moved)

  local order = {}
  for _, group in ipairs(copy) do
    table.insert(order, group.name)
  end
  return copy, order
end

function M.traffic_changed(previous, next_values)
  if type(previous) ~= "table" or type(next_values) ~= "table" then
    return true
  end
  return not (
    (tonumber(next_values.up) or previous.up) == previous.up
      and (tonumber(next_values.down) or previous.down) == previous.down
      and (tonumber(next_values.upTotal) or previous.upTotal) == previous.upTotal
      and (tonumber(next_values.downTotal) or previous.downTotal) == previous.downTotal
  )
end

function M.connections_body_needs_external_decode(body)
  return type(body) == "string" and #body > M.CONNECTIONS_INLINE_DECODE_LIMIT
end

function M.parse_connections_summary(data)
  if type(data) ~= "table" then
    return nil
  end
  return {
    count = type(data.connections) == "table" and #data.connections or 0,
    downloadTotal = tonumber(data.downloadTotal) or 0,
    uploadTotal = tonumber(data.uploadTotal) or 0,
    memory = tonumber(data.memory) or 0,
  }
end

function M.proxies_body_needs_external_decode(body)
  return type(body) == "string" and #body > M.PROXIES_INLINE_DECODE_LIMIT
end

function M.build_groups_from_proxies(proxies, default_test_url)
  if type(proxies) ~= "table" then
    return {}
  end
  local default = default_test_url or "https://www.gstatic.com/generate_204"

  local proxy_delays = {}
  for name, info in pairs(proxies) do
    if type(info) == "table" and type(info.history) == "table" and #info.history > 0 then
      local last = info.history[#info.history]
      if type(last) == "table" and last.delay ~= nil then
        proxy_delays[tostring(name)] = tonumber(last.delay) or 0
      end
    end
  end

  local groups = {}
  for name, info in pairs(proxies) do
    if type(info) == "table" and type(info.all) == "table" then
      local members = {}
      for _, member_name in ipairs(info.all) do
        local member = tostring(member_name)
        table.insert(members, {
          name = member,
          delay = proxy_delays[member],
        })
      end
      table.insert(groups, {
        name = tostring(name),
        type = tostring(info.type or ""),
        now = info.now ~= nil and tostring(info.now) or nil,
        hidden = info.hidden == true,
        testUrl = type(info.testUrl) == "string" and info.testUrl or default,
        members = members,
      })
    end
  end
  return groups
end

function M.build_groups_from_slim_proxies(slim, default_test_url)
  if type(slim) ~= "table" or type(slim.groups) ~= "table" then
    return {}
  end
  local default = default_test_url or "https://www.gstatic.com/generate_204"
  local delays = type(slim.delays) == "table" and slim.delays or {}
  local groups = {}

  for _, group in ipairs(slim.groups) do
    if type(group) == "table" and type(group.name) == "string" then
      local members = {}
      for _, member_name in ipairs(type(group.members) == "table" and group.members or {}) do
        local member = tostring(member_name)
        table.insert(members, {
          name = member,
          delay = delays[member],
        })
      end
      table.insert(groups, {
        name = group.name,
        type = tostring(group.type or ""),
        now = group.now ~= nil and tostring(group.now) or nil,
        hidden = group.hidden == true,
        testUrl = type(group.testUrl) == "string" and group.testUrl or default,
        members = members,
      })
    end
  end
  return groups
end

function M.normalize_port(value)
  local port = tonumber(value)
  if port == nil or port < 1 or port > 65535 then
    return nil
  end
  return math.floor(port)
end

function M.normalize_server(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local id = type(raw.id) == "string" and raw.id ~= "" and raw.id or nil
  local host = type(raw.host) == "string" and raw.host ~= "" and raw.host or nil
  local port = M.normalize_port(raw.port)
  if id == nil or host == nil or port == nil then
    return nil
  end
  local name = type(raw.name) == "string" and raw.name ~= "" and raw.name or (host .. ":" .. tostring(port))
  local test_url = ""
  if type(raw.testUrl) == "string" then
    test_url = raw.testUrl
  elseif type(raw.test_url) == "string" then
    test_url = raw.test_url
  end
  return {
    id = id,
    name = name,
    host = host,
    port = port,
    secret = type(raw.secret) == "string" and raw.secret or "",
    useHttps = raw.useHttps == true or raw.use_https == true,
    allowInsecureTls = raw.allowInsecureTls == true or raw.allow_insecure_tls == true,
    testUrl = test_url,
  }
end

function M.public_server_view(server)
  if type(server) ~= "table" then
    return nil
  end
  return {
    id = server.id,
    name = server.name,
    host = server.host,
    port = server.port,
    useHttps = server.useHttps == true,
    allowInsecureTls = server.allowInsecureTls == true,
    testUrl = server.testUrl or "",
    hasSecret = server.secret ~= "",
  }
end

function M.server_from_plugin_settings(id, name, cfg)
  if type(cfg) ~= "table" then
    return nil
  end
  local host = type(cfg.host) == "string" and cfg.host ~= "" and cfg.host or "127.0.0.1"
  local port = M.normalize_port(cfg.port) or 9090
  return M.normalize_server({
    id = id,
    name = name,
    host = host,
    port = port,
    secret = type(cfg.secret) == "string" and cfg.secret or "",
    use_https = cfg.use_https == true,
    allow_insecure_tls = cfg.allow_insecure_tls == true,
    test_url = type(cfg.test_url) == "string" and cfg.test_url or "",
  })
end

function M.normalize_servers_store(raw)
  local store = {
    activeId = "",
    servers = {},
    groupOrders = {},
  }
  if type(raw) ~= "table" then
    return store
  end
  if type(raw.activeId) == "string" then
    store.activeId = raw.activeId
  end
  if type(raw.servers) == "table" then
    for _, item in ipairs(raw.servers) do
      local server = M.normalize_server(item)
      if server ~= nil then
        table.insert(store.servers, server)
      end
    end
  end
  if type(raw.groupOrders) == "table" then
    for id, order in pairs(raw.groupOrders) do
      if type(id) == "string" and id ~= "" and type(order) == "table" then
        store.groupOrders[id] = M.normalize_group_order(order)
      end
    end
  end
  if store.activeId == "" and #store.servers > 0 then
    store.activeId = store.servers[1].id
  end
  if M.find_server(store.servers, store.activeId) == nil and #store.servers > 0 then
    store.activeId = store.servers[1].id
  end
  return store
end

function M.find_server(servers, id)
  if type(servers) ~= "table" or type(id) ~= "string" or id == "" then
    return nil
  end
  for _, server in ipairs(servers) do
    if server.id == id then
      return server
    end
  end
  return nil
end

function M.upsert_server(servers, server)
  local copy = {}
  local replaced = false
  for _, item in ipairs(servers or {}) do
    if item.id == server.id then
      table.insert(copy, server)
      replaced = true
    else
      table.insert(copy, item)
    end
  end
  if not replaced then
    table.insert(copy, server)
  end
  return copy
end

function M.delete_server(servers, id)
  local copy = {}
  for _, item in ipairs(servers or {}) do
    if item.id ~= id then
      table.insert(copy, item)
    end
  end
  return copy
end

function M.public_servers_state(store)
  local list = {}
  if type(store) == "table" and type(store.servers) == "table" then
    for _, server in ipairs(store.servers) do
      local view = M.public_server_view(server)
      if view ~= nil then
        table.insert(list, view)
      end
    end
  end
  return {
    activeId = type(store) == "table" and store.activeId or "",
    list = list,
  }
end

return M
