--!nonstrict
local M = {}

local function cfg(key: string, fallback: any): any
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

function M.refreshSeconds(): number
  return math.max(5, cfg("refresh_minutes", 30)) * 60
end

function M.hideLongerThanSeconds(): number
  return cfg("hide_longer_than_days", 3) * 86400
end

function M.pastWindowSeconds(): number
  return cfg("past_days", 7) * 86400
end

function M.remindersEnabled(): boolean
  return cfg("reminders_enabled", true)
end

function M.remindLeadSeconds(): number
  return cfg("remind_minutes", 30) * 60
end

function M.remindAtStart(): boolean
  return cfg("remind_at_start", true)
end

return M
