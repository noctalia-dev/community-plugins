--!nonstrict
-- Unit tests for the pure modules in lib/. No noctalia host involved.

local t = require("./support/t")
local days = require("../lib/days")
local market = require("../lib/market")
local prefsLib = require("../lib/prefs")
local alerts = require("../lib/alerts")
local ledger = require("../lib/ledger")
local portfolio = require("../lib/portfolio")
local helperLib = require("../lib/helper")
local usmarket = require("../lib/usmarket")
local summary = require("../lib/summary")
local csv = require("../lib/csv")
local allocation = require("../lib/allocation")
local drift = require("../lib/drift")

local function decode(s)
  -- Just enough JSON for the helper parser tests.
  if s == '{"ok":true,"done":false}' then
    return { ok = true, done = false }
  elseif s == '{"error":"permissions_too_broad","flags":["enableWithdrawals"]}' then
    return { error = "permissions_too_broad", flags = { "enableWithdrawals" } }
  end
  return nil
end
local function trim(s)
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- ── days ──

t.test("days round-trip across leap years and the epoch", function()
  for _, day in { "1970-01-01", "2024-02-29", "2026-10-19", "2000-12-31" } do
    t.eq(days.fromNumber(days.number(day)), day)
  end
  t.eq(days.number("1970-01-02"), 1)
end)

t.test("a local day boundary shifts the day of an instant", function()
  local ms = days.startMs("2026-10-19") + 23 * 3600000 -- 23:00 UTC
  t.eq(days.of(ms), "2026-10-19")
  t.eq(days.of(ms, 2 * 3600000), "2026-10-20")
  t.eq(days.of(days.startMs("2026-10-20", 2 * 3600000)), "2026-10-19")
  t.eq(days.offsetLabel(-5 * 3600000 - 30 * 60000), "-5:30")
  t.eq(days.weekday(days.number("2026-10-19")), 1) -- a Monday
end)

-- ── market ──

t.test("launcher queries become candidate pairs", function()
  t.eq(market.candidates("btc")[1], "BTCUSDT")
  t.eq(market.candidates("eth/eur")[1], "ETHEUR")
  t.eq(market.candidates("SOLUSDT")[1], "SOLUSDT")
  t.eq(market.candidates("$(x)"), {})
  t.eq(market.candidates("b"), {})
  t.eq(table.pack(market.split("ETHBTC")), { "ETH", "BTC", n = 2 })
end)

t.test("binance errors keep their code; rate limits are recognised", function()
  local function dec(s)
    return if s == "{-1121}" then { code = -1121, msg = "Invalid symbol." } else nil
  end
  local _, err = market.interpret({ ok = true, status = 400, body = "{-1121}" }, dec)
  t.eq(market.isInvalidSymbol(err), true)
  _, err = market.interpret({ ok = true, status = 429, body = "" }, dec)
  t.eq(err, { code = "rate_limited", status = 429 })
  _, err = market.interpret({ ok = false, status = 0 }, dec)
  t.eq(err.code, "network_error")
end)

t.test("klines give the first day, daily closes and today's open", function()
  local d0 = days.startMs("2026-10-17")
  local rows = {
    { d0, "10", "12", "9", "11" },
    { d0 + days.DAY_MS, "11", "13", "10", "12" },
    { d0 + 2 * days.DAY_MS, "12", "12", "11", "11.5" },
  }
  local first, closes, open = market.parseKlines(rows, days.of)
  t.eq({ first, closes, open }, { "2026-10-17", { 11, 12, 11.5 }, 12 })
end)

-- ── prefs ──

