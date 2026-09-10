--!nonstrict
-- service.luau — Mawaqit background fetcher

noctalia.setUpdateInterval(5000)

-- ── Config ────────────────────────────────────────────────────────────────────

local city, country, method, school, hijriDayOffset, fajrAngle, ishaAngle
local tune, tuneFajr, tuneDhuhr, tuneAsr, tuneMaghrib, tuneIsha
local showNotifications, playAzan, azanFile, twelveHourFormat

-- Safely quotes strings for shell execution to prevent injection.
local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Escapes POSIX ERE metacharacters so a path can be used as a `pkill -f`
-- pattern without accidentally behaving as a regex.
local function ereEscape(s)
    return (s:gsub("([%.%*%+%?%(%)%[%]%^%$|\\{}])", "\\%1"))
end

local function reloadConfig()
    local c_city              = noctalia.getConfig("city")
    local c_country           = noctalia.getConfig("country")
    local c_method            = noctalia.getConfig("method")
    local c_school            = noctalia.getConfig("school")
    local c_hijriDayOffset    = noctalia.getConfig("hijriDayOffset")
    local c_fajrAngle         = noctalia.getConfig("fajrAngle")
    local c_ishaAngle         = noctalia.getConfig("ishaAngle")
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

    local function validAngle(value)
        local angle = tonumber(value)
        if angle and angle == angle and angle > 0 and angle < 90 then
            return tostring(angle)
        end
        return nil
    end

    fajrAngle         = validAngle(c_fajrAngle)
    ishaAngle         = validAngle(c_ishaAngle)
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
local PRAYER_ARABIC = {
    Fajr = "الفجر", Dhuhr = "الظهر", Jumuah = "الجمعة", Asr = "العصر", Maghrib = "المغرب", Isha = "العشاء",
}

local loadedDate      = ""
local fetchPending    = false
local retryCount      = 0
local retryAt         = 0
local tomorrowFetched = false
local lastNotified    = ""
local lastAzanPlayed  = ""
local playingAzanPath = ""  -- absolute path of the azan file currently playing, if any
local azanGeneration  = 0
local RETRY_DELAYS    = { 5, 10, 15, 30, 60 }
local CALENDAR_CACHE_TTL = 30 * 24 * 60 * 60
local CALENDAR_CACHE_LIMIT = 24
local calendarFetchPending = false
local queuedCalendarRequest = nil

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

-- Formats a time-of-day value after applying a local offset. Display wraps at
-- midnight while the unwrapped value remains available for event scheduling.
local function formatAdjustedTime(secs)
    local timeOfDay = secs % 86400
    local h = math.floor(timeOfDay / 3600)
    local m = math.floor((timeOfDay % 3600) / 60)
    return formatDisplayTime(string.format("%02d:%02d", h, m))
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
    local url = string.format(
        "https://api.aladhan.com/v1/timingsByCity/%s?city=%s&country=%s&method=%s&school=%s",
        dateStr,
        noctalia.string.urlEncode(city),
        noctalia.string.urlEncode(country),
        method, school
    )
    if method == "99" then
        local settings = (fajrAngle or "null") .. ",null," .. (ishaAngle or "null")
        url ..= "&methodSettings=" .. noctalia.string.urlEncode(settings)
    end
    return url
end

local function buildCalendarUrl()
    local today = os.date("*t")
    local url = string.format(
        "https://api.aladhan.com/v1/calendarByCity/%d/%02d?city=%s&country=%s&method=%s&school=%s",
        today.year, today.month,
        noctalia.string.urlEncode(city),
        noctalia.string.urlEncode(country),
        method, school
    )
    if method == "99" then
        local settings = (fajrAngle or "null") .. ",null," .. (ishaAngle or "null")
        url ..= "&methodSettings=" .. noctalia.string.urlEncode(settings)
    end
    return url
end

local function calendarCacheKey()
    local today = os.date("*t")
    return table.concat({
        city, country, method, school, fajrAngle or "", ishaAngle or "",
        tostring(today.year), tostring(today.month),
    }, "\0")
end

