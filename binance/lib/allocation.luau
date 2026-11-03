--!strict
-- Portfolio split by asset class for the Overview: crypto, stocks,
-- stablecoins, and fiat cash as "other". Shares are of the summed holding
-- values, so they add up to 100% even when totals round differently.

local M = {}

-- USD- and EUR-pegged tokens listed on Binance spot.
local STABLECOINS = {
  USDT = true, USDC = true, FDUSD = true, TUSD = true, USDP = true, DAI = true,
  PYUSD = true, USDE = true, USD1 = true, RLUSD = true, BFUSD = true, BUSD = true,
  EURI = true, AEUR = true, EURC = true,
}

-- Fiat balances (Binance holds them as spot assets).
local FIAT = {
  USD = true, EUR = true, GBP = true, TRY = true, BRL = true, ARS = true, MXN = true,
  PLN = true, RON = true, CZK = true, UAH = true, ZAR = true, JPY = true, AUD = true,
  COP = true, KZT = true, NGN = true, IDR = true, CHF = true, SEK = true, NOK = true,
}

M.ORDER = { "crypto", "stocks", "stable", "other" }

function M.classOf(kind: string, asset: string): string
  if kind == "stock" then
    return "stocks"
  elseif STABLECOINS[asset] then
    return "stable"
  elseif FIAT[asset] then
    return "other"
  end
  return "crypto"
end

export type Slice = { id: string, value: number, share: number }

-- Non-empty classes in M.ORDER, or an empty list when nothing has a value.
function M.split(holdings: { { kind: string, asset: string, value: number } }): { Slice }
  local sums: { [string]: number } = {}
  local total = 0
  for _, h in holdings do
    if h.value > 0 then
      local id = M.classOf(h.kind, h.asset)
      sums[id] = (sums[id] or 0) + h.value
      total += h.value
    end
  end
  local out: { Slice } = {}
  if total <= 0 then
    return out
  end
  for _, id in M.ORDER do
    local value = sums[id]
    if value then
      table.insert(out, { id = id, value = value, share = value / total })
    end
  end
  return out
end

return M
