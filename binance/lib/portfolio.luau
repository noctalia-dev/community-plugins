--!nonstrict
-- Portfolio math: holdings, wallets and totals from the helper's files and
-- live prices; value history and range returns from the ledger. Pure: every
-- input arrives as plain data, every output is a report fragment.
--
-- Prices are in USDT (stocks quote in USD, taken at par). `rate` converts to
-- the display currency: 1 for USDT, the EURUSDT price for EUR. Past amounts
-- use that day's EURUSDT close, never today's rate.

local ledger = require("./ledger.luau")

local M = {}

M.STABLE = "USDT"

local function pnl(amount: number, base: number)
  return { pnl = amount, pct = if base > 0 then amount / base else nil }
end

-- prices: { [asset]: { price, open?, spark? } } in USDT.
-- Returns the USDT price of `asset`, falling back to the BTC valuation the
-- wallet call reported when the asset has no USDT pair.
local function cryptoPrice(asset: string, prices, fallbackBtc: number?): number?
  if asset == M.STABLE then
    return 1
  end
  local p = prices[asset]
  if p ~= nil then
    return p.price
  end
  local btc = prices.BTC
  if fallbackBtc ~= nil and btc ~= nil then
    return fallbackBtc * btc.price
  end
  return nil
end

-- Crypto quantities summed across wallets, with each asset's BTC valuation
-- per unit (for assets without a USDT pair).
function M.cryptoTotals(balances)
  local qty, names, btcPerUnit = {}, {}, {}
  for _, wallet in (balances and balances.wallets) or {} do
    for _, a in wallet.assets or {} do
      local total = tonumber(a.total) or 0
      if total > 0 then
        qty[a.asset] = (qty[a.asset] or 0) + total
        names[a.asset] = a.name
        local btc = tonumber(a.btc_value)
        if btc ~= nil and btc > 0 then
          btcPerUnit[a.asset] = btc / total
        end
      end
    end
  end
  return qty, names, btcPerUnit
end

export type Input = {
  balances: any, -- decoded balances.json or nil
  stocks: any, -- decoded stocks.json or nil
  prices: { [string]: any }, -- asset -> { price, open?, spark? }
  prevMarks: { [string]: number }, -- symbol -> last mark before today
  costs: { [string]: any }?, -- crypto-costs.json assets: coin -> { avg_cost, cost, realized_pnl, cost_approx } in USD
  rate: number,
}

-- Holdings (sorted by value), wallets and totals for the report.
function M.build(input: Input)
  local rate = input.rate
  local holdings, wallets = {}, {}
  local cryptoValue, stocksValue, today, partial = 0, 0, 0, false
  -- Value of the holdings in today's change, and of the priced ones left out.
  local based, unbased = 0, 0
  -- Value of assets priced through BTC: history has no daily closes for them.
  local unpaired = 0
  local qty, names, btcPerUnit = M.cryptoTotals(input.balances)
  local unitPrice = {}

  for asset, q in qty do
    local price = cryptoPrice(asset, input.prices, btcPerUnit[asset])
    unitPrice[asset] = price
    local h = { kind = "crypto", asset = asset, name = names[asset], qty = q, value = 0, allocation = 0 }
    if price ~= nil then
      h.price = price / rate
      h.value = q * price / rate
      if asset ~= M.STABLE and input.prices[asset] == nil then
        unpaired += h.value
      end
      local p = input.prices[asset]
      local open = if asset == M.STABLE then 1 elseif p ~= nil then p.open else nil
      if open ~= nil then
        h.today = pnl(q * (price - open) / rate, q * open / rate)
        today += h.today.pnl
        based += h.value
      elseif h.value > 0 then
        partial = true
        unbased += h.value
      end
      if p ~= nil and p.spark ~= nil then
        h.spark = p.spark
      end
    end
    local c = input.costs and input.costs[asset]
    if c ~= nil and tonumber(c.avg_cost) ~= nil then
      -- The basis is per coin; the wallet's quantity is what is valued.
      h.avgCost = (tonumber(c.avg_cost) :: number) / rate
      h.cost = h.avgCost * q
      if price ~= nil then
        h.floating = pnl(h.value - h.cost, h.cost)
      end
      if c.cost_approx == true then
        h.costApprox = true
      end
      if tonumber(c.realized_pnl) ~= nil then
        h.realized = (tonumber(c.realized_pnl) :: number) / rate
      end
    end
    cryptoValue += h.value
    table.insert(holdings, h)
  end

  local stockWallet = { name = "Stocks", value = 0, assets = 0, holdings = {} }
  for _, pos in (input.stocks and input.stocks.positions) or {} do
    local q = tonumber(pos.qty) or 0
    local h = { kind = "stock", asset = pos.symbol, qty = q, value = 0, allocation = 0 }
    local quote = pos.quote
    local mid = quote and tonumber(quote.mid)
    if mid ~= nil then
      h.price = mid / rate
      h.value = q * mid / rate
      h.quoteAt = quote.at_ms
      h.quoteStale = quote.stale == true
      local prev = input.prevMarks[pos.symbol]
      if prev ~= nil then
        h.today = pnl(q * (mid - prev) / rate, q * prev / rate)
        today += h.today.pnl
        based += h.value
      elseif h.value > 0 then
        partial = true
        unbased += h.value
      end
    end
    if pos.cost_known ~= false then
      local cost = (tonumber(pos.cost) or 0) / rate
      h.avgCost = (tonumber(pos.avg_cost) or 0) / rate
      h.cost = cost
      if mid ~= nil then
        h.floating = pnl(h.value - cost, cost)
      end
      if pos.cost_approx == true then
        h.costApprox = true -- the wallet's share count differs from the order replay
      end
    end
    if pos.realized_pnl ~= nil then -- absent when an order has no total
      h.realized = (tonumber(pos.realized_pnl) or 0) / rate
    end
    local tokenized = tonumber(pos.tokenized_shares) or 0
    if tokenized > 0 then
      h.tokenizedQty = tokenized
    end
    stocksValue += h.value
    stockWallet.value += h.value
    stockWallet.assets += 1
    table.insert(stockWallet.holdings, { asset = pos.symbol, qty = q, value = h.value })
    table.insert(holdings, h)
  end

  for _, wallet in (input.balances and input.balances.wallets) or {} do
    local w = { name = wallet.name, value = 0, assets = 0, holdings = {} }
    for _, a in wallet.assets or {} do
      local q = tonumber(a.total) or 0
      local price = unitPrice[a.asset]
      local value = if price ~= nil then q * price / rate else 0
      w.value += value
      w.assets += 1
      table.insert(w.holdings, { asset = a.asset, qty = q, value = value })
    end
    table.sort(w.holdings, function(a, b)
      return a.value > b.value
    end)
    table.insert(wallets, w)
  end
  if input.stocks ~= nil then
    table.insert(wallets, stockWallet)
  end

  local total = cryptoValue + stocksValue
  for _, h in holdings do
    h.allocation = if total > 0 then h.value / total else 0
  end
  table.sort(holdings, function(a, b)
    if a.value ~= b.value then
      return a.value > b.value
    end
    return a.asset < b.asset
  end)

  local totals = {
    value = total,
    crypto = cryptoValue,
    stocks = stocksValue,
    todayPartial = partial,
  }
  -- Today's change covers the holdings with a basis, as a share of their
  -- opening value. When most of the value has no basis yet (stocks before
  -- their first mark) it is left out: a figure for the small rest would
  -- read as the whole portfolio's change.
  if based > 0 and based >= unbased then
    totals.today = pnl(today, based - today)
  elseif not partial then
    totals.today = pnl(0, 0)
  end
  return holdings, wallets, totals, unpaired
