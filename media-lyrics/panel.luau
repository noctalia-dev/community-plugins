--!nonstrict
-- media-lyrics panel: cover art with progress line, track info + transport,
-- karaoke lyric layer. Redesign v0.2 ("quiet premium"): one hero (the cover),
-- minimal chrome, type-driven hierarchy. Layout (2 bands):
--   A. chrome header:  NOW PLAYING ......... [reload] [close]   (11px ghost)
--   B. info row:       [cover 50 + progress 2.5] [title / artist - album] | transport+time
--   hairline separator
--   C. lyrics: karaoke carousel (synced) or clipped list (plain), flexGrow
--   D. footer: provider - mode label (11px, low-contrast)
--
-- Progress: verified live on this host build —
--   * no arc primitive exists, and VERTICAL ui.progress bars do not render
--     at all, so the v0.1 8-segment perimeter ring and the per-edge bars were
--     dropped for a single native horizontal ui.progress (2.5px) under the art;
--   * ui.box cannot hold children (host drops them with warnings);
--   * labels centered by default: text with maxWidth inside a stretched
--     column loses left alignment -> infoCol hugs content, springer pushes
--     transport to the right edge.
--
-- The panel is a thin client: state comes from noctalia.state("media"),
-- commands go back over noctalia.state("panel_cmd").

-- ============================= design tokens =============================
-- One table, one place. Spacing on a 4px grid; colors are palette role tokens
-- with alpha so everything tracks the active Noctalia theme.

local T = {
  -- layout
  pad = 4,               -- root padding
  gapBand = 8,           -- between bands A/B/hairline/C
  gapInline = 12,         -- cover <-> text
  gapMicro = 6,           -- inside groups (transport step, meta stack)

  -- cover + ring
  cover = 50,             -- inner cover size (logical px)
  ring = 2.5,             -- ring thickness
  coverRadius = 10,       -- inner cover corner radius

  -- typography
  fsOverline = 11,        -- chrome header / footer
  fsTitle = 19,
  fsMeta = 13,
  fsTime = 12,
  fsActiveLyric = 17,
  fsNearLyric = 15,
  fsFarLyric = 14,

  -- colors (state colors live here too)
  colOverline = "on_surface_variant",
  colTitle = "on_surface",
  colMeta = "on_surface_variant",
  colTime = "on_surface_variant",
  ringTrack = "outline/0.5",
  ringFill = "primary",
  lyricActive = "primary",
  lyricNear = "on_surface",
  lyricFar = "on_surface_variant",
  footer = "on_surface_variant/0.7",
  hairline = "outline/0.35",
  emptyState = "on_surface_variant",
}

local snap = nil       -- latest snapshot from the service
local cursorLine = 0   -- keyboard/scroll cursor over lyric lines (0 = follow playback)
local lastTrackKey = "" -- track identity for cursor reset on track change
local lastSnapMs = 0
tickMarquee = nil      -- set by buildInfoRow; advances marquee clocks

local function nowMs()
  local ok, v = pcall(function() return noctalia.nowMs() end)
  if ok and type(v) == "number" then return v end
  return os.time() * 1000
end

local function interpPos(s)
  -- interpolate position between service polls for smooth lyrics
  if not s then return 0 end
  if not s.playing then return s.posSec or 0 end
  local elapsed = (lastSnapMs > 0) and ((nowMs() - lastSnapMs) / 1000) or 0
  local p = (s.posSec or 0) + elapsed
  if s.lengthSec and s.lengthSec > 0 and p > s.lengthSec then p = s.lengthSec end
  return p
end

local function fmtTime(sec)
  sec = tonumber(sec) or 0
  if sec < 0 then sec = 0 end
  local s = math.floor(sec)
  return math.floor(s / 60) .. ":" .. string.format("%02d", s % 60)
end

local glyphFor = {
  prev = "player-skip-back-filled",
  next = "player-skip-forward-filled",
  play = "player-play-filled",
  pause = "player-pause-filled",
}

local function sendCmd(action, extra)
  local cmd = { action = action }
  if extra then
    for k, v in pairs(extra) do cmd[k] = v end
  end
  noctalia.state.set("panel_cmd", cmd)
end

-- marquee phase state lives at module scope: buildInfoRow runs on EVERY
-- render, and a per-render table would reset elapsed to 0 each tick.
local marqueeState = {}   -- [key] = { text, elapsed }

-- ============================= lyrics rendering =============================

