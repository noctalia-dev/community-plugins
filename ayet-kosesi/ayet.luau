--!nonstrict

-- Ayet Köşesi
-- A Noctalia desktop widget that shows one deterministic daily verse
-- from the public Akıl Kuran API.

local API = "https://akilkuran.com/api/quran/surah/"
local AUTHORS_API = "https://akilkuran.com/api/quran/authors"
local LOGO_URL = "https://akilkuran.com/apple-touch-icon.png?v=3"

local verse = nil
local loading = false
local lastDay = nil
local lastMealId = nil
local lastLanguage = nil

local dataFile = nil

local logoFile = nil
local logoStateFile = nil
local logoLoading = false
local lastLogoDay = nil

local authorsFile = nil
local authors = nil
local authorsLoading = false
local lastAuthorsFetch = 0

local function todayKey()
    return os.date("%Y-%j")
end

local function homePath()
    local home = noctalia.getenv("HOME")
    if home == nil or home == "" then
        return nil
    end
    return home
end

local function mealIdPath()
    local home = homePath()
    if home == nil then
        return nil
    end
    return home .. "/.config/ayet-kosesi/meal-id"
end

local function readMealId()
    local path = mealIdPath()
    if path == nil then
        return nil
    end

    local raw = noctalia.readFile(path)
    if raw == nil then
        return nil
    end

    local id = tonumber(tostring(raw):gsub("^%s+", ""):gsub("%s+$", ""))
    if id ~= nil and id > 0 then
        return math.floor(id)
    end

    return nil
end

local function systemLanguage()
    local names = { "LC_ALL", "LC_MESSAGES", "LANG" }

    for _, name in ipairs(names) do
        local value = noctalia.getenv(name)

        if value ~= nil and value ~= "" then
            value = tostring(value):lower()
            value = value:gsub("%..*$", "")
            value = value:gsub("@.*$", "")
            value = value:gsub("_", "-")

            local lang = value:match("^([a-z][a-z])")
            if lang ~= nil then
                return lang
            end
        end
    end

    return "en"
end

-- Keep sensible defaults for the two languages currently provided by
-- Akıl Kuran's public author catalogue. Other languages are resolved
-- dynamically from the catalogue when available.
local DEFAULT_AUTHOR_BY_LANGUAGE = {
    tr = 105,
    en = 32,
}

local function findAuthorForLanguage(language)
    if authors == nil then
        return nil
    end

    local preferred = DEFAULT_AUTHOR_BY_LANGUAGE[language]

    if preferred ~= nil then
        for _, author in ipairs(authors) do
            if tonumber(author.id) == preferred
                and tostring(author.language or ""):lower() == language then
                return preferred
            end
        end
    end

    for _, author in ipairs(authors) do
        if tostring(author.language or ""):lower() == language then
            local id = tonumber(author.id)

            if id ~= nil and id > 0 then
                return math.floor(id)
            end
        end
    end

    return nil
end

local function saveAuthorsCache()
    if authorsFile == nil or authors == nil then
        return
    end

    local encoded = noctalia.json.encode({
        authors = authors,
        fetchedAt = os.time(),
    })

    if encoded ~= nil then
        noctalia.writeFile(authorsFile, encoded)
    end
end

local function loadAuthorsCache()
    if authorsFile == nil then
        return
    end

    local raw = noctalia.readFile(authorsFile)

    if raw == nil then
        return
    end

    local decoded = noctalia.json.decode(raw)

    if decoded ~= nil and decoded.authors ~= nil then
        authors = decoded.authors
        lastAuthorsFetch = tonumber(decoded.fetchedAt) or 0
    end
end

local fetchVerse

local function fetchAuthors()
    if authorsLoading then
        return
    end

    local now = os.time()

    -- Refresh the author catalogue at most once per day when we have one.
    if authors ~= nil
        and lastAuthorsFetch > 0
        and now - lastAuthorsFetch < 86400 then
        return
    end

    -- Avoid hammering the endpoint when the network is unavailable.
    if lastAuthorsFetch > 0
        and now - lastAuthorsFetch < 600 then
        return
    end

    authorsLoading = true
    lastAuthorsFetch = now

    local accepted = noctalia.http(
        {
            url = AUTHORS_API,
            method = "GET",
            headers = {
                "Accept: application/json",
            },
        },
        function(response)
            authorsLoading = false

            if response.ok
                and response.status >= 200
                and response.status < 300 then

                local decoded = noctalia.json.decode(response.body)

                if decoded ~= nil
                    and decoded.data ~= nil
                    and #decoded.data > 0 then

                    authors = decoded.data
                    saveAuthorsCache()

                    local language = systemLanguage()
                    local mealId = findAuthorForLanguage(language)

                    if mealId ~= lastMealId then
                        fetchVerse(todayKey(), mealId, language)
                    end
                else
                    noctalia.log("Ayet Köşesi author verisi çözülemedi.")
                end
            else
                noctalia.log(
                    "Ayet Köşesi authors HTTP hatası: "
                    .. tostring(response.status)
                )
            end

            render()
        end
    )

    if not accepted then
        authorsLoading = false
    end
