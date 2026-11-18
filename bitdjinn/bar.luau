--!nonstrict
-- BitDjinn Bar Widget — Status bar crypto ticker & trend pill.

local format = require("./lib/format.luau")

local market = {}
local summary = {}
local activeIndex = 1

local function currentCoin()
  if #market == 0 then
    return { symbol = "BTC", price = 0, change24h = 0, glyph = "currency-bitcoin" }
  end
  if activeIndex > #market then
    activeIndex = 1
  end
  return market[activeIndex]
end

local function updateTooltip()
  local lines = {}
  table.insert(lines, { key = "BitDjinn", value = noctalia.tr("tagline") })
  for _, c in ipairs(market) do
    table.insert(lines, {
      key = c.symbol,
      value = string.format("%s (%s)", format.formatPrice(c.price, summary.currency), format.formatChange(c.change24h)),
    })
  end
  if summary.totalValuation and summary.totalValuation > 0 then
    table.insert(lines, {
      key = noctalia.tr("wallet.total_valuation"),
      value = format.formatPrice(summary.totalValuation, summary.currency),
    })
  end
  barWidget.setTooltip(lines)
end

local function render()
  local coin = currentCoin()
  local priceStr = format.formatPrice(coin.price, summary.currency)
  local changeStr = format.formatChange(coin.change24h)
  local changeCol = format.changeColor(coin.change24h)
  local changeBg = format.changeBgColor(coin.change24h)
  local isPositive = (coin.change24h or 0) >= 0

  barWidget.render(ui.row({
    gap = 6,
    align = "center",
    paddingH = 4,
  }, {
    ui.glyph({
      name = coin.glyph or format.coinGlyph(coin.symbol),
      size = 15,
      color = "primary",
    }),
    ui.label({
      text = coin.symbol,
      fontWeight = "bold",
      fontSize = 12,
    }),
    ui.label({
      text = priceStr,
      fontSize = 12,
    }),
    ui.row({
      gap = 2,
      align = "center",
      paddingH = 5,
      paddingV = 2,
      radius = 4,
      fill = changeBg,
    }, {
      ui.glyph({
        name = if isPositive then "trending-up" else "trending-down",
        size = 11,
        color = changeCol,
      }),
      ui.label({
        text = changeStr,
        fontSize = 11,
        fontWeight = "medium",
        color = changeCol,
      }),
    }),
  }))

  updateTooltip()
end

function onClick()
  noctalia.togglePanel("nirvam/bitdjinn:panel")
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not startsGesture then
    return
  end
  if #market == 0 then
    return
  end
  if steps > 0 then
    activeIndex = activeIndex + 1
    if activeIndex > #market then activeIndex = 1 end
  else
    activeIndex = activeIndex - 1
    if activeIndex < 1 then activeIndex = #market end
  end
  render()
end

noctalia.state.watch("bitdjinn.market", function(val)
  if type(val) == "table" then
    market = val
  else
    market = {}
  end
  render()
end)

noctalia.state.watch("bitdjinn.summary", function(val)
  if type(val) == "table" then
    summary = val
  else
    summary = {}
  end
  render()
end)

function update()
  render()
end

-- Initial render
market = noctalia.state.get("bitdjinn.market") or {}
summary = noctalia.state.get("bitdjinn.summary") or {}
render()
