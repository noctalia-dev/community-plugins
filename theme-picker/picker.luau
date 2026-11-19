--!nonstrict
-- Theme Picker — theme picker panel.
--
-- Vertical list of themes. Each row shows the theme's color scheme as a set of
-- color dots on the left and the first wallpaper of its category as a preview
-- on the right (about half the row width). Clicking a row applies the whole
-- combo (color scheme + wallpaper).

local HOME = noctalia.getenv("HOME") or "~"
local XDG_CACHE = noctalia.getenv("XDG_CACHE_HOME")
local CACHE_DIR = (XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or (HOME .. "/.cache")) .. "/noctalia/theme-picker/thumbnails"
local XDG_STATE = noctalia.getenv("XDG_STATE_HOME")
local STATE_ROOT = (XDG_STATE and XDG_STATE ~= "" and XDG_STATE or (HOME .. "/.local/state"))
local CATALOG = STATE_ROOT .. "/noctalia/community-palettes/.catalog/palettes.json"

local DATA_DIR = noctalia.pluginDataDir()
local THEMES_FILE = DATA_DIR .. "/themes.json"

local PANEL_WALLPAPERS = "SirQuacksALot/theme-picker:wallpapers"
local PANEL_MANAGER = "SirQuacksALot/theme-picker:manager"

local PREVIEW_WIDTH = 260
local ROW_HEIGHT = 96
local DOT_SIZE = 14

-- Builtin Noctalia palettes with representative colors for the dots.
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

local data = nil       -- themes.json contents: { version, active_theme, themes = { {...} } }
local schemes = nil    -- flat list: { source, id, name, colors = { primary, secondary, tertiary, error, surface } }
local selectedIndex = 0
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

local function findTheme(id)
  for _, t in ipairs(data.themes) do
    if t.id == id then return t end
  end
  return nil
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

-- Color dots for a theme's color scheme.
local function dotsFor(theme)
  local cs = theme.color_scheme
  local colors = nil
  if type(cs) == "table" and cs.source == "builtin" then
    for _, b in ipairs(BUILTIN) do
      if b.name == cs.id then colors = b.colors break end
    end
  end
  if colors == nil then
    for _, s in ipairs(schemes) do
      if s.source == (cs and cs.source) and s.id == (cs and cs.id) then colors = s.colors break end
    end
  end
  colors = colors or { primary = "#888888", secondary = "#888888", tertiary = "#888888", error = "#888888", surface = "#888888" }

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
  return ui.row({ gap = 6, align = "center" }, dots)
end

local function firstWallpaper(theme)
  if type(theme.wallpapers) == "table" and #theme.wallpapers > 0 then
    return theme.wallpapers[1]
  end
  return nil
end

local function pickWallpaper(theme)
  if type(theme.wallpapers) ~= "table" or #theme.wallpapers == 0 then return nil end
  if not theme.always_first and theme.last_wallpaper and theme.last_wallpaper ~= "" then
    for _, w in ipairs(theme.wallpapers) do
      if w == theme.last_wallpaper then return w end
    end
  end
  return theme.wallpapers[1]
end

local function applyTheme(theme)
  if theme == nil then return end
  data.active_theme = theme.id
  saveThemes()

  local cs = theme.color_scheme
  if type(cs) == "table" and cs.source and cs.id then
    noctalia.runAsync("noctalia msg color-scheme-set " .. cs.source .. " " .. shellQuote(cs.id))
  end

  local wp = pickWallpaper(theme)
  if wp then
    noctalia.setWallpaper(wp)
    if not theme.always_first then
      theme.last_wallpaper = wp
      saveThemes()
    end
  end

  if noctalia.getConfig("notify_on_change") ~= false then
    noctalia.notify(tr("picker.title"), tr("picker.applied") .. ": " .. theme.name)
  end
  render()
end

local function openWallpapers()
  panel.close()
  noctalia.togglePanel(PANEL_WALLPAPERS)
end

local function openManager()
  panel.close()
  noctalia.togglePanel(PANEL_MANAGER)
end

