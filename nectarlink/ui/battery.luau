--!nonstrict
-- Format Android's estimate; never infer a charge time from the percentage.
local M = {}

function M.estimate(battery)
  if type(battery) ~= "table" or battery.charging ~= true then return nil end
  local minutes = battery.fullInMinutes
  if type(minutes) ~= "number" or not (minutes > 0 and minutes <= 24 * 60 and minutes % 1 == 0) then
    return nil
  end
  if minutes < 60 then return noctalia.tr("battery.estimate_minutes", { minutes = minutes }) end
  local hours, rest = math.floor(minutes / 60), minutes % 60
  if rest == 0 then return noctalia.tr("battery.estimate_hours", { hours = hours }) end
  return noctalia.tr("battery.estimate_hours_minutes", { hours = hours, minutes = rest })
end

return M
