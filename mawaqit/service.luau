--!nonstrict
-- service.luau — Mawaqit background fetcher

noctalia.setUpdateInterval(5000)

-- ── Config ────────────────────────────────────────────────────────────────────

local city, country, method, school, hijriDayOffset
local tune, tuneFajr, tuneDhuhr, tuneAsr, tuneMaghrib, tuneIsha
local showNotifications, playAzan, azanFile, twelveHourFormat

-- Safely quotes strings for shell execution to prevent injection.
local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function reloadConfig()
    local c_city              = noctalia.getConfig("city")
    local c_country           = noctalia.getConfig("country")
    local c_method            = noctalia.getConfig("method")
    local c_school            = noctalia.getConfig("school")
    local c_hijriDayOffset    = noctalia.getConfig("hijriDayOffset")
    local c_tune              = noctalia.getConfig("tune")
    local c_tuneFajr          = noctalia.getConfig("tuneFajr")
    local c_tuneDhuhr         = noctalia.getConfig("tuneDhuhr")
    local c_tuneAsr           = noctalia.getConfig("tuneAsr")
    local c_tuneMaghrib       = noctalia.getConfig("tuneMaghrib")
    local c_tuneIsha          = noctalia.getConfig("tuneIsha")
    local c_showNotifications = noctalia.getConfig("showNotifications")
    local c_playAzan          = noctalia.getConfig("playAzan")
    local c_azanFile          = noctalia.getConfig("azanFile")
    local c_twelveHourFormat  = noctalia.getConfig("twelveHourFormat")

    city              = (type(c_city)    == "string" and c_city    ~= "") and c_city    or "London"
    country           = (type(c_country) == "string" and c_country ~= "") and c_country or "UK"
    method            = (type(c_method)  == "string" and c_method  ~= "") and c_method  or "3"
    school            = (type(c_school)  == "string" and c_school  ~= "") and c_school  or "0"
    hijriDayOffset    = tonumber(c_hijriDayOffset) or 0
    tune              = (c_tune == true or c_tune == "true")
    tuneFajr          = tonumber(c_tuneFajr)    or 0
    tuneDhuhr         = tonumber(c_tuneDhuhr)   or 0
    tuneAsr           = tonumber(c_tuneAsr)     or 0
    tuneMaghrib       = tonumber(c_tuneMaghrib) or 0
    tuneIsha          = tonumber(c_tuneIsha)    or 0
    showNotifications = (c_showNotifications ~= false and c_showNotifications ~= "false")
    playAzan          = (c_playAzan == true or c_playAzan == "true")
    azanFile          = (type(c_azanFile) == "string" and c_azanFile ~= "") and c_azanFile or "azan1.mp3"
    twelveHourFormat  = (c_twelveHourFormat == true or c_twelveHourFormat == "true")
end

reloadConfig()
noctalia.log("Mawaqit: city=" .. city .. " country=" .. country .. " method=" .. method)

-- Check azan player availability at startup
local paplayAvailable = noctalia.commandExists("paplay")
local pwcatAvailable  = noctalia.commandExists("pw-cat")
if playAzan and not paplayAvailable and not pwcatAvailable then
    noctalia.log("Mawaqit: azan enabled but neither paplay nor pw-cat found")
end

-- ── State ─────────────────────────────────────────────────────────────────────

-- Prayers for countdown (no Sunrise — not a salah)
local PRAYER_NAMES = { "Fajr", "Dhuhr", "Asr", "Maghrib", "Isha" }
local AZAN_PRAYERS = { true,   true,    true,   true,      true   }

local loadedDate      = ""
local fetchPending    = false
local retryCount      = 0
local MAX_RETRIES     = 5
local retryTicks      = 0
local tomorrowFetched = false
local lastNotified    = ""
local lastAzanPlayed  = ""
local azanProcess     = nil  -- track running azan process

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function parseTime(str)
    if not str then return nil end
    local h, m = str:match("^(%d+):(%d+)")
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60
end

local function todayStr()
    return os.date("%Y-%m-%d")
end

-- Converts a 24-hour "HH:MM" string to 12-hour display, when the setting is on.
-- Returns the input unchanged (24-hour) otherwise, or if it doesn't parse.
local function formatDisplayTime(clean)
    if not twelveHourFormat then return clean end
    local h, m = clean:match("^(%d+):(%d+)")
    if not h then return clean end
    local hourNum = tonumber(h)
    local period = hourNum < 12 and "AM" or "PM"
    local displayHour = hourNum % 12
    if displayHour == 0 then displayHour = 12 end
    return string.format("%d:%s %s", displayHour, m, period)
end

local function nowSeconds()
    local t = os.date("*t")
    return t.hour * 3600 + t.min * 60 + t.sec
end

local function isJumuah()
    return os.date("*t").wday == 6
