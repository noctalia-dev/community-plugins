--!nonstrict
-- panel.luau — Mawaqit prayer times panel (clean, no azan controls beyond stop)

-- ── State ─────────────────────────────────────────────────────────────────────

local prayers       = {}
local tomorrowFajr  = nil
local hijriDate     = ""
local hijriDateAr   = ""
local gregorianDate = ""
local errorMsg      = ""
local hasData       = false
local hijriMonth    = 0
local hijriYear     = 0
local isJumuah      = false
local sunriseTime   = ""
local imsakTime     = ""
local azanPlaying   = false
local activeTab     = "prayers"
local calendarMonth = 0
local calendarYear  = 0
local calendarKey   = ""
local calendarData  = {}
local calendarStatus = "idle"
local calendarError = ""

local decoFont = noctalia.loadFont("ReemKufi.ttf")

local PRAYER_ICONS = {
    Fajr    = "moon-stars",
    Sunrise = "sunrise",
    Dhuhr   = "sun-high",
    Asr     = "sun-low",
    Maghrib = "sunset",
    Isha    = "moon",
    Imsak   = "moon-off",
}

local ARABIC_NAMES = {
    Fajr    = "الفجر",
    Dhuhr   = "الظهر",
    Asr     = "العصر",
    Maghrib = "المغرب",
    Isha    = "العشاء",
    Imsak   = "الإمساك",
}

