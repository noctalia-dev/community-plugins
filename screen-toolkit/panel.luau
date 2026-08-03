--!nonstrict
-- Screen Toolkit — main [[panel]].
--
-- Thin client for the toolkit: a header plus the tool grid grouped into
-- Capture / Annotate / Record sections. It only dispatches actions to the
-- [[service]] through the "command" state channel. Capture tools close the
-- panel first so the capture never includes it.

local panelOpen = false
local recording = noctalia.state.get("recording") == true

-- ── Helpers ────────────────────────────────────────────────────────────────

local function tr(key, subst)
  if subst then return noctalia.tr(key, subst) end
  return noctalia.tr(key)
end

local function send(action, payload)
  noctalia.state.set("command", { action = action, payload = payload })
end

-- Capture tools must not see the panel in the frame, so close it first.
local CAPTURE_ACTIONS = {
  colorPicker = true,
  ocr = true,
  qr = true,
  palette = true,
  lens = true,
  measure = true,
  annotate = true,
  annotateFullscreen = true,
  annotateWindow = true,
  record = true,
  recordMp4 = true,
  recordFullscreen = true,
  recordFullscreenMp4 = true,
}

local function runTool(action)
  if CAPTURE_ACTIONS[action] then
    panel.close()
  end
  send(action)
end

-- ── Header ─────────────────────────────────────────────────────────────────

local function header()
  local actions = {
    ui.button({ glyph = "close", onClick = function() panel.close() end }),
  }
  if recording then
    table.insert(actions, 1, ui.button({
      glyph = "square",
      variant = "destructive",
      controlSize = "sm",
      tooltip = tr("panel.stop"),
      onClick = function() send("recordStop") end,
    }))
  end
  return ui.row({ align = "center", gap = 8 }, {
    ui.label({ text = tr("panel.title"), flexGrow = 1, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.row({ gap = 4 }, actions),
  })
end

-- ── Tool grid ──────────────────────────────────────────────────────────────

local TOOLS = {
  { action = "colorPicker", label_key = "tools.colorpicker", glyph = "palette" },
  { action = "ocr", label_key = "tools.ocr", glyph = "scan" },
  { action = "qr", label_key = "tools.qr", glyph = "qrcode" },
  { action = "palette", label_key = "tools.palette", glyph = "color-swatch" },
  { action = "lens", label_key = "tools.lens", glyph = "search" },
  { action = "measure", label_key = "tools.measure", glyph = "ruler" },
}

local ANNOTATE_TOOLS = {
  { action = "annotate", label_key = "tools.annotate", glyph = "pencil" },
  { action = "annotateFullscreen", label_key = "tools.annotate_fullscreen", glyph = "maximize" },
  { action = "annotateWindow", label_key = "tools.annotate_window", glyph = "window" },
}

local RECORD_TOOLS = {
  { action = "record", label_key = "tools.record_gif", glyph = "gif" },
  { action = "recordMp4", label_key = "tools.record_mp4", glyph = "movie" },
  { action = "recordFullscreen", label_key = "tools.record_fullscreen_gif", glyph = "video" },
  { action = "recordFullscreenMp4", label_key = "tools.record_fullscreen_mp4", glyph = "video" },
}

local function toolTile(t)
  return ui.column({
    key = "tile-" .. t.action,
    flexGrow = 1,
    gap = 6,
    align = "center",
    paddingV = 6,
    radius = 10,
    fill = "surface_variant/0.28",
    borderWidth = 1,
    border = "outline",
    onClick = function() runTool(t.action) end,
  }, {
    ui.column({ width = 30, height = 30, radius = 9, fill = "primary/0.12", align = "center", justify = "center" }, {
      ui.glyph({ name = t.glyph, size = 16, color = "primary" }),
    }),
    ui.label({ text = tr(t.label_key), maxWidth = 100, maxLines = 1, textAlign = "center", fontSize = 11, color = "on_surface_variant" }),
  })
end

local function toolsRow(tools)
  local row = {}
  for _, t in ipairs(tools) do
    row[#row + 1] = toolTile(t)
  end
  return ui.row({ flexGrow = 1, gap = 6 }, row)
end

local function sectionLabel(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "on_surface_variant" })
end

local function toolGrid()
  return ui.column({ flexGrow = 1, gap = 4, justify = "space_between" }, {
    sectionLabel(tr("panel.section_capture")),
    toolsRow(TOOLS),
    sectionLabel(tr("panel.section_annotate")),
    toolsRow(ANNOTATE_TOOLS),
    sectionLabel(tr("panel.section_record")),
    toolsRow(RECORD_TOOLS),
  })
end

-- ── Main render ────────────────────────────────────────────────────────────

local function render()
  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    header(),
    toolGrid(),
  }))
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

function onOpen(_context)
  panelOpen = true
  render()
end

function onClose()
  panelOpen = false
end

noctalia.state.watch("recording", function(v)
  recording = v == true
  if panelOpen then render() end
end)

function update()
  noctalia.setUpdateInterval(500)
end
