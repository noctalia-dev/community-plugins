--!nonstrict
-- Bar widget: now-playing chip with the same display settings as the shell's
-- built-in media widget (media_widget_definition.cpp):
--   album_art_only / hide_album_art / hide_artist / artist_first /
--   min_length / max_length / art_size / title_scroll / hide_when_no_media.
-- Settings are [[widget.setting]] entries — edited in this widget's own
-- settings popup (middle click) and read via noctalia.getConfig(key).
--
-- Interactions mirror the built-in media widget 1:1
-- (src/shell/bar/widget_gesture_defaults.cpp): left = lyrics panel (our
-- equivalent of control-center media), right = media toggle, back/forward &
-- scroll = prev/next, middle = settings (host default, unbound here).
--
-- Vertical bars: icon only (art, or the state glyph) like media_widget.cpp
-- (artOnly = isVertical || albumArtOnly).
--
-- Notes:
--   * No explicit color roles — the instance Color/Icon Color settings apply.
--   * `min_length` is accepted for parity but inert: plugins cannot fix a
--     widget width; the host sizes the chip to its content.
--   * Text width budget is estimated (no measure API): ~0.62 em per char at
--     fontSize 12 -> ~7.5 px/char, calibrated against the built-in widget.

local glyphPlay = "player-play"
local glyphPause = "player-pause"

local GAP = 6
local FONT_PX = 12
local CHAR_PX = FONT_PX * 0.62     -- ~7.4 px per char (est., see above)
local SCROLL_TICKS = 2             -- advance one char every N update ticks

-- Which panel preset to open (panel_size plugin setting).
local function panelIdForSize()
  local sz = noctalia.getConfig("panel_size")
  if sz == "mini" then return "panel-mini" end
  if sz == "compact" then return "panel-compact" end
  if sz == "large" then return "panel-large" end
  return "panel"
end

-- ── settings ────────────────────────────────────────────────────────────────

