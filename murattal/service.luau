--!nonstrict
-- Service: owns mpv playback and the mp3quran.net catalog.
-- State channels:
--   quran_reciters = [ {id,name,label,server,rewaya} ]
--   quran_surahs   = [ {id,name} ]
--   quran_rewayas  = [ {id,name} ]
--   quran_juz      = [ {id,from,to,count} ]
--   quran_cache    = { ["<reciterId>:<surahId>"] = bytes }
--   quran_status   = { playing,name,reciterId,surahId,volume,url,cached,repeatOne,
--                      repeatCount,repeatDone,speed,sleepUntil,shuffle,position,
--                      duration,queue,queueIndex,juz,downloading }
--   quran_request  = { seq, action, reciterId?, surahId?, volume?, seconds?, juz?, value? }

local dataDir = noctalia.pluginDataDir()
local SOCK = dataDir .. "/mpv.sock"
local PIDFILE = dataDir .. "/mpv.pid"
local STATE_FILE = dataDir .. "/state.json"
local CACHE_DIR = dataDir .. "/audio"

local volume = tonumber(noctalia.getConfig("default_volume")) or 65
local mpvBin = noctalia.getConfig("mpv_bin") or "mpv"
local hasSocat = noctalia.commandExists("socat")
local hasMpris = false

-- Surah span of each juz, inclusive on both ends. The catalogue serves audio
-- per surah, so a juz maps to every surah it touches and the surahs on a juz
-- boundary are shared with the neighbouring juz. Boundaries verified against
-- api.alquran.cloud/v1/juz/N/quran-uthmani.
local JUZ_SPANS = {
  { 1, 2 }, -- juz 1: 1:1 .. 2:141
  { 2, 2 }, -- juz 2: 2:142 .. 2:252
  { 2, 3 }, -- juz 3: 2:253 .. 3:92
  { 3, 4 }, -- juz 4: 3:93 .. 4:23
  { 4, 4 }, -- juz 5: 4:24 .. 4:147
  { 4, 5 }, -- juz 6: 4:148 .. 5:81
  { 5, 6 }, -- juz 7: 5:82 .. 6:110
  { 6, 7 }, -- juz 8: 6:111 .. 7:87
  { 7, 8 }, -- juz 9: 7:88 .. 8:40
  { 8, 9 }, -- juz 10: 8:41 .. 9:92
  { 9, 11 }, -- juz 11: 9:93 .. 11:5
  { 11, 12 }, -- juz 12: 11:6 .. 12:52
  { 12, 14 }, -- juz 13: 12:53 .. 14:52
  { 15, 16 }, -- juz 14: 15:1 .. 16:128
  { 17, 18 }, -- juz 15: 17:1 .. 18:74
  { 18, 20 }, -- juz 16: 18:75 .. 20:135
  { 21, 22 }, -- juz 17: 21:1 .. 22:78
  { 23, 25 }, -- juz 18: 23:1 .. 25:20
  { 25, 27 }, -- juz 19: 25:21 .. 27:55
  { 27, 29 }, -- juz 20: 27:56 .. 29:45
  { 29, 33 }, -- juz 21: 29:46 .. 33:30
  { 33, 36 }, -- juz 22: 33:31 .. 36:27
  { 36, 39 }, -- juz 23: 36:28 .. 39:31
  { 39, 41 }, -- juz 24: 39:32 .. 41:46
  { 41, 45 }, -- juz 25: 41:47 .. 45:37
  { 46, 51 }, -- juz 26: 46:1 .. 51:30
  { 51, 57 }, -- juz 27: 51:31 .. 57:29
  { 58, 66 }, -- juz 28: 58:1 .. 66:12
  { 67, 77 }, -- juz 29: 67:1 .. 77:50
  { 78, 114 }, -- juz 30: 78:1 .. 114:6
}

local reciters = {}
local surahs = {}
local everyayahReciters = {}
local ayahCounts = {}
local cacheIndex = {}
local status = {
  playing = false, name = "", reciterId = "", surahId = 1, volume = volume, url = "",
  cached = false, repeatOne = false, repeatCount = 1, repeatDone = 0, speed = 1.0,
  sleepUntil = 0, shuffle = false, position = 0, duration = 0, paused = false,
  queue = {}, queueIndex = 0, juz = 0, downloading = {},
  mode = "surah", ayah = 1, ayahCount = 0, everyayahId = "",
}
local lastSeq = -1
local launchedAt = 0
local launchedFrom = 0
local lastSavedAt = 0
local lastReciterRetry = 0
local reciterFetching, everyayahFetching, suwarFetching = false, false, false
local deadStreak = 0
local playGen = 0
local queue, queueBusy, queueSince = {}, false, 0

local seekPending, seekBusy = nil, false
local volPending, volBusy = nil, false

local doPlay, doStop, doSeek, advanceQueue

local function sq(s)
  return "'" .. string.gsub(s or "", "'", "'\\''") .. "'"
end

local function pad(n)
  return string.format("%03d", tonumber(n) or 0)
end

local function publish()
  local downloading = {}
  for k, v in pairs(status.downloading or {}) do
    if v then downloading[k] = true end
  end
  noctalia.state.set("quran_status", {
    playing = status.playing == true,
    name = status.name,
    reciterId = status.reciterId,
    surahId = status.surahId,
    volume = status.volume,
    url = status.url,
    cached = status.cached == true,
    repeatOne = status.repeatOne == true,
    repeatCount = tonumber(status.repeatCount) or 1,
    repeatDone = tonumber(status.repeatDone) or 0,
    speed = tonumber(status.speed) or 1.0,
    sleepUntil = tonumber(status.sleepUntil) or 0,
    shuffle = status.shuffle == true,
    position = tonumber(status.position) or 0,
    duration = tonumber(status.duration) or 0,
    paused = status.paused == true,
    queue = status.queue,
    queueIndex = tonumber(status.queueIndex) or 0,
    juz = tonumber(status.juz) or 0,
    downloading = downloading,
    mode = status.mode or "surah",
    ayah = tonumber(status.ayah) or 1,
    ayahCount = tonumber(status.ayahCount) or 0,
    everyayahId = status.everyayahId or "",
  })
