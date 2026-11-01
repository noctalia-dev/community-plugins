--!nonstrict
-- MTG Card-Deck Wallpaper Picker for Noctalia v5.
-- Fullscreen transparent overlay replicating qs-wallpaperpicker:
-- Live fullscreen wallpaper preview, arched coverflow card deck, spectrum ribbon,
-- 5 Material 3 color chips, floating action buttons above center card, and peek mode.

local function trText(key: string, fallback: string): string
  if type(noctalia) == "table" and type(noctalia.tr) == "function" then
    local ok, val = pcall(noctalia.tr, key)
    if ok and type(val) == "string" and val ~= "" and val ~= key then
      return val
    end
  end
  return fallback
end

local function loadCacheDirect(): {any}
  local deckPath = (type(noctalia.pluginDataDir) == "function" and (noctalia.pluginDataDir() .. "/deck.json"))
    or noctalia.expandPath("~/.local/state/noctalia/plugins/data/ishan0121/wallpaper-deck/deck.json")
  if not noctalia.fileExists(deckPath) then
    deckPath = noctalia.expandPath("~/.local/state/noctalia/wallpaper-deck/deck.json")
  end

  if noctalia.fileExists(deckPath) then
    local raw = noctalia.readFile(deckPath)
    if raw and raw ~= "" then
      local ok, dec = pcall(noctalia.json.decode, raw)
      if ok and type(dec) == "table" and #dec > 0 then
        return dec
      end
    end
  end
  return {}
end

local function loadFavoritesDirect(): { [string]: boolean }
  local favPath = (type(noctalia.pluginDataDir) == "function" and (noctalia.pluginDataDir() .. "/favorites.json"))
    or noctalia.expandPath("~/.local/state/noctalia/plugins/data/ishan0121/wallpaper-deck/favorites.json")
  if not noctalia.fileExists(favPath) then
    favPath = noctalia.expandPath("~/.local/state/noctalia/wallpaper-deck/favorites.json")
  end

  if noctalia.fileExists(favPath) then
    local raw = noctalia.readFile(favPath)
    if raw and raw ~= "" then
      local ok, dec = pcall(noctalia.json.decode, raw)
      if ok and type(dec) == "table" then
        return dec
      end
    end
  end
  return {}
end