local function cfgBool(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "boolean" then return v end
  return fallback
end

local function cfgInt(key, fallback)
  local v = noctalia.getConfig(key)
  if type(v) == "number" then return math.floor(v) end
  return fallback
end

local function widgetOptions()
  local artOnly = cfgBool("album_art_only", false)
  local hideArt = cfgBool("hide_album_art", false)
  local scroll = noctalia.getConfig("title_scroll") or "none"
  if scroll ~= "always" and scroll ~= "on_hover" then scroll = "none" end
  return {
    artOnly = artOnly,
    hideArt = hideArt,
    hideArtist = cfgBool("hide_artist", false),
    artistFirst = cfgBool("artist_first", false),
    showLine = cfgBool("show_lyric_line", false),
    maxLength = cfgInt("max_length", 220),
    artSize = math.max(8, math.min(96, cfgInt("art_size", 16))),
    scroll = scroll,
    hideWhenNoMedia = cfgBool("hide_when_no_media", false),
    -- audio-reactive chip (host-driven, no API level required)
    spectrum = cfgBool("audio_spectrum", false),
    spectrumBands = math.max(1, math.min(128, cfgInt("audio_spectrum_bands", 8))),
  }
end

-- ── utf-8 helpers (char boundaries, never split a sequence) ─────────────────

local function charCount(s)
  local i, n = 1, 0
  while i <= #s do
    local b = s:byte(i)
    if b >= 0xF0 then i = i + 4
    elseif b >= 0xE0 then i = i + 3
    elseif b >= 0xC0 then i = i + 2
    else i = i + 1 end
    n = n + 1
  end
  return n
end

local function toChars(s)
  local out = {}
  local i = 1
  while i <= #s do
    local b = s:byte(i)
    local len = 1
    if b >= 0xF0 then len = 4
    elseif b >= 0xE0 then len = 3
    elseif b >= 0xC0 then len = 2 end
    out[#out + 1] = s:sub(i, i + len - 1)
    i = i + len
  end
  return out
end

-- First maxChars characters (UTF-8 safe).
local function charPrefix(s, maxChars)
  local i, n = 1, 0
  while i <= #s and n < maxChars do
    local b = s:byte(i)
    if b >= 0xF0 then i = i + 4
    elseif b >= 0xE0 then i = i + 3
    elseif b >= 0xC0 then i = i + 2
    else i = i + 1 end
    n = n + 1
  end
  return s:sub(1, i - 1)
end

-- ── text (build + scroll) ───────────────────────────────────────────────────

local scrollOffset = 0
local scrollTick = 0
local hovered = false
local lastFull = ""

local function activeLyricLine(m)
  -- Current synced line for the chip (show_lyric_line): last line whose
  -- timestamp <= posSec. Falls back to the first line before the first
  -- timestamp (karaoke convention). posSec in the snapshot is ≤150 ms stale
  -- (service polls), fine for a subtitle.
  -- lyricsStatus "choose" = the variant picker published a list; lyrics may
  -- still be live (a picked variant or default kept), so accept it too.
  if m == nil then return nil end
  if m.lyricsStatus ~= "ready" and m.lyricsStatus ~= "choose" then return nil end
  if not m.synced then return nil end
  local lines = m.lyrics
  if type(lines) ~= "table" or #lines == 0 then return nil end
  local pos = tonumber(m.posSec) or 0
  local idx = nil
  for i, l in ipairs(lines) do
    local t = tonumber(l.time) or -1
    if t >= 0 and t <= pos then idx = i end
  end
  if idx == nil then idx = 1 end
  local text = lines[idx] and lines[idx].text or ""
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  return text
end

local function buildFull(m, o)
  local title = m.title or ""
  local artist = (not o.hideArtist) and (m.artist or "") or ""
  local line = o.showLine and activeLyricLine(m) or nil
  local text
  if line then
    -- The chip shows the live lyric line instead of the artist while synced
    -- lyrics are ready; title stays for context.
    if title ~= "" then text = title .. " · " .. line else text = line end
  elseif title ~= "" and artist ~= "" then
    text = o.artistFirst and (artist .. " - " .. title) or (title .. " - " .. artist)
  else
    text = title ~= "" and title or artist
  end
  if text == "" then text = noctalia.tr("common.no-title") end
  return text
end

-- Rolling window of `budget` chars over padded text; wraps forever.
local function rolling(text, budget, offset)
  local chars = toChars(text .. "   ")
  local n = #chars
  local start = (offset % n) + 1
  local out = {}
  for k = 0, budget - 1 do
    local idx = ((start + k - 1) % n) + 1
    out[#out + 1] = chars[idx]
  end
  return table.concat(out)
end

-- ── state / snapshot ────────────────────────────────────────────────────────

local function media()
  local ok, v = pcall(function() return noctalia.state.get("media") end)
  if ok and type(v) == "table" then return v end
  return nil
end

local visible = true
local function setChipVisible(want)
  want = want == true
  if want ~= visible then
    visible = want
    barWidget.setVisible(want)
  end
end

-- ── audio spectrum (audio-reactive chip) ────────────────────────────────────
-- The host drives this ONLY when the widget declares `audio_spectrum = true`
-- (plugin_widget.cpp reads settingBool "audio_spectrum" and settingInt
-- "audio_spectrum_bands" itself, so no plugin API level is involved). It then
-- calls onAudioSpectrum(valuesCsv, stateCsv) at ~60 Hz, COALESCED — only the
-- latest frame matters, so a slow script cannot accumulate stale frames.
-- stateCsv is "audioActive,mprisPlaying" as 0/1.
--
-- The tree is not rebuilt on every frame (60 rebuilds/s in Luau is wasteful for
-- a bar meter): values are stored and the chip repaints at most every
-- SPECTRUM_REFRESH_MS. onAudioSpectrum itself is defined AFTER renderFrom
-- (see the contract note above) so it can call it.

local SPECTRUM_REFRESH_MS = 80     -- ~12 fps — enough for a bar meter
local spectrumValues = nil         -- array of levels 0..1, or nil before the first frame
local spectrumActive = false       -- audio is actually flowing
local spectrumLastPaint = 0

local function parseSpectrum(csv)
  local out = {}
  for v in string.gmatch(csv or "", "[^,]+") do
    local n = tonumber(v)
    if n == nil then break end
    out[#out + 1] = n
  end
  return out
end

-- Small band meter: one box per band, height scaled to the widget's icon slot.
local function spectrumNode(o)
  local vals = spectrumValues
  if not o.spectrum or type(vals) ~= "table" or #vals == 0 then return nil end
  -- The host adapts its analysis to the count we ask for (pipewire_spectrum.cpp reuses
  -- the largest listener request), so cap by width, not by band count: thin the bars.
  local want = math.min(o.spectrumBands, #vals)
  local barW = want <= 16 and 2 or 1
  local maxH = math.max(8, o.artSize)
  local bars = {}
  -- average adjacent bands down to `want`, so asking for fewer than the host sends
  -- still uses every value the host gave us
  local step = #vals / want
  for i = 1, want do
    local sum, cnt = 0, 0
    local from = math.floor((i - 1) * step) + 1
    local to = math.min(#vals, math.floor(i * step))
    if to < from then to = from end
    for k = from, to do
      sum = sum + (tonumber(vals[k]) or 0)
      cnt = cnt + 1
    end
    local level = cnt > 0 and (sum / cnt) or 0
    local h = math.max(2, math.floor(level * maxH + 2))
    bars[#bars + 1] = ui.box({
      key = "sp" .. i, width = barW, height = h, radius = 1,
      fill = spectrumActive and "primary" or "outline",
      opacity = spectrumActive and 1 or 0.5,
    })
  end
  return ui.row({ key = "spectrum", gap = 1, align = "center", height = maxH }, bars)
end

-- ── render ──────────────────────────────────────────────────────────────────

local lastKey = ""
local function renderKey(m, o, shown)
  -- coarse spectrum signature: the meter repaints on the forced repaints from
  -- onAudioSpectrum, but including it here keeps an ordinary update() tick from
  -- skipping a repaint when the bands have changed in the meantime.
  local specSig = ""
  if o.spectrum and type(spectrumValues) == "table" and #spectrumValues > 0 then
    local sum = 0
    for i = 1, #spectrumValues do
      sum = sum + (tonumber(spectrumValues[i]) or 0)
    end
    specSig = tostring(#spectrumValues) .. ":" .. tostring(math.floor(sum * 12))
      .. ":" .. tostring(spectrumActive)
  end
  return table.concat({
    m.hasPlayer and "1" or "0",
    tostring(m.playing),
    shown,
    m.artUrl or "",
    (type(m.artUrl) == "string" and m.artUrl ~= "" and noctalia.fileExists(m.artUrl)) and "1" or "0",
    tostring(o.artOnly),
    tostring(o.hideArt),
    tostring(o.hideArtist),
    tostring(o.artistFirst),
    tostring(o.artSize),
    barWidget.isVertical() and "V" or "H",
    specSig,
  }, "|")
end

local function renderFrom(m, force)
  if not m then m = media() end
  if not m then return end
  local o = widgetOptions()

  -- Hide-when-no-media
  if not m.hasPlayer then
    if o.hideWhenNoMedia then
      setChipVisible(false)
      return
    end
    setChipVisible(true)
    local key = "empty"
    if not force and key == lastKey then return end
    lastKey = key
    -- Empty state is ALSO a render() tree (setGlyph/setText are dead once a
    -- tree is active — verified live); no explicit color roles.
    barWidget.render(ui.row({ gap = GAP, align = "center" }, {
      ui.glyph({ name = "disc", size = 14 }),
    }))
    return
  end
  setChipVisible(true)

  local vertical = barWidget.isVertical()
  -- Paused = stable dim; playing = full opacity. The prop must ALWAYS be an
  -- explicit number — a nil opacity is read by the host as "unchanged", so
  -- resuming playback would leave the chip stuck dimmed (bug 2026-09-03).
  local dim = m.playing and 1 or 0.65
  local artOk = type(m.artUrl) == "string" and m.artUrl ~= ""
    and noctalia.fileExists(m.artUrl)

  -- Icon part: art, or the state glyph when no art; suppressed entirely by
  -- hide_album_art on horizontal bars (vertical always shows art, mirroring
  -- the built-in: hideAlbumArt is a horizontal-only option).
  local function iconChild()
    if (not vertical) and o.hideArt then return nil end
    if artOk then
      return ui.image({
        key = "cover",
        path = m.artUrl,
        width = o.artSize,
        height = o.artSize,
        radius = math.floor(o.artSize / 4),
        fit = "cover",
        opacity = dim,
      })
    end
    return ui.glyph({
      key = "state",
      name = m.playing and glyphPause or glyphPlay,
      size = math.max(10, o.artSize - 4),
      opacity = dim,
    })
  end

  -- Text part (horizontal only; suppressed by album_art_only).
  if vertical or o.artOnly then
    local children = { iconChild() }
    local key = renderKey(m, o, "icon-only")
    if not force and key == lastKey then return end
    lastKey = key
    barWidget.render(ui.row({ align = "center" }, children))
    return
  end

  local full = buildFull(m, o)
  if full ~= lastFull then
    lastFull = full
    scrollOffset = 0
    scrollTick = 0
  end

  -- Text area = max_length minus the icon slot (art or fallback glyph both
  -- occupy artSize + gap).
  local iconW = (not o.hideArt) and (o.artSize + GAP) or 0
  local budget = math.max(8, math.floor((o.maxLength - iconW) / CHAR_PX))

  local overBudget = charCount(full) > budget
  local scrolling = overBudget and
    (o.scroll == "always" or (o.scroll == "on_hover" and hovered))

  local shown
  if overBudget then
    if o.scroll == "none" then
      shown = charPrefix(full, budget - 1) .. "…"
    else
      shown = rolling(full, budget, scrollOffset)
    end
  else
    shown = full
  end

  local key = renderKey(m, o, shown)
  if not force and key == lastKey then return end
  lastKey = key

  local children = {}
  local icon = iconChild()
  if icon then children[#children + 1] = icon end

  -- Text block: a single centered label. (A playback-progress bar was
  -- considered here but dropped — see ROADMAP "show_progress in bar widget".)
  local label = ui.label({
    key = "title",
    text = shown,
    fontSize = FONT_PX,
    opacity = dim,
    maxLines = 1,
  })

  local textNode = ui.row({
    key = "textwrap",
    align = "center",
    onHover = function(state)
      local h = (state == "true")
      if h ~= hovered then
        hovered = h
        renderFrom(media(), true)
      end
    end,
  }, { label })
  children[#children + 1] = textNode

  -- audio-reactive band meter (only when the setting is on and frames arrived)
  local spec = spectrumNode(o)
  if spec then children[#children + 1] = spec end

  barWidget.render(ui.row({ gap = GAP, align = "center" }, children))
end

-- ── audio spectrum entry point ──────────────────────────────────────────────

-- Defined AFTER renderFrom on purpose: a `local function` declared lower in the
-- file is not visible above it (Luau locals are not hoisted), and calling one
-- from an earlier-defined function resolves to a nil global at run time — the
-- class of bug that once broke every seek in the panel. The host calls this only
-- when the widget declares `audio_spectrum = true`.
function onAudioSpectrum(valuesCsv, stateCsv)
  local vals = parseSpectrum(valuesCsv)
  if #vals == 0 then return end
  spectrumValues = vals
  -- stateCsv is "audioActive,mprisPlaying"
  spectrumActive = string.sub(tostring(stateCsv or "0"), 1, 1) == "1"
  local nowMs = 0
  pcall(function() nowMs = noctalia.nowMs() end)
  if nowMs > 0 and spectrumLastPaint > 0
    and (nowMs - spectrumLastPaint) < SPECTRUM_REFRESH_MS then
    return
  end
  spectrumLastPaint = nowMs
  renderFrom(media(), true)
end

-- ── loop ────────────────────────────────────────────────────────────────────

function update()
  local m = media()
  if not m then return end
  if not m.hasPlayer then
    renderFrom(m, false)
    return
  end
  local o = widgetOptions()
  local vertical = barWidget.isVertical()
  if vertical or o.artOnly or o.scroll == "none" then
    renderFrom(m, false)
    return
  end
  -- advance the rolling text
  local full = buildFull(m, o)
  local iconW = (not o.hideArt) and (o.artSize + GAP) or 0
  local budget = math.max(8, math.floor((o.maxLength - iconW) / CHAR_PX))
  local active = charCount(full) > budget and
    (o.scroll == "always" or (o.scroll == "on_hover" and hovered))
  if not active then
    renderFrom(m, false)
    return
  end
  scrollTick = scrollTick + 1
  if scrollTick % SCROLL_TICKS == 0 then
    scrollOffset = scrollOffset + 1
    renderFrom(m, true)
  end
end

noctalia.state.watch("media", function(value)
  renderFrom(value, false)
end)

noctalia.setUpdateInterval(120)

-- Left click opens the lyrics panel (the built-in media widget opens the
-- control-center media tab instead). All other gestures live in
-- [widget.actions] (plugin.toml).
function onClick()
  noctalia.togglePanel("tranzem/media-lyrics:" .. panelIdForSize())
end