local HIJRI_MONTHS = {
    "Muharram", "Safar", "Rabi al-Awwal", "Rabi ath-Thani", "Jumada al-Ula", "Jumada al-Akhira",
    "Rajab", "Shaban", "Ramadan", "Shawwal", "Dhu al-Qadah", "Dhu al-Hijjah",
}
local WEEKDAYS = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
local ISLAMIC_EVENTS = {
    ["1-1"] = { en = "Islamic New Year", ar = "رأس السنة الهجرية" },
    ["1-10"] = { en = "Ashura", ar = "عاشوراء" },
    ["3-12"] = { en = "Mawlid an-Nabi", ar = "المولد النبوي" },
    ["7-27"] = { en = "Isra wal Miraj", ar = "الإسراء والمعراج" },
    ["9-1"] = { en = "Start of Ramadan", ar = "بداية رمضان" },
    ["9-21"] = { en = "Laylat al-Qadr", ar = "ليلة القدر" },
    ["9-23"] = { en = "Laylat al-Qadr", ar = "ليلة القدر" },
    ["9-25"] = { en = "Laylat al-Qadr", ar = "ليلة القدر" },
    ["9-27"] = { en = "Laylat al-Qadr", ar = "ليلة القدر" },
    ["9-29"] = { en = "Laylat al-Qadr", ar = "ليلة القدر" },
    ["10-1"] = { en = "Eid al-Fitr", ar = "عيد الفطر" },
    ["12-9"] = { en = "Day of Arafah", ar = "يوم عرفة" },
    ["12-10"] = { en = "Eid al-Adha", ar = "عيد الأضحى" },
}
local HADITH = {
    { text = "إنما الأعمال بالنيات", source = "البخاري" },
    { text = "المسلم من سلم المسلمون من لسانه ويده", source = "البخاري" },
    { text = "لا يؤمن أحدكم حتى يحب لأخيه ما يحب لنفسه", source = "البخاري" },
    { text = "الطهور شطر الإيمان", source = "مسلم" },
    { text = "خيركم من تعلم القرآن وعلمه", source = "البخاري" },
    { text = "الدين النصيحة", source = "مسلم" },
    { text = "من كان يؤمن بالله واليوم الآخر فليقل خيراً أو ليصمت", source = "البخاري" },
    { text = "البر حسن الخلق", source = "مسلم" },
    { text = "إن الله رفيق يحب الرفق في الأمر كله", source = "البخاري" },
    { text = "الكلمة الطيبة صدقة", source = "البخاري" },
    { text = "خير الناس أنفعهم للناس", source = "الطبراني" },
    { text = "إن الله جميل يحب الجمال", source = "مسلم" },
    { text = "أحب الأعمال إلى الله أدومها وإن قل", source = "البخاري" },
    { text = "اتق الله حيثما كنت", source = "الترمذي" },
    { text = "إن من أحبكم إليّ وأقربكم مني مجلساً يوم القيامة أحاسنكم أخلاقاً", source = "الترمذي" },
    { text = "من صام رمضان إيماناً واحتساباً غُفر له ما تقدم من ذنبه", source = "البخاري" },
    { text = "أفضل الصيام بعد رمضان شهر الله المحرم", source = "مسلم" },
    { text = "ابتغوا ليلة القدر في الوتر من العشر الأواخر من رمضان", source = "البخاري" },
    { text = "تبسمك في وجه أخيك صدقة", source = "الترمذي" },
    { text = "الصلوات الخمس كفارة لما بينهن ما اجتنبت الكبائر", source = "البخاري" },
    { text = "أعوذُ بكلماتِ اللهِ التّامّاتِ مِن شرِّ ما خَلَق", source = "حصن المسلم" },
    { text = "بِسْمِ اللَّهِ الَّذِي لَا يَضُرُّ مَعَ اسْمِهِ شَيْءٌ فِي الْأَرْضِ وَلَا فِي السَّمَاءِ وَهُوَ السَّمِيعُ الْعَلِيمُ", source = "حصن المسلم" },
    { text = "سُبْحَانَ اللهِ وَبِحَمْدِهِ", source = "حصن المسلم" },
    { text = "حَسْبِيَ اللَّهُ لاَ إِلَهَ إِلاَّ هُوَ عَلَيهِ تَوَكَّلْتُ وَهُوَ رَبُّ الْعَرْشِ الْعَظِيمِ", source = "حصن المسلم" },
    { text = "اللَّهُمَّ إِنِّي أَعُوذُ بِكَ مِنَ الْكُفْرِ وَالفَقْرِ وَأَعُوذُ بِكَ مِنْ عَذَابِ القَبْرِ لاَ إِلَهَ إِلاَّ أَنْتَ", source = "حصن المسلم" },
    { text = "الْحَمْدُ لِلَّهِ الَّذِي أَحْيَانَا بَعْدَ مَا أَمَاتَنَا وَإِلَيْهِ النُّشُورُ", source = "حصن المسلم" },
    { text = "بِسْمِ اللهِ تَوَكَّلْتُ عَلَى اللهِ وَلاَ حَوْلَ وَلاَ قُوَّةَ إِلاَّ بِاللهِ", source = "حصن المسلم" },
    { text = "بِسْمِ اللهِ وَالصَّلاَةُ وَالسَّلاَمُ عَلَى رَسُولِ اللهِ اللَّهُمَّ افْتَحْ لِي أَبْوَابَ رَحْمَتِكَ", source = "حصن المسلم" },
    { text = "لاَ إِلَهَ إِلاَّ اللهُ العَظِيمُ الحَلِيمُ لاَ إِلَهَ إِلاَّ اللهُ رَبُّ العَرْشِ العَظِيمِ لاَ إِلَهَ إِلاَّ اللهُ رَبُّ السَّمَاوَاتِ وَرَبُّ الأَرْضِ وَرَبُّ العَرْشِ الكَرِيمِ", source = "حصن المسلم" },
    { text = "اللَّهُمَّ لاَ سَهْلَ إِلاَّ مَا جَعَلْتَهُ سَهْلاً وَأَنْتَ تَجْعَلُ الْحَزْنَ إِذَا شِئْتَ سَهْلاً", source = "حصن المسلم" },
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function nowSeconds()
    local t = os.date("*t")
    return t.hour * 3600 + t.min * 60 + t.sec
end

local function formatCountdown(secs)
    if secs < 0 then secs = 0 end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if h > 0 then return string.format("%dh %02dm %02ds", h, m, s) end
    if m > 0 then return string.format("%dm %02ds", m, s) end
    return string.format("%ds", s)
end

local function findNext()
    if #prayers == 0 then return nil, nil end
    local now = nowSeconds()
    local current = nil
    for _, p in ipairs(prayers) do
        if p.seconds <= now then
            current = p
        else
            if current and now < current.seconds + 300 then return current, 0 end
            return p, p.seconds - now
        end
    end
    if current and now < current.seconds + 300 then return current, 0 end
    if tomorrowFajr then
        return { name = "Fajr", time = prayers[1] and prayers[1].time or "?", seconds = tomorrowFajr },
               (86400 - now) + tomorrowFajr
    end
    return prayers[1], nil
end

local function prayerLabel(name)
    if name == "Dhuhr" and isJumuah then return "Jumu'ah" end
    return name
end

local function accentFor(name)
    if hijriMonth == 9 then
        if name == "Imsak"   then return "secondary" end
        if name == "Maghrib" then return "tertiary"  end
    end
    return "primary"
end

local function calendarRequestKey()
    return tostring(calendarYear) .. "-" .. string.format("%02d", calendarMonth)
end

local function requestCalendar(force)
    if calendarMonth < 1 or calendarYear < 1 then return end
    noctalia.state.set("command", {
        action = "calendar", month = calendarMonth, year = calendarYear, force = force == true,
    })
end

local function weekdayIndex(date)
    local day, month, year = date:match("^(%d+)%-(%d+)%-(%d+)$")
    if not day then return 0 end
    return os.date("*t", os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })).wday - 1