local stateWps = noctalia.state.get("wallpapers")
local allWallpapers = (type(stateWps) == "table" and #stateWps > 0) and stateWps or loadCacheDirect()
local allWallpapersNewest: { any }? = noctalia.state.get("wallpapers_newest")
local allWallpapersColour: { any }? = noctalia.state.get("wallpapers_colour")
local stateFavs = noctalia.state.get("favorites")
local favorites = (type(stateFavs) == "table" and next(stateFavs) ~= nil) and stateFavs or loadFavoritesDirect()
local activeWallpaper = noctalia.state.get("active_wallpaper") or ""
local initialWallpaper = activeWallpaper
local currentWallDir = noctalia.state.get("wallpaper_dir") or noctalia.getConfig("wallpaper_dir") or ""
local isScanning = noctalia.state.get("is_scanning") == true
local wallhavenData = noctalia.state.get("wallhaven_results") or { items = {} }
local wallhavenLoading = noctalia.state.get("wallhaven_loading") == true
local wallhavenError = noctalia.state.get("wallhaven_error")
local wallhavenLoadingMore = false
local wallhavenLoadingStartMs = 0
local WALLHAVEN_CACHE_DIR = noctalia.expandPath("~/.local/state/noctalia/wallhaven/thumbs")
pcall(noctalia.mkdirAll, WALLHAVEN_CACHE_DIR)

local STATE_DIR = (type(noctalia.pluginDataDir) == "function" and noctalia.pluginDataDir())
  or noctalia.expandPath("~/.local/state/noctalia/plugins/data/ishan0121/wallpaper-deck")

local displayedBgPath = ""
local prevBgPath = ""
local bgTransitionProgress = 1.0
local BG_TRANSITION_DURATION = 0.28 -- 280ms smooth crossfade duration
local previewFit = noctalia.getConfig("preview_fit") or "cover"
if previewFit ~= "cover" and previewFit ~= "contain" and previewFit ~= "stretch" then
  previewFit = "cover"
end

local function clampVal(val: number, minVal: number, maxVal: number): number
  if val < minVal then return minVal end
  if val > maxVal then return maxVal end
  return val
end

local function easeBg(t: number): number
  local c = clampVal(t, 0.0, 1.0)
  return c * c * (3.0 - 2.0 * c)
end

local function setDisplayedBackground(newPath: string)
  if not newPath or newPath == "" or displayedBgPath == newPath then return end
  if displayedBgPath ~= "" and noctalia.fileExists(displayedBgPath) then
    prevBgPath = displayedBgPath
    bgTransitionProgress = 0.0
    panel.setNeedsFrameTick(true)
  else
    prevBgPath = ""
    bgTransitionProgress = 1.0
  end
  displayedBgPath = newPath
end

local WHEEL_PID_FILE = STATE_DIR .. "/wheel_listener.pid"

local function getWheelScript(): string?
  local candidates = {
    (type(noctalia.pluginDir) == "function" and (noctalia.pluginDir() .. "/scripts/wheel_listener.py")),
    noctalia.expandPath("~/.local/state/noctalia/plugins/materialized/community/wallpaper-deck/scripts/wheel_listener.py"),
    noctalia.expandPath("~/.local/share/noctalia/plugins/wallpaper-deck/scripts/wheel_listener.py"),
    noctalia.expandPath("~/Documents/Codes/Aetheris/noctalia/community-plugins/wallpaper-deck/scripts/wheel_listener.py"),
  }
  for _, path in ipairs(candidates) do
    if path and noctalia.fileExists(path) then
      return path
    end
  end
  return nil
end

local function stopWheelListener()
  pcall(function()
    if noctalia.fileExists(WHEEL_PID_FILE) then
      local pid = noctalia.readFile(WHEEL_PID_FILE)
      pcall(noctalia.removeFile, WHEEL_PID_FILE)
      if pid and pid ~= "" then
        local trimmed = string.gsub(pid, "%s+", "")
        if tonumber(trimmed) then
          noctalia.runAsync({ "kill", "-15", trimmed })
        end
      end
    end
  end)
end

local function startWheelListener()
  pcall(function()
    stopWheelListener()
    local script = getWheelScript()
    if not script then return end
    pcall(noctalia.mkdirAll, STATE_DIR)
    noctalia.runAsync({ "python3", script, WHEEL_PID_FILE })
  end)
end

local function baseName(name: string): string
  local dot = string.find(name, "%.[^%.]+$")
  if dot and dot > 1 then
    return string.sub(name, 1, dot - 1)
  end
  return name
end

local function isItemFavorite(item: any?): boolean
  if not item then return false end
  if item.path and favorites[item.path] then return true end
  if item.name and favorites[item.name] then return true end
  local b = item.base or (item.name and baseName(item.name))
  if b and favorites[b] then return true end
  if item.id then
    local whName = "wallhaven-" .. tostring(item.id)
    if favorites[whName] or favorites[whName .. ".jpg"] or favorites[whName .. ".png"] then
      return true
    end
  end
  return false
end

local cachedFavCount = -1
local function getFavCount(): number
  if cachedFavCount >= 0 then
    return cachedFavCount
  end
  local count = 0
  for _, it in ipairs(allWallpapers) do
    if isItemFavorite(it) then count = count + 1 end
  end
  cachedFavCount = count
  return count
end

local thumbQueue = {}
local thumbPending = {}
local thumbActive = 0
local THUMB_MAX_CONCURRENT = 4

local displayedItems = {}
local selectedIdx = 1
local isPickerOpen = false
local isDeckAreaHovered = true
local hoveredDeckKeys: { [string]: boolean } = {}
local currentMode = "local" -- "local" | "favorites" | "wallhaven"
local pendingStepAfterAppend = false
local render: () -> ()
local toggleCurrentFavorite -- forward declaration
local toggleFavoriteItem -- forward declaration
local changeSort -- forward declaration

function onDeckHover(state: any, key: string?)
  local k = key or "deck_bottom_section"
  if state == "true" or state == true then
    hoveredDeckKeys[k] = true
  else
    hoveredDeckKeys[k] = nil
  end
  isDeckAreaHovered = true
end

local function isValidFile(path: string?): boolean
  if not path or path == "" then return false end
  if type(noctalia.fileInfo) == "function" then
    local info = noctalia.fileInfo(path)
    return info ~= nil and info.isDir == false and (info.size or 0) > 0
  end
  return noctalia.fileExists(path)
end

local function pumpThumbQueue()
  while thumbActive < THUMB_MAX_CONCURRENT and #thumbQueue > 0 do
    local item = table.remove(thumbQueue, 1)
    local id = item.id
    if id and not thumbPending[id] then
      local dest = WALLHAVEN_CACHE_DIR .. "/" .. id .. ".jpg"
      if isValidFile(dest) then
        item.thumb = dest
        item.preview = dest
      else
        if noctalia.fileExists(dest) then
          pcall(noctalia.removeFile, dest)
        end
        local url = item.thumbUrl or (type(item.thumb) == "string" and string.sub(item.thumb, 1, 4) == "http" and item.thumb)
        if url and url ~= "" then
          thumbPending[id] = true
          thumbActive = thumbActive + 1
          local started = false
          if type(noctalia.download) == "function" then
            started = noctalia.download(url, dest, function(ok)
              thumbActive = math.max(0, thumbActive - 1)
              thumbPending[id] = nil
              if ok and isValidFile(dest) then
                item.thumb = dest
                item.preview = dest
                if displayedItems then
                  for _, it in ipairs(displayedItems) do
                    if it.id == id then
                      it.thumb = dest
                      it.preview = dest
                    end
                  end
                end
                if type(render) == "function" then render() end
              else
                pcall(noctalia.removeFile, dest)
              end
              pumpThumbQueue()
            end)
          end
          if not started then
            noctalia.runAsync({ "curl", "-sL", "-o", dest, url }, function(res)
              thumbActive = math.max(0, thumbActive - 1)
              thumbPending[id] = nil
              if res and res.exitCode == 0 and isValidFile(dest) then
                item.thumb = dest
                item.preview = dest
                if displayedItems then
                  for _, it in ipairs(displayedItems) do
                    if it.id == id then
                      it.thumb = dest
                      it.preview = dest
                    end
                  end
                end
                if type(render) == "function" then render() end
              else
                pcall(noctalia.removeFile, dest)
              end
              pumpThumbQueue()
            end)
          end
        end
      end
    end
  end
end

local function requestWallhavenThumb(item: any, priority: boolean?): string?
  if not item or not item.id then return nil end
  if item.thumb and item._thumbValid then
    return item.thumb
  end
  if item.thumb and isValidFile(item.thumb) then
    item.preview = item.thumb
    item._thumbValid = true
    return item.thumb
  end
  local dest = WALLHAVEN_CACHE_DIR .. "/" .. item.id .. ".jpg"
  if isValidFile(dest) then
    item.thumb = dest
    item.preview = dest
    item._thumbValid = true
    return dest
  end
  if noctalia.fileExists(dest) then
    pcall(noctalia.removeFile, dest)
  end
  if not thumbPending[item.id] then
    local found = false
    for _, it in ipairs(thumbQueue) do
      if it.id == item.id then
        found = true
        break
      end
    end
    if not found then
      if priority then
        table.insert(thumbQueue, 1, item)
      else
        table.insert(thumbQueue, item)
      end
      pumpThumbQueue()
    end
  end
  return nil
end

local WALLHAVEN_PREVIEW_DIR = noctalia.expandPath("~/.cache/noctalia/wallhaven-previews")
pcall(noctalia.mkdirAll, WALLHAVEN_PREVIEW_DIR)

local hiResPreview = noctalia.getConfig("wallhaven_hires_preview") == true
local hiResQueue = {}
local hiResPending = {}
local hiResActive = 0
local HIRES_MAX_CONCURRENT = 2

local function pumpHiResQueue()
  if not hiResPreview then return end
  while hiResActive < HIRES_MAX_CONCURRENT and #hiResQueue > 0 do
    local item = table.remove(hiResQueue, 1)
    local id = item and item.id
    if id and not hiResPending[id] then
      local urlExt = string.match(item.fullUrl or "", "%.([^%.]+)$") or item.ext or "jpg"
      local ext = string.lower(urlExt)
      if ext == "jpeg" then ext = "jpg" end

      local dest = WALLHAVEN_PREVIEW_DIR .. "/" .. id .. "." .. ext
      if isValidFile(dest) then
        item.hiResPath = dest
        item._hiResValid = true
        if displayedItems then
          for _, it in ipairs(displayedItems) do
            if it.id == id then
              it.hiResPath = dest
              it._hiResValid = true
            end
          end
        end
        local active = displayedItems[selectedIdx]
        if active and active.id == id and hiResPreview then
          setDisplayedBackground(dest)
          if type(render) == "function" then render() end
        end
      else
        if noctalia.fileExists(dest) then
          pcall(noctalia.removeFile, dest)
        end
        local permanentDirs = {
          noctalia.expandPath("~/Pictures/Wallpapers/WallHaven"),
          noctalia.expandPath("~/Pictures/WallHaven"),
          noctalia.expandPath("~/Pictures/Wallpapers"),
          noctalia.expandPath("~/Pictures/wallpapers/WallHaven"),
          noctalia.expandPath("~/Pictures/wallhaven"),
          noctalia.expandPath("~/Pictures/wallpapers"),
        }
        local alreadySaved = false
        for _, pdir in ipairs(permanentDirs) do
          local pf = pdir .. "/wallhaven-" .. id .. "." .. ext
          if isValidFile(pf) then
            item.hiResPath = pf
            item._hiResValid = true
            alreadySaved = true
            local active = displayedItems[selectedIdx]
            if active and active.id == id and hiResPreview then
              setDisplayedBackground(pf)
              if type(render) == "function" then render() end
            end
            break
          end
        end

        if not alreadySaved and item.fullUrl and item.fullUrl ~= "" then
          hiResPending[id] = true
          hiResActive = hiResActive + 1

          local onDownloadDone = function(ok: boolean)
            hiResActive = math.max(0, hiResActive - 1)
            hiResPending[id] = nil
            if ok and isValidFile(dest) then
              item.hiResPath = dest
              item._hiResValid = true
              if displayedItems then
                for _, it in ipairs(displayedItems) do
                  if it.id == id then
                    it.hiResPath = dest
                    it._hiResValid = true
                  end
                end
              end
              local active = displayedItems[selectedIdx]
              if active and active.id == id and hiResPreview then
                setDisplayedBackground(dest)
                if type(render) == "function" then render() end
              end
            else
              pcall(noctalia.removeFile, dest)
            end
            pumpHiResQueue()
          end

          local started = false
          if type(noctalia.download) == "function" then
            started = noctalia.download(item.fullUrl, dest, function(ok)
              onDownloadDone(ok == true)
            end)
          end

          if not started then
            noctalia.runAsync({ "curl", "-sL", "--connect-timeout", "10", "-o", dest, item.fullUrl }, function(res)
              local ok = (res and res.exitCode == 0 and isValidFile(dest))
              onDownloadDone(ok)
            end)
          end
        end
      end
    end
  end
end

local function getWallhavenHiResCached(item: any): string?
  if not item or not item.id then return nil end
  if item.hiResPath and item._hiResValid then
    return item.hiResPath
  end
  local urlExt = string.match(item.fullUrl or "", "%.([^%.]+)$") or item.ext or "jpg"
  local ext = string.lower(urlExt)
  if ext == "jpeg" then ext = "jpg" end

  local dest = WALLHAVEN_PREVIEW_DIR .. "/" .. item.id .. "." .. ext
  if isValidFile(dest) then
    item.hiResPath = dest
    item._hiResValid = true
    return dest
  end

  local permanentDirs = {
    noctalia.expandPath("~/Pictures/Wallpapers/WallHaven"),
    noctalia.expandPath("~/Pictures/WallHaven"),
    noctalia.expandPath("~/Pictures/Wallpapers"),
    noctalia.expandPath("~/Pictures/wallpapers/WallHaven"),
    noctalia.expandPath("~/Pictures/wallhaven"),
    noctalia.expandPath("~/Pictures/wallpapers"),
  }
  for _, pdir in ipairs(permanentDirs) do
    local pf = pdir .. "/wallhaven-" .. item.id .. "." .. ext
    if isValidFile(pf) then
      item.hiResPath = pf
      item._hiResValid = true
      return pf
    end
    local pfJpg = pdir .. "/wallhaven-" .. item.id .. ".jpg"
    if isValidFile(pfJpg) then
      item.hiResPath = pfJpg
      item._hiResValid = true
      return pfJpg
    end
    local pfPng = pdir .. "/wallhaven-" .. item.id .. ".png"
    if isValidFile(pfPng) then
      item.hiResPath = pfPng
      item._hiResValid = true
      return pfPng
    end
  end
  return nil
end

local function requestWallhavenHiRes(item: any, priority: boolean?): string?
  if not item or not item.id or not item.fullUrl then return nil end
  local cached = getWallhavenHiResCached(item)
  if cached then return cached end

  if not hiResPending[item.id] then
    local inQueueIdx = nil
    for i, it in ipairs(hiResQueue) do
      if it.id == item.id then
        inQueueIdx = i
        break
      end
    end

    if priority == true then
      if inQueueIdx then
        table.remove(hiResQueue, inQueueIdx)
      end
      table.insert(hiResQueue, 1, item)
    else
      if not inQueueIdx then
        table.insert(hiResQueue, item)
      end
    end

    pumpHiResQueue()
  end

  return nil
end

local function onCardSettled()
  if currentMode ~= "wallhaven" or not hiResPreview then return end
  local item = displayedItems[selectedIdx]
  if not item or not item.id or not item.fullUrl then return end

  local cached = getWallhavenHiResCached(item)
  if cached then
    setDisplayedBackground(cached)
    if type(render) == "function" then render() end
  else
    requestWallhavenHiRes(item, true)
  end

  for offset = 1, 2 do
    local nextItem = displayedItems[selectedIdx + offset]
    if nextItem and nextItem.id and nextItem.fullUrl then
      if not getWallhavenHiResCached(nextItem) then
        requestWallhavenHiRes(nextItem, false)
      end
    end
  end
end

local settleToken = 0
local function scheduleSettle()
  if currentMode ~= "wallhaven" or not hiResPreview then return end
  settleToken = settleToken + 1
  local myToken = settleToken
  noctalia.runAsync({ "sleep", "0.2" }, function()
    if myToken ~= settleToken or not isPickerOpen then return end
    onCardSettled()
  end)
end

local currentSort = "name_asc" -- "name_asc" | "name_desc" | "colour" | "newest" | "oldest"
local searchQuery = ""
local isSearchFocused = false
local isPeeking = false
local cfgScanSub = noctalia.getConfig("scan_subdirectories")
local isFlattened = if cfgScanSub ~= nil then (cfgScanSub == true or cfgScanSub == "true" or cfgScanSub == 1) else true

local WH_SORT_LABELS = { "Date Added", "Toplist", "Hot", "Views", "Favorites", "Relevance", "Random" }
local WH_SORT_VALUES = { "date_added", "toplist", "hot", "views", "favorites", "relevance", "random" }
local WH_RATIO_LABELS = { "Any", "Landscape", "Portrait", "16:9", "16:10", "21:9", "32:9", "48:9", "9:16", "10:16", "9:18", "1:1", "3:2", "4:3", "5:4" }
local WH_RATIO_VALUES = { "", "landscape", "portrait", "16x9", "16x10", "21x9", "32x9", "48x9", "9x16", "10x16", "9x18", "1x1", "3x2", "4x3", "5x4" }
local WH_RES_MODE_LABELS = { "At Least", "Exact" }
local WH_RES_MODE_VALUES = { "atleast", "exact" }

local whCatGeneral = true
local whCatAnime = true
local whCatPeople = true

local whPuritySfw = true
local whPuritySketchy = false
local whPurityNsfw = false

local function getSortIndexFromValue(val: string?): number
  if not val or val == "" then return 0 end
  local clean = string.lower(noctalia.string.trim(val))
  for i, v in ipairs(WH_SORT_VALUES) do
    if v == clean then return i - 1 end
  end
  return 0
end

local savedSort = noctalia.state.get("wallhaven_sort") or noctalia.getConfig("wallhaven_sorting") or "date_added"
local whSortIdx = getSortIndexFromValue(savedSort)
local savedOrder = noctalia.state.get("wallhaven_order") or noctalia.getConfig("wallhaven_order") or "desc"
local whOrder = (savedOrder == "asc") and "asc" or "desc"

local whRatioIdx = 0 -- "Any"
local whResModeIdx = 0 -- "At Least"
local whResWidth = ""
local whResHeight = ""
local whClearCounter = 0
local whQuery = ""

local connectedOutputs = { "ALL" }
local selectedOutput = "ALL"
local selectedOutputIdx = 1
local monitorDropdownOpen = false

local currentThemeMode = "dark"
local currentPaletteSource = "wallpaper"

local cachedRadiusScale = 1.0
local function updateCornerRadiusScale()
  if type(noctalia.getSetting) == "function" then
    local pcallOk, scale = pcall(noctalia.getSetting, "shell.corner_radius_scale")
    if pcallOk and type(scale) == "number" then
      cachedRadiusScale = scale
      return
    end
    local pcallOk2, scale2 = pcall(noctalia.getSetting, "corner_radius_scale")
    if pcallOk2 and type(scale2) == "number" then
      cachedRadiusScale = scale2
      return
    end
  end
  cachedRadiusScale = 1.0
end
updateCornerRadiusScale()

local function R(baseRadius: number): number
  if not baseRadius or baseRadius <= 0 then return 0 end
  if cachedRadiusScale <= 0 then return 0 end
  return math.floor(baseRadius * cachedRadiusScale + 0.5)
end

local BUILTIN_PALETTES = {
  "Ayu",
  "Catppuccin",
  "Dracula",
  "Eldritch",
  "Gruvbox",
  "Kanagawa",
  "Noctalia",
  "Nord",
  "Rosé Pine",
  "Tokyo-Night",
}

local SCHEMES = {
  { id = "m3-content", label = "M3 Content" },
  { id = "m3-tonal-spot", label = "M3 Tonal Spot" },
  { id = "m3-fruit-salad", label = "M3 Fruit Salad" },
  { id = "m3-rainbow", label = "M3 Rainbow" },
  { id = "m3-monochrome", label = "M3 Monochrome" },
  { id = "vibrant", label = "Vibrant" },
  { id = "faithful", label = "Faithful" },
  { id = "soft", label = "Soft" },
  { id = "dysfunctional", label = "Dysfunctional" },
  { id = "muted", label = "Muted" },
}
local SCHEME_OPTIONS = {}
for _, s in ipairs(SCHEMES) do
  table.insert(SCHEME_OPTIONS, s.label)
end

local function loadCommunityPalettes(): {string}
  local catPath = noctalia.expandPath("~/.local/state/noctalia/community-palettes/.catalog/palettes.json")
  if noctalia.fileExists(catPath) then
    local raw = noctalia.readFile(catPath)
    if raw and raw ~= "" then
      local ok, dec = pcall(noctalia.json.decode, raw)
      if ok and type(dec) == "table" then
        local names = {}
        for _, p in ipairs(dec) do
          if type(p) == "table" and type(p.name) == "string" and p.name ~= "" then
            table.insert(names, p.name)
          end
        end
        table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
        if #names > 0 then
          return names
        end
      end
    end
  end
  return { "Osaka jade", "Oxide", "Oxocarbon", "Paradise", "Peche", "Rose Pine Moon", "Solarized", "Tokyo Night Moon", "Vesper", "Zenbones" }
end

local communityPalettes = loadCommunityPalettes()
local selectedBuiltinIdx = 1
local selectedSchemeIdx = 4 -- default m3-rainbow
local selectedCommunityIdx = 1

local animatedPos = 1.0
local animVel = 0.0
local animTargetPos = 1.0
local lastFrameMs = 0
local lastPreviewed = ""

local function resetDeckAnimation(pos: number?)
  local p = pos or 1.0
  animatedPos = p
  animTargetPos = p
  animVel = 0.0
  lastFrameMs = 0
  panel.setNeedsFrameTick(false)
end

local animateSelected = noctalia.getConfig("animate_selected_card") ~= false

local function lerp(a: number, b: number, t: number): number
  return a + (b - a) * t
end

local function clamp(val: number, minVal: number, maxVal: number): number
  if val < minVal then return minVal end
  if val > maxVal then return maxVal end
  return val
end

local VISIBLE_DECK_CARDS = 11
local DECK_K = 5

local function getCardWidth(dist: number, scale: number): number
  local t = clamp(math.abs(dist) / DECK_K, 0.0, 1.0)
  local centerW = 224 * scale
  local sideW = 132 * scale
  return math.floor(lerp(centerW, sideW, t))
end

local function getCardHeight(dist: number, scale: number): number
  local t = clamp(math.abs(dist) / DECK_K, 0.0, 1.0)
  local centerH = 344 * scale
  local sideH = 216 * scale
  return math.floor(lerp(centerH, sideH, t))
end

local function getCardLift(dist: number, scale: number): number
  local t = clamp(math.abs(dist) / DECK_K, 0.0, 1.0)
  local maxLift = 80 * scale
  return math.floor((1.0 - math.pow(t, 1.45)) * maxLift)
end

-- Responsive deck scale constrained by BOTH panel width AND panel height
local function getDeckScale(panelW: number, panelH: number?): number
  local centerW = 224.0
  local sideW = 132.0
  local span = centerW
  for d = 1, DECK_K + 1 do
    local t = math.min(d / DECK_K, 1.0)
    local w = centerW + (sideW - centerW) * t
    span = span + 2 * w
  end
  span = span + (2 * (DECK_K + 1)) * 12.0

  local availableW = math.max(360.0, panelW - 96.0)
  local scaleW = (span <= availableW) and 1.0 or (availableW / span)

  local scaleH = 1.0
  if panelH and panelH > 0 then
    -- Reserve ~165px for header rows + spectrum ribbon + hints bar, and ~76px for action bar + bottom margin
    local availH = math.max(180.0, panelH - 245.0)
    local fullDeckH = 344.0 + 80.0
    if fullDeckH > availH then
      scaleH = availH / fullDeckH
    end
  end

  return clamp(math.min(scaleW, scaleH), 0.35, 1.0)
end

local visibleCards = VISIBLE_DECK_CARDS

-- Resolves the geometry of the monitor where the picker panel is actually displayed
-- (Always the focused output — NEVER `selectedOutput`, which is the wallpaper apply target!)
local function getScreenGeometry(): (number, number, string, number)
  local w = 1920
  local h = 1080
  local currentMonitorName = ""
  local outScale = 1.0

  if type(noctalia.outputs) == "function" then
    local ok, outs = pcall(noctalia.outputs)
    if ok and type(outs) == "table" then
      local outList = outs.outputs or outs
      if type(outList) == "table" and #outList > 0 then
        local focusedName = type(noctalia.focusedOutputName) == "function" and noctalia.focusedOutputName()
        local chosen = nil

        -- 1. Try focusedOutputName (the monitor where Noctalia opens the panel)
        if focusedName and focusedName ~= "" then
          for _, out in ipairs(outList) do
            if out.name == focusedName then
              chosen = out
              break
            end
          end
        end

        -- 2. Try output with focused == true
        if not chosen then
          for _, out in ipairs(outList) do
            if out.focused == true then
              chosen = out
              break
            end
          end
        end

        -- 3. Fallback to first output
        if not chosen then
          chosen = outList[1]
        end

        if chosen then
          currentMonitorName = chosen.name or ""
          local cw = tonumber(chosen.width)
          local ch = tonumber(chosen.height)
          outScale = tonumber(chosen.scale) or 1.0
          if outScale <= 0 then outScale = 1.0 end

          if cw and cw > 0 and ch and ch > 0 then
            local scaleMode = noctalia.getConfig("scale_compensation") or "auto"
            local shouldDivideByScale = false

            if scaleMode == "scaled" then
              shouldDivideByScale = (outScale ~= 1.0)
            elseif scaleMode == "unscaled" then
              shouldDivideByScale = false
            else
              -- Auto-detect whether chosen.width is physical pixels or already logical pixels:
              -- 1. Check multi-monitor logical x/y offsets if multiple outputs exist
              if outScale ~= 1.0 and #outList > 1 then
                local cx = tonumber(chosen.x) or 0
                local cy = tonumber(chosen.y) or 0
                for _, other in ipairs(outList) do
                  if other ~= chosen then
                    local ox = tonumber(other.x) or 0
                    local oy = tonumber(other.y) or 0
                    if ox > cx then
                      local dx = ox - cx
                      if math.abs(dx - (cw / outScale)) < math.abs(dx - cw) then
                        shouldDivideByScale = true
                      end
                      break
                    elseif oy > cy then
                      local dy = oy - cy
                      if math.abs(dy - (ch / outScale)) < math.abs(dy - ch) then
                        shouldDivideByScale = true
                      end
                      break
                    end
                  end
                end
              end
            end

            if shouldDivideByScale and outScale > 0 then
              w = math.floor(cw / outScale + 0.5)
              h = math.floor(ch / outScale + 0.5)
            else
              w = math.floor(cw)
              h = math.floor(ch)
            end
          end
        end
      end
    end
  end
  return w, h, currentMonitorName, outScale
end

local cachedPanelW = 1860
local cachedPanelH = 1040

local function monitorMatchesList(monList: any, monString: any, currentMonitorName: string): boolean
  if currentMonitorName == "" then return true end
  if type(monList) == "table" then
    if #monList == 0 then return true end
    for _, m in ipairs(monList) do
      if m == "ALL" or m == "*" or m == currentMonitorName then
        return true
      end
    end
    return false
  end
  if type(monString) == "string" and monString ~= "" and monString ~= "ALL" and monString ~= "*" then
    return monString == currentMonitorName
  end
  return true
end

local function updatePanelGeometry()
  local screenW, screenH, currentMonitorName, _ = getScreenGeometry()
  local barThicknessLeft = 0
  local barThicknessRight = 0
  local barThicknessTop = 0
  local barThicknessBottom = 0

  if type(noctalia.getSetting) == "function" then
    local pcallOk, bars = pcall(noctalia.getSetting, "bar")
    if pcallOk and type(bars) == "table" then
      for k, bar in pairs(bars) do
        if k ~= "order" and type(bar) == "table" then
          -- Support per-monitor bar overrides under bar.<name>.monitor.<connector>
          local monOverride = (type(bar.monitor) == "table" and currentMonitorName ~= "" and bar.monitor[currentMonitorName]) or nil
          local effEnabled = (monOverride and monOverride.enabled ~= nil) and monOverride.enabled or bar.enabled
          local effAutoHide = (monOverride and monOverride.auto_hide ~= nil) and monOverride.auto_hide or bar.auto_hide
          local effReserve = (monOverride and monOverride.reserve_space ~= nil) and monOverride.reserve_space or bar.reserve_space
          local effPos = (monOverride and type(monOverride.position) == "string" and monOverride.position)
            or (type(bar.position) == "string" and bar.position)
            or "top" -- Noctalia default bar position is "top"

          if effEnabled ~= false and not effAutoHide and effReserve ~= false then
            local matchesMon = monitorMatchesList(bar.monitors, type(bar.monitor) == "string" and bar.monitor or nil, currentMonitorName)
            if matchesMon then
              local th = tonumber((monOverride and monOverride.thickness) or bar.thickness) or 34
              local mEdge = tonumber((monOverride and monOverride.margin_edge) or bar.margin_edge) or 0
              local mOpp = tonumber((monOverride and monOverride.margin_opposite_edge) or bar.margin_opposite_edge) or 0
              local totalBarSpan = math.max(0, th + mEdge + mOpp)

              if effPos == "left" then
                barThicknessLeft = barThicknessLeft + totalBarSpan
              elseif effPos == "right" then
                barThicknessRight = barThicknessRight + totalBarSpan
              elseif effPos == "bottom" then
                barThicknessBottom = barThicknessBottom + totalBarSpan
              else
                barThicknessTop = barThicknessTop + totalBarSpan
              end
            end
          end
        end
      end
    end

    local pcallDock, dock = pcall(noctalia.getSetting, "dock")
    if pcallDock and type(dock) == "table" and dock.enabled ~= false and not dock.auto_hide and dock.reserve_space == true then
      local matchesDockMon = monitorMatchesList(dock.monitors, type(dock.monitor) == "string" and dock.monitor or nil, currentMonitorName)
      if matchesDockMon then
        local dpos = (type(dock.position) == "string" and dock.position ~= "") and dock.position or "bottom"
        local dth = tonumber(dock.thickness) or 48
        local dmEdge = tonumber(dock.margin_edge) or tonumber(dock.margin) or 0
        local dmOpp = tonumber(dock.margin_opposite_edge) or 0
        local totalDockSpan = math.max(0, dth + dmEdge + dmOpp)

        if dpos == "left" then
          barThicknessLeft = barThicknessLeft + totalDockSpan
        elseif dpos == "right" then
          barThicknessRight = barThicknessRight + totalDockSpan
        elseif dpos == "top" then
          barThicknessTop = barThicknessTop + totalDockSpan
        else
          barThicknessBottom = barThicknessBottom + totalDockSpan
        end
      end
    end
  end

  local floatingOffset = 8
  local isAttached = false
  local borderWidth = 1
  local uiScale = 1.0

  if type(noctalia.getSetting) == "function" then
    local okFo, fo = pcall(noctalia.getSetting, "shell.panel.floating_offset")
    if okFo and type(fo) == "number" then
      floatingOffset = fo
    end
    local okPl, pl = pcall(noctalia.getSetting, "plugin_settings.ishan0121/wallpaper-deck.picker_placement")
    if okPl and pl == "attached" then
      isAttached = true
    end
    local okBorders, hasBorders = pcall(noctalia.getSetting, "shell.panel.borders")
    if okBorders and hasBorders == false then
      borderWidth = 0
    else
      local okBw, bw = pcall(noctalia.getSetting, "shell.panel.border_width")
      if okBw and type(bw) == "number" then
        borderWidth = math.max(0, bw)
      end
    end
    local okUs, us = pcall(noctalia.getSetting, "accessibility.ui_scale")
    if okUs and type(us) == "number" and us > 0.2 then
      uiScale = us
    end
  end

  local padFloat = (not isAttached and floatingOffset > 0) and (floatingOffset * 2) or 0
  local chromeInset = tonumber(noctalia.getConfig("panel_padding_offset"))
  if chromeInset == nil then
    chromeInset = 24
  end
  local totalChrome = chromeInset + (borderWidth * 2)

  local rawW = screenW - barThicknessLeft - barThicknessRight - padFloat - totalChrome
  local rawH = screenH - barThicknessTop - barThicknessBottom - padFloat - totalChrome

  if uiScale ~= 1.0 then
    rawW = math.floor(rawW / uiScale + 0.5)
    rawH = math.floor(rawH / uiScale + 0.5)
  end

  cachedPanelW = math.max(640, math.floor(rawW))
  cachedPanelH = math.max(420, math.floor(rawH))
end
updatePanelGeometry()

local function getPanelGeometry(): (number, number)
  return cachedPanelW, cachedPanelH
end

-- Contrast text color calculation for color swatches with memoization cache
local inkCache = {}
local function inkOn(hex: string): string
  if not hex or hex == "" then return "#ffffff" end
  local cached = inkCache[hex]
  if cached then return cached end
  local clean = (string.byte(hex, 1) == 35) and string.sub(hex, 2) or hex
  if #clean ~= 6 then return "#ffffff" end
  local r = tonumber(string.sub(clean, 1, 2), 16) or 255
  local g = tonumber(string.sub(clean, 3, 4), 16) or 255
  local b = tonumber(string.sub(clean, 5, 6), 16) or 255
  local lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
  local res = lum > 0.52 and "#111418" or "#ffffff"
  inkCache[hex] = res
  return res
end

-- WCAG 2.1 relative luminance
local function getWcagLuminance(hex: string?): number
  if not hex or type(hex) ~= "string" then return 0.5 end
  local clean = (string.byte(hex, 1) == 35) and string.sub(hex, 2) or hex
  if #clean ~= 6 then return 0.5 end
  local r = (tonumber(string.sub(clean, 1, 2), 16) or 255) / 255.0
  local g = (tonumber(string.sub(clean, 3, 4), 16) or 255) / 255.0
  local b = (tonumber(string.sub(clean, 5, 6), 16) or 255) / 255.0

  local function toLin(c: number): number
    return (c <= 0.04045) and (c / 12.92) or math.pow((c + 0.055) / 1.055, 2.4)
  end

  return 0.2126 * toLin(r) + 0.7152 * toLin(g) + 0.0722 * toLin(b)
end

-- WCAG contrast ratio between two relative luminance values
local function getContrastRatio(lum1: number, lum2: number): number
  local l1 = math.max(lum1, lum2)
  local l2 = math.min(lum1, lum2)
  return (l1 + 0.05) / (l2 + 0.05)
end

-- Dynamic contrast-aware text and accent colors derived from the wallpaper's generated palette
local paletteCache = {}
local function getWallpaperPaletteFontColors(item: any?)
  if not item then
    return {
      isLight = false,
      bgHex = "#111418",
      primaryText = "#ffffff",
      accent = "#80a9ff",
      muted = "#c5c7d0",
      bullet = "#c5c7d070",
    }
  end
  local cacheKey = item.path or item.id or item.name
  if cacheKey and paletteCache[cacheKey] then
    return paletteCache[cacheKey]
  end

  local colors = item.colors or {}
  local bgHex = item.sourceColor or colors.source_color or "#111418"
  local bgLum = getWcagLuminance(bgHex)

  local isLight = false
  if item.isLight ~= nil then
    isLight = (item.isLight == true)
  elseif item.topLum ~= nil and type(item.topLum) == "number" then
    isLight = (item.topLum > 0.42)
  else
    isLight = (bgLum > 0.38)
  end

  local useDarkInk = isLight

  local candidateKeys = {
    "surface_container_highest",
    "primary_container",
    "primary",
    "secondary",
    "tertiary",
    "source_color",
  }

  local scored = {}
  for _, k in ipairs(candidateKeys) do
    local hex = colors[k]
    if hex and type(hex) == "string" and string.match(hex, "^#%x%x%x%x%x%x$") then
      local lum = getWcagLuminance(hex)
      local cr = getContrastRatio(lum, bgLum)
      table.insert(scored, { key = k, hex = hex, lum = lum, contrast = cr })
    end
  end

  table.sort(scored, function(a, b)
    return a.contrast > b.contrast
  end)

  local sideCandidates = {}
  for _, c in ipairs(scored) do
    if (useDarkInk and c.lum < 0.35) or (not useDarkInk and c.lum > 0.35) then
      table.insert(sideCandidates, c)
    end
  end

  local primaryText = useDarkInk and "#000000" or "#ffffff"
  local accentColor = useDarkInk and "#004c3f" or "#80a9ff"
  local mutedText = useDarkInk and "#2c312e" or "#c5c7d0"

  if #sideCandidates > 0 then
    primaryText = sideCandidates[1].hex
    if sideCandidates[1].contrast < 3.8 then
      primaryText = useDarkInk and "#111418" or "#ffffff"
    end

    for _, c in ipairs(sideCandidates) do
      if (c.key == "primary_container" or c.key == "primary" or c.key == "tertiary" or c.key == "secondary") and c.contrast >= 2.0 then
        accentColor = c.hex
        break
      end
    end
    if not accentColor then
      accentColor = primaryText
    end

    if #sideCandidates >= 2 and sideCandidates[2].contrast >= 2.0 then
      mutedText = sideCandidates[2].hex
    else
      mutedText = primaryText
    end
  else
    primaryText = useDarkInk and "#000000" or "#ffffff"
    accentColor = useDarkInk and "#004c3f" or "#80a9ff"
    mutedText = useDarkInk and "#33353b" or "#c5c7d0"
  end

  local bulletColor = useDarkInk and (mutedText .. "a0") or (mutedText .. "70")

  local res = {
    isLight = useDarkInk,
    bgHex = bgHex,
    primaryText = primaryText,
    accent = accentColor,
    muted = mutedText,
    bullet = bulletColor,
  }
  if cacheKey then
    paletteCache[cacheKey] = res
  end
  return res
end

local function formatBytes(bytes: number): string
  if not bytes or bytes <= 0 then return "" end
  if bytes >= 1048576 then
    return string.format("%.1f MB", bytes / 1048576.0)
  else
    return string.format("%d KB", math.floor(bytes / 1024.0))
  end
end

local rawRoot = (currentWallDir ~= "" and currentWallDir)
  or noctalia.getConfig("wallpaper_dir")
  or "~/Pictures/Wallpapers"
local rootWpDir = string.gsub(noctalia.expandPath(rawRoot) or "", "/+$", "")
local rootWpDirLen = #rootWpDir

local function updateRootWpDir(newDir: string)
  if newDir and newDir ~= "" then
    local exp = noctalia.expandPath(newDir)
    if exp and exp ~= "" then
      exp = string.gsub(exp, "/+$", "")
    end
    rootWpDir = exp or ""
    rootWpDirLen = #rootWpDir
  end
end

local function itemIsSubdir(item: any): boolean
  if item.isSubdir ~= nil then
    return item.isSubdir == true
  end
  if item.relDir and item.relDir ~= "" then
    return true
  end
  if item.path and #item.path > rootWpDirLen then
    if string.sub(item.path, 1, rootWpDirLen) == rootWpDir then
      local rel = string.sub(item.path, rootWpDirLen + 2)
      if string.find(rel, "/", 1, true) then
        return true
      end
    end
  end
  return false
end

local function openPluginSettings()
  stopWheelListener()
  if type(noctalia.openSettings) == "function" then
    local ok = pcall(noctalia.openSettings)
    if ok then return end
  end
  noctalia.runAsync({ "noctalia", "msg", "settings-open-plugin", "ishan0121/wallpaper-deck" }, function() end)
  panel.close()
end

local function updateThemeFromSystem()
  -- 1. Synchronous fast path using native Noctalia settings API (zero flicker)
  if type(noctalia.getSetting) == "function" then
    local okMode, cfgMode = pcall(noctalia.getSetting, "theme.mode")
    if okMode and type(cfgMode) == "string" and cfgMode ~= "" then
      currentThemeMode = cfgMode
    elseif type(noctalia.isDarkMode) == "function" then
      currentThemeMode = noctalia.isDarkMode() and "dark" or "light"
    end
  end

  -- 2. Async CLI verification for active palette source & scheme
  noctalia.runAsync({ "noctalia", "msg", "theme-mode-get" }, function(res)
    if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
      local mode = string.match(res.stdout, "[%w_-]+")
      if mode and mode ~= "" and mode ~= currentThemeMode then
        currentThemeMode = mode
        if isPickerOpen then render() end
      end
    end
  end)

  noctalia.runAsync({ "noctalia", "msg", "color-scheme-get" }, function(res)
    if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
      local src, scheme = string.match(res.stdout, "(%S+)%s+(.+)")
      if src and src ~= "" then
        src = string.lower(noctalia.string.trim(src))
        if src == "builtin" or src == "wallpaper" or src == "community" then
          currentPaletteSource = src
        end
      end
      if scheme and scheme ~= "" then
        scheme = noctalia.string.trim(scheme)
        if currentPaletteSource == "builtin" then
          for idx, name in ipairs(BUILTIN_PALETTES) do
            if string.lower(name) == string.lower(scheme) then
              selectedBuiltinIdx = idx
              break
            end
          end
        elseif currentPaletteSource == "community" then
          for idx, name in ipairs(communityPalettes) do
            if string.lower(name) == string.lower(scheme) then
              selectedCommunityIdx = idx
              break
            end
          end
        else
          for idx, s in ipairs(SCHEMES) do
            if s.id == scheme or string.lower(s.label) == string.lower(scheme) then
              selectedSchemeIdx = idx
              break
            end
          end
        end
      end
      if isPickerOpen then render() end
    end
  end)
end

local function refreshConnectedOutputs()
  connectedOutputs = { "ALL" }
  if type(noctalia.outputs) == "function" then
    local ok, outs = pcall(noctalia.outputs)
    if ok and type(outs) == "table" then
      local outList = outs.outputs or outs
      if type(outList) == "table" then
        for _, out in ipairs(outList) do
          if out.name and out.name ~= "" then
            table.insert(connectedOutputs, out.name)
          end
        end
      end
    end
  end
  selectedOutputIdx = 1
  for idx, name in ipairs(connectedOutputs) do
    if name == selectedOutput then
      selectedOutputIdx = idx
      break
    end
  end
end

local function reverseArray(arr: { any }): { any }
  local n = #arr
  local rev = table.create(n)
  for i = 1, n do
    rev[i] = arr[n - i + 1]
  end
  return rev
end

local function sortItemsInPlace(arr: { any }, sortMode: string)
  if #arr <= 1 then return end
  if sortMode == "name_desc" then
    table.sort(arr, function(a, b) return (a.lowerName or "") > (b.lowerName or "") end)
  elseif sortMode == "newest" then
    table.sort(arr, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
  elseif sortMode == "oldest" then
    table.sort(arr, function(a, b) return (a.mtime or 0) < (b.mtime or 0) end)
  elseif sortMode == "colour" then
    table.sort(arr, function(a, b) return (a.hueKey or 3.0) < (b.hueKey or 3.0) end)
  else
    table.sort(arr, function(a, b) return (a.lowerName or "") < (b.lowerName or "") end)
  end
end

local function invalidateSortCache()
  -- No-op
end

local cachedRibbon = nil
local cachedRibbonIdx = -1
local cachedRibbonCount = -1

local function rebuildList()
  if currentMode == "wallhaven" then
    displayedItems = (wallhavenData and wallhavenData.items) or {}
    cachedRibbon = nil
    selectedIdx = clamp(selectedIdx, 1, math.max(1, #displayedItems))
    if #displayedItems > 0 then
      local halfWindow = math.floor((visibleCards or 7) / 2)
      for offset = -halfWindow, halfWindow do
        local it = displayedItems[selectedIdx + offset]
        if it then
          requestWallhavenThumb(it, offset == 0)
        end
      end
    end
    return
  end

  local hasSearch = (searchQuery ~= "")

  local src = {}
  if currentMode == "favorites" then
    for _, item in ipairs(allWallpapers) do
      if isItemFavorite(item) then
        if isFlattened or not itemIsSubdir(item) then
          table.insert(src, item)
        end
      end
    end
    if hasSearch then
      local q = string.lower(searchQuery)
      local filtered = {}
      for _, item in ipairs(src) do
        local ln = item.lowerName or string.lower(item.name or "")
        local rel = item.relDir and string.lower(item.relDir) or ""
        if string.find(ln, q, 1, true) or (rel ~= "" and string.find(rel, q, 1, true)) then
          table.insert(filtered, item)
        end
      end
      src = filtered
    end
    sortItemsInPlace(src, currentSort)
  else
    -- Local mode
    if hasSearch then
      local q = string.lower(searchQuery)
      local filtered = {}
      for _, item in ipairs(allWallpapers) do
        if isFlattened or not itemIsSubdir(item) then
          local ln = item.lowerName or string.lower(item.name or "")
          local rel = item.relDir and string.lower(item.relDir) or ""
          if string.find(ln, q, 1, true) or (rel ~= "" and string.find(rel, q, 1, true)) then
            table.insert(filtered, item)
          end
        end
      end
      src = filtered
      sortItemsInPlace(src, currentSort)
    else
      if isFlattened then
        if currentSort == "name_asc" then
          src = allWallpapers
        elseif currentSort == "name_desc" then
          src = reverseArray(allWallpapers)
        elseif currentSort == "newest" then
          src = allWallpapersNewest or allWallpapers
        elseif currentSort == "oldest" then
          src = reverseArray(allWallpapersNewest or allWallpapers)
        elseif currentSort == "colour" then
          src = allWallpapersColour or allWallpapers
        else
          src = allWallpapers
        end
      else
        local base = {}
        for _, it in ipairs(allWallpapers) do
          if not itemIsSubdir(it) then
            table.insert(base, it)
          end
        end
        if currentSort == "name_desc" then
          src = reverseArray(base)
        elseif currentSort == "newest" or currentSort == "oldest" or currentSort == "colour" then
          sortItemsInPlace(base, currentSort)
          src = base
        else
          src = base
        end
      end
    end
  end

  displayedItems = src
  cachedRibbon = nil
  selectedIdx = clamp(selectedIdx, 1, math.max(1, #displayedItems))
end

local function getApiKey(): string
  local key = noctalia.getConfig("wallhaven_api_key") or ""
  if key == "" and type(noctalia.getSetting) == "function" then
    local pcallOk, officialKey = pcall(noctalia.getSetting, "plugin_settings.noctalia/wallhaven.api_key")
    if pcallOk and type(officialKey) == "string" and officialKey ~= "" then
      key = officialKey
    end
  end
  return key
end

local function isNsfwAllowed(): boolean
  return getApiKey() ~= ""
end

local function buildCategories(): string
  local g = whCatGeneral and "1" or "0"
  local a = whCatAnime and "1" or "0"
  local p = whCatPeople and "1" or "0"
  local cat = g .. a .. p
  if cat == "000" then return "100" end
  return cat
end

local function buildPurity(): string
  local s = whPuritySfw and "1" or "0"
  local sk = whPuritySketchy and "1" or "0"
  local n = (whPurityNsfw and isNsfwAllowed()) and "1" or "0"
  local pur = s .. sk .. n
  if pur == "000" then return "100" end
  return pur
end

local function getRatioParam(): string?
  local val = WH_RATIO_VALUES[whRatioIdx + 1]
  if val and val ~= "" then
    return val
  end
  return nil
end

local function getResolutionParam(): (string?, string?)
  local wStr = whResWidth
  local hStr = whResHeight
  local mw, mh = string.match(wStr, "(%d+)[xX%*×%s]+(%d+)")
  if mw and mh then
    wStr, hStr = mw, mh
  else
    local mw2, mh2 = string.match(hStr, "(%d+)[xX%*×%s]+(%d+)")
    if mw2 and mh2 then
      wStr, hStr = mw2, mh2
    end
  end
  local w = tonumber(wStr)
  local h = tonumber(hStr)
  if w and h and w > 0 and h > 0 then
    local resStr = string.format("%dx%d", math.floor(w), math.floor(h))
    local mode = (whResModeIdx == 1) and "exact" or "atleast"
    return resStr, mode
  end
  return nil, nil
end

local function getSortingParam(): (string, string)
  local sortVal = WH_SORT_VALUES[whSortIdx + 1] or "date_added"
  return sortVal, whOrder
end

local function getActiveFilters(): any
  local sorting, order = getSortingParam()
  local trimmed = noctalia.string.trim(whQuery or "")
  if trimmed ~= "" and (sorting == "hot" or sorting == "toplist") then
    sorting = "relevance"
  end
  local res, resMode = getResolutionParam()
  local ratio = getRatioParam()
  return {
    categories = buildCategories(),
    purity = buildPurity(),
    sorting = sorting,
    order = order,
    ratios = ratio,
    resolution = res,
    resolutionMode = resMode,
  }
end

local function doWallhavenSearch(resetPage: boolean?)
  local targetPage = resetPage and 1 or (wallhavenData.page or 1)
  wallhavenLoadingMore = false
  wallhavenError = nil
  pendingStepAfterAppend = false
  if resetPage then
    selectedIdx = 1
    resetDeckAnimation(1.0)
    thumbQueue = {}
    hiResQueue = {}
  end
  wallhavenLoading = true
  noctalia.state.set("deck_command", {
    action = "wallhaven_search",
    query = whQuery,
    page = targetPage,
    filters = getActiveFilters(),
    nonce = noctalia.nowMs(),
  })
  if type(render) == "function" then
    render()
  end
end

local function toggleCategoryGeneral()
  if whCatGeneral and not whCatAnime and not whCatPeople then return end
  whCatGeneral = not whCatGeneral
  doWallhavenSearch(true)
end

local function toggleCategoryAnime()
  if whCatAnime and not whCatGeneral and not whCatPeople then return end
  whCatAnime = not whCatAnime
  doWallhavenSearch(true)
end

local function toggleCategoryPeople()
  if whCatPeople and not whCatGeneral and not whCatAnime then return end
  whCatPeople = not whCatPeople
  doWallhavenSearch(true)
end

local function togglePuritySfw()
  if whPuritySfw and not whPuritySketchy and not whPurityNsfw then return end
  whPuritySfw = not whPuritySfw
  doWallhavenSearch(true)
end

local function togglePuritySketchy()
  if whPuritySketchy and not whPuritySfw and not whPurityNsfw then return end
  whPuritySketchy = not whPuritySketchy
  doWallhavenSearch(true)
end

local function togglePurityNsfw()
  if not isNsfwAllowed() then return end
  if whPurityNsfw and not whPuritySfw and not whPuritySketchy then return end
  whPurityNsfw = not whPurityNsfw
  doWallhavenSearch(true)
end

local function buildWallhavenRow2(paletteColors: any?, panelW: number?)
  local pW = panelW or cachedPanelW
  local isCompact = (pW < 1560)
  local isUltraCompact = (pW < 1260)
  local pColors = paletteColors or {
    primaryText = "on_surface",
    accent = "primary",
    muted = "on_surface/0.7",
  }

  return ui.row({
    align = "center",
    justify = "space_between",
    height = 36,
    width = pW - 64,
  }, {
    ui.row({
      align = "center",
      gap = isCompact and 6 or 12,
      flexGrow = 1,
    }, {
      -- 1. Categories
      ui.row({ align = "center", gap = 4 }, {
        not isCompact and ui.label({ text = "Categories", fontSize = 11, fontWeight = "bold", color = pColors.muted }) or ui.spacer({ width = 1 }),
        ui.row({
          align = "center",
          gap = 2,
          fill = "surface/0.65",
          border = "outline_variant/0.2",
          borderWidth = 1,
          radius = R(16),
          padding = 2,
        }, {
          ui.button({
            text = isUltraCompact and "Gen" or "General",
            variant = whCatGeneral and "primary" or "ghost",
            controlSize = "sm",
            onClick = toggleCategoryGeneral,
          }),
          ui.button({
            text = "Anime",
            variant = whCatAnime and "primary" or "ghost",
            controlSize = "sm",
            onClick = toggleCategoryAnime,
          }),
          ui.button({
            text = isUltraCompact and "Ppl" or "People",
            variant = whCatPeople and "primary" or "ghost",
            controlSize = "sm",
            onClick = toggleCategoryPeople,
          }),
        }),
      }),

      -- 2. Purity
      ui.row({ align = "center", gap = 4 }, {
        not isCompact and ui.label({ text = "Purity", fontSize = 11, fontWeight = "bold", color = pColors.muted }) or ui.spacer({ width = 1 }),
        ui.row({
          align = "center",
          gap = 2,
          fill = "surface/0.65",
          border = "outline_variant/0.2",
          borderWidth = 1,
          radius = R(16),
          padding = 2,
        }, {
          ui.button({
            text = "SFW",
            variant = whPuritySfw and "primary" or "ghost",
            controlSize = "sm",
            onClick = togglePuritySfw,
          }),
          ui.button({
            text = isUltraCompact and "Sk" or "Sketchy",
            variant = whPuritySketchy and "primary" or "ghost",
            controlSize = "sm",
            onClick = togglePuritySketchy,
          }),
          ui.button({
            text = "NSFW",
            variant = whPurityNsfw and "primary" or "ghost",
            controlSize = "sm",
            enabled = isNsfwAllowed(),
            tooltip = not isNsfwAllowed() and "Requires Wallhaven API Key" or nil,
            onClick = togglePurityNsfw,
          }),
        }),
      }),

      -- 3. Sort & Order
      ui.row({ align = "center", gap = 4 }, {
        not isCompact and ui.label({ text = "Sort", fontSize = 11, fontWeight = "bold", color = pColors.muted }) or ui.spacer({ width = 1 }),
        ui.select({
          key = "wh_sort_select_" .. tostring(whSortIdx),
          options = WH_SORT_LABELS,
          selectedIndex = tonumber(whSortIdx) or 0,
          controlSize = "sm",
          width = isCompact and 94 or 110,
          onChange = function(idx, text)
            local num = tonumber(idx)
            if not num and text then
              for i, lbl in ipairs(WH_SORT_LABELS) do
                if lbl == text then
                  num = i - 1
                  break
                end
              end
            end
            whSortIdx = num or 0
            local sortVal = WH_SORT_VALUES[whSortIdx + 1] or "date_added"
            noctalia.state.set("wallhaven_sort", sortVal)
            doWallhavenSearch(true)
          end,
        }),
        ui.button({
          glyph = (whOrder == "desc") and "arrow-down" or "arrow-up",
          variant = "secondary",
          controlSize = "sm",
          tooltip = (whOrder == "desc") and "Descending" or "Ascending",
          onClick = function()
            whOrder = (whOrder == "desc") and "asc" or "desc"
            noctalia.state.set("wallhaven_order", whOrder)
            doWallhavenSearch(true)
          end,
        }),
      }),

      -- 4. Aspect Ratio
      ui.row({ align = "center", gap = 4 }, {
        not isCompact and ui.label({ text = "Ratio", fontSize = 11, fontWeight = "bold", color = pColors.muted }) or ui.spacer({ width = 1 }),
        ui.select({
          key = "wh_ratio_select_" .. tostring(whRatioIdx),
          options = WH_RATIO_LABELS,
          selectedIndex = tonumber(whRatioIdx) or 0,
          controlSize = "sm",
          width = isCompact and 80 or 95,
          onChange = function(idx, text)
            local num = tonumber(idx)
            if not num and text then
              for i, lbl in ipairs(WH_RATIO_LABELS) do
                if lbl == text then
                  num = i - 1
                  break
                end
              end
            end
            whRatioIdx = num or 0
            doWallhavenSearch(true)
          end,
        }),
      }),

      -- 5. Resolution & Clear
      ui.row({ align = "center", gap = 4 }, {
        not isCompact and ui.label({ text = "Res", fontSize = 11, fontWeight = "bold", color = pColors.muted }) or ui.spacer({ width = 1 }),
        ui.select({
          key = "wh_res_mode_select_" .. tostring(whResModeIdx),
          options = WH_RES_MODE_LABELS,
          selectedIndex = tonumber(whResModeIdx) or 0,
          controlSize = "sm",
          width = isCompact and 76 or 90,
          onChange = function(idx, text)
            local num = tonumber(idx)
            if not num and text then
              for i, lbl in ipairs(WH_RES_MODE_LABELS) do
                if lbl == text then
                  num = i - 1
                  break
                end
              end
            end
            whResModeIdx = num or 0
            local res, _ = getResolutionParam()
            if res then
              doWallhavenSearch(true)
            else
              render()
            end
          end,
        }),
        ui.input({
          key = "wh_res_w_" .. whClearCounter,
          placeholder = isCompact and "W" or "Width",
          value = whResWidth,
          controlSize = "sm",
          width = isCompact and 58 or 76,
          onChange = function(val)
            isSearchFocused = true
            whResWidth = noctalia.string.trim(val or "")
            local mw, mh = string.match(whResWidth, "(%d+)[xX%*×%s]+(%d+)")
            if mw and mh then
              whResWidth = mw
              whResHeight = mh
              whClearCounter = whClearCounter + 1
              doWallhavenSearch(true)
            end
          end,
          onSubmit = function(val)
            whResWidth = noctalia.string.trim(val or "")
            local res, _ = getResolutionParam()
            if res then
              doWallhavenSearch(true)
            end
          end,
        }),
        ui.label({ text = "×", fontSize = 12, color = pColors.muted }),
        ui.input({
          key = "wh_res_h_" .. whClearCounter,
          placeholder = isCompact and "H" or "Height",
          value = whResHeight,
          controlSize = "sm",
          width = isCompact and 58 or 76,
          onChange = function(val)
            isSearchFocused = true
            whResHeight = noctalia.string.trim(val or "")
            local mw, mh = string.match(whResHeight, "(%d+)[xX%*×%s]+(%d+)")
            if mw and mh then
              whResWidth = mw
              whResHeight = mh
              whClearCounter = whClearCounter + 1
              doWallhavenSearch(true)
            end
          end,
          onSubmit = function(val)
            whResHeight = noctalia.string.trim(val or "")
            local res, _ = getResolutionParam()
            if res then
              doWallhavenSearch(true)
            end
          end,
        }),
        ui.button({
          text = "Set",
          variant = (getResolutionParam() ~= nil) and "primary" or "ghost",
          controlSize = "sm",
          tooltip = "Apply Resolution",
          onClick = function()
            local res, _ = getResolutionParam()
            if res then
              doWallhavenSearch(true)
            end
          end,
        }),
        ui.button({
          text = isUltraCompact and "×" or "Clear",
          variant = "destructive",
          controlSize = "sm",
          tooltip = "Clear Resolution Filter",
          onClick = function()
            whResWidth = ""
            whResHeight = ""
            whResModeIdx = 0
            whClearCounter = whClearCounter + 1
            doWallhavenSearch(true)
          end,
        }),
      }),
    }),

    -- Right: Theme Mode Pills [Dark] [Light] [Auto]
    ui.row({
      align = "center",
      gap = 2,
      fill = "surface/0.65",
      border = "outline_variant/0.2",
      borderWidth = 1,
      radius = R(16),
      padding = 2,
    }, {
      ui.button({
        text = isCompact and nil or "Dark",
        glyph = "moon",
        variant = currentThemeMode == "dark" and "primary" or "ghost",
        controlSize = "sm",
        tooltip = "Dark Theme",
        onClick = function()
          currentThemeMode = "dark"
          noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "dark" }, function() end)
          render()
        end,
      }),
      ui.button({
        text = isCompact and nil or "Light",
        glyph = "sun",
        variant = currentThemeMode == "light" and "primary" or "ghost",
        controlSize = "sm",
        tooltip = "Light Theme",
        onClick = function()
          currentThemeMode = "light"
          noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "light" }, function() end)
          render()
        end,
      }),
      ui.button({
        text = isCompact and nil or "Auto",
        glyph = "brightness-auto",
        variant = currentThemeMode == "auto" and "primary" or "ghost",
        controlSize = "sm",
        tooltip = "Auto Theme",
        onClick = function()
          currentThemeMode = "auto"
          noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "auto" }, function() end)
          render()
        end,
      }),
    }),
  })
