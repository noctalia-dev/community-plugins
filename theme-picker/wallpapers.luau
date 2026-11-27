--!nonstrict
-- Theme Picker — categorized wallpaper picker panel.
--
-- A horizontal carousel identical in behaviour to the community
-- "wallpaper-widget" plugin, but scoped to the wallpapers of the currently
-- selected theme's category. Applying a wallpaper also remembers it as the
-- theme's last-used wallpaper (unless the theme forces the first wallpaper).

local HOME = noctalia.getenv("HOME") or "~"
local XDG_CACHE = noctalia.getenv("XDG_CACHE_HOME")
local CACHE_DIR = (XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or (HOME .. "/.cache")) .. "/noctalia/theme-picker/thumbnails"

local DATA_DIR = noctalia.pluginDataDir()
local THEMES_FILE = DATA_DIR .. "/themes.json"

local PANEL_PICKER = "SirQuacksALot/theme-picker:picker"
local PANEL_MANAGER = "SirQuacksALot/theme-picker:manager"

local selectedIndex = 1
local displayedIndex = 1
local allWallpapers = {}
local theme = nil
local currentWallpaper = ""
local isOpen = false
local pending = {}
local render

local function tr(key)
  return noctalia.tr(key)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function loadThemes()
  local raw = noctalia.readFile(THEMES_FILE)
  if raw then
    local d = noctalia.json.decode(raw)
    if type(d) == "table" then
      if type(d.themes) ~= "table" then d.themes = {} end
      return d
    end
  end
  return { version = 1, active_theme = nil, themes = {} }
end

local function saveThemes(data)
  noctalia.mkdirAll(DATA_DIR)
  local enc = noctalia.json.encode(data)
  if enc then noctalia.writeFile(THEMES_FILE, enc) end
end

local function thumbPath(wpPath)
  local h = 2166136261
  for i = 1, #wpPath do
    h = bit32.bxor(h, string.byte(wpPath, i))
    local lo = bit32.band(h, 0xFFFF) * 16777619
    local hi = bit32.band(bit32.rshift(h, 16), 0xFFFF) * 16777619
    h = bit32.band(lo + bit32.lshift(hi, 16), 0xFFFFFFFF)
  end
  local base = wpPath:match("([^/]+)%.[^.]+$") or "wp"
  local safe = base:gsub("[^%w_%-]", "_"):sub(1, 24)
  return string.format("%s/%s_%08x.jpg", CACHE_DIR, safe, h)
end

local function makeGenerateCmd(src, dst)
  return string.format(
    "[ -d %s ] || mkdir -p %s; if command -v magick >/dev/null 2>&1; then nice -n 19 magick %s -thumbnail 512x288\\> %s >/dev/null 2>&1; elif command -v convert >/dev/null 2>&1; then nice -n 19 convert %s -thumbnail 512x288\\> %s >/dev/null 2>&1; elif command -v ffmpeg >/dev/null 2>&1; then nice -n 19 ffmpeg -y -i %s -vf \"scale=512:288:force_original_aspect_ratio=decrease\" %s >/dev/null 2>&1; fi",
    shellQuote(CACHE_DIR), shellQuote(CACHE_DIR),
    shellQuote(src), shellQuote(dst),
    shellQuote(src), shellQuote(dst),
    shellQuote(src), shellQuote(dst)
  )
end

local function resolveThumb(wpPath)
  if not wpPath or wpPath == "" then return wpPath end
  local thumb = thumbPath(wpPath)
  if noctalia.fileExists(thumb) then return thumb end
  if not pending[wpPath] then
    pending[wpPath] = true
    noctalia.runAsync(makeGenerateCmd(wpPath, thumb), function()
      pending[wpPath] = nil
      if isOpen and render then render() end
    end)
  end
  return wpPath
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

local function buildWallpapersFromTheme(t)
  local list = {}
  if type(t.wallpapers) == "table" then
    for _, path in ipairs(t.wallpapers) do
      if type(path) == "string" and path ~= "" then
        local fname = path:match("([^/]+)$") or path
        local cname = fname:gsub("%.%w+$", "")
        table.insert(list, { path = path, name = cname, filename = fname })
      end
    end
  end
  return list
end

local function syncToCurrentWallpaper()
  if currentWallpaper == "" or #allWallpapers == 0 then return end
  for i, wp in ipairs(allWallpapers) do
    if wp.path == currentWallpaper then
      selectedIndex = i
      displayedIndex = i
      return
    end
  end
end

local function loadWallpapers()
  local data = loadThemes()
  local activeId = data.active_theme
  local found = nil
  if activeId then
    for _, t in ipairs(data.themes) do
      if t.id == activeId then found = t break end
    end
  end
  theme = found
  allWallpapers = found and buildWallpapersFromTheme(found) or {}
  selectedIndex = 1
  displayedIndex = 1
  currentWallpaper = ""

  local active = getCurrentWallpaper()
  if active and active ~= "" then
    currentWallpaper = active
    syncToCurrentWallpaper()
    render()
    return
  end

  -- Fall back to the daemon's default wallpaper path.
  noctalia.runAsync("noctalia msg wallpaper-get", function(result)
    if result and result.exitCode == 0 and result.stdout then
      currentWallpaper = result.stdout:gsub("%s+$", "")
      syncToCurrentWallpaper()
    end
    if isOpen and render then render() end
  end, 1500)
  render()
end

