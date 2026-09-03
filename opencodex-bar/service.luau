--!nonstrict
-- OpenCodexBar service. This is the only entry that talks to OpenCodex.
-- The other entries exchange normalized snapshot, command, and action state.

local common = require("./common.luau")

local DEFAULT_BASE_URL = "http://127.0.0.1:10100"
local DEFAULT_POLL_SECONDS = 30
local DEFAULT_FORCE_MINUTES = 10
-- OpenCodex clamps the usage window at 30 days; the panel's contribution grid
-- wants every day it will give us.
local USAGE_RANGE = "30d"

-- noctalia.http refuses a request past 8 concurrent per plugin runtime, so a
-- deployment with several OAuth providers would silently lose the overflow.
-- Queue instead, and stay a little under the ceiling.
local MAX_IN_FLIGHT = 6
-- A refresh whose callbacks never all arrive would pin `inFlight` forever.
local REFRESH_TIMEOUT_MS = 60000

local snapshot = nil
local inFlight = false
local generation = 0
local refreshStartedMs = 0
local refreshPending = false
local forcePending = false
local lastRefreshMs = 0
local lastForcedRefreshMs = 0

local queue = {}
local activeRequests = 0
local pumping = false

local tokenCache = { path = nil, value = nil, loaded = false }
local actionInFlight = false
local actionGeneration = 0
local actionStartedMs = 0

local function nowMs()
  return noctalia.nowMs()
end

-- Finite numbers only: the JSON bridge happily hands back inf/NaN.
local function number(value)
  if type(value) ~= "number" or value ~= value then return nil end
  if value == math.huge or value == -math.huge then return nil end
  return value
end

local function clampedInt(value, fallback, minValue, maxValue)
  value = number(value)
  if value == nil then return fallback end
  value = math.floor(value)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function trim(value)
  if type(value) ~= "string" then return "" end
  return noctalia.string.trim(value)
end

local function nonEmpty(value)
  value = trim(value)
  return value ~= "" and value or nil
end

local function firstTable(value, keys)
  if type(value) ~= "table" then return nil end
  for _, key in ipairs(keys) do
    if type(value[key]) == "table" then return value[key] end
  end
  return value
end

-- A collection endpoint may answer with an array, an envelope around one, or a
-- single bare object; normalize all three to a plain array.
local function collection(value, keys)
  local result = firstTable(value, keys)
  if type(result) ~= "table" then return {} end
  if result.id ~= nil or result.provider ~= nil or result.alias ~= nil then
    return { result }
  end
  return result
end

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  return type(value) == "string" and value ~= "" and value or fallback
end

local function configNumber(key, fallback, minValue, maxValue)
  return clampedInt(noctalia.getConfig(key), fallback, minValue, maxValue)
end

local function baseUrl()
  return (trim(configString("base_url", DEFAULT_BASE_URL)):gsub("/+$", ""))
end

local function isLoopbackHost(host)
  host = host:lower():gsub("%.$", "")
  if host == "localhost" or host:match("%.localhost$") then return true end
  if host == "::1" or host == "0:0:0:0:0:0:0:1" then return true end

  local first, second, third, fourth = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if first == nil or tonumber(first) ~= 127 then return false end
  return tonumber(second) <= 255 and tonumber(third) <= 255 and tonumber(fourth) <= 255
end

-- Never put the admin credential on plaintext transport beyond the local
-- machine. Parsing the authority ourselves also rejects user-info and malformed
-- ports, where it is too easy for the apparent host not to be the real one.
local function requestBaseUrl()
  local url = baseUrl()
  local scheme, authority = url:match("^([%a][%w+%.%-]*)://([^/%?#]+)")
  if scheme == nil or authority == nil or authority:find("@", 1, true) ~= nil then return nil end

  local host
  if authority:sub(1, 1) == "[" then
    host = authority:match("^%[([^%]]+)%]$") or authority:match("^%[([^%]]+)%]:%d+$")
  else
    host = authority:match("^([^:]+)$") or authority:match("^([^:]+):%d+$")
  end
  if host == nil then return nil end

  scheme = scheme:lower()
  if scheme == "https" or (scheme == "http" and isLoopbackHost(host)) then return url end
  return nil
end

local function validToken(value)
  value = trim(value)
  if value == "" or value:find("%c") ~= nil then return nil end
  return value
end

local function adminToken()
  local fromEnvironment = validToken(noctalia.getenv("OPENCODEX_ADMIN_AUTH_TOKEN"))
  if fromEnvironment ~= nil then return fromEnvironment end

  local configured = trim(noctalia.getConfig("admin_token_file"))
  if configured == "" then return nil end

  -- Cached: this is read once per request otherwise, several times a poll.
  if tokenCache.loaded and tokenCache.path == configured then return tokenCache.value end
  local contents = noctalia.readFile(configured)
  tokenCache = {
    path = configured,
    value = type(contents) == "string" and validToken(contents) or nil,
    loaded = true,
  }
  return tokenCache.value