end

local function buildStandardRow2(panelW: number?)
  local pW = panelW or cachedPanelW
  local isCompact = (pW < 1260)
  local activeItem = displayedItems[selectedIdx]
  local activeFav = isItemFavorite(activeItem)

  return ui.row({
    align = "center",
    justify = "space_between",
    height = 36,
    width = pW - 64,
  }, {
    -- Left: Palette Source + Scheme Dropdown + Fav button
    ui.row({
      flexGrow = 1,
      align = "center",
      justify = "start",
      gap = isCompact and 6 or 10,
    }, {
      ui.row({
        align = "center",
        gap = 2,
        fill = "surface/0.65",
        border = "outline_variant/0.2",
        borderWidth = 1,
        radius = R(16),
        padding = 2,
      }, {
        ui.button({
          text = "Built-In",
          variant = (currentPaletteSource == "builtin") and "primary" or "ghost",
          controlSize = "sm",
          onClick = function()
            currentPaletteSource = "builtin"
            local name = BUILTIN_PALETTES[selectedBuiltinIdx or 1] or "Noctalia"
            noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "builtin", name }, function() end)
            render()
          end,
        }),
        ui.button({
          text = "Wallpaper",
          variant = (currentPaletteSource == "wallpaper") and "primary" or "ghost",
          controlSize = "sm",
          onClick = function()
            currentPaletteSource = "wallpaper"
            local s = SCHEMES[selectedSchemeIdx or 1]
            local schemeId = s and s.id or "m3-rainbow"
            noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "wallpaper", schemeId }, function() end)
            render()
          end,
        }),
        ui.button({
          text = "Community",
          variant = (currentPaletteSource == "community") and "primary" or "ghost",
          controlSize = "sm",
          onClick = function()
            currentPaletteSource = "community"
            local name = communityPalettes[selectedCommunityIdx or 1] or "Oxocarbon"
            noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "community", name }, function() end)
            render()
          end,
        }),
      }),

      (function()
        local currentOptions = SCHEME_OPTIONS
        local currentSelectedIdx = math.max(0, (selectedSchemeIdx or 1) - 1)
        local selectWidth = isCompact and 120 or 140

        if currentPaletteSource == "builtin" then
          currentOptions = BUILTIN_PALETTES
          currentSelectedIdx = math.max(0, (selectedBuiltinIdx or 1) - 1)
          selectWidth = isCompact and 110 or 130
        elseif currentPaletteSource == "community" then
          currentOptions = communityPalettes
          currentSelectedIdx = math.max(0, (selectedCommunityIdx or 1) - 1)
          selectWidth = isCompact and 135 or 170
        end

        return ui.select({
          key = "palette_select_" .. currentPaletteSource .. "_" .. tostring(currentSelectedIdx),
          options = currentOptions,
          selectedIndex = tonumber(currentSelectedIdx) or 0,
          controlSize = "sm",
          width = selectWidth,
          onChange = function(idx)
            local num = tonumber(idx)
            local chosenIdx = (num or 0) + 1
            if currentPaletteSource == "builtin" then
              selectedBuiltinIdx = chosenIdx
              local name = BUILTIN_PALETTES[chosenIdx]
              if name then
                noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "builtin", name }, function() end)
              end
            elseif currentPaletteSource == "community" then
              selectedCommunityIdx = chosenIdx
              local name = communityPalettes[chosenIdx]
              if name then
                noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "community", name }, function() end)
              end
            else
              selectedSchemeIdx = chosenIdx
              local s = SCHEMES[chosenIdx]
              if s then
                noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "wallpaper", s.id }, function() end)
              end
            end
            render()
          end,
        })
      end)(),

      ui.button({
        glyph = activeFav and "star-filled" or "star",
        variant = activeFav and "primary" or "ghost",
        controlSize = "sm",
        tooltip = activeFav and "Remove from Favourites (F)" or "Add to Favourites (F)",
        onClick = function()
          if toggleCurrentFavorite then
            toggleCurrentFavorite()
          end
        end,
      }),
    }),

    -- Center: Sort Pills
    ui.row({
      align = "center",
      justify = "center",
    }, {
      ui.row({
        align = "center",
        gap = 2,
        fill = "surface/0.65",
        border = "outline_variant/0.2",
        borderWidth = 1,
        radius = R(16),
        padding = 2,
      }, {
        ui.button({
          text = (currentSort == "name_desc") and "Name Z-A" or "Name A-Z",
          glyph = (currentSort == "name_desc") and "sort-z-a" or "sort-a-z",
          variant = (currentSort == "name_asc" or currentSort == "name_desc" or currentSort == "name") and "secondary" or "ghost",
          controlSize = "sm",
          tooltip = (currentSort == "name_asc" or currentSort == "name") and "Name: Ascending (click for Z-A)" or "Name: Descending (click for A-Z)",
          onClick = function()
            local nextSort = (currentSort == "name_asc" or currentSort == "name") and "name_desc" or "name_asc"
            changeSort(nextSort)
          end,
        }),
        ui.button({
          text = trText("ui.sort_colour", "Colour"),
          glyph = "palette",
          variant = currentSort == "colour" and "secondary" or "ghost",
          controlSize = "sm",
          tooltip = "Sort by Chromatic Hue",
          onClick = function()
            changeSort("colour")
          end,
        }),
        ui.button({
          text = (currentSort == "oldest") and "Oldest" or trText("ui.sort_newest", "Newest"),
          glyph = (currentSort == "oldest") and "history" or "clock",
          variant = (currentSort == "newest" or currentSort == "oldest") and "secondary" or "ghost",
          controlSize = "sm",
          tooltip = (currentSort == "newest") and "Newest first (click for Oldest)" or "Oldest first (click for Newest)",
          onClick = function()
            local nextSort = (currentSort == "newest") and "oldest" or "newest"
            changeSort(nextSort)
          end,
        }),
      }),
    }),

    -- Right: Theme Mode Pills [Dark] [Light] [Auto]
    ui.row({
      flexGrow = 1,
      align = "center",
      justify = "end",
    }, {
      ui.row({
        align = "center",
        gap = 2,
        fill = "surface/0.65",
        border = "outline_variant/0.2",
        borderWidth = 1,
        radius = R(16),
        padding = 2,
      }, {
        ui.button({
          text = isCompact and nil or "Dark",
          glyph = "moon",
          variant = currentThemeMode == "dark" and "primary" or "ghost",
          controlSize = "sm",
          tooltip = "Dark Theme",
          onClick = function()
            currentThemeMode = "dark"
            noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "dark" }, function() end)
            render()
          end,
        }),
        ui.button({
          text = isCompact and nil or "Light",
          glyph = "sun",
          variant = currentThemeMode == "light" and "primary" or "ghost",
          controlSize = "sm",
          tooltip = "Light Theme",
          onClick = function()
            currentThemeMode = "light"
            noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "light" }, function() end)
            render()
          end,
        }),
        ui.button({
          text = isCompact and nil or "Auto",
          glyph = "brightness-auto",
          variant = currentThemeMode == "auto" and "primary" or "ghost",
          controlSize = "sm",
          tooltip = "Auto Theme",
          onClick = function()
            currentThemeMode = "auto"
            noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "auto" }, function() end)
            render()
          end,
        }),
      }),
    }),
  })
