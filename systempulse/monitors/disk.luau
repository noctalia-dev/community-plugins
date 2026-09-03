--!nonstrict
-- Disk monitor detail view: Mission Center style with read/write graphs and stats.

local MAX_SAMPLES = 60

local refresh = nil
local mounts = {}
local diskData = {}

local readHistory = {}
local writeHistory = {}
local readSpeed = 0
local writeSpeed = 0
local totalReadBytes = 0
local totalWriteBytes = 0
local lastReadSectors = 0
local lastWriteSectors = 0
local lastTickTime = 0

local M = {}

function M.attach(fn)
  refresh = fn
end

function M.getPreview()
  if #readHistory == 0 then
    return nil
  end
  -- use normalized max(read,write) so preview reflects dominant activity,
  -- not muddy average; matches Mission Center graph-widget connect_datasets
  local maxVal = 1
  for i = 1, #readHistory do
    local v = math.max(readHistory[i], writeHistory[i])
    if v > maxVal then maxVal = v end
  end
  -- Pow2 rounding for stable preview scaling
  local pow = 1024
  while pow < maxVal do pow = pow * 2 end
  maxVal = pow
  local combined = {}
  for i = 1, #readHistory do
    combined[i] = math.max(readHistory[i], writeHistory[i]) / maxVal
  end
  return { values = { table.unpack(combined) }, color = "secondary" }
end

function M.getValue()
  if readSpeed == 0 and writeSpeed == 0 then
    return "—"
  end
  return string.format("R:%s W:%s", formatSpeed(readSpeed), formatSpeed(writeSpeed))
end

function M.getSubtitle()
  if #mounts == 0 then
    return ""
  end
  return mounts[1].path
end

local function parseDiskStats()
  local content = noctalia.readFile("/proc/diskstats")
  if content == nil then
    return 0, 0
  end

  local readSectors = 0
  local writeSectors = 0

  for line in content:gmatch("[^\n]+") do
    local fields = {}
    for f in line:gmatch("%S+") do
      fields[#fields + 1] = f
    end
    local name = fields[3]
    local readSect = fields[6]
    local writeSect = fields[10]
    if name and not name:match("^loop") and not name:match("^ram") then
      readSectors = readSectors + (tonumber(readSect) or 0)
      writeSectors = writeSectors + (tonumber(writeSect) or 0)
    end
  end

  return readSectors * 512, writeSectors * 512
end

function M.tick()
  local m = noctalia.diskMounts()
  if m ~= nil then
    mounts = m
    diskData = {}
    for _, mount in ipairs(mounts) do
      local d = noctalia.diskStats(mount.path)
      if d ~= nil then
        diskData[mount.path] = d
      end
    end
  end

  local now = os.time()
  local readBytes, writeBytes = parseDiskStats()

  if lastTickTime > 0 then
    local elapsed = now - lastTickTime
    if elapsed > 0 then
      readSpeed = (readBytes - lastReadSectors) / elapsed
      writeSpeed = (writeBytes - lastWriteSectors) / elapsed

      table.insert(readHistory, readSpeed)
      table.insert(writeHistory, writeSpeed)
      if #readHistory > MAX_SAMPLES then
        table.remove(readHistory, 1)
        table.remove(writeHistory, 1)
      end
    end
  end

  lastReadSectors = readBytes
  lastWriteSectors = writeBytes
  lastTickTime = now
  totalReadBytes = readBytes
  totalWriteBytes = writeBytes
end

function formatSpeed(bytesPerSec)
  if bytesPerSec >= 1073741824 then
    return string.format("%.1f GB/s", bytesPerSec / 1073741824)
  elseif bytesPerSec >= 1048576 then
    return string.format("%.1f MB/s", bytesPerSec / 1048576)
  elseif bytesPerSec >= 1024 then
    return string.format("%.1f KB/s", bytesPerSec / 1024)
  end
  return string.format("%.0f B/s", bytesPerSec)
end

local function formatBytes(bytes)
  if bytes >= 1073741824 then
    return string.format("%.1f GiB", bytes / 1073741824)
  elseif bytes >= 1048576 then
    return string.format("%.1f MiB", bytes / 1048576)
  elseif bytes >= 1024 then
    return string.format("%.1f KiB", bytes / 1024)
  end
  return string.format("%.0f B", bytes)
end

local function buildYLabels()
  return ui.column({ width = 0 })
end

local function buildThroughputGraph()
  -- shared Pow2 normalization so Read/Write are distinct on same scale
  -- (Mission Center GraphWidget connect_datasets + ScaleUp/Pow2)
  local maxVal = 1024
  for i = 1, #readHistory do
    if readHistory[i] > maxVal then maxVal = readHistory[i] end
    if writeHistory[i] > maxVal then maxVal = writeHistory[i] end
  end
  -- Pow2 rounding (stable top Y label)
  local pow = 1024
  while pow < maxVal do pow = pow * 2 end
  maxVal = pow
  if maxVal < 1024 then maxVal = 1024 end

  local normalizedRead = {}
  local normalizedWrite = {}
  for i = 1, #readHistory do
    normalizedRead[i] = readHistory[i] / maxVal
    normalizedWrite[i] = writeHistory[i] / maxVal
  end

  local maxLabel = formatSpeed(maxVal)

  return ui.column({ flexGrow = 1, gap = 4 }, {
    -- legend: solid Read (secondary) vs dashed-like Write (tertiary)
    ui.row({ justify = "space_between", align = "center" }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.column({ width = 12, height = 2, radius = 1, fill = "secondary" }),
        ui.label({ text = "Read", fontSize = 10, color = "secondary" }),
        ui.label({ text = formatSpeed(readSpeed), fontSize = 10, color = "on_surface_variant" }),
      }),
      ui.row({ gap = 6, align = "center" }, {
        ui.column({ width = 12, height = 2, radius = 1, fill = "tertiary" }),
        ui.label({ text = "Write", fontSize = 10, color = "tertiary" }),
        ui.label({ text = formatSpeed(writeSpeed), fontSize = 10, color = "on_surface_variant" }),
      }),
    }),
    ui.column({ flexGrow = 1, gap = 4 }, {
      ui.graph({
        values = normalizedRead,
        color = "secondary",
        values2 = normalizedWrite,
        color2 = "tertiary",
        lineWidth = 2,
        flexGrow = 1,
      }),
      ui.row({ justify = "space_between" }, {
        ui.label({ text = "Active over time", fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = maxLabel, fontSize = 10, color = "on_surface_variant" }),
      }),
    }),
  })
