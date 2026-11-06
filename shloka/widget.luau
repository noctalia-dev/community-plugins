-- SPDX-License-Identifier: GPL-3.0-or-later
--!nonstrict

math.randomseed(noctalia.nowMs())

local devanagariFamily: string = (function()
    local family, err = noctalia.loadFont("fonts/TiroDevanagariSanskrit-Regular.ttf")
    if not family then
        noctalia.log("shloka: font load failed: " .. tostring(err))
        return "serif"
    end
    return family
end)()

local t0 = noctalia.nowMs()

local rawJson, readErr = noctalia.readFile("data/gita.json")
local verses: { any } = {}
local dataOk = false

if rawJson then
    local decoded, decodeErr = noctalia.json.decode(rawJson)
    if decoded then
        verses = decoded
        dataOk = true
        noctalia.log(string.format("shloka: loaded %d verses in %.0f ms", #verses, noctalia.nowMs() - t0))
    else
        noctalia.log("shloka: JSON decode error: " .. tostring(decodeErr))
    end
else
    noctalia.log("shloka: readFile error: " .. tostring(readErr))
end

local eligible: { number } = {}
local pos: number = 1
local lastChangeMs: number = noctalia.nowMs()
local lastDayNumber: number = -1
local W, H = 620, 340

local SPEAKERS: { [string]: string } = {
    ["श्रीभगवान्"] = "Shri Krishna",
    ["अर्जुन"] = "Arjuna",
    ["सञ्जय"] = "Sanjaya",
    ["धृतराष्ट्र"] = "Dhritarashtra",
}

local function formatSpeaker(speaker: string, lang: string): string
    if lang == "en" or lang == "none" then
        return SPEAKERS[speaker] or speaker
    end
    return speaker
end

local function gcd(a: number, b: number): number
    while b ~= 0 do
        a, b = b, a % b
    end
    return a
end

local function coprimeStride(n: number, start: number): number
    local s = start
    while gcd(s, n) ~= 1 do
        s += 1
    end
    return s
end

local function dayNumber(): number
    local dt = os.date("*t") :: { year: number, month: number, day: number, [string]: any }
    local noonToday = os.time({ year = dt.year, month = dt.month, day = dt.day, hour = 12, min = 0, sec = 0 })
    return math.floor(noonToday / 86400)
end

local function buildEligible()
    local lang = noctalia.getConfig("language") :: string
    local teachOnly = noctalia.getConfig("teachings_only") :: boolean

    eligible = {}
    for i, v in ipairs(verses) do
        if teachOnly and not v.is_teaching then
            continue
        end
        if lang == "en" and v.en == nil then
            continue
        elseif lang == "hi" and v.hi == nil then
            continue
        elseif lang == "both" and v.en == nil and v.hi == nil then
            continue
        end
        table.insert(eligible, i)
    end
end

local function pickRandom()
    if #eligible == 0 then
        return
    end
    if #eligible == 1 then
        pos = 1
        return
    end
    local newPos = pos
    while newPos == pos do
        newPos = math.random(1, #eligible)
    end
    pos = newPos
end

local function pickDaily()
    if #eligible == 0 then
        return
    end
    local n = #eligible
    local stride = coprimeStride(n, 7919)
    local dn = dayNumber()
    pos = ((dn * stride) % n) + 1
    lastDayNumber = dn
end

local function navigate(delta: number)
    if #eligible == 0 then
        return
    end
    pos = ((pos - 1 + delta) % #eligible) + 1
    lastChangeMs = noctalia.nowMs()
end

local function hasText(s: any): boolean
    return s ~= nil and s ~= ""
end

local function creditLabel(by: string, range: string?, size: number, maxW: number)
    local text = "— " .. by
    if hasText(range) then
        text ..= " (" .. (range :: string) .. ")"
    end
    return ui.label({
        text = text,
        fontSize = size,
        color = "on_surface/0.6",
        textAlign = "center",
        maxWidth = maxW,
    })
end

local function messageState(textKey: string, color: string)
    desktopWidget.render(ui.column({ width = W, height = H, padding = 4, gap = 8, align = "stretch" }, {
        ui.label({ text = noctalia.tr(textKey), color = color, textAlign = "center" }),
    }))
end

local function render()
    local maxW = W - 24

    if not dataOk then
        messageState("load_error", "error")
        return
    end
    if #eligible == 0 then
        messageState("no_verses", "on_surface_variant")
        return
    end

    local v = verses[eligible[pos]]

    local showSanskrit = noctalia.getConfig("show_sanskrit") :: boolean
    local showTranslit = noctalia.getConfig("show_transliteration") :: boolean
    local showReference = noctalia.getConfig("show_reference") :: boolean
    local showCredit = noctalia.getConfig("show_credit") :: boolean
    local showControls = noctalia.getConfig("show_controls") :: boolean
    local lang = noctalia.getConfig("language") :: string
    local fontSize = noctalia.getConfig("font_size") :: number
    local translitSize = math.round(fontSize * 0.6)
    local smallSize = math.round(fontSize * 0.5)
    local tinySize = math.round(fontSize * 0.45)

    local showEn = (lang == "en" or lang == "both") and v.en ~= nil
    local showHi = (lang == "hi" or lang == "both") and v.hi ~= nil

    local scrollChildren: { any } = {}

    if showSanskrit and hasText(v.sanskrit) then
        table.insert(scrollChildren, ui.label({
            text = v.sanskrit,
            fontFamily = devanagariFamily,
            fontSize = fontSize,
            textAlign = "center",
            maxWidth = maxW,
        }))
    end

    if showTranslit and hasText(v.transliteration) then
        table.insert(scrollChildren, ui.label({
            text = v.transliteration,
            fontSize = translitSize,
            color = "on_surface/0.7",
            textAlign = "center",
            maxWidth = maxW,
        }))
    end

    if (showSanskrit or showTranslit) and (showEn or showHi) then
        table.insert(scrollChildren, ui.separator({ spacing = 4 }))
    end

    if showEn then
        table.insert(scrollChildren, ui.label({
            text = v.en,
            fontSize = smallSize,
            textAlign = "center",
            maxWidth = maxW,
        }))
        if showCredit and v.en_by then
            table.insert(scrollChildren, creditLabel(v.en_by, v.en_range, tinySize, maxW))
        end
    end

    if showEn and showHi then
        table.insert(scrollChildren, ui.separator({ spacing = 4 }))
    end

    if showHi then
        table.insert(scrollChildren, ui.label({
            text = v.hi,
            fontFamily = devanagariFamily,
            fontSize = smallSize,
            textAlign = "center",
            maxWidth = maxW,
        }))
        if showCredit and v.hi_by then
            table.insert(scrollChildren, creditLabel(v.hi_by, v.hi_range, tinySize, maxW))
        end
    end

    local parts: { string } = {}
    if showSanskrit and hasText(v.sanskrit) then
        table.insert(parts, v.sanskrit)
    end
    if showTranslit and hasText(v.transliteration) then
        table.insert(parts, v.transliteration)
    end
    if showEn then
        table.insert(parts, v.en)
    end
    if showHi then
        table.insert(parts, v.hi)
    end
    table.insert(parts, string.format("— Bhagavad Gita %d.%d", v.chapter, v.verse))
    local copyText = table.concat(parts, "\n\n")

    local rootChildren: { any } = {}

    if showReference or showControls then
        local headerChildren: { any } = {}

        if showReference then
            table.insert(headerChildren, ui.label({
                text = string.format("%d.%d · %s", v.chapter, v.verse, formatSpeaker(v.speaker, lang)),
                fontSize = tinySize,
                color = "primary",
            }))
        else
            table.insert(headerChildren, ui.spacer({}))
        end

        if showControls then
            table.insert(headerChildren, ui.row({ gap = 4 }, {
                ui.button({
                    glyph = "chevron-left",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = function()
                        navigate(-1)
                        render()
                    end,
                }),
                ui.button({
                    glyph = "copy",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = function()
                    noctalia.copyToClipboard(copyText, "text/plain;charset=utf-8")
                        noctalia.notify(noctalia.tr("copied"))
                    end,
                }),
                ui.button({
                    glyph = "chevron-right",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = function()
                        navigate(1)
                        render()
                    end,
                }),
            }))
        end

        table.insert(rootChildren, ui.row({ align = "center", justify = "space_between" }, headerChildren))
    end

    table.insert(rootChildren, ui.scroll({ flexGrow = 1, align = "stretch", gap = 6 }, scrollChildren))

    desktopWidget.render(ui.column({ width = W, height = H, padding = 4, gap = 8, align = "stretch" }, rootChildren))
end

buildEligible()

if noctalia.getConfig("mode") == "daily" then
    pickDaily()
else
    pos = math.random(1, math.max(1, #eligible))
end
lastChangeMs = noctalia.nowMs()

noctalia.setUpdateInterval(30000)

render()

function update()
    if not dataOk or #eligible == 0 then
        return
    end

    local mode = noctalia.getConfig("mode") :: string
    local refreshMins = noctalia.getConfig("refresh_minutes") :: number
    local now = noctalia.nowMs()

    if mode == "random" then
        if refreshMins > 0 and (now - lastChangeMs) >= refreshMins * 60000 then
            pickRandom()
            lastChangeMs = now
            render()
        end
    elseif mode == "daily" and dayNumber() ~= lastDayNumber then
        pickDaily()
        render()
    end
end