end

local function errorFor(kind, status, code)
  return { kind = kind, status = status, code = code }
end

local function startRequest(path, callback, options)
  options = options or {}
  local root = requestBaseUrl()
  if root == nil then
    callback(nil, errorFor("api_error"))
    return
  end

  local headers = { "Accept: application/json" }
  if options.body ~= nil then
    table.insert(headers, "Content-Type: application/json")
  end
  local token = adminToken()
  if token ~= nil then
    table.insert(headers, "X-OpenCodex-API-Key: " .. token)
  end

  local accepted = noctalia.http({
    url = root .. path,
    method = options.method or "GET",
    headers = headers,
    body = options.body,
  }, function(response)
    if type(response) ~= "table" then
      callback(nil, errorFor("offline"))
      return
    end

    local status = number(response.status) or 0
    -- transportOk == false with no status is a connection failure, not an API error.
    if response.ok == false and status == 0 then
      callback(nil, errorFor("offline"))
      return
    end
    if status == 401 or status == 403 then
      callback(nil, errorFor("auth_error", status))
      return
    end
    -- 404 means this endpoint does not apply to the deployment (a setup with no
    -- Codex pool has no /api/codex-auth), not that a refresh failed. Reporting
    -- it as an error would park such a setup in "degraded" for good.
    if status == 404 then
      callback(nil, errorFor("not_found", status))
      return
    end
    if status < 200 or status >= 300 then
      local code = nil
      if type(response.body) == "string" and response.body ~= "" then
        local decoded = noctalia.json.decode(response.body)
        if type(decoded) == "table" then code = nonEmpty(decoded.code) or nonEmpty(decoded.error) end
      end
      callback(nil, errorFor("api_error", status, code))
      return
    end

    if type(response.body) ~= "string" or response.body == "" then
      callback({}, nil)
      return
    end
    local decoded = noctalia.json.decode(response.body)
    if decoded == nil then
      callback(nil, errorFor("invalid_json"))
      return
    end
    callback(decoded, nil)
  end)

  if accepted ~= true then
    callback(nil, errorFor("offline"))
  end
end

local function pump()
  if pumping then return end
  pumping = true
  while activeRequests < MAX_IN_FLIGHT and #queue > 0 do
    local job = table.remove(queue, 1)
    activeRequests = activeRequests + 1
    job()
  end
  pumping = false
end

local function request(path, callback, options)
  table.insert(queue, function()
    startRequest(path, function(data, err)
      activeRequests = activeRequests - 1
      callback(data, err)
      pump()
    end, options)
  end)
  pump()
end

-- OpenCodex reports epoch times in either seconds or milliseconds.
local function timestamp(value)
  value = number(value)
  if value == nil or value <= 0 then return nil end
  if value < 100000000000 then return value * 1000 end
  return value
end