local function calendarCachePath()
    local dir, err = noctalia.pluginDataDir()
    if not dir then
        noctalia.log("Mawaqit: cache unavailable: " .. tostring(err))
        return nil
    end
    return dir .. "/prayer-calendar.json"
end

local function saveCalendarCache(data)
    if type(data.data) ~= "table" or data.data[1] == nil then return end
    local path = calendarCachePath()
    if not path then return end

    local encoded, err = noctalia.json.encode({
        version = 1,
        key = calendarCacheKey(),
        fetchedAt = os.time(),
        calendar = data,
    }, true)
    if not encoded then
        noctalia.log("Mawaqit: failed to encode calendar cache: " .. tostring(err))
        return
    end

    local written, writeErr = noctalia.writeFile(path .. ".tmp", encoded)
    if not written then
        noctalia.log("Mawaqit: failed to write calendar cache: " .. tostring(writeErr))
        return
    end
    local renamed, renameErr = noctalia.renameFile(path .. ".tmp", path)
    if not renamed then
        noctalia.log("Mawaqit: failed to finalize calendar cache: " .. tostring(renameErr))
    end
end

local function loadCalendarCache()
    local path = calendarCachePath()
    if not path then return nil end
    local raw, readErr = noctalia.readFile(path)
    if not raw then
        if readErr then noctalia.log("Mawaqit: failed to read calendar cache: " .. tostring(readErr)) end
        return nil
    end
    local cached, decodeErr = noctalia.json.decode(raw)
    if type(cached) ~= "table" then
        noctalia.log("Mawaqit: invalid calendar cache: " .. tostring(decodeErr))
        return nil
    end
    if cached.version ~= 1 or cached.key ~= calendarCacheKey() or type(cached.calendar) ~= "table" then
        return nil
    end
    return cached.calendar
end

local function hijriCalendarCachePath()
    local dir, err = noctalia.pluginDataDir()
    if not dir then
        noctalia.log("Mawaqit: calendar cache unavailable: " .. tostring(err))
        return nil
    end
    return dir .. "/hijri-calendars.json"
end

local function hijriCalendarKey(year, month)
    return tostring(year) .. "-" .. string.format("%02d", month)
end

local function readHijriCalendarCache()
    local path = hijriCalendarCachePath()
    if not path then return { version = 1, months = {} }, nil end
    local raw = noctalia.readFile(path)
    if not raw then return { version = 1, months = {} }, path end
    local cache, err = noctalia.json.decode(raw)
    if type(cache) ~= "table" or cache.version ~= 1 or type(cache.months) ~= "table" then
        noctalia.log("Mawaqit: invalid Hijri calendar cache: " .. tostring(err))
        return { version = 1, months = {} }, path
    end
    return cache, path
end

local function writeHijriCalendarCache(cache, path)
    if not path then return end
    local encoded, err = noctalia.json.encode(cache, true)
    if not encoded then
        noctalia.log("Mawaqit: failed to encode Hijri calendar cache: " .. tostring(err))
        return
    end
    local written, writeErr = noctalia.writeFile(path .. ".tmp", encoded)
    if not written then
        noctalia.log("Mawaqit: failed to write Hijri calendar cache: " .. tostring(writeErr))
        return
    end
    local renamed, renameErr = noctalia.renameFile(path .. ".tmp", path)
    if not renamed then
        noctalia.log("Mawaqit: failed to finalize Hijri calendar cache: " .. tostring(renameErr))
    end
end

local function cachedHijriCalendar(year, month)
    local cache, _path = readHijriCalendarCache()
    local entry = cache.months[hijriCalendarKey(year, month)]
    if type(entry) ~= "table" or type(entry.fetchedAt) ~= "number" or type(entry.data) ~= "table" then
        return nil, 0, false
    end
    return entry.data, entry.fetchedAt, os.time() - entry.fetchedAt <= CALENDAR_CACHE_TTL
end

