--!nonstrict
-- Launcher provider for /quran.
--   /quran <surah>            play a surah with the current qari
--   /quran juz <n>            play juz n in order
--   /quran riwayah <name>     pick a qari from a riwayah, then play
--   /quran unduh              download the current surah for offline playback
--   /quran rm                 remove a favorite
local surahs = noctalia.state.get("quran_surahs") or {}
local status = noctalia.state.get("quran_status") or { reciterId = "", surahId = 1, volume = 65 }
local favorites = {}
local reciters = noctalia.state.get("quran_reciters") or {}
local rewayas = noctalia.state.get("quran_rewayas") or {}
local juzList = noctalia.state.get("quran_juz") or {}
local cacheMap = noctalia.state.get("quran_cache") or {}

noctalia.state.watch("quran_surahs", function(v)
  surahs = v or surahs
end)
noctalia.state.watch("quran_status", function(v)
  status = v or status
end)
noctalia.state.watch("quran_reciters", function(v)
  reciters = v or reciters
end)
noctalia.state.watch("quran_rewayas", function(v)
  rewayas = v or rewayas
end)
noctalia.state.watch("quran_juz", function(v)
  juzList = v or juzList
end)
noctalia.state.watch("quran_cache", function(v)
  cacheMap = v or {}
end)
noctalia.state.watch("quran_favorites", function(v)
  if type(v) == "table" then favorites = v end
end)

local function favPath()
  return noctalia.pluginDataDir() .. "/favorites.json"
end

local function loadFavorites()
  local raw = noctalia.readFile(favPath())
  if raw then
    local ok, data = pcall(function() return noctalia.json.decode(raw) end)
    if ok and type(data) == "table" then
      favorites = data
      noctalia.state.set("quran_favorites", favorites)
    end
  end
  return favorites
end

local function saveFavorites()
  noctalia.state.set("quran_favorites", favorites)
  noctalia.writeFile(favPath(), noctalia.json.encode(favorites) or "[]")
end

local function reciterName(id)
  for _, r in ipairs(reciters) do
    if tostring(r.id) == tostring(id) then return r.name end
  end
  return tostring(id)
end

local function surahName(id)
  for _, s in ipairs(surahs) do
    if tonumber(s.id) == tonumber(id) then return s.name end
  end
  return "Surah " .. tostring(id)
end

local function removeFav(reciterId, surahId)
  for i, f in ipairs(favorites) do
    if tostring(f.reciterId) == tostring(reciterId) and tonumber(f.surahId) == tonumber(surahId) then
      table.remove(favorites, i)
      saveFavorites()
      return true
    end
  end
  return false
end

local function playId(reciterId, surahId)
  return "play:" .. tostring(reciterId or "") .. ":" .. tostring(surahId)
end

local function removeId(reciterId, surahId)
  return "remove:" .. tostring(reciterId or "") .. ":" .. tostring(surahId)
end

local function rowForFav(f, score)
  local rid = f.reciterId or status.reciterId
  local sid = f.surahId
  local title = (f.surahName or surahName(sid)) .. " — " .. (f.reciterName or reciterName(rid))
  return {
    id = playId(rid, sid),
    title = title,
    subtitle = "Favorite - Enter to play, type 'rm' to remove",
    glyph = "star-filled",
    score = score,
  }
end

local function requestPlay(reciterId, surahId)
  local prev = noctalia.state.get("quran_request")
  local seq = 0
  if type(prev) == "table" and tonumber(prev.seq) then seq = tonumber(prev.seq) end
  noctalia.state.set("quran_request", { seq = seq + 1, action = "play", reciterId = reciterId, surahId = tonumber(surahId) })
  noctalia.notify("Quran", "Playing " .. surahName(tonumber(surahId)))
end

local function requestAction(action, extra)
  local prev = noctalia.state.get("quran_request")
  local seq = 0
  if type(prev) == "table" and tonumber(prev.seq) then seq = tonumber(prev.seq) end
  local r = { seq = seq + 1, action = action }
  if type(extra) == "table" then
    for k, v in pairs(extra) do r[k] = v end
  end
  noctalia.state.set("quran_request", r)
end

local function juzLabel(j)
  local from = surahName(j.from)
  local to = surahName(j.to)
  if j.from == j.to then return string.format("Juz %d — %s", j.id, from) end
  return string.format("Juz %d — %s..%s", j.id, from, to)
end

local function rowsForJuz(filter)
  local rows = {}
  local n = 0
  for _, j in ipairs(juzList) do
    local label = juzLabel(j)
    local hit = filter == "" or label:lower():find(filter:lower(), 1, true) or tostring(j.id) == filter
    if hit then
      n = n + 1
      rows[#rows + 1] = {
        id = "juz:" .. tostring(j.id),
        title = label,
        subtitle = string.format("%d surah - Enter to play in order", j.count),
        glyph = "playlist",
        score = 100 - n * 0.01,
      }
    end
  end
  return rows
end

local function rowsForRewaya(filter)
  local rows = {}
  local n = 0
  for _, r in ipairs(reciters) do
    local rw = tostring(r.rewaya or "")
    local hit = filter == "" or rw:lower():find(filter:lower(), 1, true) or (r.name or ""):lower():find(filter:lower(), 1, true)
    if hit then
      n = n + 1
      rows[#rows + 1] = {
        id = "reciter:" .. tostring(r.id),
        title = r.label or r.name or tostring(r.id),
        subtitle = rw .. " - Enter to use this qari",
        glyph = "microphone",
        score = 100 - n * 0.01,
      }
      if n >= 40 then break end
    end
  end
  return rows
end

