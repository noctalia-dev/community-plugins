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
  local combined = {}
  for i = 1, #readHistory do
    combined[i] = (readHistory[i] + writeHistory[i]) / 2
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
    return 0, 0, 0, 0
  end

  local totalRead = 0
  local totalWrite = 0
  local readSectors = 0
  local writeSectors = 0

  for line in content:gmatch("[^\n]+") do
    local name, reads, _, _, _, readSect, _, _, writes, _, _, writeSect = line:match(
      "^%s*(%S+)%s+(%d+)%s+%d+%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+%d+%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)"
    )
    if name and not name:match("^loop") and not name:match("^ram") then
      readSectors = readSectors + (readSect or 0)
      writeSectors = writeSectors + (writeSect or 0)
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
  return ui.column({ flexGrow = 1, gap = 4 }, {
    ui.column({ flexGrow = 1, gap = 4 }, {
      ui.graph({
        values = { table.unpack(readHistory) },
        color = "secondary",
        values2 = { table.unpack(writeHistory) },
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

  for path, d in pairs(diskData) do
    local usedBytes = d.totalBytes - d.freeBytes
    table.insert(rows, ui.label({ text = "", fontSize = 4 }))
    table.insert(rows, ui.row({ justify = "space_between" }, {
      ui.label({ text = path, fontSize = 11, fontWeight = "bold" }),
      ui.label({ text = string.format("%.1f%%", d.usagePercent or 0), fontSize = 11, color = "secondary" }),
    }))
    table.insert(rows, ui.row({ justify = "space_between" }, {
      ui.label({ text = "Used", fontSize = 10, color = "on_surface_variant" }),
      ui.label({ text = formatBytes(usedBytes), fontSize = 10 }),
    }))
    table.insert(rows, ui.row({ justify = "space_between" }, {
      ui.label({ text = "Total", fontSize = 10, color = "on_surface_variant" }),
      ui.label({ text = formatBytes(d.totalBytes), fontSize = 10 }),
    }))
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
        ui.label({ text = "Throughput over 1 minute", fontSize = 11, color = "on_surface_variant" }),
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
