--!nonstrict
-- US equities sessions as Binance Stocks trades them. Binance returns no
-- market phase over REST (only the `calendar` WebSocket stream has one), so
-- the phase is computed from the New York clock. Pure: the service passes
-- the date and time in America/New_York (noctalia.formatTime).
--
-- Sessions (Binance Stocks "Common Definition", tradingSession): RTH 09:30–
-- 16:00, EXTENDED 04:00–20:00 (pre-market + RTH + post-market), 24H adds an
-- overnight session 20:00 → 04:00 for symbols with overnightSupported.
-- On a 13:00 early close the post-market is assumed to run to 17:00, like
-- the NYSE Arca late session; Binance does not document it.

local days = require("./days.luau")

local M = {}

-- NYSE holidays and 13:00 early closes, from
-- https://www.nyse.com/markets/hours-calendars (checked 2026-10-19). Later
-- years count every weekday as a trading day until this table is extended.
local HOLIDAYS = {
  ["2026-01-01"] = true, ["2026-01-19"] = true, ["2026-02-16"] = true, ["2026-04-03"] = true,
  ["2026-05-25"] = true, ["2026-06-19"] = true, ["2026-07-03"] = true, ["2026-09-07"] = true,
  ["2026-11-26"] = true, ["2026-12-25"] = true,
  ["2027-01-01"] = true, ["2027-01-18"] = true, ["2027-02-15"] = true, ["2027-03-26"] = true,
  ["2027-05-31"] = true, ["2027-06-18"] = true, ["2027-07-05"] = true, ["2027-09-06"] = true,
  ["2027-11-25"] = true, ["2027-12-24"] = true,
}
local EARLY_CLOSE = { ["2026-11-27"] = true, ["2026-12-24"] = true, ["2027-11-26"] = true }

M.ZONE = "America/New_York"

local PRE_OPEN, OPEN, CLOSE, EARLY, POST_END, EARLY_POST_END = 4 * 60, 9 * 60 + 30, 16 * 60, 13 * 60, 20 * 60, 17 * 60

function M.tradingDay(day: string): boolean
  local n = days.number(day)
  if n == nil then
    return false
  end
  local weekday = days.weekday(n)
  return weekday >= 1 and weekday <= 5 and not HOLIDAYS[day]
end

-- The trading day before `day` ("YYYY-MM-DD"), or nil for a malformed day.
function M.previousTradingDay(day: string): string?
  if days.number(day) == nil then
    return nil
  end
  local prev = days.add(day, -1)
  while not M.tradingDay(prev) do
    prev = days.add(prev, -1)
  end
  return prev
end

-- "pre" | "open" | "post" | "overnight" | "closed" for a New York date
-- ("YYYY-MM-DD") and minutes since its midnight. `overnight`: the symbol
-- trades in Binance's overnight session; otherwise those hours are closed.
-- `extended == false`: no pre- or post-market either (exchangeInfo
-- extendedSession); nil means it has them.
function M.session(day: string, minutes: number, overnight: boolean?, extended: boolean?): string
  local trading = M.tradingDay(day)
  local early = EARLY_CLOSE[day] == true
  if trading then
    if minutes >= OPEN and minutes < (if early then EARLY else CLOSE) then
      return "open"
    elseif extended == false then
      -- Only the regular session; overnight hours are checked below.
    elseif minutes >= PRE_OPEN and minutes < OPEN then
      return "pre"
    elseif minutes >= (if early then EARLY else CLOSE) and minutes < (if early then EARLY_POST_END else POST_END) then
      return "post"
    end
  end
  -- The overnight session belongs to the next trading day: Sunday 20:00
  -- leads into Monday, Friday 20:00 into nothing.
  if overnight and ((minutes < PRE_OPEN and trading) or (minutes >= POST_END and M.tradingDay(days.add(day, 1)))) then
    return "overnight"
  end
  return "closed"
end

-- Parses noctalia.formatTime("%Y-%m-%d %H:%M", …) output into (day, minutes).
function M.parseClock(text: string): (string?, number?)
  local day, h, m = string.match(text or "", "^(%d%d%d%d%-%d%d%-%d%d) (%d%d):(%d%d)$")
  if day == nil then
    return nil, nil
  end
  return day, tonumber(h) * 60 + tonumber(m)
end

return M
