--!nonstrict
-- DeepSeek Usage Bar Widget & Background Service Entry

local DEFAULT_REFRESH_MINUTES = 15
local HISTORY_FILE = "balance_history.json"
local MAX_HISTORY_POINTS = 48

local CURRENCY_SYMBOLS = {
  USD = "$",
  CNY = "¥",
  EUR = "€",
  GBP = "£",
  JPY = "¥",
}

local function formatBalance(balance: number?, currency: string?): string
  if balance == nil then
    return "--.--"
  end
  local curr = currency or "USD"
  local symbol = CURRENCY_SYMBOLS[curr]
  if symbol then
    return string.format("%s%.2f", symbol, balance)
  else
    return string.format("%.2f %s", balance, curr)
  end
end

local state = {
  balance = nil :: number?,
  currency = "USD",
  lastUpdated = nil :: string?,
  errorMsg = nil :: string?,
  isFetching = false,
}

-- Load accumulated balance history from disk
local function loadHistory(): { { time: number, balance: number } }
  local dir = noctalia.pluginDataDir()
  if not dir then return {} end
  local path = dir .. "/" .. HISTORY_FILE
  local content = noctalia.readFile(path)
  if not content then return {} end
  local decoded = noctalia.json.decode(content)
  if type(decoded) == "table" then
    return decoded
  end
  return {}
end

-- Save balance sample to persistent history
local function recordBalanceSample(val: number)
  local dir = noctalia.pluginDataDir()
  if not dir then return end
  
  local history = loadHistory()
  local now = os.time()
  
  table.insert(history, { time = now, balance = val })
  
  -- Keep only the latest N samples
  while #history > MAX_HISTORY_POINTS do
    table.remove(history, 1)
  end
  
  local encoded = noctalia.json.encode(history, false)
  if encoded then
    noctalia.writeFile(dir .. "/" .. HISTORY_FILE, encoded)
  end
  
  -- Share history state with panel
  noctalia.state.set("deepseek.history", history)
end

local function renderWidget()
  local apiKey = noctalia.getConfig("api_key") or ""
  
  if apiKey == "" then
    barWidget.setGlyph("wallet")
    barWidget.setText(noctalia.tr("widget.no_key"))
    barWidget.setTooltip({
      { key = noctalia.tr("tooltip.status"), value = noctalia.tr("status.unconfigured") },
      { key = noctalia.tr("tooltip.action"), value = noctalia.tr("tooltip.click_to_configure") },
    })
    return
  end
  
  if state.isFetching and state.balance == nil then
    barWidget.setGlyph("refresh")
    barWidget.setText(noctalia.tr("widget.loading"))
    return
  end
  
  if state.errorMsg and state.balance == nil then
    barWidget.setGlyph("alert-circle")
    barWidget.setText(noctalia.tr("widget.error"))
    barWidget.setTooltip({
      { key = noctalia.tr("tooltip.status"), value = state.errorMsg },
    })
    return
  end
  
  local threshold = tonumber(noctalia.getConfig("low_balance_threshold")) or 2.0
  local balanceStr = formatBalance(state.balance, state.currency)
  
  barWidget.setGlyph("wallet")
  barWidget.setText(balanceStr)
  
  if state.balance ~= nil and state.balance < threshold then
    barWidget.setColor("error")
  else
    barWidget.setColor("primary")
  end
  
  barWidget.setTooltip({
    { key = noctalia.tr("tooltip.balance"), value = balanceStr .. " " .. state.currency },
    { key = noctalia.tr("tooltip.last_updated"), value = state.lastUpdated or noctalia.tr("status.never") },
    { key = noctalia.tr("tooltip.status"), value = state.errorMsg or noctalia.tr("status.ok") },
  })
end

local function fetchSummary()
  local apiKey = noctalia.getConfig("api_key") or ""
  if apiKey == "" then
    state.errorMsg = noctalia.tr("status.unconfigured")
    noctalia.state.set("deepseek.state", state)
    renderWidget()
    return
  end
  
  state.isFetching = true
  renderWidget()
  
  noctalia.http({
    url = "https://api.deepseek.com/user/balance",
    method = "GET",
    headers = {
      "Authorization: Bearer " .. apiKey,
      "Accept: application/json",
    },
  }, function(res)
    state.isFetching = false
    
    if not res.ok then
      state.errorMsg = string.format("HTTP Transport Error (%d)", res.status)
      noctalia.notifyError("DeepSeek Usage", state.errorMsg)
      noctalia.state.set("deepseek.state", state)
      renderWidget()
      return
    end
    
    if res.status ~= 200 then
      state.errorMsg = string.format("API Error (%d)", res.status)
      if res.status == 401 then
        state.errorMsg = noctalia.tr("error.invalid_key")
      end
      noctalia.notifyError("DeepSeek Usage", state.errorMsg)
      noctalia.state.set("deepseek.state", state)
      renderWidget()
      return
    end
    
    local parsed, err = noctalia.json.decode(res.body)
    if not parsed or type(parsed) ~= "table" then
      state.errorMsg = noctalia.tr("error.parse_failed")
      noctalia.state.set("deepseek.state", state)
      renderWidget()
      return
    end
    
    local balanceInfos = parsed.balance_infos
    if balanceInfos and #balanceInfos > 0 then
      local primaryWallet = balanceInfos[1]
      state.currency = primaryWallet.currency or "USD"
      state.balance = tonumber(primaryWallet.total_balance) or 0.0
      state.errorMsg = nil
      state.lastUpdated = noctalia.formatTime("%H:%M:%S", os.time())
      
      recordBalanceSample(state.balance)
      
      -- Check low balance notification
      local threshold = tonumber(noctalia.getConfig("low_balance_threshold")) or 2.0
      if state.balance < threshold then
        noctalia.notify("DeepSeek Balance Warning", string.format("Your DeepSeek balance is low: %s", formatBalance(state.balance, state.currency)))
      end
    else
      state.errorMsg = noctalia.tr("error.no_wallet")
    end
    
    noctalia.state.set("deepseek.state", state)
    renderWidget()
  end)
end

function update()
  local refreshMinutes = tonumber(noctalia.getConfig("refresh_minutes")) or DEFAULT_REFRESH_MINUTES
  noctalia.setUpdateInterval(refreshMinutes * 60 * 1000)
  fetchSummary()
end

function onClick()
  noctalia.togglePanel("coder/deepseek_usage:panel")
end

noctalia.state.watch("deepseek.refresh_requested", function(req)
  if req then
    noctalia.state.set("deepseek.refresh_requested", false)
    fetchSummary()
  end
end)

-- Initial setup
renderWidget()
