-- Regression tests for the render modules, runnable with Lua 5.4.
--
-- The modules are pure Lua: render.luau receives the `ui` table, so here it is
-- a double that records the tree; lyrics.luau takes and returns plain tables.
--
-- Usage: lua5.4 bin/test-render.lua lib/render.luau [lib/lyrics.luau]

local renderPath = arg[1] or "lib/render.luau"
local lyricsPath = arg[2]

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

local render = dofile(renderPath)
local lyrics = nil
if lyricsPath ~= nil then
  lyrics = dofile(lyricsPath)
end

-- ui double ---------------------------------------------------------------
--
-- Every constructor returns a node: { kind, props, children }. The tests walk
-- the tree by kind. `ui.label` keeps its text in props.text, which is what the
-- checks look at.

local function node(kind)
  return function(props, children)
    props = props or {}
    local kids = {}
    for _, child in ipairs(children or {}) do
      if child ~= nil then
        table.insert(kids, child)
      end
    end
    return { kind = kind, props = props, children = kids }
  end
end

local ui = {
  column = node("column"),
  row = node("row"),
  label = node("label"),
  box = node("box"),
  image = node("image"),
  glyph = node("glyph"),
  scroll = node("scroll"),
  button = node("button"),
  toggle = node("toggle"),
  slider = node("slider"),
  input = node("input"),
}

-- Tree helpers ------------------------------------------------------------

local function labelsOf(n)
  local found = {}
  if n == nil then
    return found
  end
  if n.kind == "label" then
    table.insert(found, n)
  end
  for _, child in ipairs(n.children or {}) do
    for _, label in ipairs(labelsOf(child)) do
      table.insert(found, label)
    end
  end
  return found
end

local function rowsOf(n)
  local found = {}
  for _, child in ipairs(n.children or {}) do
    if child.kind == "row" then
      table.insert(found, child)
    end
  end
  return found
end

local function textOf(n)
  local parts = {}
  for _, label in ipairs(labelsOf(n)) do
    table.insert(parts, tostring(label.props.text or ""))
  end
  return table.concat(parts)
end

-- Fixtures ----------------------------------------------------------------

