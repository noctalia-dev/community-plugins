--!nonstrict
-- CPU monitor detail view: Mission Center style with full-width graph and stats panel.
--
-- Shared monitor interface consumed by panel.luau:
--   attach(fn)    one-time setup; fn is the panel re-render callback
--   getPreview()  sparkline data for the sidebar card (nil before first sample)
--   getValue()    headline usage text, e.g. "42%"
--   getSubtitle() secondary line (current temperature)
--   tick()        sample once per update interval
--   build()       element tree for this tab's detail view

-- Rolling sample buffers: one point per tick, capped at 60 (~1 minute at 1s).
local MAX_SAMPLES = 60

local history = {}
local tempHistory = {}
local coreHistories = {}
local usage = 0
local temp = nil
local freq = nil
local maxFreq = nil
local load = nil
local cores = nil
local showCores = false
local refresh = nil
local minUsage = 100
local maxUsage = 0
local cpuName = "CPU"

local M = {}

-- One-time setup: store the refresh callback, switch to 1s updates and read
-- the CPU model name from /proc/cpuinfo (falls back to the "hardware" line,
-- e.g. on ARM devices).
function M.attach(fn)
  refresh = fn
  noctalia.setUpdateInterval(1000)
  local raw = noctalia.readFile("/proc/cpuinfo")
  if raw ~= nil then
    local _, _, name = raw:find("model name%s*:%s*([^\n]*)")
    if name ~= nil and name ~= "" then
      cpuName = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    else
      _, _, name = raw:find("hardware%s*:%s*([^\n]*)")
      if name ~= nil and name ~= "" then cpuName = name end
    end
  end
end

-- Sidebar sparkline source: normalized utilization history.
function M.getPreview()
  if #history == 0 then
    return nil
  end
  return { values = { table.unpack(history) }, color = "primary" }
end

-- Usage percent for the sidebar value line; em dash before the first sample.
function M.getValue()
  if usage == 0 then
    return "—"
  end
  return string.format("%d%%", usage)
end

-- Temperature as NN°C; empty until a sensor reading exists.
function M.getSubtitle()
  if temp == nil then
    return ""
  end
  return string.format("%d°C", temp)
end

-- Per-tick sampling: refresh stats, push new points onto the usage and
-- temperature buffers, track session min/max, and record per-core history
-- only while showCores is enabled (keeps idle cost low).
function M.tick()
  local s = noctalia.systemStats()
  if s == nil then
    return
  end

  usage = s.cpu.usagePercent or 0
  temp = s.cpu.tempC
  freq = s.cpu.freqMhz
  maxFreq = s.cpu.maxFreqMhz
  load = s.loadAvg

  table.insert(history, usage / 100)
  if #history > MAX_SAMPLES then
    table.remove(history, 1)
  end

  table.insert(tempHistory, (temp or 0) / 100)
  if #tempHistory > MAX_SAMPLES then
    table.remove(tempHistory, 1)
  end

  if usage < minUsage then minUsage = usage end
  if usage > maxUsage then maxUsage = usage end

  if showCores then
    cores = noctalia.cpuCores()
    if cores ~= nil then
      for i = 1, #cores do
        if coreHistories[i] == nil then
          coreHistories[i] = {}
        end
        table.insert(coreHistories[i], (cores[i] or 0) / 100)
        if #coreHistories[i] > MAX_SAMPLES then
          table.remove(coreHistories[i], 1)
        end
      end
    end
  end
end

local function formatGhz(mhz)
  if mhz == nil then
    return "—"
  end
  return string.format("%.1f GHz", mhz / 1000)
end

local function buildYLabels()
  return ui.column({ width = 0 })
end

local function buildGraph()
  return ui.column({ flexGrow = 1, gap = 4 }, {
    ui.column({ flexGrow = 1, gap = 4 }, {
      ui.graph({
        values = { table.unpack(history) },
        color = "primary",
        values2 = { table.unpack(tempHistory) },
        color2 = "error",
        lineWidth = 2,
        flexGrow = 1,
      }),
      ui.row({ justify = "space_between" }, {
        ui.label({ text = "Utilization over 1 minute", fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = "100%", fontSize = 10, color = "on_surface_variant" }),
      }),
    }),
  })
end

local function buildStatsPanel()
  local stats = {
    { label = "Utilization", value = string.format("%d%%", usage), highlight = true },
    { label = "Temperature", value = temp ~= nil and string.format("%d°C", temp) or "—" },
    { label = "Frequency", value = formatGhz(freq) },
    { label = "Max Frequency", value = formatGhz(maxFreq) },
  }
  if load ~= nil and #load >= 3 then
    table.insert(stats, { label = "Load (1m)", value = string.format("%.2f", load[1]) })
    table.insert(stats, { label = "Load (5m)", value = string.format("%.2f", load[2]) })
    table.insert(stats, { label = "Load (15m)", value = string.format("%.2f", load[3]) })
  end
  table.insert(stats, { label = "Min Usage", value = string.format("%d%%", minUsage) })
  table.insert(stats, { label = "Max Usage", value = string.format("%d%%", maxUsage) })

  local rows = {}
  for _, s in ipairs(stats) do
    local valColor = s.highlight and "primary" or nil
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
    ui.row({ padding = { left = 12, right = 12, top = 12, bottom = 4 }, align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = cpuName, fontSize = 18, fontWeight = "bold" }),
        ui.label({ text = "Utilization over 1 minute", fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({ text = string.format("%d%%", usage), fontSize = 18, fontWeight = "bold", color = "primary" }),
    }),
    ui.row({ flexGrow = 1, gap = 12, padding = { left = 12, right = 12, bottom = 12 }, align = "stretch" }, {
      ui.column({ flexGrow = 1, gap = 8 }, {
        ui.column({ fill = "surface_variant/0.4", radius = 10, border = "outline/0.2", borderWidth = 1, padding = 12, flexGrow = 1 }, {
          buildGraph(),
        }),
      }),
      buildStatsPanel(),
    }),
  })
end

return M
