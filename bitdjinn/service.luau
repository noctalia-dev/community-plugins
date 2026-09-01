--!nonstrict
-- BitDjinn Headless Service — Background Market & Blockchain Watcher.
-- Features instant 0ms multi-currency conversion cache and multi-chain tracker.

local format = require("./lib/format.luau")

noctalia.setUpdateInterval(1000)

-- ── Constant Definitions ───────────────────────────────────────────────────

local COIN_DEFS = {
  { id = "bitcoin", symbol = "BTC", name = "Bitcoin", glyph = "currency-bitcoin", defaultPrice = 80000 },
  { id = "ethereum", symbol = "ETH", name = "Ethereum", glyph = "currency-ethereum", defaultPrice = 2800 },
  { id = "solana", symbol = "SOL", name = "Solana", glyph = "currency-solana", defaultPrice = 180 },
  { id = "binancecoin", symbol = "BNB", name = "BNB", glyph = "brand-binance", defaultPrice = 600 },
  { id = "ripple", symbol = "XRP", name = "XRP", glyph = "currency-ripple", defaultPrice = 1.8 },
  { id = "dogecoin", symbol = "DOGE", name = "Dogecoin", glyph = "currency-dogecoin", defaultPrice = 0.22 },
  { id = "tether", symbol = "USDT", name = "Tether", glyph = "currency-dollar", defaultPrice = 1.0 },
  { id = "usd-coin", symbol = "USDC", name = "USD Coin", glyph = "currency-dollar", defaultPrice = 1.0 },
}

local MAX_HISTORY_POINTS = 36

-- ── Internal State ─────────────────────────────────────────────────────────

local tickCount = 0
local marketPollInterval = 30
local walletPollInterval = 60
local notifyEnabled = true
local currentCurrency = "usd"
local widgetCoin = "BTC"

-- Live exchange rates against USD (USD = 1.0, USDT = 1.0, USDC = 1.0)
local exchangeRates = {
  usd = 1.0,
  usdt = 1.0,
  usdc = 1.0,
  cny = 7.25,
  eur = 0.92,
}

local priceHistory = {}   -- coin_id -> { number }
local marketData = {}     -- array of coin tables
local watchedWallets = {} -- array of wallet objects
local isUpdating = false
local lastMarketFetchTime = 0
local lastWalletFetchTime = 0

-- ── Persistence ────────────────────────────────────────────────────────────

local function dataFilePath(): string?
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return dir .. "/bitdjinn_state.json"
end

local function saveState()
  local path = dataFilePath()
  if path == nil then
    return
  end
  local payload = {
    currency = currentCurrency,
    notifyEnabled = notifyEnabled,
    exchangeRates = exchangeRates,
    wallets = watchedWallets,
    priceHistory = priceHistory,
  }
  local raw = noctalia.json.encode(payload)
  if raw ~= nil then
    noctalia.writeFile(path, raw)
  end
end

local function loadState()
  for _, c in ipairs(COIN_DEFS) do
    if priceHistory[c.id] == nil then
      priceHistory[c.id] = { c.defaultPrice, c.defaultPrice }
    end
  end

  local path = dataFilePath()
  if path == nil then
    return
  end

  local raw = noctalia.readFile(path)
  if raw ~= nil then
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      if type(decoded.currency) == "string" then
        currentCurrency = decoded.currency
      end
      if type(decoded.notifyEnabled) == "boolean" then
        notifyEnabled = decoded.notifyEnabled
      end
      if type(decoded.exchangeRates) == "table" then
        for k, v in pairs(decoded.exchangeRates) do
          if type(v) == "number" and v > 0 then
            exchangeRates[k] = v
          end
        end
      end
      if type(decoded.wallets) == "table" then
        watchedWallets = decoded.wallets
      end
      if type(decoded.priceHistory) == "table" then
        for coinId, hist in pairs(decoded.priceHistory) do
          if type(hist) == "table" and #hist > 0 then
            priceHistory[coinId] = hist
          end
        end
      end
    end
  end
end

-- ── Price & Market Engine ──────────────────────────────────────────────────

local function getRate(currency: string): number
  local c = string.lower(currency or "usd")
  return exchangeRates[c] or 1.0
end

