--!nonstrict
-- RAM monitor detail view: Mission Center style with full-width graph and stats panel.
--
-- Shared monitor interface consumed by panel.luau:
--   attach(fn)    one-time setup; fn is the panel re-render callback
--   getPreview()  sparkline data for the sidebar card
--   getValue()    headline usage text, e.g. "37.4%"
--   getSubtitle() "used / total GiB"
--   tick()        sample once per update interval
--   build()       element tree for this tab's detail view

-- Rolling usage buffer: one point per tick, capped at 60 (~1 minute at 1s).
local MAX_SAMPLES = 60

local history = {}
local usagePercent = 0
local usedMb = 0
local totalMb = 0
local refresh = nil

local M = {}

-- One-time setup: store the panel re-render callback.
function M.attach(fn)
  refresh = fn
end

-- Sparkline source: normalized memory-usage history.
function M.getPreview()
  if #history == 0 then
    return nil
  end
  return { values = { table.unpack(history) }, color = "tertiary" }
end

-- Usage percent with one decimal; em dash before the first sample.
function M.getValue()
  if usagePercent == 0 then
    return "—"
  end
  return string.format("%.1f%%", usagePercent)
end

-- "X.X / Y.Y GiB" used vs total; empty before the first sample.
function M.getSubtitle()
  if totalMb == 0 then
    return ""
  end
  return string.format("%.1f / %.1f GiB", usedMb / 1024, totalMb / 1024)
end

-- Cache latest usage/used/total figures and append a point to the buffer.
function M.tick()
  local s = noctalia.systemStats()
  if s == nil then
    return
  end
  usagePercent = s.ram.usagePercent or 0
  usedMb = s.ram.usedMb or 0
  totalMb = s.ram.totalMb or 0
  table.insert(history, usagePercent / 100)
  if #history > MAX_SAMPLES then
    table.remove(history, 1)
  end
end

local function formatMb(mb)
  if mb >= 1024 then
    return string.format("%.1f GiB", mb / 1024)
  end
  return string.format("%.0f MiB", mb)
end

local function buildYLabels()
  return ui.column({ width = 0 })
end

local function buildGraph()
  return ui.column({ flexGrow = 1, gap = 4 }, {
    ui.column({ flexGrow = 1, gap = 4 }, {
      ui.graph({
        values = { table.unpack(history) },
        color = "tertiary",
        lineWidth = 2,
        flexGrow = 1,
      }),
      ui.row({ justify = "space_between" }, {
        ui.label({ text = "Memory usage over 1 minute", fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = formatMb(totalMb), fontSize = 10, color = "on_surface_variant" }),
      }),
    }),
  })
end

local function buildStatsPanel()
  local freeMb = totalMb - usedMb
  local stats = {
    { label = "In use", value = formatMb(usedMb), highlight = true },
    { label = "Available", value = formatMb(freeMb) },
    { label = "Total", value = formatMb(totalMb) },
    { label = "Usage", value = string.format("%.1f%%", usagePercent) },
  }

  local rows = {}
  for _, s in ipairs(stats) do
    local valColor = s.highlight and "tertiary" or nil
    table.insert(rows, ui.row({ justify = "space_between" }, {
      ui.label({ text = s.label, fontSize = 12, color = "on_surface_variant" }),
      ui.label({ text = s.value, fontSize = 12, fontWeight = s.highlight and "bold" or nil, color = valColor }),
    }))
  end
  return ui.column({
    fill = "surface_variant/0.4",
    radius = 8,
    padding = 12,
    gap = 6,
    width = 180,
  }, {
    ui.label({ text = "Statistics", fontSize = 12, fontWeight = "bold" }),
    ui.column({ gap = 4 }, rows),
  })
end

function M.build()
  return ui.column({ flexGrow = 1, gap = 0 }, {
    ui.row({ padding = 12, align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "Memory", fontSize = 18, fontWeight = "bold" }),
        ui.label({ text = "Memory usage over 1 minute", fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({ text = formatMb(totalMb), fontSize = 18, fontWeight = "bold", color = "tertiary" }),
    }),
    ui.row({ flexGrow = 1, gap = 12, padding = { left = 12, right = 12, bottom = 12 }, align = "stretch" }, {
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.column({ fill = "surface_variant/0.4", radius = 10, border = "outline/0.2", borderWidth = 1, padding = 12, flexGrow = 1 }, {
          buildGraph(),
        }),
      }),
      buildStatsPanel(),
    }),
  })
end

return M
