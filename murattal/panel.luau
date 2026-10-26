--!nonstrict
-- Murattal panel: three tabs.
--   "Surah"     — simple per-surah playback (mp3quran).
--   "Per Ayah"  — per-ayah playback (EveryAyah) with Arabic text + translation.
--   "Favorit"   — saved surah/qari pairs.
-- Advanced controls live behind the "Opsi" button so the default view stays simple.
local ready = false
local render

local reciters = noctalia.state.get("quran_reciters") or {}
local surahs = noctalia.state.get("quran_surahs") or {}
local everyayah = noctalia.state.get("quran_everyayah") or {}
local ayahCounts = noctalia.state.get("quran_ayah_counts") or {}
local rewayas = noctalia.state.get("quran_rewayas") or {}
local juzList = noctalia.state.get("quran_juz") or {}
local cacheMap = noctalia.state.get("quran_cache") or {}
local status = noctalia.state.get("quran_status") or {
  playing = false, name = "", reciterId = "", surahId = 1, volume = 65, url = "",
  cached = false, repeatOne = false, repeatCount = 1, repeatDone = 0, shuffle = false,
  speed = 1.0, sleepUntil = 0, position = 0, duration = 0,
  queue = {}, queueIndex = 0, juz = 0, downloading = {},
  mode = "surah", ayah = 1, ayahCount = 0, everyayahId = "",
}
local favorites = noctalia.state.get("quran_favorites") or {}

local dataDir = noctalia.pluginDataDir()
local favPath = dataDir .. "/favorites.json"
local textDir = dataDir .. "/text"

local showTranslation = noctalia.getConfig("show_translation") ~= false
local showLatin = noctalia.getConfig("show_latin") == true

local arabicFont
do
  local ok, family = pcall(function()
    return noctalia.loadFont("/usr/share/fonts/noto/NotoNaskhArabic-Regular.ttf")
  end)
  if ok and family then arabicFont = family end
end

local TEXT_PER_PAGE = 20

local activeTab = "surah"
local optionsOpen = false
local textCache, textLoading, textError = {}, {}, {}
local textPage = 1
local lastFollowAyah = nil

local qariOpen, surahOpen, everyayahOpen = false, false, false
local qariQuery, surahQuery, everyayahQuery = "", "", ""
local rewayaFilter = ""
local speedIndex, sleepIndex = 1, 0
local seekPending = nil

local speedValues = {0.75, 1.0, 1.25, 1.5}
local speedLabels = {"0.75x", "1.0x", "1.25x", "1.5x"}
local sleepLabels = {"Off", "15 min", "30 min", "45 min", "60 min"}
local sleepValues = {0, 15, 30, 45, 60}
local repeatLabels = {"1x", "2x", "3x", "5x"}
local repeatValues = {1, 2, 3, 5}

local function reciterById(id)
  for _, r in ipairs(reciters) do
    if tostring(r.id) == tostring(id) then return r end
  end
end

local function everyayahById(id)
  for _, r in ipairs(everyayah) do
    if tostring(r.id) == tostring(id) then return r end
  end
end

local function surahById(id)
  for _, s in ipairs(surahs) do
    if tonumber(s.id) == tonumber(id) then return s end
  end
end

local function reciterName(id)
  local r = reciterById(id)
  return r and (r.name or tostring(id)) or tostring(id)
end

local function surahNameById(id)
  local s = surahById(id)
  return s and (s.name or ("Surah " .. tostring(id))) or ("Surah " .. tostring(id))
end

local function ayahCountFor(id)
  return tonumber(ayahCounts[tonumber(id)]) or 0
end

local function loadFavorites()
  local raw = noctalia.readFile(favPath)
  if raw then
    local ok, data = pcall(function() return noctalia.json.decode(raw) end)
    if ok and type(data) == "table" then favorites = data end
  end
  noctalia.state.set("quran_favorites", favorites)
end

local function saveFavorites()
  noctalia.state.set("quran_favorites", favorites)
  noctalia.writeFile(favPath, noctalia.json.encode(favorites) or "[]")
