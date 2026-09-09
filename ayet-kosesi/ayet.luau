--!nonstrict

-- Ayet Köşesi
-- A Noctalia desktop widget powered by Akıl Kuran's public
-- /api/daily-verse endpoint.
--
-- 1.5.0 (2026-09):
--   * Gün geçişi düzeltmesi: cache artık GÜN anahtarıyla doğrulanır;
--     gece yarısından sonra ilk poll yeni ayeti çeker (eski ayet takılı kalmaz).
--   * Kopyalama: ayet metnine tıkla → metni kopyala; referans rozetine tıkla →
--     referansı kopyala; paylaşım metni / URL glyph düğmeleri (API 24
--     copyToClipboard — clipboard mime="text/plain").
--   * Manuel yenileme: ↻ düğmesi; seçim zincirini yeniden çözer (helper dahil),
--     20 sn cooldown + in-flight koruması.
--   * Uzun ayet: içerik ui.scroll içinde — 420x260 korunur, metin kaydırılır.
--   * Durum satırı: otomatik/manuel mod · dil · hata/önbellek göstergesi.
--   * Sağlamlaştırma: bozuk logo doğrulanır (boyut), resolve in-flight guard,
--     debounce yalnız KABUL edilen isteği sayar; başarısız istek 90 sn backoff.

local DAILY_API = "https://akilkuran.com/api/daily-verse"
local REGISTRY_API = "https://akilkuran.com/api/meal-registry"
local LOGO_URL = "https://akilkuran.com/apple-touch-icon.png?v=3"

-- Sağlam son fallback: /api/meal-registry de okunamazsa bunu kullan.
-- (Sitenin TR varsayılanı — registry authoritative, bu yalnız son çare.)
local LAST_RESORT_MEAL_ID = 105

-- Önbellek süreleri (saniye):
local REGISTRY_TTL = 3600        -- /api/meal-registry  ~1 saat
local FETCH_DEBOUNCE = 30        -- otomatik istekler arası en az 30 sn
local REFRESH_COOLDOWN = 20      -- manuel yenileme arası en az 20 sn
local REVALIDATE_EVERY = 5       -- her 5. poll'de revalidate penceresi (≈5 dk)
local REVALIDATE_MIN_AGE = 300   -- cache en az 5 dk eskiyse revalidate yapılır
local ERROR_RETRY_AFTER = 90     -- başarısız istekten sonra otomatik bekleme
local HELPER_TTL = 180           -- helper çıktısı 3 dk önbelleği
local NOTICE_SECONDS = 2         -- "Kopyalandı ✓" görünürlüğü

-- ══ DURUM ═════════════════════════════════════════════════════════════════
local verse = nil                -- {surah, number, text, author, url}
local verseMode = nil            -- "automatic" | "manual" (API mode)
local loading = false
local lastReference = nil        -- "13:13"
local lastMealId = nil
local lastLanguage = nil
local cachedDay = nil            -- verse.json'daki gün anahtarı (gün geçişi doğrulaması)
local savedAtClock = nil         -- cache yazım zamanı (revalidate yaş kontrolü)
local lastFetchClock = nil       -- KABUL edilen son istek (debounce/cooldown)
local lastPollClock = nil        -- son gerçek poll (saniye tikleri 60 sn kapısı)
local sonHata = nil              -- son başarısız istek zamanı (backoff)
local errorKind = nil            -- "network"|"http429"|"http503"|"http"|"json"|"invalid"|"start"
local notice = nil               -- geçici geri bildirim metni ("✓ Kopyalandı")
local noticeUntil = nil
local pollCount = 0
local manualPending = false      -- ↻ düğmesi bayrağı
local helperCacheId = nil        -- helper çıktı önbelleği (boş = seçim yok)
local helperCacheAt = nil
local resolveInProgress = false
local mealReadInProgress = false

local dataFile = nil
local logoFile = nil
local logoStateFile = nil
local logoLoading = false
local logoGoster = true
local lastLogoDay = nil

local registry = nil             -- son başarıyla çekilen registry tablosu
local registryFetchedAt = nil    -- os.time() — REGISTRY_TTL için

