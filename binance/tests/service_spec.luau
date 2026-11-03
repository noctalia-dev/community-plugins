--!nonstrict
-- The service under a fake host: what it fetches, when it spawns the helper,
-- and the report it publishes.

local t = require("./support/t")
local json = require("./support/json")
local hostLib = require("./support/host")
local loader = require("./support/loader")
local sources = require("../_generated/sources")

local T0 = hostLib.T0
local DAY = 86400000

local PRICES = {
  BTCUSDT = { open = 50000, last = 60000 },
  ETHUSDT = { open = 2500, last = 3000 },
  EURUSDT = { open = 1.25, last = 1.25 },
}

local function tickerRow(symbol)
  local p = PRICES[symbol]
  return {
    symbol = symbol,
    lastPrice = tostring(p.last),
    openPrice = tostring(p.open),
    priceChangePercent = tostring((p.last - p.open) / p.open * 100),
    highPrice = tostring(p.last),
    lowPrice = tostring(p.open),
  }
end

-- Public data-api answers: known pairs only, like Binance (-1121 otherwise).
local function market(url)
  local symbol = string.match(url, "[?&]symbol=([A-Z0-9]+)")
  if string.find(url, "ticker/24hr?symbols=", 1, true) then
    local rows = {}
    for s in pairs(PRICES) do
      if string.find(url, "%22" .. s .. "%22", 1, true) then
        table.insert(rows, tickerRow(s))
      end
    end
    for s in string.gmatch(url, "%%22([A-Z0-9]+)%%22") do
      if PRICES[s] == nil then
        return 400, { code = -1121, msg = "Invalid symbol." }
      end
    end
    return 200, rows
  end
  if PRICES[symbol] == nil then
    return 400, { code = -1121, msg = "Invalid symbol." }
  end
  if string.find(url, "/klines", 1, true) then
    local limit = tonumber(string.match(url, "limit=(%d+)"))
    local p, rows = PRICES[symbol], {}
    local today = T0 // DAY * DAY
    for i = limit - 1, 0, -1 do
      table.insert(rows, { today - i * DAY, tostring(p.open), "0", "0", tostring(p.last) })
    end
    return 200, rows
  end
  return 200, tickerRow(symbol)
end

local function start(host)
  local runtime = loader.entry(sources, host, "service.luau").start()
  return runtime
end

local function connectedFiles(host)
  host.writeJson("account.json", { v = 1, active = true, pending = "none", verified_at_ms = T0 - 3600000 })
  host.writeJson("balances.json", { v = 1, at_ms = T0, tokenized = {}, wallets = {
    { name = "Spot", active = true, btc_value = "0.5", assets = {
      { asset = "BTC", name = "Bitcoin", total = "0.5", btc_value = "0.5" },
      { asset = "USDT", name = "TetherUS", total = "100", btc_value = "0.0016" } } },
    { name = "Funding", active = true, btc_value = "0.1", assets = {
      { asset = "ETH", name = "Ethereum", total = "2", btc_value = "0.1" } } },
  } })
  host.writeJson("stocks.json", { v = 1, at_ms = T0, quote_currency = "USD", closed = {}, orders = { rows = 1, filled = 1 },
    positions = { { symbol = "AAA", qty = "2", avg_cost = "100", cost = "200", cost_known = true,
      realized_pnl = "0", fees = "0", orders = 1, tokenized_shares = "0",
      quote = { bid = "149", ask = "151", mid = "150", at_ms = T0, stale = false } } } })
  host.writeJson("ledger.json", { v = 1, first_day = "2026-10-17", days = {
    ["2026-10-17"] = { crypto = { BTC = "0.5", ETH = "2", USDT = "100" }, stocks = { AAA = "2" } } } })
  host.writeJson("marks.json", { v = 1, marks = { AAA = { ["2026-10-16"] = { mid = "140", at_ms = T0 - 3 * DAY } } } })
end

-- Every key path the report uses must appear in one of the contract fixtures.
local function paths(value, prefix, out)
  if type(value) ~= "table" then
    return out
  end
  if #value > 0 then
    for _, item in value do
      paths(item, prefix .. "[]", out)
    end
    return out
  end
  for k, v in value do
    local p = if prefix == "" then k else `{prefix}.{k}`
    if string.match(prefix, "^status%.sources$") then
      p = "status.sources.*" -- one entry per source
    end
    out[p] = true
    paths(v, p, out)
  end
  return out
end

local fixturePaths = {}
for _, name in { "snapshot.json", "snapshot-keyless.json", "snapshot-errors.json" } do
  paths(json.decode(sources[`fixtures/{name}`]), "", fixturePaths)
end

local function assertContract(report)
  for p in paths(report, "", {}) do
    if not fixturePaths[p] then
      error(`report key {p} is not in the contract fixtures`, 2)
    end
  end
end

