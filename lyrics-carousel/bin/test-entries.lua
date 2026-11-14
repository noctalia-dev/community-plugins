-- Smoke tests for the entry points (widget.luau, panel.luau, desktop.luau),
-- runnable with Lua 5.4.
--
-- Each entry is loaded in its own environment with the host simulated, so a
-- mistake in the wiring (a state key read with the wrong name, a tree built
-- with the wrong options) fails here instead of in the shell.
--
-- Usage: lua5.4 bin/test-entries.lua [render.luau lyrics.luau state.luau]

local renderPath = arg[1] or "lib/render.luau"
local lyricsPath = arg[2] or "lib/lyrics.luau"
local statePath = arg[3] or "lib/state.luau"

local checks = 0
local failures = 0

local function check(condition, message)
  checks = checks + 1
  if not condition then
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
  end
end

local function eq(current, expected, message)
  check(
    current == expected,
    string.format("%s (got %s, expected %s)", message, tostring(current), tostring(expected))
  )
end

local modules = {
  ["./lib/render.luau"] = dofile(renderPath),
  ["./lib/lyrics.luau"] = dofile(lyricsPath),
  ["./lib/state.luau"] = dofile(statePath),
}

local realRequire = require

-- Host simulation -------------------------------------------------------

-- Same shape as the host's controls: a kind, its properties and its children.
local function node(kind)
  return function(props, children)
    return { kind = kind, props = props or {}, children = children or {} }
  end
end

local ui = {
  column = node("column"),
  row = node("row"),
  label = node("label"),
  box = node("box"),
  glyph = node("glyph"),
  scroll = node("scroll"),
  button = node("button"),
  toggle = node("toggle"),
  slider = node("slider"),
  input = node("input"),
}

local CONFIG = {
  font_size = 22,
  direction = "down",
  marker = false,
  marker_style = 0,
  karaoke = true,
  ghost = true,
  header = true,
  footer = true,
  spacing = 2,
  active_scale = 1.35,
  visible_above = 2,
  visible_below = 2,
  accent = "primary",
  custom_color = "#e46767",
  offset_ms = 0,
  instrumental = true,
  instrumental_icon = 0,
  instrumental_text = "",
  silence_threshold = 4,
}

-- Two lines, so the position decides which one is active.
local LINES = {
  { start = 0, ["end"] = 5, text = "first line" },
  { start = 5, ["end"] = 10, text = "second line" },
  { start = 10, ["end"] = 15, text = "third line" },
}

-- The service reads `positionAtMs` at `nowMs`; here both are 1000, so the
-- position is exactly `positionMs`.
local function track(positionMs, playing)
  return {
    title = "Song",
    artist = "Band",
    duration = 30,
    playing = playing ~= false,
    positionMs = positionMs or 6000,
    positionAtMs = 1000,
    key = "Song\x1fBand\x1f30",
  }
end

local function baseEnv(record)
  local env = {
    ui = ui,
    pairs = pairs,
    ipairs = ipairs,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    math = math,
    string = string,
    table = table,
    require = function(name)
      local module = modules[name]
      if module ~= nil then
        return module
      end
      return realRequire(name)
    end,
    noctalia = {
      setUpdateInterval = function(ms)
        record.interval = ms
      end,
      state = {
        get = function(key)
          return record.store[key]
        end,
        set = function(key, value)
          record.store[key] = value
        end,
        watch = function()
        end,
      },
      getConfig = function(key)
        return CONFIG[key]
      end,
      tr = function(key)
        return key
      end,
      nowMs = function()
        return 1000
      end,
      openPanel = function(id)
        record.opened = id
      end,
      log = function()
      end,
      json = {
        decode = function()
          return nil
        end,
      },
    },
  }
  return env
end

local function loadEntry(path, env)
  local chunk = assert(loadfile(path, "t", env))
  chunk()
  return env
end

