-- Explicit Hub 0.68 projections. Unknown source fields never enter published state/cache.
local Time = require("./time.luau")
local Analytics = {}
local MAX_MODELS, MAX_SESSIONS, MAX_DAYS, MAX_MONTHS = 128, 200, 370, 1200
local components = { "outputTokens", "cacheReadTokens", "cacheWriteTokens", "unclassifiedTokens" }
local function number(value)
  return type(value) == "number" and value == value and value >= 0 and value < math.huge and value or nil
end
local function text(value, limit)
  if type(value) ~= "string" then return "" end
  local bounded = value:sub(1, limit or 160):gsub("[%c]", " ")
  while #bounded > 0 and not utf8.len(bounded) do bounded = bounded:sub(1, -2) end
  return bounded
end
local function metrics(source, fields)
  local target = {}
  for _, field in ipairs(fields) do target[field] = number(source[field]) end
  return target
end
local function checkpoint(step, count)
  if step and count % 32 == 0 then step() end
end
local function compare(a, b)
  if a.rank ~= b.rank then return a.rank < b.rank end
  return a.key < b.key
end
-- Keep the newest/largest K without retaining or sorting an unbounded extra array.
local function top(source, maximum, rank, step, rowType)
  local heap, count = {}, 0
  for key, row in pairs(source) do
    count += 1
    if type(key) == "string" and type(row) == (rowType or "table") and (rowType ~= "number" or number(row) ~= nil) and maximum > 0 then
      local item = { key = key, row = row, rank = rank(row, key) }
      if #heap < maximum then
        heap[#heap + 1] = item
        local i = #heap
        while i > 1 do
          local parent = math.floor(i / 2)
          if not compare(heap[i], heap[parent]) then break end
          heap[i], heap[parent], i = heap[parent], heap[i], parent
        end
      elseif compare(heap[1], item) then
        heap[1] = item
        local i = 1
        while i * 2 <= #heap do
          local child = i * 2
          if child < #heap and compare(heap[child + 1], heap[child]) then child += 1 end
          if not compare(heap[child], heap[i]) then break end
          heap[i], heap[child], i = heap[child], heap[i], child
        end
      end
    end
    checkpoint(step, count)
  end
  table.sort(heap, function(a, b) return compare(b, a) end)
  return heap, count
end
local function models(source, costs, extras, step)
  if type(source) ~= "table" then return {}, 0, false end
  local rows, count = {}, 0
  local selected, count = top(source, MAX_MODELS, function(value) return number(value) or 0 end, step, "number")
  for _, item in ipairs(selected) do
    local row = { name = text(item.key), key = #item.key <= 512 and item.key or "", tokens = number(item.row),
      cost = type(costs) == "table" and number(costs[item.key]) or nil }
    if extras then
      for field, map in pairs(extras) do
        if type(map) == "table" then row[field] = number(map[item.key]) end
      end
    end
    rows[#rows + 1] = row
  end
  return rows, count, count > #rows
end
local sessionFields = { "totalTokens", "costUsd", "messageCount", "inputTokens", "outputTokens",
  "cacheReadTokens", "cacheWriteTokens", "reasoningTokens", "timedOutputTokens", "timedDurationMs",
  "contextTokens", "contextWindow" }
local function sessions(source, step)
  if type(source) ~= "table" then return {}, 0 end
  local selected, count = top(source, MAX_SESSIONS, function(row)
    return Time.parse(row.lastUsedAt) or -math.huge
  end, step)
  local rows = {}
  for index, item in ipairs(selected) do
    local raw, row = item.row, metrics(item.row, sessionFields)
    row.key = #item.key <= 512 and not item.key:find("[%c]") and item.key or ""
    for _, field in ipairs({ "client", "sessionId", "title", "projectLabel", "sessionKind" }) do
      row[field] = text(raw[field], field == "sessionId" and 256 or 160)
    end
    row.startedAt, row.lastUsedAt = text(raw.startedAt, 64), text(raw.lastUsedAt, 64)
    row.archived, row.turnEnded = raw.archived == true, raw.turnEnded == true
    row.models, row.modelCount, row.modelsTruncated = models(raw.models, raw.modelCosts, nil, step)
    rows[#rows + 1] = row
    checkpoint(step, index)
  end
  return rows, count
end
local function freshness(devices, step)
  if type(devices) ~= "table" then return { available = false } end
  for key in pairs(devices) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #devices then return { available = false } end
  end
  local out = { available = true, sourceCount = #devices, staleCount = 0, unknownCount = 0 }
  local oldest, newest
  for index, device in ipairs(devices) do
    if type(device) == "table" then
      if device.stale == true then out.staleCount += 1 end
      local epoch = Time.parse(device.updatedAt)
      if epoch then
        if not oldest or epoch < oldest then oldest, out.oldestUpdatedAt = epoch, text(device.updatedAt, 64) end
        if not newest or epoch > newest then newest, out.newestUpdatedAt = epoch, text(device.updatedAt, 64) end
      end
      if not epoch or type(device.stale) ~= "boolean" then out.unknownCount += 1 end
    else out.unknownCount += 1 end
    checkpoint(step, index)
  end
  return out
end
function Analytics.normalize(data, step)
  if type(data) ~= "table" or type(data.periods) ~= "table" then
    return { status = "unavailable", error = "", periods = {} }
  end
  local result = { status = "unavailable", error = "", periods = {}, freshness = freshness(data.devices, step) }
  for _, name in ipairs({ "today", "month", "allTime" }) do
    local raw = data.periods[name]
    if type(raw) == "table" then
      result.status = "ready"
      local hasComponents = type(raw.capabilities) == "table" and raw.capabilities.tokenComponents == true
      local totals = { tokens = number(raw.totalTokens), cost = number(raw.costUsd) }
      if hasComponents then
        for _, field in ipairs(components) do totals[field] = number(raw[field]) end
      end
      totals.unpricedTokens = number(raw.unpricedTokens)
      local extra = { unpricedTokens = raw.modelUnpricedTokens }
      if hasComponents then
        extra.outputTokens, extra.cacheReadTokens = raw.modelOutputs, raw.modelCacheReads
        extra.cacheWriteTokens, extra.unclassifiedTokens = raw.modelCacheWrites, raw.modelUnclassifiedTokens
      end
      local modelRows, modelCount, modelTruncated = models(raw.models, raw.modelCosts, extra, step)
      local available = name ~= "allTime" and type(raw.sessions) == "table"
      local sessionRows, sessionCount = {}, 0
      if available then sessionRows, sessionCount = sessions(raw.sessions, step) end
      local omitted = type(data.sessionDetailsOmitted) == "table" and number(data.sessionDetailsOmitted[name]) or nil
      result.periods[name] = { available = true, totals = totals, tokenComponentsAvailable = hasComponents,
        models = modelRows, modelCount = modelCount, modelsTruncated = modelTruncated,
        sessions = sessionRows, sessionsAvailable = available, sessionCount = sessionCount,
        sessionOmitted = omitted or 0, sessionTruncated = sessionCount > #sessionRows,
        sessionsIncomplete = (omitted or 0) > 0 or sessionCount > #sessionRows }
    else
      result.periods[name] = { available = false, totals = {}, models = {}, sessions = {}, sessionsAvailable = false }
    end
  end
  return result
end
local historyFields = { "tokens", "cost", "messages", "activeTimeMs", "unpricedTokens" }
local function attribution(raw, withComponents, step, budget)
  if type(raw) ~= "table" then return {}, 0, false end
  local chosen, count = top(raw, math.min(MAX_MODELS, budget.remaining), function(row) return number(row.tokens) or 0 end, step)
  local rows = {}
  for _, item in ipairs(chosen) do
    local row = metrics(item.row, { "tokens", "cost", "messages", "unpricedTokens" })
    row.name, row.key = text(item.key), #item.key <= 512 and item.key or ""
    if withComponents then for _, field in ipairs(components) do row[field] = number(item.row[field]) end end
    rows[#rows + 1] = row
  end
  budget.remaining -= #rows
  return rows, count, count > #rows
end
local function buckets(raw, label, maximum, step, budget)
  local rows, count = {}, 0
  -- Source arrays are validated; a map with unexpected keys is not another supported shape.
  for key in pairs(raw) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #raw then return nil end
  end
  local map = {}
  for index, value in ipairs(raw) do
    count += 1
    if type(value) ~= "table" or type(value[label]) ~= "string"
        or not value[label]:match(label == "date" and "^%d%d%d%d%-%d%d%-%d%d$" or "^%d%d%d%d%-%d%d$") then return nil end
    local stamp = value[label] .. (label == "date" and "T00:00:00Z" or "-01T00:00:00Z")
    if not Time.parse(stamp) then return nil end
    map[tostring(index)] = value
    checkpoint(step, count)
  end
  local selected = top(map, maximum, function(row) return row[label] end, step)
  for index, item in ipairs(selected) do
    local source = item.row
    local row = metrics(source, historyFields)
    row[label] = source[label]
    row.tokenComponentsAvailable = label == "date" and source.tokenComponentsAvailable == true
    if row.tokenComponentsAvailable then
      for _, field in ipairs(components) do row[field] = number(source[field]) end
    end
    for _, dimension in ipairs({ "perClient", "perModel" }) do
      local values, total, truncated = attribution(source[dimension], row.tokenComponentsAvailable, step, budget)
      row[dimension], row[dimension .. "Count"], row[dimension .. "Truncated"] = values, total, truncated
    end
    rows[#rows + 1] = row
    checkpoint(step, index)
  end
  -- Time series are chronological; views can reverse without altering the underlying totals.
  table.sort(rows, function(a, b) return a[label] < b[label] end)
  return rows, count
end
function Analytics.history(data, step)
  if type(data) ~= "table" or type(data.daily) ~= "table" or type(data.monthly) ~= "table"
      or type(data.summary) ~= "table" then return nil, "invalid_response" end
  local budget = { remaining = 4096 }
  local daily, dailyCount = buckets(data.daily, "date", MAX_DAYS, step, budget)
  local monthly, monthlyCount = buckets(data.monthly, "month", MAX_MONTHS, step, budget)
  if not daily or not monthly then return nil, "invalid_response" end
  local summary = metrics(data.summary, { "totalTokens", "totalCost", "activeDays", "currentStreak", "longestStreak",
    "peakDayTokens", "messages", "activeTimeMs", "unpricedTokens" })
  summary.favoriteModel = text(data.summary.favoriteModel)
  return { status = "ready", error = "", daily = daily, monthly = monthly, summary = summary,
    dailyCount = dailyCount, monthlyCount = monthlyCount, dailyTruncated = dailyCount > #daily,
    monthlyTruncated = monthlyCount > #monthly }
end
-- Rebuild supported wire fields from the bounded display projection. Restoring this
-- through normal validators prevents unknown cache fields from becoming UI state.
function Analytics.cacheUsage(value, step)
  local raw = { periods = {}, sessionDetailsOmitted = {}, snapshotCounts = {}, snapshotFreshness = value.freshness }
  for name, period in pairs(value.periods or {}) do
    if period.available then
      local out = { totalTokens = period.totals.tokens, costUsd = period.totals.cost,
        capabilities = { tokenComponents = period.tokenComponentsAvailable },
        models = {}, modelCosts = {}, modelOutputs = {}, modelCacheReads = {}, modelCacheWrites = {},
        modelUnclassifiedTokens = {}, modelUnpricedTokens = {}, sessions = {} }
      for _, field in ipairs(components) do out[field] = period.totals[field] end
      out.unpricedTokens = period.totals.unpricedTokens
      for _, model in ipairs(period.models) do
        if model.key ~= "" then
          out.models[model.key], out.modelCosts[model.key] = model.tokens, model.cost
          out.modelUnpricedTokens[model.key] = model.unpricedTokens
          out.modelOutputs[model.key], out.modelCacheReads[model.key] = model.outputTokens, model.cacheReadTokens
          out.modelCacheWrites[model.key], out.modelUnclassifiedTokens[model.key] = model.cacheWriteTokens, model.unclassifiedTokens
        end
      end
      for index, row in ipairs(period.sessions) do
        if row.key ~= "" then
          local session = metrics(row, sessionFields)
          for _, field in ipairs({ "client", "sessionId", "title", "projectLabel", "sessionKind", "startedAt", "lastUsedAt", "archived", "turnEnded" }) do
            session[field] = row[field]
          end
          session.models, session.modelCosts = {}, {}
          for _, model in ipairs(row.models) do
            if model.key ~= "" then session.models[model.key], session.modelCosts[model.key] = model.tokens, model.cost end
          end
          out.sessions[row.key] = session
        end
        checkpoint(step, index)
      end
      raw.periods[name] = out
      raw.snapshotCounts[name] = { modelCount = period.modelCount, sessionCount = period.sessionCount,
        sessionOmitted = period.sessionOmitted, sessionsAvailable = period.sessionsAvailable }
      -- Already discarded local rows are also omitted from cached detail.
      raw.sessionDetailsOmitted[name] = period.sessionOmitted + math.max(0, period.sessionCount - #period.sessions)
    end
  end
  return raw
end
local function cacheAttribution(rows, step)
  local map = {}
  for index, row in ipairs(rows) do
    local item = metrics(row, { "tokens", "cost", "messages", "unpricedTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "unclassifiedTokens" })
    if row.key ~= "" then map[row.key] = item end
    checkpoint(step, index)
  end
  return map
end
function Analytics.cacheHistory(value, step)
  local out = { daily = {}, monthly = {}, summary = value.summary, dailyCount = value.dailyCount, monthlyCount = value.monthlyCount }
  for _, tier in ipairs({ "daily", "monthly" }) do
    for index, row in ipairs(value[tier] or {}) do
      local item = metrics(row, { "tokens", "cost", "messages", "activeTimeMs", "unpricedTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "unclassifiedTokens" })
      item.date, item.month, item.tokenComponentsAvailable = row.date, row.month, row.tokenComponentsAvailable
      item.perModel, item.perClient = cacheAttribution(row.perModel, step), cacheAttribution(row.perClient, step)
      item.perModelCount, item.perClientCount = row.perModelCount, row.perClientCount
      out[tier][#out[tier] + 1] = item
      checkpoint(step, index)
    end
  end
  return out
end
local function restoredCount(value, minimum)
  local count = number(value)
  return count and math.floor(count) == count and math.max(count, minimum) or minimum
end
function Analytics.restoreUsage(raw, step)
  local result = Analytics.normalize(raw, step)
  if type(raw) ~= "table" then return result end
  local meta = raw.snapshotFreshness
  if type(meta) == "table" and meta.available == true and number(meta.sourceCount)
      and number(meta.staleCount) and number(meta.unknownCount) then
    result.freshness = { available = true, sourceCount = math.floor(meta.sourceCount),
      staleCount = math.min(math.floor(number(meta.staleCount) or 0), math.floor(meta.sourceCount)),
      unknownCount = math.min(math.floor(number(meta.unknownCount) or 0), math.floor(meta.sourceCount)),
      oldestUpdatedAt = Time.parse(meta.oldestUpdatedAt) and text(meta.oldestUpdatedAt, 64) or nil,
      newestUpdatedAt = Time.parse(meta.newestUpdatedAt) and text(meta.newestUpdatedAt, 64) or nil }
  end
  if type(raw.snapshotCounts) ~= "table" then return result end
  for name, period in pairs(result.periods) do
    local counts = raw.snapshotCounts[name]
    if type(counts) == "table" and period.available then
      period.modelCount = restoredCount(counts.modelCount, #period.models)
      period.modelsTruncated = period.modelCount > #period.models
      period.sessionCount = restoredCount(counts.sessionCount, #period.sessions)
      period.sessionOmitted = restoredCount(counts.sessionOmitted, 0)
      period.sessionsAvailable = name ~= "allTime" and counts.sessionsAvailable == true
      period.sessionTruncated = period.sessionCount > #period.sessions
      period.sessionsIncomplete = period.sessionOmitted > 0 or period.sessionTruncated
    end
  end
  return result
end
function Analytics.restoreHistory(raw, step)
  local result, error = Analytics.history(raw, step)
  if not result then return nil, error end
  for _, tier in ipairs({ "daily", "monthly" }) do
    result[tier .. "Count"] = restoredCount(raw[tier .. "Count"], #result[tier])
    result[tier .. "Truncated"] = result[tier .. "Count"] > #result[tier]
    local counts = {}
    local label = tier == "daily" and "date" or "month"
    for _, row in ipairs(raw[tier]) do counts[row[label]] = row end
    for _, row in ipairs(result[tier]) do
      for _, dimension in ipairs({ "perClient", "perModel" }) do
        row[dimension .. "Count"] = restoredCount(counts[row[label]][dimension .. "Count"], #row[dimension])
        row[dimension .. "Truncated"] = row[dimension .. "Count"] > #row[dimension]
      end
    end
  end
  return result
end
return Analytics