local function saveHijriCalendar(year, month, data)
    local cache, path = readHijriCalendarCache()
    if not path then return end
    local now = os.time()
    cache.months[hijriCalendarKey(year, month)] = { fetchedAt = now, data = data }

    local entries = {}
    for key, entry in pairs(cache.months) do
        if type(entry) ~= "table" or type(entry.fetchedAt) ~= "number" or type(entry.data) ~= "table" then
            cache.months[key] = nil
        else
            entries[#entries + 1] = { key = key, fetchedAt = entry.fetchedAt }
        end
    end
    table.sort(entries, function(a, b) return a.fetchedAt > b.fetchedAt end)
    for index = CALENDAR_CACHE_LIMIT + 1, #entries do
        cache.months[entries[index].key] = nil
    end
    writeHijriCalendarCache(cache, path)
end

-- Resolves the bundled azan file's absolute path from this plugin's own
-- install directory (works for git-source and path-source installs alike).
local function azanPath()
    local pluginDir = noctalia.pluginDir()
    if type(pluginDir) ~= "string" or pluginDir == "" then
        noctalia.log("Mawaqit: could not resolve plugin directory for azan playback")
        return ""
    end
    local safe = azanFile:match("^[%w%.%-_]+$") and azanFile or "azan1.mp3"
    return pluginDir .. "/assets/" .. safe
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

    local entry = data.data
    if type(entry) == "table" and entry.timings == nil then
        local today = dateParam(0)
        for _, candidate in ipairs(entry) do
            local gregorian = candidate.date and candidate.date.gregorian
            if gregorian and gregorian.date == today then
                entry = candidate
                break
            end
        end
        if entry.timings == nil then entry = entry[1] end
    end

    local timings = entry and entry.timings
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
                    time       = formatAdjustedTime(secs),
                    seconds    = secs,
                    azanPrayer = AZAN_PRAYERS[i],
                }
            end
        end
    end

    -- Imsak (Ramadan only)
    local imsakRaw  = timings["Imsak"]
    local imsakClean = imsakRaw and (imsakRaw:match("^(%d+:%d+)") or imsakRaw)
    local imsakTime = imsakClean and formatDisplayTime(imsakClean) or ""
    local imsakSeconds = imsakClean and parseTime(imsakClean) or 0

    -- Sunrise (display only, not a prayer)
    local sunriseRaw  = timings["Sunrise"]
    local sunriseTime = sunriseRaw and formatDisplayTime(sunriseRaw:match("^(%d+:%d+)") or sunriseRaw) or ""

    -- Hijri date
    local hijri = entry.date and entry.date.hijri
    local greg  = (entry.date and entry.date.readable) or ""
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
    noctalia.state.set("imsakSeconds",  hijriMonth == 9 and imsakSeconds or 0)
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
    retryAt        = 0

    noctalia.log("Mawaqit: loaded " .. #prayers .. " prayers for " .. city .. ", " .. country
        .. " hijriMonth=" .. hijriMonth)
    return true
end

local function loadCachedCalendar()
    local cached = loadCalendarCache()
    if cached and processPrayerData(cached) then
        noctalia.log("Mawaqit: loaded prayer times from calendar cache")
        return true
    end
    return false
end

local function scheduleRetry()
    if retryCount >= #RETRY_DELAYS then
        noctalia.log("Mawaqit: retry limit reached")
        return
    end
    local delay = RETRY_DELAYS[retryCount + 1]
    retryCount += 1
    retryAt = os.time() + delay
    noctalia.log("Mawaqit: retry " .. retryCount .. " in " .. delay .. " seconds")
end

local fetchTimes

local function handleFetchFailure(message, fallback)
    if message then publishError(message) end
    if not fallback then
        noctalia.log("Mawaqit: calendar request failed, falling back to a single-day request")
        fetchTimes(true)
    else
        loadCachedCalendar()
        scheduleRetry()
    end
end

fetchTimes = function(fallback)
    if fetchPending then return end
    reloadConfig()
    fetchPending = true
    local url = fallback and buildUrl(0) or buildCalendarUrl()
    noctalia.log("Mawaqit: fetching " .. url)
    local accepted = noctalia.http({ url = url, follow_redirects = true }, function(res)
        fetchPending = false
        if not res.ok or res.body == "" then
            handleFetchFailure("Network error (status=" .. tostring(res.status) .. ")", fallback)
            return
        end
        local ok, data = pcall(function() return noctalia.json.decode(res.body) end)
        if not ok or not data then
            handleFetchFailure("Parse error", fallback)
            return
        end
        if processPrayerData(data) then
            if not fallback then saveCalendarCache(data) end
        else
            handleFetchFailure(nil, fallback)
        end
    end)
    if accepted == false then
        fetchPending = false
        handleFetchFailure("Network request rejected", fallback)
    end
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

