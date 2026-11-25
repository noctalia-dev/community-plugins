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

local allWallpapers: { any } = (function()
  local sw = noctalia.state.get("wallpapers")
  if type(sw) == "table" and #sw > 0 then return sw end
  local disk = loadCacheDirect()
  if #disk > 0 then return disk end
  return {}
end)()

local favorites: { [string]: boolean } = (function()
  local sf = noctalia.state.get("favorites")
  if type(sf) == "table" and next(sf) ~= nil then return sf end
  local disk = loadFavoritesDirect()
  if next(disk) ~= nil then return disk end
  return {}
end)()
local hasAnyFavorites = (type(favorites) == "table" and next(favorites) ~= nil)
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
local bgSlots = { [0] = "", [1] = "", retireToken = 0 }
local bgActiveSlot = 0
local animateSelected = noctalia.getConfig("animate_selected_card") ~= false
local previewFit = noctalia.getConfig("preview_fit") or "cover"
if previewFit ~= "cover" and previewFit ~= "contain" and previewFit ~= "stretch" then
  previewFit = "cover"
end

local function clampVal(val: number, minVal: number, maxVal: number): number
  if val < minVal then return minVal end
  if val > maxVal then return maxVal end
  return val
end

function bgSlots.scheduleRetirement()
  bgSlots.retireToken = (bgSlots.retireToken or 0) + 1
  local token = bgSlots.retireToken
  local delay = (animateSelected ~= false) and 350 or 250

  if type(noctalia.setTimeout) == "function" then
    noctalia.setTimeout(function()
      if bgSlots.retireToken == token then
        local inactiveSlot = 1 - bgActiveSlot
        if bgSlots[inactiveSlot] ~= "" then
          bgSlots[inactiveSlot] = ""
          if type(render) == "function" then
            render()
          end
        end
      end
    end, delay)
  end
end

function bgSlots.retireNow()
  bgSlots.retireToken = (bgSlots.retireToken or 0) + 1
  local inactiveSlot = 1 - bgActiveSlot
  if bgSlots[inactiveSlot] ~= "" then
    bgSlots[inactiveSlot] = ""
    if type(render) == "function" then
      render()
    end
  end
end

local function setDisplayedBackground(newPath: string)
  if not newPath or newPath == "" or displayedBgPath == newPath then return end
  local oldPath = displayedBgPath
  displayedBgPath = newPath

  if oldPath == "" then
    bgSlots[bgActiveSlot] = newPath
  else
    local nextSlot = 1 - bgActiveSlot
    bgSlots[nextSlot] = newPath
    bgActiveSlot = nextSlot
  end
  bgSlots.scheduleRetirement()
end

local WHEEL_PID_FILE = STATE_DIR .. "/wheel_listener.pid"

