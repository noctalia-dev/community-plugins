--!nonstrict
-- Theme Picker — theme manager panel.
--
-- Left column lists all themes; the right column edits the selected theme
-- (name, color scheme, wallpaper set). Edits are persisted immediately.
-- Heavy setup (scheme catalog + wallpaper scan + thumbnail cache check) is
-- split across frame ticks, because a single Lua callback has a tight CPU
-- budget. Thumbnails are generated in the background in batches.

local HOME = noctalia.getenv("HOME") or "~"
local XDG_CACHE = noctalia.getenv("XDG_CACHE_HOME")
local CACHE_DIR = (XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or (HOME .. "/.cache")) .. "/noctalia/theme-picker/thumbnails"
local XDG_STATE = noctalia.getenv("XDG_STATE_HOME")
local STATE_ROOT = (XDG_STATE and XDG_STATE ~= "" and XDG_STATE or (HOME .. "/.local/state"))
local CATALOG = STATE_ROOT .. "/noctalia/community-palettes/.catalog/palettes.json"
local XDG_CONFIG = noctalia.getenv("XDG_CONFIG_HOME")
local CONFIG_ROOT = (XDG_CONFIG and XDG_CONFIG ~= "" and XDG_CONFIG or (HOME .. "/.config"))
local CUSTOM_DIR = CONFIG_ROOT .. "/noctalia/palettes"

local DATA_DIR = noctalia.pluginDataDir()
local THEMES_FILE = DATA_DIR .. "/themes.json"

local PANEL_PICKER = "SirQuacksALot/theme-picker:picker"
local PANEL_WALLPAPERS = "SirQuacksALot/theme-picker:wallpapers"

local DOT_SIZE = 14
local TILE_COLUMNS = 3
local TILE_GAP = 10
local TILE_W = 160
local TILE_H = 90

local BUILTIN = {
  { name = "Noctalia",    colors = { primary = "#a9aefe", secondary = "#fff59b", tertiary = "#f3edf7", error = "#e0534d", surface = "#0e0e43" } },
  { name = "Catppuccin",  colors = { primary = "#cba6f7", secondary = "#89b4fa", tertiary = "#a6e3a1", error = "#f38ba8", surface = "#1e1e2e" } },
  { name = "Dracula",     colors = { primary = "#bd93f9", secondary = "#8be9fd", tertiary = "#50fa7b", error = "#ff5555", surface = "#282a36" } },
  { name = "Eldritch",    colors = { primary = "#a48cf2", secondary = "#04d1f9", tertiary = "#37f499", error = "#f16c75", surface = "#212337" } },
  { name = "Gruvbox",     colors = { primary = "#fabd2f", secondary = "#83a598", tertiary = "#b8bb26", error = "#fb4934", surface = "#282828" } },
  { name = "Kanagawa",    colors = { primary = "#7e9cd8", secondary = "#e46876", tertiary = "#98bb6c", error = "#e82424", surface = "#1f1f28" } },
  { name = "Nord",        colors = { primary = "#88c0d0", secondary = "#81a1c1", tertiary = "#a3be8c", error = "#bf616a", surface = "#2e3440" } },
  { name = "Rose Pine",   colors = { primary = "#c4a7e7", secondary = "#eb6f92", tertiary = "#9ccfd8", error = "#eb6f92", surface = "#191724" } },
  { name = "Tokyo-Night", colors = { primary = "#7aa2f7", secondary = "#bb9af7", tertiary = "#9ece6a", error = "#f7768e", surface = "#1a1b26" } },
}

local data = nil
local schemes = nil
local customSchemes = nil
local editingId = nil
local dirWallpapers = nil
local batchRunning = false
local isOpen = false
local schemeSource = "builtin"
local initStage = 0  -- 0: load schemes, 1: scan + cache check, 2: render + batch, 3: done
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

local function saveThemes()
  noctalia.mkdirAll(DATA_DIR)
  local enc = noctalia.json.encode(data)
  if enc then noctalia.writeFile(THEMES_FILE, enc) end
end

local function loadSchemes()
  local list = {}
  for _, b in ipairs(BUILTIN) do
    table.insert(list, { source = "builtin", id = b.name, name = b.name, colors = b.colors })
  end
  local raw = noctalia.readFile(CATALOG)
  if raw then
    local catalog = noctalia.json.decode(raw)
    if type(catalog) == "table" then
      for _, e in ipairs(catalog) do
        if type(e) == "table" and type(e.name) == "string" then
          local dark = type(e.dark) == "table" and e.dark or {}
          local light = type(e.light) == "table" and e.light or {}
          table.insert(list, {
            source = "community",
            id = e.name,
            name = e.name,
            colors = {
              primary = dark.primary or light.primary or "#888888",
              secondary = dark.secondary or light.secondary or "#888888",
              tertiary = dark.tertiary or light.tertiary or "#888888",
              error = dark.error or light.error or "#888888",
              surface = dark.surface or light.surface or "#888888",
            },
          })
        end
      end
    end
  end
  return list
