--!nonstrict
-- The daily summary notification: when it is due and what it names. Pure;
-- the service checks freshness, formats and notifies, and persists the day
-- it last sent (prefs.json summary_day) so a restart never sends it twice.

local M = {}

local function trim(s: string): string
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- "HH:MM" (24 h) -> minutes after midnight, or nil.
function M.parseTime(text: any): number?
  if type(text) ~= "string" then
    return nil
  end
  local h, m = string.match(trim(text), "^(%d%d?):(%d%d)$")
  h, m = tonumber(h), tonumber(m)
  if h == nil or m == nil or h > 23 or m > 59 then
    return nil
  end
  return h * 60 + m
end

-- Due from `atMinutes` local time until midnight on a day it was not sent
-- yet. A day whose data stays stale (or with the computer off) is skipped.
function M.due(atMinutes: number, day: string, minutes: number, lastDay: string?): boolean
  return lastDay ~= day and minutes >= atMinutes
end

-- The holding with the largest absolute move today, among those worth at
-- least 1% of the portfolio (dust swings by tens of percent).
function M.biggestMover(holdings)
  local best = nil
  for _, h in holdings or {} do
    local pct = h.today and h.today.pct
    if pct ~= nil and (h.allocation or 0) >= 0.01 and (best == nil or math.abs(pct) > math.abs(best.today.pct)) then
      best = h
    end
  end
  return best
end

return M