local function textOf(target, parts)
  parts = parts or {}
  if type(target) ~= "table" then
    return table.concat(parts, "")
  end
  if target.kind == "label" and target.props ~= nil then
    parts[#parts + 1] = tostring(target.props.text or "")
  end
  for _, child in ipairs(target.children or {}) do
    textOf(child, parts)
  end
  return table.concat(parts, "")
end

local function countKinds(target, kind)
  local total = 0
  if type(target) ~= "table" then
    return 0
  end
  if target.kind == kind then
    total = total + 1
  end
  for _, child in ipairs(target.children or {}) do
    total = total + countKinds(child, kind)
  end
  return total
end

local function widget(trackValue, lyricsValue, loading)
  local record = { store = {}, trees = 0 }
  if trackValue ~= nil then
    record.store.track = trackValue
  end
  if lyricsValue ~= nil then
    record.store.lyrics = lyricsValue
  end
  record.store.loading = loading == true
  local env = baseEnv(record)
  env.barWidget = {
    render = function(target)
      record.tree = target
      record.trees = record.trees + 1
    end,
    setTooltip = function(text)
      record.tooltip = text
    end,
  }
  loadEntry("widget.luau", env)
  return record, env
end

local function panel(trackValue, lyricsValue, loading)
  local record = { store = {}, trees = 0 }
  if trackValue ~= nil then
    record.store.track = trackValue
  end
  if lyricsValue ~= nil then
    record.store.lyrics = lyricsValue
  end
  record.store.loading = loading == true
  local env = baseEnv(record)
  env.panel = {
    render = function(target)
      record.tree = target
      record.trees = record.trees + 1
    end,
    close = function()
      record.closed = true
    end,
  }
  loadEntry("panel.luau", env)
  return record, env
end

local sync = { synced = true, lines = LINES }

-- The bar widget ---------------------------------------------------------

local bar, barEnv = widget(nil, nil, false)
eq(bar.trees, 1, "widget: it draws once when it loads")
eq(countKinds(bar.tree, "glyph"), 1, "widget: without a track it shows the note")
eq(bar.tooltip, "nothing_playing", "widget: without a track the tooltip says so")

bar.store.track = track(6000)
bar.store.lyrics = sync
barEnv.update()
eq(textOf(bar.tree), "second line", "widget: it shows the line playing now")
check(countKinds(bar.tree, "row") >= 1, "widget: the line is laid out in a row")

bar.store.track = track(11000)
barEnv.update()
eq(textOf(bar.tree), "third line", "widget: it follows the song")

-- A paused song keeps the position it was published with.
bar.store.track = track(11000, false)
barEnv.update()
eq(textOf(bar.tree), "third line", "widget: a paused song keeps its line")

bar.store.track = nil
bar.store.lyrics = nil
barEnv.update()
eq(countKinds(bar.tree, "glyph"), 1, "widget: losing the player brings the note back")

barEnv.onClick()
eq(bar.opened, "faminec/lyrics-carousel:panel", "widget: clicking opens the panel")

bar.store.track = track(6000)
bar.store.lyrics = sync
local before = bar.trees
barEnv.onIpc("refresh", nil)
check(bar.trees > before, "widget: the refresh IPC redraws")

-- The panel --------------------------------------------------------------

local view, panelEnv = panel(nil, nil, false)
check(view.tree == nil, "panel: it draws nothing before it opens")

panelEnv.onOpen()
eq(view.interval, 33, "panel: opening it asks for the fine tick")
check(view.tree ~= nil, "panel: opening it draws")
check(textOf(view.tree):find("nothing_playing", 1, true) ~= nil, "panel: without a track it explains why")

view.store.track = track(6000)
view.store.lyrics = sync
panelEnv.update()
local text = textOf(view.tree)
check(text:find("second line", 1, true) ~= nil, "panel: it shows the active line")
check(text:find("first line", 1, true) ~= nil, "panel: it shows the previous line")
check(text:find("Song", 1, true) ~= nil, "panel: the header shows the title")
check(text:find("Band", 1, true) ~= nil, "panel: the header shows the artist")
check(text:find("0:06 / 0:30", 1, true) ~= nil, "panel: the footer shows the time")

view.store.lyrics = nil
view.store.loading = true
panelEnv.update()
check(
  textOf(view.tree):find("searching_lyrics", 1, true) ~= nil,
  "panel: while searching it says so"
)

local drawn = view.trees
panelEnv.onClose()
eq(view.interval, 1000, "panel: closing it gives the tick back")
panelEnv.update()
eq(view.trees, drawn, "panel: a closed panel does not redraw")

-- The desktop widget ------------------------------------------------------

local function desktop(trackValue, lyricsValue, loading)
  local record = { store = {}, trees = 0 }
  if trackValue ~= nil then
    record.store.track = trackValue
  end
  if lyricsValue ~= nil then
    record.store.lyrics = lyricsValue
  end
  record.store.loading = loading == true
  local env = baseEnv(record)
  env.desktopWidget = {
    render = function(target)
      record.tree = target
      record.trees = record.trees + 1
    end,
    setNeedsFrameTick = function()
    end,
    setVisible = function()
    end,
  }
  loadEntry("desktop.luau", env)
  return record, env
end

local wallpaper, desktopEnv = desktop(track(6000), sync, false)
eq(wallpaper.trees, 1, "desktop: it draws once when it loads")
check(
  textOf(wallpaper.tree):find("second line", 1, true) ~= nil,
  "desktop: it shows the active line"
)
check(
  textOf(wallpaper.tree):find("Song", 1, true) ~= nil,
  "desktop: it shows the same header as the panel"
)

local wallpaperBefore = wallpaper.trees
desktopEnv.onIpc("refresh", nil)
check(wallpaper.trees > wallpaperBefore, "desktop: the refresh IPC redraws")

wallpaper.store.track = nil
wallpaper.store.lyrics = nil
desktopEnv.update()
check(
  textOf(wallpaper.tree):find("nothing_playing", 1, true) ~= nil,
  "desktop: without a player it explains why"
)

-- The control-center tile -------------------------------------------------

local function shortcutEntry(brain)
  local record = { store = { brain = brain } }
  local env = baseEnv(record)
  env.shortcut = {
    setLabel = function(text)
      record.label = text
    end,
    setIcon = function(name)
      record.icon = name
    end,
    setActive = function(value)
      record.active = value
    end,
  }
  loadEntry("shortcut.luau", env)
  return record, env
end

local tile, tileEnv = shortcutEntry(true)
eq(tile.active, true, "shortcut: the tile starts active")
eq(tile.label, "shortcut.glow_on", "shortcut: the tile says the fill is on")
eq(tile.icon, "music", "shortcut: the tile carries a glyph")

tileEnv.onClick()
eq(tile.store.brain, false, "shortcut: a click turns the fill off")
eq(tile.label, "shortcut.glow_off", "shortcut: the tile says the fill is off")
eq(tile.active, false, "shortcut: the tile turns inactive")

tileEnv.onClick()
eq(tile.store.brain, true, "shortcut: a second click turns it back on")

-- Result ------------------------------------------------------------------

if failures > 0 then
  io.stderr:write(string.format("%d of %d checks failed\n", failures, checks))
  os.exit(1)
end
print(string.format("%d checks passed", checks))
