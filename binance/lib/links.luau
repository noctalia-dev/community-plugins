--!strict
-- binance.com pages for a holding, opened by the panel through xdg-open.
--
-- Crypto opens the spot market against USDT. USDT itself has no such pair,
-- so it opens its price page. Stocks open the Binance Stocks page, whose
-- address prefixes the ticker with "EQ_" (www.binance.com sitemap, e.g.
-- /en/stocks/EQ_AAPL). The symbol becomes part of a URL handed to another
-- program, so anything but 1-20 capitals and digits gets no link.

local M = {}

local BASE = "https://www.binance.com/en"

function M.validSymbol(symbol: any): boolean
  return type(symbol) == "string" and symbol:match("^[A-Z0-9]+$") ~= nil and #symbol <= 20
end

-- kind is the Holding kind: "crypto" or "stock". nil when the asset can't
-- be linked.
function M.holdingUrl(kind: string, asset: string): string?
  if not M.validSymbol(asset) then
    return nil
  end
  if kind == "stock" then
    return `{BASE}/stocks/EQ_{asset}`
  elseif kind == "crypto" then
    if asset == "USDT" then
      return `{BASE}/price/tether`
    end
    return `{BASE}/trade/{asset}_USDT`
  end
  return nil
end

return M
