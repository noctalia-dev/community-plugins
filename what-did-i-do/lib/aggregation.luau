-- lib/aggregation.luau — query/aggregation layer over the session store.
--
-- Pure functions over plain data; used by the service for state publishing,
-- the panel for rendering, and the launcher for quick summaries. Sessions
-- carry their own dateKey so day buckets are stable across midnight.
--
-- All inputs are defensively validated: history files are user data that can
-- be malformed (spec §20), so no function here ever throws on bad rows.

local M = {}

local function safeNum(v)
  if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
    return v
  end
  return nil
end

-- rankApps(sessions, limit) -> { { appId, appName, seconds }, ... } sorted desc.
-- Rows without appId fall back to appName; rows with neither are ignored.
function M.rankApps(sessions, limit)
  local totals = {}
  local names = {}
  local order = {}
  local n = 0
  for _, row in ipairs(sessions or {}) do
    if type(row) == "table" then
      local key = row.appId or row.appName
      if type(key) == "string" and key ~= "" then
        if totals[key] == nil then
          n = n + 1
          order[n] = key
          names[key] = row.appName or key
        end
        totals[key] = (totals[key] or 0) + (safeNum(row.durationSeconds) or 0)
      end
    end
  end
  local ranked = {}
  for i = 1, n do
    local key = order[i]
    ranked[i] = { appId = key, appName = names[key] or key, seconds = totals[key] or 0 }
  end
  table.sort(ranked, function(a, b)
    if a.seconds ~= b.seconds then
      return a.seconds > b.seconds
    end
    return a.appName < b.appName
  end)
  -- Drop zero-second rows: a focused-but-unmeasurable sample (sub-second
  -- session, rounding to 0 after locale formatting) is not "usage" a user
  -- can read. rankApps keeps the *data* side honest; views show empty-state
  -- hints instead of a list of "0m".
  local visible = {}
  for _, row in ipairs(ranked) do
    if (row.seconds or 0) > 0 then
      visible[#visible + 1] = row
    end
  end
  ranked = visible
  if limit and #ranked > limit then
    local out = {}
    for i = 1, limit do
      out[i] = ranked[i]
    end
    return out
  end
  return ranked
end

-- daySummary(sessions, dateKey, appLimit) -> {
--   total, appCount, topApps, sessions, sessionCount, currentAppId?
-- }
function M.daySummary(sessions, dateKey, appLimit)
  local dayRows = {}
  for _, row in ipairs(sessions or {}) do
    if type(row) == "table" and row.dateKey == dateKey then
      table.insert(dayRows, row)
    end
  end
  local topApps = M.rankApps(dayRows, appLimit)
  -- The day total covers every row, not just the ranked top apps: the big
  -- number in the panel must not undercount when more apps than appLimit
  -- were used. Shares in the UI are computed against this same total.
  local total = 0
  for _, row in ipairs(dayRows) do
    total = total + (safeNum(row.durationSeconds) or 0)
  end
  local currentAppId = nil
  local latest = nil
  for _, row in ipairs(dayRows) do
    if row.open then
      currentAppId = row.appId
      latest = row
    end
  end
  return {
    total = total,
    appCount = #topApps,
    topApps = topApps,
    sessions = dayRows,
    sessionCount = #dayRows,
    currentAppId = currentAppId,
    currentSession = latest,
  }
end

-- weekSummary(sessions, todayKey, days, appLimit) -> {
--   perDay = { { dateKey, total } }, total, appCount, topApps, dailyAverage, sessionCount
-- }
-- todayKey is the newest day in the window; the window walks backwards from it.
function M.weekSummary(sessions, todayKey, days, appLimit)
  days = days or 7
  local window = {}
  for i = 0, days - 1 do
    window[M.shiftDateKey(todayKey, -(days - 1 - i))] = true
  end
  local inWindow = {}
  for _, row in ipairs(sessions or {}) do
    if type(row) == "table" and type(row.dateKey) == "string" and window[row.dateKey] then
      table.insert(inWindow, row)
    end
  end
  local perDay = {}
  local totalsByKey = {}
  for _, row in ipairs(inWindow) do
    totalsByKey[row.dateKey] = (totalsByKey[row.dateKey] or 0) + (safeNum(row.durationSeconds) or 0)
  end
  for i = 0, days - 1 do
    local key = M.shiftDateKey(todayKey, -(days - 1 - i))
    table.insert(perDay, { dateKey = key, total = totalsByKey[key] or 0 })
  end
  local topApps = M.rankApps(inWindow, appLimit)
  -- Week total covers every session in the window (see daySummary).
  local total = 0
  for _, row in ipairs(inWindow) do
    total = total + (safeNum(row.durationSeconds) or 0)
  end
  return {
    perDay = perDay,
    total = total,
    appCount = #topApps,
    topApps = topApps,
    dailyAverage = total / days,
    sessionCount = #inWindow,
    days = days,
  }
end

-- shiftDateKey(dateKey, deltaDays) -> key shifted by whole days.
-- Pure date arithmetic on the YYYY-MM-DD key itself (no os.date dependency,
-- so the window is stable even if the host clock changes between calls).
function M.shiftDateKey(dateKey, deltaDays)
  if type(dateKey) ~= "string" then
    return nil
  end
  local y, m, d = dateKey:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not y then
    return nil
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  -- days_from_civil (proleptic Gregorian), Howard Hinnant's algorithm.
  local yy = y - (m <= 2 and 1 or 0)
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local z = era * 146097 + doe - 719468 + deltaDays

  z = z + 719468
  era = math.floor(z / 146097)
  doe = z - era * 146097
  yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local ry = yoe + era * 400
  local rdoy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * rdoy + 2) / 153)
  local rd = rdoy - math.floor((153 * mp + 2) / 5) + 1
  local rm = mp + (mp < 10 and 3 or -9)
  ry = ry + (rm <= 2 and 1 or 0)
  return string.format("%04d-%02d-%02d", ry, rm, rd)
end

return M
