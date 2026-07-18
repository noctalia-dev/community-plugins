--!nonstrict
-- panel.luau — Mawaqit prayer times panel (clean, no azan controls)

-- ── State ─────────────────────────────────────────────────────────────────────

local prayers       = {}
local tomorrowFajr  = nil
local hijriDate     = ""
local hijriDateAr   = ""
local gregorianDate = ""
local errorMsg      = ""
local hasData       = false
local hijriMonth    = 0
local isJumuah      = false
local sunriseTime   = ""
local imsakTime     = ""
local azanPlaying   = false

local decoFont = noctalia.loadFont("DecoType.ttf")

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
    for _, p in ipairs(prayers) do
        if p.seconds > now then return p, p.seconds - now end
    end
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
            }) or ui.spacer({ width = 0 }),
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
    if banner  then children[#children+1] = banner  end
    children[#children+1] = ui.separator({ spacing = 4, color = "outline", opacity = 0.15 })
    if #rows > 0 then children[#children+1] = ui.column({ gap = 1 }, rows) end

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
    hijriMonth = tonumber(val) or 0; render()
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
    local jm = noctalia.state.get("isJumuah")
    if jm ~= nil then isJumuah = (jm == true) end
    local sr = noctalia.state.get("sunriseTime")
    if type(sr) == "string" then sunriseTime = sr end
    local im = noctalia.state.get("imsakTime")
    if type(im) == "string" then imsakTime = im end
    local ap = noctalia.state.get("azanPlaying")
    if ap ~= nil then azanPlaying = (ap == true) end
    render()
end

function onClose()   panel.close() end
function onRefresh()
    noctalia.state.set("command", { action = "refresh" })
end

function onStopAzan()
    noctalia.runAsync("pkill -f 'paplay.*azan' 2>/dev/null; pkill -f 'pw-cat.*azan' 2>/dev/null || true")
    azanPlaying = false
    noctalia.state.set("azanPlaying", false)
    render()
end

-- update() is called every second when panel is open (via panel.setWantsSecondTicks)
function update()
    if hasData then render() end
end
