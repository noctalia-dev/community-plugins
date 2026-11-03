--!nonstrict
-- Unit tests for the pure modules behind the panel: holding links and the
-- Overview's allocation split.

local t = require("./support/t")
local links = require("../lib/links")
local allocation = require("../lib/allocation")

-- ── links ──

t.test("holding links open the USDT market, the stocks page, or nothing", function()
  t.eq(links.holdingUrl("crypto", "BTC"), "https://www.binance.com/en/trade/BTC_USDT")
  t.eq(links.holdingUrl("stock", "NVDA"), "https://www.binance.com/en/stocks/EQ_NVDA")
  -- USDT_USDT does not exist.
  t.eq(links.holdingUrl("crypto", "USDT"), "https://www.binance.com/en/price/tether")
  t.eq(links.holdingUrl("wallet", "BTC"), nil)
end)

t.test("a symbol that could change the URL gets no link", function()
  for _, bad in { "", "btc", "BRK.B", "BTC/../../my/wallet", "BTC?x=1", "BTC USDT", "-BTC", string.rep("A", 21) } do
    t.eq(links.holdingUrl("crypto", bad), nil, bad)
    t.eq(links.holdingUrl("stock", bad), nil, bad)
  end
  t.eq(links.validSymbol(string.rep("A", 20)), true)
  t.eq(links.validSymbol("1000SATS"), true)
end)

-- ── allocation ──

t.test("allocation keeps stablecoins and cash out of crypto", function()
  local slices = allocation.split({
    { kind = "crypto", asset = "BTC", value = 600 },
    { kind = "stock", asset = "NVDA", value = 200 },
    { kind = "crypto", asset = "USDC", value = 100 },
    { kind = "crypto", asset = "USDT", value = 50 },
    { kind = "crypto", asset = "EUR", value = 50 },
  })
  local ids, sum = {}, 0
  for _, s in slices do
    table.insert(ids, s.id)
    sum += s.share
  end
  t.eq(table.concat(ids, ","), "crypto,stocks,stable,other")
  t.eq(slices[3].value, 150)
  t.eq(math.abs(sum - 1) < 1e-9, true, "shares add up to 100%")
end)

t.test("allocation leaves out empty classes and unpriced holdings", function()
  local slices = allocation.split({
    { kind = "crypto", asset = "BTC", value = 10 },
    { kind = "crypto", asset = "NEWCOIN", value = 0 },
  })
  t.eq(#slices, 1)
  t.eq(slices[1].share, 1)
  t.eq(#allocation.split({}), 0)
end)
return {}
