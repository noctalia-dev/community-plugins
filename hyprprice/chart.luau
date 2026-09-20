--!nonstrict
-- Dropdown panel opened by clicking the bar widget: current price, 24h
-- change, a 24h sparkline, a manual refresh button, and a search bar to
-- switch the tracked coin at runtime (service.luau defaults it to Monero).

local COINS = require("./lib/coins.luau")

local CURRENCY_SYMBOLS = {
  usd = "$",
  eur = "€",
}

local coinId = noctalia.state.get("coinId") or "monero"
local coinSymbol = noctalia.state.get("coinSymbol") or "XMR"
local coinName = noctalia.state.get("coinName") or "Monero"
local coinLogo = noctalia.state.get("coinLogo") or "assets/logos/xmr.png"
local defaultCoin = noctalia.state.get("defaultCoin") or "monero"
local coinColor = noctalia.state.get("coinColor") or "primary"
local currency = noctalia.state.get("currency") or "usd"
local price = noctalia.state.get("price")
local change = noctalia.state.get("change")
local history = noctalia.state.get("history") or {}
local historyPrices = noctalia.state.get("historyPrices") or {}
local hoverText = nil
local updatedAt = noctalia.state.get("updatedAt")
local hasError = noctalia.state.get("error") or false
local range = noctalia.state.get("range") or "24h"
local RANGE_OPTIONS = { "24h", "7d", "30d" }

local searchQuery = ""
local searchResults = {}
local searchInputGen = 0
local resultsGen = 0

local function formatPrice(value: number, cur: string): string
  local symbol = CURRENCY_SYMBOLS[cur] or (string.upper(cur) .. " ")
  if value >= 1 then
    return string.format("%s%.2f", symbol, value)
  elseif value >= 0.01 then
    return string.format("%s%.4f", symbol, value)
  end
  return string.format("%s%.8f", symbol, value)
end

local function findCoin(id: string)
  for _, c in ipairs(COINS) do
    if c.id == id then
      return c
    end
  end
  return nil
end

local function searchCoins(query: string)
  if query == "" then
    return {}
  end
  local scored = {}
  for _, c in ipairs(COINS) do
    local score = noctalia.fuzzyScore(query, c.symbol .. " " .. c.name)
    if score ~= nil then
      scored[#scored + 1] = { coin = c, score = score }
    end
  end
  table.sort(scored, function(a, b)
    return a.score > b.score
  end)
  local results = {}
  for i = 1, #scored do
    results[i] = scored[i].coin
  end
  return results
end

local function selectCoin(id: string)
  coinId = id
  searchQuery = ""
  searchResults = {}
  searchInputGen += 1
  resultsGen += 1
  noctalia.runAsync({ "noctalia", "msg", "plugin", "humblemane/hyprprice:service", "all", "set_coin", id })
end

local function isStock()
  local coin = findCoin(coinId)
  return coin ~= nil and coin.kind == "stock"
end

local function agoText()
  if updatedAt == nil then
    return "Waiting for first update…"
  end
  local secs = math.max(0, os.time() - updatedAt)
  local ago
  if secs < 60 then
    ago = `{secs}s ago`
  elseif secs < 3600 then
    ago = `{math.floor(secs / 60)}m ago`
  else
    ago = `{math.floor(secs / 3600)}h ago`
  end
  return hasError and `Update failed · last price {ago}` or `Updated {ago}`
end

local function render()
  local changeColor = "on_surface_variant"
  local changeText = "—"
  if type(change) == "number" then
    changeColor = change >= 0 and "#3DDC84" or "#FF5252"
    changeText = string.format("%s%.2f%% · %s", change >= 0 and "▲ " or "▼ ", math.abs(change), range)
  end

  local resultRows = {}
  for _, c in ipairs(searchResults) do
    resultRows[#resultRows + 1] = ui.button({
      key = c.id,
      text = `{c.symbol} · {c.name}`,
      variant = "ghost",
      contentAlign = "start",
      selected = c.id == coinId,
      onClick = function()
        selectCoin(c.id)
        render()
      end,
    })
  end

  local rangeButtons = {}
  for _, r in ipairs(RANGE_OPTIONS) do
    rangeButtons[#rangeButtons + 1] = ui.button({
      key = `range-{r}`,
      text = r,
      variant = "ghost",
      controlSize = "sm",
      selected = r == range,
      onClick = function()
        noctalia.runAsync({ "noctalia", "msg", "plugin", "humblemane/hyprprice:service", "all", "set_range", r })
      end,
    })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 8 }, {
        coinLogo ~= "" and ui.image({ path = coinLogo, width = 24, height = 24, fit = "contain" })
          or ui.label({ text = coinSymbol, fontSize = 12, fontWeight = "bold", color = coinColor }),
        ui.label({ text = coinName, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      }),
      ui.row({ gap = 4 }, {
        ui.button({
          text = string.upper(currency),
          tooltip = "Switch USD / EUR",
          variant = "ghost",
          onClick = "onCurrencyClicked",
        }),
        ui.button({ glyph = "refresh", tooltip = "Refresh now", variant = "ghost", onClick = "onRefreshClicked" }),
        ui.button({ glyph = "close", onClick = "onCloseClicked" }),
      }),
    }),

    ui.column({ gap = 2 }, {
      ui.label({
        text = type(price) == "number" and formatPrice(price, currency) or "…",
        fontSize = 28,
        fontWeight = "bold",
        color = "on_surface",
      }),
      ui.label({ text = changeText, color = changeColor }),
      ui.label({ text = agoText(), color = hasError and "#FF5252" or "on_surface_variant", fontSize = 12 }),
    }),

    ui.graph({
      values = history,
      color = coinColor,
      lineWidth = 2,
      fillOpacity = 0.15,
      height = 90,
      onPointerMove = "onGraphMove",
      onPointerLeave = "onGraphLeave",
    }),

    ui.row({ gap = 4 }, rangeButtons),

    ui.label({
      text = hoverText or `Last {range} · hover the chart to inspect`,
      color = "on_surface_variant",
      fontSize = 12,
    }),

    ui.separator({}),

    ui.input({
      key = `search-{searchInputGen}`,
      placeholder = "Search coins & stocks…",
      onChange = "onSearchChanged",
    }),

    ui.scroll({
      key = `results-{resultsGen}`,
      flexGrow = 1,
      minHeight = 90,
      gap = 2,
      align = "stretch",
    }, resultRows),

    ui.row({ gap = 8 }, {
      ui.button({
        glyph = coinId == defaultCoin and "star-filled" or "star",
        text = coinId == defaultCoin and "Default" or "Set as default",
        variant = "outline",
        selected = coinId == defaultCoin,
        flexGrow = 1,
        onClick = "onSetDefaultClicked",
      }),
      ui.button({
        text = isStock() and "Yahoo Finance" or "Kraken",
        glyph = "external-link",
        variant = "outline",
        flexGrow = 1,
        onClick = "onOpenExchange",
      }),
    }),
  }))
