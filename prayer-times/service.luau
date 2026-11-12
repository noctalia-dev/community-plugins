--!nonstrict
-- Fetches prayer times for the configured location and publishes shared state.

noctalia.setUpdateInterval(1000)

local PRAYER_ORDER = { "Fajr", "Dhuhr", "Asr", "Maghrib", "Isha" }

local locationMode = "auto"
local city = ""
local country = "Turkey"
local latitude = ""
local longitude = ""
local method = "13"
local school = "1"
local notifyEnabled = true

local loadedDate = ""
local fetchPending = false
local geoPending = false
local retryAt = 0
local retryCount = 0
local tomorrowFetched = false
local lastNotified = ""
local cachedPrayers = {}
local RETRY_DELAYS = { 5, 15, 30, 60, 120 }

local function reloadConfig()
	locationMode = noctalia.getConfig("location_mode") or "auto"
	city = noctalia.getConfig("city") or ""
	country = noctalia.getConfig("country") or "Turkey"
	latitude = noctalia.getConfig("latitude") or ""
	longitude = noctalia.getConfig("longitude") or ""
	method = noctalia.getConfig("method") or "13"
	school = noctalia.getConfig("school") or "1"
	local notify = noctalia.getConfig("notify")
	notifyEnabled = notify ~= false and notify ~= "false"
end

local function todayStr()
	return os.date("%Y-%m-%d")
end

local function nowSeconds()
	local t = os.date("*t")
	return t.hour * 3600 + t.min * 60 + t.sec
end

local function isJumuah()
	return os.date("*t").wday == 6
end

local function parseTime(str)
	if type(str) ~= "string" then
		return nil
	end
	local h, m = str:match("^(%d+):(%d+)")
	if not h then
		return nil
	end
	return tonumber(h) * 3600 + tonumber(m) * 60
end

local function cleanClock(str)
	if type(str) ~= "string" then
		return ""
	end
	return str:match("^(%d+:%d+)") or str
end

local function dateParam(offsetDays)
	local t = os.time() + (offsetDays or 0) * 86400
	local d = os.date("*t", t)
	return string.format("%02d-%02d-%04d", d.day, d.month, d.year)
end

local function publishError(msg)
	noctalia.state.set("error", msg)
end

local function cachePath()
	local dir = noctalia.pluginDataDir()
	if not dir then
		return nil
	end
	return dir .. "/cache.json"
end

local function saveCache(payload)
	local path = cachePath()
	if not path then
		return
	end
	local encoded = noctalia.json.encode(payload)
	if encoded then
		noctalia.writeFile(path, encoded)
	end
end

local function loadCache()
	local path = cachePath()
	if not path then
		return nil
	end
	local raw = noctalia.readFile(path)
	if not raw then
		return nil
	end
	local data = noctalia.json.decode(raw)
	if type(data) ~= "table" then
		return nil
	end
	return data
end

local function processTimings(entry, locationLabel)
	local timings = entry and entry.timings
	if type(timings) ~= "table" then
		publishError(noctalia.tr("error.parse"))
		return false
	end

	local prayers = {}
	for _, name in ipairs(PRAYER_ORDER) do
		local secs = parseTime(timings[name])
		if secs then
			prayers[#prayers + 1] = {
				id = name,
				time = cleanClock(timings[name]),
				seconds = secs,
			}
		end
	end

	if #prayers == 0 then
		publishError(noctalia.tr("error.parse"))
		return false
	end

	local sunrise = cleanClock(timings.Sunrise)
	local hijri = entry.date and entry.date.hijri
	local hijriLabel = ""
	if type(hijri) == "table" then
		local month = (hijri.month and hijri.month.en) or ""
		hijriLabel = string.format("%s %s %s", tostring(hijri.day or ""), month, tostring(hijri.year or ""))
	end

	local meta = entry.meta or {}
	local resolved = locationLabel
	if resolved == "" and type(meta.timezone) == "string" then
		resolved = meta.timezone
	end

	noctalia.state.set("prayers", prayers)
	noctalia.state.set("sunrise", sunrise)
	noctalia.state.set("hijri", hijriLabel)
	noctalia.state.set("gregorian", (entry.date and entry.date.readable) or "")
	noctalia.state.set("location", resolved)
	noctalia.state.set("isJumuah", isJumuah())
	noctalia.state.set("error", "")
	noctalia.state.set("updatedAt", os.time())

	cachedPrayers = prayers
	if loadedDate ~= todayStr() then
		lastNotified = ""
	end
	loadedDate = todayStr()
	retryCount = 0
	retryAt = 0

	saveCache({
		date = loadedDate,
		location = resolved,
		prayers = prayers,
		sunrise = sunrise,
		hijri = hijriLabel,
		gregorian = (entry.date and entry.date.readable) or "",
		mode = locationMode,
		method = method,
		school = school,
	})

	noctalia.log(`PrayerTimes: loaded {#prayers} times for {resolved}`)
	return true