end

local function checkWallhavenLazyLoad()
  if currentMode ~= "wallhaven" then return end
  if wallhavenLoadingMore then
    if noctalia.nowMs() - wallhavenLoadingStartMs > 8000 then
      wallhavenLoadingMore = false
    else
      return
    end
  end
  local items = wallhavenData.items or {}
  if #items == 0 then return end

  local currentPage = wallhavenData.page or 1
  local lastPage = wallhavenData.lastPage or 1

  if currentPage >= lastPage then return end

  if selectedIdx >= #displayedItems - 5 then
    wallhavenLoadingMore = true
    wallhavenLoadingStartMs = noctalia.nowMs()
    local nextPage = currentPage + 1
    noctalia.state.set("deck_command", {
      action = "wallhaven_search",
      query = whQuery,
      page = nextPage,
      append = true,
      filters = getActiveFilters(),
      nonce = noctalia.nowMs(),
    })
    if type(render) == "function" then
      render()
    end
  end
end

local function triggerPreview()
  local item = displayedItems[selectedIdx]
  if not item or not (item.path or item.id) then return end
  if currentMode == "wallhaven" then
    requestWallhavenThumb(item, true)
    checkWallhavenLazyLoad()
    return
  end
  local pPath = (item.path and item.path ~= "" and noctalia.fileExists(item.path)) and item.path or (item.preview or item.thumb or "")
  if lastPreviewed ~= pPath then
    lastPreviewed = pPath
  end
end

local function startDeckAnimation(targetIdx: number)
  if animateSelected then
    local dist = targetIdx - animatedPos
    if math.abs(dist) > (DECK_K + 2) then
      local dir = (dist > 0) and 1 or -1
      animatedPos = targetIdx - dir * (DECK_K + 1)
      animVel = dir * 8.0
    end
    animTargetPos = targetIdx
    lastFrameMs = noctalia.nowMs()
    panel.setNeedsFrameTick(true)
  else
    animatedPos = targetIdx
    animTargetPos = targetIdx
    animVel = 0.0
    panel.setNeedsFrameTick(false)
  end