t.test("keyless: prices and alerts without ever spawning Python", function()
  local host = hostLib.new()
  start(host)
  local report = host.report()
  t.eq({ report.mode, report.account.stage, #report.watchlist }, { "keyless", "none", 2 })
  host.drainRequests(market)
  report = host.report()
  t.eq(report.watchlist[1].price, 60000)
  t.eq(report.watchlist[2].change24h, 0.2)
  t.eq(#report.watchlist[1].spark, 30)
  host.command({ action = "alert_add", symbol = "btcusdt", kind = "above", value = 55000 })
  host.clock += 61000
  host.globals.noctalia.state.set("command", { action = "refresh", at = host.clock })
  host.drainRequests(market)
  t.eq(#host.notifications, 1)
  t.eq(host.readJson("prefs.json").alerts[1].symbol, "BTCUSDT")
  t.eq(#host.processes, 0)
  assertContract(host.report())
end)

t.test("connected: one helper run at a time, then a valued report", function()
  local host = hostLib.new()
  connectedFiles(host)
  local runtime = start(host)
  t.eq(#host.processes, 1, "single flight")
  t.eq(host.processes[1].argv, { "python3", "-I", "/plugin/binance_helper.py", "balances", "--data-dir", "/data" })
  t.eq(host.processes[1].timeout, 30000)
  host.finishProcess("balances", { ok = true })
  t.eq(host.processes[1].command, "stocks-sync")
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("flows-sync", { ok = true, done = true })
  host.drainRequests(market)
  runtime.call("update")
  local report = host.report()
  t.eq(report.mode, "connected")
  t.eq(report.totals.value, 0.5 * 60000 + 100 + 2 * 3000 + 2 * 150)
  -- BTC +5000, ETH +1000, AAA 2 x (150 - 140).
  t.eq(report.totals.today.pnl, 6020)
  t.eq(report.totals.todayPartial, false)
  t.eq(report.history.from, "2026-10-17")
  t.eq(#report.history.days, 3)
  t.eq(report.history.days[3].value, report.totals.value)
  t.eq(report.wallets[#report.wallets].name, "Stocks")
  assertContract(report)
  -- Nothing more to run until the next interval.
  t.eq(#host.processes, 0)
end)

t.test("targets on: the report shows drift and each drifted class is notified once", function()
  local host = hostLib.new()
  host.config.targets_enabled = true
  host.config.target_crypto, host.config.target_stocks, host.config.target_stable = 60, 30, 10
  host.config.drift_band = 5
  connectedFiles(host)
  local runtime = start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("flows-sync", { ok = true, done = true })
  host.drainRequests(market)
  runtime.call("update")
  local report = host.report()
  -- Crypto 36,000 of 36,400: far over 60%; stocks and stablecoins far under.
  t.eq(report.drift.off, { "crypto", "stocks", "stable" })
  t.eq(#host.notifications, 3)
  t.eq(host.readJson("prefs.json").drift_flagged, { "crypto", "stocks", "stable" })
  assertContract(report)
  host.clock += 61000
  host.drainRequests(market)
  runtime.call("update")
  t.eq(#host.notifications, 3, "still drifted: no repeat")
  -- A holding target set from the panel is saved and shows up as its own row.
  host.command({ action = "set_asset_target", key = "BTC", share = 0.5 })
  t.eq(host.readJson("prefs.json").asset_targets, { BTC = 0.5 })
  t.eq(host.report().drift.assets[1].id, "BTC")
end)

t.test("a crypto cost basis from trades-sync shows as average cost and floating P&L", function()
  local host = hostLib.new()
  connectedFiles(host)
  host.writeJson("crypto-costs.json", { v = 1, at_ms = T0, assets = {
    BTC = { avg_cost = "40000", cost = "20000", realized_pnl = "150", cost_approx = false },
    ETH = { avg_cost = "2000", cost = "4000", realized_pnl = "0", cost_approx = true },
  } })
  local runtime = start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("flows-sync", { ok = true, done = true })
  host.drainRequests(market)
  runtime.call("update")
  local byAsset = {}
  for _, h in host.report().holdings do
    byAsset[h.asset] = h
  end
  -- 0.5 BTC at 60,000 against an average of 40,000.
  t.eq({ byAsset.BTC.avgCost, byAsset.BTC.cost, byAsset.BTC.floating.pnl, byAsset.BTC.realized }, { 40000, 20000, 10000, 150 })
  t.eq(byAsset.ETH.costApprox, true)
  t.eq(byAsset.USDT.avgCost, nil)
  assertContract(host.report())
end)

t.test("the chart leaves out assets that only the live total can price", function()
  local host = hostLib.new()
  connectedFiles(host)
  -- XYZ has no USDT pair: live, it is valued through its BTC valuation.
  local balances = host.readJson("balances.json")
  table.insert(balances.wallets[1].assets, { asset = "XYZ", name = "Xyz", total = "10", btc_value = "0.01" })
  host.writeJson("balances.json", balances)
  local runtime = start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("flows-sync", { ok = true, done = true })
  host.drainRequests(market)
  -- The batch with XYZUSDT fails as an invalid symbol; the retry drops it.
  host.clock += 60000
  runtime.call("update")
  host.drainRequests(market)
  local report = host.report()
  local xyz = 0.01 * 60000
  t.eq(report.totals.value, 0.5 * 60000 + 100 + 2 * 3000 + 2 * 150 + xyz)
  t.eq(report.history.days[3].value, report.totals.value - xyz)
end)

t.test("a stocks sync that is not done continues right away", function()
  local host = hostLib.new()
  connectedFiles(host)
  start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = false, pages = 8 })
  host.finishProcess("flows-sync", { ok = true, done = true }) -- queued before the next chunk
  t.eq(host.processes[1].command, "stocks-sync")
end)

t.test("set_range answers with a market return inside coverage", function()
  local host = hostLib.new()
  connectedFiles(host)
  start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.drainRequests(market)
  host.command({ action = "set_range", preset = "custom", from = "2026-10-17", to = "2026-10-19" })
  local range = host.report().range
  t.eq({ range.kind, range.from, range.to, range.pnl }, { "market", "2026-10-17", "2026-10-19", 0 })
  host.command({ action = "set_range", preset = "30d" })
  t.eq(host.report().range.error, "outside_coverage")
end)

t.test("EUR display converts with the EURUSDT rate", function()
  local host = hostLib.new()
  host.config.display_currency = "EUR"
  connectedFiles(host)
  start(host)
  host.drainRequests(market)
  local report = host.report()
  t.eq(report.currency, "EUR")
  t.eq(report.totals.value, (0.5 * 60000 + 100 + 2 * 3000 + 2 * 150) / 1.25)
end)

t.test("keygen copies the public key and shows the next wizard step", function()
  local host = hostLib.new()
  start(host)
  host.command({ action = "keygen" })
  t.eq(host.processes[1].timeout, 60000)
  host.finishProcess("keygen", { ok = true, public_key_pem = "PEM" }, function()
    host.writeJson("account.json", { v = 1, active = false, pending = "private", public_key_pem = "PEM" })
  end)
  t.eq(host.clipboard, "PEM")
  local account = host.report().account
  t.eq({ account.stage, account.publicKeyPem }, { "awaiting_api_key", "PEM" })
end)

t.test("a locked keyring stops signed polling until retry", function()
  local host = hostLib.new()
  connectedFiles(host)
  local runtime = start(host)
  host.finishProcess("balances", { error = "keyring_locked" })
  t.eq(host.report().status.keyring, "locked")
  -- stocks-sync was already queued; it fails the same way.
  host.finishProcess("stocks-sync", { error = "keyring_locked" })
  host.finishProcess("flows-sync", { error = "keyring_locked" })
  host.clock += 10 * 60000
  runtime.call("update")
  t.eq(#host.processes, 0)
  host.command({ action = "retry_keyring" })
  t.eq(host.processes[1].command, "balances")
  t.eq(host.report().status.keyring, nil)
end)

t.test("an expired re-check runs first, and a failed one stops polling until it passes", function()
  local host = hostLib.new()
  connectedFiles(host)
  host.writeJson("account.json", { v = 1, active = true, pending = "none", verified_at_ms = T0 - 2 * DAY })
  local runtime = start(host)
  t.eq(host.processes[1].command, "recheck")
  host.finishProcess("recheck", { error = "permissions_too_broad", flags = { "enableSpotAndMarginTrading" }, slot = "active" }, function()
    host.writeJson("account.json", { v = 1, active = true, pending = "none", verified_at_ms = T0 - 2 * DAY,
      gate_failed = { flags = { "enableSpotAndMarginTrading" }, at_ms = T0 } })
  end)
  host.clock += 10 * 60000
  runtime.call("update")
  t.eq(#host.processes, 0)
  -- A manual refresh (bar middle-click, IPC, panel button) does not lift it.
  host.command({ action = "refresh" })
  host.command({ action = "retry_keyring" })
  t.eq(#host.processes, 0)
  -- After a restart the block holds, and the re-check runs before any data.
  local host2 = hostLib.new()
  host2.files = host.files
  local runtime2 = start(host2)
  t.eq(#host2.processes, 1)
  t.eq(host2.processes[1].command, "recheck")
  host2.finishProcess("recheck", { error = "network_error" })
  host2.clock += 10 * 60000
  runtime2.call("update")
  t.eq(#host2.processes, 0)
  -- Retried hourly; once the key passes, polling resumes.
  host2.clock += 3600000
  runtime2.call("update")
  t.eq(host2.processes[1].command, "recheck")
  host2.finishProcess("recheck", { ok = true, slot = "active", promoted = false, verified_at = host2.clock }, function()
    host2.writeJson("account.json", { v = 1, active = true, pending = "none", verified_at_ms = host2.clock })
  end)
  t.eq(host2.processes[1].command, "balances")
end)

t.test("a new key failing verify leaves the active key polling", function()
  local host = hostLib.new()
  connectedFiles(host)
  local runtime = start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("flows-sync", { ok = true, done = true })
  host.command({ action = "verify" })
  host.finishProcess("verify", { error = "permissions_too_broad", flags = { "enableWithdrawals" }, slot = "pending" })
  host.clock += 5 * 60000
  runtime.call("update")
  t.eq(host.processes[1].command, "balances")
end)

t.test("the scheduled re-check tests the active key even mid-rotation", function()
  local host = hostLib.new()
  connectedFiles(host)
  host.writeJson("account.json", { v = 1, active = true, pending = "both", verified_at_ms = T0 - 2 * DAY })
  start(host)
  -- recheck never promotes the pending pair; only the wizard's verify does.
  t.eq(host.processes[1].command, "recheck")
  -- The panel names it with an existing busy label.
  t.eq(host.report().status.busyWhat, "verify")
end)

-- flows-daily.json with every source read: 100 deposited on 2026-10-18 at
-- a EURUSDT of 1.25, 1000 deposited and 200 withdrawn long before (at 1.1).
local function day(ms)
  return os.date("!%Y-%m-%d", ms // 1000)
end

local function flowDay(at, inUsd, outUsd, eurusd)
  return { day = day(at), in_usd = tostring(inUsd), out_usd = tostring(outUsd), in_eur = tostring(inUsd / eurusd),
    out_eur = tostring(outUsd / eurusd), valued = 1, no_usd = 0, no_eur = 0, no_eur_usd = "0" }
end

local function flowsFile(host, coverage)
  local function source(fromMs)
    return { from_day = "2017-07-01", from_ms = fromMs, to_ms = T0, complete = true }
  end
  host.writeJson("flows-daily.json", { v = 1, at_ms = T0, complete = true, since_day = "2025-01-01",
    uncovered = { "gifts_and_rewards" }, count = 3,
    coverage = coverage or { deposit = source(0), withdraw = source(0), p2p = source(T0 - 180 * DAY) },
    days = {
      flowDay(T0 - 600 * DAY, 1000, 0, 1.1),
      flowDay(T0 - 500 * DAY, 0, 200, 1.1),
      flowDay(T0 - DAY, 100, 0, 1.25),
    } })
end

local function connectedWithFlows(host, coverage)
  connectedFiles(host)
  flowsFile(host, coverage)
  local runtime = start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("deposits-recent", { ok = true, done = true, flows = 3, unpriced = 0 })
  host.drainRequests(market)
  return runtime
end

t.test("the return on net deposits subtracts flows at their flow-time value", function()
  local host = hostLib.new()
  connectedWithFlows(host)
  t.eq(#host.processes, 0, "flows were caught up before the reload: next sync in an hour")
  local report = host.report()
  local value = report.totals.value
  local net = report.totals.netDeposit
  t.eq({ net.pnl, net.since, net.uncovered }, { value - 900, "2025-01-01", { "gifts_and_rewards" } })
  t.eq(net.pct, (value - 900) / 900)
  t.eq(table.find(report.gaps, "flows_pending"), nil)
  -- Second chart series: 800 before the fiat deposit, 900 from its day on.
  t.eq({ report.history.days[1].netDeposit, report.history.days[2].netDeposit }, { 800, 900 })
  assertContract(report)
end)

t.test("a range switches to net of flows only when flows cover all of it", function()
  local host = hostLib.new()
  connectedWithFlows(host)
  host.command({ action = "set_range", preset = "custom", from = "2026-10-17", to = "2026-10-19" })
  local range = host.report().range
  t.eq({ range.kind, range.pnl }, { "net_of_flows", range.endValue - range.startValue - 100 })
  -- A deposit on the start day is already in the starting value.
  host.command({ action = "set_range", preset = "custom", from = "2026-10-18", to = "2026-10-19" })
  range = host.report().range
  t.eq(range.pnl, range.endValue - range.startValue)

  -- P2P read only from yesterday: the range is not covered, so it stays a
  -- market return.
  local partial = hostLib.new()
  local function source(fromMs)
    return { from_day = "2017-07-01", from_ms = fromMs, to_ms = T0, complete = true }
  end
  connectedWithFlows(partial, { deposit = source(0), p2p = source(T0 - DAY) })
  partial.command({ action = "set_range", preset = "custom", from = "2026-10-17", to = "2026-10-19" })
  t.eq(partial.report().range.kind, "market")
end)

t.test("a deposit read with balances is netted out before the next flows sync", function()
  local host = hostLib.new()
  local runtime = connectedWithFlows(host)
  local before = host.report().totals.netDeposit.pnl
  local file = host.readJson("flows-daily.json")
  table.insert(file.days, flowDay(T0, 50, 0, 1.25))
  host.writeJson("flows-daily.json", file)
  host.clock += 5 * 60000
  runtime.call("update")
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("deposits-recent", { ok = true, done = true, flows = 4, unpriced = 0 })
  t.eq(host.report().totals.netDeposit.pnl, before - 50)
end)

t.test("an account with no deposits says so once every source is read", function()
  local host = hostLib.new()
  connectedFiles(host)
  host.writeJson("flows-daily.json", { v = 1, at_ms = T0, complete = true, uncovered = { "gifts_and_rewards" }, count = 0, days = {},
    coverage = { deposit = { from_day = "2017-07-01", from_ms = 0, to_ms = T0, complete = true } } })
  start(host)
  host.finishProcess("balances", { ok = true })
  local gaps = host.report().gaps
  t.eq({ table.find(gaps, "no_flows") ~= nil, table.find(gaps, "flows_pending") }, { true, nil })
end)

t.test("EUR flows keep their flow-time rate", function()
  local host = hostLib.new()
  host.config.display_currency = "EUR"
  connectedWithFlows(host)
  local report = host.report()
  -- 1000/1.1 - 200/1.1 + 100/1.25 deposited, whatever today's EURUSDT.
  local deposited = 800 / 1.1 + 80
  t.eq(math.abs(report.totals.netDeposit.pnl - (report.totals.value - deposited)) < 1e-9, true)
end)

t.test("the return on deposits is withheld when unpriced flows are more than 1% of deposits", function()
  local function withPre2020(host, usd)
    connectedFiles(host)
    flowsFile(host)
    local file = host.readJson("flows-daily.json")
    -- A deposit before EURUSDT listed: valued in USD, with no EUR amount.
    table.insert(file.days, 1, { day = "2018-02-01", in_usd = tostring(usd), out_usd = "0", in_eur = "0", out_eur = "0",
      valued = 1, no_usd = 0, no_eur = 1, no_eur_usd = tostring(usd) })
    host.writeJson("flows-daily.json", file)
    start(host)
    host.finishProcess("balances", { ok = true })
    host.finishProcess("stocks-sync", { ok = true, done = true })
    host.finishProcess("deposits-recent", { ok = true, done = true })
    host.drainRequests(market)
    return host.report()
  end
  local eur = hostLib.new()
  eur.config.display_currency = "EUR"
  local report = withPre2020(eur, 10000)
  local net = report.totals.netDeposit
  t.eq({ net.pnl, net.pct, net.unavailable }, { nil, nil, "unpriced_flows" })
  t.eq(report.history.days[1].netDeposit, nil, "no net-deposit series either")
  assertContract(report)
  -- The same flows in USDT are all priced.
  t.eq(withPre2020(hostLib.new(), 10000).totals.netDeposit.unavailable, nil)
  -- Under 1% of what was deposited: published, with the footnote.
  eur = hostLib.new()
  eur.config.display_currency = "EUR"
  net = withPre2020(eur, 5).totals.netDeposit
  t.eq(net.pnl ~= nil and table.find(net.uncovered, "unpriced_flows") ~= nil, true)
end)

t.test("flows still waiting for a price show as pending, not as unpriced", function()
  local host = hostLib.new()
  connectedFiles(host)
  flowsFile(host)
  local file = host.readJson("flows-daily.json")
  table.insert(file.days, { day = day(T0), in_usd = "0", out_usd = "0", in_eur = "0", out_eur = "0",
    valued = 0, no_usd = 0, no_eur = 0, no_eur_usd = "0", awaiting = 40 })
  host.writeJson("flows-daily.json", file)
  start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  t.eq(host.processes[1].command, "flows-sync", "pricing continues right away")
  host.drainRequests(market)
  local report = host.report()
  t.eq(report.totals.netDeposit, nil)
  t.eq(table.find(report.gaps, "flows_pending") ~= nil, true)
end)

t.test("a recent deposit left without a price is retried soon, not at the hourly sync", function()
  local host = hostLib.new()
  local runtime = connectedWithFlows(host)
  local file = host.readJson("flows-daily.json")
  table.insert(file.days, { day = day(T0), in_usd = "0", out_usd = "0", in_eur = "0", out_eur = "0",
    valued = 0, no_usd = 0, no_eur = 0, no_eur_usd = "0", awaiting = 1 })
  host.writeJson("flows-daily.json", file)
  host.clock += 5 * 60000
  runtime.call("update")
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("deposits-recent", { ok = true, done = true })
  t.eq(#host.processes, 0)
  host.clock += 30000
  runtime.call("update")
  t.eq(host.processes[1].command, "flows-sync")
  -- Still unpriced after the sync: the next try backs off.
  host.finishProcess("flows-sync", { ok = true, done = true })
  host.clock += 30000
  runtime.call("update")
  t.eq(#host.processes, 0)
  host.clock += 30000
  runtime.call("update")
  t.eq(host.processes[1].command, "flows-sync")
end)

t.test("a flows chunk held back by UID weight resumes when Binance allows", function()
  local host = hostLib.new()
  connectedFiles(host)
  local runtime = start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("flows-sync", { ok = true, done = false, sources_pending = { "withdraw" }, wait_ms = 45000 })
  t.eq(#host.processes, 0, "not right away")
  t.eq(host.report().totals.netDeposit, nil)
  t.eq(table.find(host.report().gaps, "flows_pending") ~= nil, true)
  host.clock += 45000
  runtime.call("update")
  t.eq(host.processes[1].command, "flows-sync")
  host.finishProcess("flows-sync", { ok = true, done = false, sources_pending = { "deposit" }, wait_ms = 0 })
  t.eq(host.processes[1].command, "flows-sync", "unthrottled chunks continue right away")
end)

t.test("a public 429 pauses fetches and is shown", function()
  local host = hostLib.new()
  local runtime = start(host)
  host.respond("ticker/24hr", 429, "")
  local pause = host.readJson("ratelimit-public.json")
  t.eq({ pause.status, pause.backoff_s, pause.until_ms }, { 429, 60, T0 + 60000 })
  t.eq(host.report().status.rateLimit.status, 429)
  host.drainRequests(market) -- klines already queued
  host.clock += 30000
  runtime.call("update")
  t.eq(#host.requests, 0, "still paused")
  host.clock += 31000
  runtime.call("update")
  t.eq(host.respond("ticker/24hr", 200, {}), true)
  t.eq(host.readJson("ratelimit-public.json"), nil, "an expired pause is cleared after a success")
end)

t.test("an unknown watchlist pair is found and skipped", function()
  local host = hostLib.new()
  host.writeJson("prefs.json", { v = 1, watchlist = { "BTCUSDT", "NOPEUSDT" } })
  local runtime = start(host)
  host.drainRequests(market)
  host.clock += 61000
  runtime.call("update")
  local batch = nil
  for _, request in host.requests do
    if string.find(request.url, "symbols=", 1, true) then
      batch = request.url
    end
  end
  t.eq(batch ~= nil and string.find(batch, "NOPEUSDT", 1, true) == nil, true)
end)

-- ── Stocks in the watchlist ──

local function stockQuoteFiles(host, quotes)
  host.writeJson("equity-symbols.json", { v = 1, at_ms = host.clock, symbols = { AAPL = { overnight = true } } })
  host.writeJson("stock-quotes.json", { v = 1, at_ms = host.clock, quotes = quotes or {}, unknown = {} })
end

local function connectedIdle(host)
  connectedFiles(host)
  local runtime = start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.finishProcess("flows-sync", { ok = true, done = true })
  host.drainRequests(market)
  return runtime
end

t.test("keyless, a ticker that is not a pair is refused with a hint to connect", function()
  local host = hostLib.new()
  start(host)
  host.drainRequests(market)
  host.command({ action = "watch_add", symbol = "aapl" })
  host.drainRequests(market)
  local report = host.report()
  t.eq(report.watchNotice.code, "stocks_need_account")
  t.eq(#report.watchlist, 2)
  t.eq(#host.processes, 0)
  assertContract(report)
end)

t.test("connected, a stock ticker is checked by the helper and quoted with the key", function()
  local host = hostLib.new()
  local runtime = connectedIdle(host)
  host.command({ action = "watch_add", symbol = "AAPL" })
  host.drainRequests(market) -- AAPLUSDT: invalid symbol
  host.finishProcess("stock-quotes", { ok = true, done = true }, function()
    stockQuoteFiles(host, { AAPL = { bid = "100", ask = "102", mid = "101", at_ms = host.clock, stale = false,
      day = "2026-10-19", prev_mid = "100", prev_day = "2026-10-18" } })
  end)
  t.eq(host.readJson("prefs.json").watchlist, { "BTCUSDT", "ETHUSDT", "EQ_AAPL" })
  -- The new entry is saved before its quote run, which reads prefs.json.
  host.finishProcess("stock-quotes", { ok = true, done = true })
  local row = host.report().watchlist[3]
  t.eq({ row.base, row.kind, row.price, row.session }, { "AAPL", "stock", 101, "pre" }) -- 08:00 in New York
  local aaa = nil
  for _, h in host.report().holdings do
    if h.asset == "AAA" then
      aaa = h
    end
  end
  t.eq(aaa.session, "pre")
  t.eq(math.floor(row.change24h * 1e6 + 0.5), 10000)
  -- Stocks never go to the public crypto API.
  host.clock += 61000
  runtime.call("update")
  for _, request in host.requests do
    t.eq(string.find(request.url, "AAPL", 1, true), nil)
  end
  assertContract(host.report())
end)

-- Catches: sessions computed on the local clock when New York is unknown.
t.test("without tzdata for New York, stocks show no session and keep the open cadence", function()
  local host = hostLib.new()
  host.tzdata = false
  host.clock = hostLib.T0 + 6 * 3600000 -- Monday 14:00 in New York, 18:00 here
  host.writeJson("prefs.json", { v = 1, watchlist = { "EQ_AAPL" } })
  stockQuoteFiles(host, { AAPL = { bid = "100", ask = "102", mid = "101", at_ms = host.clock, stale = false, day = "2026-10-19" } })
  local runtime = connectedIdle(host)
  host.finishProcess("stock-quotes", { ok = true, done = true })
  local report = host.report()
  t.eq(report.watchlist[1].session, nil)
  for _, h in report.holdings do
    t.eq(h.session, nil, h.asset)
  end
  -- Not the 30-minute closed cadence: the next quote run comes within 3 minutes.
  host.clock += 3 * 60000 + 1000
  runtime.call("update")
  t.eq(#host.processes > 0 and host.processes[1].command, "stock-quotes")
end)

t.test("connected, a ticker Binance Stocks does not list is refused", function()
  local host = hostLib.new()
  stockQuoteFiles(host)
  connectedIdle(host)
  host.command({ action = "watch_add", symbol = "ZZZZ" })
  host.drainRequests(market)
  t.eq(host.report().watchNotice.code, "unknown_symbol")
  t.eq(#host.processes, 0) -- the cached list answered
end)

-- Catches: a failed quote run dimming the surfaces with no issue saying why.
t.test("a failed stock quote run is listed as an issue", function()
  local host = hostLib.new()
  host.writeJson("prefs.json", { v = 1, watchlist = { "EQ_AAPL" } })
  local runtime = connectedIdle(host)
  host.finishProcess("stock-quotes", { ok = true, done = true })
  host.clock += 4 * 60000
  runtime.call("update")
  host.finishProcess("stock-quotes", { error = "network_error" })
  local report = host.report()
  t.eq(report.status.stale, true)
  local statusPath = "ui/status.luau" -- not a literal: run.sh rewrites require("….luau")
  local status = runtime.require(statusPath)
  local bodies = {}
  for _, issue in status.issues(report) do
    table.insert(bodies, issue.body)
  end
  t.eq(string.find(table.concat(bodies, "\n"), "panel.source.quotes", 1, true) ~= nil, true)
end)

t.test("a stock alert fires once on a fresh quote across its threshold", function()
  local host = hostLib.new()
  host.writeJson("prefs.json", { v = 1, watchlist = { "BTCUSDT" },
    alerts = { { id = "a1", symbol = "EQ_AAPL", kind = "above", value = 100, cooldown_min = 0, enabled = true } } })
  local runtime = connectedIdle(host)
  local quote = { bid = "100", ask = "102", mid = "101", at_ms = host.clock, stale = false, day = "2026-10-19" }
  host.finishProcess("stock-quotes", { ok = true, done = true }, function()
    stockQuoteFiles(host, { AAPL = quote })
  end)
  t.eq(#host.notifications, 1)
  t.eq(string.find(host.notifications[1].title, '"symbol":"AAPL"', 1, true) ~= nil, true)
  host.clock += 4 * 60000
  runtime.call("update")
  host.finishProcess("stock-quotes", { ok = true, done = true })
  t.eq(#host.notifications, 1) -- still above: re-arms only once it drops below
end)

t.test("a stock percentage alert uses the day change", function()
  local host = hostLib.new()
  host.writeJson("prefs.json", { v = 1, watchlist = {},
    alerts = { { id = "a1", symbol = "EQ_AAPL", kind = "move_pct", value = 0.05, cooldown_min = 60, enabled = true } } })
  connectedIdle(host)
  host.finishProcess("stock-quotes", { ok = true, done = true }, function()
    stockQuoteFiles(host, { AAPL = { bid = "105", ask = "107", mid = "106", at_ms = host.clock, stale = false,
      day = "2026-10-19", prev_mid = "100", prev_day = "2026-10-16" } })
  end)
  t.eq(#host.notifications, 1)
  t.eq(string.sub(host.notifications[1].body, 1, 30), "notify.alert.move_pct.body_sto")
end)

-- Catches: held stocks never getting the listing's session flags while no
-- stock is watched (stock-quotes never runs then).
t.test("a held stock gets its overnight session from the listing stocks-sync refreshed", function()
  local host = hostLib.new()
  host.clock = hostLib.T0 + 13 * 3600000 -- Monday 21:00 in New York
  connectedFiles(host)
  start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true }, function()
    host.writeJson("equity-symbols.json", { v = 1, at_ms = host.clock, symbols = { AAA = { overnight = true, extended = true } } })
  end)
  host.finishProcess("flows-sync", { ok = true, done = true })
  local aaa = nil
  for _, h in host.report().holdings do
    if h.asset == "AAA" then
      aaa = h
    end
  end
  t.eq(aaa.session, "overnight")
end)

-- Catches: a week-old base shown as today's change and firing a percentage alert.
t.test("a stock day change against a quote older than the previous trading day is dropped", function()
  local host = hostLib.new()
  host.writeJson("prefs.json", { v = 1, watchlist = { "EQ_AAPL" },
    alerts = { { id = "a1", symbol = "EQ_AAPL", kind = "move_pct", value = 0.05, cooldown_min = 60, enabled = true } } })
  connectedIdle(host)
  host.finishProcess("stock-quotes", { ok = true, done = true }, function()
    stockQuoteFiles(host, { AAPL = { bid = "108", ask = "110", mid = "109", at_ms = host.clock, stale = false,
      day = "2026-10-19", prev_mid = "100", prev_day = "2026-10-15" } }) -- Thursday; Friday was a trading day
  end)
  t.eq(host.report().watchlist[1].change24h, nil)
  t.eq(#host.notifications, 0)
end)

-- ── CSV export ──

-- Catches: the service writing into Downloads itself (writeFile follows a
-- dangling symlink and leaves the file world-readable) instead of staging.
t.test("export stages the CSV in the data dir and the helper saves it", function()
  local host = hostLib.new()
  connectedIdle(host)
  host.command({ action = "set_range", preset = "all" })
  host.command({ action = "export_csv" })
  local text = host.files["/data/export.csv"]
  t.eq(string.find(text, "\ncrypto,BTC,0.5,60000,30000,", 1, true) ~= nil, true)
  t.eq(string.find(text, "\nstock,AAA,2,150,300,100,200,100,50\n", 1, true) ~= nil, true)
  t.eq(string.find(text, "\nall,2026-10-17,2026-10-19,market,", 1, true) ~= nil, true) -- the range picked on Overview
  t.eq(host.readJson("export-request.json"), { v = 1, dir = "/home/u/Downloads", day = "2026-10-19" })
  for p in host.files do
    t.eq(string.find(p, "/home/u/Downloads/", 1, true), nil, p)
  end
  t.eq(host.processes[1].argv, { "python3", "-I", "/plugin/binance_helper.py", "export-csv", "--data-dir", "/data" })
  host.finishProcess("export-csv", { ok = true, path = "/home/u/Downloads/binance-portfolio-2026-10-19-2.csv",
    name = "binance-portfolio-2026-10-19-2.csv" })
  local export = host.report().export
  t.eq({ export.path, export.name }, { "/home/u/Downloads/binance-portfolio-2026-10-19-2.csv", "binance-portfolio-2026-10-19-2.csv" })
  t.eq(#host.notifications, 1)
  assertContract(host.report())
end)

-- Catches: a second click while the first export runs, whose request the
-- running helper deletes, turning a saved file into a reported failure.
t.test("a failed export says so and sends no notification", function()
  local host = hostLib.new()
  connectedIdle(host)
  host.command({ action = "export_csv" })
  host.finishProcess("export-csv", { error = "write_failed", detail = "PermissionError: Permission denied" })
  t.eq({ host.report().export.error, host.report().export.dir }, { "write_failed", "/home/u/Downloads" })
  t.eq(#host.notifications, 0)
end)

-- ── Daily summary ──

t.test("the daily summary is sent once a day, survives a restart and respects privacy", function()
  local host = hostLib.new()
  host.config.daily_summary = true
  host.config.daily_summary_time = "11:30" -- T0 is 12:00 (the fake host's local time is UTC)
  local runtime = connectedIdle(host)
  runtime.call("update")
  t.eq(#host.notifications, 1)
  local body = host.notifications[1].body
  t.eq(string.find(body, "36,400.00 USDT", 1, true) ~= nil, true)
  t.eq(string.find(body, '"asset":"BTC"', 1, true) ~= nil, true) -- +20%, the largest move
  runtime.call("update")
  t.eq(#host.notifications, 1)
  t.eq(host.readJson("prefs.json").summary_day, "2026-10-19")
  -- Restarted the same day: not again.
  host.processes, host.requests = {}, {}
  connectedIdle(host)
  t.eq(#host.notifications, 1)

  -- Next day, privacy on: percentages only.
  local next = hostLib.new()
  next.files = host.files
  next.clock = host.clock + DAY
  next.config = host.config
  next.writeJson("account.json", { v = 1, active = true, pending = "none", verified_at_ms = next.clock - 3600000 })
  local prefs = next.readJson("prefs.json")
  prefs.privacy = true
  next.writeJson("prefs.json", prefs)
  local nextRuntime = start(next)
  next.finishProcess("balances", { ok = true })
  next.finishProcess("stocks-sync", { ok = true, done = true })
  next.finishProcess("flows-sync", { ok = true, done = true })
  next.drainRequests(market)
  nextRuntime.call("update")
  t.eq(#next.notifications, 1)
  t.eq(string.find(next.notifications[1].body, "USDT", 1, true), nil)
  t.eq(string.find(next.notifications[1].body, "%", 1, true) ~= nil, true)
end)

t.test("the daily summary waits while balances are stale", function()
  local host = hostLib.new()
  host.config.daily_summary = true
  host.config.daily_summary_time = "11:30"
  connectedFiles(host)
  local runtime = start(host)
  host.finishProcess("balances", { error = "network_error" })
  host.drainRequests(market)
  runtime.call("update")
  t.eq(#host.notifications, 0)
end)

t.test("the status IPC logs codes and counts, never amounts", function()
  local host = hostLib.new()
  connectedFiles(host)
  local runtime = start(host)
  host.finishProcess("balances", { ok = true })
  host.finishProcess("stocks-sync", { ok = true, done = true })
  host.drainRequests(market)
  runtime.call("onIpc", "status")
  local line = host.logs[#host.logs]
  t.eq(string.find(line, "mode=connected", 1, true) ~= nil, true)
  t.eq(string.find(line, "holdings=4", 1, true) ~= nil, true)
  t.eq(string.find(line, "60000", 1, true), nil)
  t.eq(string.find(line, "36400", 1, true), nil)
end)

return {}
