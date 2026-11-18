--!nonstrict
-- One post-it, one widget instance. Add a second desktop widget for a second
-- note; each instance is bound to a note by its `key` setting.
--
-- Desktop widgets are background layer-shell surfaces: they take clicks but
-- never keyboard focus. So the paper is a single click target that hands the
-- note to the panel, which is the surface that can take typing.
--
-- The paper is drawn out of plain flex nodes, because the ui vocabulary has no
-- z-stacking: the drop shadow is an L of translucent boxes along the bottom and
-- right edges.

local colors = require("./colors.luau")

local SHADOW_WIDTH = 4
local TEXT_GAP = 6
local PAD_H = 14
local PAD_V = 14
local PAD_V_TAPED = 6
local TAPE_HEIGHT = 20
-- A label that outgrows its column is not clipped here: the extra lines are
-- drawn straight off the paper and onto the wallpaper. So the line budget has
-- to be worked out before the label is built, and this vocabulary has no text
-- metric to work it out with. Both numbers are deliberately generous - a sheet
-- that drops a line it could have drawn is a smaller lie than a sheet leaking
-- text over the wallpaper.
local LINE_HEIGHT = 1.4
-- Average advance per glyph, as a share of the font size. Tuned for the
-- bundled handwriting font, which is narrower than a UI font: too high and a
-- sheet claims to be cut when everything fits, too low and it cuts silently.
local GLYPH_ADVANCE = 0.46
-- What a sheet says instead of the rest of the note. It rides the end of the
-- last line it kept, the way a sentence trails off, rather than taking a line
-- of its own - a line of the note is worth more than a tidy mark. The whole
-- text is one click away in the panel.
local CLIPPED_MARK = "..."
local TAPE_SPOTS = { "none", "left", "center", "right", "center" }

local noteKey = noctalia.string.trim(noctalia.getConfig("key") or "")
local paperWidth = math.max(80, math.floor(tonumber(noctalia.getConfig("paper_width")) or 220))
local paperHeight = math.max(60, math.floor(tonumber(noctalia.getConfig("paper_height")) or 200))
local fontSize = math.max(8, math.floor(tonumber(noctalia.getConfig("font_size")) or 16))
-- Plugin-wide, and arriving as state rather than getConfig: getConfig here
-- reads this widget's own settings, and state makes the slider take effect the
-- moment it moves. Read at the bottom, once the watchers are in place.
local paperOpacity = 0.96
local themeColors = false
-- The shadow is drawn outside the paper, so it comes out of the widget's box
-- rather than being added to it: the sheet is that much smaller than the size
-- that was asked for.
local sheetWidth = paperWidth - SHADOW_WIDTH
local sheetHeight = paperHeight - SHADOW_WIDTH

-- Everything generated (paper tint, tape) hangs off a seed, so two
-- post-its differ from each other while each one stays the same over time. The
-- key is the stable identity when there is one; otherwise the note's id at
-- least separates one keyless note from another.
local function seedOf(note)
  if noteKey ~= "" then
    return noteKey
  end
  if note ~= nil then
    return note.id
  end
  return "default"
end

local fontFamily = nil
local fontPath = noctalia.string.trim(noctalia.getConfig("font_path") or "")
if fontPath ~= "" then
  local family, err = noctalia.loadFont(fontPath)
  if family ~= nil then
    fontFamily = family
  else
    noctalia.log("noctes: font load failed: " .. tostring(err))
  end
end

local notes = {}
local ready = false

-- What this sheet last drew. Every note edit republishes the whole list to
-- every sheet, so without this each autosave would rebuild the tree of every
-- post-it on the desktop, not just the one being written.
local lastDrawn = nil

local function signatureOf(note)
  if note == nil then
    return "-|" .. tostring(ready)
  end
  return table.concat({
    note.id, note.key or "", note.title or "", note.content or "",
    note.color or "", tostring(ready),
  }, "\30")
end

-- A sheet with no key yet - one the widget editor just made, before the
-- service adopts it - shows no note. "" is the key of every note that has no
-- sheet, so matching on it would put an arbitrary one of those on this paper.
local function currentNote()
  if noteKey == "" then
    return nil
  end
  for _, note in ipairs(notes) do
    if (note.key or "") == noteKey then
      return note
    end
  end
  return nil
end

local function resolvedTape(seed)
  local spot = colors.pick(TAPE_SPOTS, seed, "tape")
  return spot ~= "none" and spot or nil
end

-- A small signed jitter from the seed, so no two sheets share a tape width or
-- position exactly.
local function jitter(seed, salt, spread)
  return (colors.hash(salt .. "|" .. seed) % (spread * 2 + 1)) - spread
end

local function glyphCount(s)
  return (utf8 ~= nil and utf8.len(s) or nil) or #s
end

-- The first `n` glyphs, not the first n bytes: the notes are pt-BR as often as
-- not, and cutting an accent in half writes a replacement glyph on the paper.
local function cutGlyphs(s, n)
  if utf8 ~= nil and utf8.offset ~= nil then
    local at = utf8.offset(s, n + 1)
    return at ~= nil and string.sub(s, 1, at - 1) or s
  end
  return string.sub(s, 1, n)
