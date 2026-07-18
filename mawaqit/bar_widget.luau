--!nonstrict
-- bar_widget.luau — Mawaqit bar widget
-- Left click  → toggle panel
-- Right click → cycle display mode: countdown → static time → prayer name only

-- ── Config ────────────────────────────────────────────────────────────────────

local showCountdown  = noctalia.getConfig("showCountdown")
local showElapsed    = noctalia.getConfig("showElapsed")
local hidePrayerName = noctalia.getConfig("hidePrayerName")
local widgetIcon     = noctalia.getConfig("widgetIcon")  or "building-mosque"
local dynamicIcon    = noctalia.getConfig("dynamicIcon")
local textColor      = noctalia.getConfig("textColor")   or "on_surface"
local iconColor      = noctalia.getConfig("iconColor")   or "on_surface"
local activeColor    = noctalia.getConfig("activeColor") or "primary"

showCountdown  = (showCountdown  ~= false and showCountdown  ~= "false")
showElapsed    = (showElapsed    == true  or  showElapsed    == "true")
hidePrayerName = (hidePrayerName == true  or  hidePrayerName == "true")
dynamicIcon    = (dynamicIcon    == true  or  dynamicIcon    == "true")

-- ── Constants ─────────────────────────────────────────────────────────────────

local PRAYER_ICONS = {
    Fajr    = "moon-stars",
    Sunrise = "sunrise",
    Dhuhr   = "sun-high",
    Asr     = "sun-low",
    Maghrib = "sunset",
    Isha    = "moon",
}

local MODE_COUNTDOWN = 1
local MODE_STATIC    = 2
local MODE_NAME_ONLY = 3

-- ── State ─────────────────────────────────────────────────────────────────────

local prayers      = {}
local tomorrowFajr = nil
local displayMode  = MODE_COUNTDOWN
local hasData      = false
local errorMsg     = ""
local isJumuah     = false

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
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function formatCountdownShort(secs)
    if secs < 0 then secs = 0 end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    if m > 0 then return string.format("%dm", m) end
    return "soon"
end

local function getIcon(prayerName)
    if dynamicIcon and prayerName and PRAYER_ICONS[prayerName] then
        return PRAYER_ICONS[prayerName]
    end
    return widgetIcon ~= "" and widgetIcon or "building-mosque"
end

local function setColors(isActive)
    if isActive then
        barWidget.setColor(activeColor ~= "" and activeColor or "primary")
        barWidget.setGlyphColor(activeColor ~= "" and activeColor or "primary")
    else
        barWidget.setColor(textColor ~= "" and textColor or "on_surface")
        barWidget.setGlyphColor(iconColor ~= "" and iconColor or "on_surface")
    end
end

local function prayerLabel(name)
    if name == "Dhuhr" and isJumuah then return "Jumu'ah" end
    return name
end

-- ── Prayer logic ──────────────────────────────────────────────────────────────

local function findCurrentPrayer()
    if #prayers == 0 then return nil, nil, nil, nil end
    local now = nowSeconds()
    local currentIdx = nil
    for i, p in ipairs(prayers) do
        if now >= p.seconds then currentIdx = i end
    end

    local nextIdx, secondsToNext, secondsElapsed

    if currentIdx == nil then
        nextIdx        = 1
        secondsToNext  = prayers[1].seconds - now
        secondsElapsed = nil
    elseif currentIdx == #prayers then
        nextIdx        = nil
        secondsElapsed = now - prayers[currentIdx].seconds
        secondsToNext  = tomorrowFajr and (tomorrowFajr + 86400 - now) or nil
    else
        nextIdx        = currentIdx + 1
        secondsToNext  = prayers[nextIdx].seconds - now
        secondsElapsed = now - prayers[currentIdx].seconds
    end

    return currentIdx, nextIdx, secondsToNext, secondsElapsed
end

-- ── Display ───────────────────────────────────────────────────────────────────

