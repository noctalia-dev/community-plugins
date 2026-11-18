-- Keep only display fields; never put the Hub envelope or credentials in state.
local Model = {}
local Providers = require("./providers.luau")
local names = {}
for id, entry in pairs(Providers.entries) do names[id] = entry.name end
for alias, id in pairs(Providers.aliases) do names[alias] = Providers.entries[id].name end
local ranks = { codex = 1, deepseek = 2, antigravity = 3 }

local function text(value, maxLength)
  if type(value) ~= "string" then return "" end
  local bounded = value:sub(1, maxLength or 256):gsub("[%c]", " ")
  while #bounded > 0 and not utf8.len(bounded) do bounded = bounded:sub(1, -2) end
  return bounded
end

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function array(value)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then return false end
  end
  return true
end

local function balance(value)
  if type(value) ~= "table" then return nil end
  local out = { currency = text(value.currency, 16), expiresAt = text(value.expiresAt, 64),
    trackingSince = text(value.trackingSince, 64), planStatus = text(value.planStatus, 32),
    monthSinceTracking = value.monthSinceTracking == true }
  for _, field in ipairs({ "amount", "todaySpend", "weekSpend", "monthSpend", "allTimeSpend", "requestCount",
      "giftBalance", "cashBalance", "planUsed", "planLimit", "planPercent" }) do
    out[field] = finite(value[field]) and value[field] or nil
  end
  return out
end
local function resetCredits(value)
  if type(value) ~= "table" then return nil end
  return { availableCount = finite(value.availableCount) and value.availableCount or nil,
    nextExpiresAt = text(value.nextExpiresAt, 64) }
end