local requestHijriCalendar

local function publishHijriCalendar(year, month, status, data, fetchedAt, error)
    noctalia.state.set("hijriCalendar", {
        key = hijriCalendarKey(year, month),
        status = status,
        data = data or {},
        fetchedAt = fetchedAt or 0,
        error = error or "",
    })
end

local function drainCalendarQueue(year, month)
    local queued = queuedCalendarRequest
    queuedCalendarRequest = nil
    if queued and (queued.year ~= year or queued.month ~= month or queued.force) then
        requestHijriCalendar(queued.year, queued.month, queued.force)
    end
end

requestHijriCalendar = function(year, month, force)
    year = tonumber(year)
    month = tonumber(month)
    if not year or not month or year < 1 or month < 1 or month > 12 then
        noctalia.log("Mawaqit: invalid Hijri calendar request")
        return
    end
    year, month = math.floor(year), math.floor(month)

    if calendarFetchPending then
        queuedCalendarRequest = { year = year, month = month, force = force == true }
        return
    end

    local cached, fetchedAt, fresh = cachedHijriCalendar(year, month)
    if cached and fresh and not force then
        publishHijriCalendar(year, month, "ready", cached, fetchedAt)
        return
    end

    publishHijriCalendar(year, month, "loading", cached or {}, fetchedAt)
    calendarFetchPending = true
    local url = "https://api.aladhan.com/v1/hToGCalendar/" .. month .. "/" .. year
    local accepted = noctalia.http({ url = url, follow_redirects = true }, function(res)
        calendarFetchPending = false
        if res.ok and res.body ~= "" then
            local ok, data = pcall(function() return noctalia.json.decode(res.body) end)
            if ok and data and data.code == 200 and type(data.data) == "table" then
                saveHijriCalendar(year, month, data.data)
                publishHijriCalendar(year, month, "ready", data.data, os.time())
            else
                publishHijriCalendar(year, month, "error", cached or {}, fetchedAt, "Calendar data unavailable")
            end
        else
            publishHijriCalendar(year, month, "error", cached or {}, fetchedAt, "Calendar request failed")
        end

        drainCalendarQueue(year, month)
    end)
    if accepted == false then
        calendarFetchPending = false
        publishHijriCalendar(year, month, "error", cached or {}, fetchedAt, "Calendar request rejected")
        drainCalendarQueue(year, month)
    end
end

-- ── Azan playback ─────────────────────────────────────────────────────────────

-- Kills azan playback in progress. Matches on the exact absolute path this
-- plugin passed to paplay/pw-cat (tracked in playingAzanPath), not a generic
-- substring — so it can't touch an unrelated process that happens to share
-- part of that path. This is an interim measure: runAsync doesn't return a
-- PID, so command-line matching is the only way to terminate a detached
-- process with the current API.
local function stopAzan()
    azanGeneration += 1
    if playingAzanPath ~= "" then
        local pattern = shellQuote(ereEscape(playingAzanPath))
        noctalia.runAsync("pkill -f -- " .. pattern .. " 2>/dev/null || true")
        playingAzanPath = ""
    end
    noctalia.state.set("azanPlaying", false)
end

local function startAzan()
    stopAzan()
    local path = azanPath()
    if path == "" or not noctalia.fileExists(path) then
        if path ~= "" then noctalia.log("Mawaqit: azan file not found: " .. path) end
        return false
    end

    local cmd
    if paplayAvailable then
        cmd = "paplay " .. shellQuote(path) .. " 2>/dev/null"
    elseif pwcatAvailable then
        cmd = "pw-cat -p " .. shellQuote(path) .. " 2>/dev/null"
    else
        noctalia.log("Mawaqit: no azan player available (install paplay or pw-cat)")
        return false
    end

    azanGeneration += 1
    local generation = azanGeneration
    playingAzanPath = path
    noctalia.state.set("azanPlaying", true)
    local finished = "noctalia msg plugin " .. shellQuote("ycf/mawaqit:fetcher")
        .. " all azan-finished " .. generation .. " >/dev/null 2>&1"
    local launched = noctalia.runAsync("(" .. cmd .. "; " .. finished .. ") &")
    if not launched then
        playingAzanPath = ""
        noctalia.state.set("azanPlaying", false)
        return false
    end
    return true