-- Visible lyric lines depend on the panel preset (panel_size setting):
-- compact 440px fits 10, medium 520px fits 14 (historical default), large
-- 640px fits 16.
local function visibleLines()
  local sz = noctalia.getConfig("panel_size")
  if sz == "compact" then return 10 end
  if sz == "large" then return 16 end
  return 14
end

-- Header layout per panel preset: cover size, gaps, text column width and
-- transport button sizes. Compact is ~432 usable px, medium ~512, large
-- ~632 (panel width minus root padding); the numbers keep the whole header
-- (cover + text + transport + time) inside those bounds.
local function panelLayout()
  local sz = noctalia.getConfig("panel_size")
  if sz == "compact" then
    return { cover = 36, gapInline = 8, textW = 168, ctl = 14, main = 18 }
  elseif sz == "large" then
    return { cover = 56, gapInline = 14, textW = 370, ctl = 20, main = 24 }
  end
  return { cover = 50, gapInline = 12, textW = 286, ctl = 18, main = 22 }
end

local ACTIVE_ROW = 4        -- 1-based slot of the active line inside the window

local function buildLyricsBody(s)
  local lines = s.lyrics or {}
  local n = #lines

  if s.lyricsStatus == "loading" then
    return { ui.label({ text = noctalia.tr("panel.loading-lyrics"), color = T.colMeta,
      fontSize = T.fsFarLyric, fontWeight = "medium", textAlign = "center" }) }
  end
  if s.lyricsStatus == "error" then
    return { ui.label({ text = noctalia.tr("panel.lyrics-error") .. (s.lyricsError or ""),
      color = "error", fontSize = T.fsFarLyric, textAlign = "center" }) }
  end
  if s.lyricsStatus ~= "ready" or n == 0 then
    return { ui.label({ text = noctalia.tr("panel.no-lyrics"), color = T.emptyState,
      fontSize = T.fsFarLyric, fontWeight = "medium", textAlign = "center" }) }
  end

  if not s.synced then
    -- unsynced: static list inside a clipping scroll (a bare column does not
    -- clip its children), dimmed, centered, generous line spacing. The
    -- keyboard cursor still highlights a line (no seek — no timestamps).
    local rows = {}
    for i, l in ipairs(lines) do
      local isCursor = (i == cursorLine)
      rows[#rows + 1] = ui.row({
        key = "lyr" .. i,
        align = "center", justify = "center",
      }, {
        (isCursor) and ui.glyph({
          key = "cur" .. i,
          name = "chevron-right",
          size = 11,
          color = T.lyricActive,
        }) or nil,
        ui.label({
          key = "lbl" .. i, text = l.text, fontSize = T.fsFarLyric,
          color = isCursor and T.lyricActive or T.lyricNear,
          opacity = isCursor and 1 or 0.8, textAlign = "center",
        }),
      })
      rows[#rows + 1] = ui.spacer({ key = "lgap" .. i, height = T.gapMicro })
    end
    return { ui.scroll({ flexGrow = 1, align = "stretch" }, rows) }
  end

  -- synchronized: carousel around the playback line (karaoke fade ladder)
  local pos = interpPos(s)
  local active = -1
  for i = 1, n do
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time <= pos) then active = i end
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time > pos) then break end
  end

  local showCount = math.min(visibleLines(), n)
  local centerY = active >= 1 and ACTIVE_ROW or math.ceil(showCount / 2)
  -- The window centers on the keyboard cursor line when the user moved it
  -- (Up/Down/Return/Space/scroll), otherwise on the active playback line.
  -- Before the first lyric timestamp active == -1: fall back to line 1 so
  -- scrolling works from the very start (a raw active-based base was clamped
  -- to a frozen window until the first words began).
  local refActive = active >= 1 and active or 1
  local target = cursorLine >= 1 and cursorLine or refActive
  local lo = 1
  local hi = math.max(1, n - showCount + 1)
  local base = target - centerY
  base = math.max(lo, math.min(hi, base))
  local rows = {}
  for k = 1, showCount do
    local idx = base + k - 1
    if idx >= 1 and idx <= n then
      local isActive = (idx == active)
      local isCursor = (idx == cursorLine)
      local dist = math.abs(idx - active)
      local fontSize = isActive and T.fsActiveLyric
        or (dist <= 2 and T.fsNearLyric or T.fsFarLyric)
      local fontWeight = (isActive or isCursor) and "bold"
        or (dist <= 2 and "medium" or "normal")
      local color = (isActive or isCursor) and T.lyricActive
        or (dist <= 2 and T.lyricNear or T.lyricFar)
      local opacity = (isActive or isCursor) and 1
        or (dist <= 2 and 0.9 or (dist <= 5 and 0.55 or 0.3))
      local lineTime = s.lyrics[idx].time
      -- Clickable line: ui.label does not accept onClick and ui.button
      -- ignores color/fontWeight (would break the karaoke gradient), so wrap
      -- the label in a ui.row that owns the click target. Seek only when the
      -- line has a timestamp. The cursor row gets a leading chevron marker.
      local children = {}
      if isCursor then
        children[#children + 1] = ui.glyph({
          key = "cur" .. idx,
          name = "chevron-right",
          size = math.max(10, fontSize - 3),
          color = T.lyricActive,
        })
      end
      children[#children + 1] = ui.label({
        key = "lbl" .. idx,
        text = s.lyrics[idx].text,
        fontSize = fontSize,
        fontWeight = fontWeight,
        color = color,
        opacity = opacity,
        textAlign = "center",
      })
      rows[k] = ui.row({
        key = "lyr" .. idx,
        align = "center", justify = "center",
        onClick = (lineTime >= 0) and function()
          sendCmd("seekTo", { sec = lineTime })
        end or nil,
      }, children)
    else
      rows[k] = ui.spacer({ key = "gap" .. k, height = 24 })
    end
  end
  return rows
