--!nonstrict
-- Headless service: polls Kraken (crypto) or Yahoo Finance (stocks) for the
-- selected asset's price and history, computes the change, and
-- publishes it all to the plugin's shared state. bar.luau and chart.luau
-- watch it. The active coin defaults to Monero but can be switched at
-- runtime from the chart panel's search bar (onIpc "set_coin"), independent
-- of the persisted `coin` setting.
--
-- Kraken, not CoinGecko: api.coingecko.com's HTTPS endpoint is silently
-- blackholed (TLS-level, no response) from this host's HTTP client, while
-- plain HTTP to it and HTTPS to Kraken both work, so Kraken is the data
-- source here.

local COINS = require("./lib/coins.luau")

local function findCoin(id)
  for _, c in ipairs(COINS) do
    if c.id == id then
      return c
    end
  end
  return nil
end

local currency = noctalia.getConfig("currency") or "usd"
local intervalSeconds = noctalia.getConfig("interval") or 30
-- The default asset: one saved from the panel's "Set as default" button (kept
-- in the plugin data dir, since plugins can't write settings) wins over the
-- `coin` setting.
local function savedDefaultPath()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/default.json") or nil
end

local function loadDefaultCoin()
  local path = savedDefaultPath()
  local raw = path and noctalia.readFile(path)
  local decoded = raw and noctalia.json.decode(raw)
  if decoded and decoded.coin and findCoin(decoded.coin) then
    return decoded.coin
  end
  return noctalia.getConfig("coin") or "monero"
end

local defaultCoin = loadDefaultCoin()
local coinId = defaultCoin

local REQUEST_HEADERS = { "Accept: application/json", "User-Agent: noctalia-monero-widget/1.0" }
local MAX_HISTORY_POINTS = 60

-- Kraken OHLC intervals (minutes) are fixed: 1, 5, 15, 30, 60, 240, 1440, ...
local RANGES = {
  ["24h"] = { interval = 30, seconds = 86400 },
  ["7d"] = { interval = 240, seconds = 604800 },
  ["30d"] = { interval = 240, seconds = 2592000 },
}
local range = "24h"

local lastPrice = nil

local function publishCoinMeta()
  local coin = findCoin(coinId) or { id = coinId, symbol = string.upper(coinId), name = coinId }
  noctalia.state.set("coinId", coin.id)
  noctalia.state.set("defaultCoin", defaultCoin)
  noctalia.state.set("coinSymbol", coin.symbol)
  noctalia.state.set("coinName", coin.name)
  -- Not every asset has a logo file; the bar and panel show the ticker instead.
  local logo = "assets/logos/" .. string.lower(coin.symbol) .. ".png"
  noctalia.state.set("coinLogo", noctalia.fileExists(logo) and logo or "")
  noctalia.state.set("coinColor", coin.color or "primary")
end

-- Kraken's ticker keys don't match the requested pair string (legacy X/Z
-- prefixes for some assets, e.g. XMRUSD -> XXMRZUSD), so grab whichever
-- single entry the result table holds rather than guessing the key.
local function firstValue(t)
  for _, v in pairs(t) do
    return v
  end
  return nil
end

local function krakenPair(coin)
  return coin.base .. string.upper(currency)
end