local function getWheelScript(): string?
  local candidates = {
    (type(noctalia.pluginDir) == "function" and (noctalia.pluginDir() .. "/scripts/wheel_listener.py")),
    noctalia.expandPath("~/.local/state/noctalia/plugins/materialized/community/wallpaper-deck/scripts/wheel_listener.py"),
    noctalia.expandPath("~/.local/share/noctalia/plugins/wallpaper-deck/scripts/wheel_listener.py"),
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
  for j = #name, 2, -1 do
    if string.byte(name, j) == 46 then
      return string.sub(name, 1, j - 1)
    end
  end
  return name
end

local function isItemFavorite(item: any?): boolean
  if not item or not hasAnyFavorites then return false end
  if item.path and favorites[item.path] then return true end
  if item.name and favorites[item.name] then return true end
  local b = item.base
  if not b and item.name then
    b = baseName(item.name)
    item.base = b
  end
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
  if not hasAnyFavorites then
    cachedFavCount = 0
    return 0
  end
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

local displayedItems = {}
local selectedIdx = 1
local isPickerOpen = false
local isDeckAreaHovered = false
local hoveredDeckKeys: { [string]: boolean } = {}
local isSearchBoxHovered = false
local currentMode = (function()
  if noctalia.getConfig("remember_last_tab") == true then
    local sm = noctalia.state.get("deck_mode")
    if sm == "wallhaven" or sm == "favorites" or sm == "local" then
      return sm
    end
  end
  return "local"
end)()
local pendingStepAfterAppend = false
-- Held-key navigation: the shell delivers one press per physical press and
-- drops the compositor's auto-repeat, so holding Left/Right (or h/l) is
-- replayed from the frame tick while the key stays down.
local navRepeat = { dir = 0, elapsedMs = 0, repeatMs = 0, delayMs = 400, intervalMs = 120 }
local render: () -> ()
local triggerPreview -- forward declaration
local toggleCurrentFavorite -- forward declaration
local toggleFavoriteItem -- forward declaration
local changeSort -- forward declaration

local function isHoverTruthy(state: any): boolean
  if state == "true" or state == true or state == 1 then
    return true
  end
  if type(state) == "table" then
    return state.hovered == true or state.state == true or state.hovered == "true" or state.state == "true"
  end
  return false
end

local function updateDeckHoverState(state: any, fallbackKey: string, explicitKey: string?)
  local k = (type(explicitKey) == "string" and explicitKey ~= "") and explicitKey or fallbackKey
  if isHoverTruthy(state) then
    hoveredDeckKeys[k] = true
    isSearchBoxHovered = false
  else
    hoveredDeckKeys[k] = nil
  end
  isDeckAreaHovered = (next(hoveredDeckKeys) ~= nil)
end

function onDeckHover(state: any, key: string?)
  if isHoverTruthy(state) then
    local k = (type(key) == "string" and key ~= "") and key or "deck_bottom_section"
    hoveredDeckKeys[k] = true
    isDeckAreaHovered = true
    isSearchBoxHovered = false
  else
    hoveredDeckKeys = {}
    isDeckAreaHovered = false
  end
end

function onDeckContainerHover(state: any, key: string?)
  if isHoverTruthy(state) then
    local k = (type(key) == "string" and key ~= "") and key or "deck_cards_outer_row"
    hoveredDeckKeys[k] = true
    isDeckAreaHovered = true
    isSearchBoxHovered = false
  else
    hoveredDeckKeys["deck_cards_outer_row"] = nil
    hoveredDeckKeys["deck_cards_row"] = nil
    hoveredDeckKeys["deck_card_slot"] = nil
    hoveredDeckKeys["deck_card_item"] = nil
    if type(key) == "string" and key ~= "" then
      hoveredDeckKeys[key] = nil
    end
    isDeckAreaHovered = (next(hoveredDeckKeys) ~= nil)
  end
end

function onDeckRowHover(state: any, key: string?)
  updateDeckHoverState(state, "deck_cards_row", key)
end

function onDeckActionHover(state: any, key: string?)
  updateDeckHoverState(state, "deck_action_bar", key)
end

function onDeckPopoverHover(state: any, key: string?)
  updateDeckHoverState(state, "monitor_dropdown_popover", key)
end

function onDeckSlotHover(state: any, key: string?)
  updateDeckHoverState(state, "deck_card_slot", key)
end

function onDeckCardHover(state: any, key: string?)
  updateDeckHoverState(state, "deck_card_item", key)
end

function onOutsideDeckHover(state: any, _key: string?)
  if isHoverTruthy(state) then
    hoveredDeckKeys = {}
    isDeckAreaHovered = false
  end
end

function onSearchBoxHover(state: any, _key: string?)
  if isHoverTruthy(state) then
    isSearchBoxHovered = true
    hoveredDeckKeys = {}
    isDeckAreaHovered = false
  else
    isSearchBoxHovered = false
  end
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
  while thumbActive < 4 and #thumbQueue > 0 do
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
                item._thumbValid = true
                if displayedItems then
                  for _, it in ipairs(displayedItems) do
                    if it.id == id then
                      it.thumb = dest
                      it.preview = dest
                      it._thumbValid = true
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
                item._thumbValid = true
                if displayedItems then
                  for _, it in ipairs(displayedItems) do
                    if it.id == id then
                      it.thumb = dest
                      it.preview = dest
                      it._thumbValid = true
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
  if thumbPending[item.id] then
    return nil
  end
  if not item._thumbDiskChecked then
    item._thumbDiskChecked = true
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
  end
  local found = false
  for i, it in ipairs(thumbQueue) do
    if it.id == item.id then
      found = true
      if priority and i > 1 then
        table.remove(thumbQueue, i)
        table.insert(thumbQueue, 1, item)
      end
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
  return nil
end

local WALLHAVEN_PREVIEW_DIR = noctalia.expandPath("~/.cache/noctalia/wallhaven-previews")
pcall(noctalia.mkdirAll, WALLHAVEN_PREVIEW_DIR)

local PERMANENT_WH_DIRS = {
  noctalia.expandPath("~/Pictures/Wallpapers/WallHaven"),
  noctalia.expandPath("~/Pictures/WallHaven"),
  noctalia.expandPath("~/Pictures/Wallpapers"),
  noctalia.expandPath("~/Pictures/wallpapers/WallHaven"),
  noctalia.expandPath("~/Pictures/wallhaven"),
  noctalia.expandPath("~/Pictures/wallpapers"),
}

local hiResPreview = (function()
  local sh = noctalia.state.get("wallhaven_hires_preview")
  if sh ~= nil then return sh == true end
  return noctalia.getConfig("wallhaven_hires_preview") == true
end)()
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
        local alreadySaved = false
        for _, pdir in ipairs(PERMANENT_WH_DIRS) do
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
  if hiResPending[item.id] or item._hiResDiskChecked then
    return nil
  end
  item._hiResDiskChecked = true

  local urlExt = string.match(item.fullUrl or "", "%.([^%.]+)$") or item.ext or "jpg"
  local ext = string.lower(urlExt)
  if ext == "jpeg" then ext = "jpg" end

  local dest = WALLHAVEN_PREVIEW_DIR .. "/" .. item.id .. "." .. ext
  if isValidFile(dest) then
    item.hiResPath = dest
    item._hiResValid = true
    return dest
  end

  for _, pdir in ipairs(PERMANENT_WH_DIRS) do
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

function bgSlots.getActiveBackground(item: any, preferBlur: boolean?): string
  if not item then return "" end
  if currentMode == "wallhaven" then
    if hiResPreview then
      local hiRes = getWallhavenHiResCached(item)
      if hiRes and hiRes ~= "" then
        return hiRes
      end
    end
    return requestWallhavenThumb(item, true) or ""
  else
    if item._validPath == nil then
      if item.path and item.path ~= "" and noctalia.fileExists(item.path) then
        item._validPath = item.path
      else
        item._validPath = false
      end
    end
    -- Thumb/blur lookups are cached and invalidated by the thumb_update
    -- watcher, so stepping the deck does not hit the filesystem every frame.
    if item._bgThumbPath == nil then
      local tp = nil
      if item.thumb and item.thumb ~= "" and noctalia.fileExists(item.thumb) then
        tp = item.thumb
      elseif item.preview and item.preview ~= "" and noctalia.fileExists(item.preview) then
        tp = item.preview
      end
      item._bgThumbPath = tp or false
    end
    local fullPath = (item._validPath ~= false) and item._validPath or nil
    if preferBlur then
      if item._bgBlurPath == nil then
        item._bgBlurPath = (item.blur and item.blur ~= "" and noctalia.fileExists(item.blur)) and item.blur or false
      end
      local blurPath = item._bgBlurPath or nil
      if blurPath then return blurPath end
    end
    return fullPath or (item._bgThumbPath or nil) or ""
  end
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
  local item = displayedItems[selectedIdx]
  if not item then return end

  if not animateSelected then
    bgSlots.scheduleRetirement()
  end

  if currentMode ~= "wallhaven" then
    if item._prefetchIdx ~= selectedIdx then
      item._prefetchIdx = selectedIdx
      local paths = {}

      -- 1. Center card comes first
      local c = item.colors
      local hasReal = (c and c.primary and c.primary ~= "#80a9ff")
      if not hasReal and not item._paletteRequested and item.path then
        item._paletteRequested = true
        table.insert(paths, item.path)
      end

      -- 2. Immediate neighbors in radiating order: ±1, ±2, ±3
      for offset = 1, 3 do
        local leftIdx = selectedIdx - offset
        if leftIdx >= 1 then
          local it = displayedItems[leftIdx]
          if it and it.path then
            local col = it.colors
            local real = (col and col.primary and col.primary ~= "#80a9ff")
            if not real and not it._paletteRequested then
              it._paletteRequested = true
              table.insert(paths, it.path)
            end
          end
        end
        local rightIdx = selectedIdx + offset
        if rightIdx <= #displayedItems then
          local it = displayedItems[rightIdx]
          if it and it.path then
            local col = it.colors
            local real = (col and col.primary and col.primary ~= "#80a9ff")
            if not real and not it._paletteRequested then
              it._paletteRequested = true
              table.insert(paths, it.path)
            end
          end
        end
      end

      if #paths > 0 then
        noctalia.state.set("deck_command", { action = "prioritize_ribbon", paths = paths, nonce = noctalia.nowMs() })
      end
    end
    return
  end

  if not hiResPreview or not item.id or not item.fullUrl then return end

  local cached = getWallhavenHiResCached(item)
  if cached then
    setDisplayedBackground(cached)
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

local function scheduleSettle()
  -- Handled deterministically when spring animation completes in onFrameTick
end

-- The mapping is inlined on purpose: picker.luau is close to Luau's 200-local
-- limit, so no extra helper locals are introduced here.
local currentSort = (function()
  local s = noctalia.state.get("deck_sort")
  if type(s) == "string" and s ~= "" then return s end
  local mode = noctalia.getConfig("default_sort_mode")
  if mode == "colour" then return "colour" end
  if mode == "newest" then return "newest" end
  return "name_asc"
end)()
local searchQuery = ""
-- Color-search state packed into one table to stay within Luau's 200-local limit
CSF = { color = nil, hueKey = nil, searching = false, token = 0, sortUserSet = false }
local isSearchFocused = false
local whQueryDirty = false
local whResDirty = false
local searchInputNonce = 0
local lastSearchSubmitMs = 0
local isPeeking = false

local function unfocusSearch()
  isSearchBoxHovered = false
  if isSearchFocused or whQueryDirty or whResDirty then
    isSearchFocused = false
    whQueryDirty = false
    whResDirty = false
    searchInputNonce = searchInputNonce + 1
  end
end
local cfgScanSub = noctalia.getConfig("scan_subdirectories")
local isFlattened = (function()
  local sf = noctalia.state.get("deck_flattened")
  if sf ~= nil then return sf == true end
  if cfgScanSub ~= nil then
    return (cfgScanSub == true or cfgScanSub == "true" or cfgScanSub == 1)
  end
  return true
end)()

WH = {
  sortLabels = { "Date Added", "Toplist", "Hot", "Views", "Favorites", "Relevance", "Random" },
  sortValues = { "date_added", "toplist", "hot", "views", "favorites", "relevance", "random" },
  ratioLabels = { "Any", "Landscape", "Portrait", "16:9", "16:10", "21:9", "32:9", "48:9", "9:16", "10:16", "9:18", "1:1", "3:2", "4:3", "5:4" },
  ratioValues = { "", "landscape", "portrait", "16x9", "16x10", "21x9", "32x9", "48x9", "9x16", "10x16", "9x18", "1x1", "3x2", "4x3", "5x4" },
  resModeLabels = { "At Least", "Exact" },
  resModeValues = { "atleast", "exact" },
  catModalOpen = false,
  tempCatGeneral = true,
  tempCatAnime = true,
  tempCatPeople = true,
  resModalOpen = false,
  paletteSourceOptions = { "Wallpaper", "Built-In", "Community", "Custom" },
  paletteSourceKeys = { "wallpaper", "builtin", "community", "custom" },
}

local cachedApiKey = noctalia.getConfig("wallhaven_api_key") or ""
local function getApiKey(): string
  return cachedApiKey
end

local function isNsfwAllowed(): boolean
  return getApiKey() ~= ""
end

local function parseCategories(catStr: string?): (boolean, boolean, boolean)
  local s = catStr or "111"
  local g = string.sub(s, 1, 1) == "1"
  local a = string.sub(s, 2, 2) == "1"
  local p = string.sub(s, 3, 3) == "1"
  if not g and not a and not p then
    g, a, p = true, true, true
  end
  return g, a, p
end

local function parsePurity(purStr: string?): (boolean, boolean, boolean)
  local s = purStr or "100"
  local sfw = string.sub(s, 1, 1) == "1"
  local sketchy = string.sub(s, 2, 2) == "1"
  local nsfw = string.sub(s, 3, 3) == "1"
  if not sfw and not sketchy and not nsfw then
    sfw = true
  end
  return sfw, sketchy, nsfw
end

local initialCats = noctalia.state.get("wallhaven_categories")
  or (wallhavenData and (wallhavenData.categories or (wallhavenData.filters and wallhavenData.filters.categories)))
  or noctalia.getConfig("wallhaven_categories")
  or "111"
local whCatGeneral, whCatAnime, whCatPeople = parseCategories(initialCats)

function WH.getCategorySummaryText(): string
  local parts = {}
  if whCatGeneral then table.insert(parts, "General") end
  if whCatAnime then table.insert(parts, "Anime") end
  if whCatPeople then table.insert(parts, "People") end
  if #parts == 3 then return "Categories: All" end
  if #parts == 0 then return "Categories: None" end
  if #parts == 1 then return parts[1] end
  local short = {}
  for _, p in ipairs(parts) do
    if p == "General" then table.insert(short, "Gen")
    elseif p == "Anime" then table.insert(short, "Anime")
    elseif p == "People" then table.insert(short, "People") end
  end
  return table.concat(short, " + ")
end

local initialPurity = noctalia.state.get("wallhaven_purity")
  or (wallhavenData and (wallhavenData.purity or (wallhavenData.filters and wallhavenData.filters.purity)))
  or noctalia.getConfig("wallhaven_purity")
  or "100"
local whPuritySfw, whPuritySketchy, whPurityNsfw = parsePurity(initialPurity)
if not isNsfwAllowed() then
  whPurityNsfw = false
  if not whPuritySfw and not whPuritySketchy then
    whPuritySfw = true
  end
end

local function getSortIndexFromValue(val: string?): number
  if not val or val == "" then return 0 end
  local clean = string.lower(noctalia.string.trim(val))
  for i, v in ipairs(WH.sortValues) do
    if v == clean then return i - 1 end
  end
  return 0
end

local savedSort = noctalia.state.get("wallhaven_sort") or noctalia.getConfig("wallhaven_sorting") or "date_added"
local whSortIdx = getSortIndexFromValue(savedSort)
local savedOrder = noctalia.state.get("wallhaven_order") or noctalia.getConfig("wallhaven_order") or "desc"
local whOrder = (savedOrder == "asc") and "asc" or "desc"

local whRatioIdx = tonumber(noctalia.state.get("wallhaven_ratio_idx")) or 0 -- "Any"
local whResModeIdx = tonumber(noctalia.state.get("wallhaven_res_mode_idx")) or 0 -- "At Least"
local whResWidth = noctalia.state.get("wallhaven_res_width") or ""
local whResHeight = noctalia.state.get("wallhaven_res_height") or ""
local whClearCounter = 0
local whQuery = (wallhavenData and wallhavenData.query) or ""

local connectedOutputs = { "ALL" }
local selectedOutput = (function()
  local so = noctalia.state.get("deck_output")
  if type(so) == "string" and so ~= "" then return so end
  return "ALL"
end)()
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

local communityPalettes: {string}
do
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
  communityPalettes = loadCommunityPalettes()
end
local CT = require("./custom_themes.luau")
local Profiles = require("./profiles.luau")
local selectedBuiltinIdx = 1
local selectedSchemeIdx = 4 -- default m3-rainbow
local selectedCommunityIdx = 1

local animatedPos = 1.0
local animVel = 0.0
local animTargetPos = 1.0
local lastFrameMs = 0

local function resetDeckAnimation(pos: number?)
  local p = pos or 1.0
  animatedPos = p
  animTargetPos = p
  animVel = 0.0
  lastFrameMs = 0
  panel.setNeedsFrameTick(false)
end

animateSelected = noctalia.getConfig("animate_selected_card") ~= false

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

local function getCardWidthFloat(dist: number, scale: number): number
  local t = clamp(math.abs(dist) / DECK_K, 0.0, 1.0)
  local centerW = 224.0 * scale
  local sideW = 132.0 * scale
  return lerp(centerW, sideW, t)
end

local function getCardWidth(dist: number, scale: number): number
  return math.floor(getCardWidthFloat(dist, scale) + 0.5)
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
local panelInnerPad = 14

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

local function resolveBarMonitorOverride(monTable: any, currentMonitorName: string): any
  if type(monTable) ~= "table" or currentMonitorName == "" then return nil end
  if type(monTable[currentMonitorName]) == "table" then
    return monTable[currentMonitorName]
  end
  for k, v in pairs(monTable) do
    if type(v) == "table" then
      local m = v.match or k
      if m == currentMonitorName then
        return v
      end
    end
  end
  return nil
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
          local monOverride = resolveBarMonitorOverride(bar.monitor, currentMonitorName)
          local effEnabled = (monOverride and monOverride.enabled ~= nil) and monOverride.enabled or bar.enabled
          local effAutoHide = (monOverride and monOverride.auto_hide ~= nil) and monOverride.auto_hide or bar.auto_hide
          local effReserve = (monOverride and monOverride.reserve_space ~= nil) and monOverride.reserve_space or bar.reserve_space
          local effPos = (monOverride and type(monOverride.position) == "string" and monOverride.position)
            or (type(bar.position) == "string" and bar.position)
            or "top"

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
  local borderWidth = 1
  local uiScale = 1.0

  if type(noctalia.getSetting) == "function" then
    local okFo, fo = pcall(noctalia.getSetting, "shell.panel.floating_offset")
    if okFo and type(fo) == "number" then
      floatingOffset = fo
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

  local padFloat = (floatingOffset > 0) and (floatingOffset * 2) or 0
  local chromeInset = tonumber(noctalia.getConfig("panel_padding_offset"))
  -- Treat legacy default 24 or nil as 0 (full bleed, zero panel padding)
  if chromeInset == nil or chromeInset == 24 then
    chromeInset = 0
  end

  -- Offset the host's built-in 14px panel inner padding so panel_root starts at (0, 0)
  panelInnerPad = math.max(0, 14 - math.floor(chromeInset / 2 + 0.5))
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
      local prevSource = currentPaletteSource
      local prevBuiltin = selectedBuiltinIdx
      local prevCommunity = selectedCommunityIdx
      local prevScheme = selectedSchemeIdx
      local prevCustom = CT.selectedIdx

      local src, scheme = string.match(res.stdout, "(%S+)%s+(.+)")
      if src and src ~= "" then
        src = string.lower(noctalia.string.trim(src))
        if src == "builtin" or src == "wallpaper" or src == "community" or src == "custom" then
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
        elseif currentPaletteSource == "custom" then
          local customList = CT.list()
          for idx, id in ipairs(customList) do
            if string.lower(id) == string.lower(scheme) then
              CT.selectedIdx = idx
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
      local changed = (prevSource ~= currentPaletteSource)
        or (prevBuiltin ~= selectedBuiltinIdx)
        or (prevCommunity ~= selectedCommunityIdx)
        or (prevScheme ~= selectedSchemeIdx)
        or (prevCustom ~= CT.selectedIdx)
      if changed and isPickerOpen then render() end
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

local sortedListCache: { [string]: { any } } = {}

local function invalidateSortCache()
  sortedListCache = {}
end

local cachedRibbon = nil
local cachedRibbonIdx = -1
local cachedRibbonCount = -1

local function getCachedLocalList(sortMode: string, flattened: boolean): { any }
  local cacheKey = sortMode .. "_" .. (flattened and "1" or "0")
  if sortedListCache[cacheKey] then
    return sortedListCache[cacheKey]
  end

  local base: { any }
  if flattened then
    if sortMode == "name_asc" or sortMode == "name" then
      sortedListCache[cacheKey] = allWallpapers
      return allWallpapers
    elseif sortMode == "name_desc" then
      local rev = reverseArray(allWallpapers)
      sortedListCache[cacheKey] = rev
      return rev
    end
    base = table.create(#allWallpapers)
    for i, it in ipairs(allWallpapers) do
      base[i] = it
    end
  else
    base = {}
    for _, it in ipairs(allWallpapers) do
      if not itemIsSubdir(it) then
        table.insert(base, it)
      end
    end
    if sortMode == "name_asc" or sortMode == "name" then
      sortedListCache[cacheKey] = base
      return base
    elseif sortMode == "name_desc" then
      local rev = reverseArray(base)
      sortedListCache[cacheKey] = rev
      return rev
    end
  end

  sortItemsInPlace(base, sortMode)
  sortedListCache[cacheKey] = base
  return base
end

local CS = require("./color_search.luau")
-- CSF.token is used for color-filter cancellation (defined in CSF above)

local function rebuildList()
  -- Cancel any in-flight async color filter from a previous rebuild.
  CSF.token = CSF.token + 1
  local myToken = CSF.token

  if currentMode == "wallhaven" then
    CSF.searching = false
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

  local hasSearch = (searchQuery ~= "") or (CSF.hueKey ~= nil)

  local src = {}
  if currentMode == "favorites" then
    if hasAnyFavorites then
      for _, item in ipairs(allWallpapers) do
        if isItemFavorite(item) then
          if isFlattened or not itemIsSubdir(item) then
            table.insert(src, item)
          end
        end
      end
      if hasSearch then
        local q = string.lower(searchQuery)
        local colorMode = (CSF.hueKey ~= nil)
        if colorMode then
          -- Async batched: handled by CS.runColorFilter, return early
          CSF.searching = true
          CS.runColorFilter(myToken, CSF.hueKey, searchQuery, src, function()
            return CSF.token ~= myToken
          end, function(partial, done)
            if CSF.token ~= myToken then return end
            if done then
              CSF.searching = false
              triggerPreview()
            end
            displayedItems = partial
            cachedRibbon = nil
            selectedIdx = clamp(selectedIdx, 1, math.max(1, #displayedItems))
            render()
          end)
          return
        end
        local filtered = {}
        for _, item in ipairs(src) do
          local ln = item.lowerName or string.lower(item.name or "")
          local rel = item.relDir and string.lower(item.relDir) or ""
          local nameOk = (q == "") or string.find(ln, q, 1, true) or (rel ~= "" and string.find(rel, q, 1, true))
          if nameOk then
            table.insert(filtered, item)
          end
        end
        src = filtered
        sortItemsInPlace(src, currentSort)
      else
        sortItemsInPlace(src, currentSort)
      end
    end
  else
    -- Local mode
    if hasSearch then
      local q = string.lower(searchQuery)
      local colorMode = (CSF.hueKey ~= nil)
      if colorMode then
        local flatSrc = {}
        for _, item in ipairs(allWallpapers) do
          if isFlattened or not itemIsSubdir(item) then
            table.insert(flatSrc, item)
          end
        end
        CSF.searching = true
        CS.runColorFilter(myToken, CSF.hueKey, searchQuery, flatSrc, function()
          return CSF.token ~= myToken
        end, function(partial, done)
          if CSF.token ~= myToken then return end
          if done then
            CSF.searching = false
            triggerPreview()
          end
          displayedItems = partial
          cachedRibbon = nil
          selectedIdx = clamp(selectedIdx, 1, math.max(1, #displayedItems))
          render()
        end)
        return
      end
      local filtered = {}
      for _, item in ipairs(allWallpapers) do
        if isFlattened or not itemIsSubdir(item) then
          local ln = item.lowerName or string.lower(item.name or "")
          local rel = item.relDir and string.lower(item.relDir) or ""
          local nameOk = (q == "") or string.find(ln, q, 1, true) or (rel ~= "" and string.find(rel, q, 1, true))
          if nameOk then
            table.insert(filtered, item)
          end
        end
      end
      src = filtered
      sortItemsInPlace(src, currentSort)
    else
      src = getCachedLocalList(currentSort, isFlattened)
    end
  end

  displayedItems = src
  cachedRibbon = nil
  selectedIdx = clamp(selectedIdx, 1, math.max(1, #displayedItems))
end

local function buildCategories(): string
  local g = whCatGeneral and "1" or "0"
  local a = whCatAnime and "1" or "0"
  local p = whCatPeople and "1" or "0"
  local cat = g .. a .. p
  if cat == "000" then return "111" end
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
  local val = WH.ratioValues[whRatioIdx + 1]
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
  local sortVal = WH.sortValues[whSortIdx + 1] or "date_added"
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

function WH.resetFiltersToDefaults()
  local defPurity = noctalia.getConfig("wallhaven_purity") or "100"
  local s, sk, n = parsePurity(defPurity)
  if not isNsfwAllowed() then
    n = false
    if not s and not sk then s = true end
  end
  local changed = (whPuritySfw ~= s) or (whPuritySketchy ~= sk) or (whPurityNsfw ~= n)
  whPuritySfw, whPuritySketchy, whPurityNsfw = s, sk, n

  local defCats = noctalia.getConfig("wallhaven_categories") or "111"
  local g, a, p = parseCategories(defCats)
  if (whCatGeneral ~= g) or (whCatAnime ~= a) or (whCatPeople ~= p) then changed = true end
  whCatGeneral, whCatAnime, whCatPeople = g, a, p

  local defSort = noctalia.getConfig("wallhaven_sorting") or "date_added"
  local sIdx = getSortIndexFromValue(defSort)
  if whSortIdx ~= sIdx then changed = true end
  whSortIdx = sIdx

  local defOrder = noctalia.getConfig("wallhaven_order") or "desc"
  local ord = (defOrder == "asc") and "asc" or "desc"
  if whOrder ~= ord then changed = true end
  whOrder = ord

  whRatioIdx = 0
  whResModeIdx = 0
  whResWidth = ""
  whResHeight = ""
  whQuery = ""
  whQueryDirty = false
  whResDirty = false

  noctalia.state.set("wallhaven_purity", buildPurity())
  noctalia.state.set("wallhaven_categories", buildCategories())
  noctalia.state.set("wallhaven_sort", WH.sortValues[whSortIdx + 1] or "date_added")
  noctalia.state.set("wallhaven_order", whOrder)
  noctalia.state.set("wallhaven_ratio_idx", 0)
  noctalia.state.set("wallhaven_res_mode_idx", 0)
  noctalia.state.set("wallhaven_res_width", "")
  noctalia.state.set("wallhaven_res_height", "")

  if changed then
    wallhavenData = nil
  end
end

local function doWallhavenSearch(resetPage: boolean?, skipRender: boolean?)
  local targetPage = resetPage and 1 or (wallhavenData.page or 1)
  wallhavenLoadingMore = false
  wallhavenError = nil
  pendingStepAfterAppend = false
  if resetPage then
    unfocusSearch()
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
  if not skipRender and type(render) == "function" then
    render()
  end
end

local function togglePuritySfw()
  if whPuritySfw and not whPuritySketchy and not whPurityNsfw then return end
  whPuritySfw = not whPuritySfw
  noctalia.state.set("wallhaven_purity", buildPurity())
  doWallhavenSearch(true)
end

local function togglePuritySketchy()
  if whPuritySketchy and not whPuritySfw and not whPurityNsfw then return end
  whPuritySketchy = not whPuritySketchy
  noctalia.state.set("wallhaven_purity", buildPurity())
  doWallhavenSearch(true)
end

local function togglePurityNsfw()
  if not isNsfwAllowed() then return end
  if whPurityNsfw and not whPuritySfw and not whPuritySketchy then return end
  whPurityNsfw = not whPurityNsfw
  noctalia.state.set("wallhaven_purity", buildPurity())
  doWallhavenSearch(true)
end

local function buildWallhavenRow2(paletteColors: any?, panelW: number?)
  local pW = panelW or cachedPanelW
  local isCompact = (pW < 1360)
  local isUltraCompact = (pW < 1100)

  return ui.row({
    align = "center",
    justify = "space_between",
    height = 36,
    width = pW - 64,
  }, {
    -- Left: Content Filters (Categories + Purity Pills)
    ui.row({
      flexGrow = 1,
      align = "center",
      justify = "start",
      gap = isCompact and 6 or 8,
    }, {
      -- 1. Category Popover Trigger Button
      (function()
        local isAll = whCatGeneral and whCatAnime and whCatPeople
        local summary = WH.getCategorySummaryText()
        return ui.button({
          text = isUltraCompact and "Categories" or summary,
          glyph = "tag",
          variant = isAll and "secondary" or "primary",
          controlSize = "sm",
          tooltip = "Filter Categories: " .. summary .. " (Click to customize)",
          onClick = function()
            WH.tempCatGeneral = whCatGeneral
            WH.tempCatAnime = whCatAnime
            WH.tempCatPeople = whCatPeople
            WH.catModalOpen = not WH.catModalOpen
            WH.resModalOpen = false
            render()
          end,
        })
      end)(),

      -- 2. Purity Pills [SFW] [Sketchy] [NSFW]
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
          tooltip = "Safe for work",
          onClick = togglePuritySfw,
        }),
        ui.button({
          text = isUltraCompact and "Sk" or "Sketchy",
          variant = whPuritySketchy and "primary" or "ghost",
          controlSize = "sm",
          tooltip = "Sketchy / suggestive",
          onClick = togglePuritySketchy,
        }),
        ui.button({
          text = "NSFW",
          variant = whPurityNsfw and "primary" or "ghost",
          controlSize = "sm",
          enabled = isNsfwAllowed(),
          tooltip = not isNsfwAllowed() and "Requires Wallhaven API Key in Settings" or "Not safe for work (NSFW)",
          onClick = togglePurityNsfw,
        }),
      }),
    }),

    -- Center: Query Filters & Sorting (Sort + Order, Aspect Ratio, Resolution)
    ui.row({
      align = "center",
      justify = "center",
      gap = isCompact and 6 or 8,
    }, {
      -- 3. Sort Dropdown + Order Toggle
      ui.row({ align = "center", gap = 2 }, {
        ui.select({
          key = "wh_sort_select_" .. tostring(whSortIdx),
          options = WH.sortLabels,
          selectedIndex = tonumber(whSortIdx) or 0,
          controlSize = "sm",
          width = isCompact and 95 or 110,
          onChange = function(idx, text)
            local num = tonumber(idx)
            if not num and text then
              for i, lbl in ipairs(WH.sortLabels) do
                if lbl == text then num = i - 1; break end
              end
            end
            whSortIdx = num or 0
            local sortVal = WH.sortValues[whSortIdx + 1] or "date_added"
            noctalia.state.set("wallhaven_sort", sortVal)
            doWallhavenSearch(true)
          end,
        }),
        ui.button({
          glyph = (whOrder == "desc") and "arrow-down" or "arrow-up",
          variant = "secondary",
          controlSize = "sm",
          tooltip = (whOrder == "desc") and "Order: Descending (Click for Ascending)" or "Order: Ascending (Click for Descending)",
          onClick = function()
            whOrder = (whOrder == "desc") and "asc" or "desc"
            noctalia.state.set("wallhaven_order", whOrder)
            doWallhavenSearch(true)
          end,
        }),
      }),

      -- 4. Aspect Ratio Dropdown
      ui.select({
        key = "wh_ratio_select_" .. tostring(whRatioIdx),
        options = WH.ratioLabels,
        selectedIndex = tonumber(whRatioIdx) or 0,
        controlSize = "sm",
        width = isCompact and 78 or 92,
        onChange = function(idx, text)
          local num = tonumber(idx)
          if not num and text then
            for i, lbl in ipairs(WH.ratioLabels) do
              if lbl == text then num = i - 1; break end
            end
          end
          whRatioIdx = num or 0
          noctalia.state.set("wallhaven_ratio_idx", whRatioIdx)
          doWallhavenSearch(true)
        end,
      }),

      -- 5. Compact Resolution Popover Button
      (function()
        local resParam, resMode = getResolutionParam()
        local hasRes = (resParam ~= nil and resParam ~= "")
        local btnText = hasRes and (resParam .. ((resMode == "exact") and " (exact)" or "+")) or "Resolution"
        return ui.button({
          text = isUltraCompact and (hasRes and resParam or nil) or btnText,
          glyph = "aspect-ratio",
          variant = hasRes and "primary" or (WH.resModalOpen and "secondary" or "ghost"),
          controlSize = "sm",
          tooltip = hasRes and ("Resolution filter: " .. btnText .. " (Click to change)") or "Filter by resolution (Click to set)",
          onClick = function()
            WH.resModalOpen = not WH.resModalOpen
            render()
          end,
        })
      end)(),
    }),

    -- Right: Theme Mode Icon Pills [Moon] [Sun] [Auto]
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
          glyph = "brightness-auto",
          variant = currentThemeMode == "auto" and "primary" or "ghost",
          controlSize = "sm",
          tooltip = "Auto Theme (follow system)",
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
      gap = isCompact and 6 or 8,
    }, (function()
      -- Palette Source dropdown (Wallpaper, Built-In, Community, Custom)
      local srcIdx = 0
      for i, k in ipairs(WH.paletteSourceKeys) do
        if k == currentPaletteSource then
          srcIdx = i - 1
          break
        end
      end

      local sourceSelect = ui.select({
        key = "palette_source_select_" .. tostring(srcIdx),
        options = WH.paletteSourceOptions,
        selectedIndex = srcIdx,
        controlSize = "sm",
        width = isCompact and 95 or 110,
        onChange = function(idx)
          local chosen = (tonumber(idx) or 0) + 1
          local sourceKey = WH.paletteSourceKeys[chosen] or "wallpaper"
          currentPaletteSource = sourceKey
          if sourceKey == "builtin" then
            local name = BUILTIN_PALETTES[selectedBuiltinIdx or 1] or "Noctalia"
            noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "builtin", name }, function() end)
          elseif sourceKey == "wallpaper" then
            local s = SCHEMES[selectedSchemeIdx or 1]
            local schemeId = s and s.id or "m3-rainbow"
            noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "wallpaper", schemeId }, function() end)
          elseif sourceKey == "community" then
            local name = communityPalettes[selectedCommunityIdx or 1] or "Oxocarbon"
            noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "community", name }, function() end)
          elseif sourceKey == "custom" then
            local customList = CT.list()
            if #customList > 0 then
              local safeIdx = CT.selectedIdx or 1
              if safeIdx < 1 or safeIdx > #customList then
                safeIdx = 1
              end
              CT.selectedIdx = safeIdx
              local id = customList[safeIdx]
              if id then CT.apply(id) end
            end
          end
          render()
        end,
      })

      -- Dropdown: varies by source
      local dropdownWidget
      if currentPaletteSource == "builtin" then
        local idx0 = math.max(0, (selectedBuiltinIdx or 1) - 1)
        dropdownWidget = ui.select({
          key = "palette_select_builtin_" .. tostring(idx0),
          options = BUILTIN_PALETTES,
          selectedIndex = idx0,
          controlSize = "sm",
          width = isCompact and 110 or 130,
          onChange = function(idx)
            local chosenIdx = (tonumber(idx) or 0) + 1
            selectedBuiltinIdx = chosenIdx
            local name = BUILTIN_PALETTES[chosenIdx]
            if name then
              noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "builtin", name }, function() end)
            end
            render()
          end,
        })
      elseif currentPaletteSource == "community" then
        local idx0 = math.max(0, (selectedCommunityIdx or 1) - 1)
        dropdownWidget = ui.select({
          key = "palette_select_community_" .. tostring(idx0),
          options = communityPalettes,
          selectedIndex = idx0,
          controlSize = "sm",
          width = isCompact and 135 or 170,
          onChange = function(idx)
            local chosenIdx = (tonumber(idx) or 0) + 1
            selectedCommunityIdx = chosenIdx
            local name = communityPalettes[chosenIdx]
            if name then
              noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "community", name }, function() end)
            end
            render()
          end,
        })
      elseif currentPaletteSource == "custom" then
        local customList = CT.list()
        local hasCustom = #customList > 0
        local safeIdx = CT.selectedIdx or 1
        if safeIdx > #customList then safeIdx = math.max(1, #customList) end
        local displayOptions = hasCustom and customList or { "(no themes yet)" }
        local idx0 = hasCustom and math.max(0, safeIdx - 1) or 0
        dropdownWidget = ui.select({
          key = "palette_select_custom_" .. tostring(#customList) .. "_" .. tostring(idx0),
          options = displayOptions,
          selectedIndex = idx0,
          controlSize = "sm",
          width = isCompact and 130 or 160,
          onChange = function(idx)
            if not hasCustom then return end
            local chosenIdx = (tonumber(idx) or 0) + 1
            CT.selectedIdx = chosenIdx
            local id = customList[chosenIdx]
            if id then CT.apply(id) end
            render()
          end,
        })
      else
        -- Wallpaper / scheme
        local idx0 = math.max(0, (selectedSchemeIdx or 1) - 1)
        dropdownWidget = ui.select({
          key = "palette_select_wallpaper_" .. tostring(idx0),
          options = SCHEME_OPTIONS,
          selectedIndex = idx0,
          controlSize = "sm",
          width = isCompact and 120 or 140,
          onChange = function(idx)
            local chosenIdx = (tonumber(idx) or 0) + 1
            selectedSchemeIdx = chosenIdx
            local s = SCHEMES[chosenIdx]
            if s then
              noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "wallpaper", s.id }, function() end)
            end
            render()
          end,
        })
      end

      -- Build the left row items dynamically (no nil values)
      local leftItems = { sourceSelect, dropdownWidget }

      if currentPaletteSource == "custom" then
        -- "+" button to open the create modal
        table.insert(leftItems, ui.button({
          glyph = "plus",
          variant = "ghost",
          controlSize = "sm",
          tooltip = "Create new custom theme",
          onClick = function()
            CT.resetModal()
            CT.isOpen = true
            render()
          end,
        }))
        -- Trash button to delete currently selected custom theme
        local customListForTrash = CT.list()
        if #customListForTrash > 0 then
          local trashId = customListForTrash[CT.selectedIdx] or customListForTrash[1]
          table.insert(leftItems, ui.button({
            glyph = "trash",
            variant = "ghost",
            controlSize = "sm",
            tooltip = "Delete theme \"" .. tostring(trashId) .. "\"",
            onClick = function()
              CT.delete(trashId)
              CT.selectedIdx = 1
              -- If still on custom source, re-apply first remaining or fall back
              local remaining = CT.list()
              if #remaining > 0 then
                CT.apply(remaining[1])
              else
                -- Fall back to builtin if no themes left
                currentPaletteSource = "builtin"
                local name = BUILTIN_PALETTES[selectedBuiltinIdx or 1] or "Noctalia"
                noctalia.runAsync({ "noctalia", "msg", "color-scheme-set", "builtin", name }, function() end)
              end
              render()
            end,
          }))
        end
      end

      -- Favourite star button always at the end
      table.insert(leftItems, ui.button({
        glyph = activeFav and "star-filled" or "star",
        variant = activeFav and "primary" or "ghost",
        controlSize = "sm",
        tooltip = activeFav and "Remove from Favourites (F)" or "Add to Favourites (F)",
        onClick = function()
          if toggleCurrentFavorite then toggleCurrentFavorite() end
        end,
      }))

      return leftItems
    end)()),

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
          glyph = "brightness-auto",
          variant = currentThemeMode == "auto" and "primary" or "ghost",
          controlSize = "sm",
          tooltip = "Auto Theme (follow system)",
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

