local Model = require("../lib/model.luau")
local total = 0
local function test(name, fn)
  fn()
  total += 1
  print("PASS " .. name)
end
local function stats(providers) return { limits = { providers = providers } } end
local function row(provider, windows)
  return { provider = provider, windows = windows or {}, status = "ok", accountLabel = "Test" }
end

test("zero, used-percent fallback and missing values stay distinct", function()
  local rows = assert(Model.normalize(stats({ row("codex", {
    { remainingPercent = 0, usedPercent = 20 }, { usedPercent = 25 }, {},
    { remaining = 0, currency = "CNY" }, { remainingPercent = 0/0 },
  }) })))
  local windows = rows[1].windows
  assert(windows[1].value == 0 and windows[1].metric == "percent")
  assert(windows[2].value == 75 and windows[3].value == nil)
  assert(windows[4].value == 0 and windows[4].unit == "CNY")
  assert(windows[5].value == nil)
end)

test("stable priority preserves accounts, errors and stale state", function()
  local a, b = row("codex"), row("codex")
  a.accountLabel, b.accountLabel = "A", "B"
  b.status, b.stale = "unauthorized", true
  local rows = assert(Model.normalize(stats({ row("other"), row("antigravity"), a, row("deepseek"), b })))
  assert(#rows == 5 and rows[1].accountLabel == "A" and rows[2].accountLabel == "B")
  assert(rows[2].status == "unauthorized" and rows[2].stale)
  assert(rows[3].name == "DeepSeek" and rows[5].provider == "other")
end)

test("cache drops private and unrelated fields, round-trips zero", function()
  local input = row("deepseek", {{ remaining = 0, currency = "CNY" }})
  input.accountKey, input.credentials = "private", { secret = "private" }
  local normalized = assert(Model.normalize(stats({ input })))
  assert(normalized[1].accountKey == nil and normalized[1].credentials == nil)
  local cache = Model.cachePayload(normalized)
  assert(cache.limits.providers[1].accountKey == nil)
  local restored = assert(Model.normalize(cache))
  assert(restored[1].windows[1].value == 0)
end)

test("invalid payloads and bounded sizes fail visibly", function()
  assert(Model.normalize({}) == nil)
  assert(Model.normalize(stats({ bad = row("codex") })) == nil)
  assert(Model.normalize(stats({ row("codex", { bad = {} }) })) == nil)
  local many = {}
  for i = 1, 129 do many[i] = row("codex") end
  local rows, error = Model.normalize(stats(many))
  assert(rows == nil and error == "too_large")
end)

test("endpoint validation rejects embedded credentials and paths", function()
  assert(Model.origin(" http://127.0.0.1:17321/ ") == "http://127.0.0.1:17321")
  assert(Model.origin("https://hub.example") == "https://hub.example")
  assert(Model.origin("http://[::1]:17321") == "http://[::1]:17321")
  for _, url in ipairs({ "file:///tmp/key", "http://user:key@localhost", "http://localhost/api/stats", "http://localhost?key=x", "http://localhost:99999", "http://localhost\\evil" }) do
    assert(Model.origin(url) == nil, url)
  end
end)

test("credentials use only the Hub key and reject header injection", function()
  assert(Model.credential(" test-key\n", function() end) == "test-key")
  assert(Model.credential("{json}", function() return {credentials = {hub = {hostSecret = "hub-only"}, other = "no"}} end) == "hub-only")
  assert(Model.credential("{json}", function() return {} end) == nil)
  assert(Model.credential("key\nInjected: value", function() end) == nil)
  assert(Model.credential("", function() end) == nil)
end)
test("account identity survives order and label changes while regions and missing identities stay distinct", function()
  local a, b = row("codex"), row("codex")
  a.accountKey, b.accountKey = "account-a", "account-b"
  a.region, b.region = "a", "a"
  local first = assert(Model.normalize(stats({a, b})))
  a.accountLabel, b.accountLabel = "Renamed", "Renamed"
  local nextRows = assert(Model.normalize(stats({b, a})))
  assert(first[1].key == nextRows[2].key and first[2].key == nextRows[1].key)
  assert(first[1].key ~= first[2].key and first[1].key ~= "")
  local restored = assert(Model.normalize(Model.cachePayload(first), true))
  assert(restored[1].key == first[1].key)
  b.accountKey, b.region = a.accountKey, "b"
  local regions = assert(Model.normalize(stats({a, b})))
  assert(regions[1].key ~= regions[2].key)
  b.region = "a"
  local duplicate = assert(Model.normalize(stats({a, b})))
  assert(duplicate[1].key == "" and duplicate[2].key == "")
  a.accountKey = ""
  assert(assert(Model.normalize(stats({a})))[1].key == "")
end)

test("quota balance and reset credits keep exact zero/currency and discard detailed private riders", function()
  local input = row("other", {{remainingPercent = 50, remaining = 20, used = 20, limit = 40,
    metric = "requests", limitId = "limit-a", showMeter = false, detail = "Usage detail"}})
  input.balanceUsd = 0
  input.balance = {amount = 0, currency = "CNY", monthSpend = 3, planUsed = 0,
    monthSinceTracking = true, tranches = {{secret = "private"}}, unknown = "private"}
  input.resetCredits = {availableCount = 0, nextExpiresAt = "2026-11-01T00:00:00Z", grants = {{secret = "private"}}}
  local normalized = assert(Model.normalize(stats({input})))
  local p = normalized[1]
  assert(p.balanceUsd == 0 and p.balance.amount == 0 and p.balance.currency == "CNY" and p.balance.planUsed == 0)
  assert(p.balance.tranches == nil and p.balance.unknown == nil and p.resetCredits.grants == nil)
  assert(p.resetCredits.availableCount == 0 and p.windows[1].remaining == 20 and p.windows[1].sourceMetric == "requests")
  assert(not p.windows[1].showMeter and p.windows[1].limitId == "limit-a")
  local restored = assert(Model.normalize(Model.cachePayload(normalized), true))[1]
  assert(restored.balance.amount == 0 and restored.resetCredits.availableCount == 0 and restored.windows[1].remaining == 20)
end)

test("anonymous Antigravity keys remain device-scoped even with a nonempty local account key", function()
  local a, b = row("antigravity"), row("antigravity")
  a.accountKey, b.accountKey = "rpc-local", "rpc-local"
  a.sourceDeviceId, b.sourceDeviceId = "device-a", "device-b"
  local rows = assert(Model.normalize(stats({a, b})))
  assert(rows[1].key ~= "" and rows[1].key ~= rows[2].key)
  assert(rows[1].accountEmail == nil and rows[1].sourceDeviceId == nil)
  a.accountEmail, b.accountEmail = "same@example.invalid", "same@example.invalid"
  local first = assert(Model.normalize(stats({a})))[1].key
  local second = assert(Model.normalize(stats({b})))[1].key
  assert(first == second and first ~= "")
  a.accountEmail, a.sourceDeviceId = nil, nil
  assert(assert(Model.normalize(stats({a})))[1].key == "")
end)

test("third-party adapter marks survive cache without changing account identity", function()
  for adapterId, name in pairs({["newapi-account"] = "New API", ["newapi-token"] = "New API",
      sub2api = "Sub2API", custom = "Third-party APIs", unknown = "Third-party APIs"}) do
    local input = row("thirdparty")
    input.accountKey, input.adapterId = "synthetic-account", adapterId
    local normalized = assert(Model.normalize(stats({input})))[1]
    assert(normalized.provider == "thirdparty" and normalized.adapterId == adapterId and normalized.name == name)
    local restored = assert(Model.normalize(Model.cachePayload({normalized}), true))[1]
    assert(restored.adapterId == adapterId and restored.name == name and restored.key == normalized.key)
    input.adapterId = nil
    assert(assert(Model.normalize(stats({input})))[1].key == normalized.key)
  end
  local input = row("codex")
  input.adapterId = "sub2api"
  local normalized = assert(Model.normalize(stats({input})))[1]
  assert(normalized.adapterId == "" and normalized.name == "Codex")
end)

test("maximum quota projection and cache recovery yield without changing identities or windows", function()
  local input = {}
  for index = 1, 16 do
    local windows = {}
    for window = 1, 32 do windows[window] = {label = string.rep("w", 256), remainingPercent = window} end
    input[index] = row("codex", windows)
    input[index].accountKey = "maximum-" .. index
  end
  local steps = 0
  local function step() steps += 1 end
  local normalized = assert(Model.normalize(stats(input), false, step))
  assert(steps == 80 and #normalized == 16 and #normalized[16].windows == 32)
  local payload = Model.cachePayload(normalized, step)
  assert(steps == 160)
  local restored = assert(Model.normalize(payload, true, step))
  assert(steps == 240 and restored[16].key == normalized[16].key)
  assert(restored[16].windows[32].value == 32 and #restored[16].windows[32].label == 256)
end)

test("total quota windows reject excess before projecting or restoring a partial snapshot", function()
  local input = {}
  for index = 1, 16 do
    local windows = {}
    for window = 1, 32 do windows[window] = {remainingPercent = 50} end
    input[index] = row("codex", windows)
  end
  local normalized = assert(Model.normalize(stats(input)))
  assert(#normalized == 16 and #normalized[16].windows == 32)
  input[17] = row("codex", {{remainingPercent = 0}})
  local steps = 0
  local result, error = Model.normalize(stats(input), false, function() steps += 1 end)
  assert(result == nil and error == "too_large" and steps == 0)
  result, error = Model.normalize(stats(input), true)
  assert(result == nil and error == "too_large")
  -- Providers without windows still retain the independent provider cap.
  local empty = {}
  for index = 1, 128 do empty[index] = row("codex") end
  assert(#assert(Model.normalize(stats(empty))) == 128)
end)

test("normalization processes at most eight windows between yields including empty providers", function()
  local visited, previous, yields = 0, 0, 0
  local windows = {}
  for index = 1, 32 do
    windows[index] = setmetatable({}, {__index = function(_, key)
      if key == "remainingPercent" then visited += 1; return 50 end
      return nil
    end})
  end
  Model.normalize(stats({row("codex", windows), row("deepseek", {})}), false, function()
    -- The normalizer reads the percentage twice for the display value and
    -- twice more when retaining the original value.
    assert(visited - previous <= 8 * 4)
    previous, yields = visited, yields + 1
  end)
  assert(visited == 32 * 4 and yields == 6)
end)

print(tostring(total) .. " model cases passed")
