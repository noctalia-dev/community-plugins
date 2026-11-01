--!nonstrict
-- Headless service for Wallpaper Deck (Noctalia v5).
-- Handles directory scanning, caching, Matugen color extraction,
-- wallpaper applying (native / custom), live previewing, favorites persistence,
-- and Wallhaven search.

local STATE_DIR = (type(noctalia.pluginDataDir) == "function" and noctalia.pluginDataDir())
  or noctalia.expandPath("~/.local/state/noctalia/plugins/data/ishan0121/wallpaper-deck")

local CACHE_FILE = STATE_DIR .. "/cache.json"
local DECK_FILE = STATE_DIR .. "/deck.json"
local THUMB_DIR = STATE_DIR .. "/thumbs"
local FAVORITES_FILE = STATE_DIR .. "/favorites.json"

local FALLBACK_M3 = {
  primary = "#80a9ff",
  secondary = "#bfc6dc",
  tertiary = "#dfbde4",
  primary_container = "#20468a",
  surface_container_highest = "#33353b",
  source_color = "#4285f4",
}

local function rgbToHls(r: number, g: number, b: number): (number, number, number)
  local max = math.max(r, g, b)
  local min = math.min(r, g, b)
  local l = (max + min) / 2
  if max == min then
    return 0, l, 0
  end
  local d = max - min
  local s = l > 0.5 and (d / (2 - max - min)) or (d / (max + min))
  local h = 0
  if max == r then
    h = ((g - b) / d) + (g < b and 6 or 0)
  elseif max == g then
    h = ((b - r) / d) + 2
  else
    h = ((r - g) / d) + 4
  end
  h = h / 6
  return h, l, s
end

local function calcHueKey(hexColor: string?): number
  if not hexColor or #hexColor < 7 then return 3.0 end
  local hStr = string.gsub(hexColor, "^#", "")
  if #hStr ~= 6 then return 3.0 end
  local r = tonumber(string.sub(hStr, 1, 2), 16)
  local g = tonumber(string.sub(hStr, 3, 4), 16)
  local b = tonumber(string.sub(hStr, 5, 6), 16)
  if not r or not g or not b then return 3.0 end
  r, g, b = r / 255, g / 255, b / 255
  local h, l, s = rgbToHls(r, g, b)
  local hexLower = string.lower(hexColor)
  if s < 0.12 or hexLower == "#4285f4" or hexLower == "#000000" or hexLower == "#ffffff" then
    return 1.0 + l
  end
  return (h + 0.035) % 1.0
end

local hashKeyCache = {}
local function hashKey(s: string): string
  local cached = hashKeyCache[s]
  if cached then return cached end
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 4294967296
  end
  local res = string.format("%08x", h)
  hashKeyCache[s] = res
  return res
end

local favorites = {}
local isScanning = false
local scanToken = 0
local currentActive = ""
local initialWallpaper = ""
local customWallpaperDir: string? = nil

local function dirExists(path: string): boolean
  if not path or path == "" then return false end
  return noctalia.listDir(path) ~= nil
end

local function getWallhavenDownloadDir(): string
  local customDownloadDir = noctalia.getConfig("wallhaven_download_dir")
  if customDownloadDir and customDownloadDir ~= "" then
    local expanded = noctalia.expandPath(customDownloadDir)
    pcall(noctalia.mkdirAll, expanded)
    return expanded
  end

  local candidateWh = noctalia.expandPath("~/Pictures/WallHaven")
  local candidateWhLower = noctalia.expandPath("~/Pictures/wallhaven")
  if dirExists(candidateWh) then
    return candidateWh
  elseif dirExists(candidateWhLower) then
    return candidateWhLower
  end

  pcall(noctalia.mkdirAll, candidateWh)
  return candidateWh
end

local function resolveDirs(overrideDir: string?): { string }
  local dirs = {}
  local seen = {}

  local function addDir(path: string?, ensureExists: boolean?)
    if not path or path == "" then return end
    local exp = noctalia.expandPath(path)
    if exp and exp ~= "" then
      exp = string.gsub(exp, "/+$", "")
    end
    if not seen[exp] then
      if ensureExists then
        pcall(noctalia.mkdirAll, exp)
      end
      if dirExists(exp) then
        seen[exp] = true
        table.insert(dirs, exp)
      end
    end
  end

  local function parseAndAdd(inputStr: string?)
    if not inputStr or inputStr == "" then return end
    for part in string.gmatch(inputStr, "([^,;:]+)") do
      local trimmed = string.match(part, "^%s*(.-)%s*$")
      if trimmed and trimmed ~= "" then
        addDir(trimmed, false)
      end
    end
  end

  if type(overrideDir) == "string" and overrideDir ~= "" then
    if string.find(overrideDir, "|||", 1, true) then
      for part in string.gmatch(overrideDir, "([^|]+)") do
        addDir(part, false)
      end
    else
      parseAndAdd(overrideDir)
    end
    if #dirs > 0 then
      return dirs
    end
  end

  -- 1. Primary wallpaper directory
  local configured = noctalia.getConfig("wallpaper_dir")
  if configured and configured ~= "" then
    parseAndAdd(configured)
  end

  if #dirs == 0 and customWallpaperDir and customWallpaperDir ~= "" then
    addDir(customWallpaperDir, true)
  end

  if #dirs == 0 then
    local nativeDir = type(noctalia.wallpaperDirectory) == "function" and noctalia.wallpaperDirectory()
    if nativeDir and nativeDir ~= "" and dirExists(nativeDir) then
      addDir(nativeDir, false)
    end
  end

  if #dirs == 0 then
    local wpLower = noctalia.expandPath("~/Pictures/wallpapers")
    local wpUpper = noctalia.expandPath("~/Pictures/Wallpapers")
    if dirExists(wpLower) then
      addDir(wpLower, false)
    elseif dirExists(wpUpper) then
      addDir(wpUpper, false)
    else
      addDir(wpLower, true)
    end
  end

  -- 2. Additional wallpaper directory (dedicated folder setting)
  local extraDir = noctalia.getConfig("extra_wallpaper_dir")
  if extraDir and extraDir ~= "" then
    parseAndAdd(extraDir)
  end

  -- 3. Auto-include Wallhaven downloads (defaults to true)
  local incWh = noctalia.getConfig("include_wallhaven_downloads")
  if incWh ~= false then
    local whDir = getWallhavenDownloadDir()
    addDir(whDir, true)
  end

  -- 4. Additional arbitrary directories (string_list table or legacy comma/colon string)
  local addDirs = noctalia.getConfig("additional_wallpaper_dirs")
  if type(addDirs) == "table" then
    for _, d in ipairs(addDirs) do
      if type(d) == "string" and d ~= "" then
        addDir(d, false)
      end
    end
  elseif type(addDirs) == "string" and addDirs ~= "" then
    parseAndAdd(addDirs)
  end

  return dirs
