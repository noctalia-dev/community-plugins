--!nonstrict
-- The only entry that fetches or spawns the helper. Public prices come from
-- data-api.binance.vision over noctalia.http; everything that needs the key
-- runs in binance_helper.py, one invocation at a time. Keyless mode (no
-- account.json, or no active pair) never spawns Python.
--
-- The service publishes one report on state.REPORT and answers commands on
-- state.COMMAND (contract.md section 3; lib/state.luau).

local state = require("./lib/state.luau")
local prefsLib = require("./lib/prefs.luau")
local market = require("./lib/market.luau")
local helperLib = require("./lib/helper.luau")
local ratelimit = require("./lib/ratelimit.luau")
local alertsLib = require("./lib/alerts.luau")
local ledger = require("./lib/ledger.luau")
local portfolio = require("./lib/portfolio.luau")
local flowsLib = require("./lib/flows.luau")
local days = require("./lib/days.luau")
local usmarket = require("./lib/usmarket.luau")
local summaryLib = require("./lib/summary.luau")
local allocation = require("./lib/allocation.luau")
local driftLib = require("./lib/drift.luau")
local fmt = require("./ui/fmt.luau")
local csv = require("./lib/csv.luau")
local fs = require("./lib/fs.luau")

local TICK_MS = 5000
local PRICES_PANEL_MS = 30000
local PRICES_BAR_MS = 60000
local BALANCES_MS = 5 * 60000
local STOCKS_WEEKDAY_MS = 5 * 60000
local STOCKS_WEEKEND_MS = 30 * 60000
local FLOWS_MS = 3600000
local TRADES_MS = 3600000
local FLOWS_RETRY_MAX_MS = 3600000
local VERIFY_MS = 24 * 3600000
local VERIFY_RETRY_MS = 3600000
local BUSY_RETRY_MS = 10000
local SUMMARY_FRESH_MS = 15 * 60000
local QUOTES_PANEL_MS = 60000
local QUOTES_BAR_MS = 3 * 60000
local QUOTES_CLOSED_MS = 30 * 60000
local SPARK_DAYS = 30
local MAX_KLINES = 1000

local json = noctalia.json
local dataDir = noctalia.pluginDataDir()
local helperPath = `{noctalia.pluginDir()}/binance_helper.py`

local function now(): number
  return noctalia.nowMs()
end

local function path(name: string): string
  return `{dataDir}/{name}`
end

local function readJson(name: string): any
  local p = path(name)
  if not noctalia.fileExists(p) then
    return nil
  end
  local raw = noctalia.readFile(p)
  local data = if raw ~= nil then json.decode(raw) else nil
  if type(data) ~= "table" or (data.v ~= nil and data.v ~= 1) then
    return nil
  end
  return data
end

local function writeJson(name: string, data: any)
  local encoded = json.encode(data)
  if encoded ~= nil then
    fs.writeAtomic(path(name), encoded)
  end
end

-- ── State ──────────────────────────────────────────────────────────────────

local prefs = prefsLib.sanitize(readJson(prefsLib.FILE))
local account = readJson("account.json")
local balances = readJson("balances.json")
local stocks = readJson("stocks.json")
local ledgerRaw = readJson("ledger.json")
local marksRaw = readJson("marks.json")
local flows = flowsLib.parse(readJson("flows-daily.json"))
-- Watched stock tickers: quotes and the list Binance Stocks lists, both from
-- the helper's stock-quotes (the quote endpoint needs the API key).
local stockQuotes = readJson("stock-quotes.json")
local equityList = readJson("equity-symbols.json")
-- Crypto cost basis from the helper's trades-sync (spot fills plus flows).
local cryptoCosts = readJson("crypto-costs.json")

-- symbol -> market.Ticker; warm-started from the last fetch, marked stale.
local tickers: { [string]: any } = {}
local tickersFresh = false
do
  local cached = readJson("prices.json")
  if cached ~= nil and type(cached.tickers) == "table" then
    tickers = cached.tickers
  end
end

-- symbol -> false when Binance said it does not exist.
local validSymbol: { [string]: boolean } = {}

-- Daily closes per pair: symbol -> { first = day number, closes, day = fetch day }.
local series: { [string]: any } = {}
do
  local cached = readJson("history-cache.json")
  if cached ~= nil and type(cached.series) == "table" then
    for symbol, s in cached.series do
      local first = type(s) == "table" and days.number(s.first or "")
      if first and type(s.closes) == "table" then
        series[symbol] = { first = first, closes = s.closes, day = s.day, limit = s.limit }
      end
    end
  end
end
-- Open of the current day per pair under the chosen day boundary.
local opens: { [string]: { day: string, open: number } } = {}

local sources: { [string]: any } = {}
local blocked: string? = nil -- a BLOCKING error code stops signed polling
local dependency: string? = nil
local panelOpen = false
local armed: { [string]: boolean } = {}
local rangeRequest: any = nil
local lastLookup: any = nil
local watchNotice: any = nil -- why the last watch_add was refused
local lastPublished: string? = nil
local lastReport: any = nil
local lastExport: any = nil -- { path?, at, error? } of the last export_csv
-- History is recomputed only when its inputs change: bump this whenever the
-- ledger, marks, stocks, daily closes or display currency change.
local historyVersion = 0
local historyCache: any = nil
local rangeMemo: any = nil

local nextAt = { prices = 0, balances = 0, stocks = 0, flows = 0, quotes = 0, trades = 0, daily = 0, verify = 0 }
local failures = { balances = 0, stocks = 0, flows = 0, quotes = 0, trades = 0 }
if flows ~= nil and flows.ready then
  nextAt.flows = flows.at + FLOWS_MS -- caught up before the reload
end
local httpInFlight = 0

local helper = helperLib.new({
  run = noctalia.runAsync,
  decode = json.decode,
  trim = noctalia.string.trim,
  now = now,
}, function(command)
  return { "python3", "-I", helperPath, command, "--data-dir", dataDir }
end)

-- ── Small helpers ──────────────────────────────────────────────────────────

local function connected(): boolean
  return account ~= nil and account.active == true
end

local function currency(): string
  return if noctalia.getConfig("display_currency") == "EUR" then "EUR" else "USDT"
end

local function dayOffsetMs(at: number): number
  return if noctalia.getConfig("day_boundary") == "local" then days.localOffsetMs(at) else 0
end

-- USDT per display unit, or nil while the EUR rate is unknown.
local function rate(): number?
  if currency() == "USDT" then
    return 1
  end
  local eur = tickers.EURUSDT
  return if eur ~= nil then eur.price else nil
end

local function savePrefs()
  writeJson(prefsLib.FILE, {
    v = 1,
    privacy = prefs.privacy,
    bar_mode = prefs.bar_mode,
    watchlist = prefs.watchlist,
    alerts = prefs.alerts,
    summary_day = prefs.summary_day,
    drift_flagged = prefs.drift_flagged,
    asset_targets = prefs.asset_targets,
  })
