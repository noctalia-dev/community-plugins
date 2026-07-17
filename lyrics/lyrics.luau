--!nonstrict
-- Synchronized lyrics bar widget with karaoke highlighting and long-line scrolling.

noctalia.setUpdateInterval(33)

local glyph = noctalia.getConfig("glyph")
local showArtist = noctalia.getConfig("show_artist")
local hideWhenPaused = noctalia.getConfig("hide_when_paused")
local showCover = noctalia.getConfig("show_cover")
if showCover == nil then showCover = true end
local activeColor = noctalia.getConfig("active_color") or "primary"
local inactiveColor = noctalia.getConfig("inactive_color") or "on_surface_variant"

-- These are plugin settings, not per-widget settings.
local scrollMode = noctalia.getConfig("scroll_mode") or "auto"
local marqueeSpeed = tonumber(noctalia.getConfig("marquee_speed")) or 30
local maxLines = tonumber(noctalia.getConfig("max_lines")) or 1
local maxChars = tonumber(noctalia.getConfig("max_chars")) or 24
local charWidth = tonumber(noctalia.getConfig("char_width")) or 9
local gradientOn = noctalia.getConfig("gradient")
if gradientOn == nil then gradientOn = true end
local animation = noctalia.getConfig("animation") or "karaoke"
local cueText = noctalia.getConfig("cue_text") or "•••••"
if cueText == "" then cueText = "•••••" end

local track = nil
local lyrics = nil
local cover = nil
local playing = false
local showMode = "auto"
local rendered = false

local baselinePosition = 0
local baselineClock = os.clock()
local lastClock = 0
local displayKey = ""
local displayedLine = nil
local outgoingLine = nil
local transitionElapsed = 0
local marqueeElapsed = 0
local smoothProgress = 0

local FADE_OUT_MS = 130
local FADE_IN_MS = 260
local MARQUEE_HOLD = 1.1
local BLEND_MS = 350
local INTERLUDE_GAP_MS = 7000
local INTRO_MIN_MS = 6000
local INTERLUDE_MIN_MS = 8000

local function clamp(value, low, high)
  return math.min(high, math.max(low, value))
end

local function easeOutCubic(t)
  local u = 1 - clamp(t, 0, 1)
  return 1 - u * u * u
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

local function getProgressMs()
  local elapsed = playing and (os.clock() - baselineClock) * 1000 or 0
  return baselinePosition / 1000 + elapsed
end

