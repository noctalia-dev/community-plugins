--!nonstrict
local M = {}

function M.chatThread(thread)
  return type(thread) == "string" and thread:sub(1, 5) == "chat:"
end

function M.smsThread(thread)
  return type(thread) == "string" and thread ~= "" and not M.chatThread(thread)
end

local function scopeId(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

-- The wire list contains opaque IDs, not names of hidden apps.
function M.policy(raw)
  if type(raw) ~= "table" or not scopeId(raw.instance)
    or type(raw.revision) ~= "string" or #raw.revision > 20 or not raw.revision:match("^%d+$")
    or type(raw.hidden) ~= "table"
  then return nil end
  local hidden = {}
  local count = 0
  for i, scope in pairs(raw.hidden) do
    if type(i) ~= "number" or i < 1 or i % 1 ~= 0 or i > #raw.hidden or not scopeId(scope) then return nil end
    count = count + 1
    hidden[scope] = true
  end
  if count ~= #raw.hidden then return nil end
  return { instance = raw.instance, revision = raw.revision, hidden = hidden }
end

function M.policyChanged(previous, current)
  return current ~= nil and (not previous or previous.instance ~= current.instance or previous.revision ~= current.revision)
end

function M.allowsScope(policy, scope, previousInstance)
  return not policy or (not previousInstance and scopeId(scope) and not policy.hidden[scope])
end

--- Share unchanged lists and rows; allocate a projection only on removal.
local function filterRows(data, keep)
  if type(data) ~= "table" or type(data.items) ~= "table" then return data end
  local items
  for index, row in ipairs(data.items) do
    if type(row) == "table" and keep(row) then
      if items then items[#items + 1] = row end
    elseif not items then
      items = {}
      for previous = 1, index - 1 do items[previous] = data.items[previous] end
    end
  end
  if not items then return data end
  local result = {}
  for key, value in pairs(data) do result[key] = value end
  result.items = items
  return result
end

function M.withoutHiddenChats(data, policy, previousInstance)
  if not policy then return data end
  return filterRows(data, function(row)
    return (row.kind ~= "chat" and not M.chatThread(row.id))
      or M.allowsScope(policy, row.appScope, previousInstance)
  end)
end

-- Conversation lists mix two independently permitted sources. History
-- responses have no row kind; always classify those by their thread ID.
local function keepNonSms(row)
  return row.kind ~= "sms" and not (row.kind == nil and M.smsThread(row.id))
end

function M.withoutSms(data)
  return filterRows(data, keepNonSms)
end

return M