end

local lastSearchMs = 0
local function executeSearch()
  local now = noctalia.nowMs()
  if now - lastSearchMs < 150 then return end
  lastSearchMs = now

  if currentMode == "wallhaven" then
    local trimmed = noctalia.string.trim(whQuery or "")
    if trimmed ~= "" and (whSortIdx == 0 or whSortIdx == 1 or whSortIdx == 2) then
      whSortIdx = 5
      noctalia.state.set("wallhaven_sort", "relevance")
    end
    doWallhavenSearch(true)
  else
    selectedIdx = 1
    resetDeckAnimation(1.0)
    rebuildList()
    triggerPreview()
    if type(render) == "function" then
      render()
    end
  end
end

local function selectCardIndex(newIdx: number)
  if #displayedItems == 0 then return end
  local clamped = clamp(newIdx, 1, #displayedItems)
  if clamped == selectedIdx then return end
  selectedIdx = clamped
  pendingStepAfterAppend = false
  hiResQueue = {}
  startDeckAnimation(clamped)
  triggerPreview()
  scheduleSettle()
  if not animateSelected then
    onCardSettled()
  end
  if type(render) == "function" then
    render()
  end
end

local function applyCurrent()
  local item = displayedItems[selectedIdx]
  if not item then return end

  local targetOut = (selectedOutput == "ALL") and nil or selectedOutput

  if currentMode == "wallhaven" then
    local urlExt = string.match(item.fullUrl or item.path or "", "%.([^%.]+)$") or item.ext or "jpg"
    local ext = string.lower(urlExt)
    if ext == "jpeg" then ext = "jpg" end
    local cached = item.hiResPath or (WALLHAVEN_PREVIEW_DIR .. "/" .. item.id .. "." .. ext)
    if not (cached and noctalia.fileExists(cached)) then
      cached = nil
    end
    noctalia.state.set("deck_command", { action = "wallhaven_apply", item = item, cachedPath = cached, output = targetOut, nonce = noctalia.nowMs() })
  else
    local mode = noctalia.getConfig("backend_mode") or "native"
    if mode ~= "custom" and type(noctalia.setWallpaper) == "function" then
      if targetOut then
        noctalia.setWallpaper(targetOut, item.path)
      else
        noctalia.setWallpaper(item.path)
      end
    end
    activeWallpaper = item.path
    initialWallpaper = item.path
    lastPreviewed = item.path
    noctalia.state.set("deck_command", { action = "apply", path = item.path, output = targetOut, nonce = noctalia.nowMs() })
  end
  stopWheelListener()
  panel.close()
end

local function cancelAndClose()
  stopWheelListener()
  panel.close()
end

local function cyclePreviewFit()
  if previewFit == "cover" then
    previewFit = "contain"
  elseif previewFit == "contain" then
    previewFit = "stretch"
  else
    previewFit = "cover"
  end
  render()
end

local function cycleOutput()
  refreshConnectedOutputs()
  selectedOutputIdx = (selectedOutputIdx % #connectedOutputs) + 1
  selectedOutput = connectedOutputs[selectedOutputIdx] or "ALL"
  render()
end

function onSelectMonitorOutput(outName)
  if not outName then return end
  for idx, name in ipairs(connectedOutputs) do
    if name == outName then
      selectedOutputIdx = idx
      selectedOutput = name
      render()
      break
    end
  end
end

local function openMonitorMenu()
  refreshConnectedOutputs()
  local items = {
    { kind = "header", label = "Target Monitor" },
  }
  for _, outName in ipairs(connectedOutputs) do
    table.insert(items, {
      kind = "item",
      id = outName,
      label = outName .. (outName == selectedOutput and "  ✓" or ""),
      glyph = (outName == selectedOutput and "check") or ((outName == "ALL" and "devices") or "screen-share"),
      enabled = true,
    })
  end
  local ok = pcall(panel.openContextMenu, {
    items = items,
    onActivate = "onSelectMonitorOutput",
  })
  if not ok then
    cycleOutput()
  end
end

toggleFavoriteItem = function(item: any)
  if not item or not item.name then return end
  noctalia.state.set("deck_command", {
    action = "toggle_favorite",
    fileName = item.name,
    path = item.path,
    nonce = noctalia.nowMs(),
  })
  local b = item.base or baseName(item.name)
  if isItemFavorite(item) then
    favorites[item.name] = nil
    favorites[b] = nil
    if item.path then favorites[item.path] = nil end
    for _, ext in ipairs({ ".jpg", ".jpeg", ".png", ".webp" }) do
      favorites[b .. ext] = nil
    end
  else
    favorites[item.name] = true
    if string.sub(b, 1, 10) == "wallhaven-" then
      favorites[b] = true
      for _, ext in ipairs({ ".jpg", ".png", ".webp" }) do
        favorites[b .. ext] = true
      end
    end
  end
  cachedFavCount = -1
  if currentMode == "favorites" then
    rebuildList()
    resetDeckAnimation(selectedIdx)
  end
  render()
end

toggleCurrentFavorite = function()
  toggleFavoriteItem(displayedItems[selectedIdx])
end

changeSort = function(newSort: string)
  local currentItem = displayedItems[selectedIdx]
  local currentPath = currentItem and (currentItem.path or currentItem.id)
  currentSort = newSort
  rebuildList()
  if currentPath and #displayedItems > 0 then
    for i, it in ipairs(displayedItems) do
      if (it.path or it.id) == currentPath then
        selectedIdx = i
        break
      end
    end
  end
  resetDeckAnimation(selectedIdx)
  render()
end

local function cycleSort()
  local nextSort = "name_asc"
  if currentSort == "name_asc" or currentSort == "name" then
    nextSort = "name_desc"
  elseif currentSort == "name_desc" then
    nextSort = "colour"
  elseif currentSort == "colour" then
    nextSort = "newest"
  elseif currentSort == "newest" then
    nextSort = "oldest"
  end
  changeSort(nextSort)
end

local function cycleMode()
  if currentMode == "local" then
    currentMode = "favorites"
  elseif currentMode == "favorites" then
    currentMode = "wallhaven"
    if #((wallhavenData and wallhavenData.items) or {}) == 0 then
      doWallhavenSearch(true)
    end
  else
    currentMode = "local"
  end
  selectedIdx = 1
  resetDeckAnimation(1.0)
  rebuildList()
  triggerPreview()
  if currentMode == "wallhaven" then
    onCardSettled()
  end
  render()
end

local function pickRandom()
  if #displayedItems > 0 then
    selectCardIndex(math.random(1, #displayedItems))
  end
end

-- Renders the full-screen width Spectrum Ribbon below the header
local function renderSpectrumRibbon(panelW: number?)
  local pW = panelW or cachedPanelW
  local count = #displayedItems
  if count == 0 then
    return ui.box({ width = pW - 64, height = 6, fill = "surface_container/0.3", radius = R(3) })
  end
  if cachedRibbon and cachedRibbonIdx == selectedIdx and cachedRibbonCount == count then
    return cachedRibbon
  end

  local segCount = math.min(count, 32)
  local segments = {}

  for i = 1, segCount do
    local itemIndex = math.floor((i - 1) * (count / segCount)) + 1
    local item = displayedItems[itemIndex]
    local color = (item and item.sourceColor) or "#4285f4"
    local isFront = (math.abs(itemIndex - selectedIdx) < math.ceil(count / segCount))

    table.insert(segments, ui.box({
      flexGrow = 1,
      height = isFront and 14 or 6,
      fill = color,
      border = isFront and "primary" or nil,
      borderWidth = isFront and 1 or 0,
      radius = (i == 1 or i == segCount) and R(3) or 0,
      onClick = function()
        selectCardIndex(itemIndex)
      end,
    }))
  end

  local res = ui.row({
    align = "center",
    justify = "center",
    width = pW - 64,
    gap = 2,
    height = 16,
    paddingV = 2,
  }, segments)
  cachedRibbon = res
  cachedRibbonIdx = selectedIdx
  cachedRibbonCount = count
  return res
end

-- Renders one card in the arched coverflow deck
local function renderCard(item: any, index: number, distSigned: number, scale: number?)
  local s = scale or 1.0
  local dist = math.abs(distSigned)
  local isCenter = dist < 0.4

  local cardW = getCardWidth(dist, s)
  local cardH = getCardHeight(dist, s)
  local imgH = math.floor(cardH * 0.42)
  local lift = getCardLift(dist, s)
  local slotH = cardH + lift
  local maxDeckH = math.floor(344 * s + 80 * s)

  local opacity = 1.0
  if dist > DECK_K then
    opacity = math.max(0.0, clamp(1.0 - (dist - DECK_K), 0.0, 1.0) * 0.80)
  else
    opacity = lerp(1.0, 0.80, dist / DECK_K)
  end

  local isCurrent = activeWallpaper ~= "" and activeWallpaper == item.path

  local previewPath = nil
  if currentMode == "wallhaven" then
    previewPath = requestWallhavenThumb(item, isCenter)
  else
    if item._previewPath ~= nil then
      previewPath = (item._previewPath ~= "") and item._previewPath or nil
    else
      local p = item.thumb or item.preview or item.path
      if p and p ~= "" and noctalia.fileExists(p) then
        item._previewPath = p
        previewPath = p
      else
        item._previewPath = ""
        previewPath = nil
      end
    end
  end

  local chipRows = item._chipRows
  local chipStrip = item._chipStrip
  local colors = item.colors
  local hasRealColors = (colors and colors.primary and colors.primary ~= "#80a9ff")

  if not chipRows or not chipStrip or item._renderedColors ~= colors then
    item._renderedColors = colors
    local cList = colors or {}
    local pCol = cList.primary or "#80a9ff"
    local sCol = cList.secondary or "#bfc6dc"
    local tCol = cList.tertiary or "#dfbde4"
    local pcCol = cList.primary_container or "#20468a"
    local schCol = cList.surface_container_highest or "#33353b"

    local chips = {
      { label = "PRIMARY", col = pCol },
      { label = "SECONDARY", col = sCol },
      { label = "TERTIARY", col = tCol },
      { label = "CONTAINER", col = pcCol },
      { label = "SURFACE", col = schCol },
    }

    local rows = {}
    for _, c in ipairs(chips) do
      local textColor = inkOn(c.col)
      table.insert(rows, ui.row({
        align = "center",
        justify = "space_between",
        fill = c.col,
        radius = R(3),
        height = 13,
        paddingH = 4,
      }, {
        ui.label({
          text = c.label,
          fontSize = 7,
          fontWeight = "bold",
          color = textColor,
        }),
        ui.label({
          text = string.upper(c.col),
          fontSize = 7,
          fontFamily = "JetBrainsMono Nerd Font",
          color = textColor,
        }),
      }))
    end
    chipRows = rows

    chipStrip = ui.row({
      gap = 2,
      height = 7,
      align = "center",
      justify = "space_between",
    }, {
      ui.box({ fill = pCol, flexGrow = 1, height = 7, radius = R(2) }),
      ui.box({ fill = sCol, flexGrow = 1, height = 7, radius = R(2) }),
      ui.box({ fill = tCol, flexGrow = 1, height = 7, radius = R(2) }),
      ui.box({ fill = pcCol, flexGrow = 1, height = 7, radius = R(2) }),
      ui.box({ fill = schCol, flexGrow = 1, height = 7, radius = R(2) }),
    })

    if hasRealColors then
      item._chipRows = chipRows
      item._chipStrip = chipStrip
    else
      item._chipRows = nil
      item._chipStrip = nil
    end
  end

  if currentMode ~= "wallhaven" and not hasRealColors and not item._paletteRequested and item.path then
    item._paletteRequested = true
    noctalia.state.set("deck_command", { action = "prioritize_palette", path = item.path })
  end

  local chipsElement = (cardH >= 210) and ui.column({ gap = 2 }, chipRows) or chipStrip

  local displayName = item._displayName
  local detailLine = item._detailLine
  if not displayName or not detailLine then
    local resText = ""
    if item.resolution and item.resolution ~= "" then
      resText = item.resolution .. " • "
    elseif item.res and item.res ~= "" then
      resText = item.res .. " • "
    elseif item.width and item.width > 0 and item.height and item.height > 0 then
      resText = string.format("%d × %d • ", item.width, item.height)
    end
    displayName = item.base or baseName(item.name or "")
    local extStr = item.ext
    if not extStr or extStr == "" then
      local dotExt = string.match(item.name or item.path or "", "%.([^%.]+)$")
      extStr = dotExt and string.upper(dotExt) or "IMG"
    end
    local sizeFormatted = item.sizeStr or formatBytes(item.size or 0)
    if sizeFormatted ~= "" then
      detailLine = string.format("%s • %s%s", extStr, resText, sizeFormatted)
    elseif resText ~= "" then
      detailLine = string.format("%s • %s", extStr, string.gsub(resText, " • $", ""))
    else
      detailLine = extStr
    end
    item._displayName = displayName
    item._detailLine = detailLine
  end

  local itemKey = tostring(item.path or item.id or item.name or index)

  return ui.column({
    key = "slot_wrap_" .. itemKey,
    width = cardW,
    height = maxDeckH,
    align = "center",
    justify = "end",
    opacity = opacity,
    onHover = "onDeckHover",
  }, {
    ui.column({
      key = "card_" .. itemKey,
      width = cardW,
      height = slotH,
      align = "center",
      justify = "start",
      onHover = "onDeckHover",
      onClick = function()
        isSearchFocused = false
        if selectedIdx == index then
          applyCurrent()
        else
          selectCardIndex(index)
        end
      end,
    }, {
      -- Card Shell
      ui.column({
        width = cardW,
        height = cardH,
        fill = isCenter and "surface" or "surface_container/0.88",
        radius = R(math.max(4, math.floor(10 * s))),
        border = isCenter and "primary" or "outline_variant/0.25",
        borderWidth = isCenter and 2 or 1,
        padding = math.max(3, math.floor(6 * s)),
        gap = math.max(2, math.floor(3 * s)),
      }, {
        -- Header row on card (✓ current badge and // name tag)
        ui.row({ align = "center", justify = "space_between", paddingH = 2, height = math.floor(14 * math.max(0.75, s)) }, {
          isCurrent and ui.row({
            fill = "primary",
            radius = R(4),
            paddingH = math.max(2, math.floor(4 * s)),
            paddingV = 1,
          }, {
            ui.label({
              text = "✓ " .. trText("ui.current", "current"),
              fontSize = (s < 0.7) and 6 or 7,
              fontWeight = "bold",
              color = "on_primary",
            }),
          }) or ui.spacer({ width = 1 }),
          ui.label({
            text = "// " .. ((item.relDir and item.relDir ~= "") and (item.relDir .. "/") or "") .. displayName,
            fontSize = (s < 0.7) and 6 or 7,
            fontFamily = "JetBrainsMono Nerd Font",
            color = isCenter and "primary" or "on_surface/0.5",
            maxWidth = math.max(24, cardW - (isCurrent and 60 or 14)),
            maxLines = 1,
          }),
        }),

        -- Artwork Window
        (previewPath and previewPath ~= "") and ui.image({
          key = "card_preview_" .. (item.name or "") .. "_" .. previewPath,
          path = previewPath,
          width = cardW - math.max(6, math.floor(12 * s)),
          height = imgH,
          radius = R(math.max(3, math.floor(6 * s))),
          border = isCenter and "primary/0.4" or "outline_variant/0.2",
          borderWidth = 1,
          fit = "cover",
        }) or ui.column({
          key = "card_preview_ph_" .. (item.name or tostring(index)),
          width = cardW - math.max(6, math.floor(12 * s)),
          height = imgH,
          radius = R(math.max(3, math.floor(6 * s))),
          border = isCenter and "primary/0.4" or "outline_variant/0.2",
          borderWidth = 1,
          fill = item.sourceColor or "surface_container/0.5",
          align = "center",
          justify = "center",
        }, {
          ui.glyph({
            name = (currentMode == "wallhaven" and thumbPending[item.id]) and "loader-2" or "photo",
            size = isCenter and math.floor(26 * s) or math.floor(20 * s),
            color = "on_surface/0.5",
          }),
        }),

        -- 5 Material 3 Chips (or compact palette strip when compact)
        chipsElement,

        -- Card Footer: Filename + Details
        ui.column({ gap = 1, paddingH = 2 }, {
          ui.label({
            text = displayName,
            fontSize = isCenter and ((s < 0.7) and 8 or 10) or ((s < 0.7) and 7 or 9),
            fontWeight = "bold",
            maxLines = 1,
            maxWidth = math.max(24, cardW - 12),
          }),
          ui.label({
            text = detailLine,
            fontSize = (s < 0.7) and 6 or 7,
            color = "on_surface/0.65",
            maxLines = 1,
            maxWidth = math.max(24, cardW - 12),
          }),
        }),
      }),
    }),
  })
end

local function renderScanningState(paletteColors: any)
  local targetDir = (currentWallDir ~= "" and currentWallDir) or noctalia.getConfig("wallpaper_dir") or "~/Pictures/Wallpapers"
  local displayDir = noctalia.expandPath(targetDir)

  return ui.column({
    key = "deck_scanning_container",
    align = "center",
    justify = "center",
    flexGrow = 1,
    padding = 24,
  }, {
    ui.column({
      key = "deck_scanning_card",
      align = "center",
      justify = "center",
      padding = 36,
      fill = "surface/0.85",
      border = "outline_variant/0.25",
      borderWidth = 1,
      radius = R(24),
      gap = 14,
    }, {
      ui.glyph({
        name = "loader-2",
        size = 48,
        color = paletteColors.accent,
      }),
      ui.label({
        text = "Scanning Wallpapers...",
        fontSize = 20,
        fontWeight = "heavy",
        color = paletteColors.primaryText,
      }),
      ui.label({
        text = displayDir,
        fontSize = 12,
        color = paletteColors.muted,
      }),
      ui.label({
        text = "Loading wallpapers from this folder...",
        fontSize = 11,
        color = paletteColors.muted,
      }),
    }),
  })
end

local function renderWallhavenLoadingState(paletteColors: any)
  local queryText = (whQuery and whQuery ~= "") and string.format("Searching for \"%s\"...", whQuery) or "Fetching latest wallpapers from Wallhaven..."
  return ui.column({
    key = "deck_wh_loading_container",
    align = "center",
    justify = "center",
    flexGrow = 1,
    padding = 24,
  }, {
    ui.column({
      key = "deck_wh_loading_card",
      align = "center",
      justify = "center",
      padding = 36,
      fill = "surface/0.85",
      border = "outline_variant/0.25",
      borderWidth = 1,
      radius = R(24),
      gap = 14,
    }, {
      ui.glyph({
        name = "loader-2",
        size = 48,
        color = paletteColors.accent,
      }),
      ui.label({
        text = "Searching Wallhaven...",
        fontSize = 20,
        fontWeight = "heavy",
        color = paletteColors.primaryText,
      }),
      ui.label({
        text = queryText,
        fontSize = 13,
        color = paletteColors.muted,
      }),
    }),
  })
end

local function renderEmptyState(paletteColors: any)
  local targetDir = (currentWallDir ~= "" and currentWallDir) or noctalia.getConfig("wallpaper_dir") or "~/Pictures/Wallpapers"
  local displayDir = noctalia.expandPath(targetDir)

  local glyphName = "folder-off"
  local title = "This directory is empty"
  local subtitle = string.format("Add your wallpapers in %s\nor select another directory in settings.", displayDir)
  local buttons = {}

  if currentMode == "favorites" then
    glyphName = "heart-off"
    title = "No Favourites Yet"
    subtitle = trText("ui.no_favorites", "Press F on any wallpaper in the deck to add it to your favourites.")
    buttons = {
      ui.button({
        text = "Browse Local",
        glyph = "folder",
        variant = "primary",
        controlSize = "md",
        onClick = function()
          currentMode = "local"
          selectedIdx = 1
          resetDeckAnimation(1.0)
          rebuildList()
          triggerPreview()
          render()
        end,
      }),
      ui.button({
        text = "Open Settings",
        glyph = "settings",
        variant = "secondary",
        controlSize = "md",
        onClick = openPluginSettings,
      }),
    }
  elseif currentMode == "wallhaven" then
    if wallhavenError ~= nil then
      local isOffline = true
      local errTitle = trText("ui.network_unavailable", "Network Unavailable")
      local errSub = trText("ui.network_unavailable_desc", "Could not connect to Wallhaven. Check your internet connection and try again.")
      if type(wallhavenError) == "table" then
        if wallhavenError.type == "offline" or wallhavenError.status == 0 or wallhavenError.offline == true then
          isOffline = true
        elseif wallhavenError.type == "unauthorized" or wallhavenError.status == 401 or wallhavenError.status == 403 then
          isOffline = false
          errTitle = "Invalid API Key"
          errSub = "Wallhaven API Key is invalid or expired. Check your key in settings."
        elseif wallhavenError.type == "rate_limited" or wallhavenError.status == 429 then
          isOffline = false
          errTitle = "Rate Limited"
          errSub = "Too many requests to Wallhaven. Please wait a moment and try again."
        else
          isOffline = false
          errTitle = "Connection Failed"
          errSub = wallhavenError.message or "Could not load wallpapers from Wallhaven."
        end
      elseif type(wallhavenError) == "string" then
        if string.find(string.lower(wallhavenError), "network") or string.find(string.lower(wallhavenError), "contact") or string.find(string.lower(wallhavenError), "offline") then
          isOffline = true
        else
          isOffline = false
          errTitle = "Connection Failed"
          errSub = wallhavenError
        end
      end

      glyphName = isOffline and "wifi-off" or "cloud-off"
      title = errTitle
      subtitle = errSub
      buttons = {
        ui.button({
          text = trText("ui.retry", "Retry"),
          glyph = "refresh",
          variant = "primary",
          controlSize = "md",
          onClick = function()
            doWallhavenSearch(true)
          end,
        }),
        ui.button({
          text = "Open Settings",
          glyph = "settings",
          variant = "secondary",
          controlSize = "md",
          onClick = openPluginSettings,
        }),
      }
    else
      glyphName = "photo-off"
      title = trText("ui.no_wallhaven", "No Wallpapers Found")
      subtitle = (whQuery and whQuery ~= "")
        and string.format("No wallpapers matched \"%s\". Try searching with different tags.", whQuery)
        or "Try searching with different tags or adjust your Wallhaven filters above."

      if whQuery and whQuery ~= "" then
        buttons = {
          ui.button({
            text = trText("ui.clear_search", "Clear Search"),
            glyph = "close",
            variant = "primary",
            controlSize = "md",
            onClick = function()
              whQuery = ""
              doWallhavenSearch(true)
            end,
          }),
          ui.button({
            text = "Open Settings",
            glyph = "settings",
            variant = "secondary",
            controlSize = "md",
            onClick = openPluginSettings,
          }),
        }
      else
        buttons = {
          ui.button({
            text = trText("ui.retry", "Retry"),
            glyph = "refresh",
            variant = "primary",
            controlSize = "md",
            onClick = function()
              doWallhavenSearch(true)
            end,
          }),
          ui.button({
            text = "Open Settings",
            glyph = "settings",
            variant = "secondary",
            controlSize = "md",
            onClick = openPluginSettings,
          }),
        }
      end
    end
  elseif not isFlattened and #allWallpapers > 0 then
    glyphName = "folder-tree"
    title = "Subdirectory wallpapers hidden"
    subtitle = "Wallpapers were found in subdirectories. Enable Flatten to display them."
    buttons = {
      ui.button({
        text = "Show Subdirectory Wallpapers",
        glyph = "folder",
        variant = "primary",
        controlSize = "md",
        onClick = function()
          isFlattened = true
          rebuildList()
          render()
        end,
      }),
      ui.button({
        text = "Open Settings",
        glyph = "settings",
        variant = "secondary",
        controlSize = "md",
        onClick = openPluginSettings,
      }),
    }
  else
    glyphName = "folder-off"
    title = "This directory is empty"
    subtitle = string.format("Add your wallpapers in %s\nor select another directory in settings.", displayDir)
    buttons = {
      ui.button({
        text = "Open Settings",
        glyph = "settings",
        variant = "primary",
        controlSize = "md",
        onClick = openPluginSettings,
      }),
      ui.button({
        text = "Rescan Folder",
        glyph = "refresh",
        variant = "secondary",
        controlSize = "md",
        onClick = function()
          noctalia.state.set("deck_command", { action = "rescan", nonce = noctalia.nowMs() })
        end,
      }),
    }
  end

  return ui.column({
    key = "deck_empty_container",
    align = "center",
    justify = "center",
    flexGrow = 1,
    padding = 24,
  }, {
    ui.column({
      key = "deck_empty_card",
      align = "center",
      justify = "center",
      padding = 36,
      fill = "surface/0.85",
      border = "outline_variant/0.25",
      borderWidth = 1,
      radius = R(24),
      gap = 14,
    }, {
      ui.glyph({
        name = glyphName,
        size = 52,
        color = paletteColors.accent,
      }),
      ui.label({
        text = title,
        fontSize = 20,
        fontWeight = "heavy",
        color = paletteColors.primaryText,
      }),
      ui.label({
        text = subtitle,
        fontSize = 13,
        color = paletteColors.muted,
      }),
      ui.row({
        align = "center",
        justify = "center",
        gap = 12,
        paddingV = 10,
      }, buttons),
    }),
  })
end

local function renderBgLayer(panelW: number, panelH: number, activeItem: any)
  local bgChildren = {}
  local ease = easeBg(bgTransitionProgress)
  local bgFill = (#displayedItems > 0 and activeItem and activeItem.sourceColor) or "surface"

  if prevBgPath ~= "" and bgTransitionProgress < 1.0 and noctalia.fileExists(prevBgPath) then
    local prevAlpha = clampVal(1.0 - ease, 0.0, 1.0)
    table.insert(bgChildren, ui.column({
      key = "deck_bg_prev_wrap",
      width = panelW,
      height = panelH,
      padding = 0,
      opacity = prevAlpha,
      fill = bgFill,
      align = "stretch",
      justify = "start",
    }, {
      ui.image({
        key = "deck_bg_prev_img_" .. prevBgPath,
        path = prevBgPath,
        width = panelW,
        height = panelH,
        radius = R(12),
        fit = previewFit,
      }),
    }))
  end

  if displayedBgPath ~= "" and noctalia.fileExists(displayedBgPath) then
    local currAlpha = (prevBgPath ~= "" and bgTransitionProgress < 1.0) and ease or 1.0
    table.insert(bgChildren, ui.column({
      key = "deck_bg_curr_wrap",
      width = panelW,
      height = panelH,
      padding = 0,
      opacity = currAlpha,
      fill = (previewFit == "contain") and bgFill or nil,
      align = "stretch",
      justify = "start",
    }, {
      ui.image({
        key = "deck_bg_curr_img_" .. displayedBgPath,
        path = displayedBgPath,
        width = panelW,
        height = panelH,
        radius = R(12),
        fit = previewFit,
      }),
    }))
  else
    table.insert(bgChildren, ui.column({
      key = "bg_fallback",
      width = panelW,
      height = panelH,
      radius = R(12),
      fill = bgFill,
      align = "center",
      justify = "center",
    }, {
      (#displayedItems > 0 and currentMode == "wallhaven" and (not displayedBgPath or displayedBgPath == "")) and ui.row({
        align = "center",
        justify = "center",
        paddingH = 18,
        paddingV = 9,
        radius = R(20),
        fill = "surface/0.8",
        border = "outline_variant/0.3",
        borderWidth = 1,
        gap = 8,
      }, {
        ui.glyph({ name = "loader-2", size = 16, color = "primary" }),
        ui.label({ text = trText("ui.loading", "Loading preview..."), fontSize = 11, fontWeight = "bold", color = "on_surface" }),
      }) or ui.spacer({ width = 1, height = 1 }),
    }))
  end

  local isStacked = (#bgChildren > 1)
  return ui.column({
    key = "bg_layer",
    width = panelW,
    height = panelH,
    padding = 0,
    gap = isStacked and -panelH or 0,
    align = "stretch",
    justify = "start",
  }, bgChildren)
end

function render()
  updatePanelGeometry()
  local panelW, panelH = getPanelGeometry()
  local centerIdx = clamp(math.floor(animatedPos + 0.5), 1, math.max(1, #displayedItems))
  local activeItem = displayedItems[centerIdx]
  local isCurrent = activeItem and activeWallpaper ~= "" and activeWallpaper == activeItem.path
  local isFav = isItemFavorite(activeItem)
  local paletteColors = getWallpaperPaletteFontColors(activeItem)
  local isStripeWhite = paletteColors.isLight == true
  local headerTextColor = isStripeWhite and "#000000" or "#ffffff"
  local stripeTextColor = isStripeWhite and "#000000" or "#ffffff"
  local stripeBulletColor = isStripeWhite and "#00000088" or "#ffffff88"
  local stripeFill = isStripeWhite and "#ffffff99" or "surface/0.60"
  local stripeBorder = isStripeWhite and (paletteColors.accent .. "30") or "outline_variant/0.2"

  local deckCards = {}
  local screenCenterX = panelW / 2
  local deckScale = getDeckScale(panelW, panelH)
  local gap = math.max(6, math.floor(12 * deckScale))
  local maxDeckH = math.floor(344 * deckScale + 80 * deckScale)

  if #displayedItems > 0 then
    local pos = clamp(animatedPos, 1.0, #displayedItems)
    local C = math.floor(pos)
    local frac = pos - C

    local minIdx = math.max(1, C - DECK_K)
    -- Only include C + DECK_K + 1 during active fractional interpolation (frac > 0.001)
    -- so that when settled (frac == 0), the deck is strictly symmetric (DECK_K left, DECK_K right)
    local maxIdx = math.min(#displayedItems, C + DECK_K + ((frac > 0.001) and 1 or 0))

    local cardWidths = {}
    for idx = minIdx, maxIdx do
      cardWidths[idx] = getCardWidth(idx - pos, deckScale)
    end

    local wC = cardWidths[C] or getCardWidth(0, deckScale)
    local wC_next = cardWidths[C + 1] or wC
    local pitchC = (wC + wC_next) / 2.0 + gap

    -- Dynamically ensure left and right card spans never overflow panelW
    while minIdx < C do
      local sumLeftTmp = 0
      for idx = minIdx, C - 1 do
        sumLeftTmp = sumLeftTmp + cardWidths[idx] + gap
      end
      local testLeft = screenCenterX - (wC / 2.0) - sumLeftTmp - (frac * pitchC)
      if testLeft < 8 then
        minIdx = minIdx + 1
      else
        break
      end
    end

    local sumLeft = 0
    for idx = minIdx, C - 1 do
      sumLeft = sumLeft + cardWidths[idx] + gap
    end

    local leftEdgeMin = screenCenterX - (wC / 2.0) - sumLeft - (frac * pitchC)
    local hasLeftSpacer = (leftEdgeMin > gap)
    local leftSpacerWidth = hasLeftSpacer and math.max(1, math.floor(leftEdgeMin - gap)) or 0
    local actualStartX = hasLeftSpacer and (leftSpacerWidth + gap) or 0

    while maxIdx > C do
      local totalCardsW = 0
      for idx = minIdx, maxIdx do
        totalCardsW = totalCardsW + cardWidths[idx] + ((idx < maxIdx) and gap or 0)
      end
      if actualStartX + totalCardsW > panelW - 8 then
        maxIdx = maxIdx - 1
      else
        break
      end
    end

    if hasLeftSpacer then
      table.insert(deckCards, ui.box({
        key = "deck_left_spacer",
        width = leftSpacerWidth,
        height = 1,
      }))
    end

    for idx = minIdx, maxIdx do
      local distSigned = idx - pos
      table.insert(deckCards, renderCard(displayedItems[idx], idx, distSigned, deckScale))
    end
  end

  local favCount = getFavCount()

  local activeBg = ""
  if activeItem then
    if currentMode == "wallhaven" then
      if hiResPreview then
        local hiRes = getWallhavenHiResCached(activeItem)
        if hiRes and hiRes ~= "" then
          activeBg = hiRes
        else
          activeBg = requestWallhavenThumb(activeItem, true) or ""
        end
      else
        activeBg = requestWallhavenThumb(activeItem, true) or ""
      end
    else
      if activeItem._validPath == nil then
        activeItem._validPath = (activeItem.path and activeItem.path ~= "" and noctalia.fileExists(activeItem.path)) and activeItem.path or (activeItem.preview or activeItem.thumb or "")
      end
      activeBg = activeItem._validPath
    end
  end

  if #displayedItems == 0 then
    displayedBgPath = ""
    prevBgPath = ""
    bgTransitionProgress = 1.0
  else
    local isSettled = (not animateSelected) or (math.abs(animatedPos - selectedIdx) < 0.05)
    if (isSettled or displayedBgPath == "") and activeBg ~= "" then
      setDisplayedBackground(activeBg)
    end
  end

  if isPeeking then
    panel.render(ui.column({
      key = "panel_root",
      width = panelW,
      height = panelH,
      flexGrow = 1,
      gap = -panelH,
      padding = 0,
      align = "stretch",
      justify = "start",
    }, {
      -- Slot 1: Fullscreen Wallpaper Background
      renderBgLayer(panelW, panelH, activeItem),

      -- Slot 2: Peek Bottom Pill Overlay
      ui.column({
        key = "peek_overlay",
        width = panelW,
        height = panelH,
        flexGrow = 1,
        padding = 0,
        gap = 0,
        align = "stretch",
        justify = "space_between",
      }, {
        ui.spacer({ height = 16 }),
        ui.spacer({ flexGrow = 1 }),
        ui.row({
          align = "center",
          justify = "center",
          width = panelW,
          height = 48,
          paddingV = 6,
          borderWidth = 0,
          radius = 0,
        }, {
          ui.row({
            align = "center",
            justify = "center",
            height = 38,
            paddingH = 20,
            fill = "surface/0.88",
            radius = R(19),
            border = "primary/0.35",
            borderWidth = 1,
            gap = 12,
          }, {
            ui.label({ text = activeItem and activeItem.name or "", fontSize = 12, fontWeight = "bold", color = paletteColors.accent }),
            ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }),
            ui.label({ text = "Fit: " .. previewFit .. " (V)", fontSize = 11, color = paletteColors.muted }),
            ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }),
            ui.label({ text = "Space or Esc: back to deck", fontSize = 11, color = paletteColors.muted }),
          }),
        }),
      }),
    }))
    return
  end

  local searchBoxW = clamp(math.floor(panelW * ((currentMode == "wallhaven") and 0.18 or 0.14)), 140, (currentMode == "wallhaven") and 340 or 240)
  local searchInputW = math.max(80, searchBoxW - 64)

  -- Fullscreen Immersive Overlay with Fullscreen Wallpaper Background
  panel.render(ui.column({
    key = "panel_root",
    width = panelW,
    height = panelH,
    flexGrow = 1,
    gap = -panelH,
    padding = 0,
    align = "stretch",
    justify = "start",
  }, {
    -- Slot 1: Fullscreen Wallpaper Background Preview
    renderBgLayer(panelW, panelH, activeItem),

    -- Slot 2: Fullscreen UI Elements Overlaid on Top
    ui.column({
      key = "deck_overlay",
      width = panelW,
      height = panelH,
      flexGrow = 1,
      padding = 0,
      gap = 0,
      align = "stretch",
      justify = "space_between",
    }, {
      -- ── TOP HEADER SECTION ─────────────────────────────────────────
      ui.column({ width = panelW, gap = 8, paddingH = 32, paddingV = 14 }, {
        -- Row 1: App Info + Filter Input | Mode Pills | Flatten Toggle + Action Icons
        ui.row({
          align = "center",
          justify = "space_between",
          width = panelW - 64,
          height = 42,
        }, {
          -- Left: Title & Filter Input
          ui.row({
            flexGrow = 1,
            align = "center",
            justify = "start",
            gap = 12,
          }, {
            ui.row({ align = "center", gap = 10 }, {
              ui.glyph({ name = "cards", size = 24, color = isStripeWhite and "#000000" or paletteColors.accent }),
              ui.column({ gap = 1 }, {
                ui.label({ text = trText("title", "Wallpapers"), fontSize = 16, fontWeight = "heavy", color = headerTextColor }),
                ui.label({
                  text = (#displayedItems == 0) and (
                    (currentMode ~= "wallhaven" and currentMode ~= "favorites" and isScanning) and "scanning..."
                      or (currentMode == "wallhaven" and wallhavenLoading) and "searching..."
                      or (currentMode == "wallhaven" and wallhavenError ~= nil) and "offline"
                      or "0 wallpapers"
                  )
                    or ((currentMode == "wallhaven" and wallhavenLoadingMore)
                      and string.format("%d of %d (loading...)", selectedIdx, math.max(1, #displayedItems))
                      or string.format("%d of %d", selectedIdx, math.max(1, #displayedItems))),
                  fontSize = 10,
                  color = isStripeWhite and "#00000099" or paletteColors.muted,
                }),
              }),
            }),

            -- Search / Filter Input
            ui.row({
              align = "center",
              gap = 6,
            }, {
              ui.row({
                align = "center",
                gap = 6,
                fill = "surface/0.85",
                border = (isSearchFocused or (currentMode == "wallhaven" and whQuery ~= "") or (currentMode ~= "wallhaven" and searchQuery ~= "")) and paletteColors.accent or "outline_variant/0.25",
                borderWidth = isSearchFocused and 1.5 or 1,
                radius = R(10),
                paddingH = 10,
                height = 32,
                width = searchBoxW,
                onClick = function()
                  isSearchFocused = true
                  render()
                end,
              }, {
                ui.glyph({
                  name = "search",
                  size = 14,
                  color = (isSearchFocused or (currentMode == "wallhaven" and whQuery ~= "") or (currentMode ~= "wallhaven" and searchQuery ~= "")) and paletteColors.accent or paletteColors.muted,
                }),
                ui.input({
                  key = "deck_search_input_" .. (currentMode == "wallhaven" and "wh" or "local"),
                  value = (currentMode == "wallhaven") and whQuery or searchQuery,
                  placeholder = (currentMode == "wallhaven") and "Search tags..." or trText("ui.search_placeholder", "Filter..."),
                  controlSize = "sm",
                  frameVisible = false,
                  flexGrow = 1,
                  focus = isSearchFocused and true or nil,
                  submitOnEnter = true,
                  width = searchInputW,
                  onChange = function(val)
                    isSearchFocused = true
                    if currentMode == "wallhaven" then
                      whQuery = val or ""
                    else
                      searchQuery = val or ""
                      selectedIdx = 1
                      resetDeckAnimation(1.0)
                      rebuildList()
                      triggerPreview()
                      render()
                    end
                  end,
                  onSubmit = function(val)
                    if val and val ~= "" then
                      if currentMode == "wallhaven" then
                        whQuery = val
                      else
                        searchQuery = val
                      end
                    end
                    isSearchFocused = false
                    executeSearch()
                    render()
                  end,
                }),
                ((currentMode == "wallhaven" and whQuery ~= "") or (currentMode ~= "wallhaven" and searchQuery ~= "")) and ui.button({
                  glyph = "close",
                  variant = "ghost",
                  controlSize = "sm",
                  onClick = function()
                    if currentMode == "wallhaven" then
                      whQuery = ""
                      if whSortIdx == 5 then
                        whSortIdx = 0
                        noctalia.state.set("wallhaven_sort", "date_added")
                      end
                      doWallhavenSearch(true)
                    else
                      searchQuery = ""
                      selectedIdx = 1
                      resetDeckAnimation(1.0)
                      rebuildList()
                      triggerPreview()
                      render()
                    end
                  end,
                }) or ui.spacer({ width = 1 }),
              }),
              (currentMode == "wallhaven") and ui.button({
                text = "Search",
                variant = "primary",
                controlSize = "sm",
                onClick = function()
                  executeSearch()
                end,
              }) or ui.spacer({ width = 1 }),
            }),
          }),

          -- Center: Mode selector pills
          ui.row({
            align = "center",
            gap = 4,
            fill = "surface/0.75",
            border = "outline_variant/0.25",
            borderWidth = 1,
            radius = R(20),
            padding = 3,
          }, {
            ui.button({
              text = trText("ui.tab_local", "Local"),
              variant = currentMode == "local" and "primary" or "ghost",
              controlSize = "sm",
              onClick = function()
                isSearchFocused = false
                currentMode = "local"
                selectedIdx = 1
                resetDeckAnimation(1.0)
                rebuildList()
                triggerPreview()
                render()
              end,
            }),
            ui.button({
              text = string.format("%s %d", trText("ui.tab_favorites", "Favourites"), favCount),
              glyph = "heart",
              variant = currentMode == "favorites" and "primary" or "ghost",
              controlSize = "sm",
              onClick = function()
                isSearchFocused = false
                currentMode = "favorites"
                selectedIdx = 1
                resetDeckAnimation(1.0)
                rebuildList()
                triggerPreview()
                render()
              end,
            }),
            ui.button({
              text = trText("ui.tab_wallhaven", "Wallhaven"),
              glyph = "world",
              variant = currentMode == "wallhaven" and "primary" or "ghost",
              controlSize = "sm",
              onClick = function()
                isSearchFocused = false
                currentMode = "wallhaven"
                selectedIdx = 1
                resetDeckAnimation(1.0)
                if #((wallhavenData and wallhavenData.items) or {}) == 0 then
                  doWallhavenSearch(true)
                end
                rebuildList()
                triggerPreview()
                onCardSettled()
                render()
              end,
            }),
          }),

          -- Right: Hi-Res preview button + Flatten toggle + Action icons
          ui.row({
            flexGrow = 1,
            align = "center",
            gap = 10,
          }, {
            (currentMode == "wallhaven") and ui.row({
              align = "center",
              gap = 0,
            }, {
              ui.spacer({ width = 6 }),
              (function()
                local isLoadingHiRes = hiResPreview and activeItem and (hiResPending[activeItem.id] == true or (function()
                  for _, it in ipairs(hiResQueue) do
                    if it.id == (activeItem and activeItem.id) then return true end
                  end
                  return false
                end)())

                return ui.button({
                  text = isLoadingHiRes and "Hi-Res..." or (hiResPreview and "Hi-Res ON" or "Hi-Res OFF"),
                  glyph = isLoadingHiRes and "loader-2" or "sparkles",
                  variant = hiResPreview and "primary" or "secondary",
                  controlSize = "sm",
                  tooltip = hiResPreview and "Hi-Res Preview is ON (caching full HD for preview) [Press P]" or "Enable Hi-Res Preview (downloads full HD to cache) [Press P]",
                  onClick = function()
                    hiResPreview = not hiResPreview
                    if not hiResPreview then
                      hiResQueue = {}
                    else
                      displayedBgPath = ""
                      prevBgPath = ""
                      bgTransitionProgress = 1.0
                      onCardSettled()
                    end
                    triggerPreview()
                    render()
                  end,
                })
              end)(),
            }) or ui.spacer({ width = 1 }),

            ui.spacer({ flexGrow = 1 }),

            -- Flatten Toggle (Local)
            (currentMode ~= "wallhaven" and ui.row({ align = "center", gap = 6 }, {
              ui.label({ text = "Flatten", fontSize = 12, color = isFlattened and paletteColors.accent or paletteColors.primaryText }),
              ui.toggle({
                checked = isFlattened,
                onChange = function(checked)
                  isFlattened = (checked == "true" or checked == true)
                  invalidateSortCache()
                  selectedIdx = 1
                  resetDeckAnimation(1.0)
                  rebuildList()
                  triggerPreview()
                  render()
                end,
              }),
            }) or ui.spacer({ width = 1 })),

            -- Action Buttons (Settings, Fit, Peek, Random, Rescan, Close)
            ui.row({
              align = "center",
              gap = 2,
              fill = "surface/0.65",
              border = "outline_variant/0.2",
              borderWidth = 1,
              radius = R(16),
              padding = 2,
            }, {
              ui.button({
                glyph = "settings",
                variant = "ghost",
                controlSize = "sm",
                tooltip = "Plugin Settings",
                onClick = openPluginSettings,
              }),
              ui.button({
                glyph = (previewFit == "contain") and "aspect-ratio" or ((previewFit == "stretch") and "arrows-maximize" or "crop"),
                variant = (previewFit ~= "cover") and "secondary" or "ghost",
                controlSize = "sm",
                tooltip = "Preview Fit: " .. previewFit .. " (Press V to cycle cover/contain/stretch)",
                onClick = cyclePreviewFit,
              }),
              ui.button({
                glyph = isPeeking and "eye-off" or "eye",
                variant = isPeeking and "primary" or "ghost",
                controlSize = "sm",
                tooltip = "Peek Wallpaper (Space)",
                onClick = function()
                  isPeeking = not isPeeking
                  render()
                end,
              }),
              ui.button({
                glyph = "dice",
                variant = "ghost",
                controlSize = "sm",
                tooltip = "Random Wallpaper (R)",
                onClick = pickRandom,
              }),
              ui.button({
                glyph = "refresh",
                variant = "ghost",
                controlSize = "sm",
                tooltip = (currentMode == "wallhaven") and "Refresh Wallhaven" or "Rescan Folder",
                onClick = function()
                  if currentMode == "wallhaven" then
                    doWallhavenSearch(true)
                  else
                    noctalia.state.set("deck_command", { action = "rescan", nonce = noctalia.nowMs() })
                  end
                end,
              }),
              ui.button({
                glyph = "close",
                variant = "ghost",
                controlSize = "sm",
                tooltip = "Close (Esc)",
                onClick = cancelAndClose,
              }),
            }),
          }),
        }),

        -- Row 2: Individual controls (Wallhaven row in wallhaven mode, Standard palette/theme in local mode)
        (#displayedItems > 0) and ((currentMode == "wallhaven") and buildWallhavenRow2(paletteColors, panelW) or buildStandardRow2(panelW)) or ui.spacer({ width = 1, height = 1 }),

        -- Spectrum Ribbon (Edge-to-Edge)
        (#displayedItems > 0) and renderSpectrumRibbon(panelW) or ui.spacer({ width = 1, height = 1 }),

        -- Keyboard Hints Bar
        (#displayedItems > 0) and (function()
          local hintLabels = {
            ui.label({ text = "← → or wheel browse", fontSize = 10, color = stripeTextColor }),
            ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }),
            ui.label({ text = "Enter apply", fontSize = 10, fontWeight = "bold", color = stripeTextColor }),
            ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }),
            ui.label({ text = "F favourite", fontSize = 10, color = stripeTextColor }),
            ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }),
            ui.label({ text = "S sort", fontSize = 10, color = stripeTextColor }),
            ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }),
            ui.label({ text = "R random", fontSize = 10, color = stripeTextColor }),
            ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }),
            ui.label({ text = "V fit (" .. previewFit .. ")", fontSize = 10, color = stripeTextColor }),
            ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }),
            ui.label({ text = "Space peek", fontSize = 10, color = stripeTextColor }),
            ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }),
          }
          if currentMode == "wallhaven" then
            table.insert(hintLabels, ui.label({ text = "P hi-res", fontSize = 10, fontWeight = hiResPreview and "bold" or "normal", color = stripeTextColor }))
            table.insert(hintLabels, ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }))
          end
          table.insert(hintLabels, ui.label({ text = "M monitor", fontSize = 10, color = stripeTextColor }))
          table.insert(hintLabels, ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }))
          table.insert(hintLabels, ui.label({ text = "Tab source", fontSize = 10, color = stripeTextColor }))
          table.insert(hintLabels, ui.label({ text = "•", fontSize = 10, color = stripeBulletColor }))
          table.insert(hintLabels, ui.label({ text = "Esc close", fontSize = 10, color = stripeTextColor }))

          return ui.row({
            align = "center",
            justify = "center",
            width = panelW - 64,
            gap = (panelW < 1360) and 6 or 10,
            height = 24,
            paddingH = 14,
            fill = stripeFill,
            border = stripeBorder,
            borderWidth = 1,
            radius = R(12),
          }, hintLabels)
        end)() or ui.spacer({ width = 1, height = 1 }),
      }),

      -- Middle & Bottom: Scanning State, Empty State, or Arched Deck
      (#displayedItems == 0) and (
        (currentMode ~= "wallhaven" and currentMode ~= "favorites" and isScanning)
          and renderScanningState(paletteColors)
          or (currentMode == "wallhaven" and wallhavenLoading and not wallhavenError)
            and renderWallhavenLoadingState(paletteColors)
          or renderEmptyState(paletteColors)
      ) or ui.column({
        key = "deck_content_column",
        width = panelW,
        flexGrow = 1,
        padding = 0,
        gap = 0,
        align = "stretch",
        justify = "space_between",
      }, {
        ui.spacer({ flexGrow = 1 }),

        -- Bottom Section: Action Bar + Arched Deck docked cleanly together
        ui.column({
          key = "deck_bottom_section",
          width = panelW,
          fill = "#00000000",
          align = "center",
          justify = "end",
          gap = 10,
          onHover = "onDeckHover",
          onClick = function()
            if isSearchFocused then
              isSearchFocused = false
              render()
            end
          end,
        }, {
          -- Monitor Selection Dropdown Popover (floating directly above the action buttons)
          (activeItem and monitorDropdownOpen) and ui.row({
            key = "monitor_dropdown_popover",
            align = "center",
            justify = "center",
            fill = paletteColors.isLight and "surface/0.95" or "surface/0.92",
            border = "primary/0.4",
            borderWidth = 1,
            radius = R(14),
            paddingH = 6,
            paddingV = 4,
            gap = 4,
            onHover = "onDeckHover",
          }, (function()
            local rows = {}
            for idx, outName in ipairs(connectedOutputs) do
              local isSel = (outName == selectedOutput)
              table.insert(rows, ui.button({
                text = outName,
                glyph = isSel and "check" or (outName == "ALL" and "devices" or "screen-share"),
                variant = isSel and "primary" or "ghost",
                controlSize = "sm",
                onClick = function()
                  selectedOutputIdx = idx
                  selectedOutput = outName
                  monitorDropdownOpen = false
                  render()
                end,
              }))
            end
            return rows
          end)()) or ui.spacer({ width = 1, height = 1 }),

          -- Floating Action Buttons directly above Center Card
          activeItem and ui.row({
            key = "deck_action_bar",
            align = "center",
            justify = "center",
            gap = 8,
            height = 36,
            onHover = "onDeckHover",
          }, {
            ui.button({
              glyph = isFav and "heart-filled" or "heart",
              variant = isFav and "primary" or "secondary",
              controlSize = "sm",
              tooltip = "Toggle Favourite (F)",
              onClick = toggleCurrentFavorite,
            }),

            ui.row({
              align = "center",
              gap = 2,
            }, {
              ui.button({
                text = isCurrent and ("On " .. selectedOutput) or ("Apply to " .. selectedOutput),
                glyph = isCurrent and "check" or "screen-share",
                variant = isCurrent and "secondary" or "primary",
                controlSize = "sm",
                tooltip = "Apply wallpaper (Enter) • Right-click to choose monitor (M)",
                onClick = applyCurrent,
                onRightClick = function()
                  refreshConnectedOutputs()
                  monitorDropdownOpen = not monitorDropdownOpen
                  render()
                end,
              }),
              ui.button({
                glyph = monitorDropdownOpen and "chevron-up" or "chevron-down",
                variant = monitorDropdownOpen and "primary" or (isCurrent and "secondary" or "primary"),
                controlSize = "sm",
                tooltip = "Change Target Monitor (M)",
                onClick = function()
                  refreshConnectedOutputs()
                  monitorDropdownOpen = not monitorDropdownOpen
                  render()
                end,
              }),
            }),
          }) or ui.spacer({ width = 1, height = 1 }),

          -- Bottom: Arched Coverflow Card Deck Row
          ui.row({
            key = "deck_cards_row",
            width = panelW,
            align = "end",
            justify = "start",
            gap = gap,
            height = maxDeckH,
            paddingV = 0,
            borderWidth = 0,
            radius = 0,
            fill = "#00000000",
            onHover = "onDeckHover",
            onClick = function()
              if isSearchFocused then
                isSearchFocused = false
                render()
              end
            end,
          }, deckCards),
          ui.spacer({ height = 12 }),
        }),
      }),
    }),
  }))