end

local function readColors(path)
  local fallback = { primary = "#888888", secondary = "#888888", tertiary = "#888888", error = "#888888", surface = "#888888" }
  local raw = noctalia.readFile(path)
  if not raw then return fallback end
  local d = noctalia.json.decode(raw)
  if type(d) ~= "table" then return fallback end
  local dark = type(d.dark) == "table" and d.dark or d
  return {
    primary = dark.mPrimary or dark.primary or "#888888",
    secondary = dark.mSecondary or dark.secondary or "#888888",
    tertiary = dark.mTertiary or dark.tertiary or "#888888",
    error = dark.mError or dark.error or "#888888",
    surface = dark.mSurface or dark.surface or "#888888",
  }
end

local function loadCustomSchemes()
  local list = {}
  local entries = noctalia.listDir(CUSTOM_DIR)
  if not entries then return list end
  for _, name in ipairs(entries) do
    if name ~= "." and name ~= ".." and not name:match("^%.") then
      local full = CUSTOM_DIR .. "/" .. name
      local info = noctalia.fileInfo(full)
      local colors = { primary = "#888888", secondary = "#888888", tertiary = "#888888", error = "#888888", surface = "#888888" }
      local label = name:gsub("^palettes%.", ""):gsub("%.[%w_]+$", "")
      if info and info.isDir then
        local sub = noctalia.listDir(full)
        if sub then
          for _, f in ipairs(sub) do
            if f:match("%.json$") then
              colors = readColors(full .. "/" .. f)
              break
            end
          end
        end
      else
        colors = readColors(full)
      end
      table.insert(list, { source = "custom", id = label, name = label, colors = colors })
    end
  end
  return list
end

local function editingTheme()
  if editingId == nil then return nil end
  for _, t in ipairs(data.themes) do
    if t.id == editingId then return t end
  end
  return nil
end

local function syncSourceToTheme()
  local t = editingTheme()
  local src = t and t.color_scheme and t.color_scheme.source
  if src == "builtin" or src == "community" or src == "custom" then
    schemeSource = src
  else
    schemeSource = "builtin"
  end
end

local function schemesForSource(source)
  local list = {}
  if source == "custom" then
    for _, s in ipairs(customSchemes or {}) do
      table.insert(list, s)
    end
  else
    for _, s in ipairs(schemes or {}) do
      if s.source == source then table.insert(list, s) end
    end
  end
  return list
end

local function syncThemeToSource()
  local theme = editingTheme()
  if theme == nil then return end
  local cs = theme.color_scheme
  local list = schemesForSource(schemeSource)
  if type(cs) == "table" and cs.source == schemeSource then
    for _, s in ipairs(list) do
      if s.id == cs.id then return end  -- still valid in this source
    end
  end
  -- not (or no longer) in the current source: fall back to the first entry
  if list[1] then
    theme.color_scheme = { source = list[1].source, id = list[1].id }
    saveThemes()
  end
end

local function colorsDots(colors)
  local order = { "primary", "secondary", "tertiary", "error", "surface" }
  local dots = {}
  for _, role in ipairs(order) do
    table.insert(dots, ui.box({
      width = DOT_SIZE,
      height = DOT_SIZE,
      radius = DOT_SIZE / 2,
      fill = colors[role] or "#888888",
      borderWidth = 1,
      border = "outline_variant",
    }))
  end
  return ui.row({ gap = 4, align = "center" }, dots)
end

local function schemeColors(cs)
  if type(cs) == "table" then
    for _, s in ipairs(schemes or {}) do
      if s.source == cs.source and s.id == cs.id then return s.colors end
    end
    for _, s in ipairs(customSchemes or {}) do
      if s.source == cs.source and s.id == cs.id then return s.colors end
    end
  end
  return { primary = "#888888", secondary = "#888888", tertiary = "#888888", error = "#888888", surface = "#888888" }
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

local function wallpaperDir()
  local dir = noctalia.wallpaperDirectory and noctalia.wallpaperDirectory()
  if type(dir) == "string" and dir ~= "" then return noctalia.expandPath(dir) end
  return noctalia.expandPath("~/Pictures/wallpapers")