local function themeRow(theme, index)
  local isActive = data.active_theme == theme.id
  local wp = firstWallpaper(theme)
  local children = {
    ui.column({
      flexGrow = 1,
      gap = 8,
      align = "start",
      justify = "center",
    }, {
      ui.label({ text = theme.name, fontSize = 14, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      dotsFor(theme),
    }),
  }
  if wp then
    table.insert(children, ui.image({
      width = PREVIEW_WIDTH,
      height = ROW_HEIGHT - 16,
      path = resolveThumb(wp),
      fit = "cover",
      radius = 10,
      borderWidth = 1,
      border = "outline_variant",
    }))
  else
    table.insert(children, ui.column({
      width = PREVIEW_WIDTH,
      height = ROW_HEIGHT - 16,
      radius = 10,
      fill = "surface_container",
      align = "center",
      justify = "center",
    }, {
      ui.glyph({ name = "photo-off", size = 22, color = "on_surface_variant" }),
    }))
  end

  return ui.row({
    key = "theme-" .. theme.id .. (isActive and "-on" or "-off"),
    height = ROW_HEIGHT,
    gap = 14,
    paddingH = 14,
    paddingV = 8,
    radius = 14,
    align = "center",
    fill = isActive and "primary/0.12" or "surface",
    borderWidth = isActive and 2 or 1,
    border = isActive and "primary" or "outline_variant",
    onClick = function() applyTheme(theme) end,
  }, children)
end

render = function()
  if #data.themes == 0 then
    panel.render(ui.column({
      flexGrow = 1,
      align = "center",
      justify = "center",
      gap = 12,
      padding = 40,
    }, {
      ui.glyph({ name = "palette", size = 48, color = "on_surface_variant" }),
      ui.label({ text = tr("picker.empty"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = tr("picker.empty_hint"), fontSize = 13, color = "on_surface_variant" }),
      ui.button({ text = tr("picker.open_manager"), variant = "primary", onClick = openManager }),
    }))
    return
  end

  if selectedIndex < 1 or selectedIndex > #data.themes then selectedIndex = 1 end

  local rows = {}
  for i, theme in ipairs(data.themes) do
    table.insert(rows, themeRow(theme, i))
  end

  local headerChildren = {}
  if noctalia.getConfig("show_title_picker") ~= false then
    table.insert(headerChildren, ui.label({ text = tr("picker.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }))
    if noctalia.getConfig("show_nav_picker") ~= false then
      table.insert(headerChildren, ui.button({ text = tr("nav.wallpapers"), glyph = "photo", variant = "outline", onClick = openWallpapers }))
      table.insert(headerChildren, ui.button({ text = tr("nav.manager"), glyph = "settings", variant = "outline", onClick = openManager }))
    end
  end

  local footer = ui.label({
    text = tr("picker.hint"),
    fontSize = 11,
    color = "on_surface_variant",
  })

  local panelChildren = {}
  if #headerChildren > 0 then
    table.insert(panelChildren, ui.row({ align = "center", justify = "space_between", gap = 8 }, headerChildren))
  end
  table.insert(panelChildren, ui.scroll({ flexGrow = 1, gap = 10 }, rows))
  table.insert(panelChildren, footer)

  panel.render(ui.column({
    flexGrow = 1,
    gap = 12,
    align = "stretch",
    padding = 24,
  }, panelChildren))
end

function onKey(chord, pressed)
  if not pressed then return end
  if #data.themes == 0 then return end
  if chord == "Up" then
    selectedIndex = ((selectedIndex - 2) % #data.themes) + 1
    render()
  elseif chord == "Down" then
    selectedIndex = (selectedIndex % #data.themes) + 1
    render()
  elseif chord == "Return" or chord == "Enter" then
    applyTheme(data.themes[selectedIndex])
  elseif chord == "Escape" then
    panel.close()
  end
end

function onOpen(_context)
  isOpen = true
  data = loadThemes()
  schemes = loadSchemes()
  selectedIndex = 1
  for i, t in ipairs(data.themes) do
    if t.id == data.active_theme then selectedIndex = i break end
  end
  render()
end

function onClose()
  isOpen = false
end
