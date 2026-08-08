--!nonstrict
-- KVitals sparkline panel: live graphs and a metrics summary, opened near
-- the bar widget. The host diffs the tree, so re-rendering on every sample
-- is free.

local format = require("./lib/format.luau")
local chips = require("./lib/chips.luau")

local sample = noctalia.state.get("kvitals.sample")
local history = noctalia.state.get("kvitals.history")
local config = noctalia.state.get("kvitals.config")
local ready = noctalia.state.get("kvitals.ready") == true

local graph_height = noctalia.getConfig("graph_height") or 64
local show_graphs = noctalia.getConfig("show_graphs")
if show_graphs == nil then show_graphs = true end

-- ── helpers ──────────────────────────────────────────────────────────────

local function section(title, glyphName, control)
  return ui.column({ gap = 8 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = glyphName, size = 14, color = "on_surface_variant" }),
      ui.label({ text = title, fontSize = 12, fontWeight = "medium", color = "on_surface_variant" }),
    }),
    control,
  })
end

-- Normalize a byte-rate series to 0-1 against the window maximum.
local function normalizeRates(values)
  local maxValue = 1
  for _, v in ipairs(values) do
    if v > maxValue then maxValue = v end
  end
  local out = {}
  for _, v in ipairs(values) do
    table.insert(out, v / maxValue)
  end
  return out
end

local function graphRow(title, glyphName, values, values2, color, color2, currentText)
  if values == nil or #values < 2 then return nil end
  return ui.column({ gap = 4 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = glyphName, size = 14, color = "on_surface_variant" }),
      ui.label({ text = title, fontSize = 12, fontWeight = "medium", color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = currentText, fontSize = 12, color = "on_surface" }),
    }),
    ui.graph({
      values = values,
      values2 = values2,
      color = color,
      color2 = color2,
      lineWidth = 2,
      fillOpacity = 0.18,
      height = graph_height,
    }),
  })
end

local function detailRow(key, value)
  if value == nil or value == "" then return nil end
  return ui.row({ gap = 8, align = "center" }, {
    ui.label({ text = key, fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
    ui.label({ text = value, fontSize = 12, fontWeight = "medium", color = "on_surface" }),
  })
end

-- ── render ──────────────────────────────────────────────────────────────

local function render()
  local body = {}

  -- Header.
  table.insert(body, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
      ui.glyph({ name = "activity", size = 18, color = config and config.accent or "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    }),
    ui.button({ glyph = "settings", variant = "ghost", tooltip = noctalia.tr("panel.open_settings"), onClick = "onOpenSettings" }),
    ui.button({ glyph = "circle-x", variant = "ghost", onClick = "onCloseClicked" }),
  }))

  local rows = {}

  -- Graphs.
  if ready and sample and history and show_graphs then
    local accent = config.accent or "primary"
    local current = {}
    for _, chip in ipairs(chips.chips(sample, config)) do
      current[chip.id] = chip.text
    end
    local g = {}
    table.insert(g, graphRow("CPU", "cpu", history.cpu, nil, accent, nil, current.cpu))
    table.insert(g, graphRow("RAM", "database", history.ram, nil, accent, nil, current.ram))
    table.insert(g, graphRow("GPU", "device-desktop-analytics", history.gpu, nil, accent, nil, current.gpu))
    if history.vram and #history.vram >= 2 then
      table.insert(g, graphRow("VRAM", "memory", history.vram, nil, accent, nil, current.vram))
    end
    if history.netRx and #history.netRx >= 2 then
      table.insert(g, graphRow(
        "NET", "network",
        normalizeRates(history.netRx), normalizeRates(history.netTx),
        accent, "secondary",
        current.net))
    end
    local graphs = {}
    for _, node in ipairs(g) do
      if node then table.insert(graphs, node) end
    end
    if #graphs > 0 then
      table.insert(rows, ui.column({ gap = 14 }, graphs))
    end
  end

  -- Details grid, two columns.
  if ready and sample then
    local details = chips.tooltipRows(sample, config)
    local left, right = {}, {}
    for index, row in ipairs(details) do
      local node = detailRow(row.key, row.value)
      if node then
        if index % 2 == 1 then
          table.insert(left, node)
        else
          table.insert(right, node)
        end
      end
    end
    if #left > 0 or #right > 0 then
      table.insert(rows, ui.row({ gap = 24, align = "start" }, {
        ui.column({ gap = 8, flexGrow = 1 }, left),
        ui.column({ gap = 8, flexGrow = 1 }, right),
      }))
    end
  end

  table.insert(body, ui.scroll({ flexGrow = 1, gap = 20 }, rows))

  -- Footer.
  table.insert(body, ui.label({
    text = noctalia.tr("about.based_on"),
    fontSize = 11,
    color = "on_surface_variant",
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 16 }, body))
end

-- ── entry points ─────────────────────────────────────────────────────────

function onOpen(_context)
  graph_height = noctalia.getConfig("graph_height") or 64
  local g = noctalia.getConfig("show_graphs")
  if g ~= nil then show_graphs = g end
  render()
end

function onCloseClicked()
  panel.close()
end

function onOpenSettings()
  noctalia.openSettings()
end

noctalia.state.watch("kvitals.sample", function(value)
  sample = value
  render()
end)

noctalia.state.watch("kvitals.history", function(value)
  history = value
  render()
end)

noctalia.state.watch("kvitals.config", function(value)
  config = value
  render()
end)

noctalia.state.watch("kvitals.ready", function(value)
  ready = value == true
  render()
end)
