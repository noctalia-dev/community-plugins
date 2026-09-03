--!nonstrict
-- BitDjinn Desktop Widget HUD — Persistent desktop crypto ticker & portfolio card.

local format = require("./lib/format.luau")

local market = {}
local summary = {}

local function render()
  local topCoin = { symbol = "BTC", name = "Bitcoin", price = 0, change24h = 0, graphValues = { 0.5, 0.5, 0.5, 0.5 } }
  for _, c in ipairs(market) do
    if c.symbol == (summary.widgetCoin or "BTC") then
      topCoin = c
      break
    end
  end
  if topCoin.price == 0 and #market > 0 then
    topCoin = market[1]
  end

  local changeCol = format.changeColor(topCoin.change24h)
  local changeBg = format.changeBgColor(topCoin.change24h)
  local isPos = (topCoin.change24h or 0) >= 0

  desktopWidget.render(ui.column({
    width = 240,
    gap = 8,
    padding = 12,
    radius = 12,
    fill = "surface_variant/0.3",
    border = "outline/0.2",
  }, {
    -- Header: Coin Symbol, Price & Change Pill
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = format.coinGlyph(topCoin.symbol), size = 18, color = "primary" }),
        ui.label({ text = topCoin.symbol, fontWeight = "bold", fontSize = 14 }),
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
          name = if isPos then "arrow-up-right" else "arrow-down-right",
          size = 11,
          color = changeCol,
        }),
        ui.label({
          text = format.formatChange(topCoin.change24h),
          fontSize = 11,
          fontWeight = "bold",
          color = changeCol,
        }),
      }),
    }),

    -- Big Price
    ui.label({
      text = format.formatPrice(topCoin.price, summary.currency),
      fontSize = 20,
      fontWeight = "heavy",
    }),

    -- Sparkline Trend Graph Container
    ui.row({
      width = 216,
      height = 42,
      radius = 6,
      fill = changeBg,
      align = "center",
      justify = "center",
      padding = 2,
    }, {
      ui.graph({
        values = topCoin.graphValues or { 0.5, 0.5, 0.5, 0.5 },
        color = changeCol,
        lineWidth = 2,
        fillOpacity = 0.35,
        width = 212,
        height = 38,
      }),
    }),

    ui.separator({ thickness = 1, color = "outline/0.15" }),

    -- Portfolio Summary
    ui.row({ align = "center", justify = "space_between" }, {
      ui.column({ gap = 1 }, {
        ui.label({ text = noctalia.tr("wallet.total_valuation"), fontSize = 9, color = "on_surface_variant" }),
        ui.label({
          text = format.formatPrice(summary.totalValuation or 0, summary.currency),
          fontSize = 13,
          fontWeight = "bold",
          color = "primary",
        }),
      }),
      ui.button({
        glyph = "layout-dashboard",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          noctalia.togglePanel("nirvam/bitdjinn:panel")
        end,
      }),
    }),
  }))
end

function update()
  render()
end

noctalia.state.watch("bitdjinn.market", function(val)
  if type(val) == "table" then market = val else market = {} end
  render()
end)

noctalia.state.watch("bitdjinn.summary", function(val)
  if type(val) == "table" then summary = val else summary = {} end
  render()
end)

-- Initial render
market = noctalia.state.get("bitdjinn.market") or {}
summary = noctalia.state.get("bitdjinn.summary") or {}
render()
