--!nonstrict
-- Fetches rates from AwesomeAPI (BRL-based, real-time market rates) and
-- publishes units-per-USD to the widget and launcher via the state channel.
local URL = "https://economia.awesomeapi.com.br/json/all"

local function fetch()
  noctalia.http({ url = URL, follow_redirects = true }, function(res)
    if not res.ok or res.status ~= 200 then
      noctalia.log("fetch failed, status " .. tostring(res.status))
      return
    end
    local data = noctalia.json.decode(res.body)
    if type(data) ~= "table" or data.USD == nil then
      noctalia.log("unexpected response shape")
      return
    end
    local usdBid = tonumber(data.USD.bid)
    if usdBid == nil or usdBid <= 0 then
      return
    end
    -- bid = BRL per 1 unit of that currency; store units per 1 USD.
    local rates = { USD = 1.0, BRL = usdBid }
    for code, entry in pairs(data) do
      local bid = type(entry) == "table" and tonumber(entry.bid) or nil
      if code ~= "USD" and bid ~= nil and bid > 0 then
        rates[code] = usdBid / bid
      end
    end
    noctalia.state.set("rates", rates)
    noctalia.log("rates loaded")
  end)
end

noctalia.setUpdateInterval((noctalia.getConfig("refresh_minutes") or 30) * 60000)
fetch()

function update()
  fetch()
end
