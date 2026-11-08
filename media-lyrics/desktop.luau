--!nonstrict
-- Desktop widget: now-playing + synced lyrics as a background layer-shell tile.
--
-- Why this exists (ROADMAP "pinned to desktop"): a persistent *panel* still goes
-- away when no panel surface is up, so "pin to the desktop" cannot be done with
-- panels. Noctalia gives plugins a real `[[desktop_widget]]` entry kind: a
-- background surface on the desktop (and on the lockscreen) that lives
-- independently of every panel. Available at plugin_api 20, i.e. below ours.
--
-- Verified live on Noctalia 5.2.0: the entry loads, gets a surface, and survives
-- with no panel open.
--
-- It is a THIN CLIENT, exactly like the panel and the bar chip: state comes from
-- noctalia.state("media") published by the service every 150 ms, and commands go
-- back over noctalia.state("panel_cmd") — the same channel the panel uses, so the
-- desktop widget drives the very same service.

local snap = nil

-- ── settings ────────────────────────────────────────────────────────────────

local function cfgBool(key, fallback)
  local ok, v = pcall(function() return noctalia.getConfig(key) end)
  if ok and type(v) == "boolean" then return v end
  return fallback
end

local function cfgInt(key, fallback, lo, hi)
  local ok, v = pcall(function() return noctalia.getConfig(key) end)
  local n = (ok and tonumber(v)) or fallback
  n = math.floor(n)
  if lo and n < lo then n = lo end
  if hi and n > hi then n = hi end
  return n
end

-- ── helpers ─────────────────────────────────────────────────────────────────

local function fmtTime(sec)
  sec = math.max(0, math.floor(tonumber(sec) or 0))
  local m = math.floor(sec / 60)
  local s = sec % 60
  return string.format("%d:%02d", m, s)
end

local function singleLine(text)
  text = tostring(text or "")
  -- Use REAL escapes here, never the percent-r / percent-n / percent-t shorthand:
  -- in this runtime those are not character classes, they degrade to the literal
  -- letters r, n and t, so such a class silently means "any run of r/n/t" and
  -- eats those letters out of the string ("The Chemical Brothers" ->
  -- "The Chemical B o he s"). Cyrillic text is unaffected, which is why the bug
  -- looked like it only hit Latin lyrics. panel.luau already gets this right.
  -- tests/run_lib_tests.lua has a source guard that fails the build if the
  -- shorthand ever comes back.
  text = text:gsub("[\r\n\t]+", " ")
  text = text:gsub("  +", " ")
  return text
end