end

noctalia.state.watch("defaultCoin", function(value)
  defaultCoin = value
  render()
end)

noctalia.state.watch("coinId", function(value)
  coinId = value
  render()
end)

noctalia.state.watch("coinSymbol", function(value)
  coinSymbol = value
  render()
end)

noctalia.state.watch("coinName", function(value)
  coinName = value
  render()
end)

noctalia.state.watch("coinColor", function(value)
  coinColor = value
  render()
end)

noctalia.state.watch("coinLogo", function(value)
  coinLogo = value
  render()
end)

noctalia.state.watch("price", function(value)
  price = value
  render()
end)

noctalia.state.watch("change", function(value)
  change = value
  render()
end)

noctalia.state.watch("currency", function(value)
  currency = value
  render()
end)

noctalia.state.watch("range", function(value)
  range = value
  render()
end)

noctalia.state.watch("updatedAt", function(value)
  updatedAt = value
  render()
end)

noctalia.state.watch("error", function(value)
  hasError = value
  render()
end)

noctalia.state.watch("history", function(value)
  history = value
  render()
end)

noctalia.state.watch("historyPrices", function(value)
  historyPrices = value
end)

function onOpen(_context)
  panel.setWantsSecondTicks(true)
  render()
end

function update()
  render()
end

function onCurrencyClicked()
  local target = currency == "usd" and "eur" or "usd"
  noctalia.runAsync({ "noctalia", "msg", "plugin", "humblemane/hyprprice:service", "all", "set_currency", target })
end

function onSearchChanged(value)
  searchQuery = value
  searchResults = searchCoins(value)
  resultsGen += 1
  render()
end

function onGraphMove(normX)
  local n = #historyPrices
  if n == 0 then
    return
  end
  local x = tonumber(normX) or 0
  local index = math.clamp(math.floor(x * (n - 1) + 0.5) + 1, 1, n)
  hoverText = formatPrice(historyPrices[index], currency)
  render()
end

function onGraphLeave()
  hoverText = nil
  render()
end

function onRefreshClicked()
  noctalia.runAsync({ "noctalia", "msg", "plugin", "humblemane/hyprprice:service", "all", "refresh" })
end

function onOpenExchange()
  local coin = findCoin(coinId)
  if coin and coin.kind == "stock" then
    noctalia.runAsync({ "xdg-open", "https://finance.yahoo.com/quote/" .. coin.base })
    return
  end
  local base = coin and coin.base or string.upper(coinId)
  local url = "https://pro.kraken.com/app/trade/" .. string.lower(base) .. "-" .. currency
  noctalia.runAsync({ "xdg-open", url })
end

function onSetDefaultClicked()
  if coinId ~= defaultCoin then
    noctalia.runAsync({ "noctalia", "msg", "plugin", "humblemane/hyprprice:service", "all", "set_default", coinId })
  end
end

function onCloseClicked()
  panel.close()
end
