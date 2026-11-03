--!nonstrict
-- prefs.json: what the user changes from the bar and panel (plugins cannot
-- write settings). Only the service writes it. Edits are pure functions that
-- return true when something changed; the caller saves and publishes.

local M = {}

M.FILE = "prefs.json"
M.BAR_MODES = { full = true, value = true, icon = true }
M.ALERT_KINDS = { above = true, below = true, move_pct = true }
M.DEFAULT_COOLDOWN_MIN = 60
local MAX_WATCHLIST = 50
local MAX_ALERTS = 100
local MAX_ASSET_TARGETS = 50

export type Alert = {
  id: string,
  symbol: string,
  kind: string,
  value: number,
  cooldown_min: number,
  enabled: boolean,
  last_fired_ms: number?,
}

export type Prefs = {
  privacy: boolean,
  bar_mode: string,
  watchlist: { string },
  alerts: { Alert },
  summary_day: string?, -- local day the daily summary was last sent
  drift_flagged: { string }, -- classes and holdings already notified as off target
  asset_targets: { [string]: number }, -- holding key (BTC, EQ_NVDA) -> share of the portfolio
}

function M.defaults(): Prefs
  return { privacy = false, bar_mode = "full", watchlist = { "BTCUSDT", "ETHUSDT" }, alerts = {}, drift_flagged = {}, asset_targets = {} }
end

-- Stock tickers are stored as EQ_<TICKER>, the wallet's code for Binance
-- Stocks shares, so they never collide with a crypto pair.
M.STOCK_PREFIX = "EQ_"

function M.validSymbol(symbol: any): boolean
  return type(symbol) == "string"
    and (string.match(symbol, "^[A-Z0-9]+$") ~= nil or string.match(symbol, "^EQ_[A-Z0-9]+$") ~= nil)
    and #symbol <= 20
end