end

local function isFav(surahId, reciterId)
  for _, f in ipairs(favorites) do
    if tonumber(f.surahId) == tonumber(surahId) and tostring(f.reciterId) == tostring(reciterId) then return true end
  end
  return false
end

local function refresh()
  if ready and render then render() end
end

local function toggleFav(surahId, reciterId)
  for i, f in ipairs(favorites) do
    if tonumber(f.surahId) == tonumber(surahId) and tostring(f.reciterId) == tostring(reciterId) then
      table.remove(favorites, i)
      saveFavorites()
      refresh()
      return
    end
  end
  table.insert(favorites, {
    surahId = tonumber(surahId),
    reciterId = tostring(reciterId),
    reciterName = reciterName(reciterId),
    surahName = surahNameById(surahId),
  })
  saveFavorites()
  refresh()
end

noctalia.state.watch("quran_reciters", function(v) reciters = v or reciters; refresh() end)
noctalia.state.watch("quran_surahs", function(v) surahs = v or surahs; refresh() end)
noctalia.state.watch("quran_everyayah", function(v) everyayah = v or everyayah; refresh() end)
noctalia.state.watch("quran_ayah_counts", function(v) ayahCounts = v or ayahCounts; refresh() end)
noctalia.state.watch("quran_rewayas", function(v) rewayas = v or rewayas; refresh() end)
noctalia.state.watch("quran_juz", function(v) juzList = v or juzList; refresh() end)
noctalia.state.watch("quran_cache", function(v) cacheMap = v or {}; refresh() end)
noctalia.state.watch("quran_status", function(v)
  if type(v) == "table" then
    status = v
    status.repeatOne = status.repeatOne == true
    status.shuffle = status.shuffle == true
    status.cached = status.cached == true
    status.speed = tonumber(status.speed) or 1.0
    status.sleepUntil = tonumber(status.sleepUntil) or 0
    status.position = tonumber(status.position) or 0
    status.duration = tonumber(status.duration) or 0
    status.repeatCount = tonumber(status.repeatCount) or 1
    status.queue = status.queue or {}
    status.queueIndex = tonumber(status.queueIndex) or 0
    status.juz = tonumber(status.juz) or 0
    status.downloading = status.downloading or {}
    status.paused = status.paused == true
    status.mode = (status.mode == "ayah") and "ayah" or "surah"
    status.ayah = tonumber(status.ayah) or 1
    status.ayahCount = tonumber(status.ayahCount) or 0
    status.everyayahId = tostring(status.everyayahId or "")
    local a = tonumber(status.ayah) or 0
    if status.mode == "ayah" and a ~= lastFollowAyah then
      lastFollowAyah = a
      if a > 0 then textPage = math.max(1, math.ceil(a / TEXT_PER_PAGE)) end
    end
  end
  refresh()
end)
noctalia.state.watch("quran_favorites", function(v)
  if type(v) == "table" then favorites = v end
  refresh()
end)

local function req(action, extra)
  local prev = noctalia.state.get("quran_request")
  local seq = 0
  if type(prev) == "table" and tonumber(prev.seq) then seq = tonumber(prev.seq) end
  local r = { seq = seq + 1, action = action }
  if type(extra) == "table" then
    for k, v in pairs(extra) do r[k] = v end
  end
  noctalia.state.set("quran_request", r)
end

local function filterReciters(q)
  q = (q or ""):lower()
  local out = {}
  for _, r in ipairs(reciters) do
    local label = (r.label or r.name or ""):lower()
    local rewayaOk = rewayaFilter == "" or tostring(r.rewaya or "") == rewayaFilter
    if rewayaOk and (q == "" or label:find(q, 1, true) or tostring(r.id):lower():find(q, 1, true)) then
      table.insert(out, r)
      if #out >= 40 then break end
    end
  end
  return out
end

local function filterEveryAyah(q)
  q = (q or ""):lower()
  local out = {}
  for _, r in ipairs(everyayah) do
    local label = (r.label or r.name or ""):lower()
    if q == "" or label:find(q, 1, true) or tostring(r.id):lower():find(q, 1, true) then
      table.insert(out, r)
      if #out >= 40 then break end
    end
  end
  return out