local function getCoinPrice(coinSymbol: string): number
  local sym = string.upper(coinSymbol or "")
  for _, m in ipairs(marketData) do
    if m.symbol == sym then
      return m.price or 0
    end
  end
  for _, c in ipairs(COIN_DEFS) do
    if c.symbol == sym then
      return c.defaultPrice * getRate(currentCurrency)
    end
  end
  return 0
end

local function recalculatePricesForCurrency()
  local rate = getRate(currentCurrency)
  for _, m in ipairs(marketData) do
    local baseUsd = m.baseUsdPrice or m.price or 0
    m.price = baseUsd * rate
  end
end

local function publishState()
  recalculatePricesForCurrency()

  local totalValuation = 0
  for _, w in ipairs(watchedWallets) do
    local coinPrice = getCoinPrice(w.chain)
    w.value = (w.balance or 0) * coinPrice
    totalValuation = totalValuation + w.value
  end

  local topCoinPrice = getCoinPrice(widgetCoin)
  local topCoinChange = 0
  for _, m in ipairs(marketData) do
    if m.symbol == widgetCoin then
      topCoinChange = m.change24h or 0
      break
    end
  end

  noctalia.state.set("bitdjinn.market", marketData)
  noctalia.state.set("bitdjinn.wallets", watchedWallets)
  noctalia.state.set("bitdjinn.summary", {
    currency = currentCurrency,
    currencySymbol = format.currencySymbol(currentCurrency),
    totalValuation = totalValuation,
    widgetCoin = widgetCoin,
    widgetPrice = topCoinPrice,
    widgetChange = topCoinChange,
    isUpdating = isUpdating,
    lastUpdated = os.date("%H:%M:%S"),
    notifyEnabled = notifyEnabled,
  })
end

local function updateExchangeRates(onDone: () -> ())
  local rateUrl = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd,cny,eur"
  noctalia.http({
    url = rateUrl,
    method = "GET",
    headers = { "Accept: application/json", "User-Agent: Mozilla/5.0 (Noctalia-BitDjinn)" },
  }, function(res)
    if res.ok and res.status == 200 then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and type(data.bitcoin) == "table" then
        local bUsd = tonumber(data.bitcoin.usd) or 0
        local bCny = tonumber(data.bitcoin.cny) or 0
        local bEur = tonumber(data.bitcoin.eur) or 0
        if bUsd > 0 then
          if bCny > 0 then exchangeRates.cny = bCny / bUsd end
          if bEur > 0 then exchangeRates.eur = bEur / bUsd end
          exchangeRates.usd = 1.0
          exchangeRates.usdt = 1.0
          exchangeRates.usdc = 1.0
        end
      end
    end
    onDone()
  end)
end

local function fetchMarketPrices()
  isUpdating = true
  publishState()

  -- Fetch fresh exchange rates and market data in parallel
  updateExchangeRates(function()
    local ids = "bitcoin,ethereum,solana,binancecoin,ripple,dogecoin,tether,usd-coin"
    local url = string.format(
      "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=%s&sparkline=true&price_change_percentage=24h",
      ids
    )

    noctalia.http({
      url = url,
      method = "GET",
      headers = { "Accept: application/json", "User-Agent: Mozilla/5.0 (Noctalia-BitDjinn)" },
    }, function(res)
      isUpdating = false
      if not res.ok or res.status ~= 200 then
        noctalia.log(string.format("BitDjinn: market fetch error status %d, using cached prices", res.status))
        publishState()
        return
      end

      local data, err = noctalia.json.decode(res.body)
      if err ~= nil or type(data) ~= "table" then
        noctalia.log("BitDjinn: json decode error for market data")
        publishState()
        return
      end

      local coinMap = {}
      for _, item in ipairs(data) do
        if type(item) == "table" and item.id ~= nil then
          coinMap[item.id] = item
        end
      end

      local currentRate = getRate(currentCurrency)
      local updatedMarket = {}

      for _, def in ipairs(COIN_DEFS) do
        local item = coinMap[def.id]
        local baseUsdPrice = def.defaultPrice
        local change = 0
        local vol = 0
        local high24 = 0
        local low24 = 0
        local sparkline = nil

        if item ~= nil then
          baseUsdPrice = tonumber(item.current_price) or def.defaultPrice
          change = tonumber(item.price_change_percentage_24h) or 0
          vol = tonumber(item.total_volume) or 0
          high24 = (tonumber(item.high_24h) or 0) * currentRate
          low24 = (tonumber(item.low_24h) or 0) * currentRate

          if type(item.sparkline_in_7d) == "table" and type(item.sparkline_in_7d.price) == "table" then
            local rawPoints = item.sparkline_in_7d.price
            local totalRaw = #rawPoints
            if totalRaw >= 24 then
              local sliced = {}
              local startIdx = math.max(1, totalRaw - 36)
              for i = startIdx, totalRaw do
                table.insert(sliced, rawPoints[i])
              end
              sparkline = sliced
              priceHistory[def.id] = sliced
            end
          end
        end

        if sparkline == nil then
          if priceHistory[def.id] == nil then
            priceHistory[def.id] = {}
          end
          table.insert(priceHistory[def.id], baseUsdPrice)
          if #priceHistory[def.id] > MAX_HISTORY_POINTS then
            table.remove(priceHistory[def.id], 1)
          end
          sparkline = priceHistory[def.id]
        end

        table.insert(updatedMarket, {
          id = def.id,
          symbol = def.symbol,
          name = def.name,
          glyph = def.glyph,
          baseUsdPrice = baseUsdPrice,
          price = baseUsdPrice * currentRate,
          change24h = change,
          vol24h = vol * currentRate,
          high24h = high24,
          low24h = low24,
          graphValues = format.normalizeForGraph(sparkline),
        })
      end

      marketData = updatedMarket
      lastMarketFetchTime = os.time()
      saveState()
      publishState()
    end)
  end)
