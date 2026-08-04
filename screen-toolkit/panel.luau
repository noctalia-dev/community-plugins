--!nonstrict
-- Screen Toolkit — main [[panel]].
--
-- Thin client for the toolkit. Two layouts are provided, selected by the
-- "panel-mode" plugin setting:
--   * compact  — a dense grid grouped into tinted sections (default)
--   * full     — the original spacious layout with section titles
-- The panel entry to open (and thus its host-owned size) is chosen by the
-- bar [[widget]] / control-center [[shortcut]] from the same setting.
-- It only dispatches actions to the [[service]] through the "command"
-- state channel. Capture tools close the panel first so the capture never
-- includes it.

local panelOpen = false
local recording = noctalia.state.get("recording") == true
local hoveredTool = nil
local hoveredClose = false
local hoveredStop = false
local render

-- ── Helpers ────────────────────────────────────────────────────────────────

local function tr(key, subst)
  if subst then return noctalia.tr(key, subst) end
  return noctalia.tr(key)
end

local function send(action, payload)
  noctalia.state.set("command", { action = action, payload = payload })
end

local function getMode()
  return noctalia.getConfig("panel-mode") == "full" and "full" or "compact"
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

-- ── Tool data ──────────────────────────────────────────────────────────────

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

-- ── Compact mode ───────────────────────────────────────────────────────────

local function compactHeader()
  local actions = {
    ui.column({
      key = "close-button",
      width = 24,
      height = 24,
      radius = 9,
      fill = hoveredClose and "primary/0.12" or nil,
      border = hoveredClose and "primary" or "outline",
      borderWidth = 1,
      align = "center",
      justify = "center",
      onClick = function() panel.close() end,
      onHover = function(state)
        hoveredClose = state == "true"
        render()
      end,
    }, {
      ui.glyph({ name = "close", size = 14, color = hoveredClose and "on_surface" or "on_surface_variant" }),
    }),
  }
  if recording then
    table.insert(actions, 1, ui.column({
      key = "stop-button",
      width = 24,
      height = 24,
      radius = 9,
      fill = "error",
      border = hoveredStop and "on_surface" or nil,
      borderWidth = hoveredStop and 2 or 0,
      align = "center",
      justify = "center",
      tooltip = tr("panel.stop"),
      onClick = function() send("recordStop") end,
      onHover = function(state)
        hoveredStop = state == "true"
        render()
      end,
    }, {
      ui.glyph({ name = "square", size = 12, color = "on_surface" }),
    }))
  end
  return ui.row({ align = "center", gap = 6 }, {
    ui.glyph({ name = "crosshair", size = 16, color = "primary" }),
    ui.label({ text = tr("panel.title"), flexGrow = 1, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.row({ gap = 4 }, actions),
  })
end

local function compactTile(t)
  local color = hoveredTool == t.action and "primary" or "on_surface"
  return ui.column({
    key = "tile-" .. t.action,
    flexGrow = 1,
    gap = 2,
    align = "center",
  }, {
    ui.column({
      gap = 2,
      align = "center",
      onClick = function() runTool(t.action) end,
      onHover = function(state)
        hoveredTool = (state == "true") and t.action or nil
        render()
      end,
    }, {
      ui.column({ width = 30, height = 30, radius = 9, fill = "on_primary", border = color == "primary" and "primary" or "on_primary", borderWidth = 1, align = "center", justify = "center" }, {
        ui.glyph({ name = t.glyph, size = 16, color = color }),
      }),
      ui.label({ text = tr(t.label_key), maxWidth = 100, maxLines = 1, textAlign = "center", fontSize = 11, color = color }),
    }),
  })
end

local function compactToolsRow(tools)
  local row = {}
  for _, t in ipairs(tools) do
    row[#row + 1] = compactTile(t)
  end
  return ui.row({ flexGrow = 1, gap = 2 }, row)
end

local function compactSection(tools)
  return ui.column({ gap = 4, paddingV = 8, paddingH = 6, radius = 12, fill = "surface_variant" }, {
    compactToolsRow(tools),
  })
end

local function compactGrid()
  return ui.column({ gap = 6 }, {
    compactSection(TOOLS),
    compactSection(ANNOTATE_TOOLS),
    compactSection(RECORD_TOOLS),
  })
end

-- ── Full mode ──────────────────────────────────────────────────────────────

local function fullHeader()
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
  return ui.row({ align = "center", gap = 10 }, {
    ui.glyph({ name = "crosshair", size = 24, color = "primary" }),
    ui.label({ text = tr("panel.title"), flexGrow = 1, fontSize = 22, fontWeight = "bold", color = "on_surface" }),
    ui.row({ gap = 4 }, actions),
  })
end

local function fullTile(t)
  local color = hoveredTool == t.action and "primary" or "on_surface"
  return ui.column({
    key = "tile-" .. t.action,
    flexGrow = 1,
    gap = 6,
    align = "center",
    paddingV = 6,
    radius = 12,
    fill = "surface_variant",
    borderWidth = 1,
    border = color == "primary" and "primary" or "outline",
    onClick = function() runTool(t.action) end,
    onHover = function(state)
      hoveredTool = (state == "true") and t.action or nil
      render()
    end,
  }, {
    ui.column({ width = 30, height = 30, radius = 9, fill = "on_primary", border = color == "primary" and "primary" or "on_primary", borderWidth = 1, align = "center", justify = "center" }, {
      ui.glyph({ name = t.glyph, size = 16, color = color }),
    }),
    ui.label({ text = tr(t.label_key), maxWidth = 100, maxLines = 1, textAlign = "center", fontSize = 11, color = color }),
  })
end

local function fullToolsRow(tools)
  local row = {}
  for _, t in ipairs(tools) do
    row[#row + 1] = fullTile(t)
  end
  return ui.row({ flexGrow = 1, gap = 6 }, row)
end

local function sectionLabel(text)
  return ui.label({ text = text, fontSize = 11, fontWeight = "bold", color = "on_surface_variant" })
end

local function fullGrid()
  return ui.column({ flexGrow = 1, gap = 4, justify = "space_between" }, {
    sectionLabel(tr("panel.section_capture")),
    fullToolsRow(TOOLS),
    sectionLabel(tr("panel.section_annotate")),
    fullToolsRow(ANNOTATE_TOOLS),
    sectionLabel(tr("panel.section_record")),
    fullToolsRow(RECORD_TOOLS),
  })
end

-- ── Main render ────────────────────────────────────────────────────────────

render = function()
  local body
  if getMode() == "full" then
    body = ui.column({ flexGrow = 1, gap = 10 }, {
      fullHeader(),
      fullGrid(),
    })
  else
    body = ui.column({ flexGrow = 1, gap = 6 }, {
      compactHeader(),
      compactGrid(),
    })
  end
  panel.render(body)
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

function onOpen(_context)
  panelOpen = true
  hoveredTool = nil
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