end

function onOpen(context: any?)
  isPickerOpen = true
  isDeckAreaHovered = true
  hoveredDeckKeys = {}
  noctalia.state.set("deck_command", { action = "panel_state", open = true })
  updatePanelGeometry()
  updateCornerRadiusScale()
  animateSelected = noctalia.getConfig("animate_selected_card") ~= false
  local cfgFit = noctalia.getConfig("preview_fit")
  if cfgFit == "cover" or cfgFit == "contain" or cfgFit == "stretch" then
    previewFit = cfgFit
  end
  displayedBgPath = ""
  prevBgPath = ""
  bgTransitionProgress = 1.0
  cachedFavCount = -1
  cachedRibbon = nil
  startWheelListener()

  local savedSort = noctalia.state.get("wallhaven_sort") or noctalia.getConfig("wallhaven_sorting") or "date_added"
  whSortIdx = getSortIndexFromValue(savedSort)
  local savedOrder = noctalia.state.get("wallhaven_order") or noctalia.getConfig("wallhaven_order") or "desc"
  whOrder = (savedOrder == "asc") and "asc" or "desc"

  if context == "wallhaven" then
    currentMode = "wallhaven"
    if #((wallhavenData and wallhavenData.items) or {}) == 0 then
      doWallhavenSearch(true)
    end
  else
    currentMode = "local"
  end
  isSearchFocused = false
  isPeeking = false
  monitorDropdownOpen = false
  searchQuery = ""
  wallhavenLoadingMore = false
  wallhavenLoadingStartMs = 0

  local stateWallhaven = noctalia.state.get("wallhaven_results")
  if type(stateWallhaven) == "table" then
    wallhavenData = stateWallhaven
  end

  refreshConnectedOutputs()
  if not communityPalettes or #communityPalettes == 0 then
    communityPalettes = loadCommunityPalettes()
  end
  updateThemeFromSystem()

  if #allWallpapers == 0 then
    local stateWps = noctalia.state.get("wallpapers")
    if type(stateWps) == "table" and #stateWps > 0 then
      allWallpapers = stateWps
    else
      noctalia.state.set("deck_command", { action = "rescan", dir = currentWallDir, nonce = noctalia.nowMs() })
    end
  end

  favorites = noctalia.state.get("favorites") or favorites or {}
  local stateActive = noctalia.state.get("active_wallpaper") or noctalia.state.get("current_wallpaper") or ""
  if stateActive ~= "" and not string.find(stateActive, "_screen%.webp") and not string.find(stateActive, "_card%.webp") then
    activeWallpaper = stateActive
    initialWallpaper = stateActive
  elseif initialWallpaper == "" then
    initialWallpaper = activeWallpaper
  end
  rebuildList()

  if activeWallpaper ~= "" then
    for i, it in ipairs(displayedItems) do
      if it.path == activeWallpaper then
        selectedIdx = i
        break
      end
    end
  end

  animatedPos = selectedIdx
  animTargetPos = selectedIdx
  animVel = 0.0
  lastFrameMs = 0
  lastPreviewed = ""
  triggerPreview()
  panel.setNeedsFrameTick(false)
  onCardSettled()
  render()
