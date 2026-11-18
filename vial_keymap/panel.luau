--!nonstrict
-- Keymap overlay panel. Port of KeymapView.swift / OverlayController.swift / KeymapModel.swift
-- from egno/vial_helper onto Noctalia's declarative ui.* tree.
--
-- Keys while open: Esc closes (host), 0-9 zooms into a layer, a or ` shows all layers,
-- Left/Right cycle. Clicking a layer card zooms into it; clicking outside closes.

local vil = require("./vil.luau")
local keycode = require("./keycode.luau")
local geometry = require("./geometry.luau")

local DEFAULT_PATH = "~/aurora.vil"
local PANEL_HEIGHT = 1000 -- keep in sync with [[panel]] height in plugin.toml
local COMPACT_UNIT = 38   -- key pitch (logical px) in the all-layers view
local LARGE_UNIT = 76     -- key pitch in the single-layer view
local CARD_COLUMNS = 2
local COMBOS_PER_ROW = 4

local state = {
  file = nil, geo = nil, err = nil,
  selected = nil,           -- 0-based layer, nil = all
  loadedPath = nil, loadedMtime = nil,
  isOpen = false,
}

-- MARK: settings -----------------------------------------------------------------------

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function splitKeepEmpty(s)
  local out = {}
  for part in (s .. ","):gmatch("([^,]*),") do table.insert(out, trim(part)) end
  return out
end

local function settings()
  local raw = trim(noctalia.getConfig("vil_path"))
  if raw == "" then raw = DEFAULT_PATH end
  return {
    path = noctalia.expandPath(raw),
    layerNames = splitKeepEmpty(noctalia.getConfig("layer_names") or ""),
    encoders = noctalia.getConfig("encoders") or "both",
    altLayoutEnabled = noctalia.getConfig("alt_layout_enabled") ~= false,
    altLayout = trim(noctalia.getConfig("alt_layout")),
  }
end

local function layerName(cfg, n)
  local nm = cfg.layerNames[n + 1]
  if nm ~= nil and nm ~= "" then return nm end
  return nil
end

local function labelContext(cfg)
  return {
    tapDances = state.file and state.file.tapDances or {}, layerNames = cfg.layerNames,
    altLegends = cfg.altLayoutEnabled and state.altLegends or nil,
    baseLegends = state.baseLegends or {},
  }
end

-- MARK: OS keyboard layouts -------------------------------------------------------------
-- Legends of the secondary OS layout (e.g. Russian) come from the layouts Hyprland has
-- configured, compiled through libxkbcommon by xkb_legends.py, so custom layouts in
-- ~/.config/xkb are honoured. Falls back to a built-in ЙЦУКЕН table.

state.altLegends = nil      -- keycode -> letter in the second layout
state.baseLegends = nil     -- keycode -> letter in the first layout
state.altLayoutName = nil
state.layoutsFetchedAt = 0
local layoutsBusy = false

local function splitList(str)
  local out = {}
  for part in (str .. ","):gmatch("([^,]*),") do table.insert(out, trim(part)) end
  return out
end

local function applyLegends(res, layouts, altName)
  local data = res.exitCode == 0 and noctalia.json.decode(res.stdout) or nil
  if data == nil or data.legends == nil then
    noctalia.log("xkb_legends.py failed (" .. tostring(res.stderr) .. "); using built-in Russian table")
    state.altLegends, state.baseLegends, state.altLayoutName = keycode.russianFallback, {}, "ru (fallback)"
  else
    state.baseLegends = data.legends[layouts[1]] or {}
    state.altLegends = data.legends[altName]
    state.altLayoutName = altName
    if state.altLegends == nil then
      noctalia.log("layout '" .. tostring(altName) .. "' did not compile; using built-in Russian table")
      state.altLegends, state.altLayoutName = keycode.russianFallback, "ru (fallback)"
    end
  end
  if state.isOpen then render() end
end

-- Runs the helper for the given layouts; altName selects which layout supplies the legends.
local function compileLegends(layouts, variants, altName)
  local script = (noctalia.pluginDir() or ".") .. "/xkb_legends.py"
  local ok = noctalia.runAsync({ "python3", script, table.concat(layouts, ","), table.concat(variants, ",") },
    function(res) layoutsBusy = false; applyLegends(res, layouts, altName) end)
  if not ok then layoutsBusy = false end
end

local function refreshLayouts(force)
  local cfg = settings()
  if not cfg.altLayoutEnabled or layoutsBusy then return end
  if not force and state.altLegends ~= nil and noctalia.nowMs() - state.layoutsFetchedAt < 60000 then return end
  layoutsBusy = true
  state.layoutsFetchedAt = noctalia.nowMs()

  -- Explicit "layout" or "layout(variant)" from settings: compile it next to plain "us".
  if cfg.altLayout ~= "" then
    local name, variant = cfg.altLayout:match("^([%w_%-]+)%((.-)%)$")
    name = name or cfg.altLayout
    compileLegends({ "us", name }, { "", variant or "" }, name)
    return
  end

  -- Otherwise ask Hyprland which layouts are configured and take the second one.
  noctalia.runAsync({ "hyprctl", "-j", "getoption", "input:kb_layout" }, function(res)
    local opt = res.exitCode == 0 and noctalia.json.decode(res.stdout) or nil
    local layouts = splitList(opt and opt.str or "us")
    if #layouts < 2 then
      layoutsBusy = false
      state.altLegends, state.baseLegends, state.altLayoutName = nil, {}, nil
      if state.isOpen then render() end
      return
    end
    noctalia.runAsync({ "hyprctl", "-j", "getoption", "input:kb_variant" }, function(vres)
      local vopt = vres.exitCode == 0 and noctalia.json.decode(vres.stdout) or nil
      local vstr = vopt and vopt.str or ""
      if vstr == "[[EMPTY]]" then vstr = "" end
      compileLegends(layouts, splitList(vstr), layouts[2])
    end)
  end)
end

-- MARK: model --------------------------------------------------------------------------

local function visibleLayers()
  if state.file == nil then return {} end
  return vil.nonEmptyLayers(state.file)
end

local function contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

-- Re-reads the .vil when the path or its mtime changed. Returns true when state changed.
local function reload(force)
  local cfg = settings()
  local info = noctalia.fileInfo(cfg.path)
  local mtime = info and info.mtime or nil
  if not force and cfg.path == state.loadedPath and mtime == state.loadedMtime and state.file ~= nil then
    return false
  end
  state.loadedPath, state.loadedMtime = cfg.path, mtime
  local f, err = vil.load(cfg.path)
  if f then
    state.file, state.err = f, nil
    state.geo = geometry.make(f, vil)
    if state.selected ~= nil and not contains(visibleLayers(), state.selected) then state.selected = nil end
  else
    state.file, state.geo, state.err = nil, nil, err
  end
  return true
end

local function select(n)
  if n == nil then state.selected = nil; return end
  if contains(visibleLayers(), n) then state.selected = n end
end

local function cycle(delta)
  local visible = visibleLayers()
  if #visible == 0 then return end
  -- Positions: 0 = all, 1..n = visible layers.
  local positions = #visible + 1
  local current = 0
  for i, l in ipairs(visible) do if l == state.selected then current = i end end
  local nextPos = (current + delta + positions) % positions
  state.selected = nextPos == 0 and nil or visible[nextPos]
end

-- MARK: rendering ----------------------------------------------------------------------

local STYLE = {
  normal      = { fill = "on_surface/0.08",  border = "on_surface/0.10", text = "on_surface" },
  transparent = { fill = "#00000000",        border = "on_surface/0.25", text = "on_surface/0.35" },
  none        = { fill = "on_surface/0.025", border = "on_surface/0.06", text = "on_surface" },
  layer       = { fill = "primary/0.18",     border = "on_surface/0.10", text = "on_surface" },
  modifier    = { fill = "tertiary/0.18",    border = "on_surface/0.10", text = "on_surface" },
  special     = { fill = "secondary/0.18",   border = "on_surface/0.10", text = "on_surface" },
}
local KIND_COLOR = { mod = "tertiary", layer = "primary", info = "secondary" }
local LAYER_COLOR = "primary"

-- Rough text width in em, so long legends shrink to fit the cap instead of being ellipsised.
local function estimateWidth(text)
  local em = 0
  local plain = (text:gsub("{[%w%-]+}", function() em = em + 1.35; return "" end))
  for _, cp in utf8.codes(plain) do
    if cp > 127 then em = em + 1.35      -- symbols mostly come from a wider fallback font
    elseif cp >= 65 and cp <= 90 then em = em + 0.8
    elseif cp >= 48 and cp <= 57 then em = em + 0.68
    elseif cp == 32 then em = em + 0.3
    else em = em + 0.66 end
  end
  return math.max(em, 0.5)
end

local function blank(w, h)
  return ui.box({ width = math.max(1, w), height = math.max(1, h), fill = "#00000000" })
end

-- Renders legend text; "{glyph-name}" tokens become Tabler icons inline with the text.
local function legendNode(text, fontSize, color, fontWeight, maxWidth)
  if not text:find("{", 1, true) then
    return ui.label({ text = text, fontSize = fontSize, fontWeight = fontWeight or "semibold", color = color,
      maxLines = 1, maxWidth = maxWidth, textAlign = "center" })
  end
  local parts = {}
  local pos = 1
  while pos <= #text do
    local a, b, name = text:find("{([%w%-]+)}", pos)
    if a == nil then
      table.insert(parts, ui.label({ text = text:sub(pos), fontSize = fontSize, fontWeight = fontWeight or "semibold", color = color, maxLines = 1 }))
      break
    end
    if a > pos then
      table.insert(parts, ui.label({ text = text:sub(pos, a - 1), fontSize = fontSize, fontWeight = fontWeight or "semibold", color = color, maxLines = 1 }))
    end
    table.insert(parts, ui.glyph({ name = name, size = fontSize * 1.35, color = color }))
    pos = b + 1
  end
  return ui.row({ gap = fontSize * 0.08, align = "center", justify = "center" }, parts)
end

local function keycap(label, unit, key, tertiary)
  local gap = unit * 0.1
  local w, h = unit - gap, unit - gap
  local st = STYLE[label.style] or STYLE.normal
  -- Fixed vertical slots on every key: strip / primary / strip. The bottom strip holds the
  -- secondary legend when there is one, so primaries line up across the whole board.
  local strip = h * 0.21            -- bottom band: hold / layer legend
  local topStrip = h * 0.25         -- top band: second-layout letter, top-right corner
  local mainH = h - strip - topStrip
  local children = {}
  if label.style ~= "none" then
    local size = math.max(unit * 0.16, math.min(unit * 0.38, (w - 4) / estimateWidth(label.primary)))
    local top = {}
    if tertiary then
      table.insert(top, ui.label({ text = tertiary, fontSize = unit * 0.23, fontWeight = "semibold",
        color = "on_surface/0.7", maxLines = 1 }))
    end
    table.insert(children, ui.row({ height = topStrip, width = w - 2, align = "center", justify = "end", paddingH = unit * 0.1 }, top))
    -- Fixed-height wrappers clip the (tall) text line boxes, so every legend lands at the same offset.
    table.insert(children, ui.row({ height = mainH, width = w - 2, align = "center", justify = "center" }, {
      legendNode(label.primary, size, st.text, "semibold", w + 2),
    }))
    local bottom = {}
    if label.secondary ~= nil and label.secondary ~= "" then
      table.insert(bottom, legendNode(label.secondary, unit * 0.16, KIND_COLOR[label.secondaryKind] or "secondary", "semibold", w - 2))
    end
    table.insert(children, ui.row({ height = strip, width = w - 2, align = "center", justify = "center" }, bottom))
  end
  return ui.column({
    key = key, width = w, height = h,
    fill = st.fill, radius = unit * 0.16, border = st.border, borderWidth = 1,
    align = "center", justify = "center", gap = 0,
  }, children)
end

local function keyAt(layer, spec, unit, ctx, prefix)
  if not spec then return blank(unit - unit * 0.1, unit - unit * 0.1) end
  local code = vil.code(state.file, layer, spec[1], spec[2])
  if code == "-1" then return blank(unit - unit * 0.1, unit - unit * 0.1) end
  local label = keycode.label(code, ctx)
  local tertiary = nil
  if ctx.altLegends and label.style ~= "none" and label.style ~= "transparent" then
    tertiary = keycode.altLegend(code, ctx.altLegends)
    -- Only worth drawing when the second layout differs from the first on this key.
    local base = keycode.altLegend(code, ctx.baseLegends)
    if tertiary ~= nil and base ~= nil and tertiary:upper() == base:upper() then tertiary = nil end
  end
  return keycap(label, unit, prefix .. spec[1] .. "_" .. spec[2], tertiary)
end

local function encoderLegend(enc, unit, ctx)
  local size = math.max(9, unit * 0.24)
  return ui.row({
    gap = unit * 0.12, paddingH = unit * 0.2, paddingV = unit * 0.08,
    fill = "on_surface/0.05", radius = 99, align = "center",
  }, {
    legendNode("↺ " .. keycode.short(enc[1], ctx), size, "on_surface/0.7", "medium"),
    ui.label({ text = "·", fontSize = size, color = "on_surface/0.4" }),
    legendNode(keycode.short(enc[2], ctx) .. " ↻", size, "on_surface/0.7", "medium"),
  })
end

local function encoderShown(mode, index)
  if mode == "both" then return true end
  if mode == "left" then return index == 1 end
  if mode == "right" then return index == 2 end
  return false
end

local function halfNode(layer, half, halfIndex, unit, cfg, ctx)
  local gap = unit * 0.1
  local prefix = "k" .. layer .. "_"
  local nThumbs = half.thumbs and #half.thumbs or 0
  -- Thumb keys may stick out past the inner edge of the main block; the half is as wide as both.
  local blockCols = #half.cols
  local thumbEnd = half.thumbs and ((half.thumbOffset or 0) + nThumbs) or 0
  local overhang = math.max(0, thumbEnd - blockCols)

  -- Key columns: top offset (stagger) then keys at an exact 1u pitch.
  local colNodes = {}
  if half.side == "right" and overhang > 0 then table.insert(colNodes, blank(overhang * unit - gap, 1)) end
  for ci, col in ipairs(half.cols) do
    local children = {}
    if col.stagger and col.stagger > 0 then table.insert(children, blank(1, col.stagger * unit)) end
    for ki, spec in ipairs(col.keys) do
      if ki > 1 then table.insert(children, blank(1, gap)) end
      table.insert(children, keyAt(layer, spec, unit, ctx, prefix))
    end
    table.insert(colNodes, ui.column({ key = prefix .. "c" .. halfIndex .. "_" .. ci, gap = 0, align = "start" }, children))
  end
  local parts = { ui.row({ gap = gap, align = "start" }, colNodes) }

  if half.thumbs then
    table.insert(parts, blank(1, (half.thumbDrop or 0.4) * unit - gap))
    local thumbs = {}
    -- Distance from this half's left edge to the first thumb key, in key units.
    local lead
    if half.side == "right" then
      lead = math.max(blockCols, thumbEnd) - thumbEnd
    else
      lead = half.thumbOffset or 0
    end
    if lead * unit - gap > 0 then table.insert(thumbs, blank(lead * unit - gap, 1)) end
    for _, spec in ipairs(half.thumbs) do table.insert(thumbs, keyAt(layer, spec, unit, ctx, prefix)) end
    table.insert(parts, ui.row({ gap = gap, align = "start" }, thumbs))
  end

  local encs = state.file.encoders[layer + 1]
  local enc = encs and encs[halfIndex] or nil
  if enc and #enc >= 2 and encoderShown(cfg.encoders, halfIndex) then
    table.insert(parts, blank(1, unit * 0.1))
    table.insert(parts, ui.row({ justify = half.side == "right" and "end" or "start", align = "center" }, { encoderLegend(enc, unit, ctx) }))
  end

  return ui.column({ gap = gap, align = "stretch" }, parts)
end

local function keyboardNode(layer, unit, cfg, ctx)
  local halves = {}
  for i, half in ipairs(state.geo.halves) do table.insert(halves, halfNode(layer, half, i, unit, cfg, ctx)) end
  return ui.row({ gap = (state.geo.halfGap or 1) * unit, align = "start" }, halves)
end

local function layerCard(layer, unit, compact, cfg, ctx)
  local title = { ui.label({ text = "L" .. layer, fontSize = math.max(11, unit * 0.32), fontWeight = "bold", color = LAYER_COLOR }) }
  local name = layerName(cfg, layer)
  if name then
    table.insert(title, ui.label({ text = name, fontSize = math.max(11, unit * 0.3), fontWeight = "semibold", color = LAYER_COLOR }))
  end
  local props = { key = "layer" .. layer, gap = 4, align = "start" }
  if compact then
    props.padding = 10
    props.fill = "on_surface/0.04"
    props.radius = 14
    props.onClick = function() select(layer); render() end
  end
  return ui.column(props, {
    ui.row({ gap = 6, align = "center" }, title),
    keyboardNode(layer, unit, cfg, ctx),
  })
end

local function chip(text, selected, onClick, key)
  return ui.button({
    key = key, text = text, controlSize = "sm",
    variant = selected and "primary" or "ghost",
    onClick = onClick,
  })
end

local function header(cfg)
  local items = {
    ui.label({ text = state.file and state.file.fileName or noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
    ui.spacer({ flexGrow = 1 }),
  }
  local visible = visibleLayers()
  if #visible > 0 then
    table.insert(items, chip(noctalia.tr("panel.all"), state.selected == nil, function() select(nil); render() end, "chip_all"))
    for _, i in ipairs(visible) do
      local name = layerName(cfg, i)
      local title = name and (i .. " " .. name) or tostring(i)
      table.insert(items, chip(title, state.selected == i, function() select(i); render() end, "chip" .. i))
    end
  end
  table.insert(items, ui.button({ key = "settings", glyph = "settings", variant = "ghost", controlSize = "sm",
    tooltip = "Settings", onClick = function() noctalia.openSettings() end }))
  table.insert(items, ui.button({ key = "close", glyph = "x", variant = "ghost", controlSize = "sm",
    tooltip = "Close", onClick = function() panel.close() end }))
  return ui.row({ gap = 6, align = "center" }, items)
end

local function content(cfg, ctx)
  local visible = visibleLayers()
  if state.selected ~= nil and state.selected < #state.file.layers then
    return ui.row({ justify = "center", align = "start" }, { layerCard(state.selected, LARGE_UNIT, false, cfg, ctx) })
  end
  local rows = {}
  local i = 1
  while i <= #visible do
    local cards = {}
    for j = i, math.min(i + CARD_COLUMNS - 1, #visible) do
      table.insert(cards, layerCard(visible[j], COMPACT_UNIT, true, cfg, ctx))
    end
    table.insert(rows, ui.row({ gap = 24, align = "start" }, cards))
    i = i + CARD_COLUMNS
  end
  return ui.row({ justify = "center", align = "start" }, { ui.column({ gap = 14, align = "start" }, rows) })
end

local function combos(ctx)
  local list = state.file.combos
  if #list == 0 then return nil end
  local rows = {}
  local i = 1
  while i <= #list do
    local chips = {}
    for j = i, math.min(i + COMBOS_PER_ROW - 1, #list) do
      local c = list[j]
      local keys = {}
      for _, k in ipairs(c.keys) do table.insert(keys, keycode.short(k, ctx)) end
      table.insert(chips, ui.row({ key = "combo" .. j, gap = 4, paddingH = 8, paddingV = 3, fill = "on_surface/0.06", radius = 99, align = "center" }, {
        legendNode(table.concat(keys, " + "), 11, "on_surface", "medium"),
        ui.label({ text = "→", fontSize = 10, color = "on_surface/0.6" }),
        legendNode(keycode.short(c.result, ctx), 11, "primary", "semibold"),
      }))
    end
    table.insert(rows, ui.row({ gap = 6, align = "center" }, chips))
    i = i + COMBOS_PER_ROW
  end
  return ui.column({ gap = 6, align = "start" }, {
    ui.label({ text = noctalia.tr("panel.combos"), fontSize = 11, fontWeight = "semibold", color = "on_surface/0.6" }),
    ui.column({ gap = 6, align = "start" }, rows),
  })
end

local function hint(key, what)
  return ui.row({ gap = 3, align = "center" }, {
    ui.row({ paddingH = 4, paddingV = 1, fill = "on_surface/0.08", radius = 3 }, {
      ui.label({ text = key, fontSize = 10.5, fontWeight = "semibold" }),
    }),
    ui.label({ text = what, fontSize = 10.5, color = "on_surface/0.6" }),
  })
end

local function hints()
  return ui.row({ gap = 14, align = "center" }, {
    hint("esc", noctalia.tr("panel.hint.close")),
    hint("0–9", noctalia.tr("panel.hint.layer")),
    hint("a", noctalia.tr("panel.hint.all")),
    hint("←→", noctalia.tr("panel.hint.switch")),
  })
end

local function errorView(cfg)
  return ui.column({ gap = 6, align = "start", paddingV = 12 }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 18, color = "error" }),
      ui.label({ text = noctalia.tr("panel.error.title"), fontSize = 14, fontWeight = "bold" }),
    }),
    ui.label({ text = tostring(state.err or "Unknown error"), fontSize = 12, color = "on_surface/0.7" }),
    ui.label({ text = "Path: " .. cfg.path, fontSize = 11, color = "on_surface/0.6" }),
    ui.label({ text = noctalia.tr("panel.error.hint"), fontSize = 11 }),
  })
end

function render()
  local cfg = settings()
  local body = {}
  if state.file and state.geo then
    local ctx = labelContext(cfg)
    table.insert(body, content(cfg, ctx))
    local c = combos(ctx)
    if c then table.insert(body, c) end
  else
    table.insert(body, errorView(cfg))
  end
  panel.render(ui.column({ gap = 12, padding = 18, align = "stretch", height = PANEL_HEIGHT }, {
    header(cfg),
    ui.scroll({ flexGrow = 1, gap = 16, align = "stretch" }, body),
    hints(),
  }))
end

-- MARK: lifecycle ----------------------------------------------------------------------

noctalia.setUpdateInterval(2000)

refreshLayouts(true)

function onOpen(context)
  state.isOpen = true
  reload(false)
  refreshLayouts(false)
  local n = tonumber(context)
  if n ~= nil then select(n) end
  render()
end

function onClose()
  state.isOpen = false
end

-- Picks up edits to the .vil while the overlay is open (Vial re-exports, manual edits).
function update()
  if state.isOpen and reload(false) then render() end
end

function onKey(chord, pressed)
  if not pressed then return end
  if chord == "left" then
    cycle(-1)
  elseif chord == "right" then
    cycle(1)
  elseif chord == "a" or chord == "grave" then
    select(nil)
  else
    local n = tonumber(chord)
    if n == nil then return end
    select(n)
  end
  render()
end

-- noctalia msg plugin egno/vial_keymap:keymap all reload | layer <n> | all
function onIpc(event, payload)
  if event == "reload" then
    reload(true)
  elseif event == "layer" then
    select(tonumber(payload))
  elseif event == "all" then
    select(nil)
  elseif event == "layouts" then
    refreshLayouts(true)
  end
  if state.isOpen then render() end
end