end

local function render()
    local WIDTH = 420
    local HEIGHT = 260

    if verse == nil then
        desktopWidget.render(
            ui.column(
                {
                    width = WIDTH,
                    height = HEIGHT,
                    gap = 14,
                    padding = 22,
                    fill = "surface_variant/0.82",
                    radius = 20,
                    justify = "center",
                    align = "stretch",
                },
                {
                    ui.row(
                        { gap = 10, align = "center" },
                        {
                            ui.glyph({
                                name = "book",
                                size = 22,
                                color = "primary",
                            }),
                            ui.label({
                                text = "AYET KÖŞESİ",
                                fontSize = 18,
                                fontWeight = "bold",
                                color = "primary",
                            }),
                        }
                    ),
                    ui.label({
                        text = loading
                            and "Ayet alınıyor…"
                            or "Akıl Kuran'dan günlük ayet",
                        fontSize = 15,
                        color = "on_surface",
                        maxWidth = 370,
                    }),
                }
            )
        )
        return
    end

    local headerChildren = {
        ui.row(
            { gap = 10, align = "center", flexGrow = 1 },
            {
                ui.glyph({
                    name = "book",
                    size = 22,
                    color = "primary",
                }),
                ui.label({
                    text = "AYET KÖŞESİ",
                    fontSize = 18,
                    fontWeight = "bold",
                    color = "primary",
                }),
            }
        ),
    }

    local rightChildren = {}

    if logoFile ~= nil then
        table.insert(rightChildren, ui.image({
            path = logoFile,
            width = 30,
            height = 30,
        }))
    end

    table.insert(rightChildren, ui.label({
        text = verse.surah .. " " .. tostring(verse.number),
        fontSize = 13,
        fontWeight = "bold",
        color = "on_surface_variant",
    }))

    table.insert(
        headerChildren,
        ui.row(
            { gap = 8, align = "center" },
            rightChildren
        )
    )

    desktopWidget.render(
        ui.column(
            {
                width = WIDTH,
                height = HEIGHT,
                gap = 12,
                padding = 20,
                fill = "surface_variant/0.82",
                radius = 20,
                justify = "start",
                align = "stretch",
            },
            {
                ui.row(
                    {
                        gap = 8,
                        align = "center",
                        justify = "space_between",
                    },
                    headerChildren
                ),

                ui.separator({
                    thickness = 1,
                    color = "outline",
                    spacing = 2,
                }),

                ui.markdown({
                    text = "**“" .. verse.text .. "”**",
                    width = 380,
                    height = 135,
                }),

                ui.row(
                    {
                        gap = 10,
                        align = "center",
                        justify = "space_between",
                    },
                    {
                        ui.label({
                            text = verse.author,
                            fontSize = 12,
                            color = "on_surface_variant",
                            maxWidth = 180,
                        }),
                        ui.button({
                            text = "Akıl Kuran'da aç",
                            variant = "secondary",
                            controlSize = "sm",
                            onClick = "openVerse",
                        }),
                    }
                ),
            }
        )
    )
end

local function saveVerse(key, value)
    if dataFile == nil then
        return
    end

    local encoded = noctalia.json.encode({
        day = key,
        mealId = lastMealId,
        language = lastLanguage,
        verse = value,
    })

    if encoded ~= nil then
        noctalia.writeFile(dataFile, encoded)
    end
end

local function saveLogoState(key)
    if logoStateFile == nil then
        return
    end

    local encoded = noctalia.json.encode({ day = key })

    if encoded ~= nil then
        noctalia.writeFile(logoStateFile, encoded)
    end
end