end

local function dateParam(offsetDays)
    local t = os.time() + (offsetDays * 86400)
    local d = os.date("*t", t)
    return string.format("%02d-%02d-%04d", d.day, d.month, d.year)
end

local function applyTune(name, secs)
    if not tune then return secs end
    local offset = 0
    if     name == "Fajr"    then offset = tuneFajr
    elseif name == "Dhuhr"   then offset = tuneDhuhr
    elseif name == "Asr"     then offset = tuneAsr
    elseif name == "Maghrib" then offset = tuneMaghrib
    elseif name == "Isha"    then offset = tuneIsha
    end
    return secs + offset * 60
end

local function buildUrl(offsetDays)
    local dateStr = dateParam(offsetDays or 0)
    return string.format(
        "https://api.aladhan.com/v1/timingsByCity/%s?city=%s&country=%s&method=%s&school=%s",
        dateStr,
        noctalia.string.urlEncode(city),
        noctalia.string.urlEncode(country),
        method, school
    )
end

local function azanPath()
    local home = noctalia.expandPath("~")
    local safe = azanFile:match("^[%w%.%-_]+$") and azanFile or "azan1.mp3"
    return home .. "/.local/share/noctalia/plugins/mawaqit/assets/" .. safe
end

-- ── Fetch ─────────────────────────────────────────────────────────────────────

local function publishError(msg)
    noctalia.state.set("error", msg)
end

local function processPrayerData(data)
    if not data or data.code ~= 200 then
        publishError("API error: " .. tostring(data and data.status or "unknown"))
        return false
    end
    local timings = data.data and data.data.timings
    if not timings then
        publishError("Parse error: no timings in response")
        return false
    end

    local prayers = {}
    for i, name in ipairs(PRAYER_NAMES) do
        local raw = timings[name]
        if raw then
            local clean = raw:match("^(%d+:%d+)") or raw
            local secs = parseTime(clean)
            if secs then
                secs = applyTune(name, secs)
                prayers[#prayers+1] = {
                    name       = name,
                    time       = formatDisplayTime(clean),
                    seconds    = secs,
                    azanPrayer = AZAN_PRAYERS[i],
                }
            end
        end
    end

    -- Imsak (Ramadan only)
    local imsakRaw  = timings["Imsak"]
    local imsakTime = imsakRaw and formatDisplayTime(imsakRaw:match("^(%d+:%d+)") or imsakRaw) or ""

    -- Sunrise (display only, not a prayer)
    local sunriseRaw  = timings["Sunrise"]
    local sunriseTime = sunriseRaw and formatDisplayTime(sunriseRaw:match("^(%d+:%d+)") or sunriseRaw) or ""

    -- Hijri date
    local hijri = data.data.date and data.data.date.hijri
    local greg  = (data.data.date and data.data.date.readable) or ""
    local hijriDay     = 0
    local hijriMonth   = 0
    local hijriYear    = 0
    local hijriDateStr = ""
    local hijriDateAr  = ""

    if hijri then
        hijriDay   = math.max(1, math.min(30, (tonumber(hijri.day) or 0) + hijriDayOffset))
        hijriMonth = (hijri.month and hijri.month.number) or 0
        hijriYear  = tonumber(hijri.year) or 0
        local monthEn = (hijri.month and hijri.month.en) or ""
        local monthAr = (hijri.month and hijri.month.ar) or ""
        hijriDateStr  = string.format("%d %s %d AH", hijriDay, monthEn, hijriYear)

        local function toArabicNumerals(n)
            local arabic = {"٠","١","٢","٣","٤","٥","٦","٧","٨","٩"}
            return tostring(n):gsub("%d", function(d)
                return arabic[tonumber(d) + 1]
            end)
        end
        hijriDateAr = toArabicNumerals(hijriDay) .. " " .. monthAr .. " " .. toArabicNumerals(hijriYear)
    end

    noctalia.state.set("prayers",       prayers)
    noctalia.state.set("sunriseTime",   sunriseTime)
    noctalia.state.set("imsakTime",     imsakTime)
    noctalia.state.set("hijriDate",     hijriDateStr)
    noctalia.state.set("hijriDateAr",   hijriDateAr)
    noctalia.state.set("gregorianDate", greg)
    noctalia.state.set("hijriDay",      hijriDay)
    noctalia.state.set("hijriMonth",    hijriMonth)
    noctalia.state.set("hijriYear",     hijriYear)
    noctalia.state.set("isJumuah",      isJumuah())
    noctalia.state.set("error",         "")

    loadedDate     = todayStr()
    lastNotified   = ""
    lastAzanPlayed = ""
    retryCount     = 0

    noctalia.log("Mawaqit: loaded " .. #prayers .. " prayers for " .. city .. ", " .. country
        .. " hijriMonth=" .. hijriMonth)
    return true