t.test("prefs keep only well-formed values", function()
  local p = prefsLib.sanitize({
    privacy = "yes",
    bar_mode = "icon",
    watchlist = { "BTCUSDT", "BTCUSDT", "bad symbol", 7 },
    alerts = {
      { id = "a1", symbol = "BTCUSDT", kind = "above", value = 1 },
      { id = "a2", symbol = "BTCUSDT", kind = "sideways", value = 1 },
    },
  })
  t.eq(p.privacy, false)
  t.eq(p.bar_mode, "icon")
  t.eq(p.watchlist, { "BTCUSDT" })
  t.eq(#p.alerts, 1)
  t.eq(p.alerts[1].cooldown_min, prefsLib.DEFAULT_COOLDOWN_MIN)
end)

-- ── alerts ──

t.test("an alert fires on the crossing, re-arms, and respects its cooldown", function()
  local list = { { id = "a1", symbol = "X", kind = "above", value = 100, cooldown_min = 60, enabled = true } }
  local armed = {}
  local function at(price, now)
    return #alerts.evaluate(list, { X = { price = price } }, armed, now)
  end
  t.eq(at(90, 0), 0)
  t.eq(at(101, 1000), 1)
  t.eq(at(105, 2000), 0, "stays quiet while above")
  t.eq(at(99, 3000), 0)
  t.eq(at(102, 4000), 0, "re-armed but inside the cooldown")
  t.eq(at(99, 3700000), 0)
  t.eq(at(103, 3700001), 1, "after the cooldown")
  t.eq(at(103, 3800000), 0)
end)

t.test("move_pct compares the absolute 24h change", function()
  local a = { id = "m", symbol = "X", kind = "move_pct", value = 0.05, cooldown_min = 0, enabled = true }
  t.eq(alerts.condition(a, { price = 1, change24h = -0.06 }), true)
  t.eq(alerts.condition(a, { price = 1, change24h = 0.01 }), false)
  t.eq(alerts.condition(a, { price = 1 }), nil)
end)

-- ── ledger ──

t.test("ledger rows carry quantities over missing days", function()
  local rows = ledger.rows({
    days = {
      ["2026-10-17"] = { crypto = { BTC = "1" } },
      ["2026-10-19"] = { crypto = { BTC = "2" }, stocks = { AAA = "3" } },
    },
  }, "2026-10-20")
  t.eq(#rows, 4)
  t.eq(rows[2].day, "2026-10-18")
  t.eq(rows[2].crypto, { BTC = 1 })
  t.eq(rows[4].stocks, { AAA = 3 })
end)

t.test("the ledger window starts from the row in force before it", function()
  local saved = ledger.MAX_DAYS
  ledger.MAX_DAYS = 2
  local rows = ledger.rows({ days = { ["2026-10-10"] = { crypto = { BTC = "5" } } } }, "2026-10-20")
  ledger.MAX_DAYS = saved
  t.eq({ #rows, rows[1].day, rows[1].crypto.BTC }, { 2, "2026-10-19", 5 })
end)

t.test("marks look back to the last trading day", function()
  local m = ledger.marks({ marks = { AAA = { ["2026-10-16"] = { mid = "10" }, ["2026-10-19"] = { mid = "12" } } } }).AAA
  local mon = days.number("2026-10-19")
  t.eq(ledger.markOn(m, mon - 1), 10, "Sunday uses Friday")
  t.eq(ledger.markOn(m, mon), 12)
  t.eq(ledger.markOn(m, mon, true), 10, "previous close for today's P&L")
  t.eq(ledger.markOn(m, mon - 5), nil)
end)

-- ── portfolio ──

local function sample()
  return {
    balances = {
      wallets = {
        { name = "Spot", assets = {
          { asset = "BTC", name = "Bitcoin", total = "0.5", btc_value = "0.5" },
          { asset = "USDT", name = "Tether", total = "100", btc_value = "0.0016" },
          { asset = "XYZ", name = "No pair", total = "10", btc_value = "0.001" },
        } },
        { name = "Funding", assets = { { asset = "BTC", total = "0.5", btc_value = "0.5" } } },
      },
    },
    stocks = {
      positions = {
        { symbol = "AAA", qty = "2", avg_cost = "100", cost = "200", cost_known = true, realized_pnl = "5",
          tokenized_shares = "0", quote = { mid = "150", at_ms = 1, stale = false } },
        { symbol = "TOK", qty = "1", avg_cost = "0", cost = "0", cost_known = false,
          tokenized_shares = "1", quote = { mid = "10", at_ms = 1, stale = true } },
      },
    },
    prices = { BTC = { price = 60000, open = 50000 } },
    prevMarks = { AAA = 140 },
    rate = 1,
  }
end

t.test("holdings value crypto, stocks and assets without a USDT pair", function()
  local holdings, wallets, totals = portfolio.build(sample())
  local order = {}
  for _, h in holdings do
    table.insert(order, h.asset)
  end
  t.eq(order, { "BTC", "AAA", "USDT", "XYZ", "TOK" })
  t.eq(holdings[1].today, { pnl = 10000, pct = 0.2 })
  t.eq(holdings[4].value, 60, "XYZ via its BTC valuation")
  t.eq(holdings[2].floating, { pnl = 100, pct = 0.5 })
  t.eq(holdings[2].today.pnl, 20)
  t.eq({ holdings[5].avgCost, holdings[5].tokenizedQty, holdings[5].quoteStale }, { nil, 1, true })
  t.eq({ holdings[2].realized, holdings[5].realized }, { 5, nil }, "no realized line without a known total")
  t.eq({ totals.value, totals.crypto, totals.stocks }, { 60470, 60160, 310 })
  t.eq({ totals.today.pnl, totals.todayPartial }, { 10020, true })
  t.eq({ wallets[1].value, wallets[2].value, wallets[3].name, wallets[3].value }, { 30160, 30000, "Stocks", 310 })
end)

t.test("today's change stays out while most of the value has no basis", function()
  -- Day 1 with Stocks: no previous mark yet, a small stablecoin move.
  local input = sample()
  input.prices = { BTC = { price = 60000, open = 60000 } }
  input.balances = { wallets = { { name = "Funding", assets = {
    { asset = "USDC", total = "10", btc_value = "0.0002" },
  } } } }
  input.prices.USDC = { price = 0.9999, open = 1 }
  input.prevMarks = {}
  local _, _, totals = portfolio.build(input)
  t.eq({ totals.today, totals.todayPartial }, { nil, true })

  input.prevMarks = { AAA = 140 }
  _, _, totals = portfolio.build(input)
  t.eq(totals.today.pnl, 10 * (0.9999 - 1) + 20)
end)

local function historySample()
  local rows = ledger.rows({
    days = {
      ["2026-10-17"] = { crypto = { BTC = "1" }, stocks = { AAA = "1" } },
      ["2026-10-18"] = { crypto = { BTC = "2" }, stocks = { AAA = "1" } }, -- deposit of 1 BTC
    },
  }, "2026-10-19")
  return {
    rows = rows,
    closes = { BTC = { first = days.number("2026-10-17"), closes = { 100, 110, 121 } } },
    marks = ledger.marks({ marks = { AAA = { ["2026-10-19"] = { mid = "60" } } } }),
    costs = { AAA = 50 },
  }
end

t.test("history values each day and flags stocks valued at cost", function()
  local points = portfolio.history(historySample())
  t.eq(points, {
    { day = "2026-10-17", value = 150, stocksAtCost = true },
    { day = "2026-10-18", value = 270, stocksAtCost = true },
    { day = "2026-10-19", value = 302 },
  })
end)

t.test("market return ignores deposits and unmarked stock days", function()
  local input = historySample()
  local from, to = days.number("2026-10-17"), days.number("2026-10-19")
  -- Day 2: 1 BTC x 10; day 3: 2 BTC x 11. The extra BTC and AAA's first mark are not gains.
  t.eq(portfolio.marketReturn(input, from, to), 32)
  t.eq(portfolio.marketReturn(input, from + 1, to), 22)
end)

t.test("EUR history uses each day's rate", function()
  local input = historySample()
  input.eur = { first = days.number("2026-10-17"), closes = { 1, 2, 2 } }
  local points = portfolio.history(input)
  t.eq({ points[1].value, points[2].value }, { 150, 135 })
  t.eq(portfolio.marketReturn(input, days.number("2026-10-17"), days.number("2026-10-19")), 10 / 2 + 22 / 2)
end)

-- ── helper runner ──

local function fakeHost()
  local host = { calls = {}, clock = 0 }
  host.run = function(argv, cb, timeout)
    table.insert(host.calls, { command = argv[1], cb = cb, timeout = timeout })
    return true
  end
  host.decode = decode
  host.trim = trim
  host.now = function()
    return host.clock
  end
  return host
end

local function argv(command)
  return { command }
end

t.test("user actions jump the queue and repeated commands coalesce", function()
  local host = fakeHost()
  local runner = helperLib.new(host, argv)
  local seen = {}
  runner.submit("balances", false, function() end)
  runner.submit("stocks-sync", false, function()
    table.insert(seen, "stocks-1")
  end)
  runner.submit("stocks-sync", false, function()
    table.insert(seen, "stocks-2")
  end)
  runner.submit("keygen", true, function() end)
  t.eq(#host.calls, 1, "one at a time")
  host.calls[1].cb({ stdout = '{"ok":true,"done":false}', timedOut = false })
  t.eq(host.calls[2].command, "keygen")
  t.eq(host.calls[2].timeout, helperLib.KEYRING_TIMEOUT_MS)
  host.calls[2].cb({ stdout = "", timedOut = true })
  t.eq(host.calls[3].command, "stocks-sync")
  host.calls[3].cb({ stdout = '{"ok":true,"done":false}\n', timedOut = false })
  t.eq(seen, { "stocks-1", "stocks-2" })
  t.eq(#host.calls, 3)
end)

t.test("helper errors carry their detail and lost runs are abandoned", function()
  local host = fakeHost()
  local runner = helperLib.new(host, argv)
  local got = {}
  runner.submit("verify", true, function(data, err)
    table.insert(got, { data, err })
  end)
  runner.submit("balances", false, function(_, err)
    table.insert(got, { nil, err })
  end)
  host.clock = helperLib.KEYRING_TIMEOUT_MS + 20000
  runner.tick()
  t.eq(got[1][2], { code = "timeout" })
  t.eq(host.calls[2].command, "balances")
  -- The abandoned run's late answer is dropped.
  host.calls[1].cb({ stdout = '{"ok":true,"done":false}', timedOut = false })
  t.eq(#got, 1)
  host.calls[2].cb({ stdout = '{"error":"permissions_too_broad","flags":["enableWithdrawals"]}', timedOut = false })
  t.eq(got[2][2], { code = "permissions_too_broad", flags = { "enableWithdrawals" } })
end)

t.test("a helper that dies without answering is told apart from an odd answer", function()
  local _, err = helperLib.parse({ stdout = "", stderr = "can't open file", exitCode = 2, timedOut = false }, decode, trim)
  t.eq(err, { code = "helper_failed", status = 2 })
  _, err = helperLib.parse({ stdout = "garbage", exitCode = 0, timedOut = false }, decode, trim)
  t.eq(err, { code = "bad_output" })
end)

-- ── usmarket ──

-- Catches: a day change based on a quote from before a weekend or holiday
-- being refused, or one from a week ago being accepted.
t.test("the previous trading day skips weekends and NYSE holidays", function()
  t.eq(usmarket.previousTradingDay("2026-10-19"), "2026-10-16") -- Monday -> Friday
  t.eq(usmarket.previousTradingDay("2026-10-21"), "2026-10-20")
  t.eq(usmarket.previousTradingDay("2026-11-27"), "2026-11-25") -- after Thanksgiving
  t.eq(usmarket.previousTradingDay("2026-04-06"), "2026-04-02") -- Easter Monday, after Good Friday
  t.eq(usmarket.previousTradingDay("2026-10-18"), "2026-10-16") -- a Sunday
  t.eq(usmarket.previousTradingDay("bad"), nil)
end)

t.test("US sessions follow the New York clock, holidays and early closes", function()
  local function at(day, hhmm, overnight)
    local h, m = string.match(hhmm, "(%d+):(%d+)")
    return usmarket.session(day, tonumber(h) * 60 + tonumber(m), overnight)
  end
  -- Monday 2026-10-19.
  t.eq({ at("2026-10-19", "03:59"), at("2026-10-19", "04:00"), at("2026-10-19", "09:30") }, { "closed", "pre", "open" })
  t.eq({ at("2026-10-19", "15:59"), at("2026-10-19", "16:00"), at("2026-10-19", "20:00") }, { "open", "post", "closed" })
  t.eq({ at("2026-10-19", "20:00", true), at("2026-10-19", "02:00", true) }, { "overnight", "overnight" })
  -- Weekend: nothing on Saturday; overnight starts Sunday 20:00 for Monday.
  t.eq({ at("2026-10-24", "12:00", true), at("2026-10-23", "21:00", true), at("2026-10-25", "20:30", true) }, { "closed", "closed", "overnight" })
  -- Thanksgiving is closed; the day after closes at 13:00.
  t.eq({ at("2026-11-26", "10:00", true), at("2026-11-27", "12:59"), at("2026-11-27", "13:00"), at("2026-11-27", "17:00") }, { "closed", "open", "post", "closed" })
  -- No overnight into a holiday (Christmas 2026 is a Friday).
  t.eq(at("2026-12-24", "21:00", true), "closed")
  -- Catches: pre and post shown for a symbol Binance trades in the regular session only.
  t.eq({ usmarket.session("2026-10-19", 8 * 60, false, false), usmarket.session("2026-10-19", 10 * 60, false, false),
    usmarket.session("2026-10-19", 17 * 60, false, false), usmarket.session("2026-10-19", 21 * 60, true, false) },
    { "closed", "open", "closed", "overnight" })
  t.eq({ usmarket.parseClock("2026-10-19 08:05") }, { "2026-10-19", 485 })
end)

-- ── summary ──

t.test("the daily summary time parses HH:MM and is due once per day", function()
  t.eq({ summary.parseTime("20:00"), summary.parseTime(" 7:05 "), summary.parseTime("24:00"), summary.parseTime("8pm") }, { 1200, 425 })
  t.eq(summary.due(1200, "2026-10-19", 1199, nil), false)
  t.eq(summary.due(1200, "2026-10-19", 1200, "2026-10-18"), true)
  t.eq(summary.due(1200, "2026-10-19", 1300, "2026-10-19"), false) -- already sent today
end)

t.test("the biggest mover ignores dust and compares absolute moves", function()
  local mover = summary.biggestMover({
    { asset = "DUST", allocation = 0.001, today = { pnl = 1, pct = 0.9 } },
    { asset = "BTC", allocation = 0.6, today = { pnl = 10, pct = 0.02 } },
    { asset = "SOL", allocation = 0.1, today = { pnl = -5, pct = -0.07 } },
    { asset = "NEW", allocation = 0.2 },
  })
  t.eq(mover.asset, "SOL")
end)

-- ── csv ──

t.test("CSV text cells are quoted and defused against formulas", function()
  t.eq(csv.text("BTC"), "BTC")
  t.eq(csv.text('a,"b"'), '"a,""b"""')
  t.eq(csv.text("=HYPERLINK(1)"), "'=HYPERLINK(1)")
  t.eq(csv.text("-2+3"), "'-2+3")
  t.eq(csv.text("@x,y"), "\"'@x,y\"")
  t.eq({ csv.number(-12.5, 2), csv.number(0.00000001), csv.number(2), csv.number(nil) }, { "-12.5", "0.00000001", "2", "" })
end)

t.test("the export finds the XDG download folder", function()
  local dirs = '# comment\nXDG_DESKTOP_DIR="$HOME/Desktop"\nXDG_DOWNLOAD_DIR="$HOME/Téléchargements"\n'
  t.eq(csv.downloadDir(dirs, "/home/u"), "/home/u/Téléchargements")
  t.eq(csv.downloadDir("XDG_DOWNLOAD_DIR=\"relative\"", "/home/u"), nil)
end)

-- ── drift ──

local function round(x)
  return math.floor(x * 1e6 + 0.5) / 1e6
end

t.test("target weights are normalized, and no weight means no targets", function()
  local a = drift.targets({ crypto = 6, stocks = 3, stable = 1 })
  local b = drift.targets({ crypto = 60, stocks = 30, stable = 10, other = 0 })
  t.eq(a, b)
  t.eq(round(a.crypto), 0.6)
  t.eq(drift.targets({ crypto = 0, stocks = 0 }), nil)
end)

t.test("the deposit plan only buys what is under target and spends the whole amount", function()
  local holdings = {
    { kind = "spot", asset = "BTC", value = 900 },
    { kind = "spot", asset = "USDT", value = 100 },
  }
  local d = drift.compute(holdings, { crypto = 0.6, stocks = 0.3, stable = 0.1 }, {}, 0.05)
  local plan = drift.plan(d, 500)
  local spent, ids = 0, {}
  for _, step in plan do
    spent += step.amount
    table.insert(ids, step.id)
  end
  t.eq(round(spent), 500)
  t.eq(ids, { "stocks", "stable" }) -- crypto is over target: nothing goes there
  t.eq(drift.plan(d, 0), {})
end)

t.test("a holding target is a share of the whole portfolio and gets its own deposit line", function()
  local holdings = {
    { kind = "stock", asset = "NVDA", value = 100 },
    { kind = "stock", asset = "AAPL", value = 500 },
    { kind = "spot", asset = "BTC", value = 400 },
  }
  local d = drift.compute(holdings, { crypto = 0.4, stocks = 0.6 }, { EQ_NVDA = 0.2 }, 0.05)
  t.eq(d.off, { "EQ_NVDA" }) -- 10% against 20%; the classes are on target
  t.eq(d.crowded, {})
  -- 1000 more: NVDA needs 300 to reach 20% of 2000, the other stocks 300 to
  -- reach 800 (60% less NVDA's 20%), crypto 400 to reach 800.
  local amounts = {}
  for _, step in drift.plan(d, 1000) do
    amounts[if step.rest then `rest-{step.class}` else step.id] = round(step.amount)
  end
  t.eq(amounts, { EQ_NVDA = 300, ["rest-stocks"] = 300, crypto = 400 })
  -- Holding targets alone: each line stops at its target and the rest of
  -- the money is left over; with nothing targeted the card still shows.
  d = drift.compute(holdings, nil, { EQ_NVDA = 0.2 }, 0.05)
  t.eq(#d.rows, 0)
  t.eq(round(drift.plan(d, 5000)[1].amount), 1100) -- 20% of 6000, less 100 held
  t.eq(#drift.compute(holdings, nil, {}, 0.05).assets, 0)
  -- One more than its class.
  t.eq(drift.compute(holdings, { crypto = 0.4, stocks = 0.6 }, { BTC = 0.5 }, 0.05).crowded, { "crypto" })
end)

t.test("a typed deposit reads decimal commas and thousands separators", function()
  t.eq(drift.parseAmount("250,50"), 250.5)
  t.eq(drift.parseAmount("1,250.50"), 1250.5)
  t.eq(drift.parseAmount(" 1 000 "), 1000)
  t.eq(drift.parseAmount("1,000"), 1000)
  t.eq(drift.parseAmount("1.250,50"), 1250.5)
  t.eq(drift.parseAmount("0x10"), nil)
end)

t.test("a drifted class is notified once, and again only once it came well back", function()
  local function at(share)
    local holdings = { { kind = "spot", asset = "BTC", value = share }, { kind = "spot", asset = "USDT", value = 1 - share } }
    return drift.compute(holdings, { crypto = 0.5, stable = 0.5 }, {}, 0.05)
  end
  local fresh, flagged = drift.newlyOff(at(0.551), {})
  t.eq(fresh, { "crypto", "stable" })
  fresh, flagged = drift.newlyOff(at(0.549), flagged) -- just inside: still flagged
  fresh, flagged = drift.newlyOff(at(0.551), flagged)
  t.eq(fresh, {})
  fresh, flagged = drift.newlyOff(at(0.52), flagged) -- well inside: re-armed
  fresh = drift.newlyOff(at(0.551), flagged)
  t.eq(fresh, { "crypto", "stable" })
end)

return {}