local render                     -- ileri bildirim: alttaki tanıma kadar nil;
                                 -- refreshLogo + aksiyonlar bu upvalue'yi kullanır

-- ══ YARDIMCILAR ═══════════════════════════════════════════════════════════
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

local function readConfiguredMealId()
    local home = homePath()
    if home == nil then
        return nil
    end

    local path = home .. "/.config/ayet-kosesi/meal-id"
    local raw = noctalia.readFile(path)

    if raw == nil then
        return nil
    end

    local cleaned = tostring(raw):gsub("^%s+", ""):gsub("%s+$", "")
    local id = tonumber(cleaned)

    if id ~= nil and id > 0 then
        return math.floor(id)
    end

    return nil
end

local function systemLanguage()
    -- 1) Noctalia'nın KENDİ UI dili: ~/.local/state/noctalia/settings.toml
    --    [shell] lang = "tr". Process LANG'a göre çok daha güvenilir sinyal —
    --    Noctalia process'i en_US ile başlasa bile kullanıcı arayüzü tr olabilir.
    --    (API 24'te dil getter'ı yok; bu dosya okuması salt-okunur ve yerel.)
    local home = homePath()
    if home ~= nil then
        local raw = noctalia.readFile(
            home .. "/.local/state/noctalia/settings.toml"
        )
        if raw ~= nil then
            local section = nil
            for line in tostring(raw):gmatch("[^\r\n]+") do
                local head = line:match("^%s*%[([^%]]+)%]%s*$")
                if head ~= nil then
                    section = head:gsub("^%s+", ""):gsub("%s+$", "")
                elseif section == "shell" then
                    local lang = line:match(
                        '^%s*lang%s*=%s*"([a-z][a-z])"'
                    )
                    if lang ~= nil then
                        return lang
                    end
                end
            end
        end
    end

    -- 2) Process ortamı (LC_ALL / LC_MESSAGES / LANG)
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

-- ══ MEAL REGISTRY — authoritative mealci listesi (public, anonim) ═════════
-- API 24: noctalia.http GET + json.decode ile. Yanıt ~1 saat cache'lenir;
-- API hatasında eski cache kullanılır, o da yoksa nil (sabit fallback devreder).

local function registryFilePath()
    local dir = dataFile ~= nil and noctalia.pluginDataDir() or nil
    if dir == nil then
        return nil
    end
    return dir .. "/registry.json"
end

local function registryFromDisk()
    local path = registryFilePath()
    if path == nil then
        return nil
    end

    local raw = noctalia.readFile(path)
    if raw == nil then
        return nil
    end

    local decoded = noctalia.json.decode(raw)
    if decoded == nil or decoded.registry == nil then
        return nil
    end

    return decoded
end

local function saveRegistryToDisk()
    local path = registryFilePath()
    if path == nil or registry == nil then
        return
    end

    local encoded = noctalia.json.encode({
        fetchedAt = registryFetchedAt,
        registry = registry,
    })

    if encoded ~= nil then
        noctalia.writeFile(path, encoded)
    end
end

local function registryDefaultFor(language)
    if registry ~= nil then
        local ld = registry.languageDefaults
        if ld ~= nil and ld[language] ~= nil then
            return tonumber(ld[language])
        end
        if registry.default ~= nil then
            return tonumber(registry.default)
        end
    end
    return nil
end

local function isPublicMeal(id)
    if registry == nil or id == nil then
        return false
    end

    local mealciler = registry.mealciler
    if type(mealciler) ~= "table" then
        return false
    end

    for _, m in ipairs(mealciler) do
        if tonumber(m.id) == tonumber(id) and m.public == true then
            return true
        end
    end

    return false
end