function triggerPreview()
  local item = displayedItems[selectedIdx]
  if not item or not (item.path or item.id) then return end
  if currentMode == "wallhaven" then
    requestWallhavenThumb(item, true)
    checkWallhavenLazyLoad()
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
  local si = displayedItems[selectedIdx]
  if si then
    -- While the deck is moving (spring animation or a held key) use the
    -- pre-blurred preview: it decodes instantly and avoids the hitch of a
    -- full-resolution image swap on every step.
    local bg = bgSlots.getActiveBackground(si, animateSelected or navRepeat.dir ~= 0)
    if bg ~= "" and bg ~= displayedBgPath then
      setDisplayedBackground(bg)
    end
  end
  if not animateSelected then
    onCardSettled()
  end
  if type(render) == "function" then
    render()
  end
end

-- One step of the deck: dir < 0 goes left, dir > 0 goes right. At the end of
-- the loaded Wallhaven list it asks for the next page once and reports false;
-- the caller disarms the hold so a page boundary cannot hammer the service.
local function stepDeck(dir: number): boolean
  if #displayedItems == 0 then return false end
  if dir < 0 then
    if selectedIdx > 1 then
      selectCardIndex(selectedIdx - 1)
      return true
    end
    return false
  end
  if selectedIdx < #displayedItems then
    selectCardIndex(selectedIdx + 1)
    return true
  end
  if currentMode == "wallhaven" and not wallhavenLoadingMore then
    pendingStepAfterAppend = true
    checkWallhavenLazyLoad()
  end
  return false
