--!nonstrict
-- Network monitor detail view: Mission Center style with full-width graph and stats panel.

local MAX_SAMPLES = 60

local rxHistory = {}
local txHistory = {}
local rxBytesPerSec = 0
local txBytesPerSec = 0
local maxThroughput = 1
local interfaces = {}
local refresh = nil

local M = {}

function M.attach(fn)
  refresh = fn
end

function M.getPreview()
  if #rxHistory == 0 then
    return nil
  end
  local combined = {}
  for i = 1, #rxHistory do
    combined[i] = math.max(rxHistory[i], txHistory[i]) / maxThroughput
  end
  return { values = { table.unpack(combined) }, color = "error" }
end

function M.getValue()
  if rxBytesPerSec == 0 and txBytesPerSec == 0 then
    return "—"
  end
  return string.format("↓%s ↑%s", formatSpeed(rxBytesPerSec), formatSpeed(txBytesPerSec))
end

function M.getSubtitle()
  if rxBytesPerSec == 0 and txBytesPerSec == 0 then
    return ""
  end
  return string.format("↓%s ↑%s", formatSpeed(rxBytesPerSec), formatSpeed(txBytesPerSec))
end

function M.tick()
  local s = noctalia.systemStats()
  if s == nil then
    return
  end
  rxBytesPerSec = s.net.rxBytesPerSec or 0
  txBytesPerSec = s.net.txBytesPerSec or 0
  interfaces = s.net.interfaces or {}
  table.insert(rxHistory, rxBytesPerSec)
  table.insert(txHistory, txBytesPerSec)
  if #rxHistory > MAX_SAMPLES then
    table.remove(rxHistory, 1)
    table.remove(txHistory, 1)
  end
  local currentMax = math.max(rxBytesPerSec, txBytesPerSec)
  if currentMax > maxThroughput then
    maxThroughput = currentMax
  end
  maxThroughput = maxThroughput * 0.9
  if maxThroughput < 1024 then
    maxThroughput = 1024
  end
end

function formatSpeed(bytesPerSec)
  if bytesPerSec >= 1073741824 then
    return string.format("%.2f GB/s", bytesPerSec / 1073741824)
  elseif bytesPerSec >= 1048576 then
    return string.format("%.1f MB/s", bytesPerSec / 1048576)
  elseif bytesPerSec >= 1024 then
    return string.format("%.1f KB/s", bytesPerSec / 1024)
  end
  return string.format("%.0f B/s", bytesPerSec)
end

local function formatBytes(bytes)
  if bytes >= 1073741824 then
    return string.format("%.1f GB", bytes / 1073741824)
  elseif bytes >= 1048576 then
    return string.format("%.1f MB", bytes / 1048576)
  elseif bytes >= 1024 then
    return string.format("%.1f KB", bytes / 1024)
  end
  return string.format("%.0f B", bytes)
end

local function buildYLabels()
  return ui.column({ width = 0 })
end

local function buildGraph()
  local normalizedRx = {}
  local normalizedTx = {}
  for i = 1, #rxHistory do
    normalizedRx[i] = rxHistory[i] / maxThroughput
    normalizedTx[i] = txHistory[i] / maxThroughput
  end
  return ui.column({ flexGrow = 1, gap = 4 }, {
    ui.column({ flexGrow = 1, gap = 4 }, {
      ui.graph({
        values = normalizedRx,
        color = "error",
        values2 = normalizedTx,
        color2 = "tertiary",
        lineWidth = 2,
        flexGrow = 1,
      }),
      ui.row({ justify = "space_between" }, {
        ui.label({ text = "Throughput over 1 minute", fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = "—", fontSize = 10, color = "on_surface_variant" }),
      }),
    }),
  })
end

local function buildStatsPanel()
  local totalRx = 0
  local totalTx = 0
  for _, v in ipairs(rxHistory) do totalRx = totalRx + v end
  for _, v in ipairs(txHistory) do totalTx = totalTx + v end

  local stats = {
    { label = "↓ Download", value = formatSpeed(rxBytesPerSec), highlight = true, color = "error" },
    { label = "↑ Upload", value = formatSpeed(txBytesPerSec), highlight = true, color = "tertiary" },
    { label = "Total Received", value = formatBytes(totalRx) },
    { label = "Total Sent", value = formatBytes(totalTx) },
  }

  local rows = {}
  for _, s in ipairs(stats) do
    local valColor = s.color or (s.highlight and "error" or nil)
    table.insert(rows, ui.row({ justify = "space_between" }, {
      ui.label({ text = s.label, fontSize = 12, color = "on_surface_variant" }),
      ui.label({ text = s.value, fontSize = 12, fontWeight = s.highlight and "bold" or nil, color = valColor }),
    }))
  end

  if next(interfaces) ~= nil then
    table.insert(rows, ui.label({ text = "Interfaces", fontSize = 11, fontWeight = "bold" }))
    for name, data in pairs(interfaces) do
      table.insert(rows, ui.row({ justify = "space_between" }, {
        ui.label({ text = name, fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = string.format("↓%s ↑%s", formatSpeed(data.rx or 0), formatSpeed(data.tx or 0)), fontSize = 10 }),
      }))
    end
  end

  return ui.column({
    fill = "surface_variant/0.4",
    radius = 8,
    padding = 12,
    gap = 6,
    width = 200,
  }, {
    ui.label({ text = "Statistics", fontSize = 12, fontWeight = "bold" }),
    ui.column({ gap = 4 }, rows),
  })
end

function M.build()
  return ui.column({ flexGrow = 1, gap = 0 }, {
    ui.row({ padding = 12, align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = "Network", fontSize = 18, fontWeight = "bold" }),
        ui.label({ text = "Throughput over 1 minute", fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({ text = formatSpeed(maxThroughput), fontSize = 14, color = "on_surface_variant" }),
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