local function fetchRegistry(callback)
    local now = os.time()

    -- 1) Bellekte taze cache varsa doğrudan kullan
    if registry ~= nil and registryFetchedAt ~= nil
        and (now - registryFetchedAt) < REGISTRY_TTL then
        callback(true)
        return
    end

    -- 2) Disk cache'i yükle (tazeyse ağ isteği atma)
    if registry == nil then
        local disk = registryFromDisk()
        if disk ~= nil
            and disk.fetchedAt ~= nil
            and (now - tonumber(disk.fetchedAt)) < REGISTRY_TTL then
            registry = disk.registry
            registryFetchedAt = tonumber(disk.fetchedAt)
            callback(true)
            return
        end
    end

    -- 3) Ağdan çek
    local accepted = noctalia.http(
        {
            url = REGISTRY_API,
            method = "GET",
            headers = {
                "Accept: application/json",
            },
        },
        function(response)
            if response.ok
                and response.status >= 200
                and response.status < 300
                and response.body ~= nil then
                local decoded = noctalia.json.decode(response.body)
                if decoded ~= nil and decoded.mealciler ~= nil then
                    registry = decoded
                    registryFetchedAt = now
                    saveRegistryToDisk()
                    callback(true)
                    return
                end
            end

            noctalia.log("Ayet Köşesi meal-registry okunamadı; cache/fallback devrede.")
            callback(false)
        end
    )

    if not accepted then
        noctalia.log("Ayet Köşesi meal-registry isteği başlatılamadı.")
        callback(false)
    end
end

-- ══ SEÇİM ZİNCİRİ (registry authoritative) ════════════════════════════════
-- 1) ~/.config/ayet-kosesi/meal-id            (manuel override)
-- 2) helper: tarayıcı local state → mealOrder[0] (yalnız public ID basar)
-- 3) helper ID / override → registry'de public:true mı? (doğrulama)
-- 4) languageDefaults[language]                (registry'den)
-- 5) registry.default                          (registry'den)
-- 6) LAST_RESORT_MEAL_ID                       (105)
--
-- Helper çıktısı HELPER_TTL boyunca önbelleklenir: normal poll'lerde süreç
-- spawn edilmez. Manuel yenileme force=true ile taze okuma yapar (tarayıcıda
-- yapılan meal değişimini anında yakalar).
local function resolveMealId(callback, force)
    if resolveInProgress then
        return
    end
    resolveInProgress = true

    local function finish(registryOk)
        local language = systemLanguage()
        local configured = readConfiguredMealId()

        if configured ~= nil and (registryOk == false or isPublicMeal(configured)) then
            resolveInProgress = false
            callback(configured, language)
            return
        end

        local home = homePath()
        if home == nil then
            resolveInProgress = false
            callback(registryDefaultFor(language) or LAST_RESORT_MEAL_ID, language)
            return
        end

        -- Helper önbelleği (yalnız otomatik yol; manuel taze okur)
        local now = os.time()
        if not force and helperCacheAt ~= nil
            and (now - helperCacheAt) < HELPER_TTL then
            local id = helperCacheId
            if id ~= nil and registryOk and not isPublicMeal(id) then
                id = nil
            end
            resolveInProgress = false
            callback(id or registryDefaultFor(language) or LAST_RESORT_MEAL_ID, language)
            return
        end

        if mealReadInProgress then
            resolveInProgress = false
            return
        end

        mealReadInProgress = true

        local helper = home .. "/.local/bin/akilkuran-meal-id"
        local accepted = noctalia.runAsync(
            { helper },
            function(result)
                mealReadInProgress = false
                resolveInProgress = false

                local id = nil

                if result ~= nil and result.exitCode == 0 then
                    local out = tostring(result.stdout or "")
                        :gsub("^%s+", "")
                        :gsub("%s+$", "")
                    local parsed = tonumber(out)

                    if parsed ~= nil and parsed > 0 then
                        id = math.floor(parsed)
                    end
                end

                helperCacheId = id
                helperCacheAt = os.time()

                -- helper ID'si whitelist'li çıkıyor; registry'de de doğrula
                if id ~= nil and registryOk and not isPublicMeal(id) then
                    noctalia.log(
                        "Ayet Köşesi helper ID registry'de bulunamadı ("
                        .. tostring(id) .. ") — dil varsayılanına düşülüyor."
                    )
                    id = nil
                end

                callback(id or registryDefaultFor(language) or LAST_RESORT_MEAL_ID, language)
            end
        )

        if not accepted then
            mealReadInProgress = false
            resolveInProgress = false
            callback(registryDefaultFor(language) or LAST_RESORT_MEAL_ID, language)
        end
    end

    -- Önce registry'yi garanti et (cache'liyse anında döner)
    fetchRegistry(finish)