end

local function resolveDir(overrideDir: string?): string
  local dirs = resolveDirs(overrideDir)
  return dirs[1] or noctalia.expandPath("~/Pictures/wallpapers")
end

local function findCacheFile(): string
  if noctalia.fileExists(CACHE_FILE) then
    return CACHE_FILE
  end
  local legacy = noctalia.expandPath("~/.local/state/noctalia/wallpaper-deck/cache.json")
  if noctalia.fileExists(legacy) then
    return legacy
  end
  return CACHE_FILE
end

local function loadFavorites()
  favorites = {}
  local raw = noctalia.readFile(FAVORITES_FILE)
  if raw and raw ~= "" then
    local ok, decoded = pcall(noctalia.json.decode, raw)
    if ok and type(decoded) == "table" then
      for k, v in pairs(decoded) do
        if v == true then
          favorites[k] = true
        end
      end
    end
  end
  noctalia.state.set("favorites", favorites)
end

local function saveFavorites()
  noctalia.mkdirAll(STATE_DIR)
  local ok, enc = pcall(noctalia.json.encode, favorites)
  if ok and enc then
    noctalia.writeFile(FAVORITES_FILE, enc)
  end
  noctalia.state.set("favorites", favorites)
end

local function stripExtension(name: string): string
  local dot = string.find(name, "%.[^%.]+$")
  if dot and dot > 1 then
    return string.sub(name, 1, dot - 1)
  end
  return name
end

local function toggleFavorite(fileName: string, itemPath: string?)
  if not fileName or fileName == "" then return end
  local base = stripExtension(fileName)
  local isCurrentlyFav = favorites[fileName] or favorites[base] or (itemPath and favorites[itemPath])

  if isCurrentlyFav then
    favorites[fileName] = nil
    favorites[base] = nil
    if itemPath and itemPath ~= "" then
      favorites[itemPath] = nil
    end
    for _, ext in ipairs({ ".jpg", ".jpeg", ".png", ".webp" }) do
      favorites[base .. ext] = nil
    end
  else
    favorites[fileName] = true
    if string.sub(base, 1, 10) == "wallhaven-" then
      favorites[base] = true
      for _, ext in ipairs({ ".jpg", ".png", ".webp" }) do
        favorites[base .. ext] = true
      end
    end
  end
  saveFavorites()
end

local function detectActiveWallpaper()
  -- 1. Try native in-process Noctalia API first (plugin_api >= 25)
  if type(noctalia.wallpaperPath) == "function" then
    local conn = (type(noctalia.focusedOutputName) == "function" and noctalia.focusedOutputName()) or nil
    if not conn and type(noctalia.outputs) == "function" then
      local ok, outs = pcall(noctalia.outputs)
      if ok and type(outs) == "table" and #outs > 0 then
        conn = outs[1].name
      end
    end
    if conn and conn ~= "" then
      local ok, wp = pcall(noctalia.wallpaperPath, conn)
      if ok and type(wp) == "string" and wp ~= "" then
        currentActive = wp
        if initialWallpaper == "" then
          initialWallpaper = wp
        end
        noctalia.state.set("active_wallpaper", wp)
        return
      end
    end
  end

  -- 2. Fallback to CLI query
  noctalia.runAsync({ "noctalia", "msg", "wallpaper-get" }, function(res)
    if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
      local line = string.match(res.stdout, "[^\r\n]+")
      if line and line ~= "" then
        currentActive = line
        if initialWallpaper == "" then
          initialWallpaper = line
        end
        noctalia.state.set("active_wallpaper", line)
      end
    end
  end)
end

local activeDeckInMemory: { any } = {}
local activeCacheInMemory: { [string]: any } = {}
local scanSubdirs = true

local function loadDeckFromDisk(): {any}
  local targetFile = DECK_FILE
  if not noctalia.fileExists(targetFile) then
    local legacy = noctalia.expandPath("~/.local/state/noctalia/wallpaper-deck/deck.json")
    if noctalia.fileExists(legacy) then
      targetFile = legacy
    end
  end

  if #activeDeckInMemory > 0 then
    return activeDeckInMemory
  end
  if noctalia.fileExists(targetFile) then
    local raw = noctalia.readFile(targetFile)
    if raw and raw ~= "" then
      local ok, dec = pcall(noctalia.json.decode, raw)
      if ok and type(dec) == "table" and #dec > 0 then
        activeDeckInMemory = dec
        return dec
      end
    end
  end
  return {}
end

local matugenQueue = {}
local matugenActive = 0
local MAX_MATUGEN_JOBS = 2

local thumbQueue = {}
local thumbActive = 0
local MAX_THUMB_JOBS = 3

local function loadCache(): { [string]: any }
  if next(activeCacheInMemory) ~= nil then
    return activeCacheInMemory
  end
  local targetFile = findCacheFile()
  if noctalia.fileExists(targetFile) then
    local raw = noctalia.readFile(targetFile)
    if raw and raw ~= "" then
      local ok, dec = pcall(noctalia.json.decode, raw)
      if ok and type(dec) == "table" then
        activeCacheInMemory = dec
        return dec
      end
    end
  end
  return {}
end

local function writeTextFile(path: string, content: string)
  pcall(noctalia.writeFile, path, content)
end

local function pruneCacheToDeck(cache: { [string]: any }, deck: { any }?): { [string]: any }
  if not deck or #deck == 0 then return cache end
  local activePaths = {}
  for _, it in ipairs(deck) do
    if it.path then activePaths[it.path] = true end
  end
  local pruned = {}
  for p, entry in pairs(cache) do
    local fname = string.match(p, "([^/]+)$") or p
    if activePaths[p] or favorites[p] or favorites[fname] then
      pruned[p] = entry
    end
  end
  return pruned
end

local function saveDeckToDisk(deck: { any })
  local ok, deckJson = pcall(noctalia.json.encode, deck)
  if ok and deckJson then
    writeTextFile(DECK_FILE, deckJson)
  end
end

local function saveCacheToDisk(cache: { [string]: any })
  noctalia.mkdirAll(STATE_DIR)
  local ok, enc = pcall(noctalia.json.encode, cache)
  if ok and enc then
    writeTextFile(CACHE_FILE, enc)
  end
end

local function rebuildAndPublishColourDeck(deck: { any })
  if not deck or #deck == 0 then return end
  local withHue = {}
  local withoutHue = {}
  for _, it in ipairs(deck) do
    if it.hueKey then
      table.insert(withHue, it)
    else
      table.insert(withoutHue, it)
    end
  end
  if #withHue > 1 then
    table.sort(withHue, function(a, b) return (a.hueKey or 0) < (b.hueKey or 0) end)
  end
  for _, it in ipairs(withoutHue) do
    table.insert(withHue, it)
  end
  noctalia.state.set("wallpapers_colour", withHue)
end