local function useResponse(key, body, mealId, language)
    local decoded, err = noctalia.json.decode(body)

    if decoded == nil then
        noctalia.log("Ayet Köşesi JSON çözülemedi: " .. tostring(err))
        return false
    end

    local data = decoded.data

    if data == nil or data.verses == nil or #data.verses == 0 then
        noctalia.log("Ayet Köşesi verse verisi bulunamadı.")
        return false
    end

    local verses = data.verses
    local y = tonumber(os.date("%Y")) or 0
    local d = tonumber(os.date("%j")) or 1
    local seed = y * 1000 + d
    local index = (seed % #verses) + 1
    local item = verses[index]

    if item == nil or item.translation == nil then
        noctalia.log("Ayet Köşesi çeviri verisi bulunamadı.")
        return false
    end

    local surahId = item.surah_id or data.id
    local verseNumber = item.verse_number or 0

    verse = {
        surah = data.name_translation_tr or data.name or "?",
        number = verseNumber,
        text = item.translation.text or "",
        author = (item.translation.author and item.translation.author.name) or "",
        url = "https://akilkuran.com/"
            .. tostring(surahId)
            .. "/"
            .. tostring(verseNumber),
    }

    lastDay = key
    lastMealId = mealId
    lastLanguage = language

    saveVerse(key, verse)
    return true
end

fetchVerse = function(key, mealId, language)
    if loading then
        return
    end

    loading = true
    language = language or systemLanguage()
    render()

    local year = tonumber(os.date("%Y")) or 0
    local day = tonumber(os.date("%j")) or 1
    local seed = year * 1000 + day
    local surah = (seed % 114) + 1

    local url = API .. tostring(surah)

    if mealId ~= nil and mealId > 0 then
        url = url .. "?author=" .. tostring(mealId)
    end

    local accepted = noctalia.http(
        {
            url = url,
            method = "GET",
            headers = {
                "Accept: application/json",
            },
        },
        function(response)
            loading = false

            if response.ok
                and response.status >= 200
                and response.status < 300 then

                if not useResponse(
                    key,
                    response.body,
                    mealId,
                    language
                ) then
                    noctalia.log(
                        "Ayet Köşesi yanıtı kullanılamadı; cache korunuyor."
                    )
                end
            else
                noctalia.log(
                    "Akıl Kuran HTTP hatası: "
                    .. tostring(response.status)
                )
            end

            render()
        end
    )

    if not accepted then
        loading = false
        noctalia.log("Ayet Köşesi HTTP isteği başlatılamadı.")
        render()
    end
end

local function refreshLogo(key)
    if logoFile == nil or logoLoading then
        return
    end

    logoLoading = true

    local accepted = noctalia.runAsync(
        {
            "curl",
            "-fsSL",
            "--connect-timeout",
            "10",
            "--max-time",
            "20",
            "-o",
            logoFile,
            LOGO_URL,
        },
        function(result)
            logoLoading = false

            if result ~= nil and result.exitCode == 0 then
                lastLogoDay = key
                saveLogoState(key)
                noctalia.log("Ayet Köşesi logosu güncellendi.")
                render()
            else
                noctalia.log(
                    "Ayet Köşesi logosu güncellenemedi; mevcut cache korunuyor."
                )
            end
        end
    )

    if not accepted then
        logoLoading = false
    end
end

function openVerse()
    if verse == nil or verse.url == nil then
        return
    end

    noctalia.runAsync(
        { "xdg-open", verse.url },
        nil
    )
end

function update()
    noctalia.setUpdateInterval(60000)

    local key = todayKey()

    if dataFile == nil then
        local dir = noctalia.pluginDataDir()

        if dir ~= nil then
            dataFile = dir .. "/verse.json"
            logoFile = dir .. "/akilkuran-logo.png"
            logoStateFile = dir .. "/logo.json"
            authorsFile = dir .. "/authors.json"

            local raw = noctalia.readFile(dataFile)

            if raw ~= nil then
                local decoded = noctalia.json.decode(raw)

                if decoded ~= nil and decoded.verse ~= nil then
                    verse = decoded.verse
                    lastDay = decoded.day
                    lastMealId = tonumber(decoded.mealId)
                    lastLanguage = decoded.language
                end
            end

            loadAuthorsCache()

            local logoRaw = noctalia.readFile(logoStateFile)

            if logoRaw ~= nil then
                local logoDecoded = noctalia.json.decode(logoRaw)

                if logoDecoded ~= nil then
                    lastLogoDay = logoDecoded.day
                end
            end
        end
    end

    local newDay = lastDay ~= key
    local language = systemLanguage()
    local explicitMealId = readMealId()
    local logoNeedsRefresh = lastLogoDay ~= key

    if logoNeedsRefresh then
        refreshLogo(key)
    end

    -- A local meal-id file is an explicit user choice and wins over
    -- automatic language detection.
    if explicitMealId ~= nil then
        local mealChanged = explicitMealId ~= lastMealId
        local languageChanged = language ~= lastLanguage

        if verse == nil
            or newDay
            or mealChanged
            or languageChanged then
            fetchVerse(key, explicitMealId, language)
            return
        end

        render()
        return
    end

    -- No explicit meal: resolve a translation from the system language.
    if authors == nil then
        loadAuthorsCache()
    end

    if authors == nil then
        fetchAuthors()

        if verse == nil or newDay then
            render()
        end

        return
    end

    local mealId = findAuthorForLanguage(language)

    local mealChanged = mealId ~= lastMealId
    local languageChanged = language ~= lastLanguage

    if verse == nil
        or newDay
        or mealChanged
        or languageChanged then
        fetchVerse(key, mealId, language)
        return
    end

    fetchAuthors()
    render()
end

update()