end

-- ══ VERSE CACHE ═══════════════════════════════════════════════════════════
local function saveVerse(key)
    if dataFile == nil or verse == nil then
        return
    end

    local encoded = noctalia.json.encode({
        day = key,
        mealId = lastMealId,
        language = lastLanguage,
        reference = lastReference,
        savedAt = savedAtClock,
        mode = verseMode,
        verse = verse,
    })

    if encoded ~= nil then
        noctalia.writeFile(dataFile, encoded)
    end
end

local function loadCachedVerse()
    if dataFile == nil then
        return
    end

    local raw = noctalia.readFile(dataFile)
    if raw == nil then
        return
    end

    local decoded = noctalia.json.decode(raw)
    if decoded == nil or decoded.verse == nil then
        return
    end

    verse = decoded.verse
    lastMealId = tonumber(decoded.mealId)
    lastLanguage = decoded.language
    lastReference = decoded.reference
    cachedDay = decoded.day
    savedAtClock = tonumber(decoded.savedAt)
    verseMode = decoded.mode

    if lastReference == nil and verse.url ~= nil then
        lastReference = tostring(verse.url):match(
            "akilkuran%.com/(%d+/%d+)"
        )
    end
end

-- ══ LOGO ══════════════════════════════════════════════════════════════════
local function saveLogoState(key)
    if logoStateFile == nil then
        return
    end

    local encoded = noctalia.json.encode({ day = key })
    if encoded ~= nil then
        noctalia.writeFile(logoStateFile, encoded)
    end
end

local function loadLogoState()
    if logoStateFile == nil then
        return
    end

    local raw = noctalia.readFile(logoStateFile)
    if raw == nil then
        return
    end

    local decoded = noctalia.json.decode(raw)
    if decoded ~= nil then
        lastLogoDay = decoded.day
    end
end

-- Logo dosyası gerçekten kullanılabilir mi? (curl exit=0 ama bozuk/boş dosya
-- yazabilir — 500 bayt altı PNG geçersiz sayılır, simgeyle devam edilir.)
local function logoDosyasiSaglam()
    if logoFile == nil then
        return false
    end
    local fi = noctalia.fileInfo(logoFile)
    return fi ~= nil and tonumber(fi.size or 0) > 500
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
                if logoDosyasiSaglam() then
                    logoGoster = true
                    lastLogoDay = key
                    saveLogoState(key)
                else
                    logoGoster = false
                    noctalia.removeFile(logoFile)
                    noctalia.log(
                        "Ayet Köşesi logosu bozuk indirildi; simgeyle devam ediliyor."
                    )
                end
                render()
            else
                noctalia.log(
                    "Ayet Köşesi logosu güncellenemedi; cache korunuyor."
                )
            end
        end
    )

    if not accepted then
        logoLoading = false
    end
end

-- ══ GERİ BİLDİRİM ═════════════════════════════════════════════════════════
-- "Kopyalandı ✓" tarzı geçici mesaj: SAAT BAZLI expiry (noticeUntil), tick
-- sayımına değil. YENİDEN TESPİT (fiziksel test, 2026-09-08): host bu build'de
-- 1Hz update GÖNDERMİYOR — media-lyrics panel.luau'nun "VERIFIED BY PROBE"
-- yorumu setWantsSecondTicks ile update()'in gelmediğini kanıtlıyor; o
-- pluginin tek periyodik sinyali setUpdateInterval. Gerçek temizleme motoru:
-- interval'ı her update'te 1000 ms'e GERİ KUR (yıllık akış: kullanıcı
-- tıklaması yalnız anında render tetikler; döngü onu takip eder). 60 sn'lik
-- normal poll ritmi ZAMAN BAZLI kapıyla korunur — interval kısa olsa bile
-- poll yalnız son poll'dan 60 sn geçince iş yapar, ağ yükü değişmez.
-- Süre dolunca ilk saniyelik update temizler; yeni aksiyon setNotice ile
-- metni değiştirip sayacı yeniden başlatır (tek değişken → bindirme
-- imkânsız). 2 sn içinde bir poll/revalidate gelirse notice'a dokunmaz.
local function setNotice(text)
    notice = tostring(text)
    noticeUntil = os.time() + NOTICE_SECONDS
