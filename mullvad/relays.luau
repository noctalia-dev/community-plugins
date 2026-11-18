--!nonstrict
-- Pure relay list handling: parse `mullvad relay list`, pick my country / random.

local relays = {}

function relays.parse(text)
  local list = {}
  local country, city
  for raw in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
    local line = string.gsub(raw, "\r$", "")
    if string.sub(line, 1, 2) == "\t\t" then
      local host = string.match(line, "^\t\t(%S+)")
      if host and city then
        table.insert(city.hostnames, host)
      end
    elseif string.sub(line, 1, 1) == "\t" then
      local name, code, lat, lon = string.match(line, "^\t(.-) %(([%w_%-]+)%) @ (%-?[%d%.]+)[^,]*,%s*(%-?[%d%.]+)")
      if name and country then
        city = {
          code = code, name = name,
          latitude = tonumber(lat), longitude = tonumber(lon),
          hostnames = {},
        }
        table.insert(country.cities, city)
      end
    else
      local name, code = string.match(line, "^(.-) %(([%w_%-]+)%)$")
      if name then
        country = { code = code, name = name, cities = {} }
        city = nil
        table.insert(list, country)
      end
    end
  end
  return list
end

function relays.forState(list)
  local out = {}
  for _, c in ipairs(list or {}) do
    local cities = {}
    for _, ci in ipairs(c.cities) do
      table.insert(cities, { code = ci.code, name = ci.name })
    end
    table.insert(out, { code = c.code, name = c.name, cities = cities })
  end
  return out
end

local function haversine(lat1, lon1, lat2, lon2)
  local rad = math.pi / 180
  local dlat = (lat2 - lat1) * rad
  local dlon = (lon2 - lon1) * rad
  local a = math.sin(dlat / 2) ^ 2
    + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.sin(dlon / 2) ^ 2
  return 2 * 6371 * math.asin(math.sqrt(math.min(1, a)))
end

function relays.myCountry(list, realLocation)
  if realLocation == nil then
    return nil, "connect.my_country_unknown"
  end
  for _, c in ipairs(list or {}) do
    if c.name == realLocation.country then
      return c.code
    end
  end
  local lat, lon = realLocation.latitude, realLocation.longitude
  if type(lat) ~= "number" or type(lon) ~= "number" then
    return nil, "connect.my_country_unknown"
  end
  local bestCode, bestDist
  for _, c in ipairs(list or {}) do
    for _, ci in ipairs(c.cities) do
      if ci.latitude and ci.longitude then
        local d = haversine(lat, lon, ci.latitude, ci.longitude)
        if bestDist == nil or d < bestDist then
          bestCode, bestDist = c.code, d
        end
      end
    end
  end
  return bestCode
end

function relays.randomCountry(list, excludeCode, rand)
  list = list or {}
  local pool = {}
  for _, c in ipairs(list) do
    if not (excludeCode ~= nil and c.code == excludeCode and #list > 1) then
      table.insert(pool, c)
    end
  end
  if #pool == 0 then
    return nil
  end
  return pool[rand(#pool)].code
end

return relays
