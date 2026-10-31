--!nonstrict
-- Sonolith bar widget: album art, title and artist of what's playing. A thin client of the service's
-- state; it never polls Sonolith. Left click opens Now Playing (or the connect screen), right click
-- plays/pauses, the wheel changes the volume or skips.

local S = require("./lib/state.luau")
local commands = require("./lib/commands.luau")
local format = require("./lib/format.luau")

commands.init("bar")

local NOW_PLAYING = "opecko/sonolith:nowplaying"
local MARQUEE_GAP = "   ·   "

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

local settings = {
  showArt = cfg("show_art", true),
  showTitle = cfg("show_title", true),
  showArtist = cfg("show_artist", true),
  layout = cfg("layout", "inline"),
  textFormat = cfg("text_format", "{title} · {artist}"),
  order = cfg("order", "title_first"),
  artSize = cfg("art_size", 22),
  artRadius = cfg("art_radius", 6),
  maxWidth = cfg("max_width", 240),
  scrollText = cfg("scroll_long_text", false),
  showStateIcon = cfg("show_state_icon", true),
  showProgress = cfg("show_progress", false),
  whenIdle = cfg("when_idle", "glyph"),
  whenUnavailable = cfg("when_unavailable", "glyph"),
  scrollAction = cfg("scroll_action", "volume"),
  volumeStep = cfg("volume_step", 5),
}

local lastItem = nil -- for when_idle = last_track
local lastArtPath = nil
local hovered = false
local marqueeOffset = 0
local marqueeText = nil
local pendingVolume = nil

---- Text

-- Whole strings, not a character class: "·" and "–" are multibyte and share bytes with other letters.
local SEPARATORS = { "·", "•", "–", "—", "-", "|", "/", "," }