end

local function applyCache(cache)
	if type(cache) ~= "table" or cache.date ~= todayStr() then
		return false
	end
	if type(cache.prayers) ~= "table" or #cache.prayers == 0 then
		return false
	end
	cachedPrayers = cache.prayers
	loadedDate = cache.date
	noctalia.state.set("prayers", cache.prayers)
	noctalia.state.set("sunrise", cache.sunrise or "")
	noctalia.state.set("hijri", cache.hijri or "")
	noctalia.state.set("gregorian", cache.gregorian or "")
	noctalia.state.set("location", cache.location or "")
	noctalia.state.set("isJumuah", isJumuah())
	noctalia.state.set("error", "")
	return true
end

local function scheduleRetry()
	if retryCount >= #RETRY_DELAYS then
		return
	end
	retryCount += 1
	retryAt = os.time() + RETRY_DELAYS[retryCount]
	noctalia.log(`PrayerTimes: retry {retryCount} in {RETRY_DELAYS[retryCount]}s`)
end

local function fetchByUrl(url, locationLabel)
	if fetchPending then
		return
	end
	fetchPending = true
	noctalia.log("PrayerTimes: fetching " .. url)
	local accepted = noctalia.http({
		url = url,
		follow_redirects = true,
		headers = { "Accept: application/json" },
	}, function(res)
		fetchPending = false
		if not res.ok or res.body == "" then
			publishError(noctalia.tr("error.network"))
			scheduleRetry()
			return
		end
		local data = noctalia.json.decode(res.body)
		if type(data) ~= "table" or data.code ~= 200 or type(data.data) ~= "table" then
			publishError(noctalia.tr("error.parse"))
			scheduleRetry()
			return
		end
		if not processTimings(data.data, locationLabel) then
			scheduleRetry()
		end
	end)
	if accepted == false then
		fetchPending = false
		publishError(noctalia.tr("error.network"))
		scheduleRetry()
	end
end

local function timingsUrlByCoords(lat, lon, offsetDays)
	return string.format(
		"https://api.aladhan.com/v1/timings/%s?latitude=%s&longitude=%s&method=%s&school=%s",
		dateParam(offsetDays or 0),
		noctalia.string.urlEncode(tostring(lat)),
		noctalia.string.urlEncode(tostring(lon)),
		noctalia.string.urlEncode(method),
		noctalia.string.urlEncode(school)
	)
end

local function timingsUrlByCity(offsetDays)
	return string.format(
		"https://api.aladhan.com/v1/timingsByCity/%s?city=%s&country=%s&method=%s&school=%s",
		dateParam(offsetDays or 0),
		noctalia.string.urlEncode(city),
		noctalia.string.urlEncode(country),
		noctalia.string.urlEncode(method),
		noctalia.string.urlEncode(school)
	)
end

local function fetchTomorrowFajr(urlBuilder)
	noctalia.http({
		url = urlBuilder(1),
		follow_redirects = true,
		headers = { "Accept: application/json" },
	}, function(res)
		if not res.ok or res.body == "" then
			return
		end
		local data = noctalia.json.decode(res.body)
		local timings = data and data.data and data.data.timings
		local secs = timings and parseTime(timings.Fajr)
		if secs then
			noctalia.state.set("tomorrowFajr", secs)
		end
	end)
end