-- ── text measurement and manual wrapping ───────────────────────────────────
-- The host does NOT wrap ui.label text: a line wider than the surface simply runs
-- past its edge, which is what used to widen the whole widget. panel.luau solves
-- this by breaking the string itself and relying on the label rendering an
-- embedded newline; the same approach is used here. Widths are measured in em with
-- a per-character advance table rather than in character counts, because "i" and
-- "m" are nowhere near the same width.
local function toChars(text)
  local chars, i = {}, 1
  while i <= #text do
    local b = string.byte(text, i) or 0
    local step = 1
    if b >= 0xF0 then step = 4 elseif b >= 0xE0 then step = 3 elseif b >= 0xC0 then step = 2 end
    chars[#chars + 1] = string.sub(text, i, i + step - 1)
    i = i + step
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

-- Hard-cut to a whole number of em, never splitting a UTF-8 sequence.
local function truncEm(text, capEm)
  local out, used = {}, 0
  for _, ch in ipairs(toChars(text)) do
    local a = charAdv(ch)
    if used + a > capEm then return table.concat(out) .. "…" end
    out[#out + 1] = ch
    used = used + a
  end
  return table.concat(out)
end

-- Single-line text that fits a fixed pixel width, cut with an ellipsis.
local function fit(text, widthPx, fontSize)
  if not widthPx or widthPx <= 0 then return text end
  return truncEm(text, widthPx / (fontSize or 12))
end

-- Break a line into AT MOST two display lines that fit `maxW` px at `fontSize`.
-- A line needing exactly two sub-lines breaks near the middle so the halves look
-- balanced; anything longer fills the first line and is then ellipsized, because
-- the row only reserves room for two. Returns the input unchanged when it fits.
local function wrapLyric(text, fontSize, maxW)
  local capEm = (maxW or 0) / (fontSize or 12)
  if capEm <= 0 then return text end
  -- EVERY row is returned as exactly two display lines, a short one padded with a
  -- trailing newline. The label ignores an explicit `height`, so a row of one line
  -- would otherwise be ~16px shorter than a row of two and the whole widget would
  -- grow and shrink as the lyrics change. Returning a constant number of lines is
  -- what keeps the box still.
  if unitEm(text) <= capEm then return text end
  local words = {}
  for w in (text .. " "):gmatch("(.-) ") do words[#words + 1] = w end
  if #words < 2 then return truncEm(text, capEm) end

  local wEm, total = {}, 0
  for i = 1, #words do wEm[i] = unitEm(words[i]); total = total + wEm[i] end
  total = total + ADV_SPACE * (#words - 1)

  -- Balanced two-line break, both halves must fit.
  if total <= capEm * 2 then
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

  -- Too long for two lines: fill the first, ellipsize the remainder.
  local cur, curEm = {}, 0
  for i = 1, #words do
    local add = wEm[i] + (curEm > 0 and ADV_SPACE or 0)
    if curEm + add > capEm then
      local rest = {}
      for j = i, #words do rest[#rest + 1] = words[j] end
      return table.concat(cur, " ") .. "\n" .. truncEm(table.concat(rest, " "), capEm)
    end
    cur[#cur + 1] = words[i]
    curEm = curEm + add
  end
  -- Not reachable while the early "fits on one line" check is in place, but it has
  -- to pad all the same: the row height only stays put if EVERY return is two lines.
  return table.concat(cur, " ")
end

-- Position now, interpolated from the last published sample (the service only
-- publishes every 150 ms; the desktop widget ticks on second boundaries, so a
-- naive read would step visibly).
local function interpPos(s)
  if type(s) ~= "table" then return 0 end
  local base = tonumber(s.posSec) or 0
  if not s.playing then return base end
  local at = tonumber(s.posAtMs) or 0
  if at <= 0 then return base end
  local nowMs = 0
  pcall(function() nowMs = noctalia.nowMs() end)
  if nowMs <= 0 or nowMs < at then return base end
  local pos = base + (nowMs - at) / 1000
  local len = tonumber(s.lengthSec) or 0
  if len > 0 and pos > len then pos = len end
  return pos
end

-- Which lyric line is current: the last line whose timestamp has passed.
local function activeLine(s)
  if type(s) ~= "table" or type(s.lyrics) ~= "table" then return 0 end
  local pos = interpPos(s)
  local idx = 0
  for i = 1, #s.lyrics do
    local t = tonumber(s.lyrics[i].time) or -1
    if t >= 0 and t <= pos then idx = i end
  end
  return idx
end

local function sendCmd(action)
  pcall(function() noctalia.state.set("panel_cmd", { action = action }) end)
end

-- ── render ──────────────────────────────────────────────────────────────────
--
-- GEOMETRY. The host centres the plugin's tree inside the widget's fixed box, and
-- nothing inside can stretch to fill it (flexGrow on the root does nothing), so the
-- only way to keep the header and the transport from moving — and the only way to
-- stop the "no lyrics" state collapsing into a blob in the middle — is for the tree
-- to be the SAME HEIGHT in every state. So the widget is three bands:
--
--   header    fixed height, built even when there is no player at all
--   middle    always exactly `midH` pixels, whatever it happens to contain
--   transport fixed height, disabled rather than removed when idle
--
-- Only the middle's content changes between states; its box never does, so the
-- header sits at the top and the transport at the bottom in every state alike.
--
-- Row heights below are what the host actually produces, measured on the desktop:
-- 12px text renders 16px a line, the 14px active line 18px, and a wrapped row costs
-- two lines. Guessing these wrong is what would put the geometry off.

local ROW_H = 16
local ROW_H_ACTIVE = 18
local ROW_H_FS = 12
local ROW_H_ACTIVE_FS = 14

-- A snapshot with every field the render path touches, so no branch needs a nil
-- check and the idle state lays out through exactly the same code as a playing one.
local function idleSnapshot()
  return {
    hasPlayer = false, playing = false, canGoPrev = false, canGoNext = false,
    title = "", artist = "", album = "", artUrl = "",
    lengthSec = 0, positionSec = 0, positionAt = 0,
    lyrics = nil, lyricsStatus = "none",
  }
end

local function render()
  local showArtist = cfgBool("show_artist", true)
  local showCover = cfgBool("show_cover", true)
  local wantLines = cfgInt("lines", 3, 1, 9)
  local width = cfgInt("width", 320, 160, 900)
  local useBg = cfgBool("background", false)
  local textW = width - (useBg and 30 or 0)   -- padding only exists with a card

  local live = (type(snap) == "table" and snap.hasPlayer == true)
  local s = live and snap or idleSnapshot()

  -- Height of the middle band: a full window, every row on two lines, one of them
  -- the active (taller) row. It is the WORST case, so the band never has to shrink
  -- and its content can never overflow.
  local midH = (wantLines - 1) * 2 * ROW_H + 2 * ROW_H_ACTIVE

  -- ── band 1: header ─────────────────────────────────────────────────────────
  local headKids = {}
  if showCover then
    if type(s.artUrl) == "string" and s.artUrl ~= "" and noctalia.fileExists(s.artUrl) then
      headKids[#headKids + 1] = ui.image({ key = "cover", path = s.artUrl,
        width = 56, height = 56, radius = 14, fit = "cover" })
    else
      headKids[#headKids + 1] = ui.box({ key = "coverph", width = 56, height = 56,
        radius = 14, fill = "surface_variant/0.6", border = "outline/0.5", borderWidth = 1,
        align = "center" }, {
        ui.glyph({ name = live and "disc" or "music-off", size = 30, color = "on_surface_variant" }),
      })
    end
  end

  local title = singleLine(s.title)
  if title == "" then title = noctalia.tr("panel.no-media-player") end
  local artist = singleLine(s.artist ~= "" and s.artist or s.album)
  if artist == "" then artist = noctalia.tr("common.unknown-artist") end

  local infoKids = {
    ui.label({ key = "title", text = fit(title, textW, 15), fontSize = 15, color = "on_surface" }),
  }
  if showArtist then
    infoKids[#infoKids + 1] = ui.label({ key = "artist", text = fit(artist, textW, 12),
      fontSize = 12, color = "on_surface_variant" })
  end
  headKids[#headKids + 1] = ui.column({ key = "info", gap = 2, align = "start", flexGrow = 1 }, infoKids)
  local header = ui.row({ key = "header", gap = 10, align = "center" }, headKids)

  -- ── band 2: the lyric window — a fixed number of DISPLAY lines ──────────────
  -- Two properties matter here, and both are about the widget sliding:
  --   * the band always holds the SAME number of slots, and every slot is exactly one
  --     line of text at the same font size. A label's real height cannot be measured
  --     from Lua, so a slot count that depended on wrapping — or a reserve built from
  --     guessed row heights — made the band drift as the lyrics arrived. The host
  --     centres the content inside the widget's box, so that drift moved everything;
  --   * a wrapped lyric therefore consumes two slots instead of making one row taller,
  --     and the slots that are left over are filled with a space so they still occupy
  --     a line. The current line is emphasised by colour alone, never by a bigger font,
  --     because a bigger font would make its slot taller.
  local maxSlots = math.max(1, math.floor((midH + 3) / (ROW_H + 3)))
  local slotText, slotKind = {}, {}

  local lines = (type(s.lyrics) == "table" and #s.lyrics > 0) and s.lyrics or nil
  if lines then
    local n = #lines
    -- activeLine returns 0 until the playhead passes the first timestamp
    local active = math.min(math.max(activeLine(s), 1), n)
    local function pieces(i)
      local w = wrapLyric(singleLine(lines[i].text), ROW_H_FS, textW) .. "\n"
      local out = {}
      for piece in w:gmatch("([^\n]*)\n") do out[#out + 1] = piece end
      return out
    end
    -- Grow the window around the current line until the next line would no longer fit.
    local lo, hi = active, active
    local total = #pieces(active)
    local growDown, switched = true, false
    while true do
      local cand = growDown and (hi + 1) or (lo - 1)
      local add = (cand >= 1 and cand <= n) and #pieces(cand) or nil
      if add and total + add <= maxSlots then
        if growDown then hi = cand else lo = cand end
        total = total + add
        growDown, switched = not growDown, false
      else
        if switched then break end
        growDown, switched = not growDown, true
      end
    end
    for i = lo, hi do
      local kind = (i == active) and "cur"
        or (((i == active + 1) or (i == active - 1)) and "near" or "far")
      for _, piece in ipairs(pieces(i)) do
        slotText[#slotText + 1] = piece
        slotKind[#slotKind + 1] = kind
      end
    end
  else
    -- loading / nothing found / nothing playing: the hint sits in the first slot, and
    -- the rest of the slots stay empty, so the band is the same height in every state
    slotText[1] = noctalia.tr((s.lyricsStatus == "loading") and "panel.loading-lyrics"
                                                              or "panel.no-lyrics")
    slotKind[1] = "hint"
  end

  local midNodes = {}
  for k = 1, maxSlots do
    local kind = slotKind[k]
    local color = (kind == "cur" and "primary")
      or (kind == "near" and "on_surface")
      or "on_surface_variant"
    midNodes[#midNodes + 1] = ui.label({ key = "slot" .. k,
      text = slotText[k] or " ", fontSize = ROW_H_FS, color = color })
  end

  -- ── band 3: transport ──────────────────────────────────────────────────────
  -- Always present, disabled rather than removed, so the band never changes size.
  -- The time sits opposite the transport controls. The spacer only pushes anything
  -- if the row is wider than its buttons, so the row is given the same width budget as
  -- the rest of the content — as a minimum, which is all the host honours on a column
  -- anyway.
  local transport = ui.row({ key = "transport", gap = 4, align = "center",
                             minWidth = textW }, {
    ui.button({ glyph = "player-skip-back", glyphSize = 14, variant = "ghost", controlSize = "sm",
      enabled = s.canGoPrev == true, onClick = function() sendCmd("prev") end,
      tooltip = "Previous track" }),
    ui.button({ glyph = s.playing and "player-pause" or "player-play", glyphSize = 16,
      variant = "primary", controlSize = "sm",
      enabled = s.hasPlayer == true, onClick = function() sendCmd("toggle") end,
      tooltip = s.playing and "Pause" or "Play" }),
    ui.button({ glyph = "player-skip-forward", glyphSize = 14, variant = "ghost", controlSize = "sm",
      enabled = s.canGoNext == true, onClick = function() sendCmd("next") end,
      tooltip = "Next track" }),
    ui.box({ key = "transportSlack", flexGrow = 1 }),
    ui.label({ key = "time", text = fmtTime(interpPos(s)) .. " / " .. fmtTime(s.lengthSec),
      fontSize = 11, color = "on_surface_variant" }),
  })

  -- Match the built-in desktop widgets: no card, no border, no divider by default —
  -- the content sits directly on the wallpaper. A background is opt-in, like the
  -- built-in clock and weather widgets expose.
  local rootProps = { key = "root", gap = 8, align = "start", minWidth = width }
  if useBg then
    rootProps.fill = "surface_variant/0.85"
    rootProps.radius = 14
    rootProps.padding = 14
    rootProps.border = "outline/0.35"
    rootProps.borderWidth = 1
  end

  desktopWidget.render(ui.column(rootProps, {
    header,
    ui.column({ key = "middle", gap = 3, align = "start" }, midNodes),
    transport,
  }))
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local okState, initial = pcall(function() return noctalia.state.get("media") end)
if okState and type(initial) == "table" then snap = initial end

pcall(function()
  noctalia.state.watch("media", function(value)
    if type(value) == "table" then
      snap = value
      render()
    end
  end)
end)

function update()
  -- second ticks keep the clock/progress moving while a track plays
  pcall(function() desktopWidget.setWantsSecondTicks(true) end)
  render()
end

function onOpen() -- not a panel, but harmless if the host ever calls it
  render()
end

render()