end

local function previewAzan()
    reloadConfig()
    if not startAzan() then
        noctalia.notify("Mawaqit Azan preview", "Selected azan file or audio player is unavailable")
    end
end

-- ── Prayer events ─────────────────────────────────────────────────────────────

local cachedPrayers = {}
local cachedImsakSeconds = 0
local cachedHijriMonth = 0
local cachedImsakTime = ""

local function checkPrayerEvents()
    local now = nowSeconds()

    if cachedHijriMonth == 9 and cachedImsakSeconds > 0
        and now >= cachedImsakSeconds and now < cachedImsakSeconds + 30 then
        local key = loadedDate .. "_Imsak"
        if showNotifications and lastNotified ~= key then
            lastNotified = key
            noctalia.notify("Imsak - " .. cachedImsakTime, "حان وقت الإمساك")
        end
    end

    for _, p in ipairs(cachedPrayers) do
        if now >= p.seconds and now < p.seconds + 30 and p.azanPrayer then
            local key   = loadedDate .. "_" .. p.name
            local title = (p.name == "Dhuhr" and isJumuah()) and "Jumu'ah" or p.name
            local arabicName = p.name == "Dhuhr" and isJumuah() and PRAYER_ARABIC.Jumuah or PRAYER_ARABIC[p.name]

            if showNotifications and lastNotified ~= key then
                lastNotified = key
                noctalia.notify(title .. " - " .. p.time, "حان الآن موعد صلاة " .. (arabicName or title))
            end

            if playAzan and lastAzanPlayed ~= key then
                lastAzanPlayed = key
                startAzan()
            end
        end
    end
end

noctalia.state.watch("prayers", function(val)
    if type(val) == "table" then cachedPrayers = val end
end)

noctalia.state.watch("imsakSeconds", function(val)
    cachedImsakSeconds = tonumber(val) or 0
end)

noctalia.state.watch("imsakTime", function(val)
    cachedImsakTime = type(val) == "string" and val or ""
end)

noctalia.state.watch("hijriMonth", function(val)
    cachedHijriMonth = tonumber(val) or 0
end)

-- Listen to panel commands via state (cleaner than shell IPC)
noctalia.state.watch("command", function(cmd)
    if type(cmd) ~= "table" then return end
    if cmd.action == "refresh" then onConfigChanged()
    elseif cmd.action == "stopAzan" then stopAzan()
    elseif cmd.action == "previewAzan" then previewAzan()
    elseif cmd.action == "calendar" then requestHijriCalendar(cmd.year, cmd.month, cmd.force)
    end
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
    if retryAt > 0 and os.time() >= retryAt then
        retryAt = 0
        fetchTimes()
    end
    checkPrayerEvents()
end

function onConfigChanged()
    noctalia.log("Mawaqit: settings changed, reloading config and refreshing")
    reloadConfig()
    loadedDate    = ""
    retryCount    = 0
    retryAt       = 0
    cachedPrayers = {}
    noctalia.state.set("prayers", {})
    noctalia.state.set("imsakSeconds", 0)
    noctalia.state.set("hijriMonth", 0)
    fetchTimes()
end

function onIpc(event, payload)
    if event == "refresh" then
        onConfigChanged()
    elseif event == "preview-azan" then
        previewAzan()
    elseif event == "azan-finished" and tonumber(payload) == azanGeneration then
        playingAzanPath = ""
        noctalia.state.set("azanPlaying", false)
    end
end

function onExit()
    -- Clean up: stop any playing azan when plugin is disabled or noctalia exits
    stopAzan()
end

loadCachedCalendar()
fetchTimes()