end

local function lineBox(size)
  return math.max(1, math.floor(size * LINE_HEIGHT + 0.5))
end

-- Lines a string takes at `size`, wrapped to the paper. Rough by construction:
-- it counts glyphs against an average advance, so a line of Ms overflows and a
-- line of Is comes up short.
local function glyphsPerLine(size)
  return math.max(1, math.floor((sheetWidth - PAD_H * 2) / (size * GLYPH_ADVANCE)))
end

local function wrappedLines(s, size)
  local perLine = glyphsPerLine(size)
  local total = 0
  -- The trailing newline makes the last line match like any other, and an
  -- empty line still costs one.
  for line in string.gmatch(s .. "\n", "([^\n]*)\n") do
    total = total + math.max(1, math.ceil(glyphCount(line) / perLine))
  end
  return math.max(1, total)
end

-- The text cut down to `budget` wrapped lines, ending in `mark` when there was
-- more note than paper. The label's own maxLines is not enough: this host draws
-- the lines it is given whether or not they fit the column, and the overflow
-- lands on the wallpaper. So the sheet hands the label text that already fits,
-- and maxLines stays as a second net.
local function clampToLines(s, size, budget, mark)
  local perLine = glyphsPerLine(size)
  local kept = {}
  local used = 0

  -- The mark goes on the last row that was kept, so that row gives up as many
  -- glyphs as the mark takes. Without this it wraps onto a row of its own,
  -- which is the line it was supposed to save.
  local function marked()
    if mark == nil then
      return table.concat(kept, "\n")
    end
    local last = table.remove(kept) or ""
    local rows = math.max(1, math.ceil(glyphCount(last) / perLine))
    local room = math.max(0, rows * perLine - glyphCount(mark))
    if glyphCount(last) > room then
      last = cutGlyphs(last, room)
    end
    table.insert(kept, last .. mark)
    return table.concat(kept, "\n")
  end

  for line in string.gmatch(s .. "\n", "([^\n]*)\n") do
    if used >= budget then
      return marked()
    end
    local rows = math.max(1, math.ceil(glyphCount(line) / perLine))
    if used + rows <= budget then
      table.insert(kept, line)
      used = used + rows
    else
      -- The line outlives the budget: keep the rows that still fit.
      table.insert(kept, cutGlyphs(line, (budget - used) * perLine))
      return marked()
    end
  end
  return table.concat(kept, "\n")
end

-- Body lines the paper has room for, once the tape, the padding and the title
-- have taken their share.
local function paperLineBudget(titleHeight, tape)
  local padding = (tape ~= nil and PAD_V_TAPED or PAD_V) * 2
  local room = sheetHeight - padding - titleHeight
    - (tape ~= nil and TAPE_HEIGHT or 0)
  return math.max(1, math.floor(room / lineBox(fontSize)))
end

-- ── Paper parts ─────────────────────────────────────────────────────────────

-- A strip of matte tape near the top edge.
local function tapeRow(spot, seed)
  local width = 62 + jitter(seed, "tapew", 9)
  local inset = 14 + jitter(seed, "tapex", 8)
  local strip = ui.column({ gap = 0, width = width, height = 13, align = "stretch" }, {
    ui.box({ height = 1, fill = colors.TAPE_EDGE }),
    ui.box({ flexGrow = 1, fill = colors.TAPE }),
    ui.box({ height = 1, fill = colors.TAPE_EDGE }),
  })

  local cells
  if spot == "left" then
    cells = { ui.spacer({ width = inset }), strip, ui.spacer({ flexGrow = 1 }) }
  elseif spot == "right" then
    cells = { ui.spacer({ flexGrow = 1 }), strip, ui.spacer({ width = inset }) }
  else
    cells = { ui.spacer({ flexGrow = 1 }), strip, ui.spacer({ flexGrow = 1 }) }
  end
  return ui.row({ gap = 0, height = 20, align = "center" }, cells)
end

-- ── Actions ─────────────────────────────────────────────────────────────────

local function openPanel()
  -- togglePanel is the only entry point, so opening an already-open panel would
  -- close it. The panel publishes its own state for exactly this check.
  if noctalia.state.get("noctes.panelOpen") ~= true then
    noctalia.togglePanel("remo/noctes:panel")
  end
end

local function onPaperClick()
  if noteKey == "" then
    openPanel()
    return
  end
  local note = currentNote()
  if note == nil then
    -- The service creates the note for this key and selects it; the panel opens
    -- on it, so a blank post-it is one click away from being written.
    noctalia.state.set("noctes.cmd", { op = "ensure", key = noteKey })
  else
    noctalia.state.set("noctes.editing", note.id)
  end
  openPanel()
end

-- ── Render ──────────────────────────────────────────────────────────────────