end

local function errorView(err, at: number?)
  if err == nil then
    return nil
  end
  return {
    code = err.code or "internal",
    at = at or now(),
    binanceCode = err.binanceCode or err.binance_code,
    msg = err.msg,
    status = err.status,
    flags = err.flags,
    untilAt = err.untilAt or err.until_ms,
  }
end

local function sourceOk(name: string)
  sources[name] = { okAt = now(), stale = false }
end

local function sourceFailed(name: string, err)
  local s = sources[name] or { stale = false }
  s.error = errorView(err)
  s.stale = s.okAt ~= nil
  sources[name] = s
end

-- Crypto assets held now or in the ledger window (their pairs need prices
-- and daily closes).
local function heldAssets(): { string }
  local seen, out = {}, {}
  local function add(asset)
    if asset ~= portfolio.STABLE and not seen[asset] then
      seen[asset] = true
      table.insert(out, asset)
    end
  end
  local qty = portfolio.cryptoTotals(balances)
  for asset in qty do
    add(asset)
  end
  if ledgerRaw ~= nil and type(ledgerRaw.days) == "table" then
    for _, row in ledgerRaw.days do
      for asset in (type(row) == "table" and row.crypto) or {} do
        add(asset)
      end
    end
  end
  table.sort(out)
  return out
end

local function addUnique(list: { string }, symbol: string)
  if validSymbol[symbol] ~= false and not table.find(list, symbol) then
    table.insert(list, symbol)
  end
end

local function priceSymbols(): { string }
  local out = {}
  for _, symbol in prefs.watchlist do
    if not prefsLib.isStock(symbol) then
      addUnique(out, symbol)
    end
  end
  for _, symbol in prefsLib.alertSymbols(prefs) do
    addUnique(out, symbol)
  end
  if connected() then
    for _, asset in heldAssets() do
      addUnique(out, market.pairOf(asset))
    end
    addUnique(out, "BTCUSDT") -- values assets without a USDT pair
  end
  if currency() == "EUR" then
    addUnique(out, "EURUSDT")
  end
  return out
end

