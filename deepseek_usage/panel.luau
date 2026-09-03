--!nonstrict
-- DeepSeek Usage Panel Entry — Graphical Balance & Top-Up Dashboard

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

local history = {}

function openTopUpPage()
  noctalia.runAsync("xdg-open https://platform.deepseek.com/top_up")
end

function triggerRefresh()
  noctalia.state.set("deepseek.refresh_requested", true)
end

function onClosePanel()
  panel.close()
end

function onOpenSettings()
  noctalia.openSettings()
end

local function buildGraphValues(): ({ number }, number, number)
  if #history == 0 then
    return { 0 }, 0, 0
  end
  
  local minVal = history[1].balance
  local maxVal = history[1].balance
  
  for _, pt in ipairs(history) do
    if pt.balance < minVal then minVal = pt.balance end
    if pt.balance > maxVal then maxVal = pt.balance end
  end
  
  local range = maxVal - minVal
  local values = {}
  for _, pt in ipairs(history) do
    table.insert(values, range > 0 and (pt.balance - minVal) / range or 0.5)
  end
  
  return values, minVal, maxVal
end

local function renderGraphSection(values: { number }, minVal: number, maxVal: number)
  -- graph props unverified — adjust after hot-reload test
  local graphOk, graphNode = pcall(function()
    return ui.graph({
      values = values,
      height = 64,
      color = "primary",
    })
  end)

  local graphElement
  if graphOk and type(graphNode) == "table" then
    graphElement = graphNode
  else
    graphElement = ui.label({
      text = string.format("History (%d data points)", #history),
      fontSize = 11,
      color = "on_surface_variant",
    })
  end

  return ui.column({ gap = 6 }, {
    ui.row({ justify = "space_between", align = "center" }, {
      ui.label({ text = noctalia.tr("panel.history_title"), fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
      ui.label({ text = string.format("%d samples", #history), fontSize = 10, color = "on_surface_variant" }),
    }),
    ui.column({
      fill = "surface_variant/0.2",
      radius = 8,
      padding = 8,
      gap = 4,
    }, {
      graphElement,
      ui.row({ justify = "space_between" }, {
        ui.label({ text = string.format("Min: %s", formatBalance(minVal, state.currency)), fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = string.format("Max: %s", formatBalance(maxVal, state.currency)), fontSize = 10, color = "on_surface_variant" }),
      }),
    }),
  })
end

local function render()
  local apiKey = noctalia.getConfig("api_key") or ""
  local isUnconfigured = apiKey == ""
  
  local values, minVal, maxVal = buildGraphValues()
  local balanceDisplay = formatBalance(state.balance, state.currency)
  
  -- Header Row
  local headerRow = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "wallet", size = 18, color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    }),
    ui.row({ gap = 4, align = "center" }, {
      ui.button({ glyph = "refresh", variant = "ghost", onClick = "triggerRefresh", tooltip = noctalia.tr("panel.refresh_tooltip") }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onClosePanel" }),
    }),
  })

  -- Scrollable Body Items
  local bodyItems = {}

  -- Unconfigured State Banner
  if isUnconfigured then
    table.insert(bodyItems, ui.column({
      fill = "surface_variant/0.5",
      radius = 8,
      padding = 12,
      gap = 8,
      align = "stretch",
    }, {
      ui.label({ text = noctalia.tr("panel.unconfigured_title"), fontWeight = "bold", color = "error" }),
      ui.label({ text = noctalia.tr("panel.unconfigured_desc"), fontSize = 12, color = "on_surface_variant" }),
      ui.button({
        text = noctalia.tr("panel.open_settings"),
        variant = "primary",
        onClick = "onOpenSettings",
      }),
    }))
  end

  -- Error Banner
  if not isUnconfigured and state.errorMsg ~= nil then
    table.insert(bodyItems, ui.row({
      fill = "error/0.15",
      radius = 8,
      padding = 10,
      gap = 8,
      align = "center",
    }, {
      ui.glyph({ name = "alert-circle", color = "error", size = 16 }),
      ui.label({ text = state.errorMsg, color = "error", fontSize = 12, flexGrow = 1 }),
    }))
  end

  -- Hero Balance Card
  if not isUnconfigured then
    table.insert(bodyItems, ui.column({
      fill = "surface_variant/0.35",
      radius = 12,
      padding = 16,
      align = "center",
      gap = 6,
    }, {
      ui.label({ text = noctalia.tr("panel.current_balance"), fontSize = 12, color = "on_surface_variant" }),
      ui.label({ text = balanceDisplay .. " " .. state.currency, fontSize = 28, fontWeight = "bold", color = "primary" }),
      ui.label({ text = noctalia.tr("panel.wallet_info"), fontSize = 11, color = "on_surface_variant" }),
      ui.spacer({ height = 4 }),
      ui.button({
        text = "  " .. noctalia.tr("panel.add_credits") .. "  ",
        glyph = "external-link",
        variant = "primary",
        onClick = "openTopUpPage",
        tooltip = noctalia.tr("panel.add_credits_tooltip"),
      }),
    }))

    -- Graph / Trend Section
    table.insert(bodyItems, renderGraphSection(values, minVal, maxVal))
  end

  -- Footer Status Info
  local footerRow = ui.row({ justify = "space_between", align = "center" }, {
    ui.label({
      text = state.lastUpdated and (noctalia.tr("panel.updated_at") .. ": " .. state.lastUpdated) or "",
      fontSize = 10,
      color = "on_surface_variant",
    }),
    ui.button({
      text = noctalia.tr("panel.settings_btn"),
      variant = "ghost",
      onClick = "onOpenSettings",
    }),
  })

  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 12 }, {
    headerRow,
    ui.separator({}),
    ui.scroll({ flexGrow = 1, gap = 10 }, bodyItems),
    footerRow,
  }))
end

function onOpen(_context)
  state = noctalia.state.get("deepseek.state") or state
  history = noctalia.state.get("deepseek.history") or {}
  render()
end

noctalia.state.watch("deepseek.state", function(newState)
  if type(newState) == "table" then
    state = newState
    render()
  end
end)

noctalia.state.watch("deepseek.history", function(newHistory)
  if type(newHistory) == "table" then
    history = newHistory
    render()
  end
end)