end

local function doApplyWallpaperOnly(item: any, targetOut: string?)
  if not item then return end

  if currentMode == "wallhaven" then
    local urlExt = string.match(item.fullUrl or item.path or "", "%.([^%.]+)$") or item.ext or "jpg"
    local ext = string.lower(urlExt)
    if ext == "jpeg" then ext = "jpg" end
    local cached = item.hiResPath or (WALLHAVEN_PREVIEW_DIR .. "/" .. item.id .. "." .. ext)
    if not (cached and noctalia.fileExists(cached)) then
      cached = nil
    end
    noctalia.state.set("deck_command", { action = "wallhaven_apply", item = item, cachedPath = cached, output = targetOut, skipWidgets = true, nonce = noctalia.nowMs() })
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
    noctalia.state.set("deck_command", { action = "apply", path = item.path, output = targetOut, skipWidgets = true, nonce = noctalia.nowMs() })
  end
  stopWheelListener()
  panel.close()
end

local function applyCurrent()
  local item = displayedItems[selectedIdx]
  if not item then return end

  local targetOut = (selectedOutput == "ALL") and nil or selectedOutput

  if Profiles.includeWidgets and item.path and item.path ~= "" then
    local matches = Profiles.getProfilesForWallpaper(item.path, targetOut)
    if #matches == 1 then
      -- 1 match: Apply wallpaper + linked widget profile immediately (1-click flow) and update lastUsedAt
      Profiles.applyProfile(matches[1], function(wpPath, mon)
        doApplyWallpaperOnly(item, mon or targetOut)
      end)
      return
    elseif #matches >= 2 then
      -- 2+ matches: Open compact inline Quick-Pick Popover sorted by lastUsedAt descending
      Profiles.openQuickPick(matches, item, targetOut)
      render()
      return
    end
  end

  -- 0 matches or toggle OFF: Apply wallpaper normally; leave widgets untouched
  doApplyWallpaperOnly(item, targetOut)
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
  noctalia.state.set("deck_output", selectedOutput)
  render()
end

