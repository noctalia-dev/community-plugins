--!nonstrict
-- Public market data from data-api.binance.vision: request URLs, response
-- parsing and error mapping. No keys, no Python. Pure apart from
-- noctalia.json / noctalia.string, which callers may pass in tests.

local M = {}

M.HOST = "https://data-api.binance.vision"
M.STABLE = "USDT" -- every crypto price is fetched as <ASSET>USDT

-- Maps a noctalia.http response onto (data, nil) or (nil, ErrorView fields).
-- Binance error bodies ({code, msg}) keep their code; bodies are otherwise
-- never copied into errors.
function M.interpret(response, decode): (any, any)
  if response == nil or not response.ok then
    return nil, { code = "network_error" }
  end
  local status = response.status or 0
  if status == 418 or status == 429 then
    return nil, { code = "rate_limited", status = status }
  end
  local data = decode(response.body or "")
  if status ~= 200 then
    local err = { code = "api_error", status = status }
    if type(data) == "table" and type(data.code) == "number" then
      err.binanceCode = data.code
      err.msg = if type(data.msg) == "string" then string.sub(data.msg, 1, 200) else nil
    end
    return nil, err
  end
  if type(data) ~= "table" then
    return nil, { code = "bad_response" }
  end
  return data, nil
end

-- Binance -1121 "Invalid symbol": one unknown pair fails a whole batch.
function M.isInvalidSymbol(err): boolean
  return err ~= nil and err.binanceCode == -1121
end

function M.pairOf(asset: string): string
  return asset .. M.STABLE
end

-- `symbols` is a list of pairs; encode as the JSON array Binance expects.
function M.tickersUrl(symbols: { string }, encode, urlEncode): string
  return `{M.HOST}/api/v3/ticker/24hr?symbols={urlEncode(encode(symbols))}`
end

function M.tickerUrl(symbol: string): string
  return `{M.HOST}/api/v3/ticker/24hr?symbol={symbol}`
end

-- Daily klines; `timeZone` ("+2:00") moves the day boundary.
function M.klinesUrl(symbol: string, limit: number, timeZone: string?, urlEncode): string
  local url = `{M.HOST}/api/v3/klines?symbol={symbol}&interval=1d&limit={limit}`
  if timeZone ~= nil then
    url ..= `&timeZone={urlEncode(timeZone)}`
  end
  return url
end

export type Ticker = {
  symbol: string,
  price: number,
  open: number?,
  change24h: number?, -- fraction
  high24h: number?,
  low24h: number?,
}

local function parseTicker(row): Ticker?
  if type(row) ~= "table" or type(row.symbol) ~= "string" then
    return nil
  end
  local price = tonumber(row.lastPrice)
  if price == nil then
    return nil
  end
  local pct = tonumber(row.priceChangePercent)
  return {
    symbol = row.symbol,
    price = price,
    open = tonumber(row.openPrice),
    change24h = if pct ~= nil then pct / 100 else nil,
    high24h = tonumber(row.highPrice),
    low24h = tonumber(row.lowPrice),
  }
end

-- ticker/24hr answers an object for `symbol=` and an array for `symbols=`.
function M.parseTickers(data): { [string]: Ticker }
  local out = {}
  local rows = if data.symbol ~= nil then { data } else data
  for _, row in rows do
    local ticker = parseTicker(row)
    if ticker ~= nil then
      out[ticker.symbol] = ticker
    end
  end
  return out
end

-- Kline rows are [openTime, open, high, low, close, ...] with string prices.
-- Returns the first day number and one close per day (oldest first), plus the
-- open of the last (current) kline.
function M.parseKlines(data, dayOf): (string?, { number }, number?)
  local closes = {}
  local first = nil
  local lastOpen = nil
  for _, row in data do
    if type(row) == "table" and type(row[1]) == "number" then
      first = first or dayOf(row[1])
      table.insert(closes, tonumber(row[5]) or 0)
      lastOpen = tonumber(row[2])
    end
  end
  return first, closes, lastOpen
end

-- Pairs worth trying for a launcher query such as "btc", "BTCUSDT" or
-- "eth/eur".
local QUOTES = { "USDT", "USDC", "FDUSD", "EUR", "BTC" }

function M.candidates(query: string): { string }
  local q = string.upper((string.gsub(query, "[%s/%-_]", "")))
  if not string.match(q, "^[A-Z0-9]+$") or #q < 2 or #q > 20 then
    return {}
  end
  local out, seen = {}, {}
  local function add(symbol)
    if not seen[symbol] then
      seen[symbol] = true
      table.insert(out, symbol)
    end
  end
  for _, quote in QUOTES do
    if #q > #quote and string.sub(q, -#quote) == quote then
      add(q) -- already a pair
    end
  end
  for _, quote in QUOTES do
    if q ~= quote then
      add(q .. quote)
    end
  end
  return out
end

-- "BTCUSDT" -> "BTC", "USDT".
function M.split(symbol: string): (string, string)
  for _, quote in QUOTES do
    if #symbol > #quote and string.sub(symbol, -#quote) == quote then
      return string.sub(symbol, 1, -#quote - 1), quote
    end
  end
  return symbol, ""
end

return M
