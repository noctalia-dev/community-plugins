--!nonstrict
-- Price alerts: edge-triggered with a cooldown. An alert fires when its
-- condition becomes true (it re-arms once the condition is false again), and
-- never twice within its cooldown. Pure: the service notifies and saves.

local M = {}

-- True / false, or nil when the price is unknown.
function M.condition(alert, ticker): boolean?
  if ticker == nil then
    return nil
  end
  if alert.kind == "above" then
    return ticker.price >= alert.value
  elseif alert.kind == "below" then
    return ticker.price <= alert.value
  elseif alert.kind == "move_pct" then
    if ticker.change24h == nil then
      return nil
    end
    return math.abs(ticker.change24h) >= alert.value
  end
  return nil
end

-- `armed[id]` is false while an alert's condition stays true after firing.
-- Returns the alerts that fire now and updates `armed` and `last_fired_ms`.
function M.evaluate(alerts, tickers, armed: { [string]: boolean }, now: number)
  local fired = {}
  for _, alert in alerts do
    local hit = if alert.enabled then M.condition(alert, tickers[alert.symbol]) else nil
    if hit == false then
      armed[alert.id] = true
    elseif hit == true and armed[alert.id] ~= false then
      local cooling = alert.last_fired_ms ~= nil and now - alert.last_fired_ms < alert.cooldown_min * 60000
      armed[alert.id] = false
      if not cooling then
        alert.last_fired_ms = now
        table.insert(fired, alert)
      end
    end
  end
  return fired
end

return M
