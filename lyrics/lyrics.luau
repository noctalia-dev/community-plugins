--!nonstrict
-- Synchronized lyrics bar widget with karaoke highlighting and long-line scrolling.

noctalia.setUpdateInterval(33)

local glyph = noctalia.getConfig("glyph")
local showGlyph = noctalia.getConfig("show_glyph")
if showGlyph == nil then showGlyph = false end
local showArtist = noctalia.getConfig("show_artist")
local hideWhenPaused = noctalia.getConfig("hide_when_paused")
local hideWhenNoLyrics = noctalia.getConfig("hide_when_no_lyrics")
local showCover = noctalia.getConfig("show_cover")
if showCover == nil then showCover = true end
local coverShape = noctalia.getConfig("cover_shape") or "custom"
local coverRadius = tonumber(noctalia.getConfig("cover_radius")) or 5
local coverSize = tonumber(noctalia.getConfig("cover_size")) or 18
local activeColor = noctalia.getConfig("active_color") or "on_surface"
local inactiveColor = noctalia.getConfig("inactive_color") or "on_surface_variant"
local secondaryColor = noctalia.getConfig("secondary_color") or "on_surface_variant"

-- These are plugin settings, not per-widget settings.
local scrollMode = noctalia.getConfig("scroll_mode") or "auto"
local marqueeSpeed = tonumber(noctalia.getConfig("marquee_speed")) or 30
local maxLines = tonumber(noctalia.getConfig("max_lines")) or 1
local maxChars = tonumber(noctalia.getConfig("max_chars")) or 35
local charWidth = tonumber(noctalia.getConfig("char_width")) or 9
local textAlignment = noctalia.getConfig("text_alignment") or "left"
local gradientOn = noctalia.getConfig("gradient")
if gradientOn == nil then gradientOn = false end
local animation = noctalia.getConfig("animation") or "karaoke"
-- One animation setting covers both the per-character fill and the line change:
-- cascade/wave/typewriter are character fills, everything else is a line motion.
local CHARACTER_FILL_ANIMATIONS = { cascade = true, wave = true, typewriter = true }
local fillEffect = CHARACTER_FILL_ANIMATIONS[animation] and animation or (animation == "none" and "none" or "karaoke")
-- Old values kept for widgets saved by 1.6.x.
if animation == "slide" then animation = "slide_up" end
if animation == "fade" or animation == "pulse" or animation == "blink" then animation = "karaoke" end
local showCues = noctalia.getConfig("show_cues")
if showCues == nil then showCues = true end
local cueText = noctalia.getConfig("cue_text") or "•••••"
if cueText == "" then cueText = "•••••" end
local introMinMs = tonumber(noctalia.getConfig("intro_min_ms")) or 6000
local interludeMinMs = tonumber(noctalia.getConfig("interlude_min_ms")) or 5000
local interludeLeadMs = tonumber(noctalia.getConfig("interlude_lead_ms")) or 1000
local interludeGapMs = tonumber(noctalia.getConfig("interlude_gap_ms")) or 7000
local cueFontMode = noctalia.getConfig("cue_font_mode") or "custom"
local cueFontFamily = noctalia.getConfig("cue_font_family") or "sans-serif"
if cueFontFamily == "" then cueFontFamily = "sans-serif" end
local displayMode = noctalia.getConfig("display_mode") or "toggle"
local doubleLine = noctalia.getConfig("double_line")
if doubleLine == nil then doubleLine = false end
local doubleLineAutoFit = noctalia.getConfig("double_line_auto_fit")
if doubleLineAutoFit == nil then doubleLineAutoFit = false end
local doubleLineHeightBudget = tonumber(noctalia.getConfig("double_line_height_budget")) or 26
local showTranslation = noctalia.getConfig("show_translation")
if showTranslation == nil then showTranslation = false end
local showRomanization = noctalia.getConfig("show_romanization") == true
local secondaryLineMode = noctalia.getConfig("secondary_line_mode") or "translation_first"
local karaokeEnabled = noctalia.getConfig("karaoke_enabled")
if karaokeEnabled == nil then karaokeEnabled = true end
local forceKaraoke = noctalia.getConfig("force_karaoke") == true
local karaokeActiveColor = noctalia.getConfig("karaoke_active_color")
if karaokeActiveColor == nil or karaokeActiveColor == "" then karaokeActiveColor = activeColor end
local karaokeInactiveColor = noctalia.getConfig("karaoke_inactive_color")
if karaokeInactiveColor == nil or karaokeInactiveColor == "" then karaokeInactiveColor = inactiveColor end
-- Host-managed category selector: visibility only, read so the manifest lint stays clean.
local settingsPage = noctalia.getConfig("settings_page")
if settingsPage ~= nil then settingsPage = tostring(settingsPage) end
local fontFamily = noctalia.getConfig("font_family") or ""
local primaryFontSize = tonumber(noctalia.getConfig("primary_font_size")) or 0
local secondaryFontSize = tonumber(noctalia.getConfig("secondary_font_size")) or 10
local fontWeight = noctalia.getConfig("font_weight") or "normal"
local FONT_WEIGHTS = { thin = true, light = true, normal = true, medium = true, semibold = true, bold = true, heavy = true }
if not FONT_WEIGHTS[fontWeight] then fontWeight = "normal" end
local fontStyle = noctalia.getConfig("font_style") or "fixed"
local lineGap = tonumber(noctalia.getConfig("line_gap")) or 2
local paddingLeft = tonumber(noctalia.getConfig("padding_left")) or 0
local paddingRight = tonumber(noctalia.getConfig("padding_right")) or 0