function M.isStock(symbol: string): boolean
  return string.sub(symbol, 1, #M.STOCK_PREFIX) == M.STOCK_PREFIX
end

-- "EQ_AAPL" -> "AAPL".
function M.stockTicker(symbol: string): string
  return string.sub(symbol, #M.STOCK_PREFIX + 1)
end

local function validAlert(a): boolean
  return type(a) == "table"
    and type(a.id) == "string"
    and M.validSymbol(a.symbol)
    and M.ALERT_KINDS[a.kind] == true
    and type(a.value) == "number"
    and a.value == a.value -- not NaN
end

-- Accepts a decoded prefs.json (or nil) and keeps only well-formed parts.
function M.sanitize(raw): Prefs
  local p = M.defaults()
  if type(raw) ~= "table" then
    return p
  end
  if type(raw.privacy) == "boolean" then
    p.privacy = raw.privacy
  end
  if M.BAR_MODES[raw.bar_mode] then
    p.bar_mode = raw.bar_mode
  end
  if type(raw.summary_day) == "string" and string.match(raw.summary_day, "^%d%d%d%d%-%d%d%-%d%d$") then
    p.summary_day = raw.summary_day
  end
  if type(raw.drift_flagged) == "table" then
    for _, id in raw.drift_flagged do
      if type(id) == "string" and not table.find(p.drift_flagged, id) then
        table.insert(p.drift_flagged, id)
      end
    end
  end
  if type(raw.asset_targets) == "table" then
    for key, share in raw.asset_targets do
      M.setAssetTarget(p, key, share)
    end
  end
  if type(raw.watchlist) == "table" then
    p.watchlist = {}
    for _, symbol in raw.watchlist do
      if M.validSymbol(symbol) and not table.find(p.watchlist, symbol) then
        table.insert(p.watchlist, symbol)
      end
    end
  end
  if type(raw.alerts) == "table" then
    for _, a in raw.alerts do
      if validAlert(a) then
        table.insert(p.alerts, {
          id = a.id,
          symbol = a.symbol,
          kind = a.kind,
          value = a.value,
          cooldown_min = if type(a.cooldown_min) == "number" then a.cooldown_min else M.DEFAULT_COOLDOWN_MIN,
          enabled = a.enabled ~= false,
          last_fired_ms = if type(a.last_fired_ms) == "number" then a.last_fired_ms else nil,
        })
      end
    end
  end
  return p
end

-- Sets a holding's target share (0 < share <= 1), or removes it with nil.
function M.setAssetTarget(p: Prefs, key: any, share: any): boolean
  if not M.validSymbol(key) then
    return false
  end
  if share == nil then
    local had = p.asset_targets[key] ~= nil
    p.asset_targets[key] = nil
    return had
  end
  if type(share) ~= "number" or not (share > 0 and share <= 1) or p.asset_targets[key] == share then
    return false
  end
  if p.asset_targets[key] == nil then
    local n = 0
    for _ in p.asset_targets do
      n += 1
    end
    if n >= MAX_ASSET_TARGETS then
      return false
    end
  end
  p.asset_targets[key] = share
  return true
end

function M.watchAdd(p: Prefs, symbol: string): boolean
  if not M.validSymbol(symbol) or table.find(p.watchlist, symbol) or #p.watchlist >= MAX_WATCHLIST then
    return false
  end
  table.insert(p.watchlist, symbol)
  return true
end

function M.watchRemove(p: Prefs, symbol: string): boolean
  local at = table.find(p.watchlist, symbol)
  if at == nil then
    return false
  end
  table.remove(p.watchlist, at)
  return true
end

-- Moves `symbol` to 1-based `index`, clamped to the list.
function M.watchMove(p: Prefs, symbol: string, index: number): boolean
  local at = table.find(p.watchlist, symbol)
  if at == nil or type(index) ~= "number" then
    return false
  end
  local target = math.clamp(math.floor(index), 1, #p.watchlist)
  if target == at then
    return false
  end
  table.remove(p.watchlist, at)
  table.insert(p.watchlist, target, symbol)
  return true
end

local function nextId(p: Prefs): string
  local n = 0
  for _, a in p.alerts do
    local k = tonumber(string.match(a.id, "^a(%d+)$"))
    if k ~= nil and k > n then
      n = k
    end
  end
  return `a{n + 1}`
end

function M.alertAdd(p: Prefs, symbol: string, kind: string, value: number, cooldownMin: number?): Alert?
  if #p.alerts >= MAX_ALERTS then
    return nil
  end
  local alert = {
    id = nextId(p),
    symbol = symbol,
    kind = kind,
    value = value,
    cooldown_min = if type(cooldownMin) == "number" and cooldownMin >= 0 then cooldownMin else M.DEFAULT_COOLDOWN_MIN,
    enabled = true,
  }
  if not validAlert(alert) then
    return nil
  end
  table.insert(p.alerts, alert)
  return alert
end

-- fields: any of { kind, value, cooldownMin, enabled } (report names).
function M.alertUpdate(p: Prefs, id: string, fields): boolean
  for _, a in p.alerts do
    if a.id == id then
      local candidate = table.clone(a)
      if fields.kind ~= nil then
        candidate.kind = fields.kind
      end
      if type(fields.value) == "number" then
        candidate.value = fields.value
      end
      if type(fields.cooldownMin) == "number" and fields.cooldownMin >= 0 then
        candidate.cooldown_min = fields.cooldownMin
      end
      if type(fields.enabled) == "boolean" then
        candidate.enabled = fields.enabled
      end
      if not validAlert(candidate) then
        return false
      end
      for k, v in candidate do
        a[k] = v
      end
      return true
    end
  end
  return false
end

function M.alertRemove(p: Prefs, id: string): boolean
  for i, a in p.alerts do
    if a.id == id then
      table.remove(p.alerts, i)
      return true
    end
  end
  return false
end

-- Crypto pairs whose public prices the alerts need.
function M.alertSymbols(p: Prefs): { string }
  local out = {}
  for _, a in p.alerts do
    if a.enabled and not M.isStock(a.symbol) and not table.find(out, a.symbol) then
      table.insert(out, a.symbol)
    end
  end
  return out
end

-- Stock symbols the watchlist and enabled alerts need quotes for; the
-- helper's stock-quotes reads the same entries from prefs.json.
function M.watchedStocks(p: Prefs): { string }
  local out = {}
  for _, symbol in p.watchlist do
    if M.isStock(symbol) and not table.find(out, symbol) then
      table.insert(out, symbol)
    end
  end
  for _, a in p.alerts do
    if a.enabled and M.isStock(a.symbol) and not table.find(out, a.symbol) then
      table.insert(out, a.symbol)
    end
  end
  return out
end

return M
