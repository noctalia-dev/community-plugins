--!nonstrict
local M = {}

function M.fmtDur(s: number): string
  if s < 0 then
    s = 0
  end
  local d = math.floor(s / 86400)
  local h = math.floor((s % 86400) / 3600)
  local m = math.floor((s % 3600) / 60)
  if d > 0 then
    return noctalia.tr("time.days_hours", { d = d, h = h })
  elseif h > 0 then
    return noctalia.tr("time.hours_minutes", { h = h, m = m })
  end
  return noctalia.tr("time.minutes", { m = m })
end

return M