end

function onFrameTick(deltaMs: any)
  local ok, err = pcall(function()
    local numDelta = tonumber(deltaMs)
    local nowMs = noctalia.nowMs()
    local dt = 0.016
    if lastFrameMs > 0 then
      local elapsed = (nowMs - lastFrameMs) / 1000.0
      if elapsed > 0.0005 and elapsed < 0.1 then
        dt = elapsed
      end
    elseif numDelta and numDelta > 0 then
      dt = clamp(numDelta / 1000.0, 0.001, 0.05)
    end
    lastFrameMs = nowMs

    local isSpringActive = false
    if not animateSelected then
      animatedPos = selectedIdx
      animTargetPos = selectedIdx
      animVel = 0.0
    else
      local diff = animatedPos - animTargetPos
      if math.abs(diff) < 0.002 and math.abs(animVel) < 0.05 then
        local wasMoving = (animatedPos ~= animTargetPos or animVel ~= 0.0)
        animatedPos = animTargetPos
        animVel = 0.0
        if wasMoving then
          onCardSettled()
        end
      else
        isSpringActive = true
        local omega = 26.0
        local c = (animVel + omega * diff) * dt
        local e = math.exp(-omega * dt)
        animatedPos = animTargetPos + (diff + c) * e
        animVel = (animVel - omega * c) * e
      end
    end

    local isBgActive = false
    if bgTransitionProgress < 1.0 then
      local step = (dt > 0 and dt or 0.016) / BG_TRANSITION_DURATION
      bgTransitionProgress = math.min(1.0, bgTransitionProgress + step)
      if bgTransitionProgress < 1.0 then
        isBgActive = true
      else
        prevBgPath = ""
      end
    end

    panel.setNeedsFrameTick(isSpringActive or isBgActive)
    render()
  end)

  if not ok then
    if type(noctalia.log) == "function" then
      noctalia.log("[wallpaper-deck] onFrameTick error: " .. tostring(err))
    end
    panel.setNeedsFrameTick(false)
  end