end

local function findReciter(id)
  for _, r in ipairs(reciters) do
    if tostring(r.id) == tostring(id) then return r end
  end
  return nil
end

local function findSurah(id)
  for _, s in ipairs(surahs) do
    if tonumber(s.id) == tonumber(id) then return s end
  end
  return nil
end

local function findEveryAyah(id)
  for _, r in ipairs(everyayahReciters) do
    if tostring(r.id) == tostring(id) then return r end
  end
  return nil
end

local function ayahCountFor(surahId)
  return tonumber(ayahCounts[tonumber(surahId)]) or 0
end

-- ── offline cache ────────────────────────────────────────────────────────────

local function cacheDirFor(reciter)
  return CACHE_DIR .. "/" .. tostring(reciter.id):gsub("[^%w%-_]", "-")
end

local function cachePath(reciter, surahId)
  return cacheDirFor(reciter) .. "/" .. pad(surahId) .. ".mp3"
end

local function isCached(reciterId, surahId)
  local list = cacheIndex[tostring(reciterId)]
  return list ~= nil and list[tonumber(surahId)] ~= nil
end

local function publishCache()
  local flat = {}
  for rid, list in pairs(cacheIndex) do
    for sid, bytes in pairs(list) do
      flat[tostring(rid) .. ":" .. tostring(sid)] = bytes
    end
  end
  noctalia.state.set("quran_cache", flat)
end

local function refreshCache()
  noctalia.runAsync("find " .. sq(CACHE_DIR) .. " -type f -name '*.mp3' -printf '%p\\t%s\\n' 2>/dev/null", function(res)
    local idx = {}
    if res and res.exitCode == 0 then
      for line in tostring(res.stdout or ""):gmatch("[^\r\n]+") do
        local path, size = line:match("^(.-)\t(%d+)$")
        if path then
          local dir, num = path:match("^(.*)/(%d+)%.mp3$")
          local rid = dir and dir:match("([^/]+)$")
          if rid and num then
            idx[rid] = idx[rid] or {}
            idx[rid][tonumber(num)] = tonumber(size) or 0
          end
        end
      end
    end
    cacheIndex = idx
    publishCache()
  end)
end

local function resolveSource(reciter, surahId)
  if isCached(reciter.id, surahId) then
    return cachePath(reciter, surahId), true
  end
  return reciter.server .. pad(surahId) .. ".mp3", false
end

-- ── persistence ──────────────────────────────────────────────────────────────

local function saveState()
  local data = {
    reciterId = status.reciterId,
    surahId = status.surahId,
    position = math.floor(tonumber(status.position) or 0),
    volume = status.volume,
    speed = status.speed,
    repeatOne = status.repeatOne == true,
    repeatCount = tonumber(status.repeatCount) or 1,
    shuffle = status.shuffle == true,
    mode = status.mode or "surah",
    ayah = tonumber(status.ayah) or 1,
    everyayahId = status.everyayahId or "",
  }
  noctalia.writeFile(STATE_FILE, noctalia.json.encode(data) or "{}")
  lastSavedAt = os.time()
end

local function loadState()
  local raw = noctalia.readFile(STATE_FILE)
  if not raw then return end
  local ok, data = pcall(function() return noctalia.json.decode(raw) end)
  if not ok or type(data) ~= "table" then return end
  status.reciterId = tostring(data.reciterId or "")
  status.surahId = tonumber(data.surahId) or 1
  status.position = tonumber(data.position) or 0
  status.volume = math.clamp(math.floor(tonumber(data.volume) or volume), 0, 100)
  status.speed = tonumber(data.speed) or 1.0
  status.repeatOne = data.repeatOne == true
  status.repeatCount = math.clamp(math.floor(tonumber(data.repeatCount) or 1), 1, 5)
  status.shuffle = data.shuffle == true
  status.mode = (data.mode == "ayah") and "ayah" or "surah"
  status.ayah = tonumber(data.ayah) or 1
  status.everyayahId = tostring(data.everyayahId or "")
  noctalia.log("[quran] restored surah " .. tostring(status.surahId) .. " at " .. tostring(status.position) .. "s mode=" .. tostring(status.mode))
end

local function rebuildName()
  local s = findSurah(status.surahId)
  if not s then return end
  if status.mode == "ayah" then
    local r = findEveryAyah(status.everyayahId)
    if not r then return end
    local count = ayahCountFor(s.id)
    status.ayahCount = count
    if count > 0 then
      status.ayah = math.clamp(math.floor(tonumber(status.ayah) or 1), 1, count)
    end
    status.name = s.name .. " ayat " .. tostring(status.ayah) .. " — " .. r.name
    status.url = "https://everyayah.com/data/" .. r.id .. "/" .. pad(s.id) .. pad(status.ayah) .. ".mp3"
    status.cached = false
  else
    local r = findReciter(status.reciterId)
    if not r then return end
    local src, cached = resolveSource(r, s.id)
    status.url = src
    status.cached = cached
    status.name = s.name .. " — " .. r.name
  end
  publish()
end

-- ── mpv plumbing ─────────────────────────────────────────────────────────────

local function aliveCheck(onResult)
  local cmd = "test -S " .. sq(SOCK) .. " && test -f " .. sq(PIDFILE)
    .. " && p=$(tail -n 1 " .. sq(PIDFILE) .. ") && case \"$p\" in *[!0-9]*) exit 1 ;; esac && kill -0 \"$p\" 2>/dev/null"
    .. " && grep -qa mpv /proc/\"$p\"/cmdline 2>/dev/null"
  noctalia.runAsync(cmd, function(res)
    onResult(res.exitCode == 0)
  end)