local function updateDisplay()
    if not hasData then
        barWidget.setGlyph(widgetIcon ~= "" and widgetIcon or "building-mosque")
        barWidget.setText(errorMsg ~= "" and "!" or "...")
        barWidget.setColor("on_surface")
        barWidget.setGlyphColor("on_surface")
        barWidget.setTooltip(errorMsg ~= "" and errorMsg or noctalia.tr("panel.tooltip.no_data"))
        return
    end

    local currentIdx, nextIdx, secondsToNext, secondsElapsed = findCurrentPrayer()
    local displayPrayer, isActive, timeStr = nil, false, ""

    local showingElapsed = false
    if showElapsed and currentIdx ~= nil and secondsElapsed ~= nil then
        local cap = math.min(3600, secondsToNext or 3600)
        if secondsElapsed >= 0 and secondsElapsed <= cap then
            showingElapsed = true
        end
    end

    if nextIdx ~= nil then
        displayPrayer = prayers[nextIdx].name
        if showingElapsed and currentIdx ~= nil then
            displayPrayer = prayers[currentIdx].name
            isActive = true
            if displayMode == MODE_COUNTDOWN then
                timeStr = "+" .. formatCountdown(secondsElapsed)
            elseif displayMode == MODE_STATIC then
                timeStr = prayers[currentIdx].time
            end
        elseif secondsToNext ~= nil and secondsToNext <= 60 then
            isActive = true
            if displayMode ~= MODE_NAME_ONLY then timeStr = "now" end
        else
            if displayMode == MODE_COUNTDOWN and showCountdown and secondsToNext then
                timeStr = formatCountdown(secondsToNext)
            elseif displayMode == MODE_STATIC then
                timeStr = prayers[nextIdx].time
            end
        end
    else
        displayPrayer = "Fajr"
        if showingElapsed and currentIdx ~= nil then
            isActive = true
            displayPrayer = prayers[currentIdx].name
            if displayMode == MODE_COUNTDOWN then
                timeStr = "+" .. formatCountdown(secondsElapsed)
            elseif displayMode == MODE_STATIC then
                timeStr = prayers[currentIdx].time
            end
        elseif secondsToNext ~= nil then
            if displayMode == MODE_COUNTDOWN and showCountdown then
                timeStr = formatCountdown(secondsToNext)
            elseif displayMode == MODE_STATIC then
                timeStr = tomorrowFajr and prayers[1] and prayers[1].time or "?"
            end
        end
    end

    local nameLabel = prayerLabel(displayPrayer or "")
    local label
    if displayMode == MODE_NAME_ONLY then
        label = nameLabel
    elseif hidePrayerName then
        label = timeStr
    else
        label = timeStr ~= "" and (nameLabel .. "  " .. timeStr) or nameLabel
    end

    barWidget.setGlyph(getIcon(displayPrayer))
    barWidget.setText(label)
    setColors(isActive)

    if nextIdx ~= nil and secondsToNext ~= nil then
        barWidget.setTooltip({
            { key = noctalia.tr("panel.tooltip.next"), value = prayerLabel(prayers[nextIdx].name) },
            { key = noctalia.tr("panel.tooltip.time"), value = prayers[nextIdx].time },
            { key = noctalia.tr("panel.tooltip.in"),   value = formatCountdownShort(secondsToNext) },
        })
    elseif tomorrowFajr ~= nil and secondsToNext ~= nil then
        barWidget.setTooltip({
            { key = noctalia.tr("panel.tooltip.next"), value = noctalia.tr("panel.tooltip.tomorrow_fajr") },
            { key = noctalia.tr("panel.tooltip.in"),   value = formatCountdownShort(secondsToNext) },
        })
    end
end

-- ── State watchers ────────────────────────────────────────────────────────────

noctalia.state.watch("prayers", function(val)
    if type(val) == "table" and #val > 0 then
        prayers  = val
        hasData  = true
        errorMsg = ""
    end
    updateDisplay()
end)

noctalia.state.watch("tomorrowFajr", function(val)
    tomorrowFajr = tonumber(val)
end)

noctalia.state.watch("isJumuah", function(val)
    isJumuah = (val == true)
end)

noctalia.state.watch("error", function(val)
    if type(val) == "string" and val ~= "" then
        errorMsg = val
        if not hasData then updateDisplay() end
    end
end)

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

noctalia.setUpdateInterval(1000)

function update() updateDisplay() end

function onClick()
    noctalia.togglePanel("ycf/mawaqit:panel")
end

function onRightClick()
    if displayMode == MODE_COUNTDOWN then
        displayMode = MODE_STATIC
    elseif displayMode == MODE_STATIC then
        displayMode = MODE_NAME_ONLY
    else
        displayMode = MODE_COUNTDOWN
    end
    updateDisplay()
end

function onIpc(event, payload)
    if event == "refresh" then
        noctalia.state.set("command", { action = "refresh" })
    elseif event == "mode" then
        if     payload == "countdown" then displayMode = MODE_COUNTDOWN
        elseif payload == "static"    then displayMode = MODE_STATIC
        elseif payload == "name"      then displayMode = MODE_NAME_ONLY
        end
        updateDisplay()
    end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

barWidget.setGlyph(widgetIcon ~= "" and widgetIcon or "building-mosque")
barWidget.setText("...")
barWidget.setColor("on_surface")
barWidget.setGlyphColor("on_surface")
barWidget.setTooltip(noctalia.tr("plugin_name"))

local existing = noctalia.state.get("prayers")
if type(existing) == "table" and #existing > 0 then
    prayers = existing
    hasData = true
end
local existingTomorrow = noctalia.state.get("tomorrowFajr")
if existingTomorrow then tomorrowFajr = tonumber(existingTomorrow) end
local existingJumuah = noctalia.state.get("isJumuah")
if existingJumuah ~= nil then isJumuah = (existingJumuah == true) end

updateDisplay()
