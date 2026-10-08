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
--   * no arc primitive exists, and VERTICAL progress bars do not render at
--     all, so the v0.1 8-segment perimeter ring and the per-edge bars were
--     dropped for a single horizontal seek control under the art. It is a
--     ui.slider, not a ui.progress: the host never hands a plugin the pointer
--     coordinates of a click, and ui.progress is display-only, so a slider is
--     the only way to make the bar seekable (the same control the shell's own
--     control-center media tab uses);
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

  -- cover
  cover = 50,             -- inner cover size (logical px)
  coverRadius = 10,       -- inner cover corner radius

  -- typography
  fsOverline = 11,        -- chrome header / footer
  fsTitle = 19,
  fsMeta = 13,
  fsTime = 12,
  fsActiveLyric = 17,
  fsNearLyric = 15,
  fsFarLyric = 14,
  fsCountdown = 44,       -- karaoke 3-2-1 lead-in digit (big, above the centre line)

  -- colors (state colors live here too)
  colOverline = "on_surface_variant",
  colTitle = "on_surface",
  colMeta = "on_surface_variant",
  colTime = "on_surface_variant",
  ringTrack = "outline/0.5",      -- cover frame border (the progress control
  lyricActive = "primary",        -- is a ui.slider, which colours itself)
  lyricNear = "on_surface",
  lyricFar = "on_surface_variant",
  footer = "on_surface_variant/0.7",
  hairline = "outline/0.35",
  emptyState = "on_surface_variant",
}

local snap = nil       -- latest snapshot from the service
local cursorLine = 0   -- keyboard/scroll cursor over lyric lines (0 = follow playback)
local hoveredLine = 0  -- pointer hovered lyric line (0 = none); applied on the next render

-- Seek slider state (progress bar). While the user drags, the host owns the
-- thumb and re-applies `value` only when `!slider->dragging()`. Once released,
-- the target is held live in `seekPending` until playback actually reaches it,
-- so the bar neither snaps back while the service's D-Bus SetPosition is in
-- flight nor freezes when the snapshot arrives at the OLD position (a Firefox
-- MPRIS quirk: SetPosition resumes playback and reports the old position for a
-- moment). The same hold is applied to EVERY seek route - slider, lyric-line
-- click, keyboard cursor - so clicking a lyric line no longer leaves the bar
-- stuck. A seek the player never honoured expires after SEEK_HOLD_MS.
local SEEK_HOLD_MS = 15000
local seekPending = -1        -- seconds queued for seek, -1 = none
local seekQueuedAt = 0        -- ms of the request (0 = nothing pending)

local showCandidates = false -- "choose lyrics" selector open (toggled by the header button)
local marqueePaused = false -- pointer over the title/artist block pauses marquees
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

-- Single entry point for every seek (slider, lyric-line click, keyboard cursor):
-- remembers the target and marks it at once. MUST be defined after sendCmd and
-- nowMs - they are `local function`s, so a definition placed earlier would
-- capture them as nil globals and every seek would fail with
-- "attempt to call a nil value". The host is NOT guaranteed to re-run the
-- slider's onChange, so the caller must not rely on that callback to set the hold.
local function queueSeek(sec)
  sec = tonumber(sec)
  if not sec then return end
  seekPending = sec
  seekQueuedAt = nowMs()
  sendCmd("seekTo", { sec = sec })
end

-- marquee phase state lives at module scope: buildInfoRow runs on EVERY
-- render, and a per-render table would reset elapsed to 0 each tick.
local marqueeState = {}   -- [key] = { text, elapsed }

-- ============================= lyrics rendering =============================

-- (visibleLines lives below the width constants: it needs LYR_WIDTH, which - as
-- a `local` - must be declared before it, or it would resolve to a nil global.)

