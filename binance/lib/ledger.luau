--!nonstrict
-- Reads the helper's daily ledger (quantities, not values) and stock marks.
-- Days without a row (machine off) carry the previous row forward. Prices
-- are looked up per day from daily close series. Pure.

local days = require("./days.luau")

local M = {}

M.MAX_DAYS = 400

export type Row = {
  day: string,
  n: number, -- day number
  crypto: { [string]: number },
  stocks: { [string]: number },
}

local function numbers(map): { [string]: number }
  local out = {}
  if type(map) == "table" then
    for k, v in map do
      local n = tonumber(v)
      if n ~= nil and n ~= 0 then
        out[k] = n
      end
    end
  end
  return out
end

-- One row per day from the ledger's first day (or `MAX_DAYS` before
-- `today`) through `today`, carrying quantities forward.
function M.rows(ledger, today: string): { Row }
  if type(ledger) ~= "table" or type(ledger.days) ~= "table" then
    return {}
  end
  local byNumber, first = {}, nil
  for day, row in ledger.days do
    local n = days.number(day)
    if n ~= nil and type(row) == "table" then
      byNumber[n] = row
      first = if first == nil or n < first then n else first
    end
  end
  local last = days.number(today)
  if first == nil or last == nil or first > last then
    return {}
  end
  -- Find the row in force at the window start before trimming.
  local start = math.max(first, last - M.MAX_DAYS + 1)
  local current = nil
  for n = first, start do
    current = byNumber[n] or current
  end
  local rows = {}
  for n = start, last do
    current = byNumber[n] or current
    table.insert(rows, {
      day = days.fromNumber(n),
      n = n,
      crypto = numbers(current.crypto),
      stocks = numbers(current.stocks),
    })
  end
  return rows
end

-- A daily close series: first day number and closes, oldest first.
export type Series = { first: number, closes: { number } }

-- Close on day `n`; after the series ends, the last close. Nil before it.
function M.priceOn(series: Series?, n: number): number?
  if series == nil or #series.closes == 0 or n < series.first then
    return nil
  end
  local i = math.min(n - series.first + 1, #series.closes)
  return series.closes[i]
end

-- Marks of one symbol as a sorted list for lookups.
export type Marks = { days: { number }, mids: { number } }

function M.marks(raw): { [string]: Marks }
  local out = {}
  if type(raw) ~= "table" or type(raw.marks) ~= "table" then
    return out
  end
  for symbol, byDay in raw.marks do
    local list = {}
    for day, mark in byDay do
      local n, mid = days.number(day), type(mark) == "table" and tonumber(mark.mid)
      if n ~= nil and mid then
        table.insert(list, { n, mid })
      end
    end
    table.sort(list, function(a, b)
      return a[1] < b[1]
    end)
    local m = { days = {}, mids = {} }
    for _, pair in list do
      table.insert(m.days, pair[1])
      table.insert(m.mids, pair[2])
    end
    out[symbol] = m
  end
  return out
end

-- Last mark on or before day `n` (`strictlyBefore`: before `n`), or nil.
function M.markOn(m: Marks?, n: number, strictlyBefore: boolean?): number?
  if m == nil then
    return nil
  end
  -- Binary search for the last index whose day qualifies.
  local lo, hi = 1, #m.days
  local found = nil
  while lo <= hi do
    local mid = (lo + hi) // 2
    local d = m.days[mid]
    if d < n or (d == n and not strictlyBefore) then
      found = m.mids[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

return M
