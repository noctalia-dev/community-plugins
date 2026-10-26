local Analytics = require("../lib/analytics.luau")
local total = 0
local function test(name, fn) fn(); total += 1; print("PASS " .. name) end
local function period()
  return { totalTokens = 100, costUsd = 0, capabilities = {tokenComponents = true},
    outputTokens = 20, cacheReadTokens = 50, models = {A = 60, B = 40},
    modelCosts = {A = 0}, modelOutputs = {A = 10}, sessions = {} }
end
local function history()
  return { daily = {{date = "2026-10-23", tokens = 0, cost = 0, messages = 3,
    tokenComponentsAvailable = false, outputTokens = 22,
    perModel = {A = {tokens = 0, cost = 0, outputTokens = 22}}, perClient = {codex = {tokens = 0, cost = 0}} }},
    monthly = {{month = "2026-10", tokens = 10, cost = 1, outputTokens = 22}},
    summary = {totalTokens = 5000, totalCost = 9, activeDays = 10} }
end

test("producer periods and component capabilities preserve unknown and zero", function()
  local today, month = period(), period()
  month.capabilities.tokenComponents = false
  month.unpricedTokens, month.modelUnpricedTokens = 12, {A = 12}
  local value = Analytics.normalize({periods = {today = today, month = month}})
  assert(value.status == "ready" and value.periods.today.totals.tokens == 100)
  assert(value.periods.today.totals.cost == 0 and value.periods.today.totals.messages == nil)
  assert(value.periods.today.models[1].name == "A" and value.periods.today.models[1].cost == 0)
  assert(value.periods.today.models[2].cost == nil and value.periods.today.models[1].inputTokens == nil)
  assert(value.periods.today.totals.outputTokens == 20 and value.periods.month.totals.outputTokens == nil)
  assert(value.periods.month.models[1].outputTokens == nil and not value.periods.allTime.available)
  assert(value.periods.month.models[1].unpricedTokens == 12 and value.periods.month.totals.unpricedTokens == 12)
  local restored = Analytics.restoreUsage(Analytics.cacheUsage(value))
  assert(restored.periods.month.models[1].unpricedTokens == 12)
  assert(Analytics.normalize({periods = "bad"}).status == "unavailable")
end)

