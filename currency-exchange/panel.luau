--!nonstrict
local CODES = {
  "AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD",
  "HUF", "IDR", "ILS", "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK",
  "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB", "TRY", "USD", "ZAR",
}

local function indexOf(code)
  for i, c in ipairs(CODES) do
    if c == code then return i end
  end
  return 1
end

local rates = noctalia.state.get("rates")
local amountText = "1"
local fromIdx = indexOf(string.upper(noctalia.getConfig("source_currency") or "USD"))
local toIdx = indexOf(string.upper(noctalia.getConfig("target_currency") or "EUR"))

local function fmt(n)
  if n >= 1000 then
    local s = string.format("%.2f", n)
    local int, frac = s:match("^(%d+)(%..*)$")
    local grouped = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return grouped .. frac
  end
  if n >= 1 then return string.format("%.2f", n) end
  return string.format("%.4f", n)
end

local render

local function onAmount(value)
  amountText = value
  render()
end

local function onFrom(index)
  fromIdx = (tonumber(index) or 0) + 1
  render()
end

local function onTo(index)
  toIdx = (tonumber(index) or 0) + 1
  render()
end

local function swap()
  fromIdx, toIdx = toIdx, fromIdx
  render()
end

local function copyResult()
  local from, to = CODES[fromIdx], CODES[toIdx]
  local amount = tonumber((amountText:gsub(",", "."))) or 0
  if rates ~= nil and rates[from] ~= nil and rates[to] ~= nil then
    noctalia.copyToClipboard(string.format("%.2f", amount / rates[from] * rates[to]), "text/plain")
  end
end

render = function()
  local from, to = CODES[fromIdx], CODES[toIdx]
  local amount = tonumber((amountText:gsub(",", "."))) or 0
  local resultText, rateText = "…", ""
  if rates ~= nil and rates[from] ~= nil and rates[to] ~= nil then
    local rate = rates[to] / rates[from]
    resultText = fmt(amount * rate) .. " " .. to
    rateText = "1 " .. from .. " = " .. fmt(rate) .. " " .. to
  end

  panel.render(ui.column({ gap = 12, padding = 16 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "currency-dollar", size = 20, color = "primary" }),
      ui.label({ text = "Currency Converter", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "copy", variant = "ghost", tooltip = "Copy result", onClick = copyResult }),
      ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = function() panel.close() end }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({ key = "amount", value = amountText, placeholder = "Amount", focus = true,
                 flexGrow = 1, onChange = onAmount }),
      ui.select({ key = "from", options = CODES, selectedIndex = fromIdx - 1, width = 100, onChange = onFrom }),
    }),
    ui.row({ gap = 8, align = "center", justify = "center" }, {
      ui.button({ glyph = "arrows-up-down", variant = "outline", tooltip = "Swap", onClick = swap }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = resultText, fontSize = 20, fontWeight = "bold", flexGrow = 1 }),
      ui.select({ key = "to", options = CODES, selectedIndex = toIdx - 1, width = 100, onChange = onTo }),
    }),
    ui.label({ text = rateText, fontSize = 12, color = "on_surface/0.6" }),
  }))
end

noctalia.state.watch("rates", function(value)
  rates = value
  render()
end)

function onOpen()
  render()
end
