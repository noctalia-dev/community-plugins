--!nonstrict
-- MTG Card-Deck Wallpaper Picker for Noctalia v5.
-- Fullscreen transparent overlay replicating qs-wallpaperpicker:
-- Live fullscreen wallpaper preview, arched coverflow card deck, spectrum ribbon,
-- 5 Material 3 color chips, floating action buttons above center card, and peek mode.

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

local stateWps = noctalia.state.get("wallpapers")
local allWallpapers = (type(stateWps) == "table" and #stateWps > 0) and stateWps or loadCacheDirect()
local favorites = noctalia.state.get("favorites") or {}
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

local WHEEL_PID_FILE = STATE_DIR .. "/wheel_listener.pid"

local function stopWheelListener()
  pcall(function()
    if noctalia.fileExists(WHEEL_PID_FILE) then
      local pid = noctalia.readFile(WHEEL_PID_FILE)
      if pid and pid ~= "" then
        local trimmed = string.gsub(pid, "%s+", "")
        if tonumber(trimmed) then
          local cmdline = noctalia.readFile("/proc/" .. trimmed .. "/cmdline")
          if cmdline and string.find(cmdline, "wallpaper_helper.py", 1, true) and string.find(cmdline, "wheel", 1, true) then
            noctalia.runAsync({ "kill", "-15", trimmed }, function() end)
          end
        end
      end
      if type(noctalia.removeFile) == "function" then
        pcall(noctalia.removeFile, WHEEL_PID_FILE)
      else
        noctalia.runAsync({ "rm", "-f", WHEEL_PID_FILE }, function() end)
      end
    end
  end)
end

local function startWheelListener()
  pcall(function()
    stopWheelListener()
    local cmd = string.format("python3 '%s' wheel '%s' &", HELPER_SCRIPT, WHEEL_PID_FILE)
    noctalia.runAsync(cmd)
  end)
end

local displayedBgPath = ""
local cachedFavCount = -1
local function getFavCount(): number
  if cachedFavCount >= 0 then
    return cachedFavCount
  end
  local count = 0
  for _, it in ipairs(allWallpapers) do
    if favorites[it.name] then count = count + 1 end
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
local render -- forward declaration
local toggleCurrentFavorite -- forward declaration

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
        -- Remove corrupt/partial file if it exists but is invalid
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
  -- Remove 0-byte/corrupt cached file so re-download is triggered
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
local HIRES_MAX_CONCURRENT = 1

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
      else
        -- Remove corrupt/partial file if it exists but is invalid
        if noctalia.fileExists(dest) then
          pcall(noctalia.removeFile, dest)
        end
        local permanentDirs = {
          noctalia.expandPath("~/Pictures/Wallpapers/WallHaven"),
          noctalia.expandPath("~/Pictures/Wallpapers"),
          noctalia.expandPath("~/Pictures/wallpapers/WallHaven"),
          noctalia.expandPath("~/Pictures/wallpapers"),
        }
        local alreadySaved = false
        for _, pdir in ipairs(permanentDirs) do
          local pf = pdir .. "/wallhaven-" .. id .. "." .. ext
          if isValidFile(pf) then
            item.hiResPath = pf
            alreadySaved = true
            break
          end
        end

        if not alreadySaved and item.fullUrl and item.fullUrl ~= "" then
          hiResPending[id] = true
          hiResActive = hiResActive + 1

          local started = false
          if type(noctalia.download) == "function" then
            started = noctalia.download(item.fullUrl, dest, function(ok)
              hiResActive = math.max(0, hiResActive - 1)
              hiResPending[id] = nil
              if ok and isValidFile(dest) then
                item.hiResPath = dest
              else
                pcall(noctalia.removeFile, dest)
              end
              local active = displayedItems[selectedIdx]
              if active and active.id == id and hiResPreview then
                if type(render) == "function" then render() end
              end
              pumpHiResQueue()
            end)
          end

          if not started then
            noctalia.runAsync({ "curl", "-sL", "-o", dest, item.fullUrl }, function(res)
              hiResActive = math.max(0, hiResActive - 1)
              hiResPending[id] = nil
              if res and res.exitCode == 0 and isValidFile(dest) then
                item.hiResPath = dest
              else
                pcall(noctalia.removeFile, dest)
              end
              local active = displayedItems[selectedIdx]
              if active and active.id == id and hiResPreview then
                if type(render) == "function" then render() end
              end
              pumpHiResQueue()
            end)
          end
        end
      end
    end
  end
end

local function requestWallhavenHiRes(item: any, priority: boolean?): string?
  if not item or not item.id or not item.fullUrl then return nil end
  if item.hiResPath and item._hiResValid then
    return item.hiResPath
  end
  if item.hiResPath and isValidFile(item.hiResPath) then
    item._hiResValid = true
    return item.hiResPath
  end
  local urlExt = string.match(item.fullUrl, "%.([^%.]+)$") or item.ext or "jpg"
  local ext = string.lower(urlExt)
  if ext == "jpeg" then ext = "jpg" end

  -- Check if already saved in permanent wallpapers
  local permanentDirs = {
    noctalia.expandPath("~/Pictures/Wallpapers/WallHaven"),
    noctalia.expandPath("~/Pictures/Wallpapers"),
    noctalia.expandPath("~/Pictures/wallpapers/WallHaven"),
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

  local dest = WALLHAVEN_PREVIEW_DIR .. "/" .. item.id .. "." .. ext
  if isValidFile(dest) then
    item.hiResPath = dest
    item._hiResValid = true
    return dest
  end
  -- Remove 0-byte/corrupt cached file so re-download is triggered
  if noctalia.fileExists(dest) then
    pcall(noctalia.removeFile, dest)
  end

  if not hiResPending[item.id] then
    local inQueueIdx = nil
    for i, it in ipairs(hiResQueue) do
      if it.id == item.id then
        inQueueIdx = i
        break
      end
    end

    local isPriority = (priority == true) or (priority == nil and displayedItems[selectedIdx] and displayedItems[selectedIdx].id == item.id)
    if isPriority then
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

local currentMode = "local" -- "local" | "favorites" | "wallhaven"
local currentSort = "name"  -- "name" | "colour" | "newest"
local searchQuery = ""
local searchActive = false
local isPeeking = false
local isFlattened = false

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

local function getCornerRadiusScale(): number
  if type(noctalia.getSetting) == "function" then
    local pcallOk, scale = pcall(noctalia.getSetting, "shell.corner_radius_scale")
    if pcallOk and type(scale) == "number" then
      return scale
    end
    local pcallOk2, scale2 = pcall(noctalia.getSetting, "corner_radius_scale")
    if pcallOk2 and type(scale2) == "number" then
      return scale2
    end
  end
  return 1.0
end

local function R(baseRadius: number): number
  if not baseRadius or baseRadius <= 0 then return 0 end
  local scale = getCornerRadiusScale()
  if scale <= 0 then return 0 end
  return math.floor(baseRadius * scale + 0.5)
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
      local dec = noctalia.json.decode(raw)
      if type(dec) == "table" then
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
local lastPreviewed = ""

local animateSelected = noctalia.getConfig("animate_selected_card") ~= false
local visibleCards = noctalia.getConfig("visible_deck_cards") or 7

local function lerp(a: number, b: number, t: number): number
  return a + (b - a) * t
end

local function clamp(val: number, minVal: number, maxVal: number): number
  if val < minVal then return minVal end
  if val > maxVal then return maxVal end
  return val
end

local function getScreenGeometry()
  local w = 1920
  local h = 1080
  local focusedName = type(noctalia.focusedOutputName) == "function" and noctalia.focusedOutputName()
  if type(noctalia.outputs) == "function" then
    for _, out in ipairs(noctalia.outputs()) do
      if out.name == focusedName or out.focused then
        w = math.floor(out.width / math.max(out.scale or 1, 1))
        h = math.floor(out.height / math.max(out.scale or 1, 1))
        break
      end
    end
  end
  return w, h
end

local function getPanelGeometry(): (number, number)
  local screenW, screenH = getScreenGeometry()
  local barThicknessLeft = 0
  local barThicknessRight = 0
  local barThicknessTop = 0
  local barThicknessBottom = 0

  if type(noctalia.getSetting) == "function" then
    local pcallOk, bars = pcall(noctalia.getSetting, "bar")
    if pcallOk and type(bars) == "table" then
      for k, bar in pairs(bars) do
        if k ~= "order" and type(bar) == "table" and type(bar.position) == "string" and bar.enabled ~= false and not bar.auto_hide and bar.reserve_space ~= false then
          local pos = bar.position
          local th = tonumber(bar.thickness) or 34
          if pos == "left" then
            barThicknessLeft = math.max(barThicknessLeft, th)
          elseif pos == "right" then
            barThicknessRight = math.max(barThicknessRight, th)
          elseif pos == "top" then
            barThicknessTop = math.max(barThicknessTop, th)
          elseif pos == "bottom" then
            barThicknessBottom = math.max(barThicknessBottom, th)
          end
        end
      end
    end
  end

  -- Noctalia shell constants:
  -- Style::spaceSm = 8 (screen padding for detached floating panel on each side)
  -- Style::panelPadding = 14 (content padding inside decorated panel on each side)
  -- Total padding per axis = (8 + 14) * 2 = 44px
  local totalPadH = (8 + 14) * 2
  local totalPadV = (8 + 14) * 2

  local w = math.max(800, screenW - barThicknessLeft - barThicknessRight - totalPadH)
  local h = math.max(600, screenH - barThicknessTop - barThicknessBottom - totalPadV)
  return w, h
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
  local isLight = bgLum > 0.35

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

  -- Decide whether dark or light ink provides higher contrast against the background
  local useDarkInk = bgLum > 0.28
  if #scored > 0 then
    useDarkInk = scored[1].lum < bgLum
  end

  -- Filter palette candidates that are on the high-contrast side
  local sideCandidates = {}
  for _, c in ipairs(scored) do
    if (useDarkInk and c.lum < bgLum) or (not useDarkInk and c.lum > bgLum) then
      table.insert(sideCandidates, c)
    end
  end

  local primaryText = useDarkInk and "#111418" or "#ffffff"
  local accentColor = useDarkInk and "#004c3f" or "#80a9ff"
  local mutedText = useDarkInk and "#2c312e" or "#c5c7d0"

  if #sideCandidates > 0 then
    primaryText = sideCandidates[1].hex
    if sideCandidates[1].contrast < 3.8 then
      primaryText = useDarkInk and "#111418" or "#ffffff"
    end

    -- Look for a chromatic accent on the same contrast side
    for _, c in ipairs(sideCandidates) do
      if (c.key == "primary_container" or c.key == "primary" or c.key == "tertiary" or c.key == "secondary") and c.contrast >= 2.0 then
        accentColor = c.hex
        break
      end
    end
    if not accentColor then
      accentColor = primaryText
    end

    -- Look for secondary/muted text on the same contrast side
    if #sideCandidates >= 2 and sideCandidates[2].contrast >= 2.0 then
      mutedText = sideCandidates[2].hex
    else
      mutedText = primaryText
    end
  else
    primaryText = useDarkInk and "#111418" or "#ffffff"
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

local function baseName(name: string): string
  local dot = string.find(name, "%.[^%.]+$")
  if dot and dot > 1 then
    return string.sub(name, 1, dot - 1)
  end
  return name
end

local rootWpDir = (currentWallDir ~= "" and noctalia.expandPath(currentWallDir))
  or (noctalia.getConfig("wallpaper_dir") and noctalia.expandPath(noctalia.getConfig("wallpaper_dir")))
  or noctalia.expandPath("~/Pictures/Wallpapers")
local rootWpDirLen = #rootWpDir

local function updateRootWpDir(newDir: string)
  if newDir and newDir ~= "" then
    rootWpDir = noctalia.expandPath(newDir)
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
  noctalia.runAsync({ "noctalia", "msg", "settings-open-plugin", "ishan0121/wallpaper-deck" }, function() end)
  panel.close()
end

local function updateThemeFromSystem()
  noctalia.runAsync({ "noctalia", "msg", "theme-mode-get" }, function(res)
    if res and res.exitCode == 0 and res.stdout and res.stdout ~= "" then
      local mode = string.match(res.stdout, "[%w_-]+")
      if mode and mode ~= "" then
        currentThemeMode = mode
        render()
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
        else -- wallpaper
          for idx, s in ipairs(SCHEMES) do
            if s.id == scheme or string.lower(s.label) == string.lower(scheme) then
              selectedSchemeIdx = idx
              break
            end
          end
        end
      end
      render()
    end
  end)
end

local function refreshConnectedOutputs()
  connectedOutputs = { "ALL" }
  if type(noctalia.outputs) == "function" then
    for _, out in ipairs(noctalia.outputs()) do
      if out.name and out.name ~= "" then
        table.insert(connectedOutputs, out.name)
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

local function rebuildList()
  local src = {}
  if currentMode == "wallhaven" then
    src = wallhavenData.items or {}
  elseif currentMode == "favorites" then
    for _, item in ipairs(allWallpapers) do
      if favorites[item.name] then
        if isFlattened or not itemIsSubdir(item) then
          table.insert(src, item)
        end
      end
    end
  else
    for _, item in ipairs(allWallpapers) do
      if isFlattened or not itemIsSubdir(item) then
        table.insert(src, item)
      end
    end
  end

  if currentMode ~= "wallhaven" and searchQuery ~= "" then
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

  if currentMode ~= "wallhaven" and #src > 1 then
    if currentSort == "colour" then
      table.sort(src, function(a, b)
        local ka = a.hueKey or 3.0
        local kb = b.hueKey or 3.0
        if ka ~= kb then return ka < kb end
        return (a.lowerName or a.name or "") < (b.lowerName or b.name or "")
      end)
    elseif currentSort == "newest" then
      table.sort(src, function(a, b)
        local ma = a.mtime or 0
        local mb = b.mtime or 0
        if ma ~= mb then return ma > mb end
        return (a.lowerName or a.name or "") < (b.lowerName or b.name or "")
      end)
    else -- "name"
      table.sort(src, function(a, b)
        return (a.lowerName or a.name or "") < (b.lowerName or b.name or "")
      end)
    end
  end

  displayedItems = src
  cachedRibbon = nil
  selectedIdx = clamp(selectedIdx, 1, math.max(1, #displayedItems))
  if currentMode == "wallhaven" and #displayedItems > 0 then
    local halfWindow = math.floor((visibleCards or 7) / 2)
    for offset = -halfWindow, halfWindow do
      local it = displayedItems[selectedIdx + offset]
      if it then
        requestWallhavenThumb(it, offset == 0)
      end
    end
  end
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
  if resetPage then
    selectedIdx = 1
    animatedPos = 1.0
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

local function buildWallhavenRow2(paletteColors: any?)
  local pColors = paletteColors or {
    primaryText = "on_surface",
    accent = "primary",
    muted = "on_surface/0.7",
  }
  return ui.row({
    align = "center",
    justify = "space_between",
    height = 36,
  }, {
    ui.row({
      align = "center",
      gap = 12,
      flexGrow = 1,
    }, {
      -- 1. Categories
      ui.row({ align = "center", gap = 5 }, {
        ui.label({ text = "Categories", fontSize = 11, fontWeight = "bold", color = pColors.muted }),
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
            text = "General",
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
            text = "People",
            variant = whCatPeople and "primary" or "ghost",
            controlSize = "sm",
            onClick = toggleCategoryPeople,
          }),
        }),
      }),

      -- 2. Purity
      ui.row({ align = "center", gap = 5 }, {
        ui.label({ text = "Purity", fontSize = 11, fontWeight = "bold", color = pColors.muted }),
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
            text = "Sketchy",
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
      ui.row({ align = "center", gap = 5 }, {
        ui.label({ text = "Sort", fontSize = 11, fontWeight = "bold", color = pColors.muted }),
        ui.select({
          key = "wh_sort_select_" .. tostring(whSortIdx),
          options = WH_SORT_LABELS,
          selectedIndex = tonumber(whSortIdx) or 0,
          controlSize = "sm",
          width = 110,
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
      ui.row({ align = "center", gap = 5 }, {
        ui.label({ text = "Ratio", fontSize = 11, fontWeight = "bold", color = pColors.muted }),
        ui.select({
          key = "wh_ratio_select_" .. tostring(whRatioIdx),
          options = WH_RATIO_LABELS,
          selectedIndex = tonumber(whRatioIdx) or 0,
          controlSize = "sm",
          width = 95,
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
      ui.row({ align = "center", gap = 5 }, {
        ui.label({ text = "Res", fontSize = 11, fontWeight = "bold", color = pColors.muted }),
        ui.select({
          key = "wh_res_mode_select_" .. tostring(whResModeIdx),
          options = WH_RES_MODE_LABELS,
          selectedIndex = tonumber(whResModeIdx) or 0,
          controlSize = "sm",
          width = 90,
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
          placeholder = "Width",
          value = whResWidth,
          controlSize = "sm",
          width = 80,
          onChange = function(val)
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
          placeholder = "Height",
          value = whResHeight,
          controlSize = "sm",
          width = 80,
          onChange = function(val)
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
          text = "Clear",
          variant = "destructive",
          controlSize = "sm",
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
        text = "Dark",
        glyph = "moon",
        variant = currentThemeMode == "dark" and "primary" or "ghost",
        controlSize = "sm",
        onClick = function()
          currentThemeMode = "dark"
          noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "dark" }, function() end)
          render()
        end,
      }),
      ui.button({
        text = "Light",
        glyph = "sun",
        variant = currentThemeMode == "light" and "primary" or "ghost",
        controlSize = "sm",
        onClick = function()
          currentThemeMode = "light"
          noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "light" }, function() end)
          render()
        end,
      }),
      ui.button({
        text = "Auto",
        glyph = "brightness-auto",
        variant = currentThemeMode == "auto" and "primary" or "ghost",
        controlSize = "sm",
        onClick = function()
          currentThemeMode = "auto"
          noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "auto" }, function() end)
          render()
        end,
      }),
    }),
  })
end

local function buildStandardRow2()
  local activeItem = displayedItems[selectedIdx]
  return ui.row({
    align = "center",
    justify = "space_between",
    height = 36,
  }, {
    -- Left: Palette Source + Scheme Dropdown + Fav button
    ui.row({
      flexGrow = 1,
      align = "center",
      justify = "start",
      gap = 10,
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
        local selectWidth = 140

        if currentPaletteSource == "builtin" then
          currentOptions = BUILTIN_PALETTES
          currentSelectedIdx = math.max(0, (selectedBuiltinIdx or 1) - 1)
          selectWidth = 130
        elseif currentPaletteSource == "community" then
          currentOptions = communityPalettes
          currentSelectedIdx = math.max(0, (selectedCommunityIdx or 1) - 1)
          selectWidth = 170
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
            else -- wallpaper
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
        glyph = (activeItem and favorites[activeItem.name]) and "star-filled" or "star",
        variant = (activeItem and favorites[activeItem.name]) and "primary" or "ghost",
        controlSize = "sm",
        tooltip = (activeItem and favorites[activeItem.name]) and "Remove from Favourites (F)" or "Add to Favourites (F)",
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
          text = "Name",
          glyph = "sort-a-z",
          variant = currentSort == "name" and "secondary" or "ghost",
          controlSize = "sm",
          onClick = function()
            currentSort = "name"
            rebuildList()
            animatedPos = selectedIdx
            render()
          end,
        }),
        ui.button({
          text = "Colour",
          glyph = "palette",
          variant = currentSort == "colour" and "secondary" or "ghost",
          controlSize = "sm",
          onClick = function()
            currentSort = "colour"
            rebuildList()
            animatedPos = selectedIdx
            render()
          end,
        }),
        ui.button({
          text = "Newest",
          glyph = "clock",
          variant = currentSort == "newest" and "secondary" or "ghost",
          controlSize = "sm",
          onClick = function()
            currentSort = "newest"
            rebuildList()
            animatedPos = selectedIdx
            render()
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
          text = "Dark",
          glyph = "moon",
          variant = currentThemeMode == "dark" and "primary" or "ghost",
          controlSize = "sm",
          onClick = function()
            currentThemeMode = "dark"
            noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "dark" }, function() end)
            render()
          end,
        }),
        ui.button({
          text = "Light",
          glyph = "sun",
          variant = currentThemeMode == "light" and "primary" or "ghost",
          controlSize = "sm",
          onClick = function()
            currentThemeMode = "light"
            noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", "light" }, function() end)
            render()
          end,
        }),
        ui.button({
          text = "Auto",
          glyph = "brightness-auto",
          variant = currentThemeMode == "auto" and "primary" or "ghost",
          controlSize = "sm",
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

  -- Trigger next batch when viewing within the last 5 cards (e.g. index 20 of 24, 44 of 48, etc.)
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
      nonce = noctalia.nowMs()
    })
    if type(render) == "function" then
      render()
    end
  end
end

local function triggerPreview()
  local item = displayedItems[selectedIdx]
  if not item or not item.path then return end
  if currentMode == "wallhaven" then
    requestWallhavenThumb(item, true)
    if hiResPreview then
      requestWallhavenHiRes(item, true)
      for offset = 1, 2 do
        local nextItem = displayedItems[selectedIdx + offset]
        if nextItem then
          requestWallhavenHiRes(nextItem, false)
        end
      end
    end
    checkWallhavenLazyLoad()
    return
  end
  local pPath = item.preview or item.path
  if lastPreviewed ~= pPath then
    lastPreviewed = pPath
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
    if type(noctalia.setWallpaper) == "function" then
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

toggleCurrentFavorite = function()
  local item = displayedItems[selectedIdx]
  if not item then return end
  noctalia.state.set("deck_command", { action = "toggle_favorite", fileName = item.name, nonce = noctalia.nowMs() })
  if favorites[item.name] then
    favorites[item.name] = nil
  else
    favorites[item.name] = true
  end
  cachedFavCount = -1
  render()
end

local function cycleSort()
  if currentSort == "name" then
    currentSort = "colour"
  elseif currentSort == "colour" then
    currentSort = "newest"
  else
    currentSort = "name"
  end
  rebuildList()
  animatedPos = selectedIdx
  render()
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
  animatedPos = 1.0
  rebuildList()
  triggerPreview()
  render()
end

local function pickRandom()
  if #displayedItems > 0 then
    selectedIdx = math.random(1, #displayedItems)
    panel.setNeedsFrameTick(true)
    triggerPreview()
    render()
  end
end

-- Renders the full-screen width Spectrum Ribbon below the header
local cachedRibbon = nil
local cachedRibbonIdx = -1
local cachedRibbonCount = -1

local function renderSpectrumRibbon()
  local count = #displayedItems
  if count == 0 then
    return ui.box({ height = 6, fill = "surface_container/0.3", radius = R(3) })
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
        selectedIdx = itemIndex
        panel.setNeedsFrameTick(true)
        triggerPreview()
        render()
      end
    }))
  end

  local res = ui.row({
    align = "center",
    justify = "center",
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
local function renderCard(item: any, index: number, distSigned: number)
  local dist = math.abs(distSigned)
  local isCenter = dist < 0.45
  local t = math.min(dist / 3.0, 1.0)

  -- Stepping dimensions: Center card is prominent (224x344), outer cards step down (132x216)
  local cardW = math.floor(lerp(224, 132, t))
  local cardH = math.floor(lerp(344, 216, t))
  local imgH = math.floor(cardH * 0.42)

  -- True Parabolic Arch:
  -- Center card has 80px lift.
  -- Flanking cards curve gracefully downwards as distance increases (0px lift at dist >= 3).
  local lift = math.floor((1.0 - math.pow(t, 1.45)) * 80)
  local slotH = cardH + lift

  local isFav = favorites[item.name] == true
  local isCurrent = activeWallpaper == item.path

  local previewPath = nil
  if currentMode == "wallhaven" then
    previewPath = requestWallhavenThumb(item, isCenter)
  else
    if item._previewPath ~= nil then
      previewPath = (item._previewPath ~= "") and item._previewPath or nil
    else
      local p = item.thumb or item.path
      if p and p ~= "" and noctalia.fileExists(p) then
        item._previewPath = p
        previewPath = p
      else
        item._previewPath = ""
        previewPath = nil
      end
    end
  end

  local chipRows = isCenter and item._chipRowsCenter or item._chipRowsSide
  if not chipRows then
    local colors = item.colors or {}
    local pCol = colors.primary or "#80a9ff"
    local sCol = colors.secondary or "#bfc6dc"
    local tCol = colors.tertiary or "#dfbde4"
    local pcCol = colors.primary_container or "#20468a"
    local schCol = colors.surface_container_highest or "#33353b"

    local chips = {
      { label = "PRIMARY", col = pCol },
      { label = "SECONDARY", col = sCol },
      { label = "TERTIARY", col = tCol },
      { label = "CONTAINER", col = pcCol },
      { label = "SURFACE", col = schCol },
    }

    local rows = {}
    local chipH = isCenter and 16 or 11
    for _, c in ipairs(chips) do
      local textColor = inkOn(c.col)
      table.insert(rows, ui.row({
        align = "center",
        justify = "space_between",
        fill = c.col,
        radius = R(3),
        height = chipH,
        paddingH = isCenter and 6 or 3,
      }, {
        ui.label({
          text = c.label,
          fontSize = isCenter and 8 or 7,
          fontWeight = "bold",
          color = textColor,
        }),
        ui.label({
          text = string.upper(c.col),
          fontSize = isCenter and 8 or 7,
          fontFamily = "JetBrainsMono Nerd Font",
          color = textColor,
        }),
      }))
    end
    chipRows = rows
    if isCenter then
      item._chipRowsCenter = rows
    else
      item._chipRowsSide = rows
    end
  end

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
    detailLine = string.format("%s • %s%s", item.ext or "IMG", resText, item.sizeStr or formatBytes(item.size or 0))
    item._displayName = displayName
    item._detailLine = detailLine
  end

  return ui.column({
    key = "slot_" .. tostring(index),
    width = cardW,
    height = slotH,
    align = "center",
    justify = "start",
    opacity = lerp(1.0, 0.45, t),
    onClick = function()
      if selectedIdx == index then
        applyCurrent()
      else
        selectedIdx = index
        panel.setNeedsFrameTick(true)
        triggerPreview()
        render()
      end
    end,
  }, {
    -- Card Shell
    ui.column({
      width = cardW,
      height = cardH,
      fill = isCenter and "surface" or "surface_container/0.88",
      radius = isCenter and R(12) or R(8),
      border = isCenter and "primary" or "outline_variant/0.25",
      borderWidth = isCenter and 2 or 1,
      padding = isCenter and 8 or 5,
      gap = isCenter and 4 or 3,
    }, {
      -- Header row on card (✓ current badge and // name tag)
      ui.row({ align = "center", justify = "space_between", paddingH = 2, height = isCenter and 16 or 12 }, {
        isCurrent and ui.row({
          fill = "primary",
          radius = R(4),
          paddingH = 5,
          paddingV = 1,
        }, {
          ui.label({
            text = "✓ current",
            fontSize = isCenter and 9 or 7,
            fontWeight = "bold",
            color = "on_primary",
          }),
        }) or ui.spacer({ width = 1 }),
        ui.label({
          text = "// " .. ((item.relDir and item.relDir ~= "") and (item.relDir .. "/") or "") .. displayName,
          fontSize = isCenter and 9 or 7,
          fontFamily = "JetBrainsMono Nerd Font",
          color = isCenter and "primary" or "on_surface/0.5",
          maxWidth = cardW - 70,
          maxLines = 1,
        }),
      }),

      -- Artwork Window
      (previewPath and previewPath ~= "") and ui.image({
        key = "card_preview_" .. item.name .. "_" .. previewPath,
        path = previewPath,
        width = cardW - (isCenter and 16 or 10),
        height = imgH,
        radius = R(6),
        border = isCenter and "primary/0.4" or "outline_variant/0.2",
        borderWidth = 1,
        fit = "cover",
      }) or ui.column({
        key = "card_preview_ph_" .. item.name,
        width = cardW - (isCenter and 16 or 10),
        height = imgH,
        radius = R(6),
        border = isCenter and "primary/0.4" or "outline_variant/0.2",
        borderWidth = 1,
        fill = item.sourceColor or "surface_container/0.5",
        align = "center",
        justify = "center",
      }, {
        ui.glyph({
          name = (currentMode == "wallhaven" and thumbPending[item.id]) and "loader-2" or "photo",
          size = isCenter and 30 or 20,
          color = "on_surface/0.5",
        }),
      }),

      -- 5 Material 3 Chips
      ui.column({
        gap = 2,
      }, chipRows),

      -- Card Footer: Filename + Details
      ui.column({ gap = 1, paddingH = 2 }, {
        ui.label({
          text = displayName,
          fontSize = isCenter and 11 or 9,
          fontWeight = "bold",
          maxLines = 1,
          maxWidth = cardW - 16,
        }),
        ui.label({
          text = detailLine,
          fontSize = isCenter and 8 or 7,
          color = "on_surface/0.65",
          maxLines = 1,
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
    subtitle = "Press F on any wallpaper in the deck to add it to your favourites."
    buttons = {
      ui.button({
        text = "Browse Local",
        glyph = "folder",
        variant = "primary",
        controlSize = "md",
        onClick = function()
          currentMode = "local"
          selectedIdx = 1
          animatedPos = 1.0
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
      local errTitle = "Network Unavailable"
      local errSub = "Could not connect to Wallhaven. Check your internet connection and try again."
      if type(wallhavenError) == "table" then
        if wallhavenError.type == "offline" or wallhavenError.status == 0 or wallhavenError.offline == true then
          isOffline = true
          errTitle = "Network Unavailable"
          errSub = "Could not connect to Wallhaven. Check your internet connection and try again."
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
          errTitle = "Network Unavailable"
          errSub = "Could not connect to Wallhaven. Check your internet connection and try again."
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
          text = "Retry",
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
      title = "No Wallpapers Found"
      subtitle = (whQuery and whQuery ~= "")
        and string.format("No wallpapers matched \"%s\". Try searching with different tags.", whQuery)
        or "Try searching with different tags or adjust your Wallhaven filters above."

      if whQuery and whQuery ~= "" then
        buttons = {
          ui.button({
            text = "Clear Search",
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
            text = "Retry",
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

function render()
  local panelW, panelH = getPanelGeometry()
  local screenW, screenH = getScreenGeometry()
  local activeItem = displayedItems[selectedIdx]
  local isCurrent = activeItem and activeWallpaper == activeItem.path
  local isFav = activeItem and favorites[activeItem.name] == true
  local paletteColors = getWallpaperPaletteFontColors(activeItem)

  local deckCards = {}
  local halfWindow = math.floor((visibleCards or 7) / 2)
  if #displayedItems > 0 then
    for offset = -halfWindow, halfWindow do
      local idx = selectedIdx + offset
      local distSigned = offset - (animatedPos - selectedIdx)
      if idx >= 1 and idx <= #displayedItems then
        table.insert(deckCards, renderCard(displayedItems[idx], idx, distSigned))
      else
        local dist = math.abs(distSigned)
        local t = math.min(dist / 3.0, 1.0)
        local cardW = math.floor(lerp(224, 132, t))
        table.insert(deckCards, ui.box({ width = cardW, height = 1 }))
      end
    end
  end

  local favCount = getFavCount()

  local activeBg = ""
  if activeItem then
    if currentMode == "wallhaven" then
      if hiResPreview then
        local hiRes = requestWallhavenHiRes(activeItem)
        if hiRes and hiRes ~= "" and (activeItem._hiResValid or noctalia.fileExists(hiRes)) then
          activeBg = hiRes
        else
          activeBg = requestWallhavenThumb(activeItem, true) or ""
        end
      else
        activeBg = requestWallhavenThumb(activeItem, true) or ""
      end
    else
      activeBg = activeItem.preview or activeItem.path or ""
    end
  end

  -- Keep background image stable during card sliding animation to prevent decoding stalls
  local isSettled = math.abs(animatedPos - selectedIdx) < 0.05
  if isSettled or displayedBgPath == "" then
    displayedBgPath = activeBg
  end
  local bgPath = displayedBgPath

  if isPeeking then
    panel.render(ui.column({
      key = "panel_root",
      flexGrow = 1,
      gap = -panelH,
      padding = 0,
      align = "stretch",
      justify = "start",
    }, {
      -- Slot 1: Fullscreen Wallpaper Background
      ui.column({
        key = "bg_layer",
        width = panelW,
        height = panelH,
        padding = 0,
        gap = 0,
        align = "center",
        justify = "center",
      }, {
        (bgPath ~= "") and ui.image({
          key = "deck_bg_preview_image",
          path = bgPath,
          width = panelW,
          height = panelH,
          fit = "cover",
        }) or ui.column({
          key = "bg_fallback",
          width = panelW,
          height = panelH,
          fill = (activeItem and activeItem.sourceColor) or "surface",
          align = "center",
          justify = "center",
        }, {
          (currentMode == "wallhaven" and (not bgPath or bgPath == "")) and ui.row({
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
            ui.label({ text = "Loading preview...", fontSize = 11, fontWeight = "bold", color = "on_surface" }),
          }) or ui.spacer({ width = 1, height = 1 }),
        }),
      }),

      -- Slot 2: Peek Bottom Pill Overlay
      ui.column({
        key = "peek_overlay",
        flexGrow = 1,
        padding = 0,
        gap = 0,
        align = "stretch",
        justify = "space_between",
      }, {
        -- 1: Empty Top Spacer
        ui.spacer({ height = 16 }),

        -- 2: Flexible Center Spacer
        ui.spacer({ flexGrow = 1 }),

        -- 3: Bottom Pill Row
        ui.row({
          align = "center",
          justify = "center",
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
            ui.label({ text = "Space or Esc: back to deck", fontSize = 11, color = paletteColors.muted }),
          }),
        }),
      }),
    }))
    return
  end

  -- Fullscreen Immersive Overlay with Fullscreen Wallpaper Background
  panel.render(ui.column({
    key = "panel_root",
    flexGrow = 1,
    gap = -panelH,
    padding = 0,
    align = "stretch",
    justify = "start",
  }, {
    -- Slot 1: Fullscreen Wallpaper Background Preview
    ui.column({
      key = "bg_layer",
      width = panelW,
      height = panelH,
      padding = 0,
      gap = 0,
      align = "center",
      justify = "center",
    }, {
      (#displayedItems > 0 and bgPath ~= "") and ui.image({
        key = "deck_bg_preview_image",
        path = bgPath,
        width = panelW,
        height = panelH,
        fit = "cover",
      }) or ui.column({
        key = "bg_fallback",
        width = panelW,
        height = panelH,
        fill = (#displayedItems > 0 and activeItem and activeItem.sourceColor) or "surface",
        align = "center",
        justify = "center",
      }, {
        (#displayedItems > 0 and currentMode == "wallhaven" and (not bgPath or bgPath == "")) and ui.row({
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
          ui.label({ text = "Loading preview...", fontSize = 11, fontWeight = "bold", color = "on_surface" }),
        }) or ui.spacer({ width = 1, height = 1 }),
      }),
    }),

    -- Slot 2: Fullscreen UI Elements Overlaid on Top
    ui.column({
      key = "deck_overlay",
      flexGrow = 1,
      padding = 0,
      gap = 0,
      align = "stretch",
      justify = "space_between",
      -- fill = "#00000070",
    }, {
    -- ── TOP HEADER SECTION ─────────────────────────────────────────
    ui.column({ gap = 8, paddingH = 32, paddingV = 14 }, {
      -- Row 1: App Info + Filter Input | Mode Pills | Flatten Toggle + Output Select + Actions
      ui.row({
        align = "center",
        justify = "space_between",
        height = 42,
      }, {
        -- Left: Title & Filter Input
        ui.row({
          flexGrow = 1,
          align = "center",
          justify = "start",
          gap = 14,
        }, {
          ui.row({ align = "center", gap = 10 }, {
            ui.glyph({ name = "cards", size = 24, color = paletteColors.accent }),
            ui.column({ gap = 1 }, {
              ui.label({ text = "Wallpapers", fontSize = 16, fontWeight = "heavy", color = paletteColors.primaryText }),
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
                color = paletteColors.muted,
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
              border = ((currentMode == "wallhaven" and whQuery ~= "") or (currentMode ~= "wallhaven" and searchQuery ~= "")) and paletteColors.accent or "outline_variant/0.25",
              borderWidth = 1,
              radius = R(10),
              paddingH = 10,
              height = 32,
              width = (currentMode == "wallhaven") and 350 or 240,
            }, {
              ui.glyph({
                name = "search",
                size = 14,
                color = ((currentMode == "wallhaven" and whQuery ~= "") or (currentMode ~= "wallhaven" and searchQuery ~= "")) and paletteColors.accent or paletteColors.muted,
              }),
              ui.input({
                value = (currentMode == "wallhaven") and whQuery or searchQuery,
                placeholder = (currentMode == "wallhaven") and "Search tags..." or "Filter...",
                controlSize = "sm",
                frameVisible = false,
                flexGrow = 1,
                width = (currentMode == "wallhaven") and 270 or 180,
                onChange = function(val)
                  if currentMode == "wallhaven" then
                    whQuery = val or ""
                  else
                    searchQuery = val or ""
                    selectedIdx = 1
                    animatedPos = 1.0
                    rebuildList()
                    triggerPreview()
                    render()
                  end
                end,
                onSubmit = function(val)
                  if currentMode == "wallhaven" then
                    whQuery = val or ""
                    doWallhavenSearch(true)
                  else
                    searchQuery = val or ""
                    selectedIdx = 1
                    animatedPos = 1.0
                    rebuildList()
                    render()
                  end
                end,
              }),
              ((currentMode == "wallhaven" and whQuery ~= "") or (currentMode ~= "wallhaven" and searchQuery ~= "")) and ui.button({
                glyph = "close",
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                  if currentMode == "wallhaven" then
                    whQuery = ""
                    doWallhavenSearch(true)
                  else
                    searchQuery = ""
                    selectedIdx = 1
                    animatedPos = 1.0
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
                doWallhavenSearch(true)
              end,
            }) or ui.spacer({ width = 1 }),
          }),
        }),

        -- Center: Mode selector pills (centered in panel)
        -- Left: Source Switcher (Local / Favourites / Wallhaven)
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
              text = "Local",
              variant = currentMode == "local" and "primary" or "ghost",
              controlSize = "sm",
              onClick = function()
                currentMode = "local"
                selectedIdx = 1
                animatedPos = 1.0
                rebuildList()
                triggerPreview()
                render()
              end,
            }),
            ui.button({
              text = string.format("Favourites %d", favCount),
              glyph = "heart",
              variant = currentMode == "favorites" and "primary" or "ghost",
              controlSize = "sm",
              onClick = function()
                currentMode = "favorites"
                selectedIdx = 1
                animatedPos = 1.0
                rebuildList()
                triggerPreview()
                render()
              end,
            }),
            ui.button({
              text = "Wallhaven",
              glyph = "world",
              variant = currentMode == "wallhaven" and "primary" or "ghost",
              controlSize = "sm",
              onClick = function()
                currentMode = "wallhaven"
                selectedIdx = 1
                animatedPos = 1.0
                if #((wallhavenData and wallhavenData.items) or {}) == 0 then
                  doWallhavenSearch(true)
                end
                rebuildList()
                render()
              end,
            }),
          }),

        -- Right: Flatten toggle + Output select + Action icons
        ui.row({
          flexGrow = 1,
          align = "center",
          justify = "end",
          gap = 12,
        }, {
          -- Hi-Res Preview Button (Wallhaven) / Flatten Toggle (Local)
          (currentMode == "wallhaven") and (function()
            local isLoadingHiRes = hiResPreview and activeItem and (hiResPending[activeItem.id] == true or (function()
              for _, it in ipairs(hiResQueue) do
                if it.id == (activeItem and activeItem.id) then return true end
              end
              return false
            end)())

            return ui.button({
              text = isLoadingHiRes and "Hi-Res (Loading...)" or (hiResPreview and "Hi-Res ON" or "Hi-Res OFF"),
              glyph = isLoadingHiRes and "loader-2" or "sparkles",
              variant = hiResPreview and "primary" or "secondary",
              controlSize = "sm",
              tooltip = hiResPreview and "Hi-Res Preview is ON (caching full HD for preview)" or "Enable Hi-Res Preview (downloads full HD to cache)",
              onClick = function()
                hiResPreview = not hiResPreview
                if not hiResPreview then
                  hiResQueue = {}
                end
                triggerPreview()
                render()
              end,
            })
          end)() or (currentMode ~= "wallhaven" and ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = "Flatten", fontSize = 12, color = isFlattened and paletteColors.accent or paletteColors.primaryText }),
            ui.toggle({
              checked = isFlattened,
              onChange = function(checked)
                isFlattened = checked
                selectedIdx = 1
                animatedPos = 1.0
                rebuildList()
                triggerPreview()
                render()
              end,
            }),
          }) or ui.spacer({ width = 1 })),

          -- Action Buttons (Folder, Peek, Random, Rescan, Close)
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
      (#displayedItems > 0) and ((currentMode == "wallhaven") and buildWallhavenRow2(paletteColors) or buildStandardRow2()) or ui.spacer({ width = 1, height = 1 }),

      -- Spectrum Ribbon (Edge-to-Edge)
      (#displayedItems > 0) and renderSpectrumRibbon() or ui.spacer({ width = 1, height = 1 }),

      -- Keyboard Hints Bar
      (#displayedItems > 0) and (function()
        local hintLabels = {
          ui.label({ text = "← → or wheel browse", fontSize = 10, color = paletteColors.muted }),
          ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }),
          ui.label({ text = "Enter apply", fontSize = 10, fontWeight = "bold", color = paletteColors.accent }),
          ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }),
          ui.label({ text = "F favourite", fontSize = 10, color = paletteColors.muted }),
          ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }),
          ui.label({ text = "S sort", fontSize = 10, color = paletteColors.muted }),
          ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }),
          ui.label({ text = "R random", fontSize = 10, color = paletteColors.muted }),
          ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }),
          ui.label({ text = "Space peek", fontSize = 10, color = paletteColors.muted }),
          ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }),
        }
        if currentMode == "wallhaven" then
          table.insert(hintLabels, ui.label({ text = "P hi-res", fontSize = 10, color = hiResPreview and paletteColors.accent or paletteColors.muted }))
          table.insert(hintLabels, ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }))
        end
        table.insert(hintLabels, ui.label({ text = "Tab source", fontSize = 10, color = paletteColors.muted }))
        table.insert(hintLabels, ui.label({ text = "•", fontSize = 10, color = paletteColors.bullet }))
        table.insert(hintLabels, ui.label({ text = "Esc close", fontSize = 10, color = paletteColors.muted }))

        return ui.row({
          align = "center",
          justify = "center",
          gap = 12,
          height = 24,
          paddingH = 14,
          fill = paletteColors.isLight and "#ffffff99" or "surface/0.60",
          border = paletteColors.isLight and (paletteColors.accent .. "30") or "outline_variant/0.2",
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
      flexGrow = 1,
      padding = 0,
      gap = 0,
      align = "stretch",
      justify = "space_between",
    }, {
      -- Middle: Floating Action Buttons above Center Card (replacing small window)
      activeItem and ui.column({
        key = "deck_floating_actions",
        align = "center",
        justify = "end",
        flexGrow = 1,
        paddingV = 8,
        gap = 6,
      }, {
        -- Monitor Selection Dropdown Menu (shown when toggled)
        monitorDropdownOpen and ui.column({
          align = "stretch",
          justify = "center",
          fill = "surface/0.95",
          border = "outline_variant/0.3",
          borderWidth = 1,
          radius = R(12),
          padding = 4,
          gap = 2,
        }, (function()
          local rows = {}
          for idx, outName in ipairs(connectedOutputs) do
            local isSel = (outName == selectedOutput)
            table.insert(rows, ui.button({
              text = outName,
              glyph = isSel and "check" or (outName == "ALL" and "devices" or "screen-share"),
              variant = isSel and "secondary" or "ghost",
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

        ui.row({
          align = "center",
          justify = "center",
          gap = 8,
          height = 36,
        }, {
          ui.button({
            glyph = isFav and "heart-filled" or "heart",
            variant = isFav and "primary" or "secondary",
            controlSize = "sm",
            tooltip = "Toggle Favourite (F)",
            onClick = toggleCurrentFavorite,
          }),
          -- Merged Apply Button + Dropdown Chevron Button
          ui.row({
            align = "center",
            gap = 2,
          }, {
            ui.button({
              text = isCurrent and ("On " .. selectedOutput) or ("Apply to " .. selectedOutput),
              glyph = isCurrent and "check" or "screen-share",
              variant = isCurrent and "secondary" or "primary",
              controlSize = "sm",
              tooltip = "Apply wallpaper (Enter)",
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
              tooltip = "Change Target Monitor",
              onClick = function()
                refreshConnectedOutputs()
                monitorDropdownOpen = not monitorDropdownOpen
                render()
              end,
            }),
          }),
        }),
      }) or ui.spacer({ flexGrow = 1 }),

      -- Bottom: Arched Coverflow Card Deck
      ui.row({
        key = "deck_cards_row",
        width = panelW,
        align = "end",
        justify = "center",
        gap = 12,
        height = 450,
        paddingV = 10,
        borderWidth = 0,
        radius = 0,
      }, deckCards),
    }),
  }),
  }))
end

function onOpen(context: any?)
  displayedBgPath = ""
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
  searchActive = false
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
  communityPalettes = loadCommunityPalettes()
  updateThemeFromSystem()

  if #allWallpapers == 0 then
    local stateWps = noctalia.state.get("wallpapers")
    if type(stateWps) == "table" and #stateWps > 0 then
      allWallpapers = stateWps
    else
      pcall(function()
        allWallpapers = loadCacheDirect()
      end)
    end
  end

  favorites = noctalia.state.get("favorites") or {}
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
  lastPreviewed = ""
  triggerPreview()
  panel.setNeedsFrameTick(false)
  render()
end

function onFrameTick(deltaMs: number)
  if not animateSelected then
    animatedPos = selectedIdx
    panel.setNeedsFrameTick(false)
    render()
    return
  end

  local dt = math.min(deltaMs / 1000.0, 0.05)
  animatedPos = lerp(animatedPos, selectedIdx, math.min(1.0, dt * 28.0))

  local settled = math.abs(animatedPos - selectedIdx) < 0.02
  if settled then
    animatedPos = selectedIdx
    panel.setNeedsFrameTick(false)
  end
  render()
end

function onKey(chord: string, pressed: boolean)
  if not pressed then return end

  if chord == "left" or chord == "h" then
    if selectedIdx > 1 then
      selectedIdx = selectedIdx - 1
      panel.setNeedsFrameTick(true)
      triggerPreview()
      render()
    end
  elseif chord == "right" or chord == "l" then
    if selectedIdx < #displayedItems then
      selectedIdx = selectedIdx + 1
      panel.setNeedsFrameTick(true)
      triggerPreview()
      render()
    else
      checkWallhavenLazyLoad()
    end
  elseif chord == "up" or chord == "k" or chord == "u" then
    local newIdx = math.max(1, selectedIdx - 5)
    if newIdx ~= selectedIdx then
      selectedIdx = newIdx
      panel.setNeedsFrameTick(true)
      triggerPreview()
      render()
    end
  elseif chord == "down" or chord == "j" or chord == "d" then
    local newIdx = math.min(#displayedItems, selectedIdx + 5)
    if newIdx ~= selectedIdx then
      selectedIdx = newIdx
      panel.setNeedsFrameTick(true)
      triggerPreview()
      render()
    else
      checkWallhavenLazyLoad()
    end
  elseif chord == "return" then
    applyCurrent()
  elseif chord == "f" then
    toggleCurrentFavorite()
  elseif chord == "s" then
    cycleSort()
  elseif chord == "tab" then
    cycleMode()
  elseif chord == "r" then
    pickRandom()
  elseif chord == "space" then
    isPeeking = not isPeeking
    render()
  elseif chord == "p" and currentMode == "wallhaven" then
    hiResPreview = not hiResPreview
    if not hiResPreview then
      hiResQueue = {}
    end
    triggerPreview()
    render()
  elseif chord == "/" or chord == "slash" then
    searchActive = not searchActive
    render()
    elseif chord == "Pointer_Button4" or chord == "Pointer_DfltBtnPrev" or chord == "Page_Up" or chord == "Prior" then
    if selectedIdx > 1 then
      selectedIdx = selectedIdx - 1
      panel.setNeedsFrameTick(true)
      triggerPreview()
      render()
    end
  elseif chord == "Pointer_Button5" or chord == "Pointer_DfltBtnNext" or chord == "Page_Down" or chord == "Next" then
    if selectedIdx < #displayedItems then
      selectedIdx = selectedIdx + 1
      panel.setNeedsFrameTick(true)
      triggerPreview()
      render()
    else
      checkWallhavenLazyLoad()
    end
  elseif chord == "escape" then
    if monitorDropdownOpen then
      monitorDropdownOpen = false
      render()
    elseif isPeeking then
      isPeeking = false
      render()
    else
      cancelAndClose()
    end
  end
end


function onScroll(_axis: any, steps: number, _startsGesture: any)
  if steps > 0 then
    if selectedIdx > 1 then
      selectedIdx = selectedIdx - 1
      panel.setNeedsFrameTick(true)
      triggerPreview()
      render()
    end
  elseif steps < 0 then
    if selectedIdx < #displayedItems then
      selectedIdx = selectedIdx + 1
      panel.setNeedsFrameTick(true)
      triggerPreview()
      render()
    else
      checkWallhavenLazyLoad()
    end
  end
end

noctalia.state.watch("wallpapers", function(val)
  if type(val) == "table" then
    allWallpapers = val
    cachedFavCount = -1
    cachedRibbon = nil
    selectedIdx = 1
    animatedPos = 1.0
    rebuildList()
    triggerPreview()
    render()
  end
end)

noctalia.state.watch("favorites", function(val)
  if type(val) == "table" then
    favorites = val
    cachedFavCount = -1
    rebuildList()
    render()
  end
end)

noctalia.state.watch("active_wallpaper", function(val)
  if type(val) == "string" then
    activeWallpaper = val
    render()
  end
end)

noctalia.state.watch("wallhaven_loading", function(val)
  wallhavenLoading = (val == true)
  if not wallhavenLoading then
    wallhavenLoadingMore = false
  end
  render()
end)

noctalia.state.watch("wallhaven_error", function(val)
  wallhavenError = val
  if val ~= nil then
    wallhavenLoading = false
    wallhavenLoadingMore = false
  end
  render()
end)

noctalia.state.watch("wallhaven_results", function(value)
  if type(value) ~= "table" then return end
  local wasAppend = value.isAppend == true
  local prevCount = #displayedItems
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
      selectedIdx = prevIdx
      -- Pre-queue thumbnails for next cards in newly appended batch
      local batchToPreload = value.newBatch or {}
      for i = 1, math.min(#batchToPreload, 6) do
        local it = batchToPreload[i]
        if it then
          requestWallhavenThumb(it, false)
        end
      end
    else
      selectedIdx = 1
      animatedPos = 1.0
      triggerPreview()
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
    render()
  end
end)

noctalia.state.watch("wallpaper_dir", function(val)
  if type(val) == "string" and val ~= "" then
    currentWallDir = val
    updateRootWpDir(val)
    selectedIdx = 1
    animatedPos = 1.0
    rebuildList()
    render()
  end
end)

noctalia.state.watch("is_scanning", function(val)
  isScanning = (val == true)
  render()
end)

function onConfigChanged()
  local cfgDir = noctalia.getConfig("wallpaper_dir")
  if cfgDir and cfgDir ~= "" then
    local exp = noctalia.expandPath(cfgDir)
    currentWallDir = exp
    updateRootWpDir(exp)
  end
  selectedIdx = 1
  animatedPos = 1.0
  rebuildList()
  render()
  noctalia.state.set("deck_command", { action = "rescan", nonce = noctalia.nowMs() })
end

function onClose()
  stopWheelListener()
  if isPeeking then
    isPeeking = false
  end
  noctalia.state.set("deck_command", { action = "prune_cache", nonce = noctalia.nowMs() })
end
