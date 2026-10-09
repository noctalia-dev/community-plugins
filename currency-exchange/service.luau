--!nonstrict
-- Publishes units-per-USD for every currency to the widget, panel and launcher
-- via the state channel. Two sources are merged:
--   1. open.er-api.com: broad coverage (~160 currencies), daily reference rates.
--   2. AwesomeAPI: real-time market bids, overrides (1) for the currencies it
--      lists, which includes BRL.
-- If one source is down, the other still publishes what it has.
local BASE_URL = "https://open.er-api.com/v6/latest/USD"
local LIVE_URL = "https://economia.awesomeapi.com.br/json/all"

local function parseBase(body)
  local data = noctalia.json.decode(body)
  if type(data) ~= "table" or type(data.rates) ~= "table" then
    return nil
  end
  local rates = {}
  for code, rate in pairs(data.rates) do
    local n = tonumber(rate)
    if n ~= nil and n > 0 then
      rates[code] = n
    end
  end
  rates.USD = 1.0
  return rates
end

local function overlayLive(rates, body)
  local data = noctalia.json.decode(body)
  if type(data) ~= "table" or data.USD == nil then
    return false
  end
  local usdBid = tonumber(data.USD.bid)
  if usdBid == nil or usdBid <= 0 then
    return false
  end
  -- bid = BRL per 1 unit of that currency; convert to units per 1 USD.
  rates.BRL = usdBid
  for code, entry in pairs(data) do
    local bid = type(entry) == "table" and tonumber(entry.bid) or nil
    if code ~= "USD" and bid ~= nil and bid > 0 then
      rates[code] = usdBid / bid
    end
  end
  return true
end

local function fetch()
  local rates = {}
  local pending = 2

  local function done()
    pending = pending - 1
    if pending == 0 and next(rates) ~= nil then
      noctalia.state.set("rates", rates)
      noctalia.log("rates loaded")
    end
  end

  noctalia.http({ url = BASE_URL, follow_redirects = true }, function(res)
    if res.ok and res.status == 200 then
      local base = parseBase(res.body)
      if base ~= nil then
        -- Base rates go in first; live values (applied after) win.
        for code, rate in pairs(base) do
          if rates[code] == nil then
            rates[code] = rate
          end
        end
      end
    else
      noctalia.log("base fetch failed, status " .. tostring(res.status))
    end
    done()
  end)

  noctalia.http({ url = LIVE_URL, follow_redirects = true }, function(res)
    if res.ok and res.status == 200 then
      local live = {}
      if overlayLive(live, res.body) then
        for code, rate in pairs(live) do
          rates[code] = rate
        end
      end
    else
      noctalia.log("live fetch failed, status " .. tostring(res.status))
    end
    done()
  end)
end

noctalia.setUpdateInterval((noctalia.getConfig("refresh_minutes") or 30) * 60000)
fetch()

function update()
  fetch()
end