end

-- ── History ────────────────────────────────────────────────────────────────

export type HistoryInput = {
  rows: { ledger.Row },
  closes: { [string]: ledger.Series }, -- asset -> daily USDT closes
  marks: { [string]: ledger.Marks },
  costs: { [string]: number }, -- symbol -> avg cost (USD), for unmarked days
  eur: ledger.Series?, -- EURUSDT closes when the display currency is EUR
}

local function rateOn(input: HistoryInput, n: number): number?
  if input.eur == nil then
    return 1
  end
  return ledger.priceOn(input.eur, n)
end

-- USDT value of one ledger row, and whether a stock was valued at cost.
local function rowValue(input: HistoryInput, row: ledger.Row): (number, boolean)
  local value, atCost = 0, false
  for asset, q in row.crypto do
    local price = if asset == M.STABLE then 1 else ledger.priceOn(input.closes[asset], row.n)
    value += q * (price or 0)
  end
  for symbol, q in row.stocks do
    local mid = ledger.markOn(input.marks[symbol], row.n)
    if mid == nil then
      atCost = true
      mid = input.costs[symbol] or 0
    end
    value += q * mid
  end
  return value, atCost
end

-- One point per ledger day in the display currency.
function M.history(input: HistoryInput)
  local points = {}
  for _, row in input.rows do
    local usdt, atCost = rowValue(input, row)
    local rate = rateOn(input, row.n) or 1
    local point = { day = row.day, value = usdt / rate }
    if atCost then
      point.stocksAtCost = true
    end
    table.insert(points, point)
  end
  return points
end

-- Price-only ("market") return between two ledger days: each day's gain on
-- the previous day's quantities, so deposits and trades do not count as
-- performance. Stocks count only between marked days.
function M.marketReturn(input: HistoryInput, fromN: number, toN: number): number
  local total = 0
  for i = 2, #input.rows do
    local prev, row = input.rows[i - 1], input.rows[i]
    if row.n > fromN and row.n <= toN then
      local gain = 0
      for asset, q in prev.crypto do
        if asset ~= M.STABLE then
          local p0 = ledger.priceOn(input.closes[asset], prev.n)
          local p1 = ledger.priceOn(input.closes[asset], row.n)
          if p0 ~= nil and p1 ~= nil then
            gain += q * (p1 - p0)
          end
        end
      end
      for symbol, q in prev.stocks do
        local m0 = ledger.markOn(input.marks[symbol], prev.n)
        local m1 = ledger.markOn(input.marks[symbol], row.n)
        if m0 ~= nil and m1 ~= nil then
          gain += q * (m1 - m0)
        end
      end
      total += gain / (rateOn(input, row.n) or 1)
    end
  end
  return total
end

-- Start day number of a preset ending at `toN`, or nil for unknown presets.
function M.presetStart(preset: string, toN: number, yearStartN: number, firstN: number): number?
  if preset == "7d" then
    return toN - 7
  elseif preset == "30d" then
    return toN - 30
  elseif preset == "ytd" then
    return yearStartN - 1 -- the return since the last close of the previous year
  elseif preset == "all" then
    return firstN
  end
  return nil
end

return M