local function cfg(overrides)
  local base = {
    font_size = 22,
    direction = "down",
    marker = false,
    marker_style = 0,
    karaoke = true,
    ghost = true,
    header = false,
    footer = false,
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
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

local function line(start, finish, text, chars)
  return { start = start, ["end"] = finish, text = text, chars = chars }
end

local function lyricLines(count)
  local lines = {}
  for index = 1, count do
    table.insert(lines, line(index * 10, index * 10 + 10, "line " .. index))
  end
  return lines
end

-- Lyrics model ------------------------------------------------------------

if lyrics ~= nil then
  local model = lyrics.normalize({
    ok = true,
    synced = true,
    lines = {
      line(10, 20, "one"),
      line(20, 30, "two"),
      line(30, 60, ""),
      line(60, 120, "three"),
    },
  })
  check(model ~= nil, "lyrics: normalize builds a model")
  check(model and model.synced == true, "lyrics: synced flag")
  eq(lyrics.normalize({ ok = false }), nil, "lyrics: an error is not a model")
  eq(lyrics.normalize({ ok = true, lines = {} }), nil, "lyrics: no lines is not a model")

  local lines = model and model.lines or {}
  eq(lyrics.activeIndex(lines, 5), 0, "lyrics: nothing active before the first line")
  eq(lyrics.activeIndex(lines, 10), 1, "lyrics: the first line starts at its timestamp")
  eq(lyrics.activeIndex(lines, 25.5), 2, "lyrics: the active line is the last one started")
  eq(lyrics.activeIndex(lines, 120), 4, "lyrics: the last line stays active")

  eq(
    lyrics.hasWordTiming({ text = "abc", chars = { 10, 10.2, 10.4 }, start = 10, ["end"] = 11 }),
    true,
    "lyrics: aligned word timings are valid"
  )
  eq(
    lyrics.hasWordTiming({ text = "abc", chars = { 10.4, 10.2, 10 }, start = 10, ["end"] = 11 }),
    false,
    "lyrics: unordered word timings are rejected"
  )
  eq(
    lyrics.hasWordTiming({ text = "abc", chars = { 10 }, start = 10, ["end"] = 11 }),
    false,
    "lyrics: missing word timings are rejected"
  )
  eq(
    lyrics.hasWordTiming({ text = "abc", chars = { 20, 20.2, 20.4 }, start = 10, ["end"] = 11 }),
    false,
    "lyrics: word timings outside the line are rejected"
  )

  -- One timing per character, not per byte: accented lyrics are the normal
  -- case in this plugin, and "canción" is 7 characters but 8 bytes.
  local accented = {
    text = "canción",
    chars = { 10, 10.2, 10.4, 10.6, 10.8, 11, 11.2 },
    start = 10,
    ["end"] = 12,
  }
  eq(lyrics.hasWordTiming(accented), true, "lyrics: word timings count characters, not bytes")
  local accentedAmounts = lyrics.charAmounts(accented, 10.3)
  eq(accentedAmounts[7], 0, "lyrics: the last character of an accented line is addressable")
  eq(
    #lyrics.characters("canción"),
    7,
    "lyrics: characters splits by code point"
  )
  eq(lyrics.characters("canción")[5], "i", "lyrics: characters keeps the text intact")

  local timed = { text = "abcd", chars = { 10, 10.5, 11, 11.5 }, start = 10, ["end"] = 12 }
  local amounts = lyrics.charAmounts(timed, 10.25)
  eq(amounts[1], 0.5, "lyrics: a character is half filled")
  eq(amounts[2], 0, "lyrics: the next character has not started")
  local untimed = { text = "abcd", start = 10, ["end"] = 20 }
  local block = lyrics.charAmounts(untimed, 15)
  eq(block[1], 0.5, "lyrics: without word timings the whole line advances")
  eq(block[4], 0.5, "lyrics: every character of the line advances together")

  eq(lyrics.instrumental(lines, 5, 120, 4), true, "lyrics: a long intro is instrumental")
  eq(lyrics.instrumental(lines, 5, 120, 15), false, "lyrics: a short intro is not instrumental")
  eq(lyrics.instrumental(lines, 40, 120, 4), true, "lyrics: an explicit empty line is instrumental")
  eq(lyrics.instrumental(lines, 25, 120, 4), false, "lyrics: a normal line is not instrumental")
  eq(lyrics.instrumental(lines, 100, 120, 4), true, "lyrics: the outro of a long interval is instrumental")
  eq(
    lyrics.instrumental({ line(10, 14, "short") }, 12, 60, 4),
    false,
    "lyrics: a slightly long line is not an instrumental gap"
  )
end

-- Carousel ----------------------------------------------------------------

if lyrics ~= nil then
  local function carouselOpts(overrides)
    local base = {
      lines = lyricLines(10),
      position = 55, -- inside "line 5" (50..60)
      duration = 110,
      cfg = cfg(),
      ui = ui,
      state = "lyrics",
      title = "Song",
      artist = "Band",
      tr = function(key)
        return key
      end,
      model = lyrics,
    }
    for key, value in pairs(overrides or {}) do
      base[key] = value
    end
    return base
  end

  local function contains(n, text)
    return textOf(n):find(text, 1, true) ~= nil
  end

  -- Window of visible lines.
  local rows = rowsOf(render.carousel(carouselOpts()))
  eq(#rows, 5, "render: two lines above and two below the active one")
  eq(textOf(rows[1]), "line 3", "render: the window starts two lines above")
  eq(textOf(rows[5]), "line 7", "render: the window ends two lines below")
  check(
    not contains(render.carousel(carouselOpts()), "line 9"),
    "render: lines outside the window are not built"
  )

  -- Active line: bigger, one label, and the other lines fade.
  local active = rows[3]
  eq(#labelsOf(active), 1, "render: the active line without timings is one label")
  eq(textOf(active), "line 5", "render: the active line keeps its text")
  check(
    (labelsOf(active)[1] or {}).props.fontSize > cfg().font_size,
    "render: the active line is bigger"
  )
  eq(
    (labelsOf(rows[1])[1] or {}).props.fontSize,
    cfg().font_size,
    "render: the other lines keep the size"
  )
  check(
    rows[1].props.opacity ~= nil and rows[1].props.opacity < 1,
    "render: with ghost the other lines fade"
  )

  -- Per-character karaoke.
  local timed = lyricLines(10)
  timed[5] = line(50, 60, "abcd", { 50, 50.2, 50.4, 50.6 })
  local timedRows = rowsOf(render.carousel(carouselOpts({ lines = timed, position = 50.1 })))
  eq(#labelsOf(timedRows[3]), 4, "render: the active line is one label per character")
  eq(textOf(timedRows[3]), "abcd", "render: the characters spell the line")
  local firstChar = labelsOf(timedRows[3])[1]
  eq(firstChar.props.text, "a", "render: the first label is the first character")
  local secondChar = labelsOf(timedRows[3])[2]
  check(
    secondChar.props.opacity < firstChar.props.opacity,
    "render: a character not sung yet is dimmer"
  )

  -- Damaged timings: the characters exist, but they fill as one block.
  local damaged = lyricLines(10)
  damaged[5] = line(50, 60, "abcd", { 50.6, 50.4, 50.2, 50 })
  local damagedRows = rowsOf(render.carousel(carouselOpts({ lines = damaged, position = 50.1 })))
  eq(#labelsOf(damagedRows[3]), 4, "render: damaged timings keep the characters")
  eq(
    labelsOf(damagedRows[3])[1].props.opacity,
    labelsOf(damagedRows[3])[2].props.opacity,
    "render: damaged timings fill the line as a block"
  )

  -- Karaoke off: one label per row even with timings.
  local offRows = rowsOf(render.carousel(carouselOpts({ cfg = cfg({ karaoke = false }), lines = timed })))
  eq(#labelsOf(offRows[3]), 1, "render: without karaoke the line is one label")

  -- A 300 character line is not split in 300 labels.
  local long = lyricLines(10)
  long[5] = line(50, 60, string.rep("x", 300))
  local longRows = rowsOf(render.carousel(carouselOpts({ lines = long })))
  eq(#labelsOf(longRows[3]), 1, "render: a very long line is not split per character")
  eq(#labelsOf(longRows[3])[1].props.text, 300, "render: the long line keeps its text")

  -- Instrumental placeholder.
  local gap = lyricLines(10)
  gap[5] = line(50, 60, "")
  local gapTree = render.carousel(carouselOpts({ lines = gap }))
  eq(#rowsOf(gapTree), 1, "render: a gap is a single row")
  eq(textOf(gapTree), render.ICONS[1], "render: a gap shows the notes placeholder")
  local custom = render.carousel(carouselOpts({ lines = gap, cfg = cfg({ instrumental_text = "solo" }) }))
  eq(textOf(custom), "solo", "render: the custom text replaces the notes")
  local iconTree = render.carousel(carouselOpts({ lines = gap, cfg = cfg({ instrumental_icon = 2 }) }))
  eq(textOf(iconTree), render.ICONS[3], "render: the icon cycles through the variants")
  local plainGap = rowsOf(
    render.carousel(carouselOpts({ lines = gap, cfg = cfg({ instrumental = false }) }))
  )
  eq(#plainGap, 5, "render: without the placeholder the gap keeps the carousel")

  -- Marker.
  local marked = rowsOf(render.carousel(carouselOpts({ cfg = cfg({ marker = true }) })))
  eq(#labelsOf(marked[3]), 2, "render: the marker adds a label to the active row")
  eq(labelsOf(marked[3])[1].props.text, render.MARKERS[1], "render: the marker is the chosen style")
  eq(#labelsOf(marked[1]), 1, "render: the marker only goes on the active row")
  local styled = rowsOf(
    render.carousel(carouselOpts({ cfg = cfg({ marker = true, marker_style = 3 }) }))
  )
  eq(labelsOf(styled[3])[1].props.text, render.MARKERS[4], "render: the style is index based")
  eq(#labelsOf(rows[3]), 1, "render: without marker there is no glyph")

  -- Direction.
  local upRows = rowsOf(render.carousel(carouselOpts({ cfg = cfg({ direction = "up" }) })))
  eq(textOf(upRows[1]), "line 7", "render: direction up reverses the rows")
  eq(textOf(upRows[5]), "line 3", "render: direction up keeps the same window")

  -- Accent colour.
  local customAccent = rowsOf(
    render.carousel(carouselOpts({
      lines = timed,
      position = 50.1,
      cfg = cfg({ accent = "custom", custom_color = "#123456" }),
    }))
  )
  eq(labelsOf(customAccent[3])[1].props.color, "#123456", "render: a custom accent paints the sung text")
  local fromPalette = rowsOf(
    render.carousel(carouselOpts({
      lines = timed,
      position = 50.1,
      color = function()
        return "#abcdef"
      end,
    }))
  )
  eq(labelsOf(fromPalette[3])[1].props.color, "#abcdef", "render: the palette colour is used when available")

  -- Surface: header, footer and the states.
  local full = render.surface(carouselOpts({
    cfg = cfg({ header = true, footer = true }),
  }))
  check(contains(full, "Song"), "render: the header shows the title")
  check(contains(full, "Band"), "render: the header shows the artist")
  check(contains(full, "0:55 / 1:50"), "render: the footer shows position and duration")

  local bare = render.surface(carouselOpts())
  check(not contains(bare, "Song"), "render: without header there is no title")
  check(not contains(bare, "0:55"), "render: without footer there is no time")

  eq(textOf(render.surface(carouselOpts({ state = "loading" }))), "searching_lyrics", "render: loading message")
  eq(textOf(render.surface(carouselOpts({ state = "idle" }))), "nothing_playing", "render: idle message")
  eq(textOf(render.surface(carouselOpts({ state = "empty" }))), "no_lyrics", "render: empty message")

  -- Bar widget: the active line only.
  local widget = render.surface(carouselOpts({ mode = "widget" }))
  eq(widget.kind, "row", "render: the bar widget is a single row")
  eq(textOf(widget), "line 5", "render: the bar widget shows the active line")
  eq(
    textOf(render.surface(carouselOpts({ mode = "widget", state = "idle" }))),
    "nothing_playing",
    "render: the bar widget has its own message"
  )

  -- The offset setting shifts the whole lyric: at 55s a -6s offset lands in
  -- the previous line. It is applied once, in `surface`, so no entry can
  -- disagree about which line is the current one.
  eq(
    textOf(render.surface(carouselOpts({ mode = "widget", cfg = cfg({ offset_ms = -6000 }) }))),
    "line 4",
    "render: the offset shifts the active line"
  )

  local untouched = carouselOpts({ cfg = cfg({ offset_ms = -6000 }) })
  render.surface(untouched)
  eq(untouched.position, 55, "render: the surface does not mutate the caller options")
end



if failures > 0 then
  io.stderr:write(string.format("%d of %d checks failed\n", failures, checks))
  os.exit(1)
end
print(string.format("%d checks passed", checks))