end

-- ── Blockchain Address Watcher ─────────────────────────────────────────────

local function parseHexNumber(hexStr: string?): number
  if hexStr == nil or hexStr == "" then
    return 0
  end
  local clean = string.gsub(hexStr, "^0x", "")
  local n = tonumber(clean, 16)
  return n or 0
end

local function triggerTxAlert(wallet: any, delta: number, isNewTx: boolean)
  if not notifyEnabled then
    return
  end
  local title = noctalia.tr("notify.tx_title")
  local label = wallet.label or format.shortAddress(wallet.address)
  local coin = wallet.chain

  if delta > 0.000001 then
    local body = string.format(noctalia.tr("notify.balance_increase"), string.format("%.4f", delta), coin, label)
    noctalia.notify(title, body)
  elseif delta < -0.000001 then
    local body = string.format(noctalia.tr("notify.balance_decrease"), string.format("%.4f", -delta), coin, label)
    noctalia.notify(title, body)
  elseif isNewTx then
    local body = string.format(noctalia.tr("notify.tx_detected"), label, coin)
    noctalia.notify(title, body)
  end
end

local function checkBtcAddress(wallet: any, onDone: () -> ())
  local url = "https://mempool.space/api/address/" .. wallet.address
  noctalia.http({ url = url, method = "GET" }, function(res)
    if res.ok and res.status == 200 then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and type(data.chain_stats) == "table" then
        local funded = tonumber(data.chain_stats.funded_txo_sum) or 0
        local spent = tonumber(data.chain_stats.spent_txo_sum) or 0
        local txCount = (tonumber(data.chain_stats.tx_count) or 0)
        local mempoolTxs = 0
        if type(data.mempool_stats) == "table" then
          mempoolTxs = tonumber(data.mempool_stats.tx_count) or 0
        end
        local totalTx = txCount + mempoolTxs
        local newBalance = (funded - spent) / 100000000.0

        if wallet.initialized then
          local delta = newBalance - (wallet.balance or 0)
          local hasNewTx = totalTx > (wallet.txCount or 0)
          if math.abs(delta) > 0.00000001 or hasNewTx then
            triggerTxAlert(wallet, delta, hasNewTx)
          end
        end

        wallet.balance = newBalance
        wallet.txCount = totalTx
        wallet.initialized = true
        wallet.lastChecked = os.date("%H:%M:%S")
      end
    end
    onDone()
  end)
end