end

local function clearNotice()
    notice = nil
    noticeUntil = nil
end

-- ══ KULLANICI AKSİYONLARI (global — onClick string hedefleri) ═════════════
function copyVerseAction()
    if verse == nil or verse.text == nil or tostring(verse.text) == "" then
        return
    end
    if noctalia.copyToClipboard(tostring(verse.text), "text/plain") then
        setNotice("✓ Ayet kopyalandı")
        render()
    end
end

function copyShareAction()
    if verse == nil then
        return
    end

    local refMetni = lastReference
    if refMetni == nil then
        refMetni = tostring(verse.surah) .. " " .. tostring(verse.number)
    end

    local metin = "“" .. tostring(verse.text) .. "”\n"
        .. tostring(verse.surah) .. " " .. tostring(refMetni)
        .. " · " .. tostring(verse.author)

    if verse.url ~= nil and tostring(verse.url) ~= "" then
        metin = metin .. "\n" .. tostring(verse.url)
    end

    if noctalia.copyToClipboard(metin, "text/plain") then
        setNotice("✓ Paylaşım metni kopyalandı")
        render()
    end
end

function copyUrlAction()
    if verse == nil or verse.url == nil or tostring(verse.url) == "" then
        return
    end
    if noctalia.copyToClipboard(tostring(verse.url), "text/plain") then
        setNotice("✓ Bağlantı kopyalandı")
        render()
    end
end

function copyReferenceAction()
    if lastReference == nil then
        return
    end
    if noctalia.copyToClipboard(tostring(lastReference), "text/plain") then
        setNotice("✓ " .. tostring(lastReference) .. " kopyalandı")
        render()
    end
end

function manualRefreshAction()
    -- Eski feedback'i temizle (refresh eski notice'ı taşımaz) ve hemen poll.
    -- lastPollClock sıfırlanır: 60 sn kapısı manuel tıklamayı bloklamaz.
    clearNotice()
    lastPollClock = nil
    manualPending = true
    update()
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

-- ══ HATA TÜRLERİ ══════════════════════════════════════════════════════════
-- Kullanıcıya teknik detay boğmadan, kısa ve anlaşılır.
local function errorMetni(kind)
    if kind == "network" then
        return "ağ hatası"
    elseif kind == "http429" then
        return "hız sınırı — biraz bekleyin"
    elseif kind == "http503" then
        return "sunucu meşgul"
    elseif kind == "http" then
        return "API hatası"
    elseif kind == "json" then
        return "yanıt bozuk"
    elseif kind == "invalid" then
        return "yanıt geçersiz"
    elseif kind == "start" then
        return "istek başlatılamadı"
    end
    return nil
end

