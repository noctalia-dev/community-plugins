--!nonstrict
-- Screen Toolkit — result [[panel]].
--
-- A separate panel the [[service]] opens when a capture tool finishes. It
-- renders the result (color / OCR / QR / palette) at a comfortable size, with
-- copy / search / translate / share actions. It is a thin client: it reads the
-- published state and dispatches actions through the "command" channel.

local panelOpen = false

local recordState = noctalia.state.get("recordState") or "idle"
local activeTool = noctalia.state.get("activeTool")
local colorResult = noctalia.state.get("colorResult")
local colorHistory = noctalia.state.get("colorHistory") or {}
local ocrResult = noctalia.state.get("ocrResult")
local translateResult = noctalia.state.get("translateResult")
local qrResult = noctalia.state.get("qrResult")
local paletteColors = noctalia.state.get("paletteColors") or {}

-- ── Helpers ────────────────────────────────────────────────────────────────

local function tr(key, subst)
  if subst then return noctalia.tr(key, subst) end
  return noctalia.tr(key)
end

local function send(action, payload)
  noctalia.state.set("command", { action = action, payload = payload })
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", [["'"']]) .. "'"
end

local function copyText(text, notifyKey)
  if not text or text == "" then return end
  noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
  if notifyKey then noctalia.notify(tr("plugin_name"), tr(notifyKey)) end
end

local function actionButton(glyph, text, onClick, variant)
  return ui.button({
    glyph = glyph,
    text = text,
    controlSize = "sm",
    variant = variant or "default",
    onClick = onClick,
  })
end

local function refresh()
  recordState = noctalia.state.get("recordState") or "idle"
  activeTool = noctalia.state.get("activeTool")
  colorResult = noctalia.state.get("colorResult")
  colorHistory = noctalia.state.get("colorHistory") or {}
  ocrResult = noctalia.state.get("ocrResult")
  translateResult = noctalia.state.get("translateResult")
  qrResult = noctalia.state.get("qrResult")
  paletteColors = noctalia.state.get("paletteColors") or {}
end

-- ── Header ─────────────────────────────────────────────────────────────────