end

local function isImage(name)
  local lower = name:lower()
  return lower:match("%.png$") ~= nil
      or lower:match("%.jpg$") ~= nil
      or lower:match("%.jpeg$") ~= nil
      or lower:match("%.webp$") ~= nil
end

local function scanDir(dir, list, depth)
  if depth > 3 then return end
  local entries = noctalia.listDir(dir)
  if not entries then return end
  for _, name in ipairs(entries) do
    if name ~= "." and name ~= ".." and not name:match("^%.") then
      local full = dir .. "/" .. name
      if isImage(name) then
        local cname = name:gsub("%.%w+$", "")
        table.insert(list, { path = full, name = cname, filename = name })
      else
        local info = noctalia.fileInfo(full)
        if info and info.isDir then
          scanDir(full, list, depth + 1)
        end
      end
    end
  end
end

local function scanDirWallpapers()
  local list = {}
  scanDir(wallpaperDir(), list, 0)
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  return list
end

-- Cache which thumbnails already exist so renders never hit the filesystem.
local function refreshThumbs()
  if dirWallpapers == nil then return end
  for _, item in ipairs(dirWallpapers) do
    local thumb = thumbPath(item.path)
    item.thumb = noctalia.fileExists(thumb) and thumb or nil
  end
end

-- Generate missing thumbnails in the background in chunks, then re-render once.
local function triggerBatchThumbnails()
  if batchRunning or dirWallpapers == nil then return end
  local missing = {}
  for _, item in ipairs(dirWallpapers) do
    if not item.thumb then
      table.insert(missing, { src = item.path, dst = thumbPath(item.path) })
    end
  end
  if #missing == 0 then return end
  batchRunning = true

  local chunkSize = 25
  local chunkIndex = 1

  local function processNext()
    if chunkIndex > #missing then
      batchRunning = false
      refreshThumbs()
      if isOpen and render then render() end
      return
    end

    local parts = {
      "[ -d " .. shellQuote(CACHE_DIR) .. " ] || mkdir -p " .. shellQuote(CACHE_DIR) .. "; ",
      "if command -v magick >/dev/null 2>&1; then GEN=magick; ",
      "elif command -v convert >/dev/null 2>&1; then GEN=convert; ",
      "elif command -v ffmpeg >/dev/null 2>&1; then GEN=ffmpeg; ",
      "else exit 0; fi; ",
      "gen() { if [ ! -f \"$2\" ]; then if [ \"$GEN\" = \"ffmpeg\" ]; then nice -n 19 ffmpeg -y -i \"$1\" -vf \"scale=512:288:force_original_aspect_ratio=decrease\" \"$2\" >/dev/null 2>&1; else nice -n 19 \"$GEN\" \"$1\" -thumbnail 512x288\\> \"$2\" >/dev/null 2>&1; fi; fi; }; ",
    }

    local chunkEnd = math.min(chunkIndex + chunkSize - 1, #missing)
    for i = chunkIndex, chunkEnd do
      local m = missing[i]
      table.insert(parts, "gen " .. shellQuote(m.src) .. " " .. shellQuote(m.dst) .. "; ")
    end
    chunkIndex = chunkEnd + 1

    noctalia.runAsync(table.concat(parts), processNext)
  end

  processNext()
end

local function inTheme(theme, path)
  for _, w in ipairs(theme.wallpapers) do
    if w == path then return true end
  end
  return false
end

local function addWallpaper(theme, path)
  if inTheme(theme, path) then return end
  table.insert(theme.wallpapers, path)
  saveThemes()
  render()
end

local function removeWallpaper(theme, path)
  for i, w in ipairs(theme.wallpapers) do
    if w == path then
      table.remove(theme.wallpapers, i)
      break
    end
  end
  if theme.last_wallpaper == path then theme.last_wallpaper = "" end
  saveThemes()
  render()
end

local function newTheme()
  local t = {
    id = "theme-" .. tostring(noctalia.nowMs()),
    name = tr("manager.default_name"),
    color_scheme = { source = "builtin", id = "Noctalia" },
    wallpapers = {},
    last_wallpaper = "",
    always_first = false,
  }
  table.insert(data.themes, t)
  editingId = t.id
  data.active_theme = t.id
  saveThemes()
  render()
end

local function deleteTheme(theme)
  for i, x in ipairs(data.themes) do
    if x.id == theme.id then
      table.remove(data.themes, i)
      break
    end
  end
  if data.active_theme == theme.id then data.active_theme = nil end
  if editingId == theme.id then
    editingId = data.themes[1] and data.themes[1].id or nil
  end
  saveThemes()
  render()
end

local function openPicker()
  panel.close()
  noctalia.togglePanel(PANEL_PICKER)
end

local function openWallpapers()
  panel.close()
  noctalia.togglePanel(PANEL_WALLPAPERS)
end

local function sourceButton(source, label)
  return ui.button({
    text = label,
    variant = schemeSource == source and "primary" or "outline",
    onClick = function()
      schemeSource = source
      syncThemeToSource()
      render()
    end,
  })
end

local function themeListRow(theme)
  local isActive = data.active_theme == theme.id
  local isEditing = editingId == theme.id
  return ui.row({
    key = "theme-" .. theme.id .. (isEditing and "-on" or "-off"),
    gap = 8,
    paddingH = 10,
    paddingV = 8,
    radius = 10,
    align = "center",
    fill = isEditing and "primary/0.12" or "surface",
    borderWidth = isEditing and 2 or 1,
    border = isEditing and "primary" or "outline_variant",
    onClick = function()
      editingId = theme.id
      syncSourceToTheme()
      render()
    end,
  }, {
    ui.label({ text = theme.name, flexGrow = 1, fontSize = 13, color = "on_surface", maxLines = 1 }),
    isActive and ui.glyph({ name = "check", size = 14, color = "primary" }) or nil,
  })
end

local function wallpaperTile(theme, item)
  local added = inTheme(theme, item.path)
  local preview
  if item.thumb then
    preview = ui.image({ path = item.thumb, width = TILE_W, height = TILE_H, fit = "cover", radius = 8, borderWidth = added and 2 or 1, border = added and "primary" or "outline_variant" })
  else
    preview = ui.box({ width = TILE_W, height = TILE_H, radius = 8, fill = "surface_container", borderWidth = added and 2 or 1, border = added and "primary" or "outline_variant" })
  end
  return ui.column({
    key = "wp-" .. item.path .. (added and "-on" or "-off"),
    opacity = added and 1 or 0.8,
    onClick = function()
      if added then removeWallpaper(theme, item.path) else addWallpaper(theme, item.path) end
    end,
  }, {
    preview,
  })
end

local function wallpaperGrid(theme)
  local rows = {}
  local row = {}
  for _, item in ipairs(dirWallpapers) do
    table.insert(row, wallpaperTile(theme, item))
    if #row == TILE_COLUMNS then
      table.insert(rows, ui.row({ gap = TILE_GAP, align = "start" }, row))
      row = {}
    end
  end
  if #row > 0 then
    table.insert(rows, ui.row({ gap = TILE_GAP, align = "start" }, row))
  end
  return ui.column({ gap = TILE_GAP }, rows)
end

local function editor()
  local theme = editingTheme()
  if theme == nil then
    return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "palette", size = 40, color = "on_surface_variant" }),
      ui.label({ text = tr("manager.no_selection"), fontSize = 13, color = "on_surface_variant" }),
    })
  end

  if schemes == nil or dirWallpapers == nil then
    return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "loader-2", size = 28, color = "on_surface_variant" }),
      ui.label({ text = tr("manager.loading"), fontSize = 13, color = "on_surface_variant" }),
    })
  end

  local wallpapers = type(theme.wallpapers) == "table" and theme.wallpapers or {}
  theme.wallpapers = wallpapers

  local sourceSchemes = schemesForSource(schemeSource)

  local schemeNames = {}
  for _, s in ipairs(sourceSchemes) do
    table.insert(schemeNames, s.name)
  end
  local schemeIdx = 0
  local cs = theme.color_scheme
  if type(cs) == "table" then
    for i, s in ipairs(sourceSchemes) do
      if s.source == cs.source and s.id == cs.id then
        schemeIdx = i - 1
        break
      end
    end
  end

  local schemeWidget
  if #sourceSchemes > 0 then
    schemeWidget = ui.select({
      key = "scheme-" .. theme.id .. "-" .. schemeSource,
      options = schemeNames,
      selectedIndex = schemeIdx,
      width = 360,
      onChange = function(index, _text)
        local s = sourceSchemes[(tonumber(index) or 0) + 1]
        if s then
          theme.color_scheme = { source = s.source, id = s.id }
          saveThemes()
          render()
        end
      end,
    })
  else
    schemeWidget = ui.label({ text = tr("manager.no_schemes"), fontSize = 12, color = "on_surface_variant" })
  end

  local children = {
    ui.label({ text = tr("manager.name"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
    ui.input({
      key = "name-" .. theme.id,
      placeholder = tr("manager.name_placeholder"),
      value = theme.name,
      width = 360,
      onChange = function(v)
        theme.name = v
        saveThemes()
      end,
    }),

    ui.label({ text = tr("manager.scheme"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
    ui.row({ gap = 6 }, {
      sourceButton("builtin", tr("manager.source_builtin")),
      sourceButton("community", tr("manager.source_community")),
      sourceButton("custom", tr("manager.source_custom")),
    }),
    schemeWidget,
    colorsDots(schemeColors(theme.color_scheme)),

    ui.row({
      key = "always-" .. theme.id .. (theme.always_first and "-on" or "-off"),
      align = "center",
      gap = 10,
      paddingV = 4,
      onClick = function()
        theme.always_first = not theme.always_first
        saveThemes()
        render()
      end,
    }, {
      ui.label({ text = tr("manager.always_first"), flexGrow = 1, fontSize = 12, color = "on_surface" }),
      ui.column({
        width = 40,
        height = 22,
        radius = 11,
        fill = theme.always_first and "primary" or "surface_container",
        align = theme.always_first and "end" or "start",
        justify = "center",
        paddingH = 2,
      }, {
        ui.box({ width = 18, height = 18, radius = 9, fill = "surface" }),
      }),
    }),

    ui.separator({ spacing = 4 }),

    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr("manager.wallpapers") .. " (" .. tostring(#wallpapers) .. ")", fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
      ui.label({ text = tr("manager.toggle_hint"), fontSize = 11, color = "on_surface_variant" }),
    }),

    ui.scroll({ flexGrow = 1, gap = TILE_GAP }, { wallpaperGrid(theme) }),

    ui.separator({ spacing = 4 }),

    ui.button({
      text = tr("manager.delete"),
      glyph = "trash",
      variant = "destructive",
      onClick = function() deleteTheme(theme) end,
    }),
  }

  return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children)
end

render = function()
  local leftRows = {}
  for _, theme in ipairs(data.themes) do
    table.insert(leftRows, themeListRow(theme))
  end

  local left = ui.column({ width = 220, gap = 10, align = "stretch" }, {
    ui.label({ text = tr("manager.themes"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
    ui.scroll({ flexGrow = 1, gap = 6 }, leftRows),
    ui.button({ text = tr("manager.new_theme"), glyph = "plus", variant = "primary", onClick = newTheme }),
  })

  local headerChildren = {}
  if noctalia.getConfig("show_title_manager") ~= false then
    table.insert(headerChildren, ui.label({ text = tr("manager.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }))
    if noctalia.getConfig("show_nav_manager") ~= false then
      table.insert(headerChildren, ui.button({ text = tr("nav.themes"), glyph = "palette", variant = "outline", onClick = openPicker }))
      table.insert(headerChildren, ui.button({ text = tr("nav.wallpapers"), glyph = "photo", variant = "outline", onClick = openWallpapers }))
    end
  end

  local panelChildren = {}
  if #headerChildren > 0 then
    table.insert(panelChildren, ui.row({ align = "center", justify = "space_between", gap = 8 }, headerChildren))
  end
  table.insert(panelChildren, ui.row({ flexGrow = 1, gap = 16, align = "stretch" }, {
    left,
    editor(),
  }))

  panel.render(ui.column({
    flexGrow = 1,
    gap = 12,
    align = "stretch",
    padding = 24,
  }, panelChildren))
end

function onKey(chord, pressed)
  if not pressed then return end
  if chord == "Escape" then
    panel.close()
  end
end

function onOpen(_context)
  isOpen = true
  data = loadThemes()
  schemes = nil
  customSchemes = nil
  editingId = data.active_theme or (data.themes[1] and data.themes[1].id or nil)
  dirWallpapers = nil
  syncSourceToTheme()
  initStage = 0
  panel.setNeedsFrameTick(true)
  render()
end

function onFrameTick(_deltaMs)
  if initStage == 0 then
    initStage = 1
    schemes = loadSchemes()
    customSchemes = loadCustomSchemes()
  elseif initStage == 1 then
    initStage = 2
    dirWallpapers = scanDirWallpapers()
    refreshThumbs()
  elseif initStage == 2 then
    initStage = 3
    render()
    triggerBatchThumbnails()
    panel.setNeedsFrameTick(false)
  else
    panel.setNeedsFrameTick(false)
  end
end

function onClose()
  isOpen = false
end