end

function onKey(chord: string, pressed: boolean)
  if not pressed then return end

  local chordLower = string.lower(chord)
  local isReturn = (chordLower == "return" or chordLower == "enter" or chordLower == "kp_enter")

  if isReturn then
    if isSearchFocused then
      isSearchFocused = false
      executeSearch()
      render()
      return
    else
      applyCurrent()
      return
    end
  end

  if chordLower == "escape" then
    if monitorDropdownOpen then
      monitorDropdownOpen = false
      render()
    elseif isPeeking then
      isPeeking = false
      render()
    elseif isSearchFocused then
      isSearchFocused = false
      render()
    else
      cancelAndClose()
    end
    return
  end

  if chordLower == "left" or chordLower == "h" then
    isSearchFocused = false
    if selectedIdx > 1 then
      selectCardIndex(selectedIdx - 1)
    end
  elseif chordLower == "right" or chordLower == "l" then
    isSearchFocused = false
    if selectedIdx < #displayedItems then
      selectCardIndex(selectedIdx + 1)
    else
      pendingStepAfterAppend = true
      checkWallhavenLazyLoad()
    end
  elseif chordLower == "up" or chordLower == "k" or chordLower == "u" then
    isSearchFocused = false
    local newIdx = math.max(1, selectedIdx - 5)
    if newIdx ~= selectedIdx then
      selectCardIndex(newIdx)
    end
  elseif chordLower == "down" or chordLower == "j" or chordLower == "d" then
    if isSearchFocused then
      isSearchFocused = false
      render()
      return
    end
    local newIdx = math.min(#displayedItems, selectedIdx + 5)
    if newIdx ~= selectedIdx then
      selectCardIndex(newIdx)
    else
      pendingStepAfterAppend = true
      checkWallhavenLazyLoad()
    end
  elseif chordLower == "f" then
    toggleCurrentFavorite()
  elseif chordLower == "s" then
    cycleSort()
  elseif chordLower == "tab" then
    cycleMode()
  elseif chordLower == "r" then
    pickRandom()
  elseif chordLower == "v" then
    cyclePreviewFit()
  elseif chordLower == "space" then
    isPeeking = not isPeeking
    render()
  elseif chordLower == "p" then
    if currentMode == "wallhaven" then
      hiResPreview = not hiResPreview
      if not hiResPreview then
        hiResQueue = {}
      else
        displayedBgPath = ""
        prevBgPath = ""
        bgTransitionProgress = 1.0
        onCardSettled()
      end
      triggerPreview()
      render()
    else
      isPeeking = not isPeeking
      render()
    end
  elseif chordLower == "m" then
    refreshConnectedOutputs()
    monitorDropdownOpen = not monitorDropdownOpen
    render()
  elseif chordLower == "/" or chordLower == "slash" then
    isSearchFocused = not isSearchFocused
    render()
  elseif chordLower == "pointer_button4" or chordLower == "pointer_dfltbtnprev" then
    isSearchFocused = false
    if selectedIdx > 1 then
      selectCardIndex(selectedIdx - 1)
    end
  elseif chordLower == "pointer_button5" or chordLower == "pointer_dfltbtnnext" then
    isSearchFocused = false
    if selectedIdx < #displayedItems then
      selectCardIndex(selectedIdx + 1)
    else
      pendingStepAfterAppend = true
      checkWallhavenLazyLoad()
    end
  elseif chordLower == "page_up" or chordLower == "prior" then
    local newIdx = math.max(1, selectedIdx - 5)
    if newIdx ~= selectedIdx then
      selectCardIndex(newIdx)
    end
  elseif chordLower == "page_down" or chordLower == "next" then
    local newIdx = math.min(#displayedItems, selectedIdx + 5)
    if newIdx ~= selectedIdx then
      selectCardIndex(newIdx)
    else
      pendingStepAfterAppend = true
      checkWallhavenLazyLoad()
    end
  end
end

local lastScrollMs = 0

function onScroll(_axis: any, steps: any, _startsGesture: any)
  if not isPickerOpen or #displayedItems == 0 then return end
  isSearchFocused = false
  local nowMs = noctalia.nowMs()
  if nowMs - lastScrollMs < 35 then return end
  lastScrollMs = nowMs

  local stepVal = tonumber(steps) or 0
  if stepVal < 0 then
    if selectedIdx < #displayedItems then
      selectCardIndex(selectedIdx + 1)
    else
      pendingStepAfterAppend = true
      checkWallhavenLazyLoad()
    end
  elseif stepVal > 0 then
    if selectedIdx > 1 then
      selectCardIndex(selectedIdx - 1)
    end
  end
end

function onIpc(event: string, _payload: string?)
  if event == "prev" or event == "step_left" or event == "left" then
    if not isPickerOpen then return end
    isSearchFocused = false
    if selectedIdx > 1 then
      selectCardIndex(selectedIdx - 1)
    end
  elseif event == "next" or event == "step_right" or event == "right" then
    if not isPickerOpen then return end
    isSearchFocused = false
    if selectedIdx < #displayedItems then
      selectCardIndex(selectedIdx + 1)
    else
      pendingStepAfterAppend = true
      checkWallhavenLazyLoad()
    end
  elseif event == "toggle_monitor" or event == "monitor" then
    refreshConnectedOutputs()
    monitorDropdownOpen = not monitorDropdownOpen
    render()
  elseif event == "sort" or event == "cycle_sort" then
    cycleSort()
  elseif event == "sort_name" then
    changeSort((currentSort == "name_asc" or currentSort == "name") and "name_desc" or "name_asc")
  elseif event == "sort_newest" then
    changeSort((currentSort == "newest") and "oldest" or "newest")
  elseif event == "sort_colour" then
    changeSort("colour")
  elseif event == "toggle_hires" or event == "hires" then
    if currentMode == "wallhaven" then
      hiResPreview = not hiResPreview
      if not hiResPreview then
        hiResQueue = {}
      else
        displayedBgPath = ""
        prevBgPath = ""
        bgTransitionProgress = 1.0
        onCardSettled()
      end
      triggerPreview()
      render()
    end
  elseif event == "cycle_mode" or event == "mode" or event == "tab" then
    cycleMode()
  elseif event == "mode_wallhaven" or event == "wallhaven" then
    currentMode = "wallhaven"
    selectedIdx = 1
    resetDeckAnimation(1.0)
    if #((wallhavenData and wallhavenData.items) or {}) == 0 then
      doWallhavenSearch(true)
    end
    rebuildList()
    triggerPreview()
    onCardSettled()
    render()
  elseif event == "mode_local" or event == "local" then
    currentMode = "local"
    selectedIdx = 1
    resetDeckAnimation(1.0)
    rebuildList()
    triggerPreview()
    render()
  end
end

noctalia.state.watch("wallpapers", function(val)
  if type(val) == "table" then
    allWallpapers = val
    invalidateSortCache()
    cachedFavCount = -1
    cachedRibbon = nil
    if not isPickerOpen then return end
    local currentItem = displayedItems and displayedItems[selectedIdx] or nil
    local currentPath = currentItem and (currentItem.path or currentItem.id) or activeWallpaper
    rebuildList()
    if currentPath and currentPath ~= "" and #displayedItems > 0 then
      local found = false
      for idx, it in ipairs(displayedItems) do
        if (it.path or it.id) == currentPath then
          selectedIdx = idx
          found = true
          break
        end
      end
      if not found then
        selectedIdx = clamp(selectedIdx, 1, #displayedItems)
      end
    else
      selectedIdx = 1
    end
    -- Keep spring target and position synchronized when wallpaper list updates
    animatedPos = selectedIdx
    animTargetPos = selectedIdx
    animVel = 0.0
    triggerPreview()
    render()
  end
end)

noctalia.state.watch("wallpapers_newest", function(val)
  if type(val) == "table" and #val > 0 then
    allWallpapersNewest = val
    if isPickerOpen and currentMode == "local" and (currentSort == "newest" or currentSort == "oldest") and searchQuery == "" then
      rebuildList()
      resetDeckAnimation(selectedIdx)
      render()
    end
  end
end)

noctalia.state.watch("wallpapers_colour", function(val)
  if type(val) == "table" and #val > 0 then
    allWallpapersColour = val
    if isPickerOpen and currentMode == "local" and currentSort == "colour" and searchQuery == "" then
      rebuildList()
      resetDeckAnimation(selectedIdx)
      render()
    end
  end
end)

noctalia.state.watch("palette_update", function(update)
  if type(update) == "table" and update.path and update.colors then
    local changed = false
    paletteCache[update.path] = nil
    if displayedItems then
      for _, it in ipairs(displayedItems) do
        if it.path == update.path then
          it.colors = update.colors
          it.sourceColor = update.sourceColor
          it.hueKey = update.hueKey
          it._chipRows = nil
          it._chipStrip = nil
          it._renderedColors = nil
          changed = true
          break
        end
      end
    end
    if allWallpapers then
      for _, it in ipairs(allWallpapers) do
        if it.path == update.path then
          it.colors = update.colors
          it.sourceColor = update.sourceColor
          it.hueKey = update.hueKey
          it._chipRows = nil
          it._chipStrip = nil
          it._renderedColors = nil
          break
        end
      end
    end
    if changed then
      cachedRibbon = nil
      if isPickerOpen then
        render()
      end
    end
  end
end)

noctalia.state.watch("thumb_update", function(update)
  if type(update) == "table" and update.path and update.thumb then
    local changed = false
    if displayedItems then
      for _, it in ipairs(displayedItems) do
        if it.path == update.path then
          it.thumb = update.thumb
          it.preview = update.thumb
          it._previewPath = update.thumb
          changed = true
          break
        end
      end
    end
    if allWallpapers then
      for _, it in ipairs(allWallpapers) do
        if it.path == update.path then
          it.thumb = update.thumb
          it.preview = update.thumb
          it._previewPath = update.thumb
          break
        end
      end
    end
    if changed and isPickerOpen then
      render()
    end
  end
end)

noctalia.state.watch("outputs_changed", function(_val)
  refreshConnectedOutputs()
  updatePanelGeometry()
  if isPickerOpen then
    render()
  end
end)

noctalia.state.watch("favorites", function(val)
  if type(val) == "table" then
    favorites = val
    cachedFavCount = -1
    if isPickerOpen then
      rebuildList()
      render()
    end
  end
end)

noctalia.state.watch("active_wallpaper", function(val)
  if type(val) == "string" then
    activeWallpaper = val
    if isPickerOpen then
      render()
    end
  end
end)

noctalia.state.watch("wallhaven_loading", function(val)
  wallhavenLoading = (val == true)
  if not wallhavenLoading then
    wallhavenLoadingMore = false
  end
  if isPickerOpen then
    render()
  end
end)

noctalia.state.watch("wallhaven_error", function(val)
  wallhavenError = val
  if val ~= nil then
    wallhavenLoading = false
    wallhavenLoadingMore = false
  end
  if isPickerOpen then
    render()
  end
end)

noctalia.state.watch("wallhaven_results", function(value)
  if type(value) ~= "table" then return end
  local wasAppend = value.isAppend == true
  local prevIdx = selectedIdx

  wallhavenData = value
  wallhavenLoading = false
  wallhavenLoadingMore = false
  if value.items and #value.items > 0 then
    wallhavenError = nil
  end

  if currentMode == "wallhaven" then
    rebuildList()
    if wasAppend then
      if pendingStepAfterAppend and #displayedItems > prevIdx then
        pendingStepAfterAppend = false
        selectCardIndex(prevIdx + 1)
      else
        selectedIdx = prevIdx
        scheduleSettle()
      end
      local batchToPreload = value.newBatch or {}
      for i = 1, math.min(#batchToPreload, 6) do
        local it = batchToPreload[i]
        if it then
          requestWallhavenThumb(it, false)
        end
      end
    else
      selectedIdx = 1
      resetDeckAnimation(1.0)
      triggerPreview()
      onCardSettled()
    end
    if #displayedItems > 0 then
      local halfWindow = math.floor((visibleCards or 7) / 2)
      for offset = -halfWindow, halfWindow do
        local it = displayedItems[selectedIdx + offset]
        if it then
          requestWallhavenThumb(it, offset == 0)
        end
      end
    end
    if isPickerOpen then
      render()
    end
  end
end)

noctalia.state.watch("wallpaper_dir", function(val)
  if type(val) == "string" and val ~= "" and val ~= currentWallDir then
    currentWallDir = val
    updateRootWpDir(val)
    selectedIdx = 1
    resetDeckAnimation(1.0)
    rebuildList()
    if isPickerOpen then
      render()
    end
  end
end)

noctalia.state.watch("is_scanning", function(val)
  isScanning = (val == true)
  if isPickerOpen then
    render()
  end
end)

function onConfigChanged()
  updatePanelGeometry()
  updateCornerRadiusScale()
  animateSelected = noctalia.getConfig("animate_selected_card") ~= false
  local cfgFit = noctalia.getConfig("preview_fit")
  if cfgFit == "cover" or cfgFit == "contain" or cfgFit == "stretch" then
    previewFit = cfgFit
  end
  local cfgDir = noctalia.getConfig("wallpaper_dir")
  if cfgDir and cfgDir ~= "" then
    local exp = noctalia.expandPath(cfgDir)
    currentWallDir = exp
    updateRootWpDir(exp)
  end
  local cfgScanSub = noctalia.getConfig("scan_subdirectories")
  if cfgScanSub ~= nil then
    isFlattened = (cfgScanSub == true or cfgScanSub == "true" or cfgScanSub == 1)
  end
  selectedIdx = 1
  resetDeckAnimation(1.0)
  rebuildList()
  if isPickerOpen then
    render()
  end
  noctalia.state.set("deck_command", { action = "rescan", nonce = noctalia.nowMs() })
end

function onClose()
  isPickerOpen = false
  isDeckAreaHovered = false
  hoveredDeckKeys = {}
  stopWheelListener()
  if isPeeking then
    isPeeking = false
  end
  noctalia.state.set("deck_command", { action = "panel_state", open = false })
  noctalia.state.set("deck_command", { action = "prune_cache", nonce = noctalia.nowMs() })
end

function onExit(_signal: any, _reason: any)
  stopWheelListener()
end