end

local function filterSurahs(q)
  q = (q or ""):lower()
  local out = {}
  for _, s in ipairs(surahs) do
    local name = (s.name or ""):lower()
    if q == "" or tostring(s.id):find(q, 1, true) or name:find(q, 1, true) then
      table.insert(out, s)
      if #out >= 40 then break end
    end
  end
  return out
end

local function currentReciterLabel()
  local r = reciterById(status.reciterId)
  return r and (r.label or r.name or tostring(r.id)) or "Pilih qari"
end

local function currentEveryAyahLabel()
  local r = everyayahById(status.everyayahId)
  return r and (r.label or r.name or tostring(r.id)) or "Pilih reciter"
end

local function currentSurahLabel()
  local s = surahById(status.surahId)
  if not s then return "Pilih surah" end
  return string.format("%d. %s", tonumber(s.id) or 0, s.name or "")
end

local function selectReciter(r)
  if not r then return end
  req("setReciter", { reciterId = r.id })
  status.reciterId = r.id
  qariOpen = false
  qariQuery = ""
  refresh()
end

local function selectEveryAyah(r)
  if not r then return end
  req("setEveryAyah", { everyayahId = r.id })
  status.everyayahId = r.id
  everyayahOpen = false
  everyayahQuery = ""
  refresh()
end

local function selectSurah(s)
  if not s then return end
  req("setSurah", { surahId = s.id })
  status.surahId = s.id
  surahOpen = false
  surahQuery = ""
  textPage = 1
  lastFollowAyah = nil
  refresh()
end

local function fmtTime(sec)
  sec = math.floor(tonumber(sec) or 0)
  if sec < 0 then sec = 0 end
  local m = math.floor(sec / 60)
  local s = sec % 60
  return string.format("%02d:%02d", m, s)
end

local function isCached(surahId, reciterId)
  return cacheMap[tostring(reciterId) .. ":" .. tostring(surahId)] ~= nil
end

local function sleepIndexOf()
  local untilAt = tonumber(status.sleepUntil) or 0
  if untilAt <= 0 then return 0 end
  local remain = untilAt - os.time()
  if remain <= 0 then return 0 end
  for i, v in ipairs(sleepValues) do
    if v > 0 and remain <= v * 60 then return i - 1 end
  end
  return #sleepValues - 1
end

local function repeatIndexOf()
  local n = tonumber(status.repeatCount) or 1
  for i, v in ipairs(repeatValues) do
    if v == n then return i - 1 end
  end
  return 0
end

-- ── surah text ───────────────────────────────────────────────────────────────

local function textPath(n)
  return textDir .. "/" .. tostring(n) .. ".json"
end

local function loadText(n)
  n = tonumber(n)
  if not n or textLoading[n] or textCache[n] then return end
  local raw = noctalia.readFile(textPath(n))
  if raw then
    local ok, data = pcall(function() return noctalia.json.decode(raw) end)
    if ok and type(data) == "table" and type(data.ayat) == "table" then
      textCache[n] = data
      return
    end
  end
  textLoading[n] = true
  textError[n] = ""
  refresh()
  noctalia.http({ url = "https://equran.id/api/v2/surat/" .. tostring(n) }, function(res)
    textLoading[n] = nil
    if res and res.ok then
      local ok, data = pcall(function() return noctalia.json.decode(res.body) end)
      if ok and type(data) == "table" and type(data.data) == "table" and type(data.data.ayat) == "table" then
        textCache[n] = data.data
        noctalia.mkdirAll(textDir)
        noctalia.writeFile(textPath(n), noctalia.json.encode(data.data) or "{}")
      else
        textError[n] = "Respons tidak dikenal"
      end
    else
      textError[n] = "Gagal memuat (jaringan)"
    end
    refresh()
  end)
end

-- ── widgets ──────────────────────────────────────────────────────────────────