test("recent sessions are bounded without altering aggregate totals or leaking private fields", function()
  local raw = period()
  for i = 1, 205 do
    raw.sessions["codex:" .. i] = {sessionId = tostring(i), client = "codex", totalTokens = i,
      lastUsedAt = "2026-10-23T10:" .. string.format("%02d", math.floor((i-1)/60)) .. ":" .. string.format("%02d", (i-1)%60) .. "Z",
      projectId = "/private/path", title = string.rep("t", 200), prompt = "private", credentials = "private",
      models = {A = 4}, modelCosts = {A = 0}, inputTokens = 0, reasoningTokens = 5, outputTokens = 10 }
  end
  local value = Analytics.normalize({periods = {today = raw, allTime = raw}, sessionDetailsOmitted = {today = 7}})
  local p = value.periods.today
  assert(#p.sessions == 200 and p.sessionCount == 205 and p.sessionOmitted == 7 and p.sessionTruncated and p.sessionsIncomplete)
  assert(p.sessions[1].sessionId == "205" and p.sessions[200].sessionId == "6")
  assert(p.sessions[1].key == "codex:205" and p.sessions[1].inputTokens == 0 and #p.sessions[1].title == 160)
  assert(p.sessions[1].projectId == nil and p.sessions[1].prompt == nil and p.sessions[1].credentials == nil)
  assert(p.sessions[1].models[1].tokens == 4 and p.totals.tokens == 100)
  assert(not value.periods.allTime.sessionsAvailable and #value.periods.allTime.sessions == 0)
  local restored = Analytics.restoreUsage(Analytics.cacheUsage(value))
  assert(restored.periods.today.sessionCount == 205 and restored.periods.today.sessionTruncated)
  assert(restored.periods.today.sessionOmitted == 7 and #restored.periods.today.sessions == 200)
end)

test("models are bounded and stable when source order changes", function()
  local raw = period(); raw.models = {}
  for i = 1, 130 do raw.models["model-" .. i] = i end
  local p = Analytics.normalize({periods = {today = raw}}).periods.today
  assert(#p.models == 128 and p.modelCount == 130 and p.modelsTruncated)
  assert(p.models[1].name == "model-130" and p.models[128].name == "model-3")
end)

test("daily history is chronological and never invents old token components or lifetime totals", function()
  local raw = history()
  table.insert(raw.daily, {date = "2026-10-22", tokens = 2, tokenComponentsAvailable = true, outputTokens = 0,
    perModel = {B = {tokens = 2, outputTokens = 0}}})
  local value = assert(Analytics.history(raw))
  assert(value.daily[1].date == "2026-10-22" and value.daily[2].tokens == 0)
  assert(value.daily[1].outputTokens == 0 and value.daily[1].perModel[1].outputTokens == 0)
  assert(value.daily[2].outputTokens == nil and value.daily[2].perModel[1].outputTokens == nil)
  assert(value.monthly[1].outputTokens == nil and value.summary.totalTokens == 5000)
  assert(value.daily[2].perModel[1].cost == 0 and value.daily[2].perClient[1].name == "codex")
end)

test("history retention and attribution limits report omitted detail in cache too", function()
  local raw = history(); raw.daily = {}; raw.monthly = {}
  for year = 1900, 2000 do
    for month = 1, 12 do raw.monthly[#raw.monthly + 1] = {month = string.format("%04d-%02d", year, month), tokens = 1} end
  end
  for month = 1, 12 do
    for day = 1, 28 do raw.daily[#raw.daily + 1] = {date = string.format("2025-%02d-%02d", month, day), tokens = 1} end
  end
  for day = 1, 28 do raw.daily[#raw.daily + 1] = {date = string.format("2026-01-%02d", day), tokens = 1} end
  for day = 1, 28 do raw.daily[#raw.daily + 1] = {date = string.format("2026-02-%02d", day), tokens = 1} end
  local attrs = {}; for i = 1, 140 do attrs["model" .. i] = {tokens = i} end
  raw.daily[#raw.daily].perModel = attrs
  local value = assert(Analytics.history(raw))
  assert(#value.daily == 370 and value.dailyCount == 392 and value.dailyTruncated)
  assert(#value.monthly == 1200 and value.monthlyCount == 1212 and value.monthlyTruncated)
  assert(#value.daily[#value.daily].perModel == 128 and value.daily[#value.daily].perModelCount == 140)
  local restored = assert(Analytics.restoreHistory(Analytics.cacheHistory(value)))
  assert(restored.dailyCount == 392 and restored.monthlyTruncated and restored.daily[#restored.daily].perModelTruncated)
end)

test("unsupported history envelopes and malformed arrays fail explicitly", function()
  assert(Analytics.history({}) == nil)
  local raw = history(); raw.daily = {bad = {date = "2026-10-23"}}
  assert(Analytics.history(raw) == nil)
end)
test("freshness reports source collection times and stale observations without device identity", function()
  local value = Analytics.normalize({periods = {today = period()}, updatedAt = "2026-10-23T11:00:00Z",
    devices = {{updatedAt = "2026-10-23T09:00:00Z", stale = true, name = "private", deviceId = "private"},
      {updatedAt = "2026-10-23T10:00:00Z", stale = false}, {stale = false}}})
  local f = value.freshness
  assert(f.sourceCount == 3 and f.staleCount == 1 and f.unknownCount == 1)
  assert(f.oldestUpdatedAt == "2026-10-23T09:00:00Z" and f.newestUpdatedAt == "2026-10-23T10:00:00Z")
  assert(f.name == nil and f.deviceId == nil and value.updatedAt == nil)
  local restored = Analytics.restoreUsage(Analytics.cacheUsage(value))
  assert(restored.freshness.sourceCount == 3 and restored.freshness.oldestUpdatedAt == f.oldestUpdatedAt)
  assert(not Analytics.normalize({periods = {today = period()}}).freshness.available)
end)

print(tostring(total) .. " analytics cases passed")