local function render()
  local note = currentNote()
  lastDrawn = signatureOf(note)
  local seed = seedOf(note)
  -- "" is dynamic, and colors.paper turns that into a palette role or a
  -- generated paper. The color lives on the note, picked in the panel, so the
  -- same note looks the same wherever it is drawn.
  local paper, ink, inkMuted, edge = colors.paper(note ~= nil and note.color or "", seed, themeColors)
  local tape = resolvedTape(seed)

  local body = {}

  if tape ~= nil then
    table.insert(body, tapeRow(tape, seed))
  end

  local text = {}
  local hasTitle = note ~= nil and (note.title or "") ~= ""
  local titleHeight = 0
  if hasTitle then
    local titleSize = fontSize + 3
    local titleLines = math.min(2, wrappedLines(note.title, titleSize))
    titleHeight = titleLines * lineBox(titleSize) + TEXT_GAP
    table.insert(text, ui.label({
      text = clampToLines(note.title, titleSize, titleLines),
      fontSize = titleSize,
      fontWeight = "bold",
      fontFamily = fontFamily,
      color = ink,
      maxLines = 2,
    }))
  end

  local content
  if not ready then
    content = noctalia.tr("note.loading")
  elseif note == nil then
    content = noctalia.tr("note.empty_hint")
  elseif noctalia.string.trim(note.content or "") == "" then
    content = noctalia.tr("note.empty_hint")
  else
    content = note.content
  end
  local isPlaceholder = note == nil or noctalia.string.trim(note.content or "") == ""

  local budget = paperLineBudget(titleHeight, tape)
  if not isPlaceholder and wrappedLines(content, fontSize) > budget then
    content = clampToLines(content, fontSize, budget, CLIPPED_MARK)
  end

  table.insert(text, ui.label({
    text = content,
    fontSize = fontSize,
    fontFamily = fontFamily,
    color = isPlaceholder and inkMuted or ink,
    maxLines = budget,
    flexGrow = 1,
  }))

  table.insert(body, ui.column({
    gap = TEXT_GAP,
    paddingH = PAD_H,
    paddingV = tape ~= nil and PAD_V_TAPED or PAD_V,
    flexGrow = 1,
    align = "stretch",
  }, text))

  -- Paper corners stay nearly square: a rounded card reads as UI, a sharp one
  -- reads as paper.
  local sheet = ui.column({
    width = sheetWidth,
    height = sheetHeight,
    gap = 0,
    radius = 2,
    fill = colors.withAlpha(paper, paperOpacity),
    border = edge,
    borderWidth = edge ~= nil and 1 or nil,
    align = "stretch",
    onClick = onPaperClick,
  }, body)

  -- The shadow is one softened box down the right edge and one along the
  -- bottom. Stacked hard-edged bands were the obvious way to fake a falloff and
  -- the wrong one: the host rotates the whole sheet, and rotating three crisp
  -- 3px stripes resamples them into a staircase. A single box with a wide
  -- `softness` is one edge for the rotation to deal with, and the feathering
  -- does the falloff that the bands were imitating.
  local armLength = sheetHeight - SHADOW_WIDTH

  desktopWidget.render(ui.column({ gap = 0, width = paperWidth, height = paperHeight }, {
    ui.row({ gap = 0, height = sheetHeight }, {
      sheet,
      ui.column({ gap = 0, width = SHADOW_WIDTH, height = sheetHeight }, {
        ui.spacer({ width = SHADOW_WIDTH, height = SHADOW_WIDTH }),
        ui.box({
          width = SHADOW_WIDTH,
          height = armLength,
          fill = colors.SHADOW,
          softness = SHADOW_WIDTH,
        }),
      }),
    }),
    ui.row({ gap = 0, height = SHADOW_WIDTH }, {
      ui.spacer({ width = SHADOW_WIDTH, height = SHADOW_WIDTH }),
      ui.box({
        width = paperWidth - SHADOW_WIDTH,
        height = SHADOW_WIDTH,
        fill = colors.SHADOW,
        softness = SHADOW_WIDTH,
      }),
    }),
  }))
end

noctalia.state.watch("noctes.notes", function(value)
  notes = type(value) == "table" and value or {}
  if signatureOf(currentNote()) == lastDrawn then
    return
  end
  render()
end)

noctalia.state.watch("noctes.paperOpacity", function(value)
  local next = tonumber(value) or 0.96
  if next == paperOpacity then
    return
  end
  paperOpacity = next
  render()
end)

-- The host wakes a watcher on every set, changed or not. So every watcher here
-- checks against what it last drew before paying for a render; one that did
-- not would rebuild every sheet on the desk each time any of them was written.
noctalia.state.watch("noctes.ready", function(value)
  local next = value == true
  if next == ready then
    return
  end
  ready = next
  render()
end)

noctalia.state.watch("noctes.themeColors", function(value)
  local next = value == true
  if next == themeColors then
    return
  end
  themeColors = next
  render()
end)

-- Read after the watchers are registered: a value set in between is then
-- either seen here or delivered to a watcher, never missed.
local initialNotes = noctalia.state.get("noctes.notes")
notes = type(initialNotes) == "table" and initialNotes or {}
ready = noctalia.state.get("noctes.ready") == true
themeColors = noctalia.state.get("noctes.themeColors") == true
paperOpacity = tonumber(noctalia.state.get("noctes.paperOpacity")) or 0.96
render()
