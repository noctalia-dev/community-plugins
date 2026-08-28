-- Pure helpers shared by service.luau and Lua unit tests.
-- Plain Lua 5.x syntax so tests can loadfile() without a Luau runtime.

local M = {}

M.PROXIES_INLINE_DECODE_LIMIT = 65536

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

-- Mihomo's /connections payload can be large when many flows are active. The
-- panel only needs totals and a count, so scrape those fields without a full
-- json.decode that can exceed Noctalia's per-callback CPU budget.
function M.parse_connections_summary(body)
  if type(body) ~= "string" or body == "" then
    return nil
  end
  local downloadTotal = tonumber(body:match('"downloadTotal"%s*:%s*(%d+)'))
  local uploadTotal = tonumber(body:match('"uploadTotal"%s*:%s*(%d+)'))
  local memory = tonumber(body:match('"memory"%s*:%s*(%d+)'))
  if downloadTotal == nil and uploadTotal == nil and memory == nil then
    return nil
  end
  local count = 0
  for _ in body:gmatch('"chains"%s*:') do
    count = count + 1
  end
  return {
    count = count,
    downloadTotal = downloadTotal or 0,
    uploadTotal = uploadTotal or 0,
    memory = memory or 0,
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

return M
