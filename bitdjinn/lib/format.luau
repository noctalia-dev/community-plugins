--!strict
-- Formatting and display helpers for BitDjinn.

local M = {}

function M.currencySymbol(currency: string): string
  local c = string.lower(currency or "usd")
  if c == "cny" then
    return "¥"
  elseif c == "eur" then
    return "€"
  elseif c == "usdt" or c == "usdc" or c == "usd" then
    return "$"
  end
  return "$"
end

function M.formatPrice(price: number?, currency: string?): string
  if price == nil or price == 0 then
    return "--"
  end
  local sym = M.currencySymbol(currency or "usd")
  if price >= 1000 then
    local intPart = math.floor(price)
    local decPart = math.floor((price - intPart) * 100 + 0.5)
    local s = tostring(intPart)
    local formatted = ""
    local len = #s
    for i = 1, len do
      formatted = formatted .. string.sub(s, i, i)
      if (len - i) % 3 == 0 and i ~= len then
        formatted = formatted .. ","
      end
    end
    return string.format("%s%s.%02d", sym, formatted, decPart)
  elseif price >= 1 then
    return string.format("%s%.2f", sym, price)
  elseif price >= 0.0001 then
    return string.format("%s%.4f", sym, price)
  else
    return string.format("%s%.6f", sym, price)
  end
end

function M.formatCompactNumber(num: number?): string
  if num == nil then
    return "--"
  end
  if num >= 1000000000 then
    return string.format("%.2fB", num / 1000000000)
  elseif num >= 1000000 then
    return string.format("%.2fM", num / 1000000)
  elseif num >= 1000 then
    return string.format("%.2fK", num / 1000)
  else
    return string.format("%.2f", num)
  end
end

function M.formatChange(change: number?): string
  if change == nil then
    return "--"
  end
  if change > 0 then
    return string.format("+%.2f%%", change)
  else
    return string.format("%.2f%%", change)
  end
end

function M.changeColor(change: number?): string
  if change == nil then
    return "on_surface_variant"
  elseif change > 0 then
    return "#10b981" -- Emerald green for increase
  elseif change < 0 then
    return "#ef4444" -- Red for decrease
  else
    return "on_surface_variant"
  end
end

function M.changeBgColor(change: number?): string
  if change == nil then
    return "surface_variant/0.2"
  elseif change > 0 then
    return "#10b98124" -- 14% alpha emerald green
  elseif change < 0 then
    return "#ef444424" -- 14% alpha red
  else
    return "surface_variant/0.2"
  end
end

function M.shortAddress(addr: string?): string
  if addr == nil or addr == "" then
    return ""
  end
  local len = #addr
  if len <= 12 then
    return addr
  end
  return string.sub(addr, 1, 6) .. "..." .. string.sub(addr, len - 4, len)
end

function M.detectChain(addr: string?): string
  if addr == nil then
    return "unknown"
  end
  local s = string.lower(noctalia.string.trim(addr))
  if string.sub(s, 1, 2) == "0x" and #s == 42 then
    return "ETH"
  elseif string.sub(s, 1, 3) == "bc1" or string.sub(s, 1, 1) == "1" or string.sub(s, 1, 1) == "3" then
    if #s >= 26 and #s <= 62 then
      return "BTC"
    end
  elseif #s >= 32 and #s <= 44 and not string.find(s, "[^1-9a-km-za-hj-np-z]") then
    return "SOL"
  end
  return "unknown"
end

function M.coinGlyph(symbol: string?): string
  local sym = string.upper(symbol or "")
  if sym == "BTC" then
    return "currency-bitcoin"
  elseif sym == "ETH" then
    return "currency-ethereum"
  elseif sym == "SOL" then
    return "currency-solana"
  elseif sym == "BNB" then
    return "brand-binance"
  elseif sym == "DOGE" then
    return "currency-dogecoin"
  elseif sym == "XRP" then
    return "currency-ripple"
  elseif sym == "USDT" or sym == "USDC" then
    return "currency-dollar"
  end
  return "coin"
end

-- Normalize an array of historical prices to a 0.0 ~ 1.0 range for ui.graph
function M.normalizeForGraph(history: { number }?): { number }
  if history == nil or #history == 0 then
    return { 0.5, 0.5, 0.5, 0.5 }
  end
  if #history == 1 then
    return { 0.5, 0.5, 0.5, 0.5 }
  end

  local minVal = history[1]
  local maxVal = history[1]
  for _, v in ipairs(history) do
    if v < minVal then minVal = v end
    if v > maxVal then maxVal = v end
  end

  local range = maxVal - minVal
  local normalized = {}
  if range <= 0.0000001 then
    for i = 1, #history do
      table.insert(normalized, 0.5)
    end
    return normalized
  end

  for _, v in ipairs(history) do
    local norm = (v - minVal) / range
    -- Map to 0.08 ~ 0.92 range for clean margin inside graph container
    local padded = 0.08 + norm * 0.84
    table.insert(normalized, math.clamp(padded, 0.0, 1.0))
  end
  return normalized
end

return M