-- Downsample closes (oldest first) to <= MAX_HISTORY_POINTS, publish them for
-- the chart, and publish the change % against `baseline` (defaults to the
-- first close).
local function publishSeries(closes, baseline)
  local step = math.max(1, math.ceil(#closes / MAX_HISTORY_POINTS))
  local raw = {}
  for i = #closes, 1, -step do
    raw[#raw + 1] = closes[i]
  end
  for i = 1, math.floor(#raw / 2) do
    raw[i], raw[#raw - i + 1] = raw[#raw - i + 1], raw[i]
  end

  local lo, hi = raw[1], raw[1]
  for _, v in ipairs(raw) do
    if v < lo then
      lo = v
    end
    if v > hi then
      hi = v
    end
  end

  local span = hi - lo
  local normalized = {}
  for i, v in ipairs(raw) do
    normalized[i] = span > 0 and (v - lo) / span or 0.5
  end

  noctalia.state.set("history", normalized)
  noctalia.state.set("historyPrices", raw)

  baseline = baseline or raw[1]
  if lastPrice and baseline and baseline > 0 then
    noctalia.state.set("change", (lastPrice - baseline) / baseline * 100)
  end
end

local function fetchPrice()
  local coin = findCoin(coinId)
  if not coin then
    noctalia.state.set("error", true)
    return
  end

  local requestCoin = coinId
  local requestCurrency = currency
  local pair = krakenPair(coin)
  local url = "https://api.kraken.com/0/public/Ticker?pair=" .. noctalia.string.urlEncode(pair)

  noctalia.http({ url = url, headers = REQUEST_HEADERS }, function(res)
    if requestCoin ~= coinId or requestCurrency ~= currency then
      return -- superseded by a newer coin or currency switch
    end

    if not res.ok then
      noctalia.log(`humblemane/hyprprice: price request failed status={res.status}`)
      noctalia.state.set("error", true)
      return
    end

    local decoded = noctalia.json.decode(res.body)
    if not decoded or (decoded.error and #decoded.error > 0) then
      noctalia.log(`humblemane/hyprprice: price error for {pair}: {res.body}`)
      noctalia.state.set("error", true)
      return
    end

    local ticker = decoded.result and firstValue(decoded.result)
    local price = ticker and ticker.c and tonumber(ticker.c[1])

    if not price then
      noctalia.log(`humblemane/hyprprice: unexpected ticker payload: {res.body}`)
      noctalia.state.set("error", true)
      return
    end

    lastPrice = price
    noctalia.state.set("error", false)
    noctalia.state.set("currency", requestCurrency)
    noctalia.state.set("price", price)
    noctalia.state.set("updatedAt", os.time())
  end)
end

local function fetchHistory()
  local coin = findCoin(coinId)
  if not coin then
    return
  end

  local requestCoin = coinId
  local requestRange = range
  local requestCurrency = currency
  local pair = krakenPair(coin)
  local since = os.time() - RANGES[requestRange].seconds
  local url = "https://api.kraken.com/0/public/OHLC?pair="
    .. noctalia.string.urlEncode(pair)
    .. "&interval=" .. tostring(RANGES[requestRange].interval) .. "&since="
    .. tostring(since)

  noctalia.http({ url = url, headers = REQUEST_HEADERS }, function(res)
    if requestCoin ~= coinId or requestRange ~= range or requestCurrency ~= currency then
      return -- superseded by a newer coin or range switch
    end

    if not res.ok then
      noctalia.log(`humblemane/hyprprice: history request failed status={res.status}`)
      return
    end

    local decoded = noctalia.json.decode(res.body)
    if not decoded or (decoded.error and #decoded.error > 0) then
      noctalia.log(`humblemane/hyprprice: history error for {pair}: {res.body}`)
      return
    end

    local candles = nil
    if decoded.result then
      for key, value in pairs(decoded.result) do
        if key ~= "last" then
          candles = value
          break
        end
      end
    end

    if not candles or #candles == 0 then
      noctalia.log(`humblemane/hyprprice: unexpected OHLC payload: {res.body}`)
      return
    end

    local closes = {}
    for i = 1, #candles do
      closes[i] = tonumber(candles[i][5]) -- close price
    end
    publishSeries(closes)
  end)
end

-- Stocks: Yahoo Finance's chart endpoint returns price, previous close and
-- history in one call, quoted in USD for the US tickers in the list.
local YAHOO_RANGES = {
  ["24h"] = { range = "1d", interval = "5m" },
  ["7d"] = { range = "5d", interval = "30m" },
  ["30d"] = { range = "1mo", interval = "1d" },
}
local YAHOO_HEADERS = { "Accept: application/json", "User-Agent: Mozilla/5.0 (X11; Linux x86_64) HyprPrice/1.0" }

local function doFetchStock(mult, quoteCurrency)
  local coin = findCoin(coinId)
  if not coin then
    noctalia.state.set("error", true)
    return
  end

  local requestCoin = coinId
  local requestRange = range
  local requestCurrency = currency
  local r = YAHOO_RANGES[requestRange]
  local url = "https://query1.finance.yahoo.com/v8/finance/chart/"
    .. noctalia.string.urlEncode(coin.base)
    .. "?range=" .. r.range .. "&interval=" .. r.interval

  noctalia.http({ url = url, headers = YAHOO_HEADERS }, function(res)
    if requestCoin ~= coinId or requestRange ~= range or requestCurrency ~= currency then
      return -- superseded by a newer coin, range or currency switch
    end

    if not res.ok then
      noctalia.log(`humblemane/hyprprice: stock request failed status={res.status}`)
      noctalia.state.set("error", true)
      return
    end

    local decoded = noctalia.json.decode(res.body)
    local result = decoded and decoded.chart and decoded.chart.result and decoded.chart.result[1]
    local meta = result and result.meta
    local price = meta and tonumber(meta.regularMarketPrice)

    if not price then
      noctalia.log(`humblemane/hyprprice: unexpected stock payload: {string.sub(res.body, 1, 300)}`)
      noctalia.state.set("error", true)
      return
    end

    price = price * mult
    lastPrice = price
    noctalia.state.set("error", false)
    noctalia.state.set("currency", quoteCurrency)
    noctalia.state.set("price", price)
    noctalia.state.set("updatedAt", tonumber(meta.regularMarketTime) or os.time())

    local quote = result.indicators and result.indicators.quote and result.indicators.quote[1]
    local closes = {}
    for _, v in ipairs(quote and quote.close or {}) do
      if type(v) == "number" then
        closes[#closes + 1] = v * mult
      end
    end
    if #closes > 1 then
      publishSeries(closes, meta.chartPreviousClose and tonumber(meta.chartPreviousClose) * mult or nil)
    end
  end)
end

-- Yahoo quotes stocks in USD. For EUR, convert with Kraken's EUR/USD rate,
-- cached for 10 minutes; if the rate can't be fetched, fall back to USD.
local usdToEur = nil
local fxFetchedAt = 0

local function fetchStock()
  if currency ~= "eur" or (usdToEur and os.time() - fxFetchedAt < 600) then
    doFetchStock(currency == "eur" and usdToEur or 1, currency)
    return
  end

  local requestCurrency = currency
  noctalia.http({ url = "https://api.kraken.com/0/public/Ticker?pair=EURUSD", headers = REQUEST_HEADERS }, function(res)
    if requestCurrency ~= currency then
      return
    end
    local decoded = res.ok and noctalia.json.decode(res.body)
    local ticker = decoded and decoded.result and firstValue(decoded.result)
    local usdPerEur = ticker and ticker.c and tonumber(ticker.c[1])
    if usdPerEur and usdPerEur > 0 then
      usdToEur = 1 / usdPerEur
      fxFetchedAt = os.time()
      doFetchStock(usdToEur, "eur")
    else
      noctalia.log("humblemane/hyprprice: EUR/USD rate unavailable, showing USD")
      doFetchStock(1, "usd")
    end
  end)
end

local function fetchAll()
  publishCoinMeta()
  noctalia.state.set("range", range)
  local coin = findCoin(coinId)
  if coin and coin.kind == "stock" then
    fetchStock()
  else
    fetchPrice()
    fetchHistory()
  end
end

noctalia.setUpdateInterval(intervalSeconds * 1000)
fetchAll()

function update()
  fetchAll()
end

function onConfigChanged()
  currency = noctalia.getConfig("currency") or "usd"
  intervalSeconds = noctalia.getConfig("interval") or 30
  defaultCoin = loadDefaultCoin()
  coinId = defaultCoin
  noctalia.setUpdateInterval(intervalSeconds * 1000)
  fetchAll()
end

function onIpc(event, payload)
  if event == "refresh" then
    fetchAll()
  elseif event == "set_currency" and (payload == "usd" or payload == "eur") then
    currency = payload
    lastPrice = nil
    fetchAll()
  elseif event == "set_range" and RANGES[payload] then
    range = payload
    noctalia.state.set("range", range)
    local coin = findCoin(coinId)
    if coin and coin.kind == "stock" then
      fetchStock()
    else
      fetchHistory()
    end
  elseif event == "set_default" and payload and findCoin(payload) then
    local path = savedDefaultPath()
    if path then
      noctalia.writeFile(path, noctalia.json.encode({ coin = payload }))
    end
    defaultCoin = payload
    noctalia.state.set("defaultCoin", defaultCoin)
  elseif event == "set_coin" and payload and payload ~= "" then
    coinId = payload
    -- Drop the previous asset's numbers so the UI shows a loading state
    -- instead of the old price under the new asset's name.
    lastPrice = nil
    noctalia.state.set("price", false)
    noctalia.state.set("change", false)
    noctalia.state.set("history", {})
    noctalia.state.set("historyPrices", {})
    fetchAll()
  end
end