local function header()
  local title, glyph = tr("panel.title"), "crosshair"
  if recordState == "ready" then
    title, glyph = tr("panel.ready"), "video"
  elseif activeTool == "colorpicker" then
    title, glyph = tr("tools.colorpicker"), "palette"
  elseif activeTool == "ocr" then
    title, glyph = tr("tools.ocr"), "scan"
  elseif activeTool == "qr" then
    title, glyph = tr("tools.qr"), "qrcode"
  elseif activeTool == "palette" then
    title, glyph = tr("tools.palette"), "color-swatch"
  end
  return ui.row({ align = "center", gap = 10 }, {
    ui.column({ width = 36, height = 36, radius = 10, fill = "primary/0.15", align = "center", justify = "center" }, {
      ui.glyph({ name = glyph, size = 18, color = "primary" }),
    }),
    ui.label({ text = title, flexGrow = 1, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.button({
      text = tr("panel.clear"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        if recordState == "ready" then send("recordDiscard") else send("clearResult") end
        panel.close()
      end,
    }),
    ui.button({ glyph = "close", onClick = function() panel.close() end }),
  })
end

-- Recording finished: choose how to save it.
local function recordSaveCard()
  return ui.column({ flexGrow = 1, gap = 12, justify = "center" }, {
    ui.row({ gap = 10, align = "center", paddingH = 12, paddingV = 12, radius = 12, fill = "surface_variant/0.25" }, {
      ui.column({ width = 34, height = 34, radius = 10, fill = "primary/0.15", align = "center", justify = "center" }, {
        ui.glyph({ name = "video", size = 18, color = "primary" }),
      }),
      ui.column({ flexGrow = 1, gap = 1 }, {
        ui.label({ text = tr("panel.ready"), fontSize = 14, fontWeight = "bold" }),
        ui.label({ text = tr("panel.ready_hint"), fontSize = 11, color = "on_surface_variant" }),
      }),
    }),
    ui.row({ gap = 6 }, {
      actionButton("movie", tr("panel.save_mp4"), function() send("recordSaveMp4") end, "primary"),
      actionButton("gif", tr("panel.save_gif"), function() send("recordSaveGif") end),
      actionButton("copy", tr("panel.copy"), function() send("recordCopy") end),
      actionButton("trash", tr("panel.discard"), function() send("recordDiscard") end, "ghost"),
    }),
  })
end

-- ── Result views ───────────────────────────────────────────────────────────

local function emptyState(glyph, text)
  return ui.column({ flexGrow = 1, gap = 10, align = "center", justify = "center" }, {
    ui.glyph({ name = glyph, size = 30, color = "outline" }),
    ui.label({ text = text, fontSize = 12, color = "on_surface_variant" }),
  })
end

local function colorFormatRow(name, value, notifyKey)
  return ui.row({ gap = 8, align = "center", paddingH = 10, paddingV = 8, radius = 10, fill = "surface_variant/0.25" }, {
    ui.label({ text = name, width = 40, fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
    ui.label({ text = value, flexGrow = 1, fontSize = 12 }),
    ui.button({ glyph = "copy", variant = "ghost", onClick = function() copyText(value, notifyKey) end }),
  })
end

local function colorHistoryRow()
  if #colorHistory == 0 then
    return ui.label({ text = tr("panel.no_history"), fontSize = 12, color = "muted" })
  end
  local swatches = {}
  for i = #colorHistory, 1, -1 do
    local hex = colorHistory[i]
    table.insert(swatches, ui.column({
      key = "hist-" .. hex,
      flexGrow = 1,
      gap = 4,
      align = "center",
      onClick = function() copyText(hex, "panel.color_copied") end,
    }, {
      ui.box({ width = 26, height = 26, radius = 8, fill = hex, borderWidth = 1, border = "outline" }),
    }))
  end
  return ui.row({ gap = 8 }, swatches)
end

local function renderColor()
  if not colorResult then
    return emptyState("palette", tr("panel.no_color"))
  end
  local c = colorResult
  return ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ gap = 12, align = "center" }, {
      ui.box({ key = "swatch", width = 76, height = 50, radius = 12, fill = c.hex, borderWidth = 2, border = "outline" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = c.hex, fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = c.rgb, fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.column({ align = "end", gap = 4 }, {
        actionButton("color-picker", tr("panel.pick_again"), function() send("colorPicker"); panel.close() end),
        actionButton("trash", tr("panel.clear"), function() send("clearResult"); panel.close() end, "ghost"),
      }),
    }),
    ui.row({ gap = 6 }, {
      actionButton("copy", tr("panel.copy_all"), function()
        copyText(string.format("%s\n%s\n%s\n%s", c.hex, c.rgb, c.hsl, c.hsv), "panel.all_formats_copied")
      end),
      actionButton("share", tr("panel.share"), function() send("share", c.capturePath) end),
    }),
    ui.separator({ spacing = 4 }),
    colorFormatRow("HEX", c.hex, "panel.copy_hex"),
    colorFormatRow("RGB", c.rgb, "panel.copy_rgb"),
    colorFormatRow("HSL", c.hsl, "panel.copy_hsl"),
    colorFormatRow("HSV", c.hsv, "panel.copy_hsv"),
    ui.separator({ spacing = 4 }),
    ui.column({ gap = 6 }, {
      ui.row({ align = "center", justify = "space_between", gap = 8 }, {
        ui.label({ text = tr("panel.history"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
        ui.button({ text = tr("panel.clear_history"), controlSize = "sm", variant = "ghost", onClick = function() send("clearHistory") end }),
      }),
      colorHistoryRow(),
    }),
  })
end

local function renderOcr()
  if not ocrResult then
    return emptyState("scan", tr("panel.no_result"))
  end
  local scrollChildren = {
    ui.label({ text = tr("panel.ocr_text"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
    ui.label({ text = ocrResult.text, fontSize = 13 }),
  }
  if translateResult and translateResult ~= "" then
    table.insert(scrollChildren, ui.separator({ spacing = 6 }))
    table.insert(scrollChildren, ui.label({ text = tr("panel.translation"), fontSize = 12, fontWeight = "bold", color = "primary" }))
    table.insert(scrollChildren, ui.label({ text = translateResult, fontSize = 13 }))
  end
  return ui.column({ flexGrow = 1, gap = 8 }, {
    ui.row({ gap = 6 }, {
      actionButton("copy", tr("panel.copy_text"), function() copyText(ocrResult.text, "panel.copied") end),
      actionButton("search", tr("panel.search_text"), function() send("ocrSearch") end),
      ui.input({
        key = "ocr-translate-input",
        placeholder = "en",
        controlSize = "sm",
        width = 96,
        onSubmit = function(value) send("ocrTranslate", value) end,
      }),
      actionButton("share", tr("panel.share"), function() send("share", ocrResult.capturePath) end),
    }),
    ui.scroll({ flexGrow = 1, gap = 8 }, scrollChildren),
  })
end

local function renderQr()
  if not qrResult then
    return emptyState("qrcode", tr("panel.no_result"))
  end
  local text = qrResult.text or ""
  local isUrl = text:sub(1, 4) == "http"
  local buttons = {
    actionButton("copy", tr("panel.copy_text"), function() copyText(text, "panel.copied") end),
  }
  if isUrl then
    table.insert(buttons, actionButton("external-link", tr("panel.open_url"), function()
      noctalia.runAsync("xdg-open " .. shellQuote(text))
    end))
  end
  table.insert(buttons, actionButton("share", tr("panel.share"), function() send("share", qrResult.capturePath) end))
  return ui.column({ flexGrow = 1, gap = 8 }, {
    ui.row({ gap = 6 }, buttons),
    ui.scroll({ flexGrow = 1, gap = 8 }, {
      ui.image({ path = qrResult.capturePath, height = 110, fit = "contain", radius = 12, borderWidth = 1, border = "outline" }),
      ui.label({ text = text, fontSize = 13 }),
    }),
  })
end

local function renderPalette()
  if #paletteColors == 0 then
    return emptyState("color-swatch", tr("panel.no_result"))
  end
  local tiles = {}
  for i, hex in ipairs(paletteColors) do
    table.insert(tiles, ui.column({
      key = "pal-" .. i,
      flexGrow = 1,
      gap = 5,
      align = "center",
      paddingV = 8,
      radius = 12,
      fill = "surface_variant/0.25",
      borderWidth = 1,
      border = "outline",
      onClick = function() copyText(hex, "panel.color_copied") end,
    }, {
      ui.box({ width = 34, height = 34, radius = 10, fill = hex, borderWidth = 1, border = "outline" }),
      ui.label({ text = hex, fontSize = 9, color = "on_surface_variant" }),
    }))
  end
  return ui.column({ flexGrow = 1, gap = 8 }, {
    ui.row({ gap = 6 }, {
      actionButton("copy", tr("panel.copy_hex_list"), function()
        copyText(table.concat(paletteColors, "\n"), "panel.hex_list_copied")
      end),
      actionButton("code", tr("panel.copy_css_vars"), function()
        local buf = {}
        for i, hex in ipairs(paletteColors) do buf[#buf + 1] = `--palette-{i}: {hex};` end
        copyText(table.concat(buf, "\n"), "panel.css_vars_copied")
      end),
      actionButton("share", tr("panel.share"), function() send("share", "/tmp/screen-toolkit-palette.png") end),
    }),
    ui.row({ gap = 6 }, tiles),
  })
end

-- ── Render ─────────────────────────────────────────────────────────────────

local function body()
  if recordState == "ready" then
    return recordSaveCard()
  elseif activeTool == "colorpicker" then
    return renderColor()
  elseif activeTool == "ocr" then
    return renderOcr()
  elseif activeTool == "qr" then
    return renderQr()
  elseif activeTool == "palette" then
    return renderPalette()
  end
  return emptyState("crosshair", tr("panel.empty"))
end

local function render()
  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    header(),
    body(),
  }))
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

function onOpen(_context)
  panelOpen = true
  refresh()
  render()
end

function onClose()
  panelOpen = false
end

noctalia.state.watch("recordState", function(v)
  if recordState == "ready" and v ~= "ready" then
    panel.close()
    return
  end
  recordState = v or "idle"
  if panelOpen then render() end
end)
noctalia.state.watch("activeTool", function(v) activeTool = v; if panelOpen then render() end end)
noctalia.state.watch("colorResult", function(v) colorResult = v; if panelOpen then render() end end)
noctalia.state.watch("colorHistory", function(v) colorHistory = v or {}; if panelOpen then render() end end)
noctalia.state.watch("ocrResult", function(v) ocrResult = v; if panelOpen then render() end end)
noctalia.state.watch("translateResult", function(v) translateResult = v; if panelOpen then render() end end)
noctalia.state.watch("qrResult", function(v) qrResult = v; if panelOpen then render() end end)
noctalia.state.watch("paletteColors", function(v) paletteColors = v or {}; if panelOpen then render() end end)