end

-- ============================= cover: art + progress =============================

-- Cover art with a thin progress line under it. VERIFIED LIVE on this host:
--   * ui.box cannot hold children (host drops them with warnings);
--   * ui.image renders at DECLARED size only when NOT wrapped in a padded
--     container (inside a padded plate column it came out oversize), so the
--     frame is the image's own border (ui.image border/borderWidth/radius);
--   * vertical ui.progress bars do not render at all -> single horizontal
--     native progress bar under the art (agreed auto-fallback).
local function buildCover(s, coverSize)
  local COVER = coverSize or T.cover
  if s.artUrl and s.artUrl ~= "" then
    return ui.image({
      key = "cover", path = s.artUrl, width = COVER, height = COVER,
      fit = "cover", radius = T.coverRadius,
      border = T.ringTrack, borderWidth = 1,
      onClick = function() sendCmd("toggle") end,
    })
  else
    return ui.box({ key = "coverbox", width = COVER, height = COVER,
      fill = "surface_variant/0.6", border = "outline/0.5", borderWidth = 1,
      radius = T.coverRadius }, {
        ui.glyph({ name = "disc", size = math.max(28, COVER - 8), color = "on_surface_variant" }),
      })
  end
end

local function buildProgressBar(s)
  local total = s.lengthSec or 0
  local cur = interpPos(s)
  local frac = (total > 0) and math.min(1, cur / total) or 0
  return ui.progress({
    key = "pbar", progress = frac,
    fill = T.ringFill, track = T.ringTrack,
    width = "stretch", height = T.ring, radius = T.ring / 2
  })
end

-- ============================= header (cover + info + transport) =============================