end

local function weekStartDay()
    local value = tonumber(noctalia.getConfig("weekStartDay"))
    if value == 0 or value == 1 or value == 6 then return value end
    return 1
end

local function eventFor(month, day)
    local event = ISLAMIC_EVENTS[tostring(month) .. "-" .. tostring(day)]
    if event then return event end
    if (day == 13 or day == 14 or day == 15) and month ~= 9 and month ~= 10 and month ~= 12 then
        return { en = "Ayyam al-Bid", ar = "أيام البيض" }
    end
    if day == 29 then return { en = "Laylat al-Shakk", ar = "ليلة الشك" } end
    return nil
end

local function currentHijriDay()
    return tonumber(hijriDate:match("^(%d+)")) or 0
end

local function dailyHadith()
    local day = os.date("*t").yday or 1
    return HADITH[(day - 1) % #HADITH + 1]
end

local function upcomingEvent()
    local month, day = hijriMonth, currentHijriDay()
    if month == 0 or day == 0 then return nil end
    local today = eventFor(month, day)
    if today then return today, 0 end
    if isJumuah then return { en = "Friday", ar = "جمعة مباركة" }, 0 end

    for daysAway = 1, 30 do
        day += 1
        local monthLength = month % 2 == 1 and 30 or 29
        if day > monthLength then
            day = 1
            month = month % 12 + 1
        end
        local event = eventFor(month, day)
        if event then return event, daysAway end
    end
    return nil
end

local function calendarView()
    local expectedKey = calendarRequestKey()
    local days = calendarKey == expectedKey and calendarData or {}
    local monthTitle = HIJRI_MONTHS[calendarMonth] or ""
    if calendarMonth < 1 or calendarYear < 1 then
        return ui.column({ align = "center", paddingV = 24 }, {
            ui.label({ text = noctalia.tr("calendar.loading"), color = "on_surface_variant" }),
        })
    end
    local content = {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.button({ glyph = "chevron-left", variant = "ghost", tooltip = noctalia.tr("calendar.previous"), onClick = "onCalendarPrevious" }),
            ui.label({ text = monthTitle .. " " .. tostring(calendarYear), fontSize = 15,
                fontWeight = "semibold", color = calendarMonth == 9 and "primary" or "on_surface" }),
            ui.button({ glyph = "chevron-right", variant = "ghost", tooltip = noctalia.tr("calendar.next"), onClick = "onCalendarNext" }),
        }),
    }

    if calendarMonth ~= hijriMonth or calendarYear ~= hijriYear then
        content[#content + 1] = ui.button({ text = noctalia.tr("calendar.today"), variant = "ghost", onClick = "onCalendarToday" })
    end

    local event, daysAway = upcomingEvent()
    if event then
        local when = daysAway == 0 and noctalia.tr("calendar.today_label")
            or noctalia.tr("calendar.in_days", { days = daysAway })
        content[#content + 1] = ui.label({ text = when .. "  " .. event.ar, fontFamily = decoFont,
            fontSize = 13, color = "tertiary", align = "center" })
    end

    local start = weekStartDay()
    local headers = {}
    for index = 0, 6 do
        local weekday = WEEKDAYS[(start + index) % 7 + 1]
        headers[#headers + 1] = ui.label({ text = weekday, flexGrow = 1, align = "center",
            color = weekday == "Fr" and "primary" or "on_surface_variant", fontSize = 11 })
    end
    content[#content + 1] = ui.row({ gap = 2, align = "center" }, headers)

    if #days == 0 then
        content[#content + 1] = ui.label({
            text = calendarStatus == "error" and calendarError or noctalia.tr("calendar.loading"),
            color = calendarStatus == "error" and "error" or "on_surface_variant", align = "center", paddingV = 24,
        })
        return ui.column({ gap = 8 }, content)
    end

    local first = days[1].gregorian and days[1].gregorian.date or ""
    local leading = (weekdayIndex(first) - start + 7) % 7
    local cells, rows = {}, {}
    for _ = 1, leading do cells[#cells + 1] = ui.spacer({ flexGrow = 1 }) end
    for index, entry in ipairs(days) do
        local day = tonumber(entry.hijri and entry.hijri.day) or index
        local gregorianDay = entry.gregorian and entry.gregorian.day or ""
        local isToday = calendarMonth == hijriMonth and calendarYear == hijriYear and day == currentHijriDay()
        local event = eventFor(calendarMonth, day)
        local text = tostring(day) .. (event and " *" or "") .. (gregorianDay ~= "" and "\n" .. gregorianDay or "")
        cells[#cells + 1] = ui.button({ key = "calendar-" .. expectedKey .. "-" .. day, text = text,
            variant = isToday and "primary" or "ghost", flexGrow = 1, height = 40,
            tooltip = event and event.ar or nil })
        if #cells == 7 then
            rows[#rows + 1] = ui.row({ gap = 2, align = "center" }, cells)
            cells = {}
        end
    end
    while #cells > 0 and #cells < 7 do cells[#cells + 1] = ui.spacer({ flexGrow = 1 }) end
    if #cells > 0 then rows[#rows + 1] = ui.row({ gap = 2, align = "center" }, cells) end
    content[#content + 1] = ui.column({ gap = 2 }, rows)
    if calendarStatus == "loading" then
        content[#content + 1] = ui.label({ text = noctalia.tr("calendar.loading"), fontSize = 11,
            color = "on_surface_variant", align = "center" })
    end
    if calendarMonth == hijriMonth and calendarYear == hijriYear then
        local day = currentHijriDay()
        local lastTenNights = calendarMonth == 9 and day >= 20 and (day ~= 29 or #days == 30)
        if lastTenNights then
            content[#content + 1] = ui.label({
                text = "العشر الأواخر\nأفضل ليالي رمضان، فيها ليلة القدر خير من ألف شهر",
                fontFamily = decoFont, fontSize = 15, color = "primary", align = "center", paddingV = 8,
            })
        else
            local event = eventFor(calendarMonth, day)
            if event then
                content[#content + 1] = ui.label({ text = "* " .. event.ar, fontFamily = decoFont,
                    fontSize = 15, color = "tertiary", align = "center" })
            end
            local hadith = dailyHadith()
            content[#content + 1] = ui.separator({ spacing = 2, color = "outline", opacity = 0.2 })
            content[#content + 1] = ui.label({ text = hadith.text, fontFamily = decoFont,
                fontSize = 13, color = "on_surface", align = "center" })
            content[#content + 1] = ui.label({ text = "- " .. hadith.source, fontSize = 11,
                color = "on_surface_variant", align = "center" })
        end
    end
    return ui.column({ gap = 8 }, content)