function onQuery(text)
  local q = noctalia.string.trim(text or "")
  favorites = loadFavorites()
  local rows = {}
  local lower = q:lower()

  -- /quran juz [n]
  local juzArg = lower:match("^juz%s*(.*)$")
  if juzArg then
    local list = rowsForJuz(noctalia.string.trim(juzArg))
    if #list == 0 then
      rows[1] = { id = "", title = "No juz found", glyph = "mood-empty" }
    else
      rows = list
    end
    launcher.setResults(text, rows)
    return
  end

  -- /quran riwayah [name]
  local rwArg = lower:match("^riwayah%s*(.*)$")
  if rwArg then
    local list = rowsForRewaya(noctalia.string.trim(rwArg))
    if #list == 0 then
      rows[1] = { id = "", title = "No qari found", glyph = "mood-empty" }
    else
      rows = list
    end
    launcher.setResults(text, rows)
    return
  end

  -- /quran unduh
  if lower == "unduh" or lower == "download" then
    rows[1] = {
      id = "download",
      title = "Download " .. surahName(status.surahId),
      subtitle = "Save the current surah for offline playback",
      glyph = "download",
      score = 100,
    }
    launcher.setResults(text, rows)
    return
  end

  local removeMode = lower == "rm" or lower == "remove" or lower == "unfav"
    or lower:match("^rm%s") or lower:match("^remove%s") or lower:match("^unfav%s")
  if removeMode then
    local filter = q:gsub("^[Rr][Mm]%s*", ""):gsub("^[Rr]emove%s*", ""):gsub("^[Uu]nfav%s*", "")
    filter = noctalia.string.trim(filter)
    for i, f in ipairs(favorites) do
      local title = (f.surahName or surahName(f.surahId)) .. " — " .. (f.reciterName or reciterName(f.reciterId))
      if filter == "" or title:lower():find(filter:lower(), 1, true) then
        table.insert(rows, {
          id = removeId(f.reciterId, f.surahId),
          title = "Remove: " .. title,
          subtitle = "Enter to remove from favorites",
          glyph = "trash",
          score = 100 - i,
        })
      end
    end
    if #rows == 0 then
      rows[1] = { id = "", title = "No favorites to remove", glyph = "mood-empty" }
    end
    launcher.setResults(text, rows)
    return
  end

  if q == "" then
    if #favorites > 0 then
      for i, f in ipairs(favorites) do
        table.insert(rows, rowForFav(f, 100 - i))
      end
    else
      rows[1] = { id = "", title = "No favorites yet", subtitle = "Star a surah in the panel", glyph = "star" }
    end
    table.insert(rows, { id = "", title = "Type a surah name or number", glyph = "search" })
    table.insert(rows, { id = "", title = "Type 'juz 30' to play a juz", glyph = "playlist" })
    table.insert(rows, { id = "", title = "Type 'riwayah warsh' to pick a qari", glyph = "microphone" })
    table.insert(rows, { id = "", title = "Type 'unduh' to download the current surah", glyph = "download" })
    table.insert(rows, { id = "", title = "Type 'rm' to remove a favorite", glyph = "trash" })
    launcher.setResults(text, rows)
    return
  end

  local n = 0
  for _, s in ipairs(surahs) do
    local score = noctalia.fuzzyScore(q, tostring(s.id) .. " " .. (s.name or ""))
    if score ~= nil then
      n = n + 1
      local cached = cacheMap[tostring(status.reciterId) .. ":" .. tostring(s.id)] ~= nil
      table.insert(rows, {
        id = playId(status.reciterId, s.id),
        title = s.name,
        subtitle = "Surah " .. tostring(s.id) .. (cached and " - offline" or "") .. " - Enter to play",
        glyph = "player-play",
        score = (score or 0) + 50 - n * 0.01,
      })
    end
    if n >= 30 then break end
  end

  local num = tonumber(q)
  if num and num >= 1 and num <= 114 then
    local found = false
    for _, r in ipairs(rows) do
      if r.id:find(":" .. tostring(num) .. "$") then found = true end
    end
    if not found then
      table.insert(rows, 1, {
        id = playId(status.reciterId, num),
        title = surahName(num),
        subtitle = "Surah " .. tostring(num) .. " - Enter to play",
        glyph = "player-play",
        score = 1000,
      })
    end
  end

  if #rows == 0 then
    rows[1] = { id = "", title = "No surah found", subtitle = "Try another name", glyph = "mood-empty" }
  end
  launcher.setResults(text, rows)
end

function onActivate(id)
  if id == "" or id == nil then return end

  local juzId = string.match(id, "^juz:(%d+)$")
  if juzId then
    requestAction("juz", { juz = tonumber(juzId) })
    noctalia.notify("Quran", "Juz " .. juzId)
    return
  end

  local reciterId2 = string.match(id, "^reciter:(.+)$")
  if reciterId2 then
    requestAction("setReciter", { reciterId = reciterId2 })
    noctalia.notify("Quran", "Qari: " .. reciterName(reciterId2))
    return
  end

  if id == "download" then
    requestAction("download", { surahId = status.surahId })
    noctalia.notify("Quran", "Downloading " .. surahName(status.surahId))
    return
  end

  local rid, sid = string.match(id, "^remove:([^:]+):(%d+)$")
  if rid and sid then
    removeFav(rid, sid)
    noctalia.notify("Quran", "Removed from favorites")
    return
  end

  local reciterId, surahId = string.match(id, "^play:([^:]+):(%d+)$")
  if not surahId then
    surahId = string.match(id, "^play:(%d+)$")
    reciterId = status.reciterId
  end
  if surahId then
    local rid2 = (reciterId and reciterId ~= "") and reciterId or status.reciterId
    requestPlay(rid2, surahId)
  end
end