-- ══ GÜNÜN AYETİ FETCH ═════════════════════════════════════════════════════
local function fetchDailyVerse(key, mealId, language)
    if loading then
        return
    end

    loading = true
    render()

    local url = DAILY_API

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

            if not response.ok
                or response.status < 200
                or response.status >= 300 then
                local st = tonumber(response.status) or 0
                if st == 429 then
                    errorKind = "http429"
                elseif st == 503 then
                    errorKind = "http503"
                elseif st == 0 then
                    errorKind = "network"
                else
                    errorKind = "http"
                end
                sonHata = os.time()
                noctalia.log(
                    "Ayet Köşesi Günün Ayeti API hatası: "
                    .. tostring(response.status)
                )
                render()
                return
            end

            local decoded, err = noctalia.json.decode(response.body)
            if decoded == nil then
                errorKind = "json"
                sonHata = os.time()
                noctalia.log(
                    "Ayet Köşesi API JSON çözülemedi: " .. tostring(err)
                )
                render()
                return
            end

            local data = decoded.data
            if data == nil
                or data.surahId == nil
                or data.verseNum == nil
                or data.translation == nil then
                errorKind = "invalid"
                sonHata = os.time()
                noctalia.log("Ayet Köşesi API beklenen veriyi döndürmedi.")
                render()
                return
            end

            local surahId = tonumber(data.surahId)
            local verseNumber = tonumber(data.verseNum)
            if surahId == nil or verseNumber == nil
                or surahId < 1 or verseNumber < 1 then
                errorKind = "invalid"
                sonHata = os.time()
                noctalia.log("Ayet Köşesi API ayet referansı geçersiz.")
                render()
                return
            end

            local translation = data.translation
            local author = translation.author or {}
            local reference = tostring(data.ref or (
                tostring(surahId) .. ":" .. tostring(verseNumber)
            ))

            verse = {
                surah = tostring(data.surahName or "?"),
                number = verseNumber,
                text = tostring(translation.text or ""),
                author = tostring(translation.authorName or author.name or ""),
                url = tostring(data.url or (
                    "https://akilkuran.com/"
                    .. tostring(surahId)
                    .. "/"
                    .. tostring(verseNumber)
                )),
            }
            verseMode = tostring(data.mode or "")

            lastReference = reference
            lastMealId = tonumber(translation.authorId)
                or tonumber(author.id)
                or mealId
            lastLanguage = tostring(
                translation.language
                    or author.language
                    or language
                    or ""
            )

            -- Gün geçişi doğrulamasının temeli: cache yeni gün anahtarıyla
            -- yazılır. Başarısız isteklerde cachedDay ESKİ kalır, böylece
            -- bir sonraki poll yeniden dener.
            cachedDay = key
            savedAtClock = os.time()
            errorKind = nil
            sonHata = nil
            lastFetchClock = os.time()

            saveVerse(key)
            render()
        end
    )

    if not accepted then
        loading = false
        errorKind = "start"
        sonHata = os.time()
        noctalia.log("Ayet Köşesi Günün Ayeti isteği başlatılamadı.")
        render()
    end
end