local lastStateSyncTime = 0
local cacheNeedsSave = false
local syncInProgress = false
local pickerPanelOpen = false

local function scheduleCacheAndStateSync(deck: { any }, cache: { [string]: any }, force: boolean?)
  cacheNeedsSave = true
  local now = (type(noctalia.nowMs) == "function") and noctalia.nowMs() or 0
  if not syncInProgress and (force or (now - lastStateSyncTime >= 2500)) then
    lastStateSyncTime = now
    syncInProgress = true
    noctalia.runAsync({ "true" }, function()
      syncInProgress = false
      if not cacheNeedsSave then return end
      cacheNeedsSave = false
      noctalia.state.set("wallpapers", deck)
      rebuildAndPublishColourDeck(deck)
      noctalia.runAsync({ "true" }, function()
        pcall(saveCacheToDisk, pruneCacheToDeck(cache, deck))
        noctalia.runAsync({ "true" }, function()
          pcall(saveDeckToDisk, deck)
        end)
      end)
    end)
  end
end

local function prioritizePalette(p: string)
  if not (type(noctalia.commandExists) == "function" and noctalia.commandExists("matugen")) then
    return
  end
  if not p or not noctalia.fileExists(p) then return end

  noctalia.runAsync({ "true" }, function()
    local cache = loadCache()
    if cache[p] and cache[p].colors and cache[p].colors.primary ~= "#80a9ff" then
      local entry = cache[p]
      noctalia.state.set("palette_update", {
        path = p,
        colors = entry.colors,
        sourceColor = entry.sourceColor,
        hueKey = entry.hueKey or calcHueKey(entry.sourceColor or entry.colors.primary),
      })
      return
    end

    local key = hashKey(p)
    local cardThumb = THUMB_DIR .. "/" .. key .. "_card.webp"
    local inputPath = noctalia.fileExists(cardThumb) and cardThumb or p

    noctalia.runAsync({ "matugen", "image", inputPath, "--source-color-index", "0", "--dry-run", "-j", "hex", "-q" }, function(res)
      if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
        local ok, data = pcall(noctalia.json.decode, res.stdout)
        if ok and type(data) == "table" and type(data.colors) == "table" then
          local colors = data.colors
          local function getCol(role)
            local c = colors[role]
            if type(c) == "table" then
              local d = c["default"] or c["dark"]
              if type(d) == "table" then return d.color end
            end
            return nil
          end
          local prim = getCol("primary")
          local sec = getCol("secondary")
          local tert = getCol("tertiary")
          local pc = getCol("primary_container")
          local sch = getCol("surface_container_highest") or getCol("surface_container") or getCol("surface")
          local sc = getCol("source_color") or prim
          if prim and sec then
            local m3 = {
              primary = prim,
              secondary = sec,
              tertiary = tert or sec,
              primary_container = pc or prim,
              surface_container_highest = sch or "#33353b",
              source_color = sc or prim,
            }
            local hueKey = calcHueKey(sc or prim)

            if not cache[p] then cache[p] = {} end
            cache[p].colors = m3
            cache[p].sourceColor = sc or prim
            cache[p].hueKey = hueKey
            cacheNeedsSave = true

            noctalia.state.set("palette_update", {
              path = p,
              colors = m3,
              sourceColor = sc or prim,
              hueKey = hueKey,
            })

            if #activeDeckInMemory > 0 then
              for _, it in ipairs(activeDeckInMemory) do
                if it.path == p then
                  it.colors = m3
                  it.sourceColor = sc or prim
                  it.hueKey = hueKey
                  break
                end
              end
              scheduleCacheAndStateSync(activeDeckInMemory, cache, false)
            end
          end
        end
      end
    end)
  end)
end

local matugenQueueHead = 1
local matugenProcessedSinceSync = 0

local function pumpMatugenQueue(token: number, cache: { [string]: any }, deck: { any })
  if not (type(noctalia.commandExists) == "function" and noctalia.commandExists("matugen")) then
    return
  end
  -- Throttle to 1 background job while panel is open so animations stay 60fps smooth
  local maxJobs = pickerPanelOpen and 1 or MAX_MATUGEN_JOBS
  while matugenActive < maxJobs and matugenQueueHead <= #matugenQueue do
    if token ~= scanToken then return end
    local item = matugenQueue[matugenQueueHead]
    matugenQueueHead = matugenQueueHead + 1
    local p = item.path

    if item.colors and item.colors.primary ~= "#80a9ff" then
      -- Already has valid colors, skip
    elseif p and noctalia.fileExists(p) then
      local key = hashKey(p)
      local cardThumb = THUMB_DIR .. "/" .. key .. "_card.webp"
      local inputPath = (item.thumb and noctalia.fileExists(item.thumb)) and item.thumb
        or (noctalia.fileExists(cardThumb) and cardThumb or p)

      matugenActive = matugenActive + 1
      noctalia.runAsync({ "matugen", "image", inputPath, "--source-color-index", "0", "--dry-run", "-j", "hex", "-q" }, function(res)
        matugenActive = math.max(0, matugenActive - 1)
        if token ~= scanToken then return end
        if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
          local ok, data = pcall(noctalia.json.decode, res.stdout)
          if ok and type(data) == "table" and type(data.colors) == "table" then
            local colors = data.colors
            local function getCol(role)
              local c = colors[role]
              if type(c) == "table" then
                local d = c["default"] or c["dark"]
                if type(d) == "table" then return d.color end
              end
              return nil
            end
            local prim = getCol("primary")
            local sec = getCol("secondary")
            local tert = getCol("tertiary")
            local pc = getCol("primary_container")
            local sch = getCol("surface_container_highest") or getCol("surface_container") or getCol("surface")
            local sc = getCol("source_color") or prim
            if prim and sec then
              local m3 = {
                primary = prim,
                secondary = sec,
                tertiary = tert or sec,
                primary_container = pc or prim,
                surface_container_highest = sch or "#33353b",
                source_color = sc or prim,
              }
              item.colors = m3
              item.sourceColor = sc or prim
              item.hueKey = calcHueKey(sc or prim)

              if not cache[p] then cache[p] = {} end
              cache[p].colors = m3
              cache[p].sourceColor = sc or prim
              cache[p].hueKey = item.hueKey
              cache[p].mtime = item.mtime
              cache[p].size = item.size
              cacheNeedsSave = true

              noctalia.state.set("palette_update", {
                path = p,
                colors = m3,
                sourceColor = sc or prim,
                hueKey = item.hueKey,
              })
            end
          end
        end

        matugenProcessedSinceSync = matugenProcessedSinceSync + 1
        if matugenProcessedSinceSync >= 15 then
          matugenProcessedSinceSync = 0
          scheduleCacheAndStateSync(deck, cache, false)
        end

        pumpMatugenQueue(token, cache, deck)
      end)
    end
  end

  if matugenActive == 0 and matugenQueueHead > #matugenQueue then
    matugenQueue = {}
    matugenQueueHead = 1
    if cacheNeedsSave then
      scheduleCacheAndStateSync(deck, cache, true)
    end
  end
