local relays = loadModule("relays.luau")

local list = relays.parse(fixture("relay-list.txt"))
-- Fixture has 50 countries (matches the brief).
eq("country count", #list, 50)

local function country(code)
  for _, c in ipairs(list) do if c.code == code then return c end end
end
local function city(c, code)
  for _, ci in ipairs(c.cities) do if ci.code == code then return ci end end
end
local function near(name, a, b) check(name, a ~= nil and math.abs(a - b) < 1e-6) end

local al = country("al")
eq("al name", al.name, "Albania")
local tia = city(al, "tia")
check("tia exists", tia ~= nil)
near("tia lat", tia.latitude, 41.32795)
near("tia lon", tia.longitude, 19.81902)
eq("tia first host", tia.hostnames[1], "al-tia-wg-001")
eq("tia host count", #tia.hostnames, 4)
local bue = city(country("ar"), "bue")
near("bue lat", bue.latitude, -34.47456)
near("bue lon", bue.longitude, -58.66452)

-- forState
local st = relays.forState(list)
eq("forState count", #st, 50)
eq("forState code", st[1].code, list[1].code)
eq("forState city code", st[1].cities[1].code, list[1].cities[1].code)
check("forState no hostnames", st[1].cities[1].hostnames == nil)
check("forState no coords", st[1].cities[1].latitude == nil)

-- myCountry
eq("myCountry by name", relays.myCountry(list, { country = "Romania", latitude = 44.4, longitude = 26.1 }), "ro")

local function hav(lat1, lon1, lat2, lon2)
  local r = math.rad
  local dlat, dlon = r(lat2 - lat1), r(lon2 - lon1)
  local a = math.sin(dlat / 2) ^ 2 + math.cos(r(lat1)) * math.cos(r(lat2)) * math.sin(dlon / 2) ^ 2
  return 2 * 6371 * math.asin(math.sqrt(a))
end
local best, bestD
for _, c in ipairs(list) do
  for _, ci in ipairs(c.cities) do
    local d = hav(47.01, 28.86, ci.latitude, ci.longitude)
    if not bestD or d < bestD then best, bestD = c.code, d end
  end
end
eq("myCountry nearest (Moldova)", relays.myCountry(list, { country = "Moldova", latitude = 47.01, longitude = 28.86 }), best)

local code, reason = relays.myCountry(list, nil)
eq("myCountry nil code", code, nil)
eq("myCountry nil reason", reason, "connect.my_country_unknown")

-- randomCountry
eq("random excludes first", relays.randomCountry(list, list[1].code, function(n) return 1 end), list[2].code)
eq("random no exclude", relays.randomCountry(list, nil, function(n) return 1 end), list[1].code)
local single = { list[1] }
eq("random single keeps excluded", relays.randomCountry(single, list[1].code, function(n) return 1 end), list[1].code)

-- empty
local empty = relays.parse(fixture("synthetic-relay-list-empty.txt"))
eq("empty parse size", #empty, 0)
eq("empty myCountry", relays.myCountry(empty, { country = "Romania", latitude = 1, longitude = 1 }), nil)
eq("empty random", relays.randomCountry(empty, nil, function(n) return 1 end), nil)