-- ══ RENDER ════════════════════════════════════════════════════════════════
render = function()
    local WIDTH = 420
    local HEIGHT = 260

    if verse == nil then
        local durumSatiri = "Akıl Kuran'dan günlük ayet"
        if loading then
            durumSatiri = "Ayet alınıyor…"
        elseif errorKind ~= nil then
            durumSatiri = "Alınamadı: " .. (errorMetni(errorKind) or "bilinmeyen hata")
        end

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
                        text = durumSatiri,
                        fontSize = 15,
                        color = "on_surface",
                        maxWidth = 370,
                    }),
                }
            )
        )
        return
    end

    -- ── Başlık: kitap simgesi + ad + (logo) + "Sure num" ──────────────────
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

    if logoGoster and logoFile ~= nil and logoDosyasiSaglam() then
        table.insert(rightChildren, ui.image({
            path = logoFile,
            width = 24,
            height = 24,
            radius = 6,
        }))
    end

    table.insert(rightChildren, ui.label({
        text = verse.surah .. " " .. tostring(lastReference or verse.number),
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

    -- ── Durum satırı: mod · dil …… notice/hata ─────────────────────────────
    -- RENDER-ZAMANI GATE: notice süresi dolmuşsa SAĞDAKİ update()'i beklemeden
    -- burada temizle (fiziksel test kanıtı: timer yolu gecikebilir/ölabilir;
    -- render anında doğrulama, feedback'in taşmasına karşı son savunma).
    if notice ~= nil and os.time() >= (noticeUntil or 0) then
        notice = nil
        noticeUntil = nil
    end
    -- "Rad 13:13" artık BAŞLIKTA; burada referans tekrarı yok. Notice
    -- ("✓ Kopyalandı") yalnız bu satırın sağında yaşar — ayet alanından
    -- TAMAMEN bağımsız, üzerine binme imkânı yok.
    local durumBilesenleri = {}

    local ortaMetinler = {}
    if verseMode ~= nil and verseMode ~= "" then
        table.insert(ortaMetinler,
            verseMode == "manual" and "manuel" or "otomatik")
    end
    if lastLanguage ~= nil and lastLanguage ~= "" then
        table.insert(ortaMetinler, tostring(lastLanguage))
    end
    if #ortaMetinler > 0 then
        table.insert(durumBilesenleri, ui.label({
            text = table.concat(ortaMetinler, " · "),
            fontSize = 11,
            color = "on_surface_variant",
        }))
    end

    local sagMetin = nil
    local sagRenk = "on_surface_variant"
    if notice ~= nil then
        sagMetin = notice
        sagRenk = "primary"
    elseif loading then
        sagMetin = "yenileniyor…"
    elseif errorKind ~= nil then
        sagMetin = "⚠ " .. (errorMetni(errorKind) or "") .. " · önbellek"
    end
    if sagMetin ~= nil then
        table.insert(durumBilesenleri, ui.label({
            text = sagMetin,
            fontSize = 11,
            color = sagRenk,
            flexGrow = 1,
            textAlign = "end",
        }))
    end

    -- ── Aksiyon satırı: mealci …… [kopyala][paylaş][link][↻][Akıl Kuran'da aç]
    local actionChildren = {
        ui.label({
            text = verse.author,
            fontSize = 12,
            color = "on_surface_variant",
            maxWidth = 140,
            flexGrow = 1,
        }),
        ui.button({
            glyph = "copy",
            glyphSize = 15,
            width = 34,
            height = 30,
            variant = "ghost",
            enabled = not loading,
            onClick = "copyVerseAction",
        }),
        ui.button({
            glyph = "share",
            glyphSize = 15,
            width = 34,
            height = 30,
            variant = "ghost",
            enabled = not loading,
            onClick = "copyShareAction",
        }),
        ui.button({
            glyph = "link",
            glyphSize = 15,
            width = 34,
            height = 30,
            variant = "ghost",
            enabled = not loading,
            onClick = "copyUrlAction",
        }),
        ui.button({
            glyph = "refresh",
            glyphSize = 15,
            width = 34,
            height = 30,
            variant = "ghost",
            enabled = not loading,
            onClick = "manualRefreshAction",
        }),
        ui.button({
            text = "Akıl Kuran'da aç",
            variant = "secondary",
            controlSize = "sm",
            onClick = "openVerse",
        }),
    }

    desktopWidget.render(
        ui.column(
            {
                width = WIDTH,
                height = HEIGHT,
                gap = 6,
                padding = 14,
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

                -- ── AYET ALANI (sadece burası scroll) ─────────────────────
                -- YÜKSEKLIK BÜTÇESİ (260): padding 28 + başlık ~26 + 2×ayraç
                -- ~10 + status ~15 + action 30 + 5×gap 30 ≈ 139 → scroll'a
                -- kalan ~121px. SABİT height KULLANILMAZ: motor scroll'un
                -- height'ını görmezden gelip içeriğe açılıyor (v4/v5 canlı
                -- kanıt; alt kontrolleri ekrandan itti). Upstream'de kanıtlı
                -- tek desen: panel'lerdeki flexGrow=1'li scroll — motor
                -- flexGrow kutusunu kalanla sınırlayıp içeriği kırpar.
                -- onClick scroll'da GEÇERSİZ (dokümante: row/column/box/
                -- image); tıkla-kopyala için sarmalayıcı column taşır.
                ui.column(
                    {
                        onClick = "copyVerseAction",
                        flexGrow = 1,
                        width = 384,
                        align = "stretch",
                        key = "verse-area",
                    },
                    {
                        ui.scroll(
                            { flexGrow = 1, align = "stretch" },
                            {
                                ui.markdown({
                                    text = "**“" .. verse.text .. "”**",
                                    width = 368,
                                }),
                            }
                        ),
                    }
                ),

                ui.row(
                    { gap = 6, align = "center" },
                    durumBilesenleri
                ),

                ui.separator({
                    thickness = 1,
                    color = "outline",
                    spacing = 2,
                }),

                ui.row(
                    {
                        gap = 10,
                        align = "center",
                        justify = "space_between",
                    },
                    actionChildren
                ),
            }
        )
    )
end

-- ══ UPDATE DÖNGÜSÜ ════════════════════════════════════════════════════════
-- (Bu build'de kanıtı: saniye tikleri gelmez; aşağıdaki setUpdateInterval
-- çağrısı HER update'te 1000 ms'e geri kurulur — erken çıkışlar döngüyü
-- asla öldürmez. Gerçek poll işi ZAMAN BAZLI kapıyla 60 sn'de bir kalır.)
desktopWidget.setWantsSecondTicks(true)  -- semantik niyet; zararsız no-op

function update()
    local now = os.time()

    -- 0) DÖNGÜMÜZÜ HER TURDA TAZELE (media-lyrics deseni): güncel interval
    --    hangi daldan çıkarsak çıkalım 1000 ms kalır — notice sırasında bile
    --    saniyelik kalp atışı devam eder.
    noctalia.setUpdateInterval(1000)

    -- 1) Geri bildirim: SAAT dolunca temizle + normal duruma geri çiz.
    --    Pencere içinde ek iş yok (zaten çizildi; tekrar çizim gereksiz).
    if notice ~= nil then
        if now >= (noticeUntil or 0) then
            clearNotice()
            render()
        end
        return
    end

    -- 2) Poll kapısı ZAMAN BAZLI (interval'e değil): gerçek poll ~60 sn'de
    --    bir. Manuel tıklama kapıyı aşar. Interval 1000 ms olsa da bu kapı
    --    sayesinde ağ davranışı eskisiyle birebir aynı kalır.
    local manual = manualPending
    if not manual and (now - (lastPollClock or 0)) < 60 then
        return
    end
    lastPollClock = now

    local key = todayKey()
    pollCount = pollCount + 1

    if dataFile == nil then
        local dir = noctalia.pluginDataDir()

        if dir == nil then
            render()
            return
        end

        dataFile = dir .. "/verse.json"
        logoFile = dir .. "/akilkuran-logo.png"
        logoStateFile = dir .. "/logo.json"

        loadCachedVerse()
        loadLogoState()
        logoGoster = logoDosyasiSaglam()
    end

    if loading then
        render()
        return
    end

    if lastLogoDay ~= key then
        refreshLogo(key)
    end

    -- ── Cache doğrulaması (1.5.0 gün geçişi düzeltmesi) ───────────────────
    -- Cache yalnız AYNI GÜN için geçerli: gece yarısından sonra cachedDay
    -- eskir ve fetch zorunlu hale gelir — eski ayet sonsuza kadar takılmaz.
    local cacheGuncel = (lastReference ~= nil and cachedDay == key)

    local savedAt = tonumber(savedAtClock) or 0
    local revalidateVakti = cacheGuncel
        and (pollCount % REVALIDATE_EVERY) == 0
        and (os.time() - savedAt) >= REVALIDATE_MIN_AGE

    -- ── Hızlı yol: cache güncel + revalidate yok + manuel istek yok →
    --    resolveMealId/helper spawn ETMEDEN çiz ve çık (0 ağ, 0 süreç).
    if cacheGuncel and not revalidateVakti and not manualPending then
        render()
        return
    end

    resolveMealId(function(mealId, language)
        if mealId == nil then
            render()
            return
        end

        local mealAyni = (lastMealId ~= nil
            and tonumber(lastMealId) == tonumber(mealId))
        local now = os.time()

        -- Manuel: 20 sn cooldown (meal değişmişse yine de fetch — niyet net)
        -- Otomatik: 30 sn debounce
        local minGap = manualPending and REFRESH_COOLDOWN or FETCH_DEBOUNCE
        local zamanUygun = (lastFetchClock == nil)
            or ((now - lastFetchClock) >= minGap)

        -- Başarısız istek sonrası otomatik backoff (manuel muaf)
        local backoffDevrede = (errorKind ~= nil and sonHata ~= nil
            and (now - sonHata) < ERROR_RETRY_AFTER)

        local gerekli = (not cacheGuncel) or (not mealAyni) or revalidateVakti

        if manualPending then
            manualPending = false

            if zamanUygun or not mealAyni then
                fetchDailyVerse(key, mealId, language)
            else
                setNotice("Çok sık yenileme — biraz bekleyin")
                render()
            end
            return
        end

        if gerekli and zamanUygun and not backoffDevrede then
            fetchDailyVerse(key, mealId, language)
        else
            render()
        end
    end, manualPending)

    render()
end

update()