local function buildInfoRow(s)
  local L = panelLayout()
  if not s.hasPlayer then
    return { ui.row({ key = "noplayer", height = L.cover + 2 * T.ring, align = "center" }, {
      ui.label({ text = noctalia.tr("panel.no-media-player"), color = T.emptyState, fontSize = T.fsMeta }),
    }) }
  end

  local cover = buildCover(s, L.cover)

  local function ctl(glyph, action, enabled, size)
    return ui.button({
      glyph = glyph, glyphSize = size or L.ctl, variant = "ghost",
      enabled = enabled ~= false, onClick = function() sendCmd(action) end,
    })
  end

  local mainGlyph = s.playing and glyphFor.pause or glyphFor.play
  local cur = interpPos(s)
  local total = s.lengthSec or 0

  -- right block: transport row (the hero pill sits on the cover's axis) +
  -- quiet time label underneath, right-aligned
  local transportCol = ui.column({ key = "transportCol", gap = 2, align = "center", justify = "center" }, {
    ui.row({ gap = T.gapMicro, align = "center", justify = "end" }, {
      ctl(glyphFor.prev, "prev", s.canGoPrev ~= false, L.ctl),
      ui.button({
        glyph = mainGlyph, glyphSize = L.main, variant = "primary",
        enabled = s.hasPlayer == true, onClick = function() sendCmd("toggle") end,
        controlSize = "sm",
      }),
      ctl(glyphFor.next, "next", s.canGoNext ~= false, L.ctl),
    }),
    ui.label({ key = "time", text = fmtTime(cur) .. " / " .. fmtTime(total),
      fontSize = T.fsTime, color = T.colTime }),
  })

  -- middle block: title + artist - album (no wrap, marquee for overflow).
  -- PATTERN FROM COMMUNITY/TODO + lyrics.luau: text pinned left inside a
  -- fixed-width BUTTON (contentAlign = "start"); a line that does not fit is
  -- NOT ellipsized - it stays static for MARQUEE_HOLD seconds, then scrolls
  -- char-by-char (charUnits widths), holds at the end, and scrolls back.
  -- Height never jumps: button height is fixed per line.
  local TEXT_W = L.textW
  local MARQUEE_HOLD = 2        -- seconds of static display before scrolling
  local MARQUEE_SPEED = 24      -- pixels per second
  -- MPRIS metadata can contain embedded newlines ("Golden Empire feat.\n
  -- Zitaa - Original Mix"): a button then WRAPS its text to 2 lines inside
  -- the fixed-height box and the overflow draws over the next line (the
  -- "наложение букв" the user saw). Sanitize to a single line.
  local function singleLine(text)
    text = tostring(text or ""):gsub("[\r\n\t]+", " ")
    text = text:gsub("  +", " ")
    return text
  end
  local artistLine = singleLine(s.artist ~= "" and s.artist or "Unknown artist")
  if s.album ~= "" then artistLine = artistLine .. " - " .. s.album end

  -- UTF-8 aware char split + per-char width units (community/lyrics scheme)
  local function toChars(text)
    local chars = {}
    local i = 1
    while i <= #text do
      local byte = text:byte(i)
      local len = 1
      if byte >= 0xF0 then len = 4 elseif byte >= 0xE0 then len = 3
      elseif byte >= 0xC0 then len = 2 end
      chars[#chars + 1] = text:sub(i, i + len - 1)
      i = i + len
    end
    return chars
  end
  local function charUnits(char)
    -- uniform conservative estimate: this theme's font renders ~0.72em/char
    -- on average (caps-heavy titles measured wider than 0.58em predicted,
    -- which let lines slip past capacity and WRAP). 0.72 units/char keeps
    -- slices safely inside the button width.
    local byte = char:byte(1) or 0
    if byte < 0x80 then return 0.72 end
    return 1
  end
  local function textUnits(text)
    local u = 0
    for _, ch in ipairs(toChars(text)) do u = u + charUnits(ch) end
    return u
  end
  -- viewport capacity in width units, PER FONT SIZE: units are em-fractions
  -- (charUnits = em fraction), so capacity = usable px / fontSize. A single
  -- fs13-based capacity made fs19 title slices ~1.46x too wide -> the button
  -- wrapped the slice again (observed live: "…nd In That Moment I Knew Th…"
  -- on two lines). Button inner padding ~13px/side is also included.
  local function vwUnits(fs)
    return (TEXT_W - 26) / fs
  end
  local function shouldMarquee(text, fs)
    return textUnits(text) > vwUnits(fs)
  end

  -- scroll timing per line: static hold -> slow travel -> hold -> back
  -- (marqueeState is module-scope — see top of file)

  local function marqueeSlice(chars, offset, fs)
    -- visible window of vwUnits(fs) starting at char offset
    local out, used, i = {}, 0, 1
    local skip = math.floor(offset)
    local frac = offset - skip
    local index = skip + 1
    while index <= #chars and used < vwUnits(fs) do
      local w = charUnits(chars[index])
      if used + w > vwUnits(fs) then break end
      out[#out + 1] = chars[index]
      used = used + w
      index = index + 1
    end
    return table.concat(out)
  end

  local function textLine(key, text, fs, weight, colr)
    local state = marqueeState[key]
    if state == nil or state.text ~= text then
      state = { text = text, elapsed = 0, phase = 0 }
      marqueeState[key] = state
    end
    local shown = text
    if shouldMarquee(text, fs) then
      local chars = toChars(text)
      local widths = {}
      for i, ch in ipairs(chars) do widths[i] = charUnits(ch) end
      local trailing = 0
      local units = 0
      for i = #chars, 1, -1 do
        local nu = units + widths[i]
        if nu > vwUnits(fs) then break end
        units = nu
        trailing = trailing + 1
      end
      local distance = math.max(0, #chars - math.max(1, trailing))
      if distance > 0 then
        -- scroll speed in units/second: 24px/s at fs13 ≈ 1.85 units/s,
        -- scaled by fontSize so all lines scroll at the same visual speed
        local cellsPerSec = math.max(0.5, MARQUEE_SPEED / fs)
        local travel = distance / cellsPerSec
        local cycle = MARQUEE_HOLD * 2 + travel * 2
        local phase = state.elapsed % cycle
        local off
        if phase < MARQUEE_HOLD then off = 0
        else
          phase = phase - MARQUEE_HOLD
          if phase < travel then off = distance * (phase / travel)
          else
            phase = phase - travel
            if phase < MARQUEE_HOLD then off = distance
            else
              phase = phase - MARQUEE_HOLD
              off = distance * (1 - phase / travel)
            end
          end
        end
        shown = marqueeSlice(chars, math.floor(off), fs)
      end
    end
    -- key includes the slice text: the host RETAINS a button whose key is
    -- unchanged and re-renders its text in place, which visibly overlaps the
    -- old glyphs with the new ones during a text swap. Keying per slice
    -- forces a clean node recreation on every step.
    return ui.button({
      key = key .. "-" .. shown, text = shown, variant = "ghost",
      contentAlign = "start", fontSize = fs,
      width = TEXT_W, height = math.floor(fs * 1.35 + 0.5),
    })
  end

  -- advance marquee timers between renders (called from update())
  tickMarquee = function(deltaSec)
    for _, st in pairs(marqueeState) do st.elapsed = st.elapsed + deltaSec end
  end
  local infoCol = ui.column({ key = "infoCol", gap = 3, align = "start" }, {
    textLine("ttl", singleLine(s.title ~= "" and s.title or noctalia.tr("panel.no-title")),
      T.fsTitle, "semibold", T.colTitle),
    textLine("art", artistLine, T.fsMeta, "regular", T.colMeta),
  })

  -- single band, everything centered on the art's vertical axis
  return {
    ui.row({ key = "infoRow", align = "center", justify = "start", height = 62 }, {
      ui.column({ key = "coverWrap", gap = 1, align = "center",
        width = L.cover + 2 }, {
          cover,
        }),
      ui.spacer({ key = "coverGap", width = L.gapInline }),
      infoCol,
      ui.spacer({ key = "spring1", flexGrow = 1 }),
      transportCol,
    }),
  }
end

-- ============================= render =============================

local function render()
  local s = snap or {
    hasPlayer = false, title = "", artist = "", album = "", artUrl = "",
    playing = false, lengthSec = 0, posSec = 0, lyrics = {},
    lyricsStatus = "loading", lyricsProvider = "", synced = false,
  }
  local infoRow = buildInfoRow(s)

  -- footer: provider + mode in one quiet label (empty string hides itself)
  local footerTxt = ""
  if s.lyricsStatus == "ready" then
    footerTxt = (s.lyricsProvider ~= "" and s.lyricsProvider or "")
      .. (s.synced and (" - " .. noctalia.tr("panel.synced"))
        or (" - " .. noctalia.tr("panel.unsynced")))
  end

  panel.render(ui.column({ flexGrow = 1, padding = T.pad, gap = T.gapBand }, {
    -- A. chrome header: overline left, two ghost glyph buttons right
    ui.row({ key = "chrome", align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("panel.now-playing"), fontSize = T.fsOverline, fontWeight = "semibold",
        color = T.colOverline }),
      ui.row({ gap = T.gapMicro, align = "center" }, {
        ui.button({ glyph = "refresh", glyphSize = 14, variant = "ghost", controlSize = "sm",
          width = 22, height = 22,
          tooltip = noctalia.tr("panel.reload-lyrics"),
          onClick = function() noctalia.state.set("panel_req", { action = "reloadLyrics" }) end }),
        ui.button({ glyph = "close", glyphSize = 14, variant = "ghost", controlSize = "sm",
          width = 22, height = 22,
          onClick = function() panel.close() end }),
      }),
    }),
    -- B. info band (cover | info | transport)
    infoRow[1],
    -- progress bar replacing the hairline separator
    buildProgressBar(s),
    -- C. lyrics (flexGrow)
    ui.column({ key = "lyrics", flexGrow = 1, gap = T.gapMicro }, buildLyricsBody(s)),
    -- D. footer: provider - mode
    ui.label({ key = "footer", text = footerTxt, fontSize = T.fsOverline,
      color = T.footer, visible = footerTxt ~= "" }),
  }))
end

-- ============================= state wiring =============================

-- VERIFIED BY PROBE (this host build): the host NEVER calls update() or
-- onFrameTick for [[panel]] entries — both counters stayed 0 with
-- setWantsSecondTicks(true) + setNeedsFrameTick(true). The ONLY periodic
-- signal a panel gets is the service's media publishes (POLL_MS = 500ms):
-- the service re-sets noctalia.state("media") on every poll, and watch()
-- fires per publish. So the marquee clock MUST tick inside the media watch,
-- using the wall-clock delta between publishes.
noctalia.state.watch("media", function(value)
  local now = nowMs()
  if lastSnapMs > 0 then
    local deltaSec = (now - lastSnapMs) / 1000
    -- clamp: a long gap (panel closed / track change pause) must not
    -- fast-forward the marquee
    if deltaSec > 0 and deltaSec < 2.0 then
      if tickMarquee then tickMarquee(deltaSec) end
    end
  end
  -- track changed: drop the lyric cursor so the panel follows playback again
  local key = (value.title or "") .. "|" .. (value.artist or "") .. "|" .. tostring(value.lengthSec or 0)
  if key ~= lastTrackKey then
    lastTrackKey = key
    cursorLine = 0
  end
  snap = value
  lastSnapMs = nowMs()
  render()
end)

-- update() is never called by the host for panels in this build (verified
-- with a live counter probe). Kept as a harmless no-op so the entry stays
-- API-correct if a future build starts ticking panels.
function update()
end

-- Lyric cursor helpers. cursorLine is 1-based over s.lyrics; 0 = follow the
-- active playback line. moveCursor starts from the active line (or line 1
-- before the first timestamp — fixes the frozen window until the first
-- words), steps by delta and re-centers the window on the cursor.
local function activeIndex(s)
  local pos = interpPos(s)
  local active = -1
  local n = #(s.lyrics or {})
  for i = 1, n do
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time <= pos) then active = i end
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time > pos) then break end
  end
  return active
end

local function moveCursor(delta)
  local s = snap
  if not s or not s.lyrics or #s.lyrics == 0 then return end
  local n = #s.lyrics
  local cur = cursorLine
  if cur < 1 or cur > n then
    cur = activeIndex(s)
    if cur < 1 then cur = 1 end
  end
  cursorLine = math.max(1, math.min(n, cur + delta))
  render()
end

-- Activate the line under the cursor: seek the player to its timestamp
-- (synced lyrics only — plain lines have no timestamps).
local function seekCursor()
  local s = snap
  if not s or not s.synced or not s.lyrics then
    cursorLine = 0
    render()
    return
  end
  local cur = cursorLine
  if cur < 1 or cur > #s.lyrics then
    cur = activeIndex(s)
    if cur < 1 then
      cursorLine = 0
      render()
      return
    end
  end
  local lineTime = s.lyrics[cur].time
  if lineTime >= 0 then
    sendCmd("seekTo", { sec = lineTime })
  end
  cursorLine = 0
  render()
end

function onOpen(_context)
  cursorLine = 0
  -- second ticks keep position + lyrics moving between service polls
  panel.setWantsSecondTicks(true)
  noctalia.state.set("panel_req", { action = "refresh" })
  render()
end

-- Manual lyric scroll. The host's chord validator accepts only a small set
-- of key names (Up/Down/Left/Right/Return/Space/Escape/Tab — used by
-- community plugins); PageUp/PageDown/Home/End are REJECTED by the catalog
-- scan and drop the plugin from the store, so only Up/Down/Return/Space are
-- declared. Up/Down step the cursor, Return/Space seek to the cursor line.
-- The window never leaves [1..n] (clamped in buildLyricsBody).
function onKey(chord, pressed)
  if not pressed then return end
  if chord == "Up" then
    moveCursor(-1)
  elseif chord == "Down" then
    moveCursor(1)
  elseif chord == "Return" or chord == "Space" then
    seekCursor()
  end
end

-- Docs say onScroll is a bar-widget callback, but declare it anyway: if the
-- host delivers wheel events to panels, this makes wheel scrolling step the
-- lyric cursor. Harmless no-op otherwise.
function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or startsGesture then return end
  local dir = (steps or 0) > 0 and 1 or -1
  moveCursor(dir)
end