local selectedIndex = 1
local displayedIndex = 1
local allWallpapers = {}
local currentWallpaper = ""
local isScanning = false
local navToken = 0
local generatingPending = {}
local batchRunning = false
local isOpen = false

math.randomseed(math.floor((os.clock() * 1000000) % 2147483647) + os.time())

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function makeSortKey(s)
  local lower = s:lower()
  return lower:gsub("%d+", function(n)
    return string.format("%08d", tonumber(n) or 0)
  end)
end

local home = noctalia.getenv("HOME") or "~"
local xdgCache = noctalia.getenv("XDG_CACHE_HOME")
local cacheDir = (xdgCache and xdgCache ~= "" and xdgCache or (home .. "/.cache")) .. "/noctalia/wallpaper-widget/thumbnails"

local cacheDirPrepared = false
local function ensureCacheDir()
  if cacheDirPrepared then return end
  cacheDirPrepared = true
  if not noctalia.fileExists(cacheDir) then
    noctalia.runAsync("mkdir -p " .. shellQuote(cacheDir))
  end
end

local function getThumbPath(wallpaperPath)
  local h = 2166136261
  for i = 1, #wallpaperPath do
    h = bit32.bxor(h, string.byte(wallpaperPath, i))
    local lo = bit32.band(h, 0xFFFF) * 16777619
    local hi = bit32.band(bit32.rshift(h, 16), 0xFFFF) * 16777619
    h = bit32.band(lo + bit32.lshift(hi, 16), 0xFFFFFFFF)
  end
  local base = wallpaperPath:match("([^/]+)%.[^.]+$") or "wp"
  local safeBase = base:gsub("[^%w_%-]", "_"):sub(1, 24)
  return string.format("%s/%s_%08x.jpg", cacheDir, safeBase, h)
end

local function makeGenerateCmd(src, dst)
  return string.format(
    "[ -d %s ] || mkdir -p %s; if command -v magick >/dev/null 2>&1; then nice -n 19 magick %s -thumbnail 512x288\\> %s >/dev/null 2>&1; elif command -v convert >/dev/null 2>&1; then nice -n 19 convert %s -thumbnail 512x288\\> %s >/dev/null 2>&1; elif command -v ffmpeg >/dev/null 2>&1; then nice -n 19 ffmpeg -y -i %s -vf \"scale=512:288:force_original_aspect_ratio=decrease\" %s >/dev/null 2>&1; fi",
    shellQuote(cacheDir), shellQuote(cacheDir),
    shellQuote(src), shellQuote(dst),
    shellQuote(src), shellQuote(dst),
    shellQuote(src), shellQuote(dst)
  )
end

local render

local function resolveDisplayPath(originalPath)
  if not originalPath or originalPath == "" then return originalPath end
  ensureCacheDir()
  local thumb = getThumbPath(originalPath)
  if noctalia.fileExists(thumb) then
    return thumb
  end

  if not generatingPending[originalPath] then
    generatingPending[originalPath] = true
    local cmd = makeGenerateCmd(originalPath, thumb)
    noctalia.runAsync(cmd, function()
      generatingPending[originalPath] = nil
      if isOpen and noctalia.fileExists(thumb) and render then
        render()
      end
    end)
  end

  return originalPath
end