local track = nil
local lyrics = nil
local cover = nil
local playing = false
local showMode = displayMode == "track" and "track" or "auto"
local rendered = false
local hovered = false
local sourceUsed = ""
local lyricsLoading = false

local baselinePosition = 0
local baselineClock = os.clock()
local lastClock = 0
local displayKey = ""
local displayedLine = nil
local outgoingLine = nil
local transitionElapsed = 0
local marqueeElapsed = 0
local lastMarqueeText = ""
local smoothProgress = 0

local FADE_OUT_MS = 130
local FADE_IN_MS = 260
local MARQUEE_HOLD = 1.1
local BLEND_MS = 350

local function clamp(value, low, high)
  return math.min(high, math.max(low, value))
end

local function easeOutCubic(t)
  local u = 1 - clamp(t, 0, 1)
  return 1 - u * u * u
end

local function easeInOutCubic(t)
  t = clamp(t, 0, 1)
  if t < 0.5 then
    return 4 * t * t * t
  end
  local u = -2 * t + 2
  return 1 - u * u * u / 2
end

-- A short overshoot that settles back to 1, used by the spring transition.
local function springEase(t)
  t = clamp(t, 0, 1)
  return 1 + 0.22 * math.sin(math.pi * t) * (1 - t)
end

-- Extra bounce for the drop transition: the line overshoots its resting row
-- once and settles.
local function bounceEase(t)
  t = clamp(t, 0, 1)
  local u = 1 - t
  return 1 - u * u * math.cos(t * math.pi * 2.2) * 0.55
end

local REST_STATE = { x = 0, y = 0, scale = 1, scaleX = 1, scaleY = 1, rotation = 0, opacity = 1 }

local function mixState(from, to, t)
  local function full(state)
    local out = { x = 0, y = 0, scale = 1, scaleX = 1, scaleY = 1, rotation = 0, opacity = 1 }
    for key, value in pairs(state or {}) do out[key] = value end
    return out
  end
  local f = full(from)
  local g = full(to)
  return {
    x = f.x + (g.x - f.x) * t,
    y = f.y + (g.y - f.y) * t,
    scale = f.scale + (g.scale - f.scale) * t,
    scaleX = f.scaleX + (g.scaleX - f.scaleX) * t,
    scaleY = f.scaleY + (g.scaleY - f.scaleY) * t,
    rotation = f.rotation + (g.rotation - f.rotation) * t,
    opacity = f.opacity + (g.opacity - f.opacity) * t,
  }
end

-- One setting, one list. Entries are deliberately distinct at bar scale:
-- directional pushes that retract the old row, a bouncy push, a drop, a zoom,
-- and horizontal swooshes. The slight-offset presets flutter_lyric ships
-- (scale/zoom variants, focus, cinematic, appleMusic) all looked like the same
-- short fade in a one-line bar, so they were merged away instead of being kept
-- as near-duplicate names.
local ANIMATION_PRESETS = {
  karaoke = { duration = 320, kind = "cross", out = { opacity = 0 }, into = { opacity = 0 } },
  slide_up = { duration = 460, kind = "push", dir = -1, ease = easeOutCubic },
  slide_down = { duration = 460, kind = "push", dir = 1, ease = easeOutCubic },
  spring = { duration = 680, kind = "push", dir = -1, ease = springEase, out = { scale = 0.94 }, into = { scale = 0.94 } },
  drop = { duration = 680, kind = "push", dir = 1, ease = bounceEase },
  slide_left = { duration = 440, kind = "cross", out = { x = -170, opacity = 0 }, into = { x = 170, opacity = 0 } },
  slide_right = { duration = 440, kind = "cross", out = { x = 170, opacity = 0 }, into = { x = -170, opacity = 0 } },
  zoom = { duration = 520, kind = "cross", out = { scale = 0.82, opacity = 0 }, into = { scale = 1.7, opacity = 0 } },
  flip = { duration = 480, kind = "cross", ease = easeInOutCubic, out = { scaleY = 0.02, opacity = 0.35 }, into = { scaleY = 0.02, opacity = 0.35 } },
  spin = { duration = 640, kind = "cross", out = { rotation = 120, scale = 0.72, opacity = 0 }, into = { rotation = -120, scale = 0.72, opacity = 0 } },
  squash = { duration = 560, kind = "cross", ease = bounceEase, out = { scaleX = 1.3, scaleY = 0.62, opacity = 0 }, into = { scaleX = 1.3, scaleY = 0.62, opacity = 0 } },
  none = { duration = 0 },
}

-- Pool for the `random` setting: only line motions, so a line change is always
-- visible and never silently picks a character fill instead.
local RANDOM_ANIMATION_POOL = {
  "karaoke", "slide_up", "slide_down", "slide_left", "slide_right",
  "spring", "drop", "zoom", "flip", "spin", "squash",
}