end

local thumbQueueHead = 1

local function pumpThumbQueue(token: number, cache: { [string]: any }, deck: { any })
  local tool = nil
  if type(noctalia.commandExists) == "function" then
    if noctalia.commandExists("ffmpeg") then
      tool = "ffmpeg"
    elseif noctalia.commandExists("magick") then
      tool = "magick"
    end
  end
  if not tool then
    pumpMatugenQueue(token, cache, deck)
    return
  end

  local checkedInTick = 0
  local MAX_CHECK_PER_TICK = 30

  while thumbActive < MAX_THUMB_JOBS and thumbQueueHead <= #thumbQueue do
    if token ~= scanToken then return end
    local item = thumbQueue[thumbQueueHead]
    thumbQueueHead = thumbQueueHead + 1
    local p = item.path
    local key = hashKey(p)
    local cardThumb = THUMB_DIR .. "/" .. key .. "_card.webp"

    checkedInTick = checkedInTick + 1

    if noctalia.fileExists(cardThumb) then
      item.thumb = cardThumb
      item.preview = cardThumb
      if not cache[p] then cache[p] = {} end
      cache[p].thumb = cardThumb
      cache[p].preview = cardThumb
      if checkedInTick >= MAX_CHECK_PER_TICK then
        noctalia.runAsync({ "true" }, function()
          pumpThumbQueue(token, cache, deck)
        end)
        return
      end
    else
      thumbActive = thumbActive + 1
      local argv
      if tool == "ffmpeg" then
        argv = { "ffmpeg", "-y", "-loglevel", "error", "-i", p, "-vf", "scale=420:280:force_original_aspect_ratio=decrease", "-q:v", "78", cardThumb }
      else
        argv = { "magick", p, "-thumbnail", "420x280^", "-gravity", "center", "-extent", "420x280", "-quality", "78", cardThumb }
      end

      noctalia.runAsync(argv, function(res)
        thumbActive = math.max(0, thumbActive - 1)
        if token ~= scanToken then return end
        if res and res.exitCode == 0 and noctalia.fileExists(cardThumb) then
          item.thumb = cardThumb
          item.preview = cardThumb
          if not cache[p] then cache[p] = {} end
          cache[p].thumb = cardThumb
          cache[p].preview = cardThumb
          cache[p].mtime = item.mtime
          cache[p].size = item.size
          cacheNeedsSave = true
          noctalia.state.set("thumb_update", {
            path = p,
            thumb = cardThumb,
            nonce = noctalia.nowMs(),
          })
        end
        pumpThumbQueue(token, cache, deck)
      end)
    end
  end

  if thumbActive == 0 and thumbQueueHead > #thumbQueue then
    thumbQueue = {}
    thumbQueueHead = 1
    if cacheNeedsSave then
      scheduleCacheAndStateSync(deck, cache, true)
    end
    pumpMatugenQueue(token, cache, deck)
  end
end