local function triggerBatchThumbnails()
  if batchRunning or #allWallpapers == 0 then return end
  ensureCacheDir()

  local missing = {}
  for _, wp in ipairs(allWallpapers) do
    local thumb = getThumbPath(wp.path)
    if not noctalia.fileExists(thumb) then
      table.insert(missing, { src = wp.path, dst = thumb })
    end
  end

  if #missing == 0 then return end
  batchRunning = true

  local chunkSize = 25
  local chunkIndex = 1

  local function processNextChunk()
    if chunkIndex > #missing then
      batchRunning = false
      return
    end

    local scriptParts = {
      "[ -d " .. shellQuote(cacheDir) .. " ] || mkdir -p " .. shellQuote(cacheDir) .. "; ",
      "if command -v magick >/dev/null 2>&1; then GEN=magick; ",
      "elif command -v convert >/dev/null 2>&1; then GEN=convert; ",
      "elif command -v ffmpeg >/dev/null 2>&1; then GEN=ffmpeg; ",
      "else exit 0; fi; ",
      "gen() { if [ ! -f \"$2\" ]; then if [ \"$GEN\" = \"ffmpeg\" ]; then nice -n 19 ffmpeg -y -i \"$1\" -vf \"scale=512:288:force_original_aspect_ratio=decrease\" \"$2\" >/dev/null 2>&1; else nice -n 19 \"$GEN\" \"$1\" -thumbnail 512x288\\> \"$2\" >/dev/null 2>&1; fi; fi; }; ",
    }

    local chunkEnd = math.min(chunkIndex + chunkSize - 1, #missing)
    for i = chunkIndex, chunkEnd do
      local item = missing[i]
      table.insert(scriptParts, string.format("gen %s %s; ", shellQuote(item.src), shellQuote(item.dst)))
    end

    chunkIndex = chunkEnd + 1
    local batchCmd = table.concat(scriptParts)

    noctalia.runAsync(batchCmd, function()
      if isOpen and render then
        render()
      end
      processNextChunk()
    end)
  end

  processNextChunk()
end

local function getWallpaperDir()
  local configured = noctalia.getConfig("wallpaper_dir")
  if type(configured) == "string" and configured ~= "" then
    return noctalia.expandPath(configured)
  end
  if noctalia.wallpaperDirectory then
    local ok, d = pcall(function() return noctalia.wallpaperDirectory() end)
    if ok and type(d) == "string" and d ~= "" then
      return d
    end
  end
  return home .. "/Pictures/wallpapers"
end

local function isImage(name)
  local lower = name:lower()
  return lower:match("%.png$") ~= nil
      or lower:match("%.jpg$") ~= nil
      or lower:match("%.jpeg$") ~= nil
      or lower:match("%.webp$") ~= nil
end

local function getCurrentWallpaper()
  if noctalia.wallpaperPath then
    local out = noctalia.focusedOutputName and noctalia.focusedOutputName()
    if out then
      local path = noctalia.wallpaperPath(out)
      if path and path ~= "" then return path end
    end
    if noctalia.outputs then
      for _, o in ipairs(noctalia.outputs()) do
        if o.name then
          local path = noctalia.wallpaperPath(o.name)
          if path and path ~= "" then return path end
        end
      end
    end
  end
  return nil
end

local function scanDirRecursive(dir, list, depth)
  if depth > 2 then return end
  local entries = noctalia.listDir(dir)
  if not entries then return end

  for _, name in ipairs(entries) do
    if name ~= "." and name ~= ".." and not name:match("^%.") then
      local fullPath = dir .. "/" .. name
      if isImage(name) then
        local cleanName = name:gsub("%.%w+$", "")
        table.insert(list, {
          path = fullPath,
          name = cleanName,
          filename = name,
          sortKey = makeSortKey(cleanName),
        })
      else
        local info = noctalia.fileInfo(fullPath)
        if info and info.isDir then
          scanDirRecursive(fullPath, list, depth + 1)
        end
      end
    end
  end
end

local function getDisplayedWallpaperAt(offset)
  local total = #allWallpapers
  if total == 0 then return nil, 1 end
  local idx = ((displayedIndex - 1 + offset) % total) + 1
  return allWallpapers[idx], idx
end

local function syncSelectedIndexToActive()
  if currentWallpaper == "" or #allWallpapers == 0 then return end
  for i, wp in ipairs(allWallpapers) do
    if wp.path == currentWallpaper then
      selectedIndex = i
      displayedIndex = i
      return
    end
  end
end

local function refreshActiveWallpaper(callback)
  local active = getCurrentWallpaper()
  if active and active ~= "" then
    currentWallpaper = active
    if callback then callback() end
    return
  end

  noctalia.runAsync("noctalia msg wallpaper-get", function(result)
    if result and result.exitCode == 0 and result.stdout then
      currentWallpaper = result.stdout:gsub("%s+$", "")
    end
    if callback then callback() end
  end, 1500)
end

local function loadWallpapers(forceRescan)
  if not forceRescan and #allWallpapers > 0 then
    local active = getCurrentWallpaper()
    if active and active ~= "" then
      currentWallpaper = active
      syncSelectedIndexToActive()
    end
    triggerBatchThumbnails()
    render()
    return
  end

  isScanning = true
  local dir = getWallpaperDir()
  local list = {}

  scanDirRecursive(dir, list, 0)

  if #list == 0 then
    local cmd = "find " .. shellQuote(dir) .. " -type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \\) 2>/dev/null"
    noctalia.runAsync(cmd, function(result)
      isScanning = false
      if result and result.exitCode == 0 and result.stdout then
        local fallbackList = {}
        for line in result.stdout:gmatch("[^\n]+") do
          local fname = line:match("([^/]+)$") or line
          local cname = fname:gsub("%.%w+$", "")
          table.insert(fallbackList, {
            path = line,
            name = cname,
            filename = fname,
            sortKey = makeSortKey(cname),
          })
        end
        table.sort(fallbackList, function(a, b)
          return a.sortKey < b.sortKey
        end)
        allWallpapers = fallbackList
        triggerBatchThumbnails()
      else
        allWallpapers = {}
      end
      refreshActiveWallpaper(function()
        syncSelectedIndexToActive()
        if isOpen and render then
          render()
        end
      end)
    end, 4000)
  else
    table.sort(list, function(a, b)
      return a.sortKey < b.sortKey
    end)
    allWallpapers = list
    isScanning = false
    triggerBatchThumbnails()
    refreshActiveWallpaper(function()
      syncSelectedIndexToActive()
      if isOpen and render then
        render()
      end
    end)
  end
end

local function applyWallpaper(path)
  currentWallpaper = path
  render()

  if noctalia.setWallpaper then
    noctalia.setWallpaper(path)
  else
    noctalia.runAsync("noctalia msg wallpaper-set " .. shellQuote(path))
  end

  if noctalia.getConfig("notify_on_change") ~= false then
    local fname = path:match("([^/]+)$") or path
    noctalia.notify(tr("panel.title"), tr("notify.switched") .. ": " .. fname)
  end

  if noctalia.getConfig("close_on_apply") == true then
    panel.close()
  end
end

local function applyRandom()
  if #allWallpapers == 0 then return end
  if #allWallpapers == 1 then
    selectedIndex = 1
    displayedIndex = 1
    applyWallpaper(allWallpapers[1].path)
    return
  end

  local curIdx = selectedIndex
  if currentWallpaper ~= "" then
    for i, wp in ipairs(allWallpapers) do
      if wp.path == currentWallpaper then
        curIdx = i
        break
      end
    end
  end

  local offset = math.random(1, #allWallpapers - 1)
  local randIdx = ((curIdx - 1 + offset) % #allWallpapers) + 1

  selectedIndex = randIdx
  displayedIndex = randIdx
  applyWallpaper(allWallpapers[randIdx].path)
end

local function cardsCached(centerIdx)
  local total = #allWallpapers
  if total == 0 then return true end
  local leftIdx = ((centerIdx - 2 + total) % total) + 1
  local rightIdx = (centerIdx % total) + 1
  return noctalia.fileExists(getThumbPath(allWallpapers[centerIdx].path))
     and noctalia.fileExists(getThumbPath(allWallpapers[leftIdx].path))
     and noctalia.fileExists(getThumbPath(allWallpapers[rightIdx].path))
end

local function scheduleDisplay()
  navToken = navToken + 1
  local currentToken = navToken

  render()

  noctalia.runAsync({"sleep", "0.040"}, function()
    if isOpen and navToken == currentToken then
      displayedIndex = selectedIndex
      render()
    end
  end)
end

local function stepSelection(delta)
  local total = #allWallpapers
  if total == 0 then return end
  selectedIndex = ((selectedIndex - 1 + delta) % total) + 1

  if cardsCached(selectedIndex) then
    displayedIndex = selectedIndex
    render()
  else
    scheduleDisplay()
  end
end

render = function()
  if isScanning then
    panel.render(ui.column({
      align = "center",
      justify = "center",
      flexGrow = 1,
      gap = 12,
      padding = 40,
    }, {
      ui.glyph({ name = "loader-2", size = 36, color = "primary" }),
      ui.label({ text = tr("panel.loading"), fontSize = 14, color = "on_surface_variant" }),
    }))
    return
  end

  if #allWallpapers == 0 then
    local dir = getWallpaperDir()
    panel.render(ui.column({
      align = "center",
      justify = "center",
      flexGrow = 1,
      gap = 12,
      padding = 40,
    }, {
      ui.glyph({ name = "photo-off", size = 48, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.empty"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = tr("panel.empty_hint"), fontSize = 13, color = "on_surface_variant" }),
      ui.label({ text = dir, fontSize = 11, color = "outline" }),
    }))
    return
  end

  local wpLeft, idxLeft = getDisplayedWallpaperAt(-1)
  local wpCenter = getDisplayedWallpaperAt(0)
  local wpRight, idxRight = getDisplayedWallpaperAt(1)

  local isSelectedActive = (allWallpapers[selectedIndex].path == currentWallpaper)

  local carouselRow = ui.row({
    align = "center",
    justify = "center",
    gap = 20,
    flexGrow = 1,
  }, {
    ui.column({
      key = "card-left",
      align = "center",
      width = 280,
      opacity = 0.55,
      onClick = function()
        selectedIndex = idxLeft
        displayedIndex = idxLeft
        render()
      end,
    }, {
      ui.image({
        key = "img-left",
        path = resolveDisplayPath(wpLeft.path),
        width = 280,
        height = 158,
        fit = "cover",
        radius = 12,
        borderWidth = (wpLeft.path == currentWallpaper) and 2 or 0,
        border = (wpLeft.path == currentWallpaper) and "primary" or nil,
      }),
    }),

    ui.column({
      key = "card-center",
      align = "center",
      width = 460,
      onClick = function()
        applyWallpaper(wpCenter.path)
      end,
    }, {
      ui.image({
        key = "img-center",
        path = resolveDisplayPath(wpCenter.path),
        width = 460,
        height = 259,
        fit = "cover",
        radius = 16,
        borderWidth = (wpCenter.path == currentWallpaper) and 3 or 1,
        border = (wpCenter.path == currentWallpaper) and "primary" or "outline",
      }),
    }),

    ui.column({
      key = "card-right",
      align = "center",
      width = 280,
      opacity = 0.55,
      onClick = function()
        selectedIndex = idxRight
        displayedIndex = idxRight
        render()
      end,
    }, {
      ui.image({
        key = "img-right",
        path = resolveDisplayPath(wpRight.path),
        width = 280,
        height = 158,
        fit = "cover",
        radius = 12,
        borderWidth = (wpRight.path == currentWallpaper) and 2 or 0,
        border = (wpRight.path == currentWallpaper) and "primary" or nil,
      }),
    }),
  })

  local infoSection = ui.column({
    align = "center",
    gap = 4,
  }, {
    ui.row({
      align = "center",
      justify = "center",
      height = 22,
    }, {
      isSelectedActive and ui.row({
        align = "center",
        gap = 4,
        paddingH = 8,
        paddingV = 2,
        radius = 10,
        fill = "primary/0.2",
      }, {
        ui.glyph({ name = "check", size = 13, color = "primary" }),
        ui.label({ text = tr("panel.active"), fontSize = 10, fontWeight = "bold", color = "primary" }),
      }) or nil,
    }),

    ui.label({
      text = tostring(selectedIndex) .. " / " .. tostring(#allWallpapers),
      fontSize = 12,
      color = "on_surface_variant",
    }),

    ui.label({
      text = tr("panel.hint"),
      fontSize = 11,
      color = "on_surface_variant",
    }),
  })

  panel.render(ui.column({
    padding = 24,
    gap = 14,
    align = "stretch",
    flexGrow = 1,
  }, {
    carouselRow,
    infoSection,
  }))
end

function onKey(chord, pressed)
  if not pressed then return end

  if chord == "Left" or chord == "Up" then
    stepSelection(-1)
  elseif chord == "Right" or chord == "Down" then
    stepSelection(1)
  elseif chord == "Return" then
    if #allWallpapers > 0 and selectedIndex >= 1 and selectedIndex <= #allWallpapers then
      displayedIndex = selectedIndex
      applyWallpaper(allWallpapers[selectedIndex].path)
    end
  elseif chord == "Space" then
    applyRandom()
  elseif chord == "Escape" then
    panel.close()
  end
end

local lastScrollTime = 0

function onScroll(axis, steps, _startsGesture)
  if axis ~= "vertical" then return end
  if #allWallpapers == 0 then return end
  local now = os.clock()
  if now - lastScrollTime < 0.12 then return end
  lastScrollTime = now

  if (steps or 0) > 0 then
    stepSelection(1)
  else
    stepSelection(-1)
  end
end

function onOpen(_context)
  isOpen = true
  local active = getCurrentWallpaper()
  if active and active ~= "" then
    currentWallpaper = active
    syncSelectedIndexToActive()
  end

  if #allWallpapers > 0 then
    displayedIndex = selectedIndex
    render()
  else
    loadWallpapers(false)
  end
end

function onClose()
  isOpen = false
end

loadWallpapers(false)