local function pickRandomAnimation(previous)
  if #RANDOM_ANIMATION_POOL == 1 then
    return RANDOM_ANIMATION_POOL[1]
  end
  local pick
  repeat
    pick = RANDOM_ANIMATION_POOL[math.random(1, #RANDOM_ANIMATION_POOL)]
  until pick ~= previous
  return pick
end

if noctalia.nowMs ~= nil then
  math.randomseed(noctalia.nowMs())
end

local animationPreset = ANIMATION_PRESETS[animation] or ANIMATION_PRESETS.karaoke
-- The preset may change for every line while `animation = "random"`.
local currentAnimationName = animation
local currentAnimationPreset = animationPreset
if animation == "random" then
  currentAnimationName = pickRandomAnimation("")
  currentAnimationPreset = ANIMATION_PRESETS[currentAnimationName] or ANIMATION_PRESETS.karaoke
end

local function toChars(text)
  local chars = {}
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    local length = 1
    if byte >= 0xF0 then length = 4
    elseif byte >= 0xE0 then length = 3
    elseif byte >= 0xC0 then length = 2 end
    chars[#chars + 1] = text:sub(i, i + length - 1)
    i = i + length
  end
  return chars
end

local function charUnits(char)
  if char == " " or char == "\t" then return 0.35 end
  local byte = char:byte(1) or 0
  if byte < 0x80 then
    if char:match("[%.,:;!'|ilI%-%(%)]") then return 0.38 end
    if char:match("[MW@#%%&]") then return 0.85 end
    return 0.58
  end
  return 1
end

local function textUnits(text)
  local units = 0
  for _, char in ipairs(toChars(text or "")) do units = units + charUnits(char) end
  return units
end

-- A line may only drive karaoke highlighting when its word timings are complete
-- and aligned with the displayed characters. Everything else uses line mode.
local function lineHasWordTiming(line)
  if type(line) ~= "table" then return false end
  local times = line.chars
  if type(times) ~= "table" or #times < 2 then return false end
  local chars = toChars(line.text or "")
  if #chars ~= #times then return false end
  local previous = -1
  for _, value in ipairs(times) do
    local timestamp = tonumber(value)
    if not timestamp or timestamp < 0 or timestamp < previous then return false end
    previous = timestamp
  end
  return times[#times] > times[1]
end

local function getProgressMs()
  local elapsed = playing and (os.clock() - baselineClock) * 1000 or 0
  return baselinePosition / 1000 + elapsed
end

local function hasLyrics()
  return lyrics and #lyrics > 0 and track
end

local function getLineInfo()
  if not hasLyrics() then return nil end

  local position = getProgressMs()
  local synced = lyrics[1].time >= 0
  if not synced then
    return { key = "plain", index = 1, line = lyrics[1], progress = 0, synced = false }
  end

  local firstTime = lyrics[1].time
  if showCues and firstTime >= introMinMs and position < firstTime then
    return {
      key = "intro",
      index = 0,
      line = { text = cueText, cue = true },
      progress = clamp(position / firstTime, 0, 1),
      synced = true,
      position = position,
      cue = true,
    }
  end

  local index = 1
  for i = #lyrics, 1, -1 do
    if lyrics[i].time <= position then
      index = i
      break
    end
  end

  local line = lyrics[index]
  local startTime = line.time
  local durationMs = track.duration and track.duration > 0 and track.duration / 1000 or nil
  local nextLine = lyrics[index + 1]
  local nextTime = nextLine and nextLine.time
    or durationMs
    or (startTime + 4000)
  local lineEnd = nextTime

  if line.duration and line.duration > 0 and line.duration_inferred ~= true then
    lineEnd = math.min(nextTime, startTime + line.duration)
  elseif nextTime - startTime >= interludeGapMs then
    -- LRC only marks line starts. Do not stretch a lyric across a long instrumental gap.
    local firstCharTime = line.chars and tonumber(line.chars[1]) or nil
    local lastCharTime = line.chars and tonumber(line.chars[#line.chars]) or nil
    local hasWordTiming = lineHasWordTiming(line) and lastCharTime and lastCharTime > firstCharTime
    if hasWordTiming and lastCharTime >= startTime and lastCharTime < nextTime then
      lineEnd = math.min(nextTime, lastCharTime + 600)
    else
      local estimatedDuration = clamp(#toChars(line.text) * 320, 3200, 6000)
      lineEnd = math.min(nextTime, startTime + estimatedDuration)
    end
  end

  -- Only show an interlude between two real lyric lines. The final lyric stays
  -- visible through the outro instead of turning the whole song ending into dots.
  local interludeStart = math.max(startTime, lineEnd - interludeLeadMs)
  if showCues and nextLine and nextTime - lineEnd >= interludeMinMs and position >= interludeStart then
    return {
      key = "interlude-" .. tostring(index),
      index = index,
      line = { text = cueText, cue = true },
      progress = clamp((position - interludeStart) / (nextTime - interludeStart), 0, 1),
      synced = true,
      position = position,
      cue = true,
    }
  end

  local progress = lineEnd > startTime and clamp((position - startTime) / (lineEnd - startTime), 0, 1) or 1

  return {
    key = "line-" .. tostring(index),
    index = index,
    line = line,
    progress = progress,
    synced = true,
    position = position,
  }
end

local function getTrackLabel()
  if not track then return "--" end
  if not showArtist then return track.title end
  if track.artist and track.artist ~= "" then
    return track.artist .. " - " .. track.title
  end
  return track.title
end

local function getFallbackLabel()
  if not track then return "--" end
  if displayMode ~= "track" and showMode ~= "track" then
    return noctalia.tr("no_lyrics")
  end
  if track.artist and track.artist ~= "" then
    return track.title .. " + " .. track.artist
  end
  return track.title
end

-- The declarative label inherits the host body font size when the plugin does
-- not set one; Noctalia's body size is 14 logical px. Marquee math uses real
-- font metrics (CJK advance is one full font size) instead of the old fixed
-- char-width guess so a line scrolls exactly to its last character.
local INHERITED_FONT_SIZE = 14

local function resolveFontSize(secondary, fontScale)
  local base
  if secondary then
    base = secondaryFontSize
  else
    base = primaryFontSize > 0 and primaryFontSize or INHERITED_FONT_SIZE
  end
  return base * (fontScale or 1)
end

-- Latin advances in the tuned serif face run slightly wider than the coarse
-- per-class table; calibrate against a rendered line so marquee end-stops land
-- on the last glyph instead of a few pixels short.
local ASCII_WIDTH_SCALE = 1.06

local function charPixelWidth(char, fontSize)
  local units = charUnits(char)
  local byte = char:byte(1) or 0
  if byte < 0x80 then
    units = units * ASCII_WIDTH_SCALE
  end
  return units * fontSize
end

local function textPixelWidth(text, fontSize)
  local width = 0
  for _, char in ipairs(toChars(text or "")) do
    width = width + charPixelWidth(char, fontSize)
  end
  return width
end

local function marqueeViewportWidth()
  return maxChars * charWidth
end

local function shouldMarquee(text, fontSize)
  return scrollMode ~= "static" and textPixelWidth(text, fontSize) > marqueeViewportWidth()
end

local function getMarqueeOffset(chars, fontSize)
  local totalWidth = 0
  for _, char in ipairs(chars) do
    totalWidth = totalWidth + charPixelWidth(char, fontSize)
  end
  local maxOffset = math.max(0, totalWidth - marqueeViewportWidth())
  if maxOffset <= 0 then
    return 0
  end
  -- A small safety margin makes the final glyph land inside the viewport even
  -- when the font advances differ a little from the width model.
  maxOffset = maxOffset + fontSize * 0.55

  local pixelsPerSecond = math.max(1, marqueeSpeed)
  local travelTime = maxOffset / pixelsPerSecond
  local cycle = MARQUEE_HOLD + travelTime + MARQUEE_HOLD
  local phase = marqueeElapsed % cycle

  if phase < MARQUEE_HOLD then
    return 0
  end
  phase = phase - MARQUEE_HOLD
  if phase < travelTime then
    return maxOffset * (phase / travelTime)
  end
  return maxOffset
end

local function karaokeColor(charTime, charProgress, position, useGradient, sungColor, unsungColor)
  local active = sungColor or activeColor
  local inactive = unsungColor or inactiveColor
  if not playing then return inactive end
  if charTime and position then
    if not useGradient then
      return position >= charTime and active or inactive
    end
    if position >= charTime then return active end
    local distance = charTime - position
    if distance >= BLEND_MS then return inactive end
    local alpha = 1 - distance / BLEND_MS
    if alpha <= 0.5 then return inactive end
    return active .. "/" .. string.format("%.2f", math.max(0.72, alpha))
  end

  if not useGradient then
    return smoothProgress >= charProgress and active or inactive
  end
  local distance = charProgress - smoothProgress
  if distance <= 0 then return active end
  if distance >= 0.16 then return inactive end
  local alpha = 1 - distance / 0.16
  if alpha <= 0.5 then return inactive end
  return active .. "/" .. string.format("%.2f", math.max(0.72, alpha))
end

local function labelBaseline()
  if fontStyle == "fixed" then return "textFixedHeight" end
  if fontStyle == "ink_centered" then return "inkCentered" end
  return "text"
end

local function secondaryText(line)
  if not doubleLine or type(line) ~= "table" then return "" end
  local translation = showTranslation and (line.translation or "") or ""
  local romanization = showRomanization and (line.romanization or "") or ""
  if secondaryLineMode == "translation" then return translation end
  if secondaryLineMode == "romanization" then return romanization end
  if secondaryLineMode == "romanization_first" then
    return romanization ~= "" and romanization or translation
  end
  return translation ~= "" and translation or romanization
end

local function secondaryRowEnabled(text)
  return doubleLine and (showTranslation or showRomanization)
    and type(text) == "string" and text:match("%S") ~= nil
end

local function compactMetrics(hasSecondary, vertical)
  if not hasSecondary or vertical or not doubleLineAutoFit then return 1, lineGap end
  local primaryBase = primaryFontSize > 0 and primaryFontSize or 13
  local secondaryBase = secondaryFontSize > 0 and secondaryFontSize or 10
  local naturalHeight = primaryBase * 1.25 + secondaryBase * 1.25 + lineGap
  local scale = math.min(1, doubleLineHeightBudget / math.max(1, naturalHeight))
  return scale, math.floor(lineGap * scale + 0.5)
end

local function buildLineRow(line, opts)
  opts = opts or {}
  local text = type(line) == "table" and line.text or line
  local times = type(line) == "table" and line.chars or nil
  local isCue = opts.cue or (type(line) == "table" and line.cue == true)
  local wordSync = lineHasWordTiming(line)
  local perCharFill = wordSync or isCue or forceKaraoke
  local useKaraokeColors = wordSync and not isCue and not opts.solid and not opts.dim
  local chars = toChars(text or "")
  if #chars == 0 then chars = { " " } end

  local rowFontSize = resolveFontSize(opts.secondary, opts.fontScale)
  local fullLineWidth = 0
  for _, char in ipairs(chars) do
    fullLineWidth = fullLineWidth + charPixelWidth(char, rowFontSize)
  end
  local marqueeOffset = 0
  if opts.marquee then
    marqueeOffset = getMarqueeOffset(chars, rowFontSize)
  end
  local labels = {}

  for sourceIndex = 1, #chars do
    local active = playing and activeColor or inactiveColor
    local color = opts.secondary and secondaryColor or (opts.dim and inactiveColor or active)
    if not opts.solid and not opts.dim then
      if perCharFill then
        local progress = #chars > 1 and (sourceIndex - 1) / (#chars - 1) or 0
        color = karaokeColor(
          times and times[sourceIndex], progress, opts.position, opts.useGradient,
          useKaraokeColors and karaokeActiveColor or nil,
          useKaraokeColors and karaokeInactiveColor or nil
        )
      else
        -- Line mode: with no usable word timings the whole line is highlighted
        -- at once and only advances when the next line starts.
        color = active
      end
    end

    local alpha = 1
    if opts.cascade then
      local charProgress = (sourceIndex - 1) / math.max(1, #chars - 1)
      local cascadeProgress = clamp((transitionElapsed - FADE_OUT_MS) / 420, 0, 1)
      alpha = alpha * clamp((cascadeProgress - charProgress * 0.45) * 2.4, 0.08, 1)
    end
    if opts.wave then
      local waveProgress = clamp((transitionElapsed - FADE_OUT_MS) / 650, 0, 1)
      local wave = 0.55 + 0.45 * math.sin(waveProgress * math.pi * 2 - sourceIndex * 0.78)
      alpha = alpha * (wave * (1 - waveProgress) + waveProgress)
    end
    if opts.typewriter then
      local reveal = clamp((transitionElapsed - FADE_OUT_MS) / 520, 0, 1)
      local threshold = (sourceIndex - 1) / math.max(1, #chars)
      alpha = alpha * (reveal >= threshold and 1 or 0.08)
    end
    if opts.blink and transitionElapsed < FADE_OUT_MS + 540 then
      local blink = math.floor(math.max(0, transitionElapsed - FADE_OUT_MS) / 90) % 2
      alpha = alpha * (blink == 0 and 0.35 or 1)
    end

    labels[#labels + 1] = ui.label({
      key = "char-" .. tostring(sourceIndex),
      text = chars[sourceIndex],
      color = color,
      opacity = alpha,
      maxLines = 1,
      fontFamily = isCue and cueFontMode == "custom" and cueFontFamily or (fontFamily ~= "" and fontFamily or nil),
      fontSize = math.max(6, rowFontSize),
      fontWeight = opts.secondary and "normal" or fontWeight,
      baseline = labelBaseline(),
    })
  end

  local rowHeight = opts.height
  if rowHeight == nil then
    rowHeight = math.max(14, math.floor(rowFontSize * 1.25 + 0.5))
  end

  local lineRow = ui.row({
    key = opts.marquee and ((opts.key or "line") .. "-text") or (opts.key or "line"),
    gap = 0,
    align = "center",
    justify = opts.marquee and "start"
      or (textAlignment == "right" and "end" or textAlignment == "center" and "center" or "start"),
    minWidth = opts.marquee and math.ceil(fullLineWidth) or marqueeViewportWidth(),
    opacity = opts.marquee and 1 or (opts.opacity or 1),
    height = rowHeight,
    width = opts.width,
    translateX = opts.marquee and (-marqueeOffset) or opts.tx,
    translateY = opts.ty,
    scale = opts.scale,
    scaleX = opts.scaleX,
    scaleY = opts.scaleY,
    rotation = opts.rotation,
  }, labels)

  if not opts.marquee then
    return lineRow
  end

  -- Smooth pixel-level marquee: a fixed-width clipped viewport scrolls the
  -- whole row with a paint-only translateX instead of rebuilding a window of
  -- whole characters. max_chars sets the viewport width, char_width converts
  -- the unit offset into pixels, and marquee_speed stays in pixels/second.
  return ui.row({
    key = ((opts.key or "line") .. "-viewport"),
    width = math.ceil(marqueeViewportWidth()),
    height = rowHeight,
    clip = true,
    justify = "start",
    align = "center",
    opacity = opts.opacity or 1,
  }, { lineRow })
end


-- A lyric "line" is one primary row plus the optional translation/romanization
-- row. Animating them as a single block keeps the two rows together and gives
-- every row an explicit height, so a transition starts and ends on the same
-- baseline instead of nudging the line up and back down.
local function lineBlockHeights(fontScale, hasSecondary)
  local primaryBase = primaryFontSize > 0 and primaryFontSize or INHERITED_FONT_SIZE
  local primaryH = math.max(15, math.floor(primaryBase * (fontScale or 1) * 1.25 + 0.5))
  local secondaryH = 0
  if hasSecondary then
    secondaryH = math.max(10, math.floor(secondaryFontSize * (fontScale or 1) * 1.25 + 0.5))
  end
  return primaryH, secondaryH
end

local function buildLineBlock(line, spec, opts)
  opts = opts or {}
  local blockKey = opts.key or "line"
  local secondary = opts.secondaryText or ""
  local showSecondary = spec.showSecondary and not (type(line) == "table" and line.cue == true)
  local secondaryVisible = showSecondary and secondary:match("%S") ~= nil
  local rows = {
    buildLineRow(line, {
      key = blockKey,
      height = spec.primaryH,
      marquee = opts.marquee,
      position = opts.position,
      useGradient = opts.useGradient,
      solid = opts.solid,
      cascade = opts.cascade,
      wave = opts.wave,
      typewriter = opts.typewriter,
      blink = opts.blink,
      opacity = opts.rowOpacity or 1,
      cue = opts.cue,
      fontScale = spec.fontScale,
      compact = spec.compact,
    }),
  }
  if showSecondary then
    rows[#rows + 1] = buildLineRow({ text = secondaryVisible and secondary or " " }, {
      key = blockKey .. "-secondary",
      height = spec.secondaryH,
      marquee = secondaryVisible and opts.secondaryMarquee == true,
      solid = true,
      dim = true,
      secondary = true,
      opacity = secondaryVisible and opts.secondaryOpacity or (secondaryVisible and 0.82 or 0),
      fontScale = spec.fontScale,
      compact = spec.compact,
    })
  end
  local state = opts.state or REST_STATE
  return ui.column({
    key = blockKey .. "-block",
    height = spec.blockH,
    gap = showSecondary and spec.gap or 0,
    align = "start",
    justify = "center",
    opacity = state.opacity,
    translateX = state.x,
    translateY = state.y,
    scale = state.scale,
    scaleX = state.scaleX,
    scaleY = state.scaleY,
    rotation = state.rotation,
  }, rows)
end

local function render()
  local showingTrack = displayMode == "track" or showMode == "track"
  if hideWhenPaused and not playing
    or hideWhenNoLyrics and not showingTrack and not hasLyrics() and not lyricsLoading then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local vertical = barWidget.isVertical()
  local useGradient = (fillEffect == "karaoke" or fillEffect == "cascade" or fillEffect == "wave") and gradientOn
  local position = getProgressMs()
  local prefix = {}
  local coverPath = showCover and cover and cover ~= "" and noctalia.fileExists(cover) and cover or nil
  if coverPath then
    local radius = coverShape == "circle" and coverSize / 2
      or coverShape == "rounded" and math.min(5, coverSize / 2)
      or coverShape == "square" and 0
      or math.min(coverRadius, coverSize / 2)
    prefix[#prefix + 1] = ui.image({ path = coverPath, width = coverSize, height = coverSize, radius = radius, fit = "cover" })
  elseif showGlyph then
    prefix[#prefix + 1] = ui.glyph({
      name = glyph,
      size = 14,
      color = playing and activeColor or inactiveColor,
    })
  end
  local lineNodes = {}
  local renderLineGap = lineGap
  local renderTextHeight = 0
  if displayMode == "track" or showMode == "track" then
    local label = getTrackLabel()
    lineNodes[1] = buildLineRow(label, {
      key = "track",
      marquee = shouldMarquee(label, resolveFontSize(false, 1)),
      solid = true,
    })
  else
    local info = getLineInfo()
    if info then
      local transition = animation == "random" and currentAnimationPreset or animationPreset
      local outgoingValid = type(outgoingLine) == "table" and outgoingLine ~= info.line
      local transitionActive = transition ~= nil and transition.kind ~= nil and transition.duration > 0
        and outgoingValid and transitionElapsed < transition.duration
      local shownLine = info.line

      local secondary = secondaryText(info.line)
      local showSecondaryRow = secondaryRowEnabled(secondary) and not info.line.cue and not info.cue
      local fontScale, effectiveLineGap = compactMetrics(showSecondaryRow, vertical)
      local primaryH, secondaryH = lineBlockHeights(fontScale, showSecondaryRow)
      local blockH = primaryH + (showSecondaryRow and (secondaryH + effectiveLineGap) or 0)
      local blockSpec = {
        primaryH = primaryH,
        secondaryH = secondaryH,
        blockH = blockH,
        showSecondary = showSecondaryRow,
        gap = effectiveLineGap,
        fontScale = fontScale,
        compact = showSecondaryRow and not vertical and doubleLineAutoFit,
      }

      local function blockOptions(line, state, key)
        local wordSync = lineHasWordTiming(line)
        local cueLine = type(line) == "table" and line.cue == true
        local perChar = wordSync or cueLine or forceKaraoke
        local lineText = type(line) == "table" and line.text or line
        local secondary = secondaryText(line)
        -- Keep the marquee viewport during transitions too: rendering the raw
        -- row would flash the full line at full width for the transition length
        -- before it snaps back into the clipped, scrolling viewport.
        return {
          key = key,
          secondaryText = secondary,
          state = state or REST_STATE,
          marquee = shouldMarquee(lineText or "", resolveFontSize(false, blockSpec.fontScale)),
          secondaryMarquee = secondary ~= "" and shouldMarquee(secondary, resolveFontSize(true, blockSpec.fontScale))
            and not vertical,
          position = position,
          useGradient = karaokeEnabled and useGradient and perChar,
          solid = not karaokeEnabled or not perChar,
          cue = cueLine,
        }
      end

      if transitionActive and transition.kind == "push" and not vertical then
        -- Push transitions move the whole line block, so a translation row
        -- travels with its primary row instead of being left behind.
        local p = clamp(transitionElapsed / transition.duration, 0, 1)
        local eased = (transition.ease or easeOutCubic)(p)
        local outState = transition.outFn and transition.outFn(p) or mixState(REST_STATE, transition.out, eased)
        local inState = transition.inFn and transition.inFn(p) or mixState(transition.into, REST_STATE, eased)
        local outBlock = buildLineBlock(outgoingLine, blockSpec, blockOptions(outgoingLine, outState, "tr-out"))
        local inBlock = buildLineBlock(info.line, blockSpec, blockOptions(info.line, inState, "tr-in-" .. tostring(info.index)))
        local dir = transition.dir or -1
        local offset = dir < 0 and -eased * blockH or -(1 - eased) * blockH
        local blocks = dir < 0 and { outBlock, inBlock } or { inBlock, outBlock }
        lineNodes[#lineNodes + 1] = ui.column({
          key = "tr-viewport",
          width = math.ceil(marqueeViewportWidth()),
          height = blockH,
          clip = true,
          justify = "start",
          align = "start",
        }, {
          ui.column({
            key = "tr-track",
            width = math.ceil(marqueeViewportWidth()),
            height = blockH * 2,
            justify = "start",
            align = "start",
            translateY = offset,
          }, blocks),
        })
      elseif transitionActive then
        -- Cross transitions swap the single block at the halfway point, so both
        -- the primary and the secondary row animate together.
        local p = clamp(transitionElapsed / transition.duration, 0, 1)
        local ease = transition.ease or easeOutCubic
        local outgoingPhase = p < 0.5
        local q = outgoingPhase and p * 2 or (p - 0.5) * 2
        local line = outgoingPhase and outgoingLine or info.line
        local state
        if outgoingPhase then
          state = transition.outFn and transition.outFn(p) or mixState(REST_STATE, transition.out, ease(q))
        else
          state = transition.inFn and transition.inFn(p) or mixState(transition.into, REST_STATE, ease(q))
        end
        lineNodes[#lineNodes + 1] = buildLineBlock(line, blockSpec, blockOptions(
          line, state, outgoingPhase and "tr-out" or "tr-in-" .. tostring(info.index)
        ))
        shownLine = line
      else
        local perCharFill = lineHasWordTiming(info.line) or info.cue == true or forceKaraoke
        lineNodes[#lineNodes + 1] = buildLineBlock(info.line, blockSpec, {
          key = "current-" .. tostring(info.index),
          secondaryText = secondary,
          secondaryMarquee = secondary ~= "" and shouldMarquee(secondary, resolveFontSize(true, fontScale)) and not vertical,
          marquee = shouldMarquee(info.line.text, resolveFontSize(false, fontScale)),
          position = position,
          useGradient = karaokeEnabled and info.synced and useGradient and perCharFill,
          solid = not karaokeEnabled or not info.synced
            or (fillEffect ~= "karaoke" and fillEffect ~= "cascade" and fillEffect ~= "wave")
            or not perCharFill,
          cascade = animation == "cascade",
          wave = animation == "wave",
          typewriter = animation == "typewriter",
          blink = animation == "blink",
          cue = info.cue == true,
        })
        if showSecondaryRow then
          renderLineGap = effectiveLineGap
          if not vertical and doubleLineAutoFit then renderTextHeight = doubleLineHeightBudget end
        end
      end

      if vertical and maxLines > 1 and shownLine == info.line then
        for i = 1, maxLines - 1 do
          local nextLine = lyrics[info.index + i]
          if not nextLine then break end
          lineNodes[#lineNodes + 1] = buildLineRow(nextLine, {
            key = "next-" .. tostring(info.index + i),
            dim = true,
            opacity = math.max(0.25, 0.58 - (i - 1) * 0.16),
          })
        end
      end
    else
      local label = getFallbackLabel()
      lineNodes[1] = buildLineRow(label, {
        key = "fallback",
        marquee = shouldMarquee(label, resolveFontSize(false, 1)),
        solid = true,
      })
    end
  end

  if vertical then
    barWidget.render(ui.column({ gap = 3, align = "start", opacity = playing and 1 or 0.58 }, {
      ui.row({ gap = 6, align = "center" }, prefix),
      ui.column({
        gap = renderLineGap,
        align = "start",
        justify = renderTextHeight > 0 and "center" or nil,
        height = renderTextHeight > 0 and renderTextHeight or nil,
      }, lineNodes),
    }))
  else
    local children = {}
    if paddingLeft > 0 then children[#children + 1] = ui.spacer({ width = paddingLeft }) end
    for _, node in ipairs(prefix) do children[#children + 1] = node end
    children[#children + 1] = ui.column({
      gap = renderLineGap,
      align = "start",
      justify = renderTextHeight > 0 and "center" or nil,
      height = renderTextHeight > 0 and renderTextHeight or nil,
    }, lineNodes)
    if paddingRight > 0 then children[#children + 1] = ui.spacer({ width = paddingRight }) end
    barWidget.render(ui.row({ gap = 6, align = "center", opacity = playing and 1 or 0.58 }, children))
  end

  local sourceNames = {
    lrclib = "LRCLIB", netease = "NetEase", splayer = "SPlayer", splayer_next = "SPlayer Next",
    qqmusic = "QQ Music", kugou = "Kugou",
    qishui = "Qishui", apple_music = "Apple Music", spotify = "Spotify",
    musixmatch = "Musixmatch", mpris = "MPRIS", custom = "Custom", cache = "Cache",
  }
  local sourceLabel = noctalia.tr("source_label")
  local tooltip = getTrackLabel()
  if sourceUsed ~= "" then tooltip = tooltip .. "\n" .. sourceLabel .. ": " .. (sourceNames[sourceUsed] or sourceUsed) end
  barWidget.setTooltip(tooltip)
  rendered = true
end

local function toggleView()
  if displayMode ~= "toggle" then return end
  showMode = showMode == "auto" and "track" or "auto"
  marqueeElapsed = 0
  if rendered then render() end
end

function onClick()
  toggleView()
end

function onHover(entered)
  hovered = entered == true
end

function onIpc(event, _payload)
  if event == "toggle-view" and hovered then toggleView() end
end

function update()
  local now = os.clock()
  local delta = lastClock > 0 and now - lastClock or 0
  lastClock = now

  track = noctalia.state.get("track")
  lyrics = noctalia.state.get("lyrics")
  cover = noctalia.state.get("cover")
  playing = noctalia.state.get("playing") == true
  sourceUsed = noctalia.state.get("lyrics_source_used") or ""
  lyricsLoading = noctalia.state.get("lyrics_loading") == true

  local info = getLineInfo()
  local nextKey = info and info.key or "fallback"
  if nextKey ~= displayKey then
    outgoingLine = displayedLine
    displayKey = nextKey
    transitionElapsed = animation == "none" and FADE_OUT_MS + FADE_IN_MS or 0
    smoothProgress = info and info.progress or 0
    if animation == "random" then
      currentAnimationName = pickRandomAnimation(currentAnimationName)
      currentAnimationPreset = ANIMATION_PRESETS[currentAnimationName] or ANIMATION_PRESETS.karaoke
    end
  else
    local target = info and info.progress or 0
    smoothProgress = smoothProgress + (target - smoothProgress) * math.min(1, delta * 8)
  end
  displayedLine = info and info.line or nil

  if playing then
    transitionElapsed = transitionElapsed + delta * 1000
    local text, secondary, marqueeFontScale
    if showMode == "track" then
      text = getTrackLabel()
      secondary = ""
      marqueeFontScale = 1
    else
      text = info and info.line.text or ""
      secondary = info and secondaryText(info.line) or ""
      local showSecondary = info ~= nil and secondaryRowEnabled(secondary)
        and not info.line.cue and not info.cue
      marqueeFontScale = compactMetrics(showSecondary, vertical)
    end
    local marqueeText = text .. "\u{1}" .. secondary .. "\u{1}" .. tostring(showMode)
    if marqueeText ~= lastMarqueeText then
      lastMarqueeText = marqueeText
      marqueeElapsed = 0
    end
    if shouldMarquee(text, resolveFontSize(false, marqueeFontScale))
      or (secondary ~= "" and shouldMarquee(secondary, resolveFontSize(true, marqueeFontScale))) then
      marqueeElapsed = marqueeElapsed + delta
    end
  end

  render()
end

noctalia.state.watch("position", function(value)
  baselinePosition = tonumber(value) or 0
  baselineClock = os.clock()
end)

noctalia.state.watch("lyrics", function(value)
  lyrics = value
  displayKey = ""
  displayedLine = nil
  outgoingLine = nil
  marqueeElapsed = 0
end)

noctalia.state.watch("playing", function(value)
  -- Preserve the interpolated position when pausing between service polls.
  if playing and value ~= true then
    baselinePosition = getProgressMs() * 1000
  end
  playing = value == true
  baselineClock = os.clock()
end)