local function dropdown(props)
  local children = {
    ui.button({
      key = props.key .. "-trigger",
      text = props.current .. "   " .. (props.open and "▴" or "▾"),
      contentAlign = "start",
      variant = "outline",
      onClick = props.onToggle,
    }),
  }
  if props.open then
    children[#children + 1] = ui.input({
      key = props.key .. "-search",
      value = props.query,
      placeholder = props.placeholder,
      focus = true,
      onChange = props.onQuery,
      onSubmit = function()
        if props.items[1] then props.onPick(props.items[1]) end
      end,
    })
    local rows = {}
    if #props.items == 0 then
      rows[1] = ui.label({ text = "Tidak ada hasil", color = "on_surface_variant", fontSize = 11 })
    else
      for _, item in ipairs(props.items) do
        rows[#rows + 1] = ui.button({
          text = props.label(item),
          contentAlign = "start",
          controlSize = "sm",
          variant = props.isSelected(item) and "secondary" or "ghost",
          onClick = function() props.onPick(item) end,
        })
      end
    end
    children[#children + 1] = ui.scroll({ height = 160, gap = 2 }, rows)
  end
  return ui.column({ gap = 6 }, children)
end

local function tabButton(id, label)
  return ui.button({
    key = "tab-" .. id,
    text = label,
    flexGrow = 1,
    variant = activeTab == id and "secondary" or "ghost",
    onClick = function()
      if activeTab ~= id then
        activeTab = id
        qariOpen, surahOpen, everyayahOpen = false, false, false
        refresh()
      end
    end,
  })
end

local function splitName(name)
  local title, sub = tostring(name or ""):match("^(.-)%s+—%s+(.+)$")
  return title or (name or ""), sub or ""
end

local function playerCard()
  local playing = status.playing == true
  local paused = status.paused == true
  local pos = tonumber(status.position) or 0
  local dur = tonumber(status.duration) or 0
  local title, sub = splitName(status.name)
  if title == "" then title = "Belum ada audio" end
  if sub == "" then sub = "Pilih qari dan surah" end
  local modeText = status.mode == "ayah"
    and string.format("Ayah %d/%d", tonumber(status.ayah) or 1, tonumber(status.ayahCount) or 0)
    or "Surah"

  return ui.column({ gap = 6, padding = 12, radius = 10, fill = "surface_container/0.35" }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = title, fontSize = 14, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = modeText, fontSize = 9, color = "primary" }),
      ui.label({ text = (status.cached and status.mode == "surah") and "offline" or "", fontSize = 9, color = "primary" }),
    }),
    ui.label({ text = sub, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    ui.slider({
      min = 0,
      max = math.max(1, dur),
      step = 1,
      value = math.min(pos, math.max(1, dur)),
      onChange = function(v) seekPending = tonumber(v) or 0 end,
      onDragEnd = function()
        if seekPending then
          req("seek", { seconds = seekPending })
          seekPending = nil
        end
      end,
    }),
    ui.row({ justify = "space_between" }, {
      ui.label({ text = fmtTime(pos) .. " / " .. fmtTime(dur), fontSize = 10, color = "on_surface_variant" }),
      ui.label({ text = playing and (paused and "Paused" or "Playing") or "Stopped", fontSize = 10, color = playing and not paused and "primary" or "on_surface_variant" }),
    }),
    ui.row({ gap = 8, justify = "center" }, {
      ui.button({ glyph = "player-skip-back-filled", onClick = function() req("prev") end }),
      ui.button({ glyph = (playing and not paused) and "player-pause-filled" or "player-play-filled", variant = "primary", onClick = function() req("toggle") end }),
      ui.button({ glyph = "player-skip-forward-filled", onClick = function() req("next") end }),
      ui.button({ glyph = isFav(status.surahId, status.reciterId) and "star-filled" or "star", onClick = function() toggleFav(status.surahId, status.reciterId) end }),
    }),
  })
end