end

local function fetchTimes()
    if fetchPending then return end
    reloadConfig()
    fetchPending = true
    local url = buildUrl(0)
    noctalia.log("Mawaqit: fetching " .. url)
    noctalia.http({ url = url, follow_redirects = true }, function(res)
        fetchPending = false
        if not res.ok or res.body == "" then
            retryCount += 1
            publishError("Network error (status=" .. tostring(res.status) .. ")")
            return
        end
        local ok, data = pcall(function() return noctalia.json.decode(res.body) end)
        if not ok or not data then
            retryCount += 1
            publishError("Parse error")
            return
        end
        processPrayerData(data)
    end)
end

local function fetchTomorrowFajr()
    local url = buildUrl(1)
    noctalia.http({ url = url, follow_redirects = true }, function(res)
        if not res.ok or res.body == "" then return end
        local ok, data = pcall(function() return noctalia.json.decode(res.body) end)
        if not ok or not data or data.code ~= 200 then return end
        local timings = data.data and data.data.timings
        if not timings then return end
        local raw = timings["Fajr"]
        if raw then
            local clean = raw:match("^(%d+:%d+)") or raw
            local secs  = parseTime(clean)
            if secs then
                secs = applyTune("Fajr", secs)
                noctalia.state.set("tomorrowFajr", secs)
            end
        end
    end)
end

-- ── Prayer events ─────────────────────────────────────────────────────────────

local cachedPrayers = {}

-- Kills any azan playback in progress. Uses pkill -f matched against the fixed
-- player command names, not the (already validated) file path, so this is safe
-- regardless of azanFile's contents.
local function stopAzan()
    noctalia.runAsync("pkill -f 'paplay.*azan' 2>/dev/null; pkill -f 'pw-cat.*azan' 2>/dev/null || true")
    noctalia.state.set("azanPlaying", false)
end

local function checkPrayerEvents()
    if #cachedPrayers == 0 then return end
    local now = nowSeconds()
    for _, p in ipairs(cachedPrayers) do
        if now >= p.seconds and now < p.seconds + 30 and p.azanPrayer then
            local key   = loadedDate .. "_" .. p.name
            local title = (p.name == "Dhuhr" and isJumuah()) and "Jumu'ah" or p.name

            if showNotifications and lastNotified ~= key then
                lastNotified = key
                noctalia.notify(title .. " prayer time", "It is time for " .. title)
            end

            if playAzan and lastAzanPlayed ~= key then
                lastAzanPlayed = key
                local path = azanPath()
                -- noctalia.fileExists checks safely, no shell interpolation involved.
                if noctalia.fileExists(path) then
                    noctalia.state.set("azanPlaying", true)
                    local cmd
                    if paplayAvailable then
                        cmd = "paplay " .. shellQuote(path) .. " 2>/dev/null"
                    elseif pwcatAvailable then
                        cmd = "pw-cat -p " .. shellQuote(path) .. " 2>/dev/null"
                    else
                        noctalia.log("Mawaqit: no azan player available (install paplay or pw-cat)")
                        noctalia.state.set("azanPlaying", false)
                        return
                    end
                    noctalia.runAsync(cmd, function(_res)
                        noctalia.state.set("azanPlaying", false)
                    end)
                else
                    noctalia.log("Mawaqit: azan file not found: " .. path)
                end
            end
        end
    end
end

noctalia.state.watch("prayers", function(val)
    if type(val) == "table" then cachedPrayers = val end
end)

-- Listen to panel commands via state (cleaner than shell IPC)
noctalia.state.watch("command", function(cmd)
    if type(cmd) ~= "table" then return end
    if cmd.action == "refresh" then onConfigChanged() end
end)

-- ── Main tick ─────────────────────────────────────────────────────────────────

function update()
    local today = todayStr()
    if loadedDate ~= today then
        tomorrowFetched = false
        fetchTimes()
    end
    if loadedDate == today and not tomorrowFetched then
        tomorrowFetched = true
        fetchTomorrowFajr()
    end
    if retryCount > 0 and retryCount <= MAX_RETRIES then
        retryTicks += 1
        if retryTicks >= 6 then
            retryTicks = 0
            fetchTimes()
        end
    end
    checkPrayerEvents()
end

function onConfigChanged()
    noctalia.log("Mawaqit: settings changed, reloading config and refreshing")
    reloadConfig()
    loadedDate    = ""
    retryCount    = 0
    cachedPrayers = {}
    noctalia.state.set("prayers", {})
    fetchTimes()
end

function onIpc(event, _payload)
    if event == "refresh" then
        onConfigChanged()
    end
end

function onExit()
    -- Clean up: stop any playing azan when plugin is disabled or noctalia exits
    stopAzan()
end