local function spark(symbol: string): { number }?
  local s = series[symbol]
  if s == nil or #s.closes < 2 then
    return nil
  end
  local out = {}
  for i = math.max(1, #s.closes - SPARK_DAYS + 1), #s.closes do
    table.insert(out, s.closes[i])
  end
  return out
end

-- ── Report ─────────────────────────────────────────────────────────────────

local function accountView()
  local view = { stage = "none", rotating = false }
  if account == nil then
    return view
  end
  local pending = account.pending or "none"
  if pending == "private" then
    view.stage = "awaiting_api_key"
  elseif pending == "both" then
    view.stage = "awaiting_verify"
  elseif account.active then
    view.stage = "active"
  end
  view.rotating = account.active == true and pending ~= "none"
  if pending ~= "none" then
    view.publicKeyPem = account.public_key_pem
  end
  view.verifiedAt = account.verified_at_ms
  if type(account.last_error) == "table" then
    view.error = errorView(account.last_error, account.last_error.at_ms)
  end
  return view
end

local function statusView()
  local view = {
    busy = helper.current() ~= nil or httpInFlight > 0,
    sources = sources,
    stale = false,
  }
  local running = helper.current()
  if running ~= nil then
    view.busyWhat = if running == "stocks-sync"
      then "stocks"
      elseif running == "flows-sync" then "flows"
      elseif running == "deposits-recent" then "balances"
      elseif running == "stock-quotes" then "prices"
      elseif running == "trades-sync" then "trades"
      elseif running == "store-api-key" then "store_api_key"
      elseif running == "recheck" then "verify"
      else running
  elseif httpInFlight > 0 then
    view.busyWhat = "prices"
  end
  local latest = nil
  for _, s in sources do
    view.stale = view.stale or s.stale
    if s.okAt ~= nil and (latest == nil or s.okAt > latest) then
      latest = s.okAt
    end
  end
  if not tickersFresh and next(tickers) ~= nil then
    view.stale = true
  end
  view.lastRefreshAt = latest
  local pause = ratelimit.active(dataDir, now())
  if pause ~= nil then
    view.rateLimit = { ["until"] = pause.untilMs, status = pause.status, scope = if pause.status == 418 then "all" else "public" }
  end
  if blocked == "keyring_locked" then
    view.keyring = "locked"
  elseif blocked == "no_secret_service" then
    view.keyring = "no_service"
  end
  view.dependency = dependency
  return view
end

-- Without tzdata for New York, formatTime silently falls back to local
-- time, which would put every session hours off: then no session at all.
local nyClock = noctalia.isValidTimezone(usmarket.ZONE)

-- Binance Stocks session of `ticker` right now: "pre" | "open" | "post" |
-- "overnight" | "closed". Overnight counts only for symbols Binance lists
-- with overnight trading; unknown ones read as closed, never as live.
-- Nil when the New York clock is unknown.
local function stockSession(ticker: string): string?
  if not nyClock then
    return nil
  end
  local day, minutes = usmarket.parseClock(noctalia.formatTime("%Y-%m-%d %H:%M", now() // 1000, usmarket.ZONE))
  if day == nil then
    return nil
  end
  local info = equityList and type(equityList.symbols) == "table" and equityList.symbols[ticker]
  local listed = type(info) == "table"
  return usmarket.session(day, minutes :: number, listed and info.overnight == true, not listed or info.extended ~= false)
end

-- A stock's day change: the midpoint against the last quote of an earlier
-- day, but only when that day is no older than the trading day before the
-- quote's. After a week away the base is a week old and the "day" change
-- would be the week's, enough to fire a percentage alert: none then.
local function stockDayChange(q, price: number): number?
  local prev = tonumber(q.prev_mid)
  local base = type(q.day) == "string" and usmarket.previousTradingDay(q.day)
  if prev == nil or prev <= 0 or not base or type(q.prev_day) ~= "string" or q.prev_day < base then
    return nil
  end
  return price / prev - 1
end

-- A watched stock: its quote midpoint in USD, and the change against the
-- last quote of an earlier UTC day (Holdings' base for stocks too). No
-- sparkline: Binance has no keyless or REST daily history for stocks.
local function stockTickerView(symbol: string)
  local ticker = prefsLib.stockTicker(symbol)
  local view: any = { symbol = symbol, base = ticker, quote = "USD", kind = "stock", alerts = 0, session = stockSession(ticker) }
  if not connected() then
    view.note = "needs_account"
    return view
  end
  local q = stockQuotes and type(stockQuotes.quotes) == "table" and stockQuotes.quotes[ticker]
  if type(q) == "table" and tonumber(q.mid) ~= nil then
    view.price = tonumber(q.mid)
    view.quoteAt = q.at_ms
    view.quoteStale = if q.stale == true then true else nil
    view.change24h = stockDayChange(q, view.price)
  elseif stockQuotes and type(stockQuotes.unknown) == "table" and table.find(stockQuotes.unknown, ticker) then
    view.note = "unknown_stock"
  end
  return view
end

local function tickerView(symbol: string)
  local view
  if prefsLib.isStock(symbol) then
    view = stockTickerView(symbol)
  else
    local base, quote = market.split(symbol)
    local t = tickers[symbol]
    view = { symbol = symbol, base = base, quote = quote, alerts = 0, spark = spark(symbol) }
    if t ~= nil then
      view.price = t.price
      view.change24h = t.change24h
      view.high24h = t.high24h
      view.low24h = t.low24h
    end
  end
  for _, a in prefs.alerts do
    if a.enabled and a.symbol == symbol then
      view.alerts += 1
    end
  end
  return view
end

local function alertViews()
  local out = {}
  for _, a in prefs.alerts do
    table.insert(out, {
      id = a.id,
      symbol = a.symbol,
      kind = a.kind,
      value = a.value,
      cooldownMin = a.cooldown_min,
      enabled = a.enabled,
      lastFiredAt = a.last_fired_ms,
    })
  end
  return out
end

-- Price inputs for portfolio.build, keyed by asset.
local function assetPrices(): { [string]: any }
  local out = {}
  for _, asset in heldAssets() do
    local symbol = market.pairOf(asset)
    local t = tickers[symbol]
    if t ~= nil then
      local o = opens[symbol]
      out[asset] = {
        price = t.price,
        open = if o ~= nil and o.day == days.of(now(), dayOffsetMs(now())) then o.open else nil,
        spark = spark(symbol),
      }
    end
  end
  return out
end

local function prevMarks(marks): { [string]: number }
  local out = {}
  local todayN = now() // days.DAY_MS -- marks are UTC days
  for symbol, m in marks do
    local mark = ledger.markOn(m, todayN, true)
    if mark ~= nil then
      out[symbol] = mark
    end
  end
  return out
end

local function historyInput(marks)
  local closes = {}
  for _, asset in heldAssets() do
    closes[asset] = series[market.pairOf(asset)]
  end
  local costs = {}
  for _, pos in (stocks and stocks.positions) or {} do
    costs[pos.symbol] = tonumber(pos.avg_cost) or 0
  end
  return {
    rows = ledger.rows(ledgerRaw, days.of(now())),
    closes = closes,
    marks = marks,
    costs = costs,
    eur = if currency() == "EUR" then series.EURUSDT else nil,
  }
end

local function rangeView(input, points, eur: boolean)
  if rangeRequest == nil or #input.rows == 0 then
    return nil
  end
  local rows = input.rows
  local firstN, lastN = rows[1].n, rows[#rows].n
  local preset = rangeRequest.preset
  local fromN, toN = nil, lastN
  if preset == "custom" then
    fromN, toN = days.number(rangeRequest.from or ""), days.number(rangeRequest.to or "")
  else
    local yearStart = days.number(string.sub(days.fromNumber(lastN), 1, 4) .. "-01-01") :: number
    fromN = portfolio.presetStart(preset, lastN, yearStart, firstN)
  end
  local view = {
    preset = preset,
    from = if fromN then days.fromNumber(fromN) else (rangeRequest.from or ""),
    to = if toN then days.fromNumber(toN) else (rangeRequest.to or ""),
    kind = "market",
    startValue = 0,
    endValue = 0,
    pnl = 0,
  }
  if fromN == nil or toN == nil or fromN < firstN or toN > lastN or fromN >= toN then
    view.error = "outside_coverage"
    return view
  end
  view.startValue = points[fromN - firstN + 1].value
  view.endValue = points[toN - firstN + 1].value
  local key = `{historyVersion}:{fromN}:{toN}`
  if rangeMemo == nil or rangeMemo.key ~= key then
    rangeMemo = { key = key, pnl = portfolio.marketReturn(input, fromN, toN) }
  end
  if flowsLib.covers(flows, fromN, toN, eur) then
    -- Flows are known for the whole range: the change in value minus what
    -- was deposited, against the starting value plus net deposits.
    local net = flowsLib.netIn(flows, fromN, toN, eur)
    view.kind = "net_of_flows"
    view.pnl = view.endValue - view.startValue - net
    local base = view.startValue + math.max(net, 0)
    view.pct = if base > 0 then view.pnl / base else nil
    return view
  end
  view.pnl = rangeMemo.pnl
  view.pct = if view.startValue > 0 then view.pnl / view.startValue else nil
  return view
end

local function historyView(input, points)
  if #points == 0 then
    return nil
  end
  local rows = input.rows
  local firstN, lastN = rows[1].n, rows[#rows].n
  local yearStart = days.number(string.sub(days.fromNumber(lastN), 1, 4) .. "-01-01") :: number
  local presets = {}
  for _, preset in { "7d", "30d", "ytd", "all" } do
    local start = portfolio.presetStart(preset, lastN, yearStart, firstN)
    if start ~= nil and start >= firstN and start < lastN then
      table.insert(presets, preset)
    end
  end
  return { from = days.fromNumber(firstN), to = days.fromNumber(lastN), days = points, presets = presets }
end

-- Drift from the target allocation (settings), or nil when targets are off.
-- Notifies once per class that leaves the band, and only once balances,
-- stocks and prices have all loaded (or stocks failed: an account without
-- Binance Stocks), so a half-synced portfolio cannot look drifted.
local function driftView(holdings)
  if noctalia.getConfig("targets_enabled") ~= true then
    return nil
  end
  local weights = {}
  for _, id in allocation.ORDER do
    weights[id] = tonumber(noctalia.getConfig(`target_{id}`))
  end
  local band = (tonumber(noctalia.getConfig("drift_band")) or driftLib.DEFAULT_BAND * 100) / 100
  local d = driftLib.compute(holdings, driftLib.targets(weights), prefs.asset_targets, band)
  local stocksPending = stocks == nil and not (sources.stocks and sources.stocks.error)
  if d == nil or balances == nil or stocksPending or not tickersFresh then
    return d
  end
  local fresh, flagged = driftLib.newlyOff(d, prefs.drift_flagged)
  if noctalia.getConfig("drift_notify") ~= false then
    local function notifyRow(row, name)
      if table.find(fresh, row.id) then
        local subst = { class = name, share = fmt.share(row.share), target = fmt.share(row.target) }
        noctalia.notify(noctalia.tr("notify.drift.title", subst), noctalia.tr("notify.drift.body", subst))
      end
    end
    for _, row in d.rows do
      notifyRow(row, noctalia.tr(`panel.overview.class.{row.id}`))
    end
    for _, row in d.assets do
      notifyRow(row, row.asset)
    end
  end
  if table.concat(flagged, ",") ~= table.concat(prefs.drift_flagged, ",") then
    prefs.drift_flagged = flagged
    savePrefs()
  end
  return d
end

local function publish()
  local r = rate()
  local cur = if r == nil then "USDT" else currency()
  r = r or 1
  local report = {
    v = state.VERSION,
    currency = cur,
    privacy = prefs.privacy,
    barMode = prefs.bar_mode,
    mode = if connected() then "connected" else "keyless",
    status = statusView(),
    account = accountView(),
    holdings = {},
    wallets = {},
    watchlist = {},
    alerts = alertViews(),
    gaps = {},
    watchNotice = watchNotice,
    export = lastExport,
  }
  for _, symbol in prefs.watchlist do
    table.insert(report.watchlist, tickerView(symbol))
  end
  if connected() and (balances ~= nil or stocks ~= nil) then
    local version = `{historyVersion}:{cur}:{days.of(now())}`
    if historyCache == nil or historyCache.version ~= version then
      local marks = ledger.marks(marksRaw)
      local input = historyInput(marks)
      if cur ~= currency() then
        input.eur = nil
      end
      local points = portfolio.history(input)
      local net = flowsLib.netDeposit(flows, 0, cur == "EUR")
      if net ~= nil and net.pnl ~= nil then
        -- Second chart series: net deposits to date, at flow-time rates.
        local dayNumbers = {}
        for i, row in input.rows do
          dayNumbers[i] = row.n
        end
        for i, net in flowsLib.cumulative(flows, dayNumbers, cur == "EUR") do
          points[i].netDeposit = net
        end
      end
      historyCache = { version = version, marks = marks, input = input, points = points, eur = cur == "EUR" }
      rangeMemo = nil
    end
    local holdings, wallets, totals, unpaired = portfolio.build({
      balances = balances,
      stocks = stocks,
      prices = assetPrices(),
      prevMarks = prevMarks(historyCache.marks),
      costs = cryptoCosts and cryptoCosts.assets,
      rate = r,
    })
    totals.netDeposit = flowsLib.netDeposit(flows, totals.value, cur == "EUR")
    for _, h in holdings do
      if h.kind == "stock" then
        h.session = stockSession(h.asset)
      end
    end
    report.holdings, report.wallets, report.totals = holdings, wallets, totals
    report.drift = driftView(holdings)
    local points = historyCache.points
    if #points > 0 then
      -- The chart ends at the live total, less what history values at 0:
      -- assets without a USDT pair, priced only live through BTC.
      points[#points].value = totals.value - unpaired
    end
    report.history = historyView(historyCache.input, points)
    report.range = rangeView(historyCache.input, points, historyCache.eur)
    report.gaps = { "dividends", "splits" }
    if totals.netDeposit == nil then
      table.insert(report.gaps, if flows ~= nil and flows.ready and flows.since == nil then "no_flows" else "flows_pending")
    end
  end
  local encoded = json.encode(report)
  if encoded == lastPublished then
    return
  end
  lastPublished = encoded
  lastReport = report
  report.at = now()
  noctalia.state.set(state.REPORT, report)
end

-- ── Public prices ──────────────────────────────────────────────────────────

local function paused(): boolean
  return ratelimit.active(dataDir, now()) ~= nil
end

local function httpGet(url: string, done: (any, any) -> ())
  httpInFlight += 1
  local started = noctalia.http({ url = url, headers = { "Accept: application/json" } }, function(response)
    httpInFlight -= 1
    local data, err = market.interpret(response, json.decode)
    if err ~= nil and err.code == "rate_limited" then
      local pause = ratelimit.recordPublic(dataDir, err.status, now())
      err.untilAt = pause.untilMs
    elseif err == nil then
      ratelimit.clearPublic(dataDir, now())
    end
    done(data, err)
  end)
  if not started then
    httpInFlight -= 1
    done(nil, { code = "network_error" })
  end
end

-- `prices` is what the alerts were evaluated against (crypto tickers or
-- stock quotes), keyed by alert symbol.
local function notifyAlerts(fired, prices)
  for _, alert in fired do
    local t = prices[alert.symbol]
    local subst = {
      symbol = if prefsLib.isStock(alert.symbol) then prefsLib.stockTicker(alert.symbol) else alert.symbol,
      price = string.format("%.8g", t and t.price or 0),
      value = if alert.kind == "move_pct"
        then string.format("%.4g%%", alert.value * 100)
        else string.format("%.8g", alert.value),
    }
    -- A stock's move is its day change, not a 24h one.
    local body = if alert.kind == "move_pct" and prefsLib.isStock(alert.symbol) then "body_stock" else "body"
    noctalia.notify(noctalia.tr(`notify.alert.{alert.kind}.title`, subst), noctalia.tr(`notify.alert.{alert.kind}.{body}`, subst))
  end
  if #fired > 0 then
    savePrefs()
  end
end

-- Finds which symbols of a failed batch do not exist, one request each.
local function probeSymbols(symbols: { string }, done: () -> ())
  local remaining = 0
  for _, symbol in symbols do
    if validSymbol[symbol] == nil then
      remaining += 1
      httpGet(market.tickerUrl(symbol), function(data, err)
        if data ~= nil then
          validSymbol[symbol] = true
        elseif market.isInvalidSymbol(err) then
          validSymbol[symbol] = false
        end
        remaining -= 1
        if remaining == 0 then
          done()
        end
      end)
    end
  end
  if remaining == 0 then
    done()
  end
end

local fetchPrices

fetchPrices = function()
  local interval = if panelOpen then PRICES_PANEL_MS else PRICES_BAR_MS
  nextAt.prices = now() + interval
  local symbols = priceSymbols()
  if #symbols == 0 or paused() then
    return
  end
  httpGet(market.tickersUrl(symbols, json.encode, noctalia.string.urlEncode), function(data, err)
    if data ~= nil then
      for symbol, t in market.parseTickers(data) do
        tickers[symbol] = t
        validSymbol[symbol] = true
      end
      tickersFresh = true
      sourceOk("prices")
      notifyAlerts(alertsLib.evaluate(prefs.alerts, tickers, armed, now()), tickers)
      writeJson("prices.json", { v = 1, at_ms = now(), tickers = tickers })
    elseif market.isInvalidSymbol(err) then
      for _, symbol in symbols do
        validSymbol[symbol] = nil -- one of them was delisted; find it
      end
      probeSymbols(symbols, function()
        nextAt.prices = now()
      end)
    else
      sourceFailed("prices", err)
    end
    publish()
  end)
end

-- ── Daily closes and opens ─────────────────────────────────────────────────

local klineQueue: { any } = {}
local klineBusy = false

local function saveSeries()
  local out = {}
  for symbol, s in series do
    out[symbol] = { first = days.fromNumber(s.first), closes = s.closes, day = s.day, limit = s.limit }
  end
  writeJson("history-cache.json", { v = 1, series = out })
end

local pumpKlines

pumpKlines = function()
  if klineBusy then
    return
  end
  if #klineQueue == 0 or paused() then
    klineQueue = {}
    return
  end
  local job = table.remove(klineQueue, 1)
  klineBusy = true
  local url = market.klinesUrl(job.symbol, job.limit, job.timeZone, noctalia.string.urlEncode)
  httpGet(url, function(data, err)
    klineBusy = false
    if data ~= nil then
      if job.kind == "history" then
        local first, closes = market.parseKlines(data, function(ms)
          return ms // days.DAY_MS
        end)
        if first ~= nil then
          series[job.symbol] = { first = first, closes = closes, day = job.day, limit = job.limit }
        end
      else
        local _, _, open = market.parseKlines(data, days.of)
        if open ~= nil then
          opens[job.symbol] = { day = job.day, open = open }
        end
      end
    elseif market.isInvalidSymbol(err) then
      validSymbol[job.symbol] = false
    elseif err ~= nil and err.code == "rate_limited" then
      klineQueue = {}
    end
    if #klineQueue == 0 then
      historyVersion += 1
      saveSeries()
      publish()
    end
    pumpKlines()
  end)
end

local function enqueueKline(job)
  for _, queued in klineQueue do
    if queued.symbol == job.symbol and queued.kind == job.kind then
      queued.limit = math.max(queued.limit, job.limit)
      return
    end
  end
  table.insert(klineQueue, job)
end

-- Once per day (and when new assets appear): daily closes for history and
-- sparklines, and today's open under the configured day boundary.
local function planDaily()
  nextAt.daily = now() + 60000
  local today = days.of(now())
  local offset = dayOffsetMs(now())
  local boundaryDay = days.of(now(), offset)
  local coverage = SPARK_DAYS + 1
  if ledgerRaw ~= nil and type(ledgerRaw.first_day) == "string" then
    local first = days.number(ledgerRaw.first_day)
    if first ~= nil then
      coverage = math.max(coverage, now() // days.DAY_MS - first + 2)
    end
  end
  local function history(symbol: string, limit: number)
    limit = math.min(limit, MAX_KLINES)
    local s = series[symbol]
    if validSymbol[symbol] ~= false and (s == nil or s.day ~= today or (s.limit or 0) < limit) then
      enqueueKline({ kind = "history", symbol = symbol, limit = limit, day = today })
    end
  end
  for _, symbol in prefs.watchlist do
    if not prefsLib.isStock(symbol) then
      history(symbol, SPARK_DAYS + 1)
    end
  end
  if connected() then
    for _, asset in heldAssets() do
      local symbol = market.pairOf(asset)
      history(symbol, coverage)
      local o = opens[symbol]
      if validSymbol[symbol] ~= false and (o == nil or o.day ~= boundaryDay) then
        enqueueKline({
          kind = "open",
          symbol = symbol,
          limit = 1,
          timeZone = if offset ~= 0 then days.offsetLabel(offset) else nil,
          day = boundaryDay,
        })
      end
    end
  end
  if currency() == "EUR" then
    history("EURUSDT", coverage)
  end
  pumpKlines()
end

-- ── Helper jobs ────────────────────────────────────────────────────────────

-- Errors that stop signed polling until the user acts: a locked or missing
-- keyring, a missing key, or a key that fails the read-only gate or that
-- Binance rejects.
local BLOCKING = {
  keyring_locked = true,
  no_secret_service = true,
  item_missing = true,
  permissions_too_broad = true,
  auth_rejected = true,
}
-- Blocks only a passing verify lifts; refresh and retry leave them.
local GATE = { permissions_too_broad = true, auth_rejected = true }

-- The helper refuses account data while the active key fails the gate
-- (account.json gate_failed); start out blocked so the re-verify runs first.
if account ~= nil and type(account.gate_failed) == "table" then
  blocked = "permissions_too_broad"
end

local function liftBlock()
  if not GATE[blocked] then
    blocked = nil
  end
end

local function reloadAccount()
  account = readJson("account.json")
end

local function stocksInterval(): number
  local weekday = days.weekday(now() // days.DAY_MS)
  return if weekday == 0 or weekday == 6 then STOCKS_WEEKEND_MS else STOCKS_WEEKDAY_MS
end

-- Retry delay after the source's n-th failure in a row.
local function backoff(name: string): number
  failures[name] += 1
  local interval = if name == "stocks"
    then stocksInterval()
    elseif name == "flows" or name == "trades" then FLOWS_RETRY_MAX_MS
    else BALANCES_MS
  return math.min(30000 * 2 ^ (failures[name] - 1), interval)
end

-- Shared failure handling for data subcommands. Returns the retry delay.
local function signedFailure(name: string, err): number
  if BLOCKING[err.code] then
    blocked = err.code
  elseif err.code == "missing_dependency" then
    dependency = "python-cryptography"
  end
  if err.code == "busy" then
    return BUSY_RETRY_MS
  end
  sourceFailed(name, err)
  return backoff(name)
end

-- Re-reads the flows summary. Flows still waiting for a price are retried on
-- the failure backoff instead of at the hourly sync, as the return stays
-- pending (and deposits-recent skipped) until they are priced.
local function readFlows()
  flows = flowsLib.parse(readJson("flows-daily.json"))
  if flows ~= nil and not flows.ready then
    nextAt.flows = math.min(nextAt.flows, now() + backoff("flows"))
  else
    failures.flows = 0
  end
end

local function signedAllowed(): boolean
  return connected() and blocked == nil and dependency == nil and not paused()
end

-- The re-verify also runs while a failed gate blocks polling: it is how a
-- key that was fixed in API Management gets used again.
local function verifyAllowed(): boolean
  return connected() and (blocked == nil or GATE[blocked] == true) and dependency == nil and not paused()
end

local runStocks

-- Crypto deposits since the last scan, read with every balances run so a
-- fresh deposit isn't counted as profit until the hourly flows sync. The
-- helper skips it until the first full sync has read deposits back.
local function runRecentDeposits()
  if flows == nil or not flows.ready or helper.pending("flows-sync") or helper.pending("deposits-recent") then
    return
  end
  helper.submit("deposits-recent", false, function(data, err)
    if err == nil and not data.skipped then
      readFlows()
      historyVersion += 1
      publish()
    end
  end)
end

local function runBalances(user: boolean)
  nextAt.balances = now() + BALANCES_MS
  helper.submit("balances", user, function(_, err)
    if err == nil then
      failures.balances = 0
      balances = readJson("balances.json")
      ledgerRaw = readJson("ledger.json")
      historyVersion += 1
      sourceOk("balances")
      planDaily()
      runRecentDeposits()
    else
      nextAt.balances = now() + signedFailure("balances", err)
    end
    publish()
  end)
end

runStocks = function(user: boolean)
  nextAt.stocks = now() + stocksInterval()
  helper.submit("stocks-sync", user, function(data, err)
    if err ~= nil then
      nextAt.stocks = now() + signedFailure("stocks", err)
    elseif data.done == false then
      if signedAllowed() then
        runStocks(user) -- next chunk right away; still one helper at a time
      end
    else
      failures.stocks = 0
      stocks = readJson("stocks.json")
      equityList = readJson("equity-symbols.json") -- refreshed for held stocks too
      ledgerRaw = readJson("ledger.json")
      marksRaw = readJson("marks.json")
      historyVersion += 1
      sourceOk("stocks")
    end
    publish()
  end)
end

-- Crypto cost basis: hourly, once flows are caught up (deposits are part of
-- the replay) and balances say which coins are held. Chunks continue at once.
local runTrades

runTrades = function(user: boolean)
  nextAt.trades = now() + TRADES_MS
  helper.submit("trades-sync", user, function(data, err)
    if err ~= nil then
      nextAt.trades = now() + signedFailure("trades", err)
    elseif data.done == false then
      local wait = tonumber(data.wait_ms) or 0
      if wait > 0 then
        nextAt.trades = now() + wait -- near Binance's per-minute IP weight
      elseif signedAllowed() then
        runTrades(user)
      end
    else
      failures.trades = 0
      cryptoCosts = readJson("crypto-costs.json")
      sourceOk("trades")
    end
    publish()
  end)
end

-- Flows sync in chunks until caught up, then hourly. A chunk that stopped on
-- Binance's per-minute UID weight says when to continue (wait_ms).
local runFlows

runFlows = function(user: boolean)
  nextAt.flows = now() + FLOWS_MS
  helper.submit("flows-sync", user, function(data, err)
    if err ~= nil then
      if err.code == "not_implemented" then
        return
      end
      nextAt.flows = now() + signedFailure("flows", err)
    elseif data.done == false then
      local wait = tonumber(data.wait_ms) or 0
      if wait > 0 then
        nextAt.flows = now() + wait
      elseif signedAllowed() then
        runFlows(user)
      end
    else
      readFlows()
      historyVersion += 1
      sourceOk("flows")
    end
    publish()
  end)
end

-- Quotes don't move while every watched stock's market is closed.
local function quotesInterval(): number
  for _, symbol in prefsLib.watchedStocks(prefs) do
    if stockSession(prefsLib.stockTicker(symbol)) ~= "closed" then
      return if panelOpen then QUOTES_PANEL_MS else QUOTES_BAR_MS
    end
  end
  return QUOTES_CLOSED_MS
end

-- Fresh stock quotes as alert inputs, keyed EQ_<TICKER>. A stale quote is
-- the last one seen before the market closed and was already evaluated.
local function stockPrices(): { [string]: any }
  local out = {}
  for ticker, q in (stockQuotes and type(stockQuotes.quotes) == "table" and stockQuotes.quotes) or {} do
    local price = type(q) == "table" and q.stale ~= true and tonumber(q.mid)
    if price then
      out[prefsLib.STOCK_PREFIX .. ticker] = { price = price, change24h = stockDayChange(q, price) }
    end
  end
  return out
end

-- Quotes for watched stocks (and the list of tickers Binance Stocks has).
local function runStockQuotes(user: boolean, after: (() -> ())?)
  nextAt.quotes = now() + quotesInterval()
  helper.submit("stock-quotes", user, function(_, err)
    if err == nil then
      failures.quotes = 0
      stockQuotes = readJson("stock-quotes.json")
      equityList = readJson("equity-symbols.json")
      sourceOk("quotes")
      local prices = stockPrices()
      notifyAlerts(alertsLib.evaluate(prefs.alerts, prices, armed, now()), prices)
    else
      nextAt.quotes = now() + signedFailure("quotes", err)
    end
    if after ~= nil then
      after()
    end
    publish()
  end)
end

local function refreshSigned(user: boolean)
  if signedAllowed() then
    runBalances(user)
    runStocks(user)
  end
end

-- Keyring subcommands; account.json reflects their outcome.
local function runAccountCommand(command: string, user: boolean, after: ((any) -> ())?)
  if user then
    liftBlock()
    dependency = nil
  end
  helper.submit(command, user, function(data, err)
    reloadAccount()
    if err ~= nil and err.code == "missing_dependency" then
      dependency = "python-cryptography"
    elseif err ~= nil and BLOCKING[err.code] and command ~= "keygen" and command ~= "store-api-key" and err.slot ~= "pending" then
      -- A new key that fails verify leaves the active key polling.
      blocked = err.code
    elseif err == nil and (command == "verify" or command == "recheck") then
      blocked = nil
    end
    if err == nil and after ~= nil then
      after(data)
    end
    publish()
  end)
  publish()
end

-- Verifies a new pair (wizard) or re-checks the active key's read-only gate
-- (scheduled). Only the wizard may promote a pending pair; the re-check
-- always tests the active key, even mid-rotation.
local function verify(user: boolean)
  nextAt.verify = now() + VERIFY_RETRY_MS
  runAccountCommand(if user then "verify" else "recheck", user, function(data)
    nextAt.verify = now() + VERIFY_MS
    if data.promoted then
      sources = {}
    end
    refreshSigned(user)
  end)
end

local function verifying(): boolean
  return helper.pending("verify") or helper.pending("recheck")
end

local function disconnect()
  runAccountCommand("disconnect", true, function()
    account, balances, stocks, ledgerRaw, marksRaw, flows = nil, nil, nil, nil, nil, nil
    stockQuotes, equityList, cryptoCosts = nil, nil, nil
    historyVersion += 1
    sources = { prices = sources.prices }
  end)
end

-- ── CSV export ─────────────────────────────────────────────────────────────

-- XDG_DOWNLOAD_DIR from the environment or user-dirs.dirs, else ~/Downloads.
local function downloadDir(): string?
  local home = noctalia.getenv("HOME")
  if home == nil or home == "" then
    return nil
  end
  local dir = noctalia.getenv("XDG_DOWNLOAD_DIR")
  if dir == nil or string.sub(dir, 1, 1) ~= "/" then
    local config = noctalia.getenv("XDG_CONFIG_HOME")
    config = if config ~= nil and config ~= "" then config else `{home}/.config`
    local path = `{config}/user-dirs.dirs`
    dir = csv.downloadDir(if noctalia.fileExists(path) then noctalia.readFile(path) else nil, home)
  end
  return dir or `{home}/Downloads`
end

-- Writes holdings and the return on deposits (with the selected range) as
-- of the last published report. Luau builds it, as the service already holds
-- every figure in the report currency, and stages it in the data dir (0700);
-- the helper creates the file in the downloads folder (new name, mode 0600,
-- never through a symlink), which writeFile can't do.
local function exportCsv()
  -- The running export deletes the staged files when it ends; a second
  -- click would lose its request and report a failure.
  if helper.pending("export-csv") then
    return
  end
  local r = lastReport
  local t = now()
  if r == nil or r.mode ~= "connected" or r.totals == nil then
    lastExport = { at = t, error = "no_data" }
    return
  end
  local dir = downloadDir()
  local stamp = noctalia.formatTime("%Y-%m-%d %H:%M", t // 1000)
  local staged = path("export.csv")
  if dir == nil or not fs.writeAtomic(staged, csv.build(r, stamp)) then
    lastExport = { at = t, error = "write_failed", dir = dir }
    return
  end
  writeJson("export-request.json", { v = 1, dir = dir, day = string.sub(stamp, 1, 10) })
  helper.submit("export-csv", true, function(data, err)
    if err ~= nil or type(data.path) ~= "string" or type(data.name) ~= "string" then
      lastExport = { at = now(), error = "write_failed", dir = dir }
    else
      lastExport = { at = now(), path = data.path, name = data.name }
      noctalia.notify(noctalia.tr("notify.export.title"), noctalia.tr("notify.export.body", { name = data.name, dir = dir }))
    end
    publish()
  end)
end

-- ── Commands ───────────────────────────────────────────────────────────────

local function lookup(query: string)
  local candidates = market.candidates(query)
  local results, remaining = {}, #candidates
  lastLookup = query
  local function finish()
    if lastLookup ~= query then
      return -- superseded by a newer query
    end
    local ordered = {}
    for _, symbol in candidates do
      if results[symbol] ~= nil then
        table.insert(ordered, results[symbol])
      end
    end
    noctalia.state.set(state.LOOKUP, { query = query, at = now(), results = ordered })
  end
  if remaining == 0 or paused() then
    local view = { query = query, at = now(), results = {} }
    if remaining > 0 then
      view.error = { code = "rate_limited", at = now() }
    end
    noctalia.state.set(state.LOOKUP, view)
    return
  end
  for _, symbol in candidates do
    httpGet(market.tickerUrl(symbol), function(data, _)
      if data ~= nil then
        local parsed = market.parseTickers(data)[symbol]
        if parsed ~= nil then
          tickers[symbol] = parsed
          validSymbol[symbol] = true
          results[symbol] = tickerView(symbol)
        end
      end
      remaining -= 1
      if remaining == 0 then
        finish()
      end
    end)
  end
end

local function refuseWatch(symbol: string, code: string)
  watchNotice = { symbol = symbol, code = code, at = now() }
  publish()
end

local function addWatched(symbol: string)
  if prefsLib.watchAdd(prefs, symbol) then
    watchNotice = nil
    savePrefs()
    if prefsLib.isStock(symbol) then
      if signedAllowed() then
        runStockQuotes(true)
      end
    else
      nextAt.prices = now()
      planDaily()
    end
    publish()
  end
end

-- A ticker that is not a crypto pair may be a Binance Stocks ticker. Only the
-- helper can tell (exchangeInfo needs the API key), so keyless it is refused
-- with a hint to connect.
local function watchAddStock(entered: string, ticker: string)
  local symbol = prefsLib.STOCK_PREFIX .. ticker
  if not connected() then
    refuseWatch(entered, "stocks_need_account")
    return
  end
  local function check()
    local listed = equityList and type(equityList.symbols) == "table" and equityList.symbols
    if listed and listed[ticker] ~= nil then
      addWatched(symbol)
    else
      -- No list yet: the helper failed or signed calls are paused.
      refuseWatch(entered, if listed then "unknown_symbol" else "stocks_unavailable")
    end
  end
  if equityList == nil and signedAllowed() then
    runStockQuotes(true, check) -- fetches the ticker list on its first run
  else
    check()
  end
end

local function watchAdd(symbol: string)
  if not prefsLib.validSymbol(symbol) or table.find(prefs.watchlist, symbol) then
    return
  end
  if prefsLib.isStock(symbol) then
    watchAddStock(symbol, prefsLib.stockTicker(symbol))
    return
  end
  if validSymbol[symbol] then
    addWatched(symbol)
    return
  end
  httpGet(market.tickerUrl(symbol), function(data, err)
    if data ~= nil then
      validSymbol[symbol] = true
      addWatched(symbol)
    elseif market.isInvalidSymbol(err) then
      if prefsLib.validSymbol(prefsLib.STOCK_PREFIX .. symbol) and #symbol <= 16 then
        watchAddStock(symbol, symbol)
      else
        refuseWatch(symbol, "unknown_symbol")
      end
    end
  end)
end

local function onCommand(command)
  if type(command) ~= "table" then
    return
  end
  local action = command.action
  local changed = false
  if action == "refresh" then
    local scope = command.scope or "all"
    if scope == "all" or scope == "prices" then
      fetchPrices()
    end
    liftBlock()
    if scope == "all" or scope == "balances" then
      if signedAllowed() then
        runBalances(true)
      end
    end
    if scope == "all" or scope == "stocks" then
      if signedAllowed() then
        runStocks(true)
        if #prefsLib.watchedStocks(prefs) > 0 then
          runStockQuotes(true)
        end
      end
    end
    if scope == "flows" and signedAllowed() and not helper.pending("flows-sync") then
      runFlows(true)
    end
  elseif action == "panel" then
    panelOpen = command.open == true
    if panelOpen then
      nextAt.prices = math.min(nextAt.prices, now() + PRICES_PANEL_MS)
      nextAt.quotes = math.min(nextAt.quotes, now() + quotesInterval())
    else
      watchNotice = nil
    end
  elseif action == "keygen" then
    runAccountCommand("keygen", true, function(data)
      if type(data.public_key_pem) == "string" then
        noctalia.copyToClipboard(data.public_key_pem, "text/plain")
      end
    end)
  elseif action == "copy_public_key" then
    if account ~= nil and type(account.public_key_pem) == "string" then
      noctalia.copyToClipboard(account.public_key_pem, "text/plain")
    end
  elseif action == "store_api_key" then
    runAccountCommand("store-api-key", true)
  elseif action == "verify" then
    verify(true)
  elseif action == "disconnect" then
    disconnect()
  elseif action == "retry_keyring" then
    liftBlock()
    refreshSigned(true)
  elseif action == "set_privacy" and type(command.value) == "boolean" then
    changed = prefs.privacy ~= command.value
    prefs.privacy = command.value
  elseif action == "set_bar_mode" and prefsLib.BAR_MODES[command.mode] then
    changed = prefs.bar_mode ~= command.mode
    prefs.bar_mode = command.mode
  elseif action == "watch_add" and type(command.symbol) == "string" then
    watchAdd(string.upper(command.symbol))
  elseif action == "watch_remove" and type(command.symbol) == "string" then
    changed = prefsLib.watchRemove(prefs, command.symbol)
  elseif action == "watch_move" and type(command.symbol) == "string" then
    changed = prefsLib.watchMove(prefs, command.symbol, command.index)
  elseif action == "alert_add" and type(command.symbol) == "string" then
    changed = prefsLib.alertAdd(prefs, string.upper(command.symbol), command.kind, command.value, command.cooldownMin) ~= nil
    if changed then
      nextAt.prices = now()
      nextAt.quotes = now()
    end
  elseif action == "alert_update" and type(command.id) == "string" then
    changed = prefsLib.alertUpdate(prefs, command.id, command)
    armed[command.id] = nil
  elseif action == "set_asset_target" and type(command.key) == "string" then
    changed = prefsLib.setAssetTarget(prefs, command.key, command.share)
  elseif action == "alert_remove" and type(command.id) == "string" then
    changed = prefsLib.alertRemove(prefs, command.id)
  elseif action == "set_range" and type(command.preset) == "string" then
    rangeRequest = { preset = command.preset, from = command.from, to = command.to }
  elseif action == "lookup" and type(command.query) == "string" then
    lookup(command.query)
  elseif action == "export_csv" then
    exportCsv()
  end
  if changed then
    savePrefs()
  end
  publish()
end

-- ── Host callbacks ─────────────────────────────────────────────────────────

-- ── Daily summary ──────────────────────────────────────────────────────────

local function freshSource(name: string, t: number): boolean
  local s = sources[name]
  return s ~= nil and s.error == nil and s.okAt ~= nil and t - s.okAt <= SUMMARY_FRESH_MS
end

-- Once a day at the chosen local time: total, today's change and the
-- biggest mover, percentages only under the privacy mask. It waits while
-- balances or prices are stale and gives the day up at midnight.
local function dailySummary(t: number)
  if noctalia.getConfig("daily_summary") ~= true then
    return
  end
  local at = summaryLib.parseTime(noctalia.getConfig("daily_summary_time"))
  local day, minutes = usmarket.parseClock(noctalia.formatTime("%Y-%m-%d %H:%M", t // 1000))
  if at == nil or day == nil or not summaryLib.due(at, day, minutes :: number, prefs.summary_day) then
    return
  end
  local r = lastReport
  if r == nil or r.totals == nil or not tickersFresh or not freshSource("balances", t) or not freshSource("prices", t) then
    return
  end
  local privacy, cur, totals = r.privacy, r.currency, r.totals
  local lines = {}
  if not privacy then
    table.insert(lines, noctalia.tr("notify.summary.total", { value = fmt.money(totals.value, cur) }))
  end
  local today = totals.today
  if today ~= nil and (today.pct ~= nil or not privacy) then
    local change = if privacy then fmt.pct(today.pct) else fmt.money(today.pnl, cur, { signed = true })
    if not privacy and today.pct ~= nil then
      change ..= ` ({fmt.pct(today.pct)})`
    end
    table.insert(lines, noctalia.tr("notify.summary.today", { change = change }))
  end
  local mover = summaryLib.biggestMover(r.holdings)
  if mover ~= nil then
    table.insert(lines, noctalia.tr("notify.summary.mover", { asset = mover.asset, pct = fmt.pct(mover.today.pct) }))
  end
  noctalia.notify(noctalia.tr("notify.summary.title"), table.concat(lines, "\n"))
  prefs.summary_day = day
  savePrefs()
end

local function tick()
  local t = now()
  helper.tick()
  if t >= nextAt.prices then
    fetchPrices()
  end
  if t >= nextAt.daily then
    planDaily()
  end
  if verifyAllowed() then
    -- Due daily, and hourly while the gate blocks polling. It runs before
    -- any data subcommand, so an expired check is never skipped past.
    local verifiedAt = account.verified_at_ms or 0
    local due = t - verifiedAt > VERIFY_MS or blocked ~= nil
    if due and t >= nextAt.verify and not verifying() then
      verify(false)
    end
  end
  if signedAllowed() and not verifying() then
    if t >= nextAt.balances then
      runBalances(false)
    end
    if t >= nextAt.stocks then
      runStocks(false)
    end
    if t >= nextAt.flows and not helper.pending("flows-sync") then
      runFlows(false)
    end
    if t >= nextAt.quotes and #prefsLib.watchedStocks(prefs) > 0 then
      runStockQuotes(false)
    end
    -- The least urgent sync: it waits for an idle helper, so balances and
    -- the deposits read with them never queue behind it.
    if t >= nextAt.trades and balances ~= nil and flows ~= nil and flows.ready and helper.current() == nil then
      runTrades(false)
    end
  end
  publish()
  dailySummary(t)
end

function update()
  tick()
end

-- `noctalia msg plugin ayagmar/binance:service all status` logs what the
-- service publishes: modes, counts and error codes, never amounts.
local function logStatus()
  local report = noctalia.state.get(state.REPORT)
  if type(report) ~= "table" then
    noctalia.log("binance: no report published")
    return
  end
  local parts = {
    `mode={report.mode}`,
    `account={report.account.stage}`,
    `currency={report.currency}`,
    `watchlist={#report.watchlist}`,
    `holdings={#report.holdings}`,
    `wallets={#report.wallets}`,
    `history_days={if report.history then #report.history.days else 0}`,
    `busy={report.status.busyWhat or "no"}`,
  }
  for name, source in report.status.sources do
    table.insert(parts, `{name}={if source.error then source.error.code else "ok"}`)
  end
  if report.status.rateLimit then
    table.insert(parts, `rate_limited={report.status.rateLimit.status}`)
  end
  if report.status.keyring then
    table.insert(parts, `keyring={report.status.keyring}`)
  end
  local approx = 0
  for _, h in report.holdings do
    if h.costApprox then
      approx += 1
    end
  end
  table.insert(parts, `cost_approx={approx}`)
  if flows ~= nil then
    local complete, errors = 0, {}
    for source, c in flows.coverage do
      if c.complete then
        complete += 1
      elseif c.error then
        table.insert(errors, `{source}:{c.error}`)
      end
    end
    table.insert(parts, `flows_count={flows.count} flows_complete={complete} flows_since={flows.since or "-"}`)
    if #errors > 0 then
      table.insert(parts, `flows_errors={table.concat(errors, ",")}`)
    end
  end
  noctalia.log("binance: " .. table.concat(parts, " "))
end

function onIpc(event, _payload)
  if event == "refresh" then
    onCommand({ action = "refresh" })
  elseif event == "status" then
    logStatus()
  elseif event == "privacy-on" or event == "privacy-off" or event == "privacy-toggle" then
    local value = if event == "privacy-toggle" then not prefs.privacy else event == "privacy-on"
    onCommand({ action = "set_privacy", value = value })
  end
end

function onConfigChanged()
  -- Currency or day boundary changed: new pairs and opens may be needed.
  opens = {}
  historyVersion += 1
  nextAt.prices = 0
  nextAt.daily = 0
  tick()
end

noctalia.state.watch(state.COMMAND, onCommand)
noctalia.setUpdateInterval(TICK_MS)
publish() -- surfaces leave their "starting" state even before the first fetch
tick()