local function checkEthAddress(wallet: any, onDone: () -> ())
  local rpcUrl = "https://ethereum-rpc.publicnode.com"
  local balancePayload = noctalia.json.encode({
    jsonrpc = "2.0",
    method = "eth_getBalance",
    params = { wallet.address, "latest" },
    id = 1,
  })

  noctalia.http({
    url = rpcUrl,
    method = "POST",
    headers = { "Content-Type: application/json" },
    body = balancePayload,
  }, function(res)
    if res.ok and res.status == 200 then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and data.result ~= nil then
        local wei = parseHexNumber(data.result)
        local newBalance = wei / 1000000000000000000.0

        local txCountPayload = noctalia.json.encode({
          jsonrpc = "2.0",
          method = "eth_getTransactionCount",
          params = { wallet.address, "latest" },
          id = 2,
        })
        noctalia.http({
          url = rpcUrl,
          method = "POST",
          headers = { "Content-Type: application/json" },
          body = txCountPayload,
        }, function(txRes)
          local txCount = wallet.txCount or 0
          if txRes.ok and txRes.status == 200 then
            local txData = noctalia.json.decode(txRes.body)
            if type(txData) == "table" and txData.result ~= nil then
              txCount = parseHexNumber(txData.result)
            end
          end

          if wallet.initialized then
            local delta = newBalance - (wallet.balance or 0)
            local hasNewTx = txCount > (wallet.txCount or 0)
            if math.abs(delta) > 0.00000001 or hasNewTx then
              triggerTxAlert(wallet, delta, hasNewTx)
            end
          end

          wallet.balance = newBalance
          wallet.txCount = txCount
          wallet.initialized = true
          wallet.lastChecked = os.date("%H:%M:%S")
          onDone()
        end)
        return
      end
    end
    onDone()
  end)
end

local function checkSolAddress(wallet: any, onDone: () -> ())
  local rpcUrl = "https://api.mainnet-beta.solana.com"
  local payload = noctalia.json.encode({
    jsonrpc = "2.0",
    method = "getBalance",
    params = { wallet.address },
    id = 1,
  })

  noctalia.http({
    url = rpcUrl,
    method = "POST",
    headers = { "Content-Type: application/json" },
    body = payload,
  }, function(res)
    if res.ok and res.status == 200 then
      local data = noctalia.json.decode(res.body)
      if type(data) == "table" and type(data.result) == "table" then
        local lamports = tonumber(data.result.value) or 0
        local newBalance = lamports / 1000000000.0

        if wallet.initialized then
          local delta = newBalance - (wallet.balance or 0)
          if math.abs(delta) > 0.00000001 then
            triggerTxAlert(wallet, delta, false)
          end
        end

        wallet.balance = newBalance
        wallet.initialized = true
        wallet.lastChecked = os.date("%H:%M:%S")
      end
    end
    onDone()
  end)
end

local function fetchWalletBalances()
  if #watchedWallets == 0 then
    publishState()
    return
  end

  local remaining = #watchedWallets
  local function onDoneOne()
    remaining = remaining - 1
    if remaining <= 0 then
      lastWalletFetchTime = os.time()
      saveState()
      publishState()
    end
  end

  for _, w in ipairs(watchedWallets) do
    if w.chain == "BTC" then
      checkBtcAddress(w, onDoneOne)
    elseif w.chain == "ETH" then
      checkEthAddress(w, onDoneOne)
    elseif w.chain == "SOL" then
      checkSolAddress(w, onDoneOne)
    else
      onDoneOne()
    end
  end
end

-- ── Wallet Management Actions ──────────────────────────────────────────────