-- Header layout per panel preset. Spacing is uniform everywhere: the
-- cover-to-text gap, the text-to-transport gap and the header's own side
-- insets all use GAP_PX (12 px - the cover-to-text gap the owner standardised
-- on in the mini panel). The cover is ONE size in every preset: compact used to
-- run a 36 px cover while medium/large ran 50/56, which read as a bug ("только
-- в режиме compact обложка меньше чем во всех остальных"). The text column is
-- computed to take ALL the width left between the cover, the two gaps and the
-- transport block - no dead slot (a flexGrow spring used to swallow ~127 px
-- while the title was still truncated).
local GAP_PX = 12
local COVER_PX = 50
local function panelLayout()
  local sz = noctalia.getConfig("panel_size")
  -- transport block width (prev + play + next + the time label under them),
  -- measured live per preset; it scales with the button tiers.
  if sz == "compact" then
    return { cover = COVER_PX, gapInline = GAP_PX, transport = 120, textW = 224, ctl = 14, main = 18 }
  elseif sz == "large" then
    return { cover = COVER_PX, gapInline = GAP_PX, transport = 150, textW = 398, ctl = 20, main = 24 }
  end
  return { cover = COVER_PX, gapInline = GAP_PX, transport = 132, textW = 296, ctl = 18, main = 22 }
end

-- (the karaoke window is symmetric around the anchor line; see buildLyricsBody)

-- Long lyric lines must not spill past the panel edge: a ui.label wider
-- than the panel is clipped at the surface edge (verified live — compact
-- 440 px panel cut ~47+ char lines mid-word). ui.label DOES render "\n"
-- (verified live), so long lines are soft-wrapped into sub-lines. Glyph
-- budget: advance factor 0.62 em measured live on this host at scale 1.5
-- (mixed-case text, incl. spaces); bold/medium run wider and get a bump.
-- Width per preset measured live: the panel surface itself (compact 440 /
-- medium 520 / large 640); wrapLyric subtracts WRAP_GUTTER (root padding plus
-- a small margin so a flush-fitting line breaks instead of touching the edge).
local LYR_WIDTH = { compact = 440, medium = 520, large = 640 }
-- Wrap safety gutter: a line whose advance width lands exactly on the content
-- width renders its last glyph flush against the panel border (seen live: the
-- final "m" of "...my doom" touched the edge). Keep the wrap a little inside
-- so flush-fitting lines break instead of kissing the frame - the same rule
-- the mini panel uses. The width is the panel surface; the gutter covers the
-- root padding plus that margin.
local WRAP_GUTTER = 24

-- Vertical budget: how many REAL rows the lyrics area holds. The presets' panel
-- heights are 440/520/640; the header band, the seek slider and the footer take
-- roughly the first 120 px and the bottom ~45 px, leaving an area that a
-- measured row pitch (~29 px: 17 px glyphs on a 21 px line box + the 6 px gap)
-- actually fits. Verified against a live screenshot at scale 2: the medium panel
-- area is 357 px and a rendered row is 29 px, so 14 rows overflowed the bottom
-- edge by ~50 px and the last line was clipped - the reported "text climbs onto
-- the panel edge". Sizes stay on the 2-3-4 step so a compact panel can never
-- budget MORE rows than a large one.
local LYR_AREA_PX = { compact = 278, medium = 357, large = 477 }
local LYR_ROW_PX = 29
local function visibleLines()
  local sz = noctalia.getConfig("panel_size")
  return math.floor((LYR_AREA_PX[sz] or LYR_AREA_PX.medium) / LYR_ROW_PX)
end
-- Per-character advance widths in em, MEASURED live on this host (12-char runs
-- beside a 100 px reference bar, scale 1: i/l 0.27, m 0.92, w 0.79, a 0.56,
-- A 0.64, space 0.28). A flat per-character factor cannot work here: the
-- spread between the narrowest and widest glyph is 3.4x. The old count-based
-- budget (42 chars for an active fs17 line) rejected a 51-char line that
-- actually renders at ~333 px inside the 474 px content width, so lines that
-- fit were wrapped as soon as they became active. Bold runs ~5% wider.
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
local function charAdv(c)
  local o = string.byte(c) or 32
  if o >= 0x80 then return 1.0 end                      -- CJK / emoji: full width
  if c == " " then return 0.28 end
  if c == "i" or c == "l" or c == "I" then return 0.27 end
  if c == "m" then return 0.92 end
  if c == "w" or c == "M" or c == "W" then return 0.80 end
  if c == "." or c == "," or c == ":" or c == ";" or c == "'" or c == "!"
     or c == "|" or c == "`" then return 0.28 end
  if c == "(" or c == ")" or c == "[" or c == "]" or c == "{" or c == "}" then return 0.35 end
  if c == "j" or c == "t" or c == "f" or c == "r" then return 0.39 end
  if string.find("ABCDGHNOQRUVXY", c, 1, true) then return 0.64 end
  return 0.56
end
local function unitEm(text)
  local u = 0
  for _, ch in ipairs(toChars(text)) do u = u + charAdv(ch) end
  return u
end
local ADV_SPACE = 0.28

-- Split a lyric line into display sub-lines that fit the panel width, measured
-- in em (unitEm) against the per-size capacity, NOT in character counts.
-- Word-aware and BALANCED: a line needing exactly two sub-lines breaks near the
-- middle; longer lines fill whole chunks. A single word wider than the whole
-- line is hard-sliced (never splitting a UTF-8 sequence). Returns the original
-- string when it already fits. `reserved` shrinks the budget (cursor chevron).
local function wrapLyric(text, fontSize, fontWeight, reserved)
  if text == nil or text == "" then return text end
  local sz = noctalia.getConfig("panel_size") or "medium"
  local maxW = (LYR_WIDTH[sz] or LYR_WIDTH.medium) - WRAP_GUTTER - (reserved or 0)
  if maxW < 10 then maxW = 10 end
  local wf = (fontWeight == "bold" and 1.062) or (fontWeight == "medium" and 1.023) or 1.0
  local capEm = maxW / (fontSize * wf)          -- line capacity in em units
  local total = unitEm(text)
  if total <= capEm then return text end
  local words = {}
  for w in (text .. " "):gmatch("(.-) ") do
    words[#words + 1] = w
  end
  -- Balanced two-line break: both halves must fit, difference minimised.
  if #words >= 2 and total <= capEm * 2 then
    local wEm = {}
    for i = 1, #words do wEm[i] = unitEm(words[i]) end
    local best, bestScore, aEm = nil, math.huge, 0
    for i = 1, #words - 1 do
      aEm = aEm + wEm[i] + (i > 1 and ADV_SPACE or 0)
      local bEm = total - aEm - ADV_SPACE
      if aEm <= capEm and bEm <= capEm then
        local score = math.abs(aEm - bEm)
        if score < bestScore then best, bestScore = i, score end
      end
    end
    if best then
      local a, b = {}, {}
      for j = 1, best do a[#a + 1] = words[j] end
      for j = best + 1, #words do b[#b + 1] = words[j] end
      return table.concat(a, " ") .. "\n" .. table.concat(b, " ")
    end
  end
  -- Three-or-more (or an unbalanced leftover): greedy word fill.
  local out, cur, curEm = {}, "", 0
  for i = 1, #words do
    local w = words[i]
    local wEm = unitEm(w)
    if wEm > capEm then
      -- hard-slice by em, never splitting a UTF-8 sequence
      if cur ~= "" then out[#out + 1] = cur; cur, curEm = "", 0 end
      local acc, accEm = "", 0
      for _, ch in ipairs(toChars(w)) do
        local ce = charAdv(ch)
        if acc ~= "" and accEm + ce > capEm then
          out[#out + 1] = acc; acc, accEm = "", 0
        end
        acc = acc .. ch
        accEm = accEm + ce
      end
      cur, curEm = acc, accEm
    elseif cur == "" then
      cur, curEm = w, wEm
    elseif curEm + ADV_SPACE + wEm <= capEm then
      cur = cur .. " " .. w
      curEm = curEm + ADV_SPACE + wEm
    else
      out[#out + 1] = cur
      cur, curEm = w, wEm
    end
  end
  if cur ~= "" then out[#out + 1] = cur end
  return table.concat(out, "\n")
end

-- Countdown state for the karaoke lead-in: a 3-2-1 shown ONLY in the last three
-- seconds before the first line. The window is capped, not just the value: a
-- long intro must show NOTHING (a bare min(3, ceil(remaining)) would clamp 38 s
-- down to "3" and pin a stale digit to the panel for the whole intro). A track
-- whose first line starts within three seconds simply enters the window at its
-- real second (2 -> 1 -> line).
local function countdownValue(s)
  local lines = s.lyrics or {}
  local first = lines[1] and lines[1].time or -1
  if not (first and first > 0) then return 0 end
  local pos = interpPos(s)
  local remaining = first - pos
  if remaining <= 0 or remaining > 3 then return 0 end
  local active = -1
  for i = 1, #lines do
    if (lines[i].time >= 0) and (lines[i].time <= pos) then active = i end
    if (lines[i].time >= 0) and (lines[i].time > pos) then break end
  end
  if active >= 1 then return 0 end
  return math.ceil(remaining)
end

-- The countdown digit is placed INSIDE the empty lyric slots above the first
-- line (pre-start only): those slots merge into one box whose height matches
-- the slots it replaces, so the block never changes and the digit reads as
-- centred between the progress bar and the first line. A row with
-- align = "center" centres the label on the cross (vertical) axis - verified
-- live; the nested-flex variant did not.
local function countdownSlotHeight(halfSlots)
  -- exactly replaces the `halfSlots` empty slot cells the digit overwrites, so
  -- the pre-start block is the same height as the plain-spacer layout. Uses the
  -- same measured row pitch as SLOT_H - the old fs*1.25 estimate (27 px) no
  -- longer matches a real row (29 px) and left the box 2 px per slot short.
  return halfSlots * LYR_ROW_PX
end

local function buildLyricsBody(s)
  local lines = s.lyrics or {}
  local n = #lines

  if s.lyricsStatus == "loading" then
    return { ui.label({ text = noctalia.tr("panel.loading-lyrics"), color = T.colMeta,
      fontSize = T.fsFarLyric, fontWeight = "medium", textAlign = "center" }) }
  end
  if s.lyricsStatus == "choose" and showCandidates then
    -- Lyrics-variant selector: a "Default" row (restore the automatic chain
    -- result, shown when any default source actually loaded) followed by the
    -- LRCLIB search candidates. The active variant is highlighted; picking a
    -- row applies it WITHOUT clearing the list, so the user can switch again
    -- immediately. Each row is a button that sends chooseLyrics with the
    -- 1-based index (0 = Default).
    local cands = s.lyricsCandidates or {}
    local rows = {}
    local vi = s.lyricsVariantIndex or 0
    -- "Default" row: shown when there is something to restore — either the
    -- automatic chain lyrics are live right now (variantIndex == 0) or a
    -- picked variant is active (variantIndex > 0): "Default" re-runs the
    -- automatic chain for this track.
    local hasDefault = (vi == 0 and (s.lyricsProvider or "") ~= "" and #(s.lyrics or {}) > 0)
      or vi > 0
    if hasDefault then
      local defLabel = noctalia.tr("panel.variant-default")
        .. (vi == 0 and s.lyricsProvider ~= "" and (" (" .. s.lyricsProvider .. ")") or "")
      rows[#rows + 1] = ui.button({
        key = "candDef",
        text = defLabel,
        fontSize = T.fsFarLyric,
        color = T.lyricActive,
        fill = "surface_variant/0.4",
        radius = 8,
        padding = 6,
        onClick = function()
          showCandidates = false
          noctalia.state.set("panel_req", { action = "chooseLyrics", index = 0 })
        end,
      })
    end
    for i, c in ipairs(cands) do
      local label = (c.title or "") .. " — " .. (c.artist or "")
      if (c.album or "") ~= "" then label = label .. " (" .. c.album .. ")" end
      local isActive = (s.lyricsVariantIndex == i)
      rows[#rows + 1] = ui.button({
        key = "cand" .. i,
        text = (isActive and "● " or "") .. label,
        fontSize = T.fsFarLyric,
        color = isActive and T.lyricActive or T.colTitle,
        fill = "surface_variant/0.4",
        radius = 8,
        padding = 6,
        onClick = function()
          showCandidates = false
          noctalia.state.set("panel_req", { action = "chooseLyrics", index = i })
        end,
      })
    end
    if #rows == 0 then
      -- No default loaded and no candidates found (e.g. network down or a
      -- genuinely unknown track): say so instead of rendering an empty list.
      return { ui.label({ text = noctalia.tr("panel.no-variants"),
        color = T.emptyState, fontSize = T.fsFarLyric, textAlign = "center" }) }
    end
    return rows
  end
  if s.lyricsStatus == "error" then
    return { ui.label({ text = noctalia.tr("panel.lyrics-error") .. (s.lyricsError or ""),
      color = "error", fontSize = T.fsFarLyric, textAlign = "center" }) }
  end
  if (s.lyricsStatus == "choose" or s.lyricsStatus == "ready") and #(s.lyrics or {}) > 0 then
    -- ready, or "choose" with the picker closed (or a picked variant live):
    -- render the karaoke/plain lyrics that are actually loaded.
    if not s.synced then
      -- unsynced: static list inside a clipping scroll (a bare column does not
      -- clip its children), dimmed, centered, generous line spacing. The
      -- keyboard cursor still highlights a line (no seek — no timestamps).
      local rows = {}
      for i, l in ipairs(lines) do
        local isCursor = (i == cursorLine)
        -- Build the children list conditionally — a literal
        -- `cond and node or nil` inside the children array emits a nil
        -- child, which the host logs as "ui tree node is not a table".
        local rowChildren = {}
        if isCursor then
          rowChildren[#rowChildren + 1] = ui.glyph({
            key = "cur" .. i,
            name = "chevron-right",
            size = 11,
            color = T.lyricActive,
          })
        end
        rowChildren[#rowChildren + 1] = ui.label({
          key = "lbl" .. i, text = wrapLyric(l.text, T.fsFarLyric, "normal", isCursor and 16 or 0),
          fontSize = T.fsFarLyric,
          color = isCursor and T.lyricActive or T.lyricNear,
          opacity = isCursor and 1 or 0.8, textAlign = "center",
        })
        rows[#rows + 1] = ui.row({
          key = "lyr" .. i,
          align = "center", justify = "center",
        }, rowChildren)
        rows[#rows + 1] = ui.spacer({ key = "lgap" .. i, height = T.gapMicro })
      end
      -- The unsynced list is a FILLING body: it must own the whole lyrics area
      -- and scroll inside it. It must NOT be wrapped in the balanced flexGrow
      -- centering spacers (see render): those exist to centre the fixed-height
      -- karaoke block, and with a third flexGrow on the scroll the free height
      -- split three ways - the list ended up a third of the area with big gaps
      -- above and below it. The second return value tells render not to centre.
      return { ui.scroll({ flexGrow = 1, align = "stretch" }, rows) }, true
    end

    -- synchronized: carousel around the playback line (karaoke fade ladder)
  local pos = interpPos(s)
  local active = -1
  for i = 1, n do
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time <= pos) then active = i end
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time > pos) then break end
  end

  -- Lyric class per line: font size / weight from the karaoke distance
  -- ladder, precomputed ONCE so the window budget and the render loop share
  -- the same values (they must never drift apart).
  local fsArr, wArr = {}, {}
  for i = 1, n do
    local isA = (i == active)
    local isC = (i == cursorLine)
    local d = math.abs(i - active)
    fsArr[i] = isA and T.fsActiveLyric or (d <= 2 and T.fsNearLyric or T.fsFarLyric)
    wArr[i] = (isA or isC) and "bold" or (d <= 2 and "medium" or "normal")
  end
  -- Wrapped lines consume more than one visual row. The window must fit a
  -- VERTICAL BUDGET of visibleLines() rows, so count the wrapped sub-lines
  -- a row needs and shrink the window until its total fits (wrapping long
  -- lines must never push the active line below the panel edge).
  local function sublines(i)
    return 1 + select(2, wrapLyric(s.lyrics[i].text, fsArr[i], wArr[i], i == cursorLine and 16 or 0):gsub("\n", ""))
  end
  -- Karaoke centering: the anchor line (the cursor while the user scrolls,
  -- otherwise the playing line - and before playback starts the first line) is
  -- pinned to the exact vertical CENTRE of the lyrics area. The window always
  -- carries the same number of slots above and below the anchor and the parent
  -- column centres the block, so the anchor stays on the centre line on load,
  -- through the track, and at the end (the last line returns to the centre
  -- instead of sticking to the bottom edge). Out-of-range slots become spacers
  -- of the same height, which keeps the symmetry exact.
  local anchor = cursorLine >= 1 and cursorLine or (active >= 1 and active or 1)
  if anchor < 1 then anchor = 1 end
  if anchor > n then anchor = n end
  -- the "current" line is the playing one only: before the first line starts
  -- nothing is highlighted yet (the opening line lights up exactly at its
  -- timestamp, not earlier - owner: "первая строчка не должна подсвечиваться
  -- сразу а только в положенный ей момент").
  local hl = active
  local budget = visibleLines()
  local half = math.floor((budget - 1) / 2)
  -- edge spacers must match a REAL row's height, measured live (~29 px: a 17 px
  -- active glyph on its 21 px line box plus the 6 px micro gap) - NOT fs*1.25,
  -- which under-sized the slot at 27 px and let the block run past the area.
  local SLOT_H = LYR_ROW_PX
  -- shrink the side slots if wrapped sub-lines would overflow the area
  while half > 0 do
    local used = 0
    for k = -half, half do
      local idx = anchor + k
      if idx >= 1 and idx <= n then used = used + sublines(idx) end
    end
    if used <= budget then break end
    half = half - 1
  end
  local rows = {}
  local countdown = countdownValue(s)
  -- slots are a plain sequence (rows must be a dense array: negative keys are
  -- invisible to ipairs/#, which silently dropped the left half of the window)
  for si = 1, (2 * half + 1) do
    local k = si - 1 - half
    local idx = anchor + k
    if idx >= 1 and idx <= n then
      local isActive = (idx == hl)
      local isCursor = (idx == cursorLine)
      local isHover = (idx == hoveredLine)
      local dist = math.abs(idx - active)
      local fontSize = (idx == active) and T.fsActiveLyric or fsArr[idx]
      local fontWeight = (idx == hl) and "bold" or wArr[idx]
      local color = (isActive or isCursor or isHover) and T.lyricActive
        or (dist <= 2 and T.lyricNear or T.lyricFar)
      local opacity = (isActive or isCursor or isHover) and 1
        or (dist <= 2 and 0.9 or (dist <= 5 and 0.55 or 0.3))
      local lineTime = s.lyrics[idx].time
      -- Clickable line: ui.label does not accept onClick and ui.button
      -- ignores color/fontWeight (would break the karaoke gradient), so wrap
      -- the label in a ui.row that owns the click target. Seek only when the
      -- line has a timestamp. The cursor row gets a leading chevron marker.
      -- Hovering a row highlights it by shifting the text colour/opacity only
      -- (no background fill: the tint lingered after the pointer left the row
      -- on this host, while colour alone reads as a clean hover and matches the
      -- active-line treatment).
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
        text = wrapLyric(s.lyrics[idx].text, fontSize, fontWeight, isCursor and 16 or 0),
        fontSize = fontSize,
        fontWeight = fontWeight,
        color = color,
        opacity = opacity,
        textAlign = "center",
      })
      local rowProps = {
        key = "lyr" .. idx,
        align = "center", justify = "center",
        onClick = (lineTime >= 0) and function() queueSeek(lineTime) end or nil,
      }
      -- Hover highlight without a crash: NEVER call render() inside onHover —
      -- re-creating the tree mid-event-dispatch kills the host (plugin got
      -- disabled). The panel already re-renders ~6x/s on the media watch, so
      -- hovering only sets a flag and the next watch tick repaints it.
      rowProps.onHover = function(state)
        local want = (state == "true") and idx or 0
        if want ~= hoveredLine then hoveredLine = want end
      end
      rows[si] = ui.row(rowProps, children)
    elseif countdown > 0 and k >= -half and k <= -1 then
      -- pre-start: the empty slots above the first line merge into one box
      -- carrying the 3-2-1 digit, centred on the vertical axis by align. Only
      -- the topmost carries it; the rest collapse (no height, no gap) so the
      -- block's total height stays the same as with plain spacers.
      if k == -half then
        rows[si] = ui.row({
          key = "countdown", align = "center", justify = "center",
          height = countdownSlotHeight(half),
        }, {
          ui.label({
            key = "countdownLabel", text = tostring(countdown),
            fontSize = T.fsCountdown, fontWeight = "bold",
            color = T.lyricActive, opacity = 0.95, textAlign = "center",
          }),
        })
      else
        rows[si] = ui.spacer({ key = "gap" .. si, height = 0, visible = false })
      end
    else
      -- keep the symmetry: an empty slot is the same height as a text row, so
      -- the anchor line stays exactly on the centre line at the track's start
      -- and end (the block is centred by the parent column).
      rows[si] = ui.spacer({ key = "gap" .. si, height = SLOT_H })
    end
  end
  return rows
  end
  -- No lyrics after the whole chain (and the picker shows nothing else):
  return { ui.label({ text = noctalia.tr("panel.no-lyrics"), color = T.emptyState,
    fontSize = T.fsFarLyric, fontWeight = "medium", textAlign = "center" }) }
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
    -- no art: show a fallback disc glyph
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

  -- Seekable slider, the same control the shell's own control-center media tab
  -- uses (src/shell/control_center/tabs/media_tab.cpp: ui::slider + onValueChanged
  -- + onDragEnd). This is the canonical route: the host does NOT hand a plugin
  -- the pointer coordinates of a click, and ui.progress is display-only, but
  -- ui.slider owns its own pointer handling - drag to scrub, click to jump, and
  -- the host skips re-applying `value` while the thumb is held. Seeking reuses
  -- the transport the lyric lines already click through (panel_cmd "seekTo").
  local seekMax = (total > 0) and total or 0.001
  -- While a queued seek is still landing, keep showing its target rather than
  -- the not-yet-updated position (see seekPending/seekQueuedAt). Three cases,
  -- and the LANDED case must clear the pending first:
  --   landed       -> the player is on (or within tolerance of) the target, so
  --                   drop the pending and hand the bar back to the live
  --                   position. This must be the first test: the earlier version
  --                   required convergence AND the age timeout at the same
  --                   instant, so once playback ran past the target the first
  --                   condition became true again and the bar stayed pinned to
  --                   the target for the rest of the track (the reported freeze);
  --   too old      -> the player never honoured it; stop forcing the target;
  --   in flight    -> show the target, not the stale snapshot position.
  local queued = tonumber(seekPending) or -1   -- host may deliver values as strings
  if queued >= 0 then
    local live = tonumber(s.posSec) or 0
    if math.abs(live - queued) <= 0.5 then
      seekPending = -1
      seekQueuedAt = 0
    elseif seekQueuedAt > 0 and (nowMs() - seekQueuedAt) > SEEK_HOLD_MS then
      seekPending = -1
      seekQueuedAt = 0
    else
      cur = queued
      frac = math.min(1, cur / seekMax)
    end
  end

  -- The host calls setValue() on every render, and setValue fires
  -- onValueChanged - so a naive onChange receives the value we just painted
  -- back on every 150 ms snapshot and seeks to it, dragging the track along in
  -- steps. The reconciler only calls setValue when `value` actually changed, so
  -- the echo always carries the exact number we rendered; a real interaction
  -- (click, drag, wheel) carries a different one. Ignore anything that matches
  -- what we last painted. (The shell's media tab guards the same feedback with
  -- m_syncingProgress; a plugin cannot set that flag, so it compares values.)
  local painted = frac * seekMax
  local function onScrub(v)
    -- onChange fires on every move while dragging and once on a plain click.
    -- The host formats the value with std::format("{}", value), i.e. it arrives
    -- as a STRING in Luau (despite the docs saying "a number for a slider") -
    -- coerce it before handing it to the service, which does arithmetic on it.
    local sec = tonumber(v)
    if not sec then return end
    if math.abs(sec - painted) < 0.5 then return end   -- echo of our own value
    queueSeek(sec)                 -- hold + send in one place (the host may not
  end                              -- re-fire onChange, so never rely on it here)

  return ui.slider({
    key = "seek",
    -- No width prop: a `column` stretches its children across the cross axis
    -- (FlexAlign::Stretch on the ui.* layer), which is what makes the slider span
    -- the panel exactly like the old ui.progress did. A string width such as
    -- "stretch" is NOT parsed (the reconciler reads `width` as a number), and a
    -- ui.row wrapper would stretch on the wrong axis and leave the slider at the
    -- host's 180 px sliderDefaultWidth.
    min = 0, max = seekMax, step = 1,
    value = painted,
    enabled = (s.hasPlayer == true) and (total > 0),
    controlSize = "sm",
    onChange = onScrub,
    -- the host calls onDragEnd with no value; the last onChange already
    -- queued the target, so this only marks the interaction as finished.
    onDragEnd = function() seekQueuedAt = nowMs() end,
  })
end

-- ============================= header (cover + info + transport) =============================

local function buildInfoRow(s)
  local L = panelLayout()
  if not s.hasPlayer then
    return { ui.row({ key = "noplayer", height = L.cover, align = "center" }, {
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
  -- The column takes ALL the width left between the cover gap and the
  -- transport gap (flexGrow = 1 below) so the title uses the free area instead
  -- of being clamped to a fixed 168 px slot while a spring idles beside it.
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
  local artistLine = singleLine(s.artist ~= "" and s.artist or noctalia.tr("common.unknown-artist"))
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
    -- Exact per-glyph advance in em - the same measured table wrapLyric uses
    -- (charAdv). The previous flat 0.72 em/char over-estimated mixed-case
    -- titles by ~30%, so the marquee window came out far narrower than the
    -- slot and the title ended in open space (owner: "окно для текста обрезано").
    return charAdv(char)
  end
  local function textUnits(text)
    local u = 0
    for _, ch in ipairs(toChars(text)) do u = u + charUnits(ch) end
    return u
  end
  -- viewport capacity in width units, PER FONT SIZE: units are em-fractions
  -- (charUnits = em fraction), so capacity = usable px / fontSize. The lines now
  -- render as ui.label (no button chrome), so the full column width is usable -
  -- the old -26 px reserved button inner padding and left a gap on the right.
  local function vwUnits(fs)
    return TEXT_W / fs
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
    -- key is STABLE (no slice suffix): the node is kept across scroll frames,
    -- only its text is re-rendered in place. A per-slice key forced a fresh node
    -- recreation each frame, which re-dirties the surface and makes the compositor
    -- re-blur it -> visible blink on some GPUs (issue #649 on AMD Barcelo).
    -- In-place text swaps may briefly overlap glyphs at the marquee edge, but that
    -- is far less disruptive than the per-frame surface churn.
    -- Render with ui.label, not ui.button: the column stretches to the free
    -- width, and a label's textAlign = "start" reliably pins the text to the
    -- left (a stretched button centred its caption - contentAlign had no
    -- effect in a panel, so short titles floated in the middle of the slot).
    return ui.label({
      key = key, text = shown, fontSize = fs, fontWeight = weight,
      color = colr, textAlign = "start", maxLines = 1, width = TEXT_W,
      height = math.floor(fs * 1.35 + 0.5),
    })
  end

  -- advance marquee timers between renders (called from update())
  -- Hovering the title/artist block pauses scrolling: keep the phase frozen
  -- (do NOT accumulate elapsed) so the marquee does not fast-forward past a
  -- long hover and resume with a jump.
  tickMarquee = function(deltaSec)
    if marqueePaused then return end
    for _, st in pairs(marqueeState) do st.elapsed = st.elapsed + deltaSec end
  end
  local infoCol = ui.column({
    -- Fixed width (TEXT_W) with align = "start": the column's children stretch
    -- to that width and are pinned left, so the title starts right after the
    -- cover. A flexGrow column instead centred its children (flexGrow + start
    -- on the cross axis conflict) and a start-only column collapsed the label
    -- to its text, which then centred inside the free space.
    key = "infoCol", gap = 3, align = "start", width = TEXT_W,
    -- hover pauses the marquees under the pointer; onHover true is always
    -- matched by a false, so a hover-away resumes scrolling cleanly.
    onHover = function(state, key)
      local want = (state == "true")
      if want ~= marqueePaused then
        marqueePaused = want
      end
    end,
  }, {
    textLine("ttl", singleLine(s.title ~= "" and s.title or noctalia.tr("common.no-title")),
      T.fsTitle, "semibold", T.colTitle),
    textLine("art", artistLine, T.fsMeta, "regular", T.colMeta),
  })

  -- single band, everything centered on the art's vertical axis.
  -- Both inline gaps use the same GAP_PX as the cover-to-text gap, and there is
  -- no flexGrow spring: the info column stretches, so the header reads with one
  -- rhythm and the free width lands in the text (not in an empty slot).
  return {
    ui.row({ key = "infoRow", align = "center", justify = "start", height = 62 }, {
      ui.column({ key = "coverWrap", gap = 1, align = "center",
        width = L.cover + 2 }, {
          cover,
        }),
      ui.spacer({ key = "coverGap", width = L.gapInline }),
      infoCol,
      ui.spacer({ key = "transportGap", width = L.gapInline }),
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
  if s.lyricsStatus == "ready" or ((s.lyricsStatus == "choose") and #(s.lyrics or {}) > 0) then
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
        -- "Lyrics variants" button: ALWAYS visible while a track is loaded
        -- (not only when the chain ended in a "choose" state). Opens the
        -- variant selector: the service fetches LRCLIB search candidates on
        -- demand and keeps the playing lyrics untouched until a row is picked.
        ui.button({ glyph = "list", glyphSize = 14, variant = "ghost", controlSize = "sm",
          width = 22, height = 22,
          visible = s.hasPlayer == true and (s.title or "") ~= "",
          tooltip = noctalia.tr("panel.choose-lyrics"),
          onClick = function()
            showCandidates = not showCandidates
            if showCandidates then
              -- (re)open: always ask the service for a fresh candidate list
              noctalia.state.set("panel_req", { action = "openLyricChoices" })
            end
            render()
          end }),
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
    -- C. lyrics (flexGrow). The block is centred with a balanced flexGrow
    -- spacer above and below (this host ignored justify = "center" on the
    -- column, verified live) - so the anchor line sits on the centre line.
    (function()
      local nodes, fills = buildLyricsBody(s)
      local kids = {}
      -- Centre the karaoke block with balanced flexGrow spacers (this host
      -- ignored justify = "center" on the column, verified live), but leave a
      -- FILLING body (the unsynced scroll list) to own the whole area: adding
      -- spacers there would split the free height three ways.
      if not fills then kids[#kids + 1] = ui.spacer({ key = "lyricsTopFlex", flexGrow = 1 }) end
      for i = 1, #nodes do kids[#kids + 1] = nodes[i] end
      if not fills then kids[#kids + 1] = ui.spacer({ key = "lyricsBotFlex", flexGrow = 1 }) end
      return ui.column({ key = "lyrics", flexGrow = 1, gap = T.gapMicro }, kids)
    end)(),
    -- D. footer: provider - mode
    ui.label({ key = "footer", text = footerTxt, fontSize = T.fsOverline,
      color = T.footer, visible = footerTxt ~= "" }),
  }))
end

-- ============================= state wiring =============================

-- VERIFIED BY PROBE (this host build): the host NEVER calls update() or
-- onFrameTick for [[panel]] entries — both counters stayed 0 with
-- setWantsSecondTicks(true) + setNeedsFrameTick(true). The ONLY periodic
-- signal a panel gets is the service's media publishes (POLL_MS = 150ms):
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
    hoveredLine = 0
    -- a new track invalidates the variant picker: close it and reset local
    -- open-state (the service drops its own list in invalidateLyrics()).
    showCandidates = false
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
  hoveredLine = 0
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
    queueSeek(lineTime)
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