local function processScanOutput(stdout: string, dirs: {string}, primaryDir: string, token: number, hasStats: boolean)
  if token ~= scanToken then return end

  local cache = loadCache()
  local rawLines = string.split(stdout, "\n")
  local seen = {}
  local results = {}
  matugenQueue = {}
  matugenQueueHead = 1
  thumbQueue = {}
  thumbQueueHead = 1

  local dirInfos = {}
  for idx, rDir in ipairs(dirs) do
    table.insert(dirInfos, {
      dir = rDir,
      len = #rDir,
      name = string.match(rDir, "([^/]+)$") or rDir,
      idx = idx,
    })
  end

  local lineIdx = 1
  local BATCH_SIZE = 20

  local function fastFileName(p: string): string
    for j = #p, 1, -1 do
      if string.byte(p, j) == 47 then
        return string.sub(p, j + 1)
      end
    end
    return p
  end

  local function fastBaseAndExt(fn: string): (string, string)
    for j = #fn, 1, -1 do
      if string.byte(fn, j) == 46 then
        if j > 1 then
          return string.sub(fn, 1, j - 1), string.upper(string.sub(fn, j + 1))
        else
          return fn, ""
        end
      end
    end
    return fn, ""
  end

  local function fastFolder(sub: string): string?
    for j = #sub, 1, -1 do
      if string.byte(sub, j) == 47 then
        return (j > 1) and string.sub(sub, 1, j - 1) or nil
      end
    end
    return nil
  end

  local function processBatch()
    if token ~= scanToken then return end

    local endIdx = math.min(#rawLines, lineIdx + BATCH_SIZE - 1)
    for i = lineIdx, endIdx do
      local line = rawLines[i]
      local trimmed = string.match(line, "^%s*(.-)%s*$")
      if trimmed and trimmed ~= "" then
        local fileName = nil
        local filePath, sizeStr, mtimeStr
        if hasStats then
          local tab1 = string.find(trimmed, "\t", 1, true)
          if tab1 then
            local tab2 = string.find(trimmed, "\t", tab1 + 1, true)
            if tab2 then
              local tab3 = string.find(trimmed, "\t", tab2 + 1, true)
              fileName = string.sub(trimmed, 1, tab1 - 1)
              filePath = string.sub(trimmed, tab1 + 1, tab2 - 1)
              if tab3 then
                sizeStr = string.sub(trimmed, tab2 + 1, tab3 - 1)
                mtimeStr = string.sub(trimmed, tab3 + 1)
              else
                sizeStr = string.sub(trimmed, tab2 + 1)
                mtimeStr = "0"
              end
            else
              filePath = string.sub(trimmed, 1, tab1 - 1)
              sizeStr = string.sub(trimmed, tab1 + 1)
              mtimeStr = "0"
            end
          else
            filePath = trimmed
          end
        else
          filePath = trimmed
        end

        if filePath and filePath ~= "" and not seen[filePath] then
          local isHidden = (string.find(filePath, "/%.") ~= nil)
          if not isHidden then
            seen[filePath] = true
            if not fileName or fileName == "" then
              fileName = fastFileName(filePath)
            end
            if fileName and string.sub(fileName, 1, 1) ~= "." then
              local base, ext = fastBaseAndExt(fileName)
              local size = tonumber(sizeStr) or 0
              local mtime = math.floor(tonumber(mtimeStr) or 0)

              local relDir = ""
              local isSubdir = false
              for _, dInfo in ipairs(dirInfos) do
                if string.sub(filePath, 1, dInfo.len) == dInfo.dir then
                  local sub = string.sub(filePath, dInfo.len + 2)
                  local folder = fastFolder(sub)
                  if folder and folder ~= "" and folder ~= "." then
                    isSubdir = true
                    if #dirs > 1 and dInfo.idx > 1 then
                      relDir = dInfo.name .. "/" .. folder
                    else
                      relDir = folder
                    end
                  elseif #dirs > 1 and dInfo.idx > 1 then
                    isSubdir = true
                    relDir = dInfo.name
                  end
                  break
                end
              end

              local cached = cache[filePath]
              local colors = nil
              local sourceColor = nil
              local hueKey = nil
              local thumb = nil
              local preview = nil
              local resStr = nil
              local topLum = nil
              local isLight = nil

              if cached and (cached.mtime == mtime or mtime == 0) and (cached.size == size or size == 0) then
                colors = cached.colors
                sourceColor = cached.sourceColor
                hueKey = cached.hueKey
                thumb = cached.thumb
                preview = cached.preview
                resStr = cached.res
                topLum = cached.topLum
                isLight = cached.isLight
              end

              local key = hashKey(filePath)
              local cardThumb = THUMB_DIR .. "/" .. key .. "_card.webp"

              local hasCardThumb = noctalia.fileExists(cardThumb)
              local effectiveThumb = (hasCardThumb and cardThumb) or (thumb and thumb ~= filePath and thumb) or nil

              local item: { [string]: any } = {
                path = filePath,
                name = fileName,
                base = base,
                ext = (ext ~= "" and ext) or "IMG",
                lowerName = string.lower(fileName),
                mtime = mtime,
                size = size,
              }
              local hasRealColors = (colors and colors.primary and colors.primary ~= "#80a9ff")
              if hasRealColors then
                item.colors = colors
                item.sourceColor = sourceColor
                item.hueKey = hueKey or calcHueKey(sourceColor or colors.primary)
              end
              if topLum ~= nil then item.topLum = topLum end
              if isLight ~= nil then item.isLight = isLight end
              if effectiveThumb then
                item.thumb = effectiveThumb
                item.preview = effectiveThumb
              end
              if resStr and resStr ~= "" then item.res = resStr end
              if isSubdir then
                item.isSubdir = true
                item.relDir = relDir
              end
              table.insert(results, item)

              if not effectiveThumb then
                table.insert(thumbQueue, item)
              end
              if not hasRealColors then
                table.insert(matugenQueue, item)
              end
            end
          end
        end
      end
    end

    lineIdx = endIdx + 1
    if lineIdx <= #rawLines then
      noctalia.runAsync({ "true" }, processBatch)
      return
    end

    -- Run finalization in decoupled async callback ticks so each stage has a fresh CPU budget
    noctalia.runAsync({ "true" }, function()
      if token ~= scanToken then return end

      local selectedDeck = results
      activeDeckInMemory = selectedDeck
      activeCacheInMemory = cache

      noctalia.runAsync({ "true" }, function()
        if token ~= scanToken then return end
        noctalia.state.set("wallpapers", selectedDeck)
        noctalia.state.set("wallpaper_dir", primaryDir)
        noctalia.state.set("wallpaper_dirs", dirs)

        isScanning = false
        noctalia.state.set("is_scanning", false)

        noctalia.runAsync({ "true" }, function()
          local ok, deckJson = pcall(noctalia.json.encode, selectedDeck)
          if ok and deckJson then
            writeTextFile(DECK_FILE, deckJson)
          end
        end)

        -- Generate and broadcast newestDeck and colourDeck in decoupled async ticks
        local isSub = if scanSubdirs == nil then true else (scanSubdirs == true or scanSubdirs == "true" or scanSubdirs == 1)
        local depthPart = if not isSub then "-maxdepth 1 " else ""
        local newestCmd = { "sh", "-c", [[find -L "$@" ]] .. depthPart .. [[\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.bmp" -o -iname "*.avif" \) -printf "%T@\t%p\n" | sort -rn | cut -f 2]], "sh" }
        for _, d in ipairs(dirs) do table.insert(newestCmd, d) end

        noctalia.runAsync(newestCmd, function(nRes)
          if token ~= scanToken then return end
          if nRes and nRes.exitCode == 0 and nRes.stdout and nRes.stdout ~= "" then
            local byPath = {}
            for _, it in ipairs(selectedDeck) do
              if it.path then byPath[it.path] = it end
            end
            local newestDeck = {}
            local pLines = string.split(nRes.stdout, "\n")
            for _, p in ipairs(pLines) do
              local it = byPath[p]
              if it then table.insert(newestDeck, it) end
            end
            if #newestDeck > 0 then
              noctalia.state.set("wallpapers_newest", newestDeck)
            end
          end

          noctalia.runAsync({ "true" }, function()
            if token ~= scanToken then return end
            rebuildAndPublishColourDeck(selectedDeck)
          end)
        end)

        -- Start thumbnail generator (which chains into Matugen palette extraction)
        noctalia.runAsync({ "true" }, function()
          if token ~= scanToken then return end
          pumpThumbQueue(token, cache, selectedDeck)
        end)
      end)
    end)
  end

  noctalia.runAsync({ "true" }, processBatch)
end

local function scanWallpapers(targetDir: any?)
  local overrideStr = (type(targetDir) == "string") and targetDir or nil
  local dirs = resolveDirs(overrideStr)
  local primaryDir = dirs[1] or resolveDir()
  customWallpaperDir = primaryDir

  scanToken = scanToken + 1
  local myToken = scanToken

  isScanning = true
  noctalia.state.set("is_scanning", true)
  noctalia.state.set("wallpaper_dir", primaryDir)
  noctalia.state.set("wallpaper_dirs", dirs)

  noctalia.mkdirAll(STATE_DIR)
  noctalia.mkdirAll(THUMB_DIR)

  if #dirs == 0 then
    isScanning = false
    noctalia.state.set("is_scanning", false)
    noctalia.state.set("wallpapers", {})
    return
  end

  local cfgSub = noctalia.getConfig("scan_subdirectories")
  if cfgSub == nil then
    scanSubdirs = true
  else
    scanSubdirs = (cfgSub == true or cfgSub == "true" or cfgSub == 1)
  end

  local depthArg = if not scanSubdirs then "-maxdepth 1 " else ""
  local findArgs = {
    "sh",
    "-c",
    [[find -L "$@" ]] .. depthArg .. [[\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.bmp" -o -iname "*.avif" \) -printf "%f\t%p\t%s\t%T@\n" | sort -f]],
    "sh",
  }
  for _, d in ipairs(dirs) do
    table.insert(findArgs, d)
  end

  noctalia.runAsync(findArgs, function(res)
    if myToken ~= scanToken then
      return
    end

    if not res or res.exitCode ~= 0 or not res.stdout or res.stdout == "" then
      local fallbackArgs = { "find", "-L" }
      for _, d in ipairs(dirs) do
        table.insert(fallbackArgs, d)
      end
      if not scanSubdirs then
        table.insert(fallbackArgs, "-maxdepth")
        table.insert(fallbackArgs, "1")
      end
      table.insert(fallbackArgs, "-type")
      table.insert(fallbackArgs, "f")
      table.insert(fallbackArgs, "(")
      table.insert(fallbackArgs, "-iname")
      table.insert(fallbackArgs, "*.jpg")
      table.insert(fallbackArgs, "-o")
      table.insert(fallbackArgs, "-iname")
      table.insert(fallbackArgs, "*.jpeg")
      table.insert(fallbackArgs, "-o")
      table.insert(fallbackArgs, "-iname")
      table.insert(fallbackArgs, "*.png")
      table.insert(fallbackArgs, "-o")
      table.insert(fallbackArgs, "-iname")
      table.insert(fallbackArgs, "*.webp")
      table.insert(fallbackArgs, "-o")
      table.insert(fallbackArgs, "-iname")
      table.insert(fallbackArgs, "*.gif")
      table.insert(fallbackArgs, "-o")
      table.insert(fallbackArgs, "-iname")
      table.insert(fallbackArgs, "*.bmp")
      table.insert(fallbackArgs, "-o")
      table.insert(fallbackArgs, "-iname")
      table.insert(fallbackArgs, "*.avif")
      table.insert(fallbackArgs, ")")

      noctalia.runAsync(fallbackArgs, function(fbRes)
        if myToken ~= scanToken then return end
        if not fbRes or fbRes.exitCode ~= 0 or not fbRes.stdout or fbRes.stdout == "" then
          isScanning = false
          noctalia.state.set("is_scanning", false)
          local cached = loadDeckFromDisk()
          if #cached > 0 then
            noctalia.state.set("wallpapers", cached)
          else
            noctalia.state.set("wallpapers", {})
          end
          return
        end
        processScanOutput(fbRes.stdout, dirs, primaryDir, myToken, false)
      end)
      return
    end

    processScanOutput(res.stdout, dirs, primaryDir, myToken, true)
  end)
end

local function previewWallpaper(path: string)
  if not path or path == "" then return end
  noctalia.setWallpaper(path)
end

local function executeShellTemplate(template: string, path: string, outputTarget: string?)
  if not template or template == "" then return end
  local out = outputTarget or "*"

  local script = template
  script = string.gsub(script, '"{path}"', '"$1"')
  script = string.gsub(script, "'{path}'", '"$1"')
  script = string.gsub(script, "{path}", '"$1"')

  script = string.gsub(script, '"{output}"', '"$2"')
  script = string.gsub(script, "'{output}'", '"$2"')
  script = string.gsub(script, "{output}", '"$2"')

  noctalia.runAsync({ "sh", "-c", script, "wallpaper-deck", path, out }, function() end)
end

local function applyWallpaper(path: string, outputTarget: string?)
  local mode = noctalia.getConfig("backend_mode") or "native"

  if mode == "custom" then
    local cmd = noctalia.getConfig("custom_command") or ""
    executeShellTemplate(cmd, path, outputTarget)
  else
    if outputTarget and outputTarget ~= "*" and outputTarget ~= "ALL" then
      noctalia.setWallpaperEnabled(outputTarget, true)
      noctalia.setWallpaper(outputTarget, path)
    else
      noctalia.setWallpaper(path)
    end
  end

  local postHook = noctalia.getConfig("post_hook_command") or ""
  if postHook ~= "" then
    executeShellTemplate(postHook, path, outputTarget)
  end

  currentActive = path
  initialWallpaper = path
  noctalia.state.set("active_wallpaper", path)
end

local function revertPreview()
  if initialWallpaper and initialWallpaper ~= "" then
    noctalia.setWallpaper(initialWallpaper)
    noctalia.state.set("active_wallpaper", initialWallpaper)
  end
end

local WALLHAVEN_CACHE_DIR = noctalia.expandPath("~/.local/state/noctalia/wallhaven/thumbs")
local WALLHAVEN_PREVIEW_DIR = noctalia.expandPath("~/.cache/noctalia/wallhaven-previews")

local currentWallhavenItems = {}
local activeWallhavenFilters = {}
local activeWallhavenQuery = ""

local function prunePreviewCache()
  local maxMb = tonumber(noctalia.getConfig("wallhaven_cache_limit_mb")) or 300
  if maxMb <= 0 then maxMb = 300 end
  local maxBytes = maxMb * 1024 * 1024

  if not noctalia.fileExists(WALLHAVEN_PREVIEW_DIR) then return end

  local files = noctalia.listDir(WALLHAVEN_PREVIEW_DIR)
  if not files or #files == 0 then return end

  local entries = {}
  local totalBytes = 0

  for _, fname in ipairs(files) do
    if fname ~= "." and fname ~= ".." then
      local fullPath = WALLHAVEN_PREVIEW_DIR .. "/" .. fname
      local info = type(noctalia.fileInfo) == "function" and noctalia.fileInfo(fullPath)
      if info and not info.isDir and (info.size or 0) > 0 then
        totalBytes = totalBytes + info.size
        table.insert(entries, {
          path = fullPath,
          size = info.size,
          mtime = info.mtime or 0,
        })
      elseif info and not info.isDir and (info.size or 0) == 0 then
        pcall(noctalia.removeFile, fullPath)
      end
    end
  end

  if totalBytes <= maxBytes then
    return
  end

  if #entries > 1 then
    table.sort(entries, function(a, b)
      return (a.mtime or 0) < (b.mtime or 0)
    end)
  end

  local targetBytes = math.floor(maxBytes * 0.75)
  for _, entry in ipairs(entries) do
    if totalBytes <= targetBytes then
      break
    end
    pcall(noctalia.removeFile, entry.path)
    totalBytes = totalBytes - entry.size
  end
end

local function clearAllPreviewCache()
  if not noctalia.fileExists(WALLHAVEN_PREVIEW_DIR) then return end
  local files = noctalia.listDir(WALLHAVEN_PREVIEW_DIR)
  if not files then return end
  for _, fname in ipairs(files) do
    if fname ~= "." and fname ~= ".." then
      pcall(noctalia.removeFile, WALLHAVEN_PREVIEW_DIR .. "/" .. fname)
    end
  end
  if type(noctalia.notify) == "function" then
    pcall(noctalia.notify, "Wallpaper Deck", "Wallhaven preview cache cleared")
  end
end

local function searchWallhaven(query: string, pageNum: number, append: boolean?, filters: any?)
  pcall(noctalia.mkdirAll, WALLHAVEN_CACHE_DIR)
  pcall(noctalia.mkdirAll, WALLHAVEN_PREVIEW_DIR)

  if append == true then
    filters = filters or activeWallhavenFilters
    query = (query and query ~= "") and query or activeWallhavenQuery
  else
    activeWallhavenFilters = filters or {}
    activeWallhavenQuery = query or ""
  end
  filters = filters or {}

  local apiKey = noctalia.getConfig("wallhaven_api_key") or ""
  if apiKey == "" and type(noctalia.getSetting) == "function" then
    local pcallOk, officialKey = pcall(noctalia.getSetting, "plugin_settings.noctalia/wallhaven.api_key")
    if pcallOk and type(officialKey) == "string" and officialKey ~= "" then
      apiKey = officialKey
    end
  end

  local categories = filters.categories or noctalia.getConfig("wallhaven_categories") or "111"
  local purity = filters.purity or noctalia.getConfig("wallhaven_purity") or "100"
  local sorting = filters.sorting or noctalia.getConfig("wallhaven_sorting") or "date_added"
  local order = filters.order or noctalia.getConfig("wallhaven_order") or "desc"

  if sorting == "relevance" and (query == nil or query == "") then
    sorting = "date_added"
  end
  if query and query ~= "" and (sorting == "hot" or sorting == "toplist") then
    sorting = "relevance"
  end

  local params = {
    "categories=" .. categories,
    "purity=" .. purity,
    "sorting=" .. sorting,
    "order=" .. order,
    "page=" .. tostring(pageNum or 1),
  }
  if query and query ~= "" then
    table.insert(params, "q=" .. noctalia.string.urlEncode(query))
  end
  if apiKey and apiKey ~= "" then
    table.insert(params, "apikey=" .. noctalia.string.urlEncode(apiKey))
  end

  if filters.ratios and filters.ratios ~= "" then
    table.insert(params, "ratios=" .. noctalia.string.urlEncode(filters.ratios))
  end

  if filters.resolution and filters.resolution ~= "" then
    if filters.resolutionMode == "exact" then
      table.insert(params, "resolutions=" .. noctalia.string.urlEncode(filters.resolution))
    else
      table.insert(params, "atleast=" .. noctalia.string.urlEncode(filters.resolution))
    end
  end

  local headers = {
    "Accept: application/json",
    "User-Agent: Noctalia/1.0 (WallpaperDeck)",
  }
  if apiKey and apiKey ~= "" then
    table.insert(headers, "X-API-Key: " .. apiKey)
  end

  local url = "https://wallhaven.cc/api/v1/search?" .. table.concat(params, "&")
  noctalia.state.set("wallhaven_loading", true)
  noctalia.state.set("wallhaven_error", nil)

  local handleFailure = function(resp)
    noctalia.state.set("wallhaven_loading", false)
    local status = resp and resp.status
    local isOffline = (status == nil or status == 0 or status == 503 or status == 504)
    local errMsg = isOffline and "Network unavailable. Please check your internet connection."
      or (status == 401 or status == 403) and "Wallhaven API Key is invalid or expired."
      or (status == 429) and "Too many requests to Wallhaven. Please wait a moment."
      or ("Failed to contact Wallhaven (HTTP " .. tostring(status or "error") .. ")")

    if type(noctalia.log) == "function" then
      noctalia.log("[DECK_SERVICE] Wallhaven HTTP request failed: " .. tostring(resp and (resp.status or resp.error)))
    end

    noctalia.state.set("wallhaven_error", {
      type = isOffline and "offline" or "http_error",
      status = status,
      message = errMsg,
      nonce = noctalia.nowMs(),
    })

    if append == true then
      pcall(noctalia.notifyError, "Wallhaven", errMsg)
    else
      currentWallhavenItems = {}
      noctalia.state.set("wallhaven_results", {
        query = query,
        page = 1,
        lastPage = 1,
        total = 0,
        items = {},
        isAppend = false,
        nonce = noctalia.nowMs(),
      })
    end
  end

  local accepted = noctalia.http({ url = url, headers = headers }, function(resp)
    if not resp or (resp.ok == false and resp.status ~= 200) or not resp.body then
      handleFailure(resp)
      return
    end

    local ok, data = pcall(noctalia.json.decode, resp.body)
    if not ok or not data or not data.data then
      noctalia.state.set("wallhaven_loading", false)
      noctalia.state.set("wallhaven_error", {
        type = "invalid_response",
        status = 200,
        message = "Invalid response received from Wallhaven.",
        nonce = noctalia.nowMs(),
      })
      if append ~= true then
        currentWallhavenItems = {}
        noctalia.state.set("wallhaven_results", {
          query = query,
          page = 1,
          lastPage = 1,
          total = 0,
          items = {},
          isAppend = false,
          nonce = noctalia.nowMs(),
        })
      end
      return
    end

    noctalia.state.set("wallhaven_loading", false)
    noctalia.state.set("wallhaven_error", nil)

    local results = {}
    for _, item in ipairs(data.data) do
      local thumbUrl = (item.thumbs and item.thumbs.large) or (item.thumbs and item.thumbs.original) or (item.thumbs and item.thumbs.small) or item.path
      local primaryCol = (item.colors and item.colors[1]) or "#4285f4"
      local localThumb = WALLHAVEN_CACHE_DIR .. "/" .. item.id .. ".jpg"
      local hasLocalThumb = noctalia.fileExists(localThumb)

      table.insert(results, {
        id = item.id,
        name = "wallhaven-" .. item.id,
        base = "wallhaven-" .. item.id,
        path = item.path,
        fullUrl = item.path,
        thumbUrl = thumbUrl,
        thumb = hasLocalThumb and localThumb or nil,
        preview = hasLocalThumb and localThumb or nil,
        resolution = item.resolution or "HD",
        size = item.file_size or 0,
        favorites = item.favorites or 0,
        colors = {
          primary = (item.colors and item.colors[1]) or "#80a9ff",
          secondary = (item.colors and item.colors[2]) or "#bfc6dc",
          tertiary = (item.colors and item.colors[3]) or "#dfbde4",
          primary_container = (item.colors and item.colors[4]) or "#20468a",
          surface_container_highest = (item.colors and item.colors[5]) or "#33353b",
          source_color = primaryCol,
        },
        sourceColor = primaryCol,
        hueKey = calcHueKey(primaryCol),
        kind = "IMG",
        ext = string.upper(item.file_type and string.match(item.file_type, "/([^/]+)$") or "JPG"),
      })
    end

    if append ~= true then
      currentWallhavenItems = {}
    elseif #currentWallhavenItems == 0 then
      local existing = noctalia.state.get("wallhaven_results")
      if type(existing) == "table" and type(existing.items) == "table" then
        currentWallhavenItems = {}
        for _, it in ipairs(existing.items) do
          table.insert(currentWallhavenItems, it)
        end
      end
    end
    for _, it in ipairs(results) do
      table.insert(currentWallhavenItems, it)
    end

    local lastPage = 1
    if data.meta and type(data.meta.last_page) == "number" then
      lastPage = math.max(1, math.floor(data.meta.last_page))
    end
    local totalCount = #currentWallhavenItems
    if data.meta and type(data.meta.total) == "number" then
      totalCount = data.meta.total
    end

    noctalia.state.set("wallhaven_results", {
      query = query,
      page = pageNum or 1,
      lastPage = lastPage,
      total = totalCount,
      items = currentWallhavenItems,
      newBatch = results,
      isAppend = (append == true),
      nonce = noctalia.nowMs(),
    })
  end)

  if not accepted then
    handleFailure(nil)
  end
end

-- Download or copy the FULL high-res wallpaper ONLY when user selects/applies it
local function downloadAndApplyWallhaven(item: any, outputTarget: string?, cachedPath: string?)
  if not item or not item.fullUrl then return end
  local dir = getWallhavenDownloadDir()

  local urlExt = string.match(item.fullUrl or item.path or "", "%.([^%.]+)$")
  local ext = string.lower(urlExt or item.ext or "jpg")
  if ext == "jpeg" then ext = "jpg" end
  local targetPath = dir .. "/wallhaven-" .. item.id .. "." .. ext

  local baseDir = resolveDir()

  -- 1. Check if already exists in target directory or base directory
  local existingCandidates = {
    targetPath,
    dir .. "/wallhaven-" .. item.id .. ".jpg",
    dir .. "/wallhaven-" .. item.id .. ".png",
    dir .. "/wallhaven-" .. item.id .. ".jpeg",
    baseDir .. "/wallhaven-" .. item.id .. ".jpg",
    baseDir .. "/wallhaven-" .. item.id .. ".png",
    baseDir .. "/wallhaven-" .. item.id .. ".jpeg",
  }
  for _, cp in ipairs(existingCandidates) do
    if noctalia.fileExists(cp) then
      applyWallpaper(cp, outputTarget)
      return
    end
  end

  -- 2. Check if already downloaded into preview cache (from Hi-Res preview)
  local previewCandidates = {
    cachedPath,
    item.hiResPath,
    WALLHAVEN_PREVIEW_DIR .. "/" .. item.id .. "." .. ext,
    WALLHAVEN_PREVIEW_DIR .. "/" .. item.id .. ".jpg",
    WALLHAVEN_PREVIEW_DIR .. "/" .. item.id .. ".png",
    WALLHAVEN_PREVIEW_DIR .. "/" .. item.id .. ".jpeg",
  }
  local validCache = nil
  for _, cp in ipairs(previewCandidates) do
    if cp and cp ~= "" and noctalia.fileExists(cp) then
      validCache = cp
      break
    end
  end

  if validCache then
    pcall(noctalia.notify, "Wallhaven", "Saving " .. item.name .. " to " .. dir .. "...")
    noctalia.runAsync({ "cp", "-f", validCache, targetPath }, function(res)
      if res and res.exitCode == 0 and noctalia.fileExists(targetPath) then
        applyWallpaper(targetPath, outputTarget)
        pcall(noctalia.notify, "Wallhaven", "Applied " .. item.name)
        scanWallpapers()
      else
        pcall(noctalia.notifyError, "Wallhaven", "Failed to copy cached wallpaper")
      end
    end)
    return
  end

  -- 3. Not in cache: download directly to target directory
  pcall(noctalia.notify, "Wallhaven", "Downloading full wallpaper " .. item.name .. "...")

  local downloadDone = function(ok: boolean)
    if ok and noctalia.fileExists(targetPath) then
      applyWallpaper(targetPath, outputTarget)
      pcall(noctalia.notify, "Wallhaven", "Applied " .. item.name)
      scanWallpapers()
    else
      pcall(noctalia.notifyError, "Wallhaven", "Failed to download wallpaper")
    end
  end

  local started = noctalia.download(item.fullUrl, targetPath, function(ok)
    downloadDone(ok)
  end)

  if not started then
    noctalia.runAsync({ "curl", "-sL", "-o", targetPath, item.fullUrl }, function(res)
      if res and res.exitCode == 0 and noctalia.fileExists(targetPath) then
        downloadDone(true)
      else
        downloadDone(false)
      end
    end)
  end
end

-- Listen to picker commands
noctalia.state.watch("deck_command", function(cmd)
  if type(cmd) ~= "table" then return end
  local action = cmd.action
  if action == "preview" and cmd.path then
    previewWallpaper(cmd.path)
  elseif action == "revert" then
    revertPreview()
  elseif action == "apply" and cmd.path then
    applyWallpaper(cmd.path, cmd.output)
  elseif action == "rescan" then
    isScanning = false
    scanWallpapers(cmd.dir)
  elseif action == "change_dir" and cmd.dir then
    customWallpaperDir = cmd.dir
    isScanning = false
    scanWallpapers(cmd.dir)
  elseif action == "toggle_favorite" and cmd.fileName then
    toggleFavorite(cmd.fileName, cmd.path)
  elseif action == "wallhaven_search" then
    searchWallhaven(cmd.query or "", cmd.page or 1, cmd.append == true, cmd.filters)
  elseif action == "wallhaven_apply" and cmd.item then
    downloadAndApplyWallhaven(cmd.item, cmd.output, cmd.cachedPath)
    prunePreviewCache()
  elseif action == "prioritize_palette" and cmd.path then
    prioritizePalette(cmd.path)
  elseif action == "panel_state" then
    pickerPanelOpen = (cmd.open == true)
    if not pickerPanelOpen and #activeDeckInMemory > 0 then
      pumpMatugenQueue(scanToken, activeCacheInMemory, activeDeckInMemory)
    end
  elseif action == "prune_cache" then
    noctalia.runAsync({ "true" }, prunePreviewCache)
  elseif action == "clear_preview_cache" then
    noctalia.runAsync({ "true" }, clearAllPreviewCache)
  end
end)

function onEnable()
  loadFavorites()
  detectActiveWallpaper()
  noctalia.runAsync({ "true" }, function()
    scanWallpapers()
  end)
  noctalia.runAsync({ "true" }, function()
    prunePreviewCache()
  end)
end

function onOutputsChanged()
  detectActiveWallpaper()
  noctalia.state.set("outputs_changed", noctalia.nowMs())
end

function onConfigChanged()
  isScanning = false
  customWallpaperDir = nil
  scanWallpapers()
  noctalia.runAsync({ "true" }, prunePreviewCache)
end

function onIpc(event: string, payload: string?)
  if event == "rescan" then
    isScanning = false
    scanWallpapers(payload)
  elseif event == "change_dir" and payload then
    customWallpaperDir = payload
    isScanning = false
    scanWallpapers(payload)
  elseif event == "apply" and payload then
    applyWallpaper(payload, nil)
  elseif event == "preview" and payload then
    previewWallpaper(payload)
  elseif event == "revert" then
    revertPreview()
  elseif event == "toggle_favorite" and payload then
    toggleFavorite(payload, nil)
  elseif event == "prune_cache" then
    prunePreviewCache()
  elseif event == "clear_preview_cache" then
    clearAllPreviewCache()
  end
end

-- Bootstrap
loadFavorites()
detectActiveWallpaper()