end

local function buildStatsPanel()
  local stats = {
    { label = "Read speed", value = formatSpeed(readSpeed), highlight = true },
    { label = "Write speed", value = formatSpeed(writeSpeed), highlight = true },
    { label = "Total Read", value = formatBytes(totalReadBytes) },
    { label = "Total Written", value = formatBytes(totalWriteBytes) },
  }

  local rows = {}
  for _, s in ipairs(stats) do
    local valColor = s.highlight and "secondary" or nil
    table.insert(rows, ui.row({ justify = "space_between" }, {
      ui.label({ text = s.label, fontSize = 12, color = "on_surface_variant" }),
      ui.label({ text = s.value, fontSize = 12, fontWeight = s.highlight and "bold" or nil, color = valColor }),
    }))
  end

  -- sort partitions largest first (Mission Center partition_usage_item sort)
  local sorted = {}
  for path, d in pairs(diskData) do
    table.insert(sorted, { path = path, d = d })
  end
  table.sort(sorted, function(a, b)
    return (a.d.totalBytes or 0) > (b.d.totalBytes or 0)
  end)

  for _, entry in ipairs(sorted) do
    local path = entry.path
    local d = entry.d
    if d.totalBytes == nil or d.totalBytes == 0 then
      -- hide bar when size unknown (Mission Center size==None)
      table.insert(rows, ui.label({ text = "", fontSize = 4 }))
      table.insert(rows, ui.row({ justify = "space_between" }, {
        ui.label({ text = path, fontSize = 11, fontWeight = "bold" }),
        ui.label({ text = "—", fontSize = 11, color = "on_surface_variant" }),
      }))
      table.insert(rows, ui.row({ justify = "space_between" }, {
        ui.label({ text = "Used", fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = "—", fontSize = 10 }),
      }))
      table.insert(rows, ui.row({ justify = "space_between" }, {
        ui.label({ text = "Total", fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = "—", fontSize = 10 }),
      }))
    else
      local total = d.totalBytes
      local free = d.freeBytes
      -- Use usagePercent as authoritative when available; bytes-derived
      -- pct drifts if freeBytes is nil/0 (would give 100% like 500/500)
      local pct
      if d.usagePercent ~= nil then
        pct = tonumber(d.usagePercent) or 0
      elseif free ~= nil and total > 0 then
        pct = ((total - free) / total) * 100
      elseif d.availableBytes ~= nil and total > 0 then
        pct = ((total - d.availableBytes) / total) * 100
      else
        -- no authoritative source -> 0% (avoid 500/500 =100% false full)
        pct = 0
      end
      pct = math.max(0, math.min(100, pct))

      -- Derive usedBytes consistently with pct so Used label matches bar
      local usedBytes
      if free ~= nil then
        usedBytes = total - free
        -- if bytes-derived pct disagrees wildly with usagePercent (>2%), prefer usagePercent-derived used
        if d.usagePercent ~= nil then
          local bytesPct = (usedBytes / total) * 100
          if math.abs(bytesPct - pct) > 2 then
            usedBytes = total * pct / 100
          end
        end
      elseif d.usagePercent ~= nil then
        usedBytes = total * pct / 100
      else
        usedBytes = total - (free or 0)
      end

      local widthPct = string.format("%.0f%%", pct)
      table.insert(rows, ui.label({ text = "", fontSize = 4 }))
      table.insert(rows, ui.row({ justify = "space_between" }, {
        ui.label({ text = path, fontSize = 11, fontWeight = "bold" }),
        ui.label({ text = string.format("%.1f%%", pct), fontSize = 11, color = "secondary" }),
      }))
      table.insert(rows, ui.row({ justify = "space_between" }, {
        ui.label({ text = "Used", fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = formatBytes(usedBytes), fontSize = 10 }),
      }))
      table.insert(rows, ui.row({ justify = "space_between" }, {
        ui.label({ text = "Total", fontSize = 10, color = "on_surface_variant" }),
        ui.label({ text = formatBytes(total), fontSize = 10 }),
      }))
      -- small storage-used progress bar — width clamped to pct, so 500GB total never shows 100% unless truly full
      table.insert(rows, ui.column({ width = "100%", height = 4, radius = 2, fill = "outline/0.2" }, {
        ui.column({ width = widthPct, height = 4, radius = 2, fill = "secondary" }),
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
        ui.label({ text = "Disk", fontSize = 18, fontWeight = "bold" }),
        ui.label({ text = "Active over time", fontSize = 11, color = "on_surface_variant" }),
      }),
    }),
    ui.row({ flexGrow = 1, gap = 12, padding = { left = 12, right = 12, bottom = 12 }, align = "stretch" }, {
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.column({ fill = "surface_variant/0.4", radius = 10, border = "outline/0.2", borderWidth = 1, padding = 12, flexGrow = 1 }, {
          buildThroughputGraph(),
        }),
      }),
      buildStatsPanel(),
    }),
  })
end

return M