local function normalizedLabel(value)
  if type(value) ~= "string" then return "" end
  local label = trim(value):lower()
  return (label:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

local function canonicalWindow(label)
  local key = normalizedLabel(label)
  if key == "five_hour" or key == "five_hours" or key == "5_hour" or key == "5_hours" then return "five_hour" end
  if key == "weekly" or key == "week" then return "weekly" end
  if key == "monthly" or key == "month" then return "monthly" end
  return nil
end

local function quotaPercent(value)
  value = number(value)
  if value == nil then return nil end
  if value < 0 then return 0 end
  if value > 100 then return 100 end
  return value
end

local function windowPercent(value)
  if type(value) ~= "table" then return nil end
  return quotaPercent(value.usedPercent or value.percent or value.percentage or value.utilizationPercent)
end

local function windowReset(value)
  if type(value) ~= "table" then return nil end
  return timestamp(value.resetAtMs or value.resetAt or value.reset)
end

local function normalizeQuota(value)
  if type(value) ~= "table" then return nil end
  local source = type(value.quota) == "table" and value.quota or value
  local windows = {}
  local seen = {}

  local function add(id, label, percent, resetAt)
    percent = quotaPercent(percent)
    if percent == nil or seen[id] then return end
    seen[id] = true
    table.insert(windows, {
      id = id,
      label = label,
      usedPercent = percent,
      resetAtMs = timestamp(resetAt),
    })
  end

  add("five_hour", noctalia.tr("window.five_hour"), source.fiveHourPercent, source.fiveHourResetAt)
  add("weekly", noctalia.tr("window.weekly"), source.weeklyPercent, source.weeklyResetAt)
  add("monthly", noctalia.tr("window.monthly"), source.monthlyPercent, source.monthlyResetAt)

  local custom = source.customWindows
  if type(custom) == "table" then
    for index, item in ipairs(custom) do
      local raw = type(item) == "table" and item or { percent = item }
      local label = trim(type(item) == "table" and (item.label or item.name or item.window or item.id) or nil)
      if label == "" then label = tostring(index) end
      add(canonicalWindow(label) or ("custom:" .. normalizedLabel(label)), label, windowPercent(raw), windowReset(raw))
    end
    -- Object-shaped customWindows has no server-order guarantee, but is still
    -- supported for compatibility with older OpenCodex responses. Integer keys
    -- were already taken by the ipairs pass above and are skipped here.
    for label, item in pairs(custom) do
      if type(label) == "string" and type(item) == "table" then
        local id = canonicalWindow(label) or ("custom:" .. normalizedLabel(label))
        add(id, trim(item.label or item.name or label), windowPercent(item), windowReset(item))
      end
    end
  end

  -- OpenCodex's dashboard calls these "reset credits": each one instantly
  -- clears the account's current hourly and weekly limits.
  local resetCredits = number(source.resetCredits)
  if resetCredits ~= nil and resetCredits < 0 then resetCredits = nil end

  if #windows == 0 and resetCredits == nil then return nil end
  return {
    windows = windows,
    resetCredits = resetCredits,
    updatedAtMs = timestamp(source.updatedAtMs or source.updatedAt),
  }
end

-- Deliberately never an email address: the panel lists accounts in the open.
-- Give OpenCodex's native login a stable friendly name; aliases and log labels
-- identify added pool accounts without exposing their email addresses.
local function accountLabel(account, isMain)
  if isMain then
    local label = noctalia.tr("account.main")
    -- Some Noctalia builds retain the previous English catalog during plugin
    -- hot reloads. Keep the requested capitalization correct in that case.
    if label == "account.main" or label == "Main account" then return "Main Account" end
    return label
  end
  local label = nonEmpty(account.alias) or nonEmpty(account.logLabel)
  if label ~= nil then return label end
  return nonEmpty(account.id) or nonEmpty(account.accountId) or noctalia.tr("account.fallback")
end

-- `health` is an object ({ status = "healthy" }) on current OpenCodex builds,
-- and a bare string on older ones.
local function normalizeHealth(account)
  local health = account.health
  if type(health) == "table" then
    health = health.status or health.state
  end
  return nonEmpty(health), nonEmpty(account.healthLabel), nonEmpty(account.healthSummary)
end

local function activeIdFrom(value)
  if type(value) ~= "table" then return nil end
  local id = value.activeCodexAccountId or value.activeAccountId or value.activeId
  return type(id) == "string" and id or nil
end

-- `true`/`false` are meaningful, but so is "OpenCodex never said"; keep nil.
local function tribool(value)
  if value == true then return true end
  if value == false then return false end
  return nil
end

local function normalizeAccount(raw, activeId, isMain)
  local id = nonEmpty(raw.id) or nonEmpty(raw.accountId)
  if id == nil then return nil end
  local health, healthLabel, healthSummary = normalizeHealth(raw)
  return {
    id = id,
    label = accountLabel(raw, isMain),
    plan = nonEmpty(raw.plan),
    isMain = isMain == true,
    active = raw.active == true or (activeId ~= nil and activeId == id),
    paused = tribool(raw.paused),
    needsReauth = tribool(raw.needsReauth),
    health = health,
    healthLabel = healthLabel,
    healthSummary = healthSummary,
    quotaUnavailable = raw.quotaUnavailable == true,
    quota = normalizeQuota(raw.quota),
  }
end

local function normalizeAccounts(value, activeId)
  local accounts = {}
  for _, raw in ipairs(collection(value, { "accounts", "data", "items" })) do
    if type(raw) == "table" then
      local account = normalizeAccount(raw, activeId, raw.isMain == true)
      if account ~= nil then table.insert(accounts, account) end
    end
  end
  return accounts
end

local function normalizeProvider(raw)
  if type(raw) ~= "table" then return nil end
  local id = nonEmpty(raw.id) or nonEmpty(raw.provider) or nonEmpty(raw.name)
  if id == nil then return nil end
  local disabled = raw.disabled == true or raw.enabled == false or raw.authMode == "disabled" or raw.mode == "disabled"
  return {
    id = id,
    label = nonEmpty(raw.label) or nonEmpty(raw.displayName) or nonEmpty(raw.name) or id,
    enabled = not disabled,
    oauth = raw.authMode == "oauth",
    quota = nil,
    accounts = {},
    pool = nil,
  }
end

local function providerList(value)
  local result = {}
  for _, raw in ipairs(collection(value, { "providers", "data", "items" })) do
    local provider = normalizeProvider(raw)
    if provider ~= nil then table.insert(result, provider) end
  end
  return result
end

local function providerQuotaList(value)
  local result = {}
  -- Current builds answer with { generatedAt, reports = [...] }.
  for _, raw in ipairs(collection(value, { "reports", "quotas", "providerQuotas", "data", "items" })) do
    if type(raw) == "table" then
      local id = nonEmpty(raw.provider) or nonEmpty(raw.id) or nonEmpty(raw.providerId)
      local quota = normalizeQuota(raw.quota or raw)
      if id ~= nil and quota ~= nil then
        -- The report carries a presentable name ("OpenAI (Codex login)") that
        -- /api/providers does not.
        table.insert(result, { id = id, label = nonEmpty(raw.label), quota = quota })
      end
    end
  end
  return result
end

-- OpenCodex's report labels are mostly "<Vendor> <Product>" ("Anthropic
-- Claude", "xAI Grok"), but the Codex one reads "OpenAI (Codex login)" — it
-- names the auth method rather than the product. Restate it in the same shape.
-- Matching the suffix rather than the provider id keeps a plain OpenAI
-- API-key provider from being mislabelled "Codex".
local function displayLabel(id, label)
  if type(label) ~= "string" then return label end
  return (label:gsub("%s*%(Codex login%)%s*$", " Codex"))
end

local function providerById(providers, id)
  for _, provider in ipairs(providers) do
    if provider.id == id then return provider end
  end
  return nil
end

local function ensureProvider(providers, id, label)
  local provider = providerById(providers, id)
  if provider ~= nil then return provider end
  provider = {
    id = id,
    label = label or id,
    enabled = true,
    quota = nil,
    accounts = {},
    pool = nil,
  }
  table.insert(providers, provider)
  return provider
end

-- 1 = Monday .. 7 = Sunday, for laying days out in weekday rows.
local function weekdayOf(dateText)
  local y, m, d = dateText:match("^(%d+)-(%d+)-(%d+)")
  if y == nil then return nil end
  local stamp = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  if stamp == nil then return nil end
  return (tonumber(os.date("%w", stamp)) + 6) % 7 + 1
end

local function normalizeUsage(value)
  if type(value) ~= "table" then return nil end
  local source = type(value.usage) == "table" and value.usage or value
  local totals = source.totals or source.summary or source.aggregate or source
  if type(totals) ~= "table" then totals = {} end
  local function metric(keys)
    for _, key in ipairs(keys) do
      local n = number(totals[key])
      if n ~= nil then return n end
    end
    return 0
  end

  local usage = {
    range = USAGE_RANGE,
    totals = {
      requests = metric({ "requests", "requestCount", "totalRequests" }),
      inputTokens = metric({ "inputTokens", "promptTokens" }),
      outputTokens = metric({ "outputTokens", "completionTokens" }),
      cachedInputTokens = metric({ "cachedInputTokens", "cacheReadTokens" }),
      reasoningOutputTokens = metric({ "reasoningOutputTokens", "reasoningTokens" }),
      totalTokens = metric({ "totalTokens", "tokens" }),
      estimatedCostUsd = metric({ "estimatedCostUsd", "costUsd", "estimatedCost", "cost" }),
    },
  }

  -- Daily buckets expose per-model token counts but no dollar figure. Keep the
  -- model rows: they are the only way to remove a hidden provider from a day.
  -- A period-wide rate allocates each model's own known cost across its days;
  -- missing rates stay missing rather than turning a partial day into $0.
  local modelCostRates = {}
  local function modelKey(provider, model)
    return tostring(provider or ""):lower() .. "\31" .. tostring(model or ""):lower()
  end

  local models = {}
  for _, item in ipairs(type(source.models) == "table" and source.models or {}) do
    if type(item) == "table" then
      local model = nonEmpty(item.model) or nonEmpty(item.resolvedModel) or nonEmpty(item.id)
      local provider = nonEmpty(item.provider) or ""
      local tokens = number(item.totalTokens or item.tokens)
      local estimatedCost = number(item.estimatedCostUsd or item.costUsd or item.estimatedCost or item.cost)
      if model ~= nil and tokens ~= nil and tokens > 0 and estimatedCost ~= nil then
        modelCostRates[modelKey(provider, model)] = estimatedCost / tokens
      end
      if model ~= nil then
        table.insert(models, {
          model = model,
          provider = provider,
          requests = number(item.requests or item.requestCount) or 0,
          totalTokens = tokens or 0,
          estimatedCostUsd = estimatedCost or 0,
        })
      end
    end
  end
  table.sort(models, function(a, b) return a.requests > b.requests end)
  usage.models = models

  local function normalizeDayModels(day)
    local result = {}
    for _, item in ipairs(type(day.models) == "table" and day.models or {}) do
      if type(item) == "table" then
        local model = nonEmpty(item.model) or nonEmpty(item.resolvedModel) or nonEmpty(item.id)
        local provider = nonEmpty(item.provider) or ""
        if model ~= nil then
          local requests = number(item.requests or item.requestCount) or 0
          local tokens = number(item.totalTokens or item.tokens) or 0
          local rate = modelCostRates[modelKey(provider, model)]
          table.insert(result, {
            model = model,
            provider = provider,
            requests = requests,
            totalTokens = tokens,
            estimatedCostUsd = tokens > 0 and rate ~= nil and tokens * rate or nil,
          })
        end
      end
    end
    return result
  end

  local function dailyEstimatedCost(day, dayModels)
    local direct = number(day.estimatedCostUsd or day.costUsd or day.estimatedCost or day.cost)
    if direct ~= nil then return direct end
    if #dayModels == 0 then return nil end

    local total, hasUsage = 0, false
    for _, item in ipairs(dayModels) do
      if item.requests > 0 or item.totalTokens > 0 then
        hasUsage = true
        if item.estimatedCostUsd == nil then return nil end
        total = total + item.estimatedCostUsd
      end
    end
    return hasUsage and total or nil
  end

  -- Daily buckets, trimmed to what the panel's contribution grid draws. The
  -- weekday is resolved here so the panel never has to parse a date. `all`
  -- preserves the API's deduplicated request total when a later settings change
  -- removes the filter without a successful usage refresh.
  local days = {}
  for _, day in ipairs(type(source.days) == "table" and source.days or {}) do
    if type(day) == "table" then
      local date = day.date or day.day or day.localDate
      if type(date) == "string" then
        date = date:sub(1, 10)
        local dayModels = normalizeDayModels(day)
        local entry = {
          date = date,
          weekday = weekdayOf(date),
          requests = number(day.requests or day.requestCount) or 0,
          totalTokens = number(day.totalTokens or day.tokens) or 0,
          estimatedCostUsd = dailyEstimatedCost(day, dayModels),
          models = dayModels,
        }
        entry.all = {
          requests = entry.requests,
          totalTokens = entry.totalTokens,
          estimatedCostUsd = entry.estimatedCostUsd,
        }
        table.insert(days, entry)
      end
    end
  end
  usage.days = days

  local providers = {}
  for _, item in ipairs(type(source.providers) == "table" and source.providers or {}) do
    if type(item) == "table" then
      local id = nonEmpty(item.provider) or nonEmpty(item.id) or nonEmpty(item.name)
      if id ~= nil then
        table.insert(providers, {
          id = id,
          requests = number(item.requests or item.requestCount) or 0,
          totalTokens = number(item.totalTokens or item.tokens) or 0,
          estimatedCostUsd = number(item.estimatedCostUsd or item.costUsd or item.cost) or 0,
          shareRatio = number(item.shareRatio),
        })
      end
    end
  end
  table.sort(providers, function(a, b) return a.requests > b.requests end)
  usage.providers = providers

  return usage
end

local function filterUsageDays(usage, providerStates)
  if type(usage) ~= "table" then return usage end

  local hidden = {}
  local function hide(id)
    if id ~= nil then hidden[tostring(id):lower()] = true end
  end
  for id in pairs(common.hiddenProviders()) do hide(id) end
  for _, provider in ipairs(providerStates or {}) do
    if provider.enabled ~= true then hide(provider.id) end
  end
  -- Codex-login usage is filed under either id depending on the endpoint.
  if hidden.openai then hidden.codex = true end
  if hidden.codex then hidden.openai = true end

  local function isHidden(id)
    return hidden[tostring(id or ""):lower()] == true
  end

  -- Match the panel's definition of an active filter: an excluded id has to be
  -- present in the usage response, not merely typed into settings.
  local excluded = false
  for _, item in ipairs(usage.providers or {}) do
    if isHidden(item.id) then excluded = true break end
  end
  if not excluded then
    for _, item in ipairs(usage.models or {}) do
      if isHidden(item.provider) then excluded = true break end
    end
  end

  usage.today = nil
  local today = os.date("%Y-%m-%d")
  for _, day in ipairs(usage.days or {}) do
    local all = type(day.all) == "table" and day.all or {
      requests = day.requests,
      totalTokens = day.totalTokens,
      estimatedCostUsd = day.estimatedCostUsd,
    }
    day.all = all

    local dayModels = type(day.models) == "table" and day.models or {}
    if excluded and #dayModels > 0 then
      local requests, totalTokens, estimatedCost = 0, 0, 0
      local completeCost = true
      for _, item in ipairs(dayModels) do
        if not isHidden(item.provider) then
          requests = requests + (number(item.requests) or 0)
          totalTokens = totalTokens + (number(item.totalTokens) or 0)
          if (number(item.requests) or 0) > 0 or (number(item.totalTokens) or 0) > 0 then
            local cost = number(item.estimatedCostUsd)
            if cost == nil then
              completeCost = false
            else
              estimatedCost = estimatedCost + cost
            end
          end
        end
      end
      day.requests = requests
      day.totalTokens = totalTokens
      day.estimatedCostUsd = completeCost and estimatedCost or nil
    else
      day.requests = number(all.requests) or 0
      day.totalTokens = number(all.totalTokens) or 0
      day.estimatedCostUsd = number(all.estimatedCostUsd)
    end

    if day.date == today then
      usage.today = {
        requests = day.requests,
        totalTokens = day.totalTokens,
        estimatedCostUsd = day.estimatedCostUsd,
      }
    end
  end
  return usage
end

-- Active first, then healthy, then anything needing attention, then paused;
-- ties keep OpenCodex's own ordering.
local function sortedAccounts(accounts)
  local decorated = {}
  for index, account in ipairs(accounts or {}) do
    table.insert(decorated, { account = account, index = index })
  end
  local function rank(account)
    if account.paused == true then return 4 end
    if account.needsReauth == true or account.quotaUnavailable == true then return 3 end
    if account.active == true then return 1 end
    local health = type(account.health) == "string" and account.health:lower() or ""
    if health == "degraded" or health == "unhealthy" or health == "unavailable" or health == "error" then return 3 end
    return 2
  end
  table.sort(decorated, function(a, b)
    local ar, br = rank(a.account), rank(b.account)
    if ar == br then return a.index < b.index end
    return ar < br
  end)
  local result = {}
  for _, item in ipairs(decorated) do table.insert(result, item.account) end
  return result
end

local function poolFrom(value)
  if type(value) ~= "table" then return nil end
  return {
    strategy = type(value.accountPoolStrategy) == "string" and value.accountPoolStrategy or nil,
    stickyLimit = number(value.accountPoolStickyLimit),
    autoSwitchThreshold = number(value.autoSwitchThreshold),
    failoverThreshold = number(value.upstreamFailoverThreshold),
  }
end

local function initialSnapshot()
  return {
    schemaVersion = 1,
    status = "loading",
    generatedAtMs = nowMs(),
    lastSuccessfulAtMs = nil,
    refreshing = true,
    error = nil,
    providers = {},
    usage = nil,
  }
end

local function publish(value)
  snapshot = value
  noctalia.state.set("snapshot", value)
end

local function mergeSnapshot(results, previous)
  local providers
  if results.providers ~= nil and results.providers.data ~= nil then
    providers = providerList(results.providers.data)
    -- Provider discovery carries no accounts or quotas; keep the last good ones
    -- so a partial refresh never blanks the panel.
    for _, provider in ipairs(providers) do
      local old = providerById(previous.providers or {}, provider.id)
      if old ~= nil then
        provider.quota = copy(old.quota)
        provider.accounts = copy(old.accounts or {})
        provider.pool = copy(old.pool)
      end
    end
  else
    providers = copy(previous.providers or {})
  end

  for _, provider in ipairs(providers) do
    provider.accounts = provider.accounts or {}
  end

  if results.providerQuotas ~= nil and results.providerQuotas.data ~= nil then
    for _, item in ipairs(providerQuotaList(results.providerQuotas.data)) do
      local provider = ensureProvider(providers, item.id)
      provider.quota = item.quota
      -- /api/providers only knows the bare id ("openai"); prefer a real name.
      if item.label ~= nil and provider.label == provider.id then
        provider.label = item.label
      end
    end
  end

  local activeData = results.active and results.active.data or nil
  local activeId = activeIdFrom(activeData)
  local previousOpenAi = providerById(previous.providers or {}, "openai")
  if activeId == nil and previousOpenAi ~= nil then
    for _, account in ipairs(previousOpenAi.accounts or {}) do
      if account.active == true then
        activeId = account.id
        break
      end
    end
  end

  if results.codexAccounts ~= nil and results.codexAccounts.data ~= nil then
    local codexAccounts = sortedAccounts(normalizeAccounts(results.codexAccounts.data, activeId))
    -- Only vouch for an OpenAI provider that /api/providers did not list if the
    -- Codex pool actually holds accounts; otherwise a deployment that never
    -- configured Codex grows an empty "OpenAI" group.
    if #codexAccounts > 0 or providerById(providers, "openai") ~= nil then
      local openai = ensureProvider(providers, "openai", "OpenAI")
      if openai.label == "openai" then openai.label = "OpenAI" end
      openai.accounts = codexAccounts
      if activeData ~= nil then
        openai.pool = poolFrom(activeData)
      end
    end
  end

  for providerId, result in pairs(results.oauth) do
    if result.data ~= nil then
      local provider = ensureProvider(providers, providerId)
      provider.accounts = sortedAccounts(normalizeAccounts(result.data, activeIdFrom(result.data)))
    end
  end

  for _, provider in ipairs(providers) do
    provider.label = displayLabel(provider.id, provider.label)
  end

  local usage = copy(previous.usage)
  if results.usage ~= nil and results.usage.data ~= nil then
    usage = normalizeUsage(results.usage.data)
  end
  usage = filterUsageDays(usage, providers)

  local anySuccess, hasFailure, hasAuthError, hasOffline = false, false, false, false
  local firstErrorKind = nil
  local function inspect(result)
    if result == nil then return end
    if result.data ~= nil then
      anySuccess = true
    elseif result.error ~= nil and result.error.kind ~= "not_found" then
      hasFailure = true
      if result.error.kind == "auth_error" then hasAuthError = true end
      if result.error.kind == "offline" then hasOffline = true end
      if firstErrorKind == nil then firstErrorKind = result.error.kind end
    end
  end
  inspect(results.providers)
  inspect(results.codexAccounts)
  inspect(results.active)
  inspect(results.providerQuotas)
  inspect(results.usage)
  for _, result in pairs(results.oauth) do inspect(result) end

  local status, errorKind = "ok", nil
  if hasAuthError then
    status, errorKind = "auth_error", "auth_error"
  elseif not anySuccess and hasOffline then
    status, errorKind = "offline", "offline"
  elseif hasFailure then
    status = "degraded"
    errorKind = anySuccess and "partial_failure" or (firstErrorKind or "api_error")
    if not anySuccess then status = "offline" end
  end

  return {
    schemaVersion = 1,
    status = status,
    generatedAtMs = nowMs(),
    lastSuccessfulAtMs = anySuccess and nowMs() or previous.lastSuccessfulAtMs,
    refreshing = false,
    error = errorKind ~= nil and { kind = errorKind } or nil,
    providers = providers,
    usage = usage,
  }
end

local refresh

local function finishRefresh(results, previous)
  publish(mergeSnapshot(results, previous))
  inFlight = false
  if refreshPending then
    local runForce = forcePending
    refreshPending = false
    forcePending = false
    refresh(runForce)
  end
end

function refresh(force)
  if inFlight then
    refreshPending = true
    if force then forcePending = true end
    return
  end

  inFlight = true
  -- Re-read the file once per refresh so OpenCodex token rotation recovers
  -- without requiring a settings change. The first request repopulates it and
  -- every other request in this refresh reuses that value.
  tokenCache = { path = nil, value = nil, loaded = false }
  generation = generation + 1
  local myGeneration = generation
  refreshStartedMs = nowMs()
  lastRefreshMs = refreshStartedMs
  if force then lastForcedRefreshMs = refreshStartedMs end

  local previous = snapshot or initialSnapshot()
  if not previous.refreshing then
    -- Shallow copy: mergeSnapshot only reads `previous`, and every field it
    -- keeps is deep-copied there.
    local loading = {}
    for key, value in pairs(previous) do loading[key] = value end
    loading.refreshing = true
    loading.generatedAtMs = refreshStartedMs
    publish(loading)
  end

  local results = { oauth = {} }
  local pending = 0
  -- Discovery has to finish before `pending` can mean anything: it is what
  -- schedules the per-provider OAuth requests.
  local discoveryComplete = false

  local function maybeFinish()
    -- A refresh abandoned by the watchdog must not publish when its late
    -- callbacks finally land on top of a newer one.
    if generation ~= myGeneration then return end
    if pending ~= 0 or not discoveryComplete then return end
    finishRefresh(results, previous)
  end

  local function addRequest(name, path, onData)
    pending = pending + 1
    request(path, function(data, err)
      results[name] = { data = data, error = err }
      if data ~= nil and onData ~= nil then onData(data) end
      pending = pending - 1
      maybeFinish()
    end)
  end

  addRequest("providers", "/api/providers", function(data)
    for _, provider in ipairs(providerList(data)) do
      -- A provider hidden in the plugin settings is never drawn, so there is no
      -- reason to spend a round trip fetching its accounts and quota.
      if provider.enabled and provider.oauth and not common.isHidden(provider.id)
        and provider.id ~= "openai" and provider.id ~= "codex" then
        local query = "?provider=" .. noctalia.string.urlEncode(provider.id)
        -- Only Anthropic exposes per-account quota through this endpoint.
        if provider.id:lower() == "anthropic" then
          query = query .. "&quota=1" .. (force and "&refresh=1" or "")
        end
        pending = pending + 1
        request("/api/oauth/accounts" .. query, function(accounts, err)
          results.oauth[provider.id] = { data = accounts, error = err }
          pending = pending - 1
          maybeFinish()
        end)
      end
    end
  end)
  -- Set unconditionally: a failed discovery must still release maybeFinish,
  -- otherwise one unreachable /api/providers wedges the service permanently.
  discoveryComplete = true

  addRequest("codexAccounts", "/api/codex-auth/accounts" .. (force and "?refresh=1" or ""))
  addRequest("active", "/api/codex-auth/active")
  addRequest("providerQuotas", "/api/provider-quotas" .. (force and "?refresh=1" or ""))
  addRequest("usage", "/api/usage?range=" .. USAGE_RANGE .. "&surface=all")
  maybeFinish()
end

local function findCodexAccount(accountId)
  local provider = providerById((snapshot and snapshot.providers) or {}, "openai")
  for _, account in ipairs((provider and provider.accounts) or {}) do
    if account.id == accountId then return account end
  end
  return nil
end

local function publishAction(value)
  noctalia.state.set("action", value)
end

local function runAccountAction(command)
  if actionInFlight then return end
  local accountId = nonEmpty(command.accountId)
  local account = accountId ~= nil and findCodexAccount(accountId) or nil
  local actionType = command.type
  if account == nil or account.paused == true or account.needsReauth == true then
    publishAction({ status = "error", type = actionType, accountId = accountId, code = "invalid_account" })
    return
  end
  if actionType == "reset_account" then
    local credits = account.quota and number(account.quota.resetCredits) or nil
    if credits == nil or credits <= 0 then
      publishAction({ status = "error", type = actionType, accountId = accountId, code = "no_credit" })
      return
    end
  end

  actionInFlight = true
  actionGeneration = actionGeneration + 1
  local myActionGeneration = actionGeneration
  actionStartedMs = nowMs()
  publishAction({ status = "working", type = actionType, accountId = accountId })
  tokenCache = { path = nil, value = nil, loaded = false }

  local path, method, body
  if actionType == "select_account" then
    path, method = "/api/codex-auth/active", "PUT"
    body = noctalia.json.encode({ accountId = accountId })
  else
    path, method = "/api/codex-auth/reset-credits/consume", "POST"
    body = noctalia.json.encode({ accountId = accountId })
  end

  request(path, function(data, err)
    if actionGeneration ~= myActionGeneration then return end
    actionInFlight = false
    if err ~= nil then
      publishAction({
        status = "error",
        type = actionType,
        accountId = accountId,
        code = err.code or err.kind,
        httpStatus = err.status,
      })
      return
    end

    local code = type(data) == "table" and nonEmpty(data.code) or nil
    if actionType == "reset_account" and code ~= "reset" and code ~= "already_redeemed" then
      publishAction({ status = "error", type = actionType, accountId = accountId, code = code or "api_error" })
      refresh(true)
      return
    end

    publishAction({
      status = "success",
      type = actionType,
      accountId = accountId,
      code = code,
      remaining = type(data) == "table" and number(data.remaining) or nil,
    })
    refresh(true)
  end, { method = method, body = body })
end

noctalia.state.watch("command", function(command)
  if type(command) ~= "table" then return end
  if command.type == "refresh" then
    refresh(true)
  elseif command.type == "select_account" or command.type == "reset_account" then
    runAccountAction(command)
  end
end)

function onConfigChanged()
  tokenCache = { path = nil, value = nil, loaded = false }
  refresh(true)
end

function update()
  local now = nowMs()

  -- Apply the same lost-callback protection to mutations. A late response from
  -- an abandoned action is ignored rather than overwriting a newer result.
  if actionInFlight and now - actionStartedMs >= REFRESH_TIMEOUT_MS then
    actionGeneration = actionGeneration + 1
    actionInFlight = false
    publishAction({ status = "error", code = "timeout" })
  end

  -- A refresh whose callbacks were lost would otherwise block every later one.
  -- Bumping the generation orphans it; the in-flight requests still settle
  -- normally so the concurrency counters stay honest.
  if inFlight and now - refreshStartedMs >= REFRESH_TIMEOUT_MS then
    generation = generation + 1
    inFlight = false
    refreshPending = false
    forcePending = false
  end

  local forceMinutes = configNumber("force_refresh_minutes", DEFAULT_FORCE_MINUTES, 5, 60)
  local pollSeconds = configNumber("poll_seconds", DEFAULT_POLL_SECONDS, 10, 300)
  -- Forced first: it also satisfies the normal poll, and checking it second
  -- lets a short poll interval starve it by a tick every time.
  if now - lastForcedRefreshMs >= forceMinutes * 60000 then
    refresh(true)
  elseif now - lastRefreshMs >= pollSeconds * 1000 then
    refresh(false)
  end
end

publish(initialSnapshot())
publishAction({ status = "idle" })
lastForcedRefreshMs = nowMs()
noctalia.setUpdateInterval(1000)
refresh(false)