local function getLineInfo()
  if not lyrics or #lyrics == 0 or not track then return nil end

  local position = getProgressMs()
  local synced = lyrics[1].time >= 0
  if not synced then
    return { key = "plain", index = 1, line = lyrics[1], progress = 0, synced = false }
  end

  local firstTime = lyrics[1].time
  if firstTime >= INTRO_MIN_MS and position < firstTime then
    return {
      key = "intro",
      index = 0,
      line = { text = cueText },
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

  if line.duration and line.duration > 0 then
    lineEnd = math.min(nextTime, startTime + line.duration)
  elseif nextTime - startTime >= INTERLUDE_GAP_MS then
    -- LRC only marks line starts. Do not stretch a lyric across a long instrumental gap.
    local estimatedDuration = clamp(#toChars(line.text) * 320, 3200, 6000)
    lineEnd = math.min(nextTime, startTime + estimatedDuration)
  end

  -- Only show an interlude between two real lyric lines. The final lyric stays
  -- visible through the outro instead of turning the whole song ending into dots.
  if nextLine and nextTime - lineEnd >= INTERLUDE_MIN_MS and position >= lineEnd then
    return {
      key = "interlude-" .. tostring(index),
      index = index,
      line = { text = cueText },
      progress = clamp((position - lineEnd) / (nextTime - lineEnd), 0, 1),
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
  if track.artist and track.artist ~= "" then
    return track.title .. " + " .. track.artist
  end
  return track.title
end

local function shouldMarquee(text)
  return scrollMode ~= "static" and #toChars(text) > maxChars
end

local function getMarqueeOffset(length)
  local distance = math.max(0, length - maxChars)
  if distance == 0 then return 0 end

  -- The setting is pixels per second; convert it to character cells per second.
  local charsPerSecond = math.max(0.5, marqueeSpeed / math.max(1, charWidth))
  local travelTime = distance / charsPerSecond
  local cycle = MARQUEE_HOLD * 2 + travelTime * 2
  local phase = marqueeElapsed % cycle

  if phase < MARQUEE_HOLD then return 0 end
  phase = phase - MARQUEE_HOLD
  if phase < travelTime then return distance * (phase / travelTime) end
  phase = phase - travelTime
  if phase < MARQUEE_HOLD then return distance end
  phase = phase - MARQUEE_HOLD
  return distance * (1 - phase / travelTime)
end

local function karaokeColor(charTime, charProgress, position, useGradient)
  if not playing then return inactiveColor end
  local active = activeColor
  local inactive = inactiveColor
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

local function buildLineRow(line, opts)
  opts = opts or {}
  local text = type(line) == "table" and line.text or line
  local times = type(line) == "table" and line.chars or nil
  local chars = toChars(text or "")
  if #chars == 0 then chars = { " " } end

  local exactOffset = opts.marquee and getMarqueeOffset(#chars) or 0
  local offset = math.floor(exactOffset)
  local fraction = exactOffset - offset
  local first = offset + 1
  local last = math.min(#chars, first + maxChars)
  local labels = {}

  for sourceIndex = first, last do
    local active = playing and activeColor or inactiveColor
    local color = opts.dim and inactiveColor or active
    if not opts.solid and not opts.dim then
      local progress = #chars > 1 and (sourceIndex - 1) / (#chars - 1) or 0
      color = karaokeColor(times and times[sourceIndex], progress, opts.position, opts.useGradient)
    end

    -- Soft viewport edges make cell-by-cell marquee movement less abrupt.
    local alpha = 1
    local edgeAlpha = noctalia.isDarkMode() and 0.5 or 0.72
    if opts.marquee and offset > 0 and sourceIndex == first then alpha = edgeAlpha end
    if opts.marquee and last < #chars and sourceIndex == last then alpha = edgeAlpha end
    if opts.cascade then
      local charProgress = (sourceIndex - first) / math.max(1, last - first)
      local cascadeProgress = clamp((transitionElapsed - FADE_OUT_MS) / 420, 0, 1)
      alpha = alpha * clamp((cascadeProgress - charProgress * 0.45) * 2.4, 0.08, 1)
    end
    if opts.wave then
      local waveProgress = clamp((transitionElapsed - FADE_OUT_MS) / 650, 0, 1)
      local wave = 0.55 + 0.45 * math.sin(waveProgress * math.pi * 2 - sourceIndex * 0.78)
      alpha = alpha * (wave * (1 - waveProgress) + waveProgress)
    end

    -- Bar labels elide glyphs when constrained below their natural width, so
    -- animate the viewport edges with opacity without clipping CJK characters.
    if opts.marquee and fraction > 0 then
      if sourceIndex == first then
        alpha = alpha * (1 - fraction)
      elseif sourceIndex == first + maxChars then
        alpha = alpha * fraction
      end
    elseif sourceIndex == first + maxChars then
      alpha = 0
    end

    labels[#labels + 1] = ui.label({
      key = "char-" .. tostring(sourceIndex),
      text = chars[sourceIndex],
      color = color,
      opacity = alpha,
      maxLines = 1,
    })
  end

  if opts.marquee then
    while #labels < maxChars + 1 do
      labels[#labels + 1] = ui.label({ text = " ", opacity = 0, maxLines = 1 })
    end
  end

  return ui.row({
    key = opts.key or "line",
    gap = 0,
    align = "center",
    minWidth = maxChars * charWidth,
    opacity = opts.opacity or 1,
  }, labels)
end

local function currentTransitionLine(info)
  if animation == "none" or transitionElapsed >= FADE_OUT_MS then
    local opacity = animation == "none" and 1
      or easeOutCubic((transitionElapsed - FADE_OUT_MS) / FADE_IN_MS)
    return info and info.line or nil, opacity
  end
  return outgoingLine, 1 - easeOutCubic(transitionElapsed / FADE_OUT_MS)
end

local function render()
  if hideWhenPaused and not playing then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local vertical = barWidget.isVertical()
  local useGradient = (animation == "karaoke" or animation == "cascade" or animation == "wave") and gradientOn
  local position = getProgressMs()
  local prefix = {}
  local coverPath = showCover and cover and cover ~= "" and noctalia.fileExists(cover) and cover or nil
  if coverPath then
    prefix[#prefix + 1] = ui.image({ path = coverPath, width = 18, height = 18, radius = 9, fit = "cover" })
  else
    prefix[#prefix + 1] = ui.glyph({
      name = glyph,
      size = 14,
      color = playing and activeColor or inactiveColor,
    })
  end

  local lineNodes = {}
  if showMode == "track" then
    local label = getTrackLabel()
    lineNodes[1] = buildLineRow(label, {
      key = "track",
      marquee = shouldMarquee(label),
      solid = true,
    })
  else
    local info = getLineInfo()
    if info then
      local shownLine, opacity = currentTransitionLine(info)
      if shownLine then
        lineNodes[#lineNodes + 1] = buildLineRow(shownLine, {
          key = "current-" .. tostring(info.index),
          marquee = shownLine == info.line and shouldMarquee(shownLine.text),
          position = position,
          useGradient = shownLine == info.line and info.synced and useGradient,
          solid = not info.synced or (animation ~= "karaoke" and animation ~= "cascade" and animation ~= "wave"),
          cascade = shownLine == info.line and animation == "cascade",
          wave = shownLine == info.line and animation == "wave",
          opacity = opacity,
        })
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
        marquee = shouldMarquee(label),
        solid = true,
      })
    end
  end

  if vertical then
    barWidget.render(ui.column({ gap = 3, align = "start", opacity = playing and 1 or 0.58 }, {
      ui.row({ gap = 6, align = "center" }, prefix),
      ui.column({ gap = 2, align = "start" }, lineNodes),
    }))
  else
    local children = {}
    for _, node in ipairs(prefix) do children[#children + 1] = node end
    children[#children + 1] = lineNodes[1]
    barWidget.render(ui.row({ gap = 6, align = "center", opacity = playing and 1 or 0.58 }, children))
  end

  barWidget.setTooltip(getTrackLabel())
  rendered = true
end

function onClick()
  showMode = showMode == "auto" and "track" or "auto"
  marqueeElapsed = 0
  if rendered then render() end
end

function onRightClick()
  noctalia.runAsync("playerctl play-pause", function(result)
    if result.exitCode == 0 then
      local wasPlaying = playing
      if wasPlaying then baselinePosition = getProgressMs() * 1000 end
      playing = not wasPlaying
      noctalia.state.set("playing", playing)
      baselineClock = os.clock()
      render()
    end
  end)
end

function update()
  local now = os.clock()
  local delta = lastClock > 0 and now - lastClock or 0
  lastClock = now

  track = noctalia.state.get("track")
  lyrics = noctalia.state.get("lyrics")
  cover = noctalia.state.get("cover")
  playing = noctalia.state.get("playing") == true

  local info = getLineInfo()
  local nextKey = info and info.key or "fallback"
  if nextKey ~= displayKey then
    outgoingLine = displayedLine
    displayKey = nextKey
    transitionElapsed = animation == "none" and FADE_OUT_MS + FADE_IN_MS or 0
    marqueeElapsed = 0
    smoothProgress = info and info.progress or 0
  else
    local target = info and info.progress or 0
    smoothProgress = smoothProgress + (target - smoothProgress) * math.min(1, delta * 8)
  end
  displayedLine = info and info.line or nil

  if playing then
    transitionElapsed = transitionElapsed + delta * 1000
    local text = showMode == "track" and getTrackLabel() or (info and info.line.text or "")
    if shouldMarquee(text) then marqueeElapsed = marqueeElapsed + delta end
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
