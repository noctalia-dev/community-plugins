--!nonstrict
-- Bar widget: renders the Monero price published by service.luau.
-- Click opens the chart panel (chart.luau).

local CURRENCY_SYMBOLS = {
  usd = "$",
  eur = "€",
}

local showChange = noctalia.getConfig("show_change")
if showChange == nil then
  showChange = true
end

local price = noctalia.state.get("price")
local change = noctalia.state.get("change")
local currency = noctalia.state.get("currency") or "usd"
local hasError = noctalia.state.get("error") or false
local coinSymbol = noctalia.state.get("coinSymbol") or "XMR"
local coinLogo = noctalia.state.get("coinLogo") or "assets/logos/xmr.png"

local function formatPrice(value: number, cur: string): string
  local symbol = CURRENCY_SYMBOLS[cur] or (string.upper(cur) .. " ")
  if value >= 1 then
    return string.format("%s%.2f", symbol, value)
  elseif value >= 0.01 then
    return string.format("%s%.4f", symbol, value)
  end
  return string.format("%s%.8f", symbol, value)
end

local function render()
  local label
  local changeLabel, changeColor
  if type(price) ~= "number" then
    label = hasError and "--" or "…"
    barWidget.setTooltip(hasError and "Price unavailable" or "Fetching price…")
  else
    label = formatPrice(price, currency)
    if showChange and type(change) == "number" then
      local arrow = change >= 0 and "▲" or "▼"
      changeLabel = string.format("%s%.1f%%", arrow, math.abs(change))
      changeColor = change >= 0 and "#3DDC84" or "#FF5252"
    end
    barWidget.setTooltip(`{coinSymbol} · click for chart`)
  end

  local children = {}
  if coinLogo ~= "" then
    children[#children + 1] = ui.image({ path = coinLogo, width = 18, height = 18, fit = "contain" })
  else
    label = `{coinSymbol} {label}`
  end
  children[#children + 1] = ui.label({ text = label })
  if changeLabel then
    children[#children + 1] = ui.label({ text = changeLabel, color = changeColor })
  end

  barWidget.render(ui.row({ gap = 6, align = "center" }, children))
end

render()

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

noctalia.state.watch("error", function(value)
  hasError = value
  render()
end)

noctalia.state.watch("coinSymbol", function(value)
  coinSymbol = value
  render()
end)

noctalia.state.watch("coinLogo", function(value)
  coinLogo = value
  render()
end)

function onClick()
  noctalia.togglePanel("humblemane/hyprprice:chart")
end