-- Identity uses full bounded source identifiers, never mutable display labels or row order.
-- Length prefixes distinguish delimiters inside account names without truncating identity.
local function identity(row)
  local provider, account = row.provider, row.accountKey
  if type(provider) ~= "string" or #provider > 64 or type(account) ~= "string"
      or #account > 512 or account:find("[%c]") then return "" end
  local device = ""
  if account == "" then return "" end
  if provider == "antigravity" and not (type(row.accountEmail) == "string" and row.accountEmail ~= ""
      and row.status ~= "notConfigured" and row.status ~= "disabled") then
    if type(row.sourceDeviceId) ~= "string" or row.sourceDeviceId == "" then return "" end
    device = row.sourceDeviceId
  end
  local region = row.region == nil and "" or row.region
  if type(region) ~= "string" or #region > 128 or region:find("[%c]")
      or #device > 512 or device:find("[%c]") or provider:find("[%c]") then return "" end
  local pieces = {}
  for _, value in ipairs({ provider, account, region, device }) do
    pieces[#pieces + 1] = tostring(#value) .. ":" .. value
  end
  return table.concat(pieces, "|")
end

function Model.normalize(data, fromCache, step)
  if type(data) ~= "table" or type(data.limits) ~= "table"
      or not array(data.limits.providers) then return nil, "invalid_response" end
  local rows = data.limits.providers
  if #rows > 128 then return nil, "too_large" end
  -- Native state publication must copy the complete display model in one call.
  -- Reject excess windows before projection instead of truncating valid data.
  local windowCount = 0
  for _, row in ipairs(rows) do
    if type(row) ~= "table" or type(row.provider) ~= "string" or row.provider == ""
        or not array(row.windows) then return nil, "invalid_response" end
    if #row.windows > 32 then return nil, "too_large" end
    windowCount += #row.windows
    if windowCount > 512 then return nil, "too_large" end
  end
  local providers = {}
  for index, row in ipairs(rows) do
    local windows = {}
    for windowIndex, window in ipairs(row.windows) do
      if type(window) ~= "table" then return nil, "invalid_response" end
      local value, unit, metric = nil, "", "unknown"
      if finite(window.remainingPercent) then
        value, unit, metric = math.clamp(window.remainingPercent, 0, 100), "%", "percent"
      elseif finite(window.usedPercent) then
        value, unit, metric = math.clamp(100 - window.usedPercent, 0, 100), "%", "percent"
      elseif finite(window.remaining) then
        value, unit, metric = window.remaining, text(window.currency, 16), "balance"
      end
      windows[#windows + 1] = {
        label = text(window.label), kind = text(window.kind, 48),
        value = value, unit = unit, metric = metric, resetsAt = text(window.resetsAt, 64),
        limitId = text(window.limitId, 128), source = text(window.source, 64),
        boundaryKind = text(window.boundaryKind, 64), additional = window.additional == true,
        sourceMetric = text(window.metric, 64), showMeter = window.showMeter ~= false,
        detail = text(window.detail), resetDescription = text(window.resetDescription),
        remaining = finite(window.remaining) and window.remaining or nil,
        usedPercent = finite(window.usedPercent) and window.usedPercent or nil,
        remainingPercent = finite(window.remainingPercent) and window.remainingPercent or nil,
        currency = text(window.currency, 16),
        used = finite(window.used) and window.used or nil,
        limit = finite(window.limit) and window.limit or nil,
        windowMinutes = finite(window.windowMinutes) and window.windowMinutes or nil,
      }
      if step and windowIndex % 8 == 0 then step() end
    end
    local adapterId = row.provider == "thirdparty" and text(row.adapterId, 64) or ""
    local adapter = Providers.adapters[adapterId]
    providers[#providers + 1] = {
      provider = text(row.provider, 64), adapterId = adapterId,
      name = adapter and adapter.name or names[row.provider] or text(row.provider, 64),
      key = fromCache and type(row.key) == "string" and #row.key <= 2048
        and not row.key:find("[%c]") and row.key or identity(row),
      accountLabel = text(row.accountLabel), planLabel = text(row.planLabel), status = text(row.status, 48),
      balanceUsd = finite(row.balanceUsd) and row.balanceUsd or nil,
      balance = balance(row.balance), resetCredits = resetCredits(row.resetCredits),
      stale = row.stale == true, updatedAt = text(row.updatedAt, 64), windows = windows,
      order = index,
    }
    -- Bound each native callback's projection work as well as display size.
    if step then step() end
  end
  table.sort(providers, function(left, right)
    local a, b = ranks[left.provider] or 4, ranks[right.provider] or 4
    return a < b or (a == b and left.order < right.order)
  end)
  local seen = {}
  for _, provider in ipairs(providers) do
    provider.order = nil
    if provider.key ~= "" then seen[provider.key] = (seen[provider.key] or 0) + 1 end
  end
  -- Ambiguous source identities cannot be pinned safely.
  for _, provider in ipairs(providers) do
    if seen[provider.key] and seen[provider.key] > 1 then provider.key = "" end
  end
  return providers
end

-- Project the already-small display model back into the supported input shape
-- before caching. Reuse normal validation when restoring an untrusted cache.
function Model.cachePayload(providers, step)
  local rows = {}
  for index, provider in ipairs(providers) do
    local windows = {}
    for windowIndex, window in ipairs(provider.windows) do
      windows[#windows + 1] = {
        label = window.label, kind = window.kind, resetsAt = window.resetsAt,
        remainingPercent = window.metric == "percent" and window.value or window.remainingPercent,
        remaining = window.remaining,
        usedPercent = window.usedPercent, currency = window.currency, limitId = window.limitId, source = window.source,
        boundaryKind = window.boundaryKind, additional = window.additional, metric = window.sourceMetric,
        showMeter = window.showMeter, detail = window.detail, resetDescription = window.resetDescription,
        used = window.used, limit = window.limit, windowMinutes = window.windowMinutes,
      }
      if step and windowIndex % 8 == 0 then step() end
    end
    rows[#rows + 1] = {
      provider = provider.provider, adapterId = provider.adapterId, key = provider.key,
      accountLabel = provider.accountLabel, planLabel = provider.planLabel,
      balanceUsd = provider.balanceUsd, balance = provider.balance, resetCredits = provider.resetCredits,
      status = provider.status, stale = provider.stale, updatedAt = provider.updatedAt, windows = windows,
    }
    if step then step() end
  end
  return { limits = { providers = rows } }
end

function Model.origin(value)
  if type(value) ~= "string" then return nil end
  local cleaned = value:match("^%s*(.-)%s*$"):gsub("/+$", "")
  local scheme, authority = cleaned:match("^(https?)://([^/]+)$")
  if not scheme or authority:find("[%s@?#\\]") then return nil end
  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^(%[[%x:%.]+%]):(%d+)$")
    if not host then host = authority:match("^(%[[%x:%.]+%])$") end
  else
    host, port = authority:match("^([%w%.%-]+):(%d+)$")
    if not host then host = authority:match("^([%w%.%-]+)$") end
  end
  if not host or (port and (tonumber(port) < 1 or tonumber(port) > 65535)) then return nil end
  return cleaned
end

function Model.credential(contents, decode)
  if type(contents) ~= "string" or #contents > 65536 then return nil end
  local secret = contents:match("^%s*(.-)%s*$")
  if secret:sub(1, 1) == "{" then
    local ok, document = pcall(decode, secret)
    if not ok or type(document) ~= "table" or type(document.credentials) ~= "table"
        or type(document.credentials.hub) ~= "table" then return nil end
    secret = document.credentials.hub.hostSecret
  end
  if type(secret) ~= "string" or secret == "" or #secret > 4096
      or secret:find("[%c]") then return nil end
  return secret
end

return Model