local function optionsCard()
  local rows = {
    ui.row({ gap = 10, align = "center" }, {
      ui.label({ text = "Volume", fontSize = 11, color = "on_surface_variant", width = 52 }),
      ui.slider({
        flexGrow = 1,
        min = 0,
        max = 100,
        step = 5,
        value = tonumber(status.volume) or 65,
        onChange = function(v) req("volume", { volume = math.floor(tonumber(v) or 0) }) end,
      }),
      ui.label({ text = tostring(status.volume or 65) .. "%", fontSize = 11, color = "on_surface_variant", width = 40, textAlign = "end" }),
    }),
    ui.row({ gap = 8 }, {
      ui.button({ text = status.repeatOne and "Repeat: On" or "Repeat: Off", flexGrow = 1, onClick = function() req("repeat") end }),
      ui.button({ text = status.shuffle and "Shuffle: On" or "Shuffle: Off", flexGrow = 1, onClick = function() req("shuffle") end }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Ulangi", fontSize = 11, color = "on_surface_variant", width = 52 }),
      ui.select({
        options = repeatLabels,
        selectedIndex = repeatIndexOf(),
        flexGrow = 1,
        onChange = function(index)
          local i = (tonumber(index) or 0) + 1
          req("repeatCount", { value = repeatValues[i] or 1 })
          refresh()
        end,
      }),
      ui.label({ text = "Speed", fontSize = 11, color = "on_surface_variant", width = 44 }),
      ui.select({
        options = speedLabels,
        selectedIndex = speedIndex,
        flexGrow = 1,
        onChange = function(index)
          local i = (tonumber(index) or 0) + 1
          if speedValues[i] then
            req("speed", { speed = speedValues[i] })
            status.speed = speedValues[i]
            refresh()
          end
        end,
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Sleep", fontSize = 11, color = "on_surface_variant", width = 52 }),
      ui.select({
        options = sleepLabels,
        selectedIndex = sleepIndex,
        flexGrow = 1,
        onChange = function(index)
          local i = (tonumber(index) or 0) + 1
          req("sleep", { minutes = sleepValues[i] or 0 })
          refresh()
        end,
      }),
      ui.label({
        text = (tonumber(status.sleepUntil) or 0) > 0
          and (fmtTime(math.max(0, (tonumber(status.sleepUntil) or 0) - os.time())) .. " lagi")
          or "",
        fontSize = 10,
        color = "on_surface_variant",
        width = 70,
        textAlign = "end",
      }),
    }),
    ui.row({ gap = 12, align = "center" }, {
      ui.label({ text = "Terjemahan", fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      ui.toggle({
        checked = showTranslation,
        onChange = function(v)
          showTranslation = (v == "true")
          refresh()
        end,
      }),
      ui.label({ text = "Latin", fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      ui.toggle({
        checked = showLatin,
        onChange = function(v)
          showLatin = (v == "true")
          refresh()
        end,
      }),
    }),
  }

  if activeTab == "surah" then
    local juzOptions = {"— pilih juz —"}
    for i = 1, 30 do juzOptions[#juzOptions + 1] = "Juz " .. tostring(i) end
    local curJuz = tonumber(status.juz) or 0
    rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
      ui.select({
        options = juzOptions,
        selectedIndex = curJuz > 0 and curJuz or 0,
        flexGrow = 1,
        onChange = function(index)
          local n = tonumber(index) or 0
          if n >= 1 and n <= 30 then req("juz", { juz = n }) end
        end,
      }),
      ui.button({
        text = "Putar juz",
        variant = "primary",
        enabled = curJuz >= 1 and curJuz <= 30,
        onClick = function()
          if curJuz >= 1 and curJuz <= 30 then req("juz", { juz = curJuz }) end
        end,
      }),
    })

    local rewayaOptions = {"Semua riwayah"}
    local rewayaIndex = 0
    for i, rw in ipairs(rewayas) do
      rewayaOptions[#rewayaOptions + 1] = rw.name or tostring(rw.id)
      if rewayaFilter ~= "" and rw.name == rewayaFilter then rewayaIndex = i end
    end
    rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Riwayah", fontSize = 11, color = "on_surface_variant", width = 52 }),
      ui.select({
        options = rewayaOptions,
        selectedIndex = rewayaIndex,
        flexGrow = 1,
        onChange = function(index)
          local i = (tonumber(index) or 0) + 1
          rewayaFilter = (i == 1) and "" or (rewayaOptions[i] or "")
          qariOpen = false
          refresh()
        end,
      }),
    })
  end

  return ui.column({ gap = 8, padding = 10, radius = 10, fill = "surface_container/0.25" }, rows)
end

-- ── tab: Surah (simple) ──────────────────────────────────────────────────────

local function renderSurah()
  local qariItems = filterReciters(qariQuery)
  local surahItems = filterSurahs(surahQuery)
  local sid = tonumber(status.surahId) or 1
  local rid = status.reciterId
  local cachedNow = isCached(sid, rid)
  local busy = status.downloading[tostring(sid)] == true

  local content = {
    dropdown({
      key = "qari",
      open = qariOpen,
      query = qariQuery,
      current = currentReciterLabel(),
      placeholder = "Cari qari...",
      items = qariItems,
      label = function(r) return r.label or r.name or tostring(r.id) end,
      isSelected = function(r) return tostring(r.id) == tostring(status.reciterId) end,
      onToggle = function()
        qariOpen = not qariOpen
        if qariOpen then surahOpen, everyayahOpen = false, false end
        refresh()
      end,
      onQuery = function(v) qariQuery = tostring(v or ""); refresh() end,
      onPick = function(r) selectReciter(r) end,
    }),
    dropdown({
      key = "surah",
      open = surahOpen,
      query = surahQuery,
      current = currentSurahLabel(),
      placeholder = "Cari surah...",
      items = surahItems,
      label = function(s) return string.format("%d. %s", tonumber(s.id) or 0, s.name or "") end,
      isSelected = function(s) return tonumber(s.id) == tonumber(status.surahId) end,
      onToggle = function()
        surahOpen = not surahOpen
        if surahOpen then qariOpen, everyayahOpen = false, false end
        refresh()
      end,
      onQuery = function(v) surahQuery = tostring(v or ""); refresh() end,
      onPick = function(s) selectSurah(s) end,
    }),
    ui.button({
      text = "Putar surah",
      glyph = "player-play",
      variant = "primary",
      onClick = function() req("play", { reciterId = status.reciterId, surahId = status.surahId }) end,
    }),
    ui.button({
      text = busy and "Mengunduh…" or (cachedNow and "Hapus unduhan" or "Unduh surah"),
      variant = cachedNow and "ghost" or "outline",
      enabled = not busy,
      onClick = function()
        if cachedNow then
          req("removeDownload", { surahId = sid })
        else
          req("download", { surahId = sid })
        end
      end,
    }),
    ui.label({ text = "Pilih qari dan surah, lalu Putar. Pengaturan lain ada di Opsi.", fontSize = 10, color = "on_surface_variant" }),
  }
  renderShell(content, nil, optionsOpen and optionsCard() or nil)
end

-- ── tab: Per Ayah ────────────────────────────────────────────────────────────

local function playAyah(ayah)
  local rid = status.everyayahId
  if rid == "" and #everyayah > 0 then rid = everyayah[1].id end
  if rid == "" then
    noctalia.notifyError("Quran", "Reciter EveryAyah belum siap")
    return
  end
  req("playAyah", { everyayahId = rid, surahId = status.surahId, ayah = tonumber(ayah) or 1 })
end

local function repeatAyah(ayah)
  req("repeat", { value = true })
  playAyah(ayah)
end

local function renderAyah()
  local sid = tonumber(status.surahId) or 1
  loadText(sid)
  local everyayahItems = filterEveryAyah(everyayahQuery)
  local surahItems = filterSurahs(surahQuery)
  local doc = textCache[sid]
  local total = doc and #(doc.ayat or {}) or 0

  local toolbar = ui.column({ gap = 6 }, {
    dropdown({
      key = "everyayah",
      open = everyayahOpen,
      query = everyayahQuery,
      current = currentEveryAyahLabel(),
      placeholder = "Cari reciter...",
      items = everyayahItems,
      label = function(r) return r.label or r.name or tostring(r.id) end,
      isSelected = function(r) return tostring(r.id) == tostring(status.everyayahId) end,
      onToggle = function()
        everyayahOpen = not everyayahOpen
        if everyayahOpen then qariOpen, surahOpen = false, false end
        refresh()
      end,
      onQuery = function(v) everyayahQuery = tostring(v or ""); refresh() end,
      onPick = function(r) selectEveryAyah(r) end,
    }),
    dropdown({
      key = "ayah-surah",
      open = surahOpen,
      query = surahQuery,
      current = currentSurahLabel(),
      placeholder = "Cari surah...",
      items = surahItems,
      label = function(s) return string.format("%d. %s", tonumber(s.id) or 0, s.name or "") end,
      isSelected = function(s) return tonumber(s.id) == tonumber(status.surahId) end,
      onToggle = function()
        surahOpen = not surahOpen
        if surahOpen then qariOpen, everyayahOpen = false, false end
        refresh()
      end,
      onQuery = function(v) surahQuery = tostring(v or ""); refresh() end,
      onPick = function(s) selectSurah(s) end,
    }),
  })
  local content = {}

  if textLoading[sid] then
    content[#content + 1] = ui.label({ text = "Memuat teks…", fontSize = 11, color = "on_surface_variant" })
  elseif not doc then
    content[#content + 1] = ui.label({
      text = (textError[sid] ~= "" and textError[sid]) or "Teks belum tersedia",
      fontSize = 11,
      color = "error",
    })
    content[#content + 1] = ui.button({
      text = "Coba lagi",
      controlSize = "sm",
      variant = "outline",
      onClick = function()
        textError[sid] = ""
        refresh()
      end,
    })
  else
    local ayat = doc.ayat or {}
    local pages = math.max(1, math.ceil(total / TEXT_PER_PAGE))
    if textPage > pages then textPage = pages end
    local from = (textPage - 1) * TEXT_PER_PAGE + 1
    local to = math.min(total, textPage * TEXT_PER_PAGE)
    local count = ayahCountFor(sid)
    local currentAyah = (status.mode == "ayah" and tonumber(status.surahId) == sid) and tonumber(status.ayah) or 0

    content[#content + 1] = ui.row({ justify = "space_between", align = "center" }, {
      ui.label({
        text = string.format("%s · %d ayat%s", tostring(doc.tempatTurun or ""), total,
          count > 0 and (" · EveryAyah " .. tostring(count)) or ""),
        fontSize = 11,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.label({
        text = currentAyah > 0 and ("Ayah " .. tostring(currentAyah)) or "",
        fontSize = 10,
        color = "primary",
      }),
    })

    if pages > 1 then
      content[#content + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.button({
          glyph = "chevron-left",
          controlSize = "sm",
          enabled = textPage > 1,
          onClick = function()
            textPage = math.max(1, textPage - 1)
            refresh()
          end,
        }),
        ui.label({
          text = string.format("%d–%d / %d", from, to, total),
          fontSize = 10,
          color = "on_surface_variant",
          flexGrow = 1,
          textAlign = "center",
        }),
        ui.button({
          glyph = "chevron-right",
          controlSize = "sm",
          enabled = textPage < pages,
          onClick = function()
            textPage = math.min(pages, textPage + 1)
            refresh()
          end,
        }),
      })
    end

    for i = from, to do
      local a = ayat[i]
      if a then
        local emphasized = currentAyah == i
        local rows = {
          ui.row({ gap = 10, align = "start" }, {
            ui.label({ text = tostring(a.nomorAyat or i), fontSize = 10, color = "primary", width = 22 }),
            ui.label({
              text = tostring(a.teksArab or ""):gsub("%s+$", ""),
              fontSize = 19,
              flexGrow = 1,
              textAlign = "end",
              fontFamily = arabicFont,
            }),
          }),
        }
        if showLatin and a.teksLatin and a.teksLatin ~= "" then
          rows[#rows + 1] = ui.label({ text = tostring(a.teksLatin), fontSize = 10, color = "on_surface_variant" })
        end
        if showTranslation and a.teksIndonesia and a.teksIndonesia ~= "" then
          rows[#rows + 1] = ui.label({ text = tostring(a.teksIndonesia), fontSize = 11, color = "on_surface_variant" })
        end
        rows[#rows + 1] = ui.row({ gap = 6, align = "center" }, {
          ui.label({
            text = emphasized and "Sedang diputar" or "",
            fontSize = 9,
            color = "primary",
            flexGrow = 1,
          }),
          ui.button({
            glyph = "player-play",
            controlSize = "sm",
            tooltip = "Putar ayat " .. tostring(i),
            onClick = function() playAyah(i) end,
          }),
          ui.button({
            glyph = "repeat",
            controlSize = "sm",
            tooltip = "Ulangi ayat ini",
            onClick = function() repeatAyah(i) end,
          }),
        })
        content[#content + 1] = ui.column({
          key = "ayah-" .. tostring(i),
          gap = 4,
          padding = 8,
          radius = 8,
          fill = emphasized and "primary/0.12" or "surface_container/0.25",
          border = emphasized and "primary" or nil,
          borderWidth = emphasized and 1 or 0,
        }, rows)
      end
    end
  end

  local reveal
  if status.mode == "ayah" and tonumber(status.surahId) == sid then
    reveal = "ayah-" .. tostring(status.ayah)
  end
  renderShell(content, reveal, optionsOpen and optionsCard() or nil, toolbar)
end

-- ── tab: Favorit ─────────────────────────────────────────────────────────────

local function renderFavorites()
  local rows = {}
  for _, f in ipairs(favorites) do
    local title = (f.surahName or surahNameById(f.surahId)) .. " — " .. (f.reciterName or reciterName(f.reciterId))
    rows[#rows + 1] = ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = title, flexGrow = 1, fontSize = 11, maxLines = 1 }),
      ui.button({ glyph = "player-play", controlSize = "sm", tooltip = "Play", onClick = function() req("play", { reciterId = f.reciterId, surahId = f.surahId }) end }),
      ui.button({ glyph = "trash", controlSize = "sm", tooltip = "Remove", onClick = function() toggleFav(f.surahId, f.reciterId) end }),
    })
  end
  if #rows == 0 then
    rows[1] = ui.label({ text = "Belum ada favorit. Tekan bintang di kartu pemutar untuk menyimpan surah/qari.", fontSize = 11, color = "on_surface_variant" })
  end
  local content = { ui.label({ text = "Favorit surah & qari", fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }) }
  for _, row in ipairs(rows) do content[#content + 1] = row end
  renderShell(content, nil, optionsOpen and optionsCard() or nil)
end

-- ── shell ────────────────────────────────────────────────────────────────────

function renderShell(content, revealKey, optionsNode, toolbarNode)
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Murattal", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        text = optionsOpen and "Opsi ▴" or "Opsi ▾",
        variant = optionsOpen and "secondary" or "ghost",
        onClick = function()
          optionsOpen = not optionsOpen
          refresh()
        end,
      }),
      ui.button({ glyph = "close", onClick = function() panel.close() end }),
    }),
    ui.row({ gap = 6 }, {
      tabButton("surah", "Surah"),
      tabButton("ayah", "Per Ayah"),
      tabButton("favorites", "Favorit"),
    }),
    playerCard(),
  }
  if toolbarNode then children[#children + 1] = toolbarNode end
  if optionsNode then children[#children + 1] = optionsNode end
  children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 10, revealKey = revealKey }, content)
  panel.render(ui.column({ flexGrow = 1, gap = 10 }, children))
end

render = function()
  if activeTab == "ayah" then
    renderAyah()
  elseif activeTab == "favorites" then
    renderFavorites()
  else
    renderSurah()
  end
end

function onOpen(_context)
  loadFavorites()
  refresh()
end

function onClose()
  panel.close()
end

ready = true
