-- Pure helpers shared by service.luau and Lua unit tests.
-- Plain Lua 5.x syntax so tests can loadfile() without a Luau runtime.

local M = {}

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

return M