-- Drops separators left dangling by an empty field ("Title · ").
local function trimSeparators(text)
  local changed = true
  while changed do
    changed = false
    text = noctalia.string.trim(text)
    for _, sep in ipairs(SEPARATORS) do
      if string.sub(text, 1, #sep) == sep then
        text, changed = string.sub(text, #sep + 1), true
      end
      if #text >= #sep and string.sub(text, -#sep) == sep then
        text, changed = string.sub(text, 1, -#sep - 1), true
      end
    end
  end
  return text
end

local function fill(template, item)
  local values = {
    title = item.title or "",
    artist = format.artists(item),
    album = format.album(item),
  }
  local text = string.gsub(template, "{(%w+)}", function(name)
    return values[name] or ""
  end)
  return trimSeparators(text)
end

local function inlineText(item)
  if settings.showTitle and settings.showArtist then
    return fill(settings.textFormat, item)
  elseif settings.showTitle then
    return item.title or ""
  elseif settings.showArtist then
    return format.artists(item)
  end
  return ""
end

-- A rough characters-per-width estimate; the label still elides whatever does not fit.
local function maxChars()
  return math.max(4, math.floor(settings.maxWidth / 7))
end

-- Long text "scrolls" one character per tick (scroll_long_text).
local function marquee(text)
  if not settings.scrollText or utf8.len(text) == nil or utf8.len(text) <= maxChars() then
    marqueeText = nil
    return text
  end
  if marqueeText ~= text then
    marqueeText = text
    marqueeOffset = 0
  end
  local loop = text .. MARQUEE_GAP
  local chars = {}
  for _, c in utf8.codes(loop) do
    table.insert(chars, utf8.char(c))
  end
  local out = {}
  for i = 0, maxChars() - 1 do
    table.insert(out, chars[(marqueeOffset + i) % #chars + 1])
  end
  return table.concat(out)
end

---- Tooltip

local function trackTooltip(item)
  local lines = { item.title or "" }
  local artist, album = format.artists(item), format.album(item)
  if artist ~= "" then
    table.insert(lines, artist)
  end
  if album ~= "" and album ~= artist then
    table.insert(lines, album)
  end
  local pos, dur = S.positionNow()
  if dur then
    table.insert(lines, `{format.duration(pos)} / {format.duration(dur)}`)
  end
  return table.concat(lines, "\n")
end

---- Pieces

local function artNode(item)
  local art = S.get(S.ART)
  local path = type(art) == "table" and (art.thumb or art.path) or nil
  if path then
    lastArtPath = path
  end
  path = path or lastArtPath
  local size = settings.artSize
  if path then
    return ui.image({ key = "art-img", path = path, width = size, height = size, radius = settings.artRadius, fit = "cover" })
  end
  return ui.column({
    key = "art-ph",
    width = size,
    height = size,
    radius = settings.artRadius,
    fill = "surface_container_high",
    align = "center",
    justify = "center",
  }, {
    ui.glyph({ name = item and item.type == "episode" and "microphone" or "music", size = math.floor(size * 0.6), color = "on_surface_variant" }),
  })
end

local function glyphOnly(name, color)
  return ui.row({ align = "center" }, { ui.glyph({ name = name, color = color }) })
end

---- Render

local function setTooltip(text)
  barWidget.setTooltip(text) -- never clearTooltip() on an empty one: it crashes (see the timer plugin)
end

local function hide()
  barWidget.setVisible(false)
end

local function show(tree, tooltip)
  barWidget.setVisible(true)
  barWidget.render(tree)
  setTooltip(tooltip)
end

local function render()
  local conn = S.get(S.CONN) or { state = "starting" }

  if conn.state ~= S.CONNECTED then
    local state = conn.state
    if state == "unavailable" or state == "starting" or state == "error" then
      if settings.whenUnavailable == "hide" then
        return hide()
      end
      local tip = state == "error" and conn.message == "noPython" and noctalia.tr("np.no_python.title")
        or noctalia.tr("bar.tooltip.unavailable")
      return show(glyphOnly("music-off", "on_surface_variant"), tip)
    end
    local tip = state == "pending" and noctalia.tr("np.pending.title") or noctalia.tr("bar.tooltip.connect")
    return show(glyphOnly("plug-connected-x", "on_surface_variant"), tip)
  end

  local item = S.track()
  if item then
    lastItem = item
  elseif settings.whenIdle == "last_track" then
    item = lastItem
  end
  if not item then
    if settings.whenIdle == "hide" then
      return hide()
    end
    return show(glyphOnly("music"), noctalia.tr("np.nothing_playing.title"))
  end

  local player = S.get(S.PLAYER)
  local paused = not S.track() or type(player) ~= "table" or player.status ~= "playing"
  local textColor = paused and "on_surface/0.6" or "on_surface"
  local subColor = paused and "on_surface_variant/0.6" or "on_surface_variant"
  local tooltip = trackTooltip(item)

  local hasText = settings.showTitle or settings.showArtist
  if not settings.showArt and not hasText then
    return show(glyphOnly("music"), tooltip)
  end

  -- Side bar: art only (or the glyph when art is off); the text goes into the tooltip.
  if barWidget.isVertical() then
    if settings.showArt then
      return show(ui.column({ align = "center" }, { artNode(item) }), tooltip)
    end
    return show(glyphOnly("music"), tooltip)
  end

  local children = {}
  if settings.showArt then
    table.insert(children, artNode(item))
  end

  if hasText then
    local textNodes = {}
    if settings.layout == "stacked" and settings.showTitle and settings.showArtist then
      local first = { text = item.title or "", color = textColor, fontSize = 12, fontWeight = "medium" }
      local second = { text = format.artists(item), color = subColor, fontSize = 10 }
      if settings.order == "artist_first" then
        first.text, second.text = second.text, first.text
      end
      first.maxWidth, first.maxLines = settings.maxWidth, 1
      second.maxWidth, second.maxLines = settings.maxWidth, 1
      table.insert(textNodes, ui.label(first))
      table.insert(textNodes, ui.label(second))
    else
      table.insert(textNodes, ui.label({
        text = marquee(inlineText(item)),
        color = textColor,
        maxWidth = settings.maxWidth,
        maxLines = 1,
      }))
    end
    if settings.showProgress then
      local pos, dur = S.positionNow()
      table.insert(textNodes, ui.progress({
        height = 2,
        progress = dur and dur > 0 and pos / dur or 0,
        fill = paused and "primary/0.5" or "primary",
        track = "on_surface/0.12",
        radius = 1,
      }))
    end
    table.insert(children, ui.column({ key = "text", gap = settings.showProgress and 2 or 0, justify = "center" }, textNodes))
  end

  if settings.showStateIcon and S.track() then
    table.insert(children, ui.glyph({
      key = "state",
      name = paused and "player-pause" or "player-play",
      size = 14,
      color = paused and "on_surface_variant" or "primary",
    }))
  end

  show(ui.row({ gap = 8, align = "center" }, children), tooltip)
end

---- Ticks: only when something on screen moves (progress, scrolling text, an open tooltip)

local function wantsTicks()
  local player = S.get(S.PLAYER)
  local playing = type(player) == "table" and player.status == "playing"
  return (settings.showProgress and playing) or (hovered and playing) or marqueeText ~= nil
end

local function syncInterval()
  if settings.scrollText and marqueeText then
    noctalia.setUpdateInterval(300)
  else
    noctalia.setUpdateInterval(1000)
  end
end

local lastRenderAt = 0

function update()
  if marqueeText then
    marqueeOffset += 1
  end
  -- Without anything moving, a slow tick catches orientation changes and nothing else.
  if wantsTicks() or noctalia.nowMs() - lastRenderAt > 5000 then
    lastRenderAt = noctalia.nowMs()
    render()
    syncInterval()
  end
end

for _, key in ipairs({ S.CONN, S.TRACK, S.ART, S.PLAYER }) do
  noctalia.state.watch(key, function()
    render()
    syncInterval()
  end)
end

render()
syncInterval()

---- Input

function onHover(entered)
  hovered = entered == true or entered == "true"
end

function onClick()
  noctalia.togglePanel(NOW_PLAYING)
end

function onRightClick()
  if S.isConnected() and S.hasScope("player:control") and S.track() then
    commands.send("player.toggle")
  else
    noctalia.togglePanel(NOW_PLAYING)
  end
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or not S.isConnected() or not S.hasScope("player:control") then
    return
  end
  if settings.scrollAction == "volume" then
    local player = S.get(S.PLAYER)
    if type(player) ~= "table" then
      return
    end
    -- Keep our own target between events, so a fast flick adds up instead of restarting from stale state.
    local base = pendingVolume or player.volume
    local target = math.clamp(base - steps * settings.volumeStep, 0, 100)
    if target == base then
      return
    end
    pendingVolume = target
    commands.send("player.setVolume", { volume = target }, function()
      if pendingVolume == target then
        pendingVolume = nil
      end
    end)
  elseif settings.scrollAction == "track" and startsGesture and S.track() then
    commands.send(steps > 0 and "player.next" or "player.previous")
  end
end