end

local function initializeCalendar()
    if activeTab ~= "calendar" or calendarMonth ~= 0 or hijriMonth < 1 or hijriYear < 1 then return end
    calendarMonth, calendarYear = hijriMonth, hijriYear
    requestCalendar(false)
end

-- ── Render ────────────────────────────────────────────────────────────────────

local function render()
    local nextPrayer, secondsToNext = findNext()

    -- ── Header ────────────────────────────────────────────────────────────────
    local header = ui.row({ align = "center", justify = "space_between" }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "building-mosque", size = 18, color = "primary" }),
            ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
        }),
        ui.row({ align = "center", gap = 4 }, {
            azanPlaying and ui.button({
                glyph   = "player-stop-filled",
                variant = "destructive",
                onClick = "onStopAzan",
            }) or ui.button({ glyph = "player-play-filled", variant = "ghost", onClick = "onPreviewAzan" }),
            ui.button({ glyph = "settings", variant = "ghost", onClick = "onSettings" }),
            ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
            ui.button({ glyph = "x",       variant = "ghost", onClick = "onClose"   }),
        }),
    })

    -- ── Date row ──────────────────────────────────────────────────────────────
    local dateRow = nil
    if gregorianDate ~= "" or hijriDate ~= "" then
        local hijriLabel
        if decoFont and decoFont ~= "" and hijriDateAr ~= "" then
            hijriLabel = ui.label({
                text       = hijriDateAr,
                fontSize   = 26,
                fontFamily = decoFont,
                color      = hijriMonth == 9 and "primary" or "secondary",
            })
        else
            hijriLabel = ui.label({
                text       = hijriDate,
                fontSize   = 13,
                fontWeight = "semibold",
                color      = hijriMonth == 9 and "primary" or "secondary",
            })
        end
        dateRow = ui.row({ align = "center", justify = "space_between" }, {
            ui.label({ text = gregorianDate, fontSize = 12, color = "on_surface_variant" }),
            hijriLabel,
        })
    end

    -- ── Countdown banner — plain text, no card ────────────────────────────────
    local banner = nil
    if nextPrayer and secondsToNext then
        local isNow  = secondsToNext <= 60
        local aColor = accentFor(nextPrayer.name)
        local label  = prayerLabel(nextPrayer.name)

        if isNow then
            local arName = ARABIC_NAMES[nextPrayer.name] or nextPrayer.name
            local bannerChildren = {}
            if decoFont and decoFont ~= "" then
                bannerChildren[#bannerChildren+1] = ui.label({
                    text       = "حان الآن موعد صلاة " .. arName,
                    fontSize   = 20,
                    fontFamily = decoFont,
                    color      = aColor,
                })
            end
            bannerChildren[#bannerChildren+1] = ui.label({
                text     = label .. " — " .. noctalia.tr("panel.now"),
                fontSize = 12,
                color    = "on_surface_variant",
            })
            banner = ui.column({ align = "center", gap = 4, paddingV = 6 }, bannerChildren)
        else
            banner = ui.column({ align = "center", gap = 2, paddingV = 6 }, {
                ui.label({ text = label .. " " .. noctalia.tr("panel.in"), fontSize = 12, color = "on_surface_variant" }),
                ui.label({ text = formatCountdown(secondsToNext), fontSize = 26,
                    fontWeight = "bold", color = aColor }),
            })
        end
    elseif not hasData then
        banner = ui.column({ align = "center", paddingV = 6 }, {
            ui.label({
                text  = errorMsg ~= "" and errorMsg or noctalia.tr("panel.loading"),
                fontSize = 13,
                color = errorMsg ~= "" and "error" or "on_surface_variant",
            }),
        })
    end

    -- ── Prayer rows ───────────────────────────────────────────────────────────
    local rows = {}

    -- Imsak (Ramadan only)
    if hijriMonth == 9 and imsakTime ~= "" then
        rows[#rows+1] = ui.row({
            key = "Imsak", align = "center", justify = "space_between",
            paddingH = 12, paddingV = 8,
            fill = "secondary/0.15", radius = 8,
        }, {
            ui.row({ align = "center", gap = 10 }, {
                ui.glyph({ name = "moon-off", size = 14, color = "secondary" }),
                ui.label({ text = "Imsak", fontSize = 14, color = "secondary" }),
            }),
            ui.label({ text = imsakTime, fontSize = 14, color = "secondary" }),
        })
    end

    for _, p in ipairs(prayers) do
        local isNext  = nextPrayer and p.name == nextPrayer.name
        local aColor  = accentFor(p.name)
        local nameClr = isNext and aColor or "on_surface"
        local timeClr = isNext and aColor or "on_surface_variant"
        local weight  = isNext and "semibold" or "normal"
        local icon    = PRAYER_ICONS[p.name] or "sun"
        local label   = prayerLabel(p.name)

        rows[#rows+1] = ui.row({
            key      = p.name,
            align    = "center", justify = "space_between",
            paddingH = 12,
            paddingV = isNext and 10 or 8,
            fill     = isNext and "surface_variant" or nil,
            radius   = isNext and 10 or nil,
        }, {
            ui.row({ align = "center", gap = 10 }, {
                ui.glyph({ name = icon, size = 14, color = nameClr }),
                ui.label({ text = label, fontSize = 14, fontWeight = weight, color = nameClr }),
            }),
            ui.label({ text = p.time, fontSize = 14, fontWeight = weight, color = timeClr }),
        })

        -- Sunrise between Fajr and Dhuhr
        if p.name == "Fajr" and sunriseTime ~= "" then
            rows[#rows+1] = ui.row({
                key = "Sunrise", align = "center", justify = "space_between",
                paddingH = 12, paddingV = 8,
            }, {
                ui.row({ align = "center", gap = 10 }, {
                    ui.glyph({ name = "sunrise", size = 14, color = "on_surface_variant" }),
                    ui.label({ text = noctalia.tr("panel.sunrise"), fontSize = 14, color = "on_surface_variant" }),
                }),
                ui.label({ text = sunriseTime, fontSize = 14, color = "on_surface_variant" }),
            })
        end
    end

    -- ── Assemble ──────────────────────────────────────────────────────────────
    local children = { header }
    if dateRow then children[#children+1] = dateRow end
    children[#children+1] = ui.separator({ spacing = 4, color = "outline", opacity = 0.2 })
    children[#children+1] = ui.row({ gap = 4, align = "center" }, {
        ui.button({ text = noctalia.tr("panel.tabs.prayers"), variant = activeTab == "prayers" and "primary" or "ghost",
            flexGrow = 1, onClick = "onTabPrayers" }),
        ui.button({ text = noctalia.tr("panel.tabs.calendar"), variant = activeTab == "calendar" and "primary" or "ghost",
            flexGrow = 1, onClick = "onTabCalendar" }),
    })
    children[#children+1] = ui.separator({ spacing = 4, color = "outline", opacity = 0.15 })

    if activeTab == "prayers" then
        local prayerContent = {}
        if banner then prayerContent[#prayerContent + 1] = banner end
        if #rows > 0 then prayerContent[#prayerContent + 1] = ui.column({ gap = 1 }, rows) end
        children[#children+1] = ui.scroll({ key = "mawaqit-prayers", flexGrow = 1, gap = 8, align = "stretch" }, prayerContent)
    else
        children[#children+1] = ui.scroll({ key = "mawaqit-calendar", flexGrow = 1, gap = 8, align = "stretch" }, { calendarView() })
    end

    panel.render(ui.column({ flexGrow = 1, gap = 8 }, children))
end

-- ── State watchers ────────────────────────────────────────────────────────────

noctalia.state.watch("prayers", function(val)
    if type(val) == "table" then prayers = val; hasData = #val > 0 end
    render()
end)
noctalia.state.watch("tomorrowFajr", function(val)
    tomorrowFajr = tonumber(val); render()
end)
noctalia.state.watch("hijriDate", function(val)
    if type(val) == "string" then hijriDate = val end; render()
end)
noctalia.state.watch("hijriDateAr", function(val)
    if type(val) == "string" then hijriDateAr = val end; render()
end)
noctalia.state.watch("gregorianDate", function(val)
    if type(val) == "string" then gregorianDate = val end; render()
end)
noctalia.state.watch("hijriMonth", function(val)
    hijriMonth = tonumber(val) or 0; initializeCalendar(); render()
end)
noctalia.state.watch("hijriYear", function(val)
    hijriYear = tonumber(val) or 0; initializeCalendar(); render()
end)
noctalia.state.watch("hijriCalendar", function(val)
    if type(val) == "table" then
        calendarKey = type(val.key) == "string" and val.key or ""
        calendarData = type(val.data) == "table" and val.data or {}
        calendarStatus = type(val.status) == "string" and val.status or "idle"
        calendarError = type(val.error) == "string" and val.error or ""
    end
    render()
end)
noctalia.state.watch("isJumuah", function(val)
    isJumuah = (val == true); render()
end)
noctalia.state.watch("sunriseTime", function(val)
    if type(val) == "string" then sunriseTime = val end; render()
end)
noctalia.state.watch("imsakTime", function(val)
    if type(val) == "string" then imsakTime = val end; render()
end)
noctalia.state.watch("azanPlaying", function(val)
    azanPlaying = (val == true); render()
end)
noctalia.state.watch("error", function(val)
    if type(val) == "string" then errorMsg = val end
    if not hasData then render() end
end)

-- ── Callbacks ─────────────────────────────────────────────────────────────────

function onOpen(_context)
    panel.setWantsSecondTicks(true)
    local p = noctalia.state.get("prayers")
    if type(p) == "table" then prayers = p; hasData = #p > 0 end
    local tf = noctalia.state.get("tomorrowFajr")
    if tf then tomorrowFajr = tonumber(tf) end
    local hd = noctalia.state.get("hijriDate")
    if type(hd) == "string" then hijriDate = hd end
    local hdar = noctalia.state.get("hijriDateAr")
    if type(hdar) == "string" then hijriDateAr = hdar end
    local gd = noctalia.state.get("gregorianDate")
    if type(gd) == "string" then gregorianDate = gd end
    local hm = noctalia.state.get("hijriMonth")
    if hm then hijriMonth = tonumber(hm) or 0 end
    local hy = noctalia.state.get("hijriYear")
    if hy then hijriYear = tonumber(hy) or 0 end
    local jm = noctalia.state.get("isJumuah")
    if jm ~= nil then isJumuah = (jm == true) end
    local sr = noctalia.state.get("sunriseTime")
    if type(sr) == "string" then sunriseTime = sr end
    local im = noctalia.state.get("imsakTime")
    if type(im) == "string" then imsakTime = im end
    local ap = noctalia.state.get("azanPlaying")
    if ap ~= nil then azanPlaying = (ap == true) end
    local calendar = noctalia.state.get("hijriCalendar")
    if type(calendar) == "table" then
        calendarKey = type(calendar.key) == "string" and calendar.key or ""
        calendarData = type(calendar.data) == "table" and calendar.data or {}
        calendarStatus = type(calendar.status) == "string" and calendar.status or "idle"
        calendarError = type(calendar.error) == "string" and calendar.error or ""
    end
    initializeCalendar()
    render()
end

function onClose()   panel.close() end
function onSettings()
    panel.close()
    noctalia.runAsync("noctalia msg settings-open-plugin ycf/mawaqit")
end
function onRefresh()
    if activeTab == "calendar" then requestCalendar(true)
    else noctalia.state.set("command", { action = "refresh" }) end
end

function onTabPrayers()
    activeTab = "prayers"
    render()
end

function onTabCalendar()
    activeTab = "calendar"
    initializeCalendar()
    render()
end

function onCalendarPrevious()
    calendarMonth -= 1
    if calendarMonth < 1 then calendarMonth, calendarYear = 12, calendarYear - 1 end
    requestCalendar(false)
    render()
end

function onCalendarNext()
    calendarMonth += 1
    if calendarMonth > 12 then calendarMonth, calendarYear = 1, calendarYear + 1 end
    requestCalendar(false)
    render()
end

function onCalendarToday()
    calendarMonth, calendarYear = hijriMonth, hijriYear
    requestCalendar(false)
    render()
end

function onStopAzan()
    noctalia.state.set("command", { action = "stopAzan" })
    azanPlaying = false
    noctalia.state.set("azanPlaying", false)
    render()
end

function onPreviewAzan()
    noctalia.state.set("command", { action = "previewAzan" })
end

-- update() is called every second when panel is open (via panel.setWantsSecondTicks)
function update()
    if hasData then render() end
end