end

local function mpvCmd(payload)
  noctalia.writeFile(dataDir .. "/mpvcmd.json", payload .. "\n")
  return "(socat - " .. sq(SOCK) .. " < " .. sq(dataDir .. "/mpvcmd.json") .. " >/dev/null 2>&1 || true)"
end

local function killRecorded(signal)
  local guard = "grep -qa mpv /proc/\"$p\"/cmdline 2>/dev/null && grep -qaF -- "
    .. sq(dataDir) .. " /proc/\"$p\"/cmdline 2>/dev/null"
  return "while read -r p; do case \"$p\" in ''|*[!0-9]*) continue ;; esac; "
    .. "if " .. guard .. "; then kill " .. signal .. " \"$p\" >/dev/null 2>&1 || true; fi; done < "
    .. sq(PIDFILE)
end

local function sweepStray(signal)
  local comm = string.match(mpvBin, "([^/]+)$") or "mpv"
  return "for f in $(grep -laF -- " .. sq(SOCK) .. " /proc/[0-9]*/cmdline 2>/dev/null); do "
    .. "p=${f#/proc/}; p=${p%/cmdline}; "
    .. "[ \"$(cat /proc/$p/comm 2>/dev/null)\" = " .. sq(comm) .. " ] || continue; "
    .. "kill " .. signal .. " \"$p\" >/dev/null 2>&1 || true; done"
end

local function killStrays(signal)
  return "if [ -f " .. sq(PIDFILE) .. " ]; then " .. killRecorded(signal) .. "; fi; "
    .. sweepStray(signal)
end

local function stopMpv(onDone)
  local parts = {}
  if hasSocat then
    table.insert(parts, mpvCmd('{"command":["quit"]}'))
  end
  table.insert(parts, "sleep 0.3")
  table.insert(parts, killStrays(""))
  table.insert(parts, "sleep 0.4")
  table.insert(parts, killStrays("-9"))
  table.insert(parts, "rm -f " .. sq(SOCK) .. " " .. sq(PIDFILE))
  noctalia.runAsync(table.concat(parts, "; "), function()
    if onDone then onDone() end
  end)
end

local function launchMpv(src, name, startAt, onDone)
  -- --start beats a post-launch seek: the IPC socket is not listening yet when
  -- the process is forked, so a seek sent right away is dropped.
  local startArg = ""
  if (tonumber(startAt) or 0) > 0 then
    startArg = " --start=" .. tostring(math.floor(tonumber(startAt)))
  end
  local cmd = "rm -f " .. sq(SOCK) .. "; "
    .. "nohup " .. sq(mpvBin) .. " --no-video --input-ipc-server=" .. sq(SOCK)
    .. " --volume=" .. tostring(status.volume)
    .. " --speed=" .. tostring(status.speed or 1.0)
    .. startArg
    .. " --title=" .. sq("quran: " .. name)
    .. " -- " .. sq(src) .. " >" .. sq(dataDir .. "/mpv.log") .. " 2>&1 & "
    .. "echo $! >> " .. sq(PIDFILE)
  noctalia.writeFile(dataDir .. "/lastcmd.txt", cmd)
  return noctalia.runAsync(cmd, function(res)
    if onDone then onDone(res) end
  end)
end

local function runNext()
  if queueBusy then return end
  local job = table.remove(queue, 1)
  if not job then return end
  queueBusy = true
  queueSince = os.time()
  local finished = false
  job(function()
    if finished then return end
    finished = true
    queueBusy = false
    runNext()
  end)
end

local function enqueue(job)
  table.insert(queue, job)
  runNext()
end

-- ── catalog ──────────────────────────────────────────────────────────────────