local function getDisplayedWallpaperAt(offset)
  local total = #allWallpapers
  if total == 0 then return nil, 1 end
  local idx = ((displayedIndex - 1 + offset) % total) + 1
  return allWallpapers[idx], idx
end

local function applyWallpaper(path)
  currentWallpaper = path
  render()
  noctalia.setWallpaper(path)

  if theme and not theme.always_first then
    theme.last_wallpaper = path
    local data = loadThemes()
    for _, t in ipairs(data.themes) do
      if t.id == theme.id then t.last_wallpaper = path break end
    end
    saveThemes(data)
  end

  if noctalia.getConfig("notify_on_change") ~= false then
    local fname = path:match("([^/]+)$") or path
    noctalia.notify(tr("wallpapers.title"), tr("wallpapers.switched") .. ": " .. fname)
  end

  if noctalia.getConfig("close_on_apply") == true then
    panel.close()
  end
end

local function applyRandom()
  if #allWallpapers == 0 then return end
  local randIdx = math.random(1, #allWallpapers)
  selectedIndex = randIdx
  displayedIndex = randIdx
  applyWallpaper(allWallpapers[randIdx].path)
end

local function stepSelection(delta)
  local total = #allWallpapers
  if total == 0 then return end
  selectedIndex = ((selectedIndex - 1 + delta) % total) + 1
  displayedIndex = selectedIndex
  render()
end

local function openPicker()
  panel.close()
  noctalia.togglePanel(PANEL_PICKER)
end

local function openManager()
  panel.close()
  noctalia.togglePanel(PANEL_MANAGER)
end

local function emptyState(glyphName, title, hint)
  return ui.column({
    align = "center",
    justify = "center",
    flexGrow = 1,
    gap = 12,
    padding = 40,
  }, {
    ui.glyph({ name = glyphName, size = 48, color = "on_surface_variant" }),
    ui.label({ text = title, fontSize = 15, fontWeight = "bold", color = "on_surface" }),
    ui.label({ text = hint, fontSize = 13, color = "on_surface_variant" }),
    ui.button({ text = tr("wallpapers.back"), variant = "primary", onClick = openPicker }),
  })
end

local function buildHeader()
  local children = {}
  if noctalia.getConfig("show_title_wallpapers") ~= false then
    table.insert(children, ui.label({ text = tr("wallpapers.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }))
    if theme then
      table.insert(children, ui.label({ text = theme.name, fontSize = 12, color = "on_surface_variant" }))
    end
    if noctalia.getConfig("show_nav_wallpapers") ~= false then
      table.insert(children, ui.button({ text = tr("nav.themes"), glyph = "palette", variant = "outline", onClick = openPicker }))
      table.insert(children, ui.button({ text = tr("nav.manager"), glyph = "settings", variant = "outline", onClick = openManager }))
    end
  end
  if #children == 0 then return nil end
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, children)
end

render = function()
  local header = buildHeader()

  if theme == nil then
    local panelChildren = {}
    if header then table.insert(panelChildren, header) end
    table.insert(panelChildren, emptyState("photo-off", tr("wallpapers.no_theme"), tr("wallpapers.no_theme_hint")))
    panel.render(ui.column({
      flexGrow = 1,
      gap = 12,
      align = "stretch",
      padding = 24,
    }, panelChildren))
    return
  end

  if #allWallpapers == 0 then
    local panelChildren = {}
    if header then table.insert(panelChildren, header) end
    table.insert(panelChildren, emptyState("photo-off", tr("wallpapers.empty"), tr("wallpapers.empty_hint")))
    panel.render(ui.column({
      flexGrow = 1,
      gap = 12,
      align = "stretch",
      padding = 24,
    }, panelChildren))
    return
  end

  local wpLeft, idxLeft = getDisplayedWallpaperAt(-1)
  local wpCenter = getDisplayedWallpaperAt(0)
  local wpRight, idxRight = getDisplayedWallpaperAt(1)

  local carouselRow = ui.row({
    align = "center",
    justify = "center",
    gap = 20,
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
        path = resolveThumb(wpLeft.path),
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
        path = resolveThumb(wpCenter.path),
        width = 460,
        height = 259,
        fit = "cover",
        radius = 16,
        borderWidth = (wpCenter.path == currentWallpaper) and 3 or 1,
        border = (wpCenter.path == currentWallpaper) and "primary" or "outline_variant",
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
        path = resolveThumb(wpRight.path),
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
    ui.label({
      text = tostring(selectedIndex) .. " / " .. tostring(#allWallpapers),
      fontSize = 12,
      color = "on_surface_variant",
    }),
    ui.label({
      text = tr("wallpapers.hint"),
      fontSize = 11,
      color = "on_surface_variant",
    }),
  })

  local panelChildren = {}
  if header then table.insert(panelChildren, header) end
  table.insert(panelChildren, carouselRow)
  table.insert(panelChildren, infoSection)

  panel.render(ui.column({
    padding = 24,
    gap = 14,
    align = "stretch",
    flexGrow = 1,
  }, panelChildren))
end

function onKey(chord, pressed)
  if not pressed then return end
  if chord == "Left" or chord == "Up" then
    stepSelection(-1)
  elseif chord == "Right" or chord == "Down" then
    stepSelection(1)
  elseif chord == "Return" or chord == "Enter" then
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
  loadWallpapers()
end

function onClose()
  isOpen = false
end

math.randomseed(math.floor((os.clock() * 1000000) % 2147483647) + os.time())
