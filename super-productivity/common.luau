--!nonstrict

local M = {}

M.PANEL_ID = "redxtech/super-productivity:details"
M.SNAPSHOT_KEY = "super-productivity.snapshot"
M.ACTION_KEY = "super-productivity.action"
M.INTENT_KEY = "super-productivity.intent"
M.PROTOCOL_VERSION = 1
local request_sequence = 0

function M.without_trailing_slash(path)
  local normalized = tostring(path or ""):gsub("/+$", "")
  return normalized
end


function M.trim(value)
  return noctalia.string.trim(tostring(value or ""))
end


function M.truncate(value, maximum)
  value = tostring(value or "")
  maximum = math.max(1, math.floor(tonumber(maximum) or 36))
  local length = utf8.len(value)
  if length == nil then return "…" end
  if length <= maximum then return value end
  if maximum <= 1 then return "…" end
  local end_byte = utf8.offset(value, maximum)
  if end_byte == nil then return "…" end
  return value:sub(1, end_byte - 1) .. "…"
end

function M.task_due_at(task)
  if type(task) ~= "table" then return nil end
  return tonumber(task.dueAt)
end

function M.relative_due(task, now_ms)
  local due_at = M.task_due_at(task)
  if due_at == nil then return noctalia.tr("due.unscheduled") end
  now_ms = tonumber(now_ms) or noctalia.nowMs()
  local delta = due_at - now_ms
  local overdue = delta < 0
  local absolute = math.abs(delta)

  if absolute < 60000 then
    return overdue and noctalia.tr("due.just_overdue") or noctalia.tr("due.now")
  end

  local minutes = math.floor(absolute / 60000)
  if minutes < 60 then
    return overdue
      and noctalia.tr("due.overdue_minutes", { count = minutes })
      or noctalia.tr("due.in_minutes", { count = minutes })
  end

  local hours = math.floor(minutes / 60)
  if hours < 24 then
    return overdue
      and noctalia.tr("due.overdue_hours", { count = hours })
      or noctalia.tr("due.in_hours", { count = hours })
  end

  local days = math.floor(hours / 24)
  return overdue
    and noctalia.tr("due.overdue_days", { count = days })
    or noctalia.tr("due.in_days", { count = days })
end

function M.format_duration(milliseconds)
  local total_minutes = math.floor(math.max(0, tonumber(milliseconds) or 0) / 60000)
  local hours = math.floor(total_minutes / 60)
  local minutes = total_minutes % 60
  if hours > 0 and minutes > 0 then
    return tostring(hours) .. "h " .. tostring(minutes) .. "m"
  elseif hours > 0 then
    return tostring(hours) .. "h"
  end
  return tostring(minutes) .. "m"
end

function M.action_busy(action)
  return type(action) == "table" and action.status == "working"
end

function M.terminal_action(action)
  if type(action) ~= "table" then return false end
  return action.status == "success" or action.status == "error" or action.status == "unknown"
end

function M.send_intent(kind, fields)
  request_sequence += 1
  local request_id = "ui-" .. tostring(math.floor(noctalia.nowMs())) .. "-" .. tostring(request_sequence)
  local intent = fields or {}
  intent.type = kind
  intent.requestId = request_id
  intent.nonce = noctalia.nowMs()
  noctalia.state.set(M.INTENT_KEY, intent)
  return request_id
end

return M