local function buildJuz()
  local out = {}
  for i = 1, #JUZ_SPANS do
    local from, to = JUZ_SPANS[i][1], JUZ_SPANS[i][2]
    out[#out + 1] = { id = i, from = from, to = to, count = to - from + 1 }
  end
  noctalia.state.set("quran_juz", out)
end

local function fetchReciters(attempt)
  if reciterFetching then return end
  reciterFetching = true
  attempt = attempt or 1
  noctalia.http({ url = "https://www.mp3quran.net/api/v3/reciters?language=id" }, function(res)
    reciterFetching = false
    if res and res.ok then
      local ok, data = pcall(function() return noctalia.json.decode(res.body) end)
      if ok and type(data) == "table" and type(data.reciters) == "table" then
        local out = {}
        local seen, rewayaOrder = {}, {}
        for _, q in ipairs(data.reciters) do
          for _, m in ipairs(q.moshaf or {}) do
            if m.server and tonumber(m.surah_total) == 114 then
              local rewaya = m.name or ""
              local id = tostring(q.id) .. "-" .. tostring(m.id)
              out[#out + 1] = {
                id = id,
                name = q.name,
                label = q.name .. " — " .. rewaya,
                server = m.server,
                rewaya = rewaya,
              }
              if not seen[rewaya] then
                seen[rewaya] = true
                rewayaOrder[#rewayaOrder + 1] = { id = tostring(m.rewaya_id or ""), name = rewaya }
              end
            end
          end
        end
        table.sort(rewayaOrder, function(a, b) return a.name < b.name end)
        reciters = out
        noctalia.state.set("quran_reciters", reciters)
        noctalia.state.set("quran_rewayas", rewayaOrder)
        if status.reciterId == "" and #reciters > 0 then
          status.reciterId = reciters[1].id
        end
        noctalia.log("[quran] reciters: " .. tostring(#reciters) .. ", rewayas: " .. tostring(#rewayaOrder))
        rebuildName()
        noctalia.runAsync("sleep 0.2", function() refreshCache() end)
        return
      end
    end
    noctalia.log("[quran] reciter fetch failed (attempt " .. tostring(attempt) .. ")")
    if attempt < 3 then fetchReciters(attempt + 1) end
  end)
end

local function fetchSuwar(attempt)
  if suwarFetching then return end
  suwarFetching = true
  attempt = attempt or 1
  noctalia.http({ url = "https://www.mp3quran.net/api/v3/suwar?language=id" }, function(res)
    suwarFetching = false
    if res and res.ok then
      local ok, data = pcall(function() return noctalia.json.decode(res.body) end)
      if ok and type(data) == "table" and type(data.suwar) == "table" then
        local out = {}
        for _, s in ipairs(data.suwar) do
          out[#out + 1] = { id = tonumber(s.id), name = s.name }
        end
        surahs = out
        noctalia.state.set("quran_surahs", surahs)
        buildJuz()
        noctalia.log("[quran] surahs: " .. tostring(#surahs))
        rebuildName()
        return
      end
    end
    noctalia.log("[quran] suwar fetch failed (attempt " .. tostring(attempt) .. ")")
    if attempt < 3 then
      fetchSuwar(attempt + 1)
    elseif #surahs == 0 then
      local out = {}
      for i = 1, 114 do out[i] = { id = i, name = "Surah " .. tostring(i) } end
      surahs = out
      noctalia.state.set("quran_surahs", surahs)
      buildJuz()
      noctalia.log("[quran] using fallback surah list")
    end
  end)
end

local function fetchEveryAyah(attempt)
  if everyayahFetching then return end
  everyayahFetching = true
  attempt = attempt or 1
  noctalia.http({ url = "https://everyayah.com/data/recitations.js" }, function(res)
    everyayahFetching = false
    if res and res.ok then
      local ok, data = pcall(function() return noctalia.json.decode(res.body) end)
      if ok and type(data) == "table" and type(data.ayahCount) == "table" then
        local counts = {}
        for i, v in ipairs(data.ayahCount) do counts[i] = tonumber(v) or 0 end
        local out = {}
        for k, v in pairs(data) do
          local n = tonumber(k)
          if n and type(v) == "table" and v.subfolder then
            out[#out + 1] = {
              id = tostring(v.subfolder),
              name = tostring(v.name or v.subfolder),
              bitrate = tostring(v.bitrate or ""),
              label = tostring(v.name or v.subfolder) .. " — " .. tostring(v.bitrate or ""),
            }
          end
        end
        table.sort(out, function(a, b) return a.label < b.label end)
        everyayahReciters = out
        ayahCounts = counts
        noctalia.state.set("quran_everyayah", everyayahReciters)
        noctalia.state.set("quran_ayah_counts", ayahCounts)
        if status.everyayahId == "" and #out > 0 then status.everyayahId = out[1].id end
        noctalia.log("[quran] everyayah: " .. tostring(#out) .. " reciters, surahs=" .. tostring(#counts))
        if status.mode == "ayah" then rebuildName() end
        return
      end
    end
    noctalia.log("[quran] everyayah fetch failed (attempt " .. tostring(attempt) .. ")")
    if attempt < 3 then fetchEveryAyah(attempt + 1) end
  end)
end

local function fetchCatalog()
  fetchReciters(1)
  fetchSuwar(1)
  fetchEveryAyah(1)
end

-- ── playback ─────────────────────────────────────────────────────────────────

doPlay = function(reciterId, surahId, opts)
  opts = opts or {}
  local r = findReciter(reciterId)
  local s = findSurah(surahId)
  if not r then
    noctalia.notifyError("Quran", "Qari tidak ditemukan")
    return
  end
  if not s then
    noctalia.notifyError("Quran", "Surah tidak ditemukan")
    return
  end

  local startAt = tonumber(opts.startAt)
  if startAt == nil then startAt = 0 end
  if startAt < 0 then startAt = 0 end

  local src, cached = resolveSource(r, s.id)
  playGen = playGen + 1
  local gen = playGen
  status.mode = "surah"
  status.ayah = 0
  status.ayahCount = 0
  status.reciterId = tostring(r.id)
  status.surahId = tonumber(s.id)
  status.name = s.name .. " — " .. r.name
  status.url = src
  status.cached = cached
  status.playing = true
  status.paused = false
  status.position = startAt
  status.duration = 0
  status.repeatDone = tonumber(opts.repeatDone) or 0
  publish()

  local dropped = false
  local function superseded()
    if gen == playGen then return false end
    if not dropped then
      dropped = true
      noctalia.log("[quran] play superseded")
    end
    return true
  end

  enqueue(function(done)
    if superseded() then done(); return end
    stopMpv(function()
      if superseded() then done(); return end
      launchMpv(src, status.name, startAt, function(res)
        local launched = (res == nil or res.exitCode == 0)
        noctalia.log("[quran] launched=" .. tostring(launched) .. " cached=" .. tostring(cached) .. " start=" .. tostring(startAt))
        if launched then
          launchedAt = os.time()
          launchedFrom = startAt
          deadStreak = 0
          publish()
        else
          noctalia.notifyError("Quran", "Gagal memutar mpv")
          status.playing = false
          publish()
        end
        done()
      end)
    end)
  end)
end

local function doPlayAyah(reciterId, surahId, ayah, opts)
  opts = opts or {}
  local r = findEveryAyah(reciterId)
  local s = findSurah(surahId)
  if not r then
    noctalia.notifyError("Quran", "Reciter EveryAyah tidak ditemukan")
    return
  end
  if not s then
    noctalia.notifyError("Quran", "Surah tidak ditemukan")
    return
  end
  local count = ayahCountFor(s.id)
  if count <= 0 then
    noctalia.notifyError("Quran", "Jumlah ayah belum siap")
    return
  end
  ayah = math.clamp(math.floor(tonumber(ayah) or 1), 1, count)
  local src = "https://everyayah.com/data/" .. r.id .. "/" .. pad(s.id) .. pad(ayah) .. ".mp3"
  playGen = playGen + 1
  local gen = playGen
  status.mode = "ayah"
  status.everyayahId = tostring(r.id)
  status.surahId = tonumber(s.id)
  status.ayah = ayah
  status.ayahCount = count
  status.name = s.name .. " ayat " .. tostring(ayah) .. " — " .. r.name
  status.url = src
  status.cached = false
  status.playing = true
  status.paused = false
  status.position = 0
  status.duration = 0
  status.repeatDone = tonumber(opts.repeatDone) or 0
  publish()

  local dropped = false
  local function superseded()
    if gen == playGen then return false end
    if not dropped then
      dropped = true
      noctalia.log("[quran] ayah play superseded")
    end
    return true
  end

  enqueue(function(done)
    if superseded() then done(); return end
    stopMpv(function()
      if superseded() then done(); return end
      launchMpv(src, status.name, 0, function(res)
        local launched = (res == nil or res.exitCode == 0)
        noctalia.log("[quran] ayah launched=" .. tostring(launched) .. " " .. src)
        if launched then
          launchedAt = os.time()
          launchedFrom = 0
          deadStreak = 0
          publish()
        else
          noctalia.notifyError("Quran", "Gagal memutar ayat")
          status.playing = false
          publish()
        end
        done()
      end)
    end)
  end)
end

doStop = function()
  playGen = playGen + 1
  status.playing = false
  publish()
  saveState()
  enqueue(function(done)
    stopMpv(done)
  end)
end

-- A slider drag emits one request per step; queueing them all would keep mpv
-- seeking long after the drag ended. Keep only the newest target.
doSeek = function(seconds)
  seconds = tonumber(seconds)
  if seconds == nil then return end
  if seconds < 0 then seconds = 0 end
  status.position = seconds
  publish()
  if not status.playing or not hasSocat then return end
  seekPending = seconds
  if seekBusy then return end
  local function flush()
    local target = seekPending
    seekPending = nil
    if target == nil then
      seekBusy = false
      return
    end
    seekBusy = true
    noctalia.runAsync(mpvCmd('{"command":["seek",' .. tostring(target) .. ',"absolute"]}'), function()
      seekBusy = false
      if seekPending ~= nil then flush() end
    end)
  end
  flush()
end

local function doVolume(v)
  v = math.clamp(math.floor(tonumber(v) or status.volume), 0, 100)
  if v == status.volume then return end
  status.volume = v
  publish()
  if not status.playing then return end
  if hasSocat then
    volPending = v
    if volBusy then return end
    local function flush()
      local target = volPending
      volPending = nil
      if target == nil then
        volBusy = false
        return
      end
      volBusy = true
      noctalia.runAsync(mpvCmd('{"command":["set_property","volume",' .. tostring(target) .. "]}"), function()
        volBusy = false
        if volPending ~= nil then flush() end
      end)
    end
    flush()
  else
    local url = status.url
    if url == "" then return end
    enqueue(function(done)
      if not status.playing or url ~= status.url then done(); return end
      stopMpv(function()
        if not status.playing or url ~= status.url then done(); return end
        launchMpv(url, status.name, 0, function() done() end)
      end)
    end)
  end
end

local function doSpeed(v)
  v = tonumber(v)
  if v == nil then return end
  v = math.clamp(v, 0.5, 2.0)
  status.speed = v
  publish()
  saveState()
  if not status.playing or not hasSocat then return end
  enqueue(function(done)
    noctalia.runAsync(mpvCmd('{"command":["set_property","speed",' .. tostring(v) .. "]}"), function()
      done()
    end)
  end)
end

local function doRepeat(value)
  if value == nil then
    status.repeatOne = not (status.repeatOne == true)
  else
    status.repeatOne = (value == true or value == "true" or value == 1 or value == "1")
  end
  publish()
  saveState()
end

local function doRepeatCount(value)
  status.repeatCount = math.clamp(math.floor(tonumber(value) or 1), 1, 5)
  status.repeatDone = 0
  publish()
  saveState()
end

local function doSleep(minutes)
  minutes = tonumber(minutes) or 0
  if minutes <= 0 then
    status.sleepUntil = 0
  else
    status.sleepUntil = os.time() + math.floor(minutes * 60)
  end
  publish()
end

local function doShuffle(value)
  if value == nil then
    status.shuffle = not (status.shuffle == true)
  else
    status.shuffle = (value == true or value == "true" or value == 1 or value == "1")
  end
  publish()
  saveState()
end

local function queryProgressFromLog()
  if hasSocat then return end
  noctalia.runAsync("tail -n 30 " .. sq(dataDir .. "/mpv.log") .. " 2>/dev/null", function(res)
    if not (res and res.exitCode == 0) then return end
    local lastPos, lastDur
    for line in tostring(res.stdout or ""):gmatch("[^\r\n]+") do
      local p, d = line:match("A:%s*(%d+:%d+)%s*/%s*(%d+:%d+)")
      if p then lastPos, lastDur = p, d end
    end
    if not lastPos then return end
    local function toSec(t)
      local m, sec = t:match("(%d+):(%d+)")
      return (tonumber(m) or 0) * 60 + (tonumber(sec) or 0)
    end
    if status.playing then
      status.position = toSec(lastPos)
      status.duration = toSec(lastDur)
      publish()
    end
  end)
end

local function queryProgress()
  if not hasSocat or not status.playing then return end
  local cmd = "{ printf '%s\\n' '{\"command\":[\"get_property\",\"playback-time\"],\"request_id\":1}' '{\"command\":[\"get_property\",\"duration\"],\"request_id\":2}' '{\"command\":[\"get_property\",\"pause\"],\"request_id\":3}'; } | socat - " .. sq(SOCK)
  noctalia.runAsync(cmd, function(res)
    if not (res and res.exitCode == 0) then return end
    local pos, dur = status.position, status.duration
    local paused
    for line in tostring(res.stdout or ""):gmatch("[^\r\n]+") do
      local ok, data = pcall(function() return noctalia.json.decode(line) end)
      if ok and type(data) == "table" and data.request_id and data.data ~= nil then
        if data.request_id == 1 then pos = tonumber(data.data) or pos end
        if data.request_id == 2 then dur = tonumber(data.data) or dur end
        if data.request_id == 3 then paused = (data.data == true) end
      end
    end
    if status.playing then
      status.position = pos
      status.duration = dur
      -- Media keys and the bar's media widget pause mpv behind our back; mirror
      -- that so the widget glyph and the panel stop claiming it is playing.
      if paused ~= nil then status.paused = paused end
      publish()
    end
  end)
end

-- ── queue / juz ──────────────────────────────────────────────────────────────

advanceQueue = function()
  local q = status.queue or {}
  if #q == 0 then return false end
  local i = tonumber(status.queueIndex) or 0
  if i < #q then
    status.queueIndex = i + 1
    doPlay(status.reciterId, q[status.queueIndex], { startAt = 0 })
    return true
  end
  status.queue = {}
  status.queueIndex = 0
  status.juz = 0
  publish()
  return false
end

local function doJuz(n)
  n = tonumber(n)
  if not n or n < 1 or n > 30 then return end
  local span = JUZ_SPANS[n]
  local from, to = span[1], span[2]
  local ids = {}
  for i = from, to do ids[#ids + 1] = i end
  status.queue = ids
  status.queueIndex = 1
  status.juz = n
  publish()
  noctalia.log("[quran] juz " .. tostring(n) .. " -> " .. tostring(#ids) .. " surah")
  doPlay(status.reciterId, ids[1], { startAt = 0 })
end

local function sequentialFrom(step)
  if #surahs == 0 then return tonumber(status.surahId) or 1 end
  local i = 1
  for idx, s in ipairs(surahs) do
    if tonumber(s.id) == tonumber(status.surahId) then i = idx; break end
  end
  return surahs[((i - 1 + step) % #surahs) + 1].id
end

local function stepAyah(step)
  local count = ayahCountFor(status.surahId)
  if count <= 0 then return false end
  local a = (tonumber(status.ayah) or 1) + step
  if a > count then
    local sid = sequentialFrom(1)
    if ayahCountFor(sid) > 0 then
      doPlayAyah(status.everyayahId, sid, 1, { startAt = 0 })
    end
    return true
  end
  if a < 1 then
    local sid = sequentialFrom(-1)
    local c = ayahCountFor(sid)
    if c > 0 then doPlayAyah(status.everyayahId, sid, c, { startAt = 0 }) end
    return true
  end
  doPlayAyah(status.everyayahId, status.surahId, a, { startAt = 0 })
  return true
end

-- ── downloads ────────────────────────────────────────────────────────────────

local function doDownload(surahId)
  local r = findReciter(status.reciterId)
  local s = findSurah(surahId)
  if not r or not s then
    noctalia.notifyError("Quran", "Qari/surah tidak ditemukan")
    return
  end
  if isCached(r.id, s.id) then
    noctalia.notify("Quran", tostring(s.name) .. " sudah tersimpan")
    return
  end
  local path = cachePath(r, s.id)
  local url = r.server .. pad(s.id) .. ".mp3"
  status.downloading[tostring(s.id)] = true
  publish()
  local cmd = "mkdir -p " .. sq(cacheDirFor(r))
    .. " && curl -fsSL --retry 2 --connect-timeout 20 -o " .. sq(path .. ".part") .. " " .. sq(url)
    .. " && mv -f " .. sq(path .. ".part") .. " " .. sq(path)
    .. " && stat -c %s " .. sq(path)
  noctalia.log("[quran] download " .. url)
  noctalia.runAsync(cmd, function(res)
    status.downloading[tostring(s.id)] = nil
    if res and res.exitCode == 0 then
      local bytes = tonumber(noctalia.string.trim(tostring(res.stdout or ""))) or 0
      cacheIndex[tostring(r.id)] = cacheIndex[tostring(r.id)] or {}
      cacheIndex[tostring(r.id)][tonumber(s.id)] = bytes
      publishCache()
      noctalia.notify("Quran", tostring(s.name) .. " terunduh (" .. tostring(math.floor(bytes / 1024)) .. " KB)")
      if tonumber(status.surahId) == tonumber(s.id) and tostring(status.reciterId) == tostring(r.id) then
        status.cached = true
      end
    else
      noctalia.runAsync("rm -f " .. sq(path .. ".part"), nil)
      noctalia.notifyError("Quran", "Unduhan gagal: " .. tostring(s.name))
    end
    publish()
  end)
end

local function doRemoveDownload(surahId)
  local r = findReciter(status.reciterId)
  local s = findSurah(surahId)
  if not r or not s then return end
  local path = cachePath(r, s.id)
  noctalia.runAsync("rm -f " .. sq(path), function()
    if cacheIndex[tostring(r.id)] then
      cacheIndex[tostring(r.id)][tonumber(s.id)] = nil
    end
    publishCache()
    if tonumber(status.surahId) == tonumber(s.id) and tostring(status.reciterId) == tostring(r.id) then
      status.cached = false
      status.url = r.server .. pad(s.id) .. ".mp3"
    end
    publish()
    noctalia.notify("Quran", "Hapus unduhan " .. tostring(s.name))
  end)
end

-- ── request dispatch ─────────────────────────────────────────────────────────

local function handleRequest(req)
  if type(req) ~= "table" then return end
  local seq = tonumber(req.seq) or -1
  if seq <= lastSeq then return end
  lastSeq = seq
  noctalia.log("[quran] request action=" .. tostring(req.action))
  local action = req.action
  if action == "play" then
    status.queue, status.queueIndex, status.juz = {}, 0, 0
    doPlay(req.reciterId or status.reciterId, req.surahId or status.surahId, { startAt = 0 })
  elseif action == "playAyah" then
    status.queue, status.queueIndex, status.juz = {}, 0, 0
    doPlayAyah(req.everyayahId or status.everyayahId, req.surahId or status.surahId, req.ayah or status.ayah, { startAt = 0 })
  elseif action == "setMode" then
    status.mode = (req.mode == "ayah") and "ayah" or "surah"
    if status.mode == "ayah" and status.everyayahId == "" and #everyayahReciters > 0 then
      status.everyayahId = everyayahReciters[1].id
    end
    status.ayahCount = ayahCountFor(status.surahId)
    if status.ayahCount > 0 then
      status.ayah = math.clamp(tonumber(status.ayah) or 1, 1, status.ayahCount)
    end
    rebuildName()
    saveState()
  elseif action == "setEveryAyah" then
    status.everyayahId = tostring(req.everyayahId)
    rebuildName()
    saveState()
  elseif action == "setAyah" then
    local count = ayahCountFor(status.surahId)
    if count > 0 then
      status.ayah = math.clamp(math.floor(tonumber(req.ayah) or 1), 1, count)
    end
    rebuildName()
    saveState()
  elseif action == "stop" then
    doStop()
  elseif action == "toggle" then
    if status.playing and status.paused then
      -- Paused from a media key: resume in place instead of relaunching mpv.
      status.paused = false
      publish()
      if hasSocat then
        enqueue(function(done)
          noctalia.runAsync(mpvCmd('{"command":["set_property","pause",false]}'), function()
            done()
          end)
        end)
      end
    elseif status.playing then
      doStop()
    elseif status.mode == "ayah" then
      doPlayAyah(status.everyayahId, status.surahId, status.ayah, { startAt = 0 })
    else
      doPlay(status.reciterId, status.surahId, { startAt = tonumber(status.position) or 0 })
    end
  elseif action == "juz" then
    doJuz(req.juz)
  elseif action == "volume" then
    doVolume(req.volume)
  elseif action == "speed" then
    doSpeed(req.speed)
  elseif action == "repeat" then
    doRepeat(req.value)
  elseif action == "repeatCount" then
    doRepeatCount(req.value)
  elseif action == "sleep" then
    doSleep(req.minutes)
  elseif action == "shuffle" then
    doShuffle(req.value)
  elseif action == "seek" then
    doSeek(req.seconds)
  elseif action == "download" then
    doDownload(req.surahId or status.surahId)
  elseif action == "removeDownload" then
    doRemoveDownload(req.surahId or status.surahId)
  elseif action == "cache" then
    refreshCache()
  elseif action == "next" then
    status.repeatDone = 0
    if status.mode == "ayah" then
      stepAyah(1)
    elseif not advanceQueue() then
      doPlay(status.reciterId, sequentialFrom(1), { startAt = 0 })
    end
  elseif action == "prev" then
    status.repeatDone = 0
    if status.mode == "ayah" then
      stepAyah(-1)
    else
      local q = status.queue or {}
      local i = tonumber(status.queueIndex) or 0
      if #q > 0 and i > 1 then
        status.queueIndex = i - 1
        doPlay(status.reciterId, q[status.queueIndex], { startAt = 0 })
      else
        doPlay(status.reciterId, sequentialFrom(-1), { startAt = 0 })
      end
    end
  elseif action == "setReciter" then
    status.reciterId = tostring(req.reciterId)
    rebuildName()
    saveState()
  elseif action == "setSurah" then
    status.surahId = tonumber(req.surahId) or status.surahId
    status.ayahCount = ayahCountFor(status.surahId)
    if status.ayahCount > 0 then
      status.ayah = math.clamp(tonumber(status.ayah) or 1, 1, status.ayahCount)
    end
    rebuildName()
    saveState()
  end
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

-- mpv-mpris installs into /etc/mpv/scripts, which mpv auto-loads for every
-- instance. Passing --script= as well exports the D-Bus object twice and the
-- second registration fails, so detection here is informational only.
noctalia.runAsync("test -f /etc/mpv/scripts/mpris.so && echo etc || (test -f /usr/lib/mpv-mpris/mpris.so && echo lib || true)", function(res)
  hasMpris = res ~= nil and res.exitCode == 0 and tostring(res.stdout or ""):find("%a") ~= nil
  noctalia.log("[quran] mpris auto-load=" .. tostring(hasMpris))
end)

loadState()
noctalia.state.set("quran_juz", {})
noctalia.state.set("quran_rewayas", {})
noctalia.state.set("quran_cache", {})

noctalia.state.watch("quran_request", handleRequest)

-- The host keeps the last request across a service restart. Replaying it would
-- resume playback every time the plugin reloads, so seed the dedupe counter with
-- whatever is already there and only honour requests that arrive afterwards.
local initial = noctalia.state.get("quran_request")
if type(initial) == "table" and tonumber(initial.seq) then
  lastSeq = tonumber(initial.seq)
end

publish()
fetchCatalog()

noctalia.setUpdateInterval(2000)

function update()
  if #reciters == 0 and os.time() - lastReciterRetry > 20 then
    lastReciterRetry = os.time()
    noctalia.log("[quran] reciter list empty, retrying")
    fetchReciters(1)
  end
  if queueBusy and os.time() - queueSince > 15 then
    noctalia.log("[quran] queue stuck, reset")
    queue, queueBusy = {}, false
  end
  if status.playing and (tonumber(status.sleepUntil) or 0) > 0 and os.time() >= tonumber(status.sleepUntil) then
    status.sleepUntil = 0
    doStop()
    return
  end
  if status.playing then
    if hasSocat then queryProgress() else queryProgressFromLog() end
    if os.time() - lastSavedAt >= 15 then saveState() end
    if os.time() - launchedAt < 8 then return end
    aliveCheck(function(alive)
      if not status.playing then return end
      if alive then
        deadStreak = 0
        return
      end
      deadStreak = deadStreak + 1
      if deadStreak < 2 then return end
      deadStreak = 0
      -- A surah resumed near its end finishes within seconds of launch, which
      -- the old "died under 30s" rule reported as a playback failure. Judge by
      -- progress instead: anything that advanced means the file played out.
      local advanced = (tonumber(status.position) or 0) - (tonumber(launchedFrom) or 0)
      if advanced < 3 and os.time() - launchedAt < 30 then
        status.playing = false
        publish()
        noctalia.notifyError("Quran", "Gagal memutar (" .. tostring(status.name) .. ")")
        noctalia.log("[quran] mpv died fast, see mpv.log advanced=" .. tostring(advanced))
        return
      end
      if status.repeatOne == true then
        if status.mode == "ayah" then
          doPlayAyah(status.everyayahId, status.surahId, status.ayah, { startAt = 0 })
        else
          doPlay(status.reciterId, status.surahId, { startAt = 0 })
        end
        return
      end
      local rc = tonumber(status.repeatCount) or 1
      local doneCount = tonumber(status.repeatDone) or 0
      if rc > 1 and doneCount + 1 < rc then
        if status.mode == "ayah" then
          doPlayAyah(status.everyayahId, status.surahId, status.ayah, { startAt = 0, repeatDone = doneCount + 1 })
        else
          doPlay(status.reciterId, status.surahId, { startAt = 0, repeatDone = doneCount + 1 })
        end
        return
      end
      status.repeatDone = 0
      if status.mode == "ayah" then
        if status.shuffle == true and #surahs > 0 then
          math.randomseed(os.time())
          local sid = surahs[math.random(#surahs)].id
          if ayahCountFor(sid) > 0 then doPlayAyah(status.everyayahId, sid, 1, { startAt = 0 }) end
          return
        end
        stepAyah(1)
        return
      end
      if advanceQueue() then return end
      if status.shuffle == true and #surahs > 0 then
        math.randomseed(os.time())
        doPlay(status.reciterId, surahs[math.random(#surahs)].id, { startAt = 0 })
        return
      end
      if #surahs > 0 then
        doPlay(status.reciterId, sequentialFrom(1), { startAt = 0 })
      else
        status.playing = false
        publish()
      end
    end)
  end
end

function onConfigChanged()
  volume = math.clamp(math.floor(tonumber(noctalia.getConfig("default_volume")) or volume), 0, 100)
  mpvBin = noctalia.getConfig("mpv_bin") or mpvBin
  hasSocat = noctalia.commandExists("socat")
  if not status.playing then
    status.volume = volume
    publish()
  end
end

function onIpc(event, payload)
  noctalia.log("[quran] onIpc " .. tostring(event))
  local function fire(tbl)
    tbl.seq = lastSeq + 1
    handleRequest(tbl)
  end
  if event == "play" and payload and payload ~= "" then
    local ok, data = pcall(function() return noctalia.json.decode(payload) end)
    if ok and type(data) == "table" then
      fire({ action = "play", reciterId = data.reciterId, surahId = data.surahId })
    else
      fire({ action = "play" })
    end
  elseif event == "playAyah" and payload and payload ~= "" then
    local ok, data = pcall(function() return noctalia.json.decode(payload) end)
    if ok and type(data) == "table" then
      fire({ action = "playAyah", everyayahId = data.everyayahId, surahId = data.surahId, ayah = data.ayah })
    end
  elseif event == "setMode" then
    fire({ action = "setMode", mode = payload })
  elseif event == "setEveryAyah" then
    fire({ action = "setEveryAyah", everyayahId = payload })
  elseif event == "setAyah" then
    local n = tonumber(payload)
    if n then fire({ action = "setAyah", ayah = n }) end
  elseif event == "stop" then
    fire({ action = "stop" })
  elseif event == "toggle" then
    fire({ action = "toggle" })
  elseif event == "volume" then
    local v = tonumber(payload)
    if v then fire({ action = "volume", volume = v }) end
  elseif event == "next" then
    fire({ action = "next" })
  elseif event == "prev" then
    fire({ action = "prev" })
  elseif event == "speed" then
    local v = tonumber(payload)
    if v then fire({ action = "speed", speed = v }) end
  elseif event == "repeat" then
    fire({ action = "repeat" })
  elseif event == "repeatCount" then
    local v = tonumber(payload)
    if v then fire({ action = "repeatCount", value = v }) end
  elseif event == "sleep" then
    local m = tonumber(payload)
    if m then fire({ action = "sleep", minutes = m }) end
  elseif event == "shuffle" then
    fire({ action = "shuffle" })
  elseif event == "seek" then
    local sec = tonumber(payload)
    if sec then fire({ action = "seek", seconds = sec }) end
  elseif event == "juz" then
    local n = tonumber(payload)
    if n then fire({ action = "juz", juz = n }) end
  elseif event == "download" then
    fire({ action = "download" })
  elseif event == "removeDownload" then
    fire({ action = "removeDownload" })
  elseif event == "cache" then
    fire({ action = "cache" })
  elseif event == "refresh" then
    fetchCatalog()
  end
end

function onExit(signal, reason)
  saveState()
  doStop()
end