function onSelectMonitorOutput(outName)
  if not outName then return end
  for idx, name in ipairs(connectedOutputs) do
    if name == outName then
      selectedOutputIdx = idx
      selectedOutput = name
      noctalia.state.set("deck_output", selectedOutput)
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
  hasAnyFavorites = (next(favorites) ~= nil)
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
  CSF.sortUserSet = true
  local currentItem = displayedItems[selectedIdx]
  local currentPath = currentItem and (currentItem.path or currentItem.id)
  currentSort = newSort
  noctalia.state.set("deck_sort", newSort)
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
  unfocusSearch()
  if currentMode == "local" then
    currentMode = "favorites"
  elseif currentMode == "favorites" then
    currentMode = "wallhaven"
    if noctalia.getConfig("remember_last_tab") ~= true then
      WH.resetFiltersToDefaults()
    end
    if #((wallhavenData and wallhavenData.items) or {}) == 0 then
      doWallhavenSearch(true, true)
    end
  else
    currentMode = "local"
  end
  noctalia.state.set("deck_mode", currentMode)
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

  -- Palette prioritization is triggered on settle (onCardSettled) to keep render() pure and fast

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

  local cardFolder = "Wallpapers"
  if currentMode == "wallhaven" then
    cardFolder = "Wallhaven"
  elseif item.relDir and item.relDir ~= "" then
    if string.find(item.relDir, "/", 1, true) then
      cardFolder = string.match(item.relDir, "([^/]+)$") or item.relDir
    else
      cardFolder = item.relDir
    end
  elseif rootWpDir and rootWpDir ~= "" then
    cardFolder = string.match(rootWpDir, "([^/]+)$") or "Wallpapers"
  end

  return ui.column({
    key = "slot_wrap_" .. itemKey,
    width = cardW,
    height = maxDeckH,
    align = "center",
    justify = "end",
    opacity = opacity,
    onHover = "onDeckSlotHover",
  }, {
    ui.column({
      key = "card_" .. itemKey,
      width = cardW,
      height = slotH,
      align = "center",
      justify = "start",
      onHover = "onDeckCardHover",
      onClick = function()
        unfocusSearch()
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
        -- Header row on card (✓ current badge, profile badge, and // name tag)
        ui.row({ align = "center", justify = "space_between", paddingH = 2, height = math.floor(14 * math.max(0.75, s)) }, {
          ui.row({ align = "center", gap = 3 }, (function()
            local badges = {}
            if isCurrent then
              table.insert(badges, ui.row({
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
              }))
            end
            if Profiles.hasProfileForWallpaper(item.path) then
              local badgeChildren = {
                ui.glyph({ name = "layout-grid", size = (s < 0.7) and 7 or 8, color = "secondary" }),
              }
              if s >= 0.75 then
                table.insert(badgeChildren, ui.label({
                  text = "profile",
                  fontSize = 6,
                  fontWeight = "bold",
                  color = "secondary",
                }))
              end
              table.insert(badges, ui.row({
                fill = "secondary/0.25",
                radius = R(4),
                paddingH = math.max(2, math.floor(3 * s)),
                paddingV = 1,
                gap = 2,
                align = "center",
              }, badgeChildren))
            end
            if #badges == 0 then
              table.insert(badges, ui.spacer({ width = 1 }))
            end
            return badges
          end)()),
          ui.label({
            text = "// " .. cardFolder,
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

CSF.renderState = function(paletteColors: any, hexColor: string?)
  local colorLabel = hexColor and ("Filtering by " .. string.upper(hexColor) .. "...") or "Filtering by color..."
  return ui.column({
    key = "deck_color_search_container",
    align = "center",
    justify = "center",
    flexGrow = 1,
    padding = 24,
  }, {
    ui.column({
      key = "deck_color_search_card",
      align = "center",
      justify = "center",
      padding = 36,
      fill = "surface/0.85",
      border = "outline_variant/0.25",
      borderWidth = 1,
      radius = R(24),
      gap = 14,
    }, {
      hexColor and ui.row({ align = "center", gap = 10 }, {
        ui.box({
          width = 40,
          height = 40,
          fill = hexColor,
          radius = R(10),
          border = "outline_variant/0.3",
          borderWidth = 1,
        }),
        ui.glyph({ name = "loader-2", size = 32, color = paletteColors.accent }),
      }) or ui.glyph({ name = "loader-2", size = 48, color = paletteColors.accent }),
      ui.label({
        text = "Searching by Color",
        fontSize = 20,
        fontWeight = "heavy",
        color = paletteColors.primaryText,
      }),
      ui.label({
        text = colorLabel,
        fontSize = 12,
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

  if currentMode == "favorites" and (not hasAnyFavorites or (searchQuery == "" and CSF.hueKey == nil)) then
    if #allWallpapers == 0 and (isScanning or noctalia.state.get("is_scanning") == true) then
      return renderScanningState(paletteColors)
    end
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
          unfocusSearch()
          currentMode = "local"
          noctalia.state.set("deck_mode", "local")
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
  elseif (searchQuery ~= "") or (CSF.hueKey ~= nil) then
    glyphName = "search"
    title = "No Wallpapers Found"
    subtitle = (CSF.color and ("No wallpapers match the color " .. CSF.color .. "."))
      or string.format("No wallpapers match \"%s\".", searchQuery)
    buttons = {
      ui.button({
        text = "Clear Filter",
        glyph = "close",
        variant = "primary",
        controlSize = "md",
        onClick = function()
          searchQuery = ""
          CSF.color = nil
          CSF.hueKey = nil
          CSF.searching = false
          selectedIdx = 1
          resetDeckAnimation(1.0)
          rebuildList()
          triggerPreview()
          render()
        end,
      }),
    }
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

CSF.renderBg = function(panelW: number, panelH: number, activeItem: any)
  local bgFill = (#displayedItems > 0 and activeItem and activeItem.sourceColor) or "surface"

  local activePath = bgSlots[bgActiveSlot]
  local inactiveSlot = 1 - bgActiveSlot
  local inactivePath = bgSlots[inactiveSlot]

  if (not activePath or activePath == "") and (not inactivePath or inactivePath == "") then
    return ui.column({
      key = "bg_layer",
      width = panelW,
      height = panelH,
      radius = R(12),
      fill = bgFill,
      align = "center",
      justify = "center",
      onHover = "onOutsideDeckHover",
    }, {
      (#displayedItems > 0 and currentMode == "wallhaven") and ui.row({
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
    })
  end

  local bgChildren = {}

  -- Render inactive slot underneath so old wallpaper remains visible during async decoding
  if inactivePath and inactivePath ~= "" and inactivePath ~= activePath then
    table.insert(bgChildren, ui.image({
      key = "deck_bg_slot_" .. inactiveSlot,
      path = inactivePath,
      width = panelW,
      height = panelH,
      radius = R(12),
      fit = previewFit,
    }))
  end

  -- Render active slot on top
  if activePath and activePath ~= "" then
    table.insert(bgChildren, ui.image({
      key = "deck_bg_slot_" .. bgActiveSlot,
      path = activePath,
      width = panelW,
      height = panelH,
      radius = R(12),
      fit = previewFit,
    }))
  end

  return ui.column({
    key = "bg_layer",
    width = panelW,
    height = panelH,
    padding = 0,
    radius = R(12),
    fill = bgFill,
    gap = -panelH,
    align = "stretch",
    justify = "start",
    onHover = "onOutsideDeckHover",
  }, bgChildren)
end

function WH.renderCategoriesModal(panelW: number, panelH: number): any
  local modalW = math.min(panelW - 64, 380)

  local function buildCategoryItem(id: string, name: string, desc: string, isChecked: boolean, onToggle: () -> ())
    return ui.row({
      key = "wh_cat_item_" .. id,
      align = "center",
      justify = "space_between",
      fill = isChecked and "primary/0.12" or "surface_container/0.5",
      border = isChecked and "primary/0.6" or "outline_variant/0.25",
      borderWidth = 1,
      radius = R(10),
      paddingH = 14,
      paddingV = 10,
      gap = 12,
      onClick = onToggle,
    }, {
      ui.row({ align = "center", gap = 10, flexGrow = 1 }, {
        ui.glyph({
          name = isChecked and "check" or "circle",
          size = 18,
          color = isChecked and "primary" or "on_surface/0.4",
        }),
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({
            text = name,
            fontSize = 13,
            fontWeight = "bold",
            color = isChecked and "on_surface" or "on_surface/0.8",
          }),
          ui.label({
            text = desc,
            fontSize = 11,
            color = "on_surface/0.6",
          }),
        }),
      }),
    })
  end

  return ui.column({
    key = "wh_cat_modal_backdrop",
    width = panelW,
    height = panelH,
    align = "center",
    justify = "center",
    fill = "surface/0.65",
    padding = 0,
    gap = 0,
    onClick = function()
      WH.catModalOpen = false
      render()
    end,
  }, {
    ui.column({
      key = "wh_cat_modal_card",
      width = modalW,
      fill = "surface",
      border = "outline_variant/0.3",
      borderWidth = 1,
      radius = R(16),
      padding = 18,
      gap = 14,
      align = "stretch",
      justify = "start",
      onClick = function() end,
    }, {
      -- Header
      ui.row({
        align = "center",
        justify = "space_between",
      }, {
        ui.row({ align = "center", gap = 8 }, {
          ui.glyph({ name = "tag", size = 18, color = "primary" }),
          ui.label({ text = "Filter Categories", fontSize = 14, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.button({
          glyph = "close",
          variant = "ghost",
          controlSize = "sm",
          tooltip = "Close (Esc)",
          onClick = function()
            WH.catModalOpen = false
            render()
          end,
        }),
      }),

      -- 3 Category Options
      ui.column({ gap = 8 }, {
        buildCategoryItem("general", "General", "Photography, landscape, nature & abstract", WH.tempCatGeneral, function()
          WH.tempCatGeneral = not WH.tempCatGeneral
          render()
        end),
        buildCategoryItem("anime", "Anime", "Anime, manga & stylized digital art", WH.tempCatAnime, function()
          WH.tempCatAnime = not WH.tempCatAnime
          render()
        end),
        buildCategoryItem("people", "People", "Portraits, real models & people", WH.tempCatPeople, function()
          WH.tempCatPeople = not WH.tempCatPeople
          render()
        end),
      }),

      -- Footer Actions
      ui.row({
        align = "center",
        justify = "space_between",
        paddingV = 4,
      }, {
        ui.button({
          text = "Select All",
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            WH.tempCatGeneral = true
            WH.tempCatAnime = true
            WH.tempCatPeople = true
            render()
          end,
        }),

        ui.row({ align = "center", gap = 8 }, {
          ui.button({
            text = "Cancel",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
              WH.catModalOpen = false
              render()
            end,
          }),
          ui.button({
            text = "Apply",
            glyph = "check",
            variant = "primary",
            controlSize = "sm",
            onClick = function()
              if not WH.tempCatGeneral and not WH.tempCatAnime and not WH.tempCatPeople then
                WH.tempCatGeneral = true
              end
              whCatGeneral = WH.tempCatGeneral
              whCatAnime = WH.tempCatAnime
              whCatPeople = WH.tempCatPeople
              WH.catModalOpen = false
              noctalia.state.set("wallhaven_categories", buildCategories())
              doWallhavenSearch(true)
            end,
          }),
        }),
      }),
    }),
  })
end

function WH.renderResolutionModal(panelW: number, panelH: number): any
  local modalW = math.min(panelW - 64, 460)
  local currentRes, _ = getResolutionParam()
  local hasCurrentRes = (currentRes ~= nil)

  return ui.column({
    key = "wh_res_modal_backdrop",
    width = panelW,
    height = panelH,
    align = "center",
    justify = "center",
    fill = "surface/0.65",
    padding = 0,
    gap = 0,
    onClick = function()
      WH.resModalOpen = false
      render()
    end,
  }, {
    ui.column({
      key = "wh_res_modal_card",
      width = modalW,
      fill = "surface",
      border = "outline_variant/0.3",
      borderWidth = 1,
      radius = R(16),
      padding = 18,
      gap = 14,
      align = "stretch",
      justify = "start",
      onClick = function() end,
    }, {
      -- Header
      ui.row({
        align = "center",
        justify = "space_between",
      }, {
        ui.row({ align = "center", gap = 8 }, {
          ui.glyph({ name = "aspect-ratio", size = 18, color = "primary" }),
          ui.label({ text = "Filter by Resolution", fontSize = 14, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.button({
          glyph = "close",
          variant = "ghost",
          controlSize = "sm",
          tooltip = "Close (Esc)",
          onClick = function()
            WH.resModalOpen = false
            render()
          end,
        }),
      }),

      -- Quick Presets (2 rows of 2 buttons so they fit comfortably inside the modal)
      ui.column({ gap = 6 }, {
        ui.label({ text = "POPULAR PRESETS", fontSize = 9, fontWeight = "bold", color = "on_surface/0.6" }),
        ui.row({
          align = "center",
          gap = 8,
        }, {
          ui.button({
            text = "1080p (1920×1080)",
            variant = (whResWidth == "1920" and whResHeight == "1080") and "primary" or "secondary",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
              whResWidth = "1920"
              whResHeight = "1080"
              whClearCounter = whClearCounter + 1
              render()
            end,
          }),
          ui.button({
            text = "1440p (2560×1440)",
            variant = (whResWidth == "2560" and whResHeight == "1440") and "primary" or "secondary",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
              whResWidth = "2560"
              whResHeight = "1440"
              whClearCounter = whClearCounter + 1
              render()
            end,
          }),
        }),
        ui.row({
          align = "center",
          gap = 8,
        }, {
          ui.button({
            text = "4K (3840×2160)",
            variant = (whResWidth == "3840" and whResHeight == "2160") and "primary" or "secondary",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
              whResWidth = "3840"
              whResHeight = "2160"
              whClearCounter = whClearCounter + 1
              render()
            end,
          }),
          ui.button({
            text = "Ultrawide (3440×1440)",
            variant = (whResWidth == "3440" and whResHeight == "1440") and "primary" or "secondary",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
              whResWidth = "3440"
              whResHeight = "1440"
              whClearCounter = whClearCounter + 1
              render()
            end,
          }),
        }),
      }),

      -- Custom Width & Height Inputs
      ui.column({ gap = 6 }, {
        ui.label({ text = "CUSTOM RESOLUTION", fontSize = 9, fontWeight = "bold", color = "on_surface/0.6" }),
        ui.row({
          align = "center",
          gap = 8,
        }, {
          ui.select({
            key = "wh_res_modal_mode_select_" .. tostring(whResModeIdx),
            options = WH.resModeLabels,
            selectedIndex = tonumber(whResModeIdx) or 0,
            controlSize = "sm",
            width = 96,
            onChange = function(idx, text)
              local num = tonumber(idx)
              if not num and text then
                for i, lbl in ipairs(WH.resModeLabels) do
                  if lbl == text then num = i - 1; break end
                end
              end
              whResModeIdx = num or 0
              render()
            end,
          }),
          ui.input({
            key = "wh_res_w_" .. whClearCounter,
            placeholder = "Width (px)",
            value = whResWidth,
            controlSize = "sm",
            flexGrow = 1,
            onChange = function(val)
              isSearchFocused = true
              whResDirty = true
              whResWidth = noctalia.string.trim(val or "")
              local mw, mh = string.match(whResWidth, "(%d+)[xX%*×%s]+(%d+)")
              if mw and mh then
                whResWidth = mw
                whResHeight = mh
                whClearCounter = whClearCounter + 1
                render()
              end
            end,
            onSubmit = function(val)
              whResWidth = noctalia.string.trim(val or "")
              noctalia.state.set("wallhaven_res_width", whResWidth)
              noctalia.state.set("wallhaven_res_mode_idx", whResModeIdx)
              unfocusSearch()
              WH.resModalOpen = false
              doWallhavenSearch(true)
            end,
          }),
          ui.label({ text = "×", fontSize = 14, color = "on_surface/0.6" }),
          ui.input({
            key = "wh_res_h_" .. whClearCounter,
            placeholder = "Height (px)",
            value = whResHeight,
            controlSize = "sm",
            flexGrow = 1,
            onChange = function(val)
              isSearchFocused = true
              whResDirty = true
              whResHeight = noctalia.string.trim(val or "")
              local mw, mh = string.match(whResHeight, "(%d+)[xX%*×%s]+(%d+)")
              if mw and mh then
                whResWidth = mw
                whResHeight = mh
                whClearCounter = whClearCounter + 1
                render()
              end
            end,
            onSubmit = function(val)
              whResHeight = noctalia.string.trim(val or "")
              noctalia.state.set("wallhaven_res_height", whResHeight)
              noctalia.state.set("wallhaven_res_mode_idx", whResModeIdx)
              unfocusSearch()
              WH.resModalOpen = false
              doWallhavenSearch(true)
            end,
          }),
        }),
      }),

      -- Footer Actions
      ui.row({
        align = "center",
        justify = "space_between",
        paddingV = 4,
      }, {
        hasCurrentRes and ui.button({
          text = "Clear Filter",
          glyph = "trash",
          variant = "destructive",
          controlSize = "sm",
          onClick = function()
            whResWidth = ""
            whResHeight = ""
            whResModeIdx = 0
            noctalia.state.set("wallhaven_res_width", "")
            noctalia.state.set("wallhaven_res_height", "")
            noctalia.state.set("wallhaven_res_mode_idx", 0)
            whClearCounter = whClearCounter + 1
            WH.resModalOpen = false
            doWallhavenSearch(true)
          end,
        }) or ui.spacer({ width = 1 }),

        ui.row({ align = "center", gap = 8 }, {
          ui.button({
            text = "Cancel",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
              WH.resModalOpen = false
              render()
            end,
          }),
          ui.button({
            text = "Apply",
            glyph = "check",
            variant = "primary",
            controlSize = "sm",
            onClick = function()
              WH.resModalOpen = false
              noctalia.state.set("wallhaven_res_width", whResWidth)
              noctalia.state.set("wallhaven_res_height", whResHeight)
              noctalia.state.set("wallhaven_res_mode_idx", whResModeIdx)
              local res, _ = getResolutionParam()
              if res then
                doWallhavenSearch(true)
              else
                render()
              end
            end,
          }),
        }),
      }),
    }),
  })
end

function render()
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
  local leftSpacerWidth = 0
  local screenCenterX = panelW / 2.0
  local deckScale = getDeckScale(panelW, panelH)
  local gap = math.max(6, math.floor(12 * deckScale))
  local maxDeckH = math.floor(344 * deckScale + 80 * deckScale)

  if #displayedItems > 0 then
    local pos = clamp(animatedPos, 1.0, #displayedItems)
    -- Anchor the visible card window to the nearest integer index so the card window
    -- switches at the midpoint (frac = +/-0.5) and stays 100% constant while settling!
    local C = clamp(math.floor(pos + 0.5), 1, #displayedItems)
    local frac = pos - C

    local minIdx = math.max(1, C - DECK_K)
    local maxIdx = math.min(#displayedItems, C + DECK_K)

    local cardWidths = {}
    local cardWidthsFloat = {}
    for idx = minIdx, maxIdx do
      local d = idx - pos
      cardWidthsFloat[idx] = getCardWidthFloat(d, deckScale)
      cardWidths[idx] = math.floor(cardWidthsFloat[idx] + 0.5)
    end

    local wCFloat = cardWidthsFloat[C] or getCardWidthFloat(0, deckScale)
    local neighborIdx = (frac >= 0) and (C + 1) or (C - 1)
    local wNeighborFloat = cardWidthsFloat[neighborIdx] or getCardWidthFloat(1.0 - math.abs(frac), deckScale)
    local pitchC = (wCFloat + wNeighborFloat) / 2.0 + gap

    -- Dynamically ensure left and right card spans never overflow panelW
    while minIdx < C do
      local sumLeftTmp = 0.0
      for idx = minIdx, C - 1 do
        sumLeftTmp = sumLeftTmp + cardWidths[idx] + gap
      end
      local testLeft = screenCenterX - (wCFloat / 2.0) - sumLeftTmp - (frac * pitchC)
      if testLeft < 8 then
        minIdx = minIdx + 1
      else
        break
      end
    end

    local sumLeft = 0.0
    for idx = minIdx, C - 1 do
      sumLeft = sumLeft + cardWidths[idx] + gap
    end

    local leftEdgeMin = screenCenterX - (wCFloat / 2.0) - sumLeft - (frac * pitchC)
    leftSpacerWidth = math.max(0, math.floor(leftEdgeMin + 0.5))

    while maxIdx > C do
      local totalCardsW = 0
      for idx = minIdx, maxIdx do
        totalCardsW = totalCardsW + cardWidths[idx] + ((idx < maxIdx) and gap or 0)
      end
      if leftSpacerWidth + totalCardsW > panelW - 8 then
        maxIdx = maxIdx - 1
      else
        break
      end
    end

    local activeHoverKeys: { [string]: boolean } = {
      deck_bottom_section = true,
      deck_cards_outer_row = true,
      deck_cards_row = true,
      deck_card_slot = true,
      deck_card_item = true,
    }
    if activeItem then
      activeHoverKeys["deck_action_bar"] = true
      if monitorDropdownOpen then
        activeHoverKeys["monitor_dropdown_popover"] = true
      end
    end

    for idx = minIdx, maxIdx do
      local it = displayedItems[idx]
      local itKey = tostring(it and (it.path or it.id or it.name) or idx)
      activeHoverKeys["slot_wrap_" .. itKey] = true
      activeHoverKeys["card_" .. itKey] = true
      local distSigned = idx - pos
      table.insert(deckCards, renderCard(it, idx, distSigned, deckScale))
    end

    for k in pairs(hoveredDeckKeys) do
      if not activeHoverKeys[k] then
        hoveredDeckKeys[k] = nil
      end
    end
    isDeckAreaHovered = (next(hoveredDeckKeys) ~= nil)
  else
    hoveredDeckKeys = {}
    isDeckAreaHovered = false
  end

  local favCount = getFavCount()

  local deckMoving = (navRepeat.dir ~= 0) or (animateSelected and (animatedPos ~= animTargetPos or animVel ~= 0.0))
  local activeBg = bgSlots.getActiveBackground(activeItem, deckMoving)

  if #displayedItems == 0 then
    displayedBgPath = ""
    bgSlots[0] = ""
    bgSlots[1] = ""
  else
    if activeBg ~= "" then
      setDisplayedBackground(activeBg)
    end
  end

  local function wrapFullBleed(rootNode: any)
    if panelInnerPad <= 0 then
      return rootNode
    end
    return ui.column({
      key = "panel_bleed_v",
      width = panelW,
      height = panelH,
      padding = 0,
      gap = -(panelInnerPad + 1),
      align = "start",
      justify = "start",
    }, {
      ui.box({ key = "bleed_anchor_v", width = 1, height = 1 }),
      ui.row({
        key = "panel_bleed_h",
        width = panelW,
        height = panelH,
        padding = 0,
        gap = -(panelInnerPad + 1),
        align = "start",
        justify = "start",
      }, {
        ui.box({ key = "bleed_anchor_h", width = 1, height = 1 }),
        rootNode,
      }),
    })
  end

  if isPeeking then
    hoveredDeckKeys = {}
    isDeckAreaHovered = false
    panel.render(wrapFullBleed(ui.column({
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
      CSF.renderBg(panelW, panelH, activeItem),

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
    })))
    return
  end

  local searchBoxW = clamp(math.floor(panelW * ((currentMode == "wallhaven") and 0.18 or 0.14)), 140, (currentMode == "wallhaven") and 340 or 240)
  local searchInputW = math.max(80, searchBoxW - 64)
  local dismissSearch = (isSearchFocused or whQueryDirty or whResDirty) and function()
    unfocusSearch()
    render()
  end or nil

  -- Fullscreen Immersive Overlay with Fullscreen Wallpaper Background
  panel.render(wrapFullBleed(ui.column({
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
    CSF.renderBg(panelW, panelH, activeItem),

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
      ui.column({ key = "deck_header_section", width = panelW, gap = 8, paddingH = 32, paddingV = 14, onHover = "onOutsideDeckHover" }, {
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
                  text = CSF.searching and "filtering..."
                    or (#displayedItems == 0) and (
                      (currentMode ~= "wallhaven" and (isScanning or (#allWallpapers == 0 and noctalia.state.get("is_scanning") == true))) and "loading..."
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
                key = "deck_search_box",
                align = "center",
                gap = 6,
                fill = "surface/0.85",
                border = (isSearchFocused or (currentMode == "wallhaven" and whQuery ~= "") or (currentMode ~= "wallhaven" and searchQuery ~= "")) and paletteColors.accent or "outline_variant/0.25",
                borderWidth = isSearchFocused and 1.5 or 1,
                radius = R(10),
                paddingH = 10,
                height = 32,
                width = searchBoxW,
                onHover = "onSearchBoxHover",
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
                  key = "deck_search_input_" .. (currentMode == "wallhaven" and "wh_" or "local_") .. tostring(searchInputNonce),
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
                      whQueryDirty = true
                      whResDirty = false
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
                    if type(val) == "string" then
                      if currentMode == "wallhaven" then
                        whQuery = val
                      else
                        searchQuery = val
                      end
                    end
                    local isWh = (currentMode == "wallhaven")
                    unfocusSearch()
                    lastSearchSubmitMs = noctalia.nowMs()
                    if isWh then
                      executeSearch()
                    else
                      applyCurrent()
                    end
                  end,
                }),
                ((currentMode == "wallhaven" and whQuery ~= "") or (currentMode ~= "wallhaven" and searchQuery ~= "")) and ui.button({
                  glyph = "close",
                  variant = "ghost",
                  controlSize = "sm",
                  onClick = function()
                    unfocusSearch()
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

              -- Search by color (local/favorites only)
              (currentMode ~= "wallhaven") and ui.row({
                align = "center",
                gap = 4,
              }, {
                ui.button({
                  glyph = "palette",
                  text = (CSF.color and CSF.color ~= "") and "Color" or nil,
                  variant = (CSF.color and CSF.color ~= "") and "secondary" or "ghost",
                  controlSize = "sm",
                  tooltip = (CSF.color and CSF.color ~= "") and ("Search by color: " .. CSF.color .. " (click to change)") or "Search by color",
                  onClick = function()
                    if type(noctalia.openColorPicker) == "function" then
                      pcall(noctalia.openColorPicker, CSF.color or "#80a9ff", function(picked)
                        if picked and picked ~= "" then
                          CSF.color = picked
                          CSF.hueKey = CS.colorToHueKey(picked)
                          selectedIdx = 1
                          resetDeckAnimation(1.0)
                          -- Show loading state immediately, then rebuildList kicks off the
                          -- batched async color filter (startColorFilter) and returns early.
                          CSF.searching = true
                          render()
                          rebuildList()
                          -- triggerPreview and final render happen inside startColorFilter when done
                        end
                      end)
                    end
                  end,
                }),
                (CSF.color and CSF.color ~= "") and ui.button({
                  glyph = "close",
                  variant = "ghost",
                  controlSize = "sm",
                  tooltip = "Clear color filter",
                  onClick = function()
                    CSF.color = nil
                    CSF.hueKey = nil
                    CSF.searching = false
                    selectedIdx = 1
                    resetDeckAnimation(1.0)
                    rebuildList()
                    triggerPreview()
                    render()
                  end,
                }) or ui.spacer({ width = 1 }),
              }) or ui.spacer({ width = 1 }),
              (currentMode == "wallhaven") and ui.button({
                text = "Search",
                variant = "primary",
                controlSize = "sm",
                onClick = function()
                  unfocusSearch()
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
                unfocusSearch()
                currentMode = "local"
                noctalia.state.set("deck_mode", "local")
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
                unfocusSearch()
                currentMode = "favorites"
                noctalia.state.set("deck_mode", "favorites")
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
                unfocusSearch()
                currentMode = "wallhaven"
                noctalia.state.set("deck_mode", "wallhaven")
                selectedIdx = 1
                resetDeckAnimation(1.0)
                if noctalia.getConfig("remember_last_tab") ~= true then
                  WH.resetFiltersToDefaults()
                end
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
                    noctalia.state.set("wallhaven_hires_preview", hiResPreview)
                    if not hiResPreview then
                      hiResQueue = {}
                    else
                      onCardSettled()
                    end
                    triggerPreview()
                    render()
                  end,
                })
              end)(),
            }) or ui.spacer({ width = 1 }),

            ui.spacer({ flexGrow = 1 }),

            -- Profiles Management Button & Include Widgets Toggle Pill
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
                text = "Profiles",
                glyph = "layout-grid",
                variant = (Profiles.isOpen or Profiles.isAddModalOpen) and "primary" or "ghost",
                controlSize = "sm",
                tooltip = "Manage Desktop Widget Profiles",
                onClick = function()
                  refreshConnectedOutputs()
                  Profiles.loadProfiles()
                  Profiles.isOpen = true
                  Profiles.isAddModalOpen = false
                  render()
                end,
              }),
              ui.button({
                text = "Widgets",
                glyph = Profiles.includeWidgets and "check" or "x",
                variant = Profiles.includeWidgets and "primary" or "ghost",
                controlSize = "sm",
                tooltip = Profiles.includeWidgets and "Include Widgets: ON (Click to toggle)" or "Include Widgets: OFF (Click to toggle)",
                onClick = function()
                  Profiles.toggleIncludeWidgets()
                  render()
                end,
              }),
            }),

            -- Flatten Toggle (Local)
            (currentMode ~= "wallhaven" and ui.row({ align = "center", gap = 6 }, {
              ui.label({ text = "Flatten", fontSize = 12, color = isFlattened and paletteColors.accent or paletteColors.primaryText }),
              ui.toggle({
                checked = isFlattened,
                onChange = function(checked)
                  isFlattened = (checked == "true" or checked == true)
                  noctalia.state.set("deck_flattened", isFlattened)
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

      -- Middle & Bottom: Scanning State, Color Searching State, Empty State, or Arched Deck
      -- Also show scanning state when allWallpapers is empty in local mode (service still loading deck).
      (CSF.searching or #displayedItems == 0) and (
        CSF.searching
          and CSF.renderState(paletteColors, CSF.color)
          or (currentMode ~= "wallhaven" and (isScanning or (#allWallpapers == 0 and noctalia.state.get("is_scanning") == true)))
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
        ui.box({
          key = "deck_upper_spacer",
          width = panelW,
          flexGrow = 1,
          fill = "#00000001",
          onHover = "onOutsideDeckHover",
          onClick = dismissSearch,
        }),

        -- Bottom Section: Action Bar + Arched Deck docked cleanly together
        ui.column({
          key = "deck_bottom_section",
          width = panelW,
          fill = "#00000001",
          align = "center",
          justify = "end",
          gap = 10,
          onHover = "onDeckHover",
          onClick = dismissSearch,
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
            onHover = "onDeckPopoverHover",
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
                  noctalia.state.set("deck_output", selectedOutput)
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
            onHover = "onDeckActionHover",
          }, {
            ui.button({
              glyph = isFav and "heart-filled" or "heart",
              variant = isFav and "primary" or "secondary",
              controlSize = "sm",
              tooltip = "Toggle Favourite (F)",
              onClick = toggleCurrentFavorite,
            }),

            -- ui.button({
            --   glyph = "refresh",
            --   variant = "secondary",
            --   controlSize = "sm",
            --   tooltip = "Regenerate palette for current card (click) or all cards (right-click)",
            --   onClick = function()
            --     if activeItem and activeItem.path then
            --       noctalia.state.set("deck_command", { action = "regenerate_palette", paths = { activeItem.path }, nonce = noctalia.nowMs() })
            --     end
            --   end,
            --   onRightClick = function()
            --     local paths = {}
            --     for _, it in ipairs(displayedItems) do
            --       if it and it.path then table.insert(paths, it.path) end
            --     end
            --     if #paths > 0 then
            --       noctalia.state.set("deck_command", { action = "regenerate_palette", paths = paths, nonce = noctalia.nowMs() })
            --     end
            --   end,
            -- }),

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

          -- Bottom: Arched Coverflow Card Deck Row (outer gap=0 wrapper eliminates spacer gap jump)
          ui.row({
            key = "deck_cards_outer_row",
            width = panelW,
            align = "end",
            justify = "start",
            gap = 0,
            height = maxDeckH,
            paddingV = 0,
            borderWidth = 0,
            radius = 0,
            fill = "#00000001",
            onHover = "onDeckContainerHover",
            onClick = dismissSearch,
          }, {
            (leftSpacerWidth > 0) and ui.box({
              key = "deck_left_spacer",
              width = leftSpacerWidth,
              height = 1,
            }) or nil,
            ui.row({
              key = "deck_cards_row",
              align = "end",
              justify = "start",
              gap = gap,
              height = maxDeckH,
              paddingV = 0,
              borderWidth = 0,
              radius = 0,
              fill = "#00000001",
              onHover = "onDeckRowHover",
            }, deckCards),
          }),
          ui.spacer({ height = 12 }),
        }),
      }),
    }),
  })))

  -- Inject Custom Themes modal overlay on top if open
  if CT.isOpen then
    local modalNode = CT.renderModal(ui, panelW, panelH, R, render)
    if modalNode then
      panel.render(wrapFullBleed(ui.column({
        key = "panel_root_modal",
        width = panelW,
        height = panelH,
        flexGrow = 1,
        gap = -panelH,
        padding = 0,
        align = "stretch",
        justify = "start",
      }, {
        CSF.renderBg(panelW, panelH, activeItem),
        ui.column({
          key = "deck_overlay_dim",
          width = panelW,
          height = panelH,
          flexGrow = 1,
          padding = 0,
          gap = 0,
          align = "stretch",
          justify = "start",
        }, {
          ui.column({
            key = "deck_header_modal",
            width = panelW,
            gap = 8,
            paddingH = 32,
            paddingV = 14,
          }, {
            buildStandardRow2(panelW),
          }),
        }),
        modalNode,
      })))
      return
    end
  end

  -- Inject Profiles modal overlay on top if open
  if Profiles.isOpen or Profiles.isAddModalOpen then
    local centerWp = activeItem and activeItem.path or ""
    local modalNode = Profiles.renderProfilesModal(
      ui, panelW, panelH, R, render,
      function(wpPath, mon)
        local targetOut = (mon == "ALL" or mon == "all") and nil or mon
        local it = { path = wpPath }
        doApplyWallpaperOnly(it, targetOut)
      end,
      activeWallpaper,
      centerWp,
      connectedOutputs,
      selectedOutput
    )
    if modalNode then
      panel.render(wrapFullBleed(ui.column({
        key = "panel_root_profiles_modal",
        width = panelW,
        height = panelH,
        flexGrow = 1,
        gap = -panelH,
        padding = 0,
        align = "stretch",
        justify = "start",
      }, {
        CSF.renderBg(panelW, panelH, activeItem),
        ui.column({
          key = "deck_overlay_dim",
          width = panelW,
          height = panelH,
          flexGrow = 1,
          padding = 0,
          gap = 0,
          align = "stretch",
          justify = "start",
        }, {
          ui.column({
            key = "deck_header_modal",
            width = panelW,
            gap = 8,
            paddingH = 32,
            paddingV = 14,
          }, {
            buildStandardRow2(panelW),
          }),
        }),
        modalNode,
      })))
      return
    end
  end

  -- Inject Quick-Pick Popover on top if open
  if Profiles.isQuickPickOpen then
    local popoverNode = Profiles.renderQuickPickPopover(
      ui, panelW, panelH, R, render,
      function(profile)
        Profiles.applyProfile(profile, function(wpPath, mon)
          local targetOut = (mon == "ALL" or mon == "all") and nil or mon
          local it = { path = wpPath }
          doApplyWallpaperOnly(it, targetOut)
        end)
      end,
      function(wpItem, targetMon)
        doApplyWallpaperOnly(wpItem, targetMon)
      end
    )
    if popoverNode then
      panel.render(wrapFullBleed(ui.column({
        key = "panel_root_quick_pick",
        width = panelW,
        height = panelH,
        flexGrow = 1,
        gap = -panelH,
        padding = 0,
        align = "stretch",
        justify = "start",
      }, {
        CSF.renderBg(panelW, panelH, activeItem),
        popoverNode,
      })))
      return
    end
  end

  -- Inject Wallhaven Categories Modal on top if open
  if currentMode == "wallhaven" and WH.catModalOpen then
    local catModalNode = WH.renderCategoriesModal(panelW, panelH)
    if catModalNode then
      panel.render(wrapFullBleed(ui.column({
        key = "panel_root_cat_modal",
        width = panelW,
        height = panelH,
        flexGrow = 1,
        gap = -panelH,
        padding = 0,
        align = "stretch",
        justify = "start",
      }, {
        CSF.renderBg(panelW, panelH, activeItem),
        catModalNode,
      })))
      return
    end
  end

  -- Inject Wallhaven Resolution Modal on top if open
  if currentMode == "wallhaven" and WH.resModalOpen then
    local resModalNode = WH.renderResolutionModal(panelW, panelH)
    if resModalNode then
      panel.render(wrapFullBleed(ui.column({
        key = "panel_root_res_modal",
        width = panelW,
        height = panelH,
        flexGrow = 1,
        gap = -panelH,
        padding = 0,
        align = "stretch",
        justify = "start",
      }, {
        CSF.renderBg(panelW, panelH, activeItem),
        resModalNode,
      })))
      return
    end
  end
end

nativeScrollActive = false

function onOpen(context: any?)
  isPickerOpen = true
  isDeckAreaHovered = false
  isSearchBoxHovered = false
  nativeScrollActive = false
  scrollAccum = 0
  navRepeat.dir = 0
  hoveredDeckKeys = {}
  CT.isOpen = false
  CT.statusText = ""
  CT.statusIsError = false
  Profiles.isOpen = false
  Profiles.isAddModalOpen = false
  Profiles.isQuickPickOpen = false
  Profiles.statusText = ""
  Profiles.statusIsError = false
  WH.resModalOpen = false
  WH.catModalOpen = false
  noctalia.state.set("deck_command", { action = "panel_state", open = true })
  updatePanelGeometry()
  updateCornerRadiusScale()
  animateSelected = noctalia.getConfig("animate_selected_card") ~= false
  cachedApiKey = noctalia.getConfig("wallhaven_api_key") or ""
  local cfgFit = noctalia.getConfig("preview_fit")
  if cfgFit == "cover" or cfgFit == "contain" or cfgFit == "stretch" then
    previewFit = cfgFit
  end
  displayedBgPath = ""
  bgSlots[0] = ""
  bgSlots[1] = ""
  bgActiveSlot = 0
  bgSlots.retireToken = (bgSlots.retireToken or 0) + 1
  cachedRibbon = nil

  isScanning = (noctalia.state.get("is_scanning") == true)

  local requestedMode: string? = nil
  if type(context) == "string" and context ~= "" then
    requestedMode = string.lower(context)
  elseif type(context) == "table" then
    local m = context.mode or context.tab or context.view
    if type(m) == "string" and m ~= "" then
      requestedMode = string.lower(m)
    end
  end

  local rememberLastTab = noctalia.getConfig("remember_last_tab") == true

  if requestedMode == "wallhaven" or requestedMode == "favorites" or requestedMode == "local" then
    currentMode = requestedMode
  elseif rememberLastTab then
    local savedMode = noctalia.state.get("deck_mode")
    if savedMode == "wallhaven" or savedMode == "favorites" or savedMode == "local" then
      currentMode = savedMode
    else
      currentMode = "local"
    end
  else
    currentMode = "local"
  end
  noctalia.state.set("deck_mode", currentMode)

  if rememberLastTab then
    local stateWallhaven = noctalia.state.get("wallhaven_results")
    if type(stateWallhaven) == "table" then
      wallhavenData = stateWallhaven
    end

    local savedPurity = noctalia.state.get("wallhaven_purity")
      or (wallhavenData and (wallhavenData.purity or (wallhavenData.filters and wallhavenData.filters.purity)))
      or noctalia.getConfig("wallhaven_purity")
      or "100"
    whPuritySfw, whPuritySketchy, whPurityNsfw = parsePurity(savedPurity)
    if not isNsfwAllowed() then
      whPurityNsfw = false
      if not whPuritySfw and not whPuritySketchy then
        whPuritySfw = true
      end
    end

    local savedCats = noctalia.state.get("wallhaven_categories")
      or (wallhavenData and (wallhavenData.categories or (wallhavenData.filters and wallhavenData.filters.categories)))
      or noctalia.getConfig("wallhaven_categories")
      or "111"
    whCatGeneral, whCatAnime, whCatPeople = parseCategories(savedCats)

    local savedSort = noctalia.state.get("wallhaven_sort")
      or (wallhavenData and (wallhavenData.sorting or (wallhavenData.filters and wallhavenData.filters.sorting)))
      or noctalia.getConfig("wallhaven_sorting")
      or "date_added"
    whSortIdx = getSortIndexFromValue(savedSort)

    local savedOrder = noctalia.state.get("wallhaven_order")
      or (wallhavenData and (wallhavenData.order or (wallhavenData.filters and wallhavenData.filters.order)))
      or noctalia.getConfig("wallhaven_order")
      or "desc"
    whOrder = (savedOrder == "asc") and "asc" or "desc"

    local savedRatio = tonumber(noctalia.state.get("wallhaven_ratio_idx"))
    if savedRatio then whRatioIdx = savedRatio end

    local savedResMode = tonumber(noctalia.state.get("wallhaven_res_mode_idx"))
    if savedResMode then whResModeIdx = savedResMode end

    local savedResW = noctalia.state.get("wallhaven_res_width")
    if type(savedResW) == "string" then whResWidth = savedResW end

    local savedResH = noctalia.state.get("wallhaven_res_height")
    if type(savedResH) == "string" then whResHeight = savedResH end

    whQuery = (wallhavenData and wallhavenData.query) or whQuery or ""
  else
    WH.resetFiltersToDefaults()
    wallhavenData = nil
    whQuery = ""
  end

  local savedHiRes = noctalia.state.get("wallhaven_hires_preview")
  if savedHiRes ~= nil then
    hiResPreview = (savedHiRes == true)
  end

  local savedLocalSort = noctalia.state.get("deck_sort")
  if type(savedLocalSort) == "string" and savedLocalSort ~= "" then
    currentSort = savedLocalSort
  else
    -- No sort chosen yet in this session: seed from the setting.
    local defaultMode = noctalia.getConfig("default_sort_mode")
    if defaultMode == "colour" then
      currentSort = "colour"
    elseif defaultMode == "newest" then
      currentSort = "newest"
    else
      currentSort = "name_asc"
    end
  end

  local savedFlattened = noctalia.state.get("deck_flattened")
  if savedFlattened ~= nil then
    isFlattened = (savedFlattened == true)
  else
    local cfgScanSub = noctalia.getConfig("scan_subdirectories")
    if cfgScanSub ~= nil then
      isFlattened = (cfgScanSub == true or cfgScanSub == "true" or cfgScanSub == 1)
    end
  end

  local savedOut = noctalia.state.get("deck_output")
  if type(savedOut) == "string" and savedOut ~= "" then
    selectedOutput = savedOut
  end

  local stateWallDir = noctalia.state.get("wallpaper_dir") or noctalia.getConfig("wallpaper_dir")
  if stateWallDir and stateWallDir ~= "" and stateWallDir ~= currentWallDir then
    currentWallDir = stateWallDir
    updateRootWpDir(stateWallDir)
    invalidateSortCache()
  end

  if not hasAnyFavorites or next(favorites) == nil then
    local stateFavs = noctalia.state.get("favorites")
    if type(stateFavs) == "table" and next(stateFavs) ~= nil then
      favorites = stateFavs
      hasAnyFavorites = true
    else
      local diskFavs = loadFavoritesDirect()
      if next(diskFavs) ~= nil then
        favorites = diskFavs
        hasAnyFavorites = true
      end
    end
  end

  if currentMode == "wallhaven" then
    if #((wallhavenData and wallhavenData.items) or {}) == 0 then
      doWallhavenSearch(true, true)
    end
  end
  isSearchFocused = false
  whQueryDirty = false
  whResDirty = false
  lastSearchSubmitMs = 0
  isPeeking = false
  monitorDropdownOpen = false
  searchQuery = ""
  CSF.color = nil
  CSF.hueKey = nil
  CSF.searching = false
  wallhavenLoadingMore = false
  wallhavenLoadingStartMs = 0

  if #allWallpapers == 0 then
    local stateWps = noctalia.state.get("wallpapers")
    if type(stateWps) == "table" and #stateWps > 0 then
      allWallpapers = stateWps
      invalidateSortCache()
    else
      local diskWps = loadCacheDirect()
      if #diskWps > 0 then
        allWallpapers = diskWps
        invalidateSortCache()
      elseif not isScanning and noctalia.state.get("is_scanning") ~= true then
        isScanning = true
        noctalia.state.set("is_scanning", true)
        noctalia.state.set("deck_command", { action = "rescan", nonce = noctalia.nowMs() })
      end
    end
  end

  local stateActive = noctalia.state.get("active_wallpaper") or activeWallpaper
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
  triggerPreview()
  panel.setNeedsFrameTick(false)
  onCardSettled()
  render()

  -- Defer non-critical background initialization to a separate async tick so onOpen stays well within CPU budget
  noctalia.runAsync({ "true" }, function()
    if not isPickerOpen then return end
    refreshConnectedOutputs()
    updateThemeFromSystem()
    startWheelListener()
  end)

  -- Prefetch palettes for all 32 ribbon segments on first open (local mode only)
  if currentMode ~= "wallhaven" then
    noctalia.runAsync({ "true" }, function()
      if not isPickerOpen then return end
      local count = #displayedItems
      if count == 0 then return end
      local segCount = math.min(count, 32)
      local paths = {}
      for i = 1, segCount do
        local itemIndex = math.floor((i - 1) * (count / segCount)) + 1
        local it = displayedItems[itemIndex]
        if it and it.path then
          local c = it.colors
          local hasReal = (c and c.primary and c.primary ~= "#80a9ff")
          if not hasReal and not it._paletteRequested then
            it._paletteRequested = true
            table.insert(paths, it.path)
          end
        end
      end
      if #paths > 0 then
        noctalia.state.set("deck_command", { action = "prioritize_ribbon", paths = paths })
      end
    end)
  end
end

function onFrameTick(deltaMs: any)
  local ok, err = pcall(function()
    local numDelta = tonumber(deltaMs)
    local nowMs = noctalia.nowMs()
    local dt = 0.016
    if lastFrameMs > 0 then
      local elapsed = (nowMs - lastFrameMs) / 1000.0
      if elapsed > 0.0005 then
        dt = clamp(elapsed, 0.001, 0.15)
      end
    elseif numDelta and numDelta > 0 then
      dt = clamp(numDelta / 1000.0, 0.001, 0.05)
    end
    lastFrameMs = nowMs

    -- Disarm a hold whenever a modal, the monitor dropdown or the search field
    -- takes over: a key release swallowed by the dialog must not keep stepping.
    if navRepeat.dir ~= 0 and (CT.isOpen or Profiles.isOpen or WH.catModalOpen or WH.resModalOpen
        or isSearchFocused or isPeeking or monitorDropdownOpen) then
      -- The tick still renders once below, and the settle path swaps the blur
      -- back to the sharp image.
      navRepeat.dir = 0
    end

    -- Held Left/Right: replay the auto-repeat that the shell filters out.
    if navRepeat.dir ~= 0 then
      navRepeat.elapsedMs = navRepeat.elapsedMs + dt * 1000.0
      local fired = 0
      while navRepeat.elapsedMs >= navRepeat.delayMs + navRepeat.repeatMs and fired < 4 do
        navRepeat.repeatMs = navRepeat.repeatMs + navRepeat.intervalMs
        fired = fired + 1
        if not stepDeck(navRepeat.dir) then
          -- Deck end, or a Wallhaven page is already being requested: stop
          -- until the user presses again instead of retrying every frame.
          navRepeat.dir = 0
          break
        end
      end
    end

    local isSpringActive = false
    if not animateSelected then
      animatedPos = selectedIdx
      animTargetPos = selectedIdx
      animVel = 0.0
    else
      local diff = animatedPos - animTargetPos
      if math.abs(diff) < 0.008 and math.abs(animVel) < 0.15 then
        local wasMoving = (animatedPos ~= animTargetPos or animVel ~= 0.0)
        animatedPos = animTargetPos
        animVel = 0.0
        if wasMoving then
          onCardSettled()
          bgSlots.retireNow()
          -- Force background update immediately when spring settles
          local si = displayedItems[selectedIdx]
          if si then
            local bg = bgSlots.getActiveBackground(si)
            if bg ~= "" and bg ~= displayedBgPath then
              setDisplayedBackground(bg)
            end
          end
        end
      else
        isSpringActive = true
        local omega = 32.0
        local c = (animVel + omega * diff) * dt
        local e = math.exp(-omega * dt)
        animatedPos = animTargetPos + (diff + c) * e
        animVel = (animVel - omega * c) * e
      end
    end

    panel.setNeedsFrameTick(isSpringActive or navRepeat.dir ~= 0)
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
  local chordLower = string.lower(chord)
  local navDir = 0
  if chordLower == "left" or chordLower == "h" then
    navDir = -1
  elseif chordLower == "right" or chordLower == "l" then
    navDir = 1
  end

  -- Key-up must be handled before the press-only return: otherwise a release
  -- that arrives while a modal is open leaves the repeat armed forever.
  if not pressed then
    if navDir ~= 0 and navRepeat.dir == navDir then
      navRepeat.dir = 0
      -- No frame is scheduled once the spring has settled, so refresh here to
      -- swap the blurred moving background back to the sharp one.
      if type(render) == "function" then
        render()
      end
    end
    return
  end

  local isReturn = (chordLower == "return" or chordLower == "enter" or chordLower == "kp_enter")

  -- Custom Themes modal intercepts Escape and Enter first
  if CT.isOpen then
    if chordLower == "escape" then
      CT.isOpen = false
      CT.statusText = ""
      CT.statusIsError = false
      render()
    end
    return
  end

  -- Profiles modals & quick-pick popover intercept keys
  local profilesHandled = Profiles.onKey(
    chord,
    pressed,
    render,
    function(profile)
      Profiles.applyProfile(profile, function(wpPath, mon)
        local targetOut = (mon == "ALL" or mon == "all") and nil or mon
        local it = { path = wpPath }
        doApplyWallpaperOnly(it, targetOut)
      end)
    end,
    function(wpItem, targetMon)
      doApplyWallpaperOnly(wpItem, targetMon)
    end
  )
  if profilesHandled then
    return
  end

  if isReturn then
    local nowMs = noctalia.nowMs()
    if nowMs - lastSearchSubmitMs < 300 then
      return
    end
    if currentMode == "wallhaven" and (isSearchFocused or isSearchBoxHovered or whQueryDirty or whResDirty) then
      local wasResDirty = whResDirty
      unfocusSearch()
      lastSearchSubmitMs = nowMs
      if wasResDirty then
        local res, _ = getResolutionParam()
        if res then
          doWallhavenSearch(true)
          return
        end
      end
      executeSearch()
      return
    else
      unfocusSearch()
      lastSearchSubmitMs = nowMs
      applyCurrent()
      return
    end
  end

  if chordLower == "escape" then
    if WH.catModalOpen then
      WH.catModalOpen = false
      render()
    elseif WH.resModalOpen then
      WH.resModalOpen = false
      render()
    elseif monitorDropdownOpen then
      monitorDropdownOpen = false
      render()
    elseif isPeeking then
      isPeeking = false
      render()
    elseif isSearchFocused or whQueryDirty or whResDirty then
      unfocusSearch()
      render()
    else
      cancelAndClose()
    end
    return
  end

  if chordLower == "pointer_button4" or chordLower == "pointer_dfltbtnprev" then
    if not nativeScrollActive then
      nativeScrollActive = true
      stopWheelListener()
    end
    if not isDeckAreaHovered or isPeeking then return end
    if WH.catModalOpen or WH.resModalOpen or monitorDropdownOpen or isSearchBoxHovered then return end
    unfocusSearch()
    if selectedIdx > 1 then
      selectCardIndex(selectedIdx - 1)
    end
    return
  elseif chordLower == "pointer_button5" or chordLower == "pointer_dfltbtnnext" then
    if not nativeScrollActive then
      nativeScrollActive = true
      stopWheelListener()
    end
    if not isDeckAreaHovered or isPeeking then return end
    if WH.catModalOpen or WH.resModalOpen or monitorDropdownOpen or isSearchBoxHovered then return end
    unfocusSearch()
    if selectedIdx < #displayedItems then
      selectCardIndex(selectedIdx + 1)
    else
      pendingStepAfterAppend = true
      checkWallhavenLazyLoad()
    end
    return
  end

  if isSearchFocused or isSearchBoxHovered then
    if chordLower == "down" or chordLower == "up" then
      unfocusSearch()
      render()
    elseif chordLower == "tab" then
      unfocusSearch()
      cycleMode()
    end
    return
  end

  if navDir ~= 0 then
    -- Category/resolution popovers keep keyboard focus: never step behind them.
    if WH.catModalOpen or WH.resModalOpen then return end
    unfocusSearch()
    -- Step once immediately, then keep repeating from the frame tick while
    -- the key stays down (the shell collapses auto-repeat into one press).
    navRepeat.dir = navDir
    navRepeat.elapsedMs = 0
    navRepeat.repeatMs = 0
    if not stepDeck(navDir) then
      -- Nothing to step to (deck edge or page request in flight): do not arm
      -- the repeat, otherwise it would fire into the same boundary.
      navRepeat.dir = 0
    end
    panel.setNeedsFrameTick(true)
  elseif chordLower == "up" or chordLower == "k" or chordLower == "u" then
    unfocusSearch()
    local newIdx = math.max(1, selectedIdx - 5)
    if newIdx ~= selectedIdx then
      selectCardIndex(newIdx)
    end
  elseif chordLower == "down" or chordLower == "j" or chordLower == "d" then
    unfocusSearch()
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
    isSearchFocused = true
    render()
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

scrollAccum = 0

function onScroll(_axis: any, steps: any, _startsGesture: any)
  if not isPickerOpen or #displayedItems == 0 then return end
  if not nativeScrollActive then
    nativeScrollActive = true
    stopWheelListener()
  end
  if not isDeckAreaHovered or isPeeking then return end
  -- Modals and the search box own the wheel: never step the deck behind them.
  if CT.isOpen or Profiles.isOpen or WH.catModalOpen or WH.resModalOpen
      or monitorDropdownOpen or isSearchBoxHovered then
    return
  end
  unfocusSearch()

  local stepVal = tonumber(steps) or 0
  -- Clamp pathological deltas: every accumulated step renders a full frame, so
  -- an unbounded loop from one event would freeze the panel.
  if stepVal > 10 then stepVal = 10 elseif stepVal < -10 then stepVal = -10 end
  scrollAccum = scrollAccum + stepVal

  -- Move by whole accumulated steps instead of throttling by time.
  while scrollAccum >= 1 do
    scrollAccum = scrollAccum - 1
    if selectedIdx > 1 then
      selectCardIndex(selectedIdx - 1)
    end
  end
  while scrollAccum <= -1 do
    scrollAccum = scrollAccum + 1
    if selectedIdx < #displayedItems then
      selectCardIndex(selectedIdx + 1)
    else
      pendingStepAfterAppend = true
      checkWallhavenLazyLoad()
      scrollAccum = 0
      break
    end
  end
end

function onIpc(event: string, _payload: string?)
  if event == "prev" or event == "step_left" or event == "left" then
    if not isPickerOpen or nativeScrollActive or not isDeckAreaHovered or isPeeking then return end
    if CT.isOpen or Profiles.isOpen or WH.catModalOpen or WH.resModalOpen
        or monitorDropdownOpen or isSearchBoxHovered then return end
    unfocusSearch()
    if selectedIdx > 1 then
      selectCardIndex(selectedIdx - 1)
    end
  elseif event == "next" or event == "step_right" or event == "right" then
    if not isPickerOpen or nativeScrollActive or not isDeckAreaHovered or isPeeking then return end
    if CT.isOpen or Profiles.isOpen or WH.catModalOpen or WH.resModalOpen
        or monitorDropdownOpen or isSearchBoxHovered then return end
    unfocusSearch()
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
      noctalia.state.set("wallhaven_hires_preview", hiResPreview)
      if not hiResPreview then
        hiResQueue = {}
      else
        onCardSettled()
      end
      triggerPreview()
      render()
    end
  elseif event == "cycle_mode" or event == "mode" or event == "tab" then
    cycleMode()
  elseif event == "mode_wallhaven" or event == "wallhaven" then
    currentMode = "wallhaven"
    noctalia.state.set("deck_mode", "wallhaven")
    selectedIdx = 1
    resetDeckAnimation(1.0)
    if noctalia.getConfig("remember_last_tab") ~= true then
      WH.resetFiltersToDefaults()
    end
    if #((wallhavenData and wallhavenData.items) or {}) == 0 then
      doWallhavenSearch(true, true)
    end
    rebuildList()
    triggerPreview()
    onCardSettled()
    render()
  elseif event == "mode_favorites" or event == "favorites" then
    currentMode = "favorites"
    noctalia.state.set("deck_mode", "favorites")
    selectedIdx = 1
    resetDeckAnimation(1.0)
    rebuildList()
    triggerPreview()
    render()
  elseif event == "mode_local" or event == "local" then
    currentMode = "local"
    noctalia.state.set("deck_mode", "local")
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

-- Sorted views (newest/oldest/colour) are computed and cached on-demand in picker.luau via sortedListCache

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
          it.hueKeyPrimary = update.hueKeyPrimary or CS.colorToHueKey(update.colors.primary)
          it.hueKeySecondary = update.hueKeySecondary or CS.colorToHueKey(update.colors.secondary)
          it.hueKeyTertiary = update.hueKeyTertiary or CS.colorToHueKey(update.colors.tertiary)
          it.hueKeyContainer = update.hueKeyContainer or CS.colorToHueKey(update.colors.primary_container)
          it.hueKeySurface = update.hueKeySurface or CS.colorToHueKey(update.colors.surface_container_highest)
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
          it.hueKeyPrimary = update.hueKeyPrimary or CS.colorToHueKey(update.colors.primary)
          it.hueKeySecondary = update.hueKeySecondary or CS.colorToHueKey(update.colors.secondary)
          it.hueKeyTertiary = update.hueKeyTertiary or CS.colorToHueKey(update.colors.tertiary)
          it.hueKeyContainer = update.hueKeyContainer or CS.colorToHueKey(update.colors.primary_container)
          it.hueKeySurface = update.hueKeySurface or CS.colorToHueKey(update.colors.surface_container_highest)
          it._chipRows = nil
          it._chipStrip = nil
          it._renderedColors = nil
          changed = true
          break
        end
      end
    end
    if changed then
      cachedRibbon = nil
      sortedListCache["colour_1"] = nil
      sortedListCache["colour_0"] = nil
      if isPickerOpen and (not animateSelected or animatedPos == selectedIdx) then
        -- Preserve hover state so background palette renders don't break scroll
        local savedHover = isDeckAreaHovered
        local savedKeys = {}
        for k, v in pairs(hoveredDeckKeys) do savedKeys[k] = v end
        render()
        if savedHover then
          for k, v in pairs(savedKeys) do hoveredDeckKeys[k] = v end
          isDeckAreaHovered = true
        end
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
          if update.blur and update.blur ~= "" then
            it.blur = update.blur
          end
          -- Invalidate every cached path (full, card thumb, blur): a card drawn
          -- before generation finished must not stay pinned to its fallback.
          it._validPath = nil
          it._bgThumbPath = nil
          it._bgBlurPath = nil
          if it.path == (displayedItems[selectedIdx] and displayedItems[selectedIdx].path) then
            if not (it.path and it.path ~= "" and noctalia.fileExists(it.path)) then
              setDisplayedBackground(update.thumb)
            end
          end
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
          if update.blur and update.blur ~= "" then
            it.blur = update.blur
          end
          it._validPath = nil
          it._bgThumbPath = nil
          it._bgBlurPath = nil
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
    hasAnyFavorites = (next(favorites) ~= nil)
    cachedFavCount = -1
    if isPickerOpen then
      if currentMode == "favorites" then
        rebuildList()
      end
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

  if type(value.purity) == "string" and value.purity ~= "" then
    noctalia.state.set("wallhaven_purity", value.purity)
    local s, sk, n = parsePurity(value.purity)
    if not isNsfwAllowed() then
      n = false
      if not s and not sk then s = true end
    end
    whPuritySfw, whPuritySketchy, whPurityNsfw = s, sk, n
  end
  if type(value.categories) == "string" and value.categories ~= "" then
    noctalia.state.set("wallhaven_categories", value.categories)
    whCatGeneral, whCatAnime, whCatPeople = parseCategories(value.categories)
  end
  if type(value.sorting) == "string" and value.sorting ~= "" then
    noctalia.state.set("wallhaven_sort", value.sorting)
    whSortIdx = getSortIndexFromValue(value.sorting)
  end
  if type(value.order) == "string" and value.order ~= "" then
    noctalia.state.set("wallhaven_order", value.order)
    whOrder = (value.order == "asc") and "asc" or "desc"
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
  cachedApiKey = noctalia.getConfig("wallhaven_api_key") or "" 
  local cfgFit = noctalia.getConfig("preview_fit")
  if cfgFit == "cover" or cfgFit == "contain" or cfgFit == "stretch" then
    previewFit = cfgFit
  end
  local cfgDir = noctalia.getConfig("wallpaper_dir")
  if cfgDir and cfgDir ~= "" then
    local exp = noctalia.expandPath(cfgDir)
    currentWallDir = exp
    updateRootWpDir(exp)
    invalidateSortCache()
  end
  local cfgScanSub = noctalia.getConfig("scan_subdirectories")
  if cfgScanSub ~= nil then
    isFlattened = (cfgScanSub == true or cfgScanSub == "true" or cfgScanSub == 1)
  end
  local cfgPurity = noctalia.getConfig("wallhaven_purity")
  if cfgPurity and cfgPurity ~= "" then
    whPuritySfw, whPuritySketchy, whPurityNsfw = parsePurity(cfgPurity)
    if not isNsfwAllowed() then
      whPurityNsfw = false
      if not whPuritySfw and not whPuritySketchy then whPuritySfw = true end
    end
    noctalia.state.set("wallhaven_purity", buildPurity())
  end
  local cfgCats = noctalia.getConfig("wallhaven_categories")
  if cfgCats and cfgCats ~= "" then
    whCatGeneral, whCatAnime, whCatPeople = parseCategories(cfgCats)
    noctalia.state.set("wallhaven_categories", buildCategories())
  end
  local cfgSort = noctalia.getConfig("wallhaven_sorting")
  if cfgSort and cfgSort ~= "" then
    whSortIdx = getSortIndexFromValue(cfgSort)
    noctalia.state.set("wallhaven_sort", cfgSort)
  end
  local cfgOrder = noctalia.getConfig("wallhaven_order")
  if cfgOrder and cfgOrder ~= "" then
    whOrder = (cfgOrder == "asc") and "asc" or "desc"
    noctalia.state.set("wallhaven_order", whOrder)
  end
  -- Apply a changed default sort live unless the user picked a sort this
  -- session (in which case their choice wins until the panel reopens).
  if not CSF.sortUserSet then
    local defaultMode = noctalia.getConfig("default_sort_mode")
    if defaultMode == "colour" then
      currentSort = "colour"
    elseif defaultMode == "newest" then
      currentSort = "newest"
    else
      currentSort = "name_asc"
    end
  end
  selectedIdx = 1
  resetDeckAnimation(1.0)
  rebuildList()
  if isPickerOpen then
    render()
  end
end

function onClose()
  isPickerOpen = false
  isDeckAreaHovered = false
  isSearchBoxHovered = false
  hoveredDeckKeys = {}
  -- A key can still be down when the panel closes: never leave a repeat armed.
  navRepeat.dir = 0
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
