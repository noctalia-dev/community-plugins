--!nonstrict
local rates = noctalia.state.get("rates")

local function fmt(n)
  if n >= 1 then return string.format("%.2f", n) end
  return string.format("%.4f", n)
end

local function render()
  local from = string.upper(noctalia.getConfig("source_currency") or "USD")
  local to = string.upper(noctalia.getConfig("target_currency") or "EUR")
  local mode = noctalia.getConfig("display_mode") or "full"
  barWidget.setGlyph("currency-dollar")
  if mode == "icon" then
    barWidget.setText("")
  elseif rates == nil or rates[from] == nil or rates[to] == nil then
    barWidget.setText("…")
  else
    local rate = rates[to] / rates[from]
    barWidget.setText(mode == "full" and (from .. "/" .. to .. " " .. fmt(rate)) or fmt(rate))
    barWidget.setTooltip({ { "1 " .. from, fmt(rate) .. " " .. to } })
  end
end

noctalia.state.watch("rates", function(value)
  rates = value
  render()
end)
render()

function onClick()
  noctalia.togglePanel("vinioli/currency-exchange:converter")
end