local function geolocateThenFetch()
	if geoPending then
		return
	end
	geoPending = true
	noctalia.http({
		url = "http://ip-api.com/json/?fields=status,message,lat,lon,city,country,timezone",
		follow_redirects = true,
		headers = { "Accept: application/json" },
	}, function(res)
		geoPending = false
		if not res.ok or res.body == "" then
			publishError(noctalia.tr("error.location"))
			scheduleRetry()
			return
		end
		local data = noctalia.json.decode(res.body)
		if type(data) ~= "table" or data.status ~= "success" then
			publishError(noctalia.tr("error.location"))
			scheduleRetry()
			return
		end
		local lat, lon = data.lat, data.lon
		local label = table.concat({
			tostring(data.city or ""),
			tostring(data.country or ""),
		}, ", "):gsub("^, ", ""):gsub(", $", "")
		if label == "" then
			label = string.format("%.4f, %.4f", lat, lon)
		end
		local url = timingsUrlByCoords(lat, lon, 0)
		fetchByUrl(url, label)
		tomorrowFetched = true
		fetchTomorrowFajr(function(offset)
			return timingsUrlByCoords(lat, lon, offset)
		end)
	end)
end

local function fetchTimes()
	reloadConfig()

	if locationMode == "coords" then
		local lat = tonumber(latitude)
		local lon = tonumber(longitude)
		if not lat or not lon then
			publishError(noctalia.tr("error.coords"))
			return
		end
		local label = string.format("%.4f, %.4f", lat, lon)
		fetchByUrl(timingsUrlByCoords(lat, lon, 0), label)
		tomorrowFetched = true
		fetchTomorrowFajr(function(offset)
			return timingsUrlByCoords(lat, lon, offset)
		end)
		return
	end

	if locationMode == "city" then
		if city == "" then
			publishError(noctalia.tr("error.city"))
			return
		end
		local label = city
		if country ~= "" then
			label ..= ", " .. country
		end
		fetchByUrl(timingsUrlByCity(0), label)
		tomorrowFetched = true
		fetchTomorrowFajr(timingsUrlByCity)
		return
	end

	-- auto: prefer shell address when set, otherwise IP geolocation
	local address = noctalia.getSetting("location.address")
	if type(address) == "string" and address ~= "" then
		local url = string.format(
			"https://api.aladhan.com/v1/timingsByAddress/%s?address=%s&method=%s&school=%s",
			dateParam(0),
			noctalia.string.urlEncode(address),
			noctalia.string.urlEncode(method),
			noctalia.string.urlEncode(school)
		)
		fetchByUrl(url, address)
		tomorrowFetched = true
		fetchTomorrowFajr(function(offset)
			return string.format(
				"https://api.aladhan.com/v1/timingsByAddress/%s?address=%s&method=%s&school=%s",
				dateParam(offset),
				noctalia.string.urlEncode(address),
				noctalia.string.urlEncode(method),
				noctalia.string.urlEncode(school)
			)
		end)
		return
	end

	geolocateThenFetch()
end

local function checkNotifications()
	if not notifyEnabled or #cachedPrayers == 0 then
		return
	end
	local now = nowSeconds()
	for _, p in ipairs(cachedPrayers) do
		if now >= p.seconds and now < p.seconds + 30 then
			local key = loadedDate .. "_" .. p.id
			if lastNotified ~= key then
				lastNotified = key
				local nameKey = "prayer." .. string.lower(p.id)
				local name = noctalia.tr(nameKey)
				if p.id == "Dhuhr" and isJumuah() then
					name = noctalia.tr("prayer.jumuah")
				end
				noctalia.notify(
					noctalia.tr("notify.title", { name = name }),
					noctalia.tr("notify.body", { time = p.time })
				)
			end
		end
	end
end

function update()
	local today = todayStr()
	if loadedDate ~= today and not fetchPending and not geoPending then
		tomorrowFetched = false
		fetchTimes()
	end
	if retryAt > 0 and os.time() >= retryAt and not fetchPending and not geoPending then
		retryAt = 0
		fetchTimes()
	end
	checkNotifications()
end

function onConfigChanged()
	noctalia.log("PrayerTimes: settings changed, refreshing")
	loadedDate = ""
	retryCount = 0
	retryAt = 0
	tomorrowFetched = false
	cachedPrayers = {}
	noctalia.state.set("prayers", {})
	fetchTimes()
end

function onIpc(event, _payload)
	if event == "refresh" then
		onConfigChanged()
	end
end

noctalia.state.watch("command", function(cmd)
	if type(cmd) == "table" and cmd.action == "refresh" then
		onConfigChanged()
	end
end)

reloadConfig()
if not applyCache(loadCache()) then
	fetchTimes()
else
	noctalia.log("PrayerTimes: restored cache for " .. loadedDate)
	-- Soft refresh in background
	fetchTimes()
end
