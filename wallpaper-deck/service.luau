--!nonstrict
-- Headless service for Wallpaper Deck (Noctalia v5).
-- Handles directory scanning, caching, Matugen color extraction,
-- wallpaper applying (native / custom), live previewing, favorites persistence,
-- and Wallhaven search.

local pluginDir = (type(noctalia.pluginDir) == "function" and noctalia.pluginDir())
  or noctalia.expandPath("~/.local/share/noctalia/plugins/wallpaper-deck")

local HELPER_SCRIPT = pluginDir .. "/scripts/wallpaper_helper.py"
if not noctalia.fileExists(HELPER_SCRIPT) then
  local devHelper = noctalia.expandPath("~/Documents/Codes/Aetheris/noctalia/plugins/wallpaper-deck/scripts/wallpaper_helper.py")
  if noctalia.fileExists(devHelper) then
    HELPER_SCRIPT = devHelper
  end
end

local STATE_DIR = (type(noctalia.pluginDataDir) == "function" and noctalia.pluginDataDir())
  or noctalia.expandPath("~/.local/state/noctalia/plugins/data/ishan0121/wallpaper-deck")

local CACHE_FILE = STATE_DIR .. "/cache.json"
local DECK_FILE = STATE_DIR .. "/deck.json"
local THUMB_DIR = STATE_DIR .. "/thumbs"
local FAVORITES_FILE = STATE_DIR .. "/favorites.json"

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

  if overrideDir and overrideDir ~= "" then
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

  -- 4. Additional arbitrary comma-separated directories
  local addDirs = noctalia.getConfig("additional_wallpaper_dirs")
  if addDirs and addDirs ~= "" then
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
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
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
  local enc = noctalia.json.encode(favorites)
  if enc then
    noctalia.writeFile(FAVORITES_FILE, enc)
  end
  noctalia.state.set("favorites", favorites)
end

local function toggleFavorite(fileName: string)
  if not fileName or fileName == "" then return end
  if favorites[fileName] then
    favorites[fileName] = nil
  else
    favorites[fileName] = true
  end
  saveFavorites()
end

local function detectActiveWallpaper()
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

local function loadDeckFromDisk(): {any}
  local targetFile = DECK_FILE
  if not noctalia.fileExists(targetFile) then
    local legacy = noctalia.expandPath("~/.local/state/noctalia/wallpaper-deck/deck.json")
    if noctalia.fileExists(legacy) then
      targetFile = legacy
    end
  end

  if noctalia.fileExists(targetFile) then
    local raw = noctalia.readFile(targetFile)
    if raw and raw ~= "" then
      local ok, dec = pcall(noctalia.json.decode, raw)
      if ok and type(dec) == "table" and #dec > 0 then
        return dec
      end
    end
  end
  return {}
end

local function scanWallpapers(targetDir: string?)
  local dirs = resolveDirs(targetDir)
  local primaryDir = dirs[1] or resolveDir()
  customWallpaperDir = primaryDir

  scanToken = scanToken + 1
  local myToken = scanToken

  isScanning = true
  noctalia.state.set("is_scanning", true)
  noctalia.state.set("wallpaper_dir", primaryDir)
  noctalia.state.set("wallpaper_dirs", dirs)

  -- If wallpapers state is currently empty, load cached deck immediately so UI displays wallpapers without waiting
  local currentWps = noctalia.state.get("wallpapers")
  if not currentWps or (type(currentWps) == "table" and #currentWps == 0) then
    local cached = loadDeckFromDisk()
    if #cached > 0 then
      noctalia.state.set("wallpapers", cached)
    end
  end

  noctalia.mkdirAll(STATE_DIR)
  noctalia.mkdirAll(THUMB_DIR)

  local activeCache = findCacheFile()
  local dirParam = table.concat(dirs, "|||")
  local maxDeck = tostring(noctalia.getConfig("max_deck_wallpapers") or 600)

  noctalia.runAsync({ "python3", HELPER_SCRIPT, "scan", dirParam, activeCache, THUMB_DIR, "24", maxDeck }, function(res)
    if myToken ~= scanToken then
      return
    end

    isScanning = false
    noctalia.state.set("is_scanning", false)

    if not res or res.exitCode ~= 0 then
      local cached = loadDeckFromDisk()
      if #cached > 0 then
        noctalia.state.set("wallpapers", cached)
      else
        noctalia.state.set("wallpapers", {})
      end
      return
    end

    local items = loadDeckFromDisk()
    if #items > 0 then
      noctalia.state.set("wallpapers", items)
      noctalia.state.set("wallpaper_dir", primaryDir)
      noctalia.state.set("wallpaper_dirs", dirs)
    else
      noctalia.state.set("wallpapers", {})
    end
  end)
end

local function previewWallpaper(path: string)
  if not path or path == "" then return end
  noctalia.setWallpaper(path)
end

local function executeShellTemplate(template: string, path: string, outputTarget: string?)
  if not template or template == "" then return end
  local out = outputTarget or "*"

  -- Replace placeholder patterns with shell positional parameters $1 and $2.
  -- Both quoted and unquoted variations are mapped to "$1" / "$2" so values are
  -- passed safely via the argv array to sh -c without command substitution or injection.
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
    -- Native mode
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

  table.sort(entries, function(a, b)
    return (a.mtime or 0) < (b.mtime or 0)
  end)

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
  else
    activeWallhavenFilters = filters or {}
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

    local data = noctalia.json.decode(resp.body)
    if not data or not data.data then
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
        hueKey = 0.5,
        kind = "IMG",
        ext = string.upper(item.file_type and string.match(item.file_type, "/([^/]+)$") or "JPG"),
      })
    end

    if append ~= true then
      currentWallhavenItems = {}
    elseif #currentWallhavenItems == 0 then
      local existing = noctalia.state.get("wallhaven_results")
      if type(existing) == "table" and type(existing.items) == "table" then
        currentWallhavenItems = existing.items
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
    toggleFavorite(cmd.fileName)
  elseif action == "wallhaven_search" then
    searchWallhaven(cmd.query or "", cmd.page or 1, cmd.append == true, cmd.filters)
  elseif action == "wallhaven_apply" and cmd.item then
    downloadAndApplyWallhaven(cmd.item, cmd.output, cmd.cachedPath)
    prunePreviewCache()
  elseif action == "prune_cache" then
    prunePreviewCache()
  elseif action == "clear_preview_cache" then
    clearAllPreviewCache()
  end
end)

function onEnable()
  loadFavorites()
  detectActiveWallpaper()
  scanWallpapers()
  prunePreviewCache()
end

function onConfigChanged()
  isScanning = false
  customWallpaperDir = nil
  scanWallpapers()
  prunePreviewCache()
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
    toggleFavorite(payload)
  elseif event == "prune_cache" then
    prunePreviewCache()
  elseif event == "clear_preview_cache" then
    clearAllPreviewCache()
  end
end

-- Bootstrap
loadFavorites()
detectActiveWallpaper()
scanWallpapers()
prunePreviewCache()