local function addWallet(addr: string, label: string): (boolean, string?)
  local clean = noctalia.string.trim(addr or "")
  if clean == "" then
    return false, "invalid_address"
  end

  local chain = format.detectChain(clean)
  if chain == "unknown" then
    return false, "invalid_address"
  end

  for _, w in ipairs(watchedWallets) do
    if string.lower(w.address) == string.lower(clean) then
      return false, "duplicate_address"
    end
  end

  local cleanLabel = noctalia.string.trim(label or "")
  if cleanLabel == "" then
    cleanLabel = chain .. " (" .. format.shortAddress(clean) .. ")"
  end

  local newWallet = {
    id = "w_" .. tostring(os.time()) .. "_" .. tostring(#watchedWallets + 1),
    address = clean,
    chain = chain,
    label = cleanLabel,
    balance = 0,
    value = 0,
    txCount = 0,
    initialized = false,
    lastChecked = "--",
  }

  table.insert(watchedWallets, newWallet)
  saveState()
  publishState()

  if chain == "BTC" then
    checkBtcAddress(newWallet, function() saveState() publishState() end)
  elseif chain == "ETH" then
    checkEthAddress(newWallet, function() saveState() publishState() end)
  elseif chain == "SOL" then
    checkSolAddress(newWallet, function() saveState() publishState() end)
  end

  return true, nil
end

local function removeWallet(addrOrId: string): boolean
  local target = noctalia.string.trim(addrOrId or "")
  local idx = nil
  for i, w in ipairs(watchedWallets) do
    if w.id == target or string.lower(w.address) == string.lower(target) then
      idx = i
      break
    end
  end
  if idx ~= nil then
    table.remove(watchedWallets, idx)
    saveState()
    publishState()
    return true
  end
  return false
end

-- ── Command & State Watching ───────────────────────────────────────────────

noctalia.state.watch("bitdjinn.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local op = cmd.op
  if op == "add_wallet" then
    local ok, reason = addWallet(cmd.address, cmd.label)
    if not ok and reason ~= nil then
      noctalia.notify(noctalia.tr("title"), noctalia.tr("wallet." .. reason))
    end
  elseif op == "remove_wallet" then
    removeWallet(cmd.address or cmd.id)
  elseif op == "refresh" then
    fetchMarketPrices()
    fetchWalletBalances()
  elseif op == "set_currency" then
    if type(cmd.currency) == "string" then
      currentCurrency = string.lower(cmd.currency)
      saveState()
      -- Instantaneous local currency conversion (0ms)
      publishState()
    end
  elseif op == "toggle_notify" then
    notifyEnabled = not notifyEnabled
    saveState()
    publishState()
  end
  noctalia.state.set("bitdjinn.cmd", nil)
end)

function onConfigChanged()
  local confCur = noctalia.getConfig("currency")
  if confCur ~= nil and confCur ~= "" then
    currentCurrency = string.lower(confCur)
  end
  local confInt = tonumber(noctalia.getConfig("interval"))
  if confInt ~= nil and confInt >= 10 then
    marketPollInterval = confInt
  end
  local confWallInt = tonumber(noctalia.getConfig("wallet_interval"))
  if confWallInt ~= nil and confWallInt >= 15 then
    walletPollInterval = confWallInt
  end
  local confNotify = noctalia.getConfig("notify_tx")
  if type(confNotify) == "boolean" then
    notifyEnabled = confNotify
  end
  local confCoin = noctalia.getConfig("widget_coin")
  if confCoin ~= nil and confCoin ~= "" then
    widgetCoin = string.upper(confCoin)
  end

  publishState()
  fetchMarketPrices()
  fetchWalletBalances()
end

function onIpc(event, payload)
  if event == "refresh" then
    fetchMarketPrices()
    fetchWalletBalances()
    noctalia.notify(noctalia.tr("title"), noctalia.tr("ui.refresh"))
  elseif event == "add" then
    local addr, label = string.match(payload or "", "^(%S+)%s*(.*)$")
    if addr ~= nil then
      local ok, reason = addWallet(addr, label)
      if ok then
        noctalia.notify(noctalia.tr("title"), "Wallet added: " .. addr)
      else
        noctalia.notify(noctalia.tr("title"), "Failed: " .. (reason or "invalid"))
      end
    end
  elseif event == "remove" then
    if removeWallet(payload or "") then
      noctalia.notify(noctalia.tr("title"), "Wallet removed: " .. (payload or ""))
    end
  elseif event == "toggle_notify" then
    notifyEnabled = not notifyEnabled
    saveState()
    publishState()
    noctalia.notify(noctalia.tr("title"), if notifyEnabled then noctalia.tr("shortcut.label_on") else noctalia.tr("shortcut.label_off"))
  end
end

-- ── Main Loop ──────────────────────────────────────────────────────────────

function update()
  tickCount = tickCount + 1

  if tickCount % marketPollInterval == 0 or os.time() - lastMarketFetchTime > marketPollInterval then
    fetchMarketPrices()
  end

  if tickCount % walletPollInterval == 0 or os.time() - lastWalletFetchTime > walletPollInterval then
    fetchWalletBalances()
  end
end

-- ── Boot Initialization ────────────────────────────────────────────────────

loadState()
onConfigChanged()
fetchMarketPrices()
fetchWalletBalances()
