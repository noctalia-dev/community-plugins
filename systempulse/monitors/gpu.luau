--!nonstrict
-- GPU monitor detail view using nvtop for direct GPU data.

local MAX_SAMPLES = 60

local history = {}
local vramHistory = {}
local deviceName = "GPU"
local usagePercent = 0
local tempC = nil
local fanSpeed = nil
local powerDraw = nil
local gpuClock = nil
local memClock = nil
local vramUsedBytes = nil
local vramTotalBytes = nil
local encodePercent = nil
local decodePercent = nil
local hasNvtop = false
local refresh = nil
local M = {}

function M.attach(fn)
  refresh = fn
  hasNvtop = noctalia.commandExists("nvtop")
end

function M.getPreview()
  if #history == 0 then return nil end
  return { values = { table.unpack(history) }, color = "secondary" }
end

function M.getValue()
  if usagePercent == 0 then return "—" end
  local val = string.format("%d%%", usagePercent)
  if tempC ~= nil then val = val .. string.format(" (%d°C)", tempC) end
  return val
end

function M.getSubtitle()
  return ""
end

local function parsePercent(s)
  if s == nil then return nil end
  return tonumber(s:match("(%d+)"))
end

local function parseClock(s)
  if s == nil then return nil end
  return tonumber(s:match("(%d+)"))
end

local function parseBytes(s)
  if s == nil then return nil end
  return tonumber(s)
end

local pendingNvtop = nil

local function onNvtopResult(result)
  if result == nil or result.exitCode ~= 0 then return end
  local stdout = result.stdout
  if stdout == nil or stdout == "" then return end
  local ok, data = pcall(noctalia.json.decode, stdout)
  if not ok or type(data) ~= "table" or data[1] == nil then return end
  pendingNvtop = data[1]
end

function M.tick()
  if hasNvtop then
    noctalia.runAsync("nvtop -s", onNvtopResult, 5000)
  end

  if pendingNvtop ~= nil then
    local gpu = pendingNvtop
    pendingNvtop = nil
    deviceName = gpu.device_name or deviceName
    usagePercent = parsePercent(gpu.gpu_util) or 0
    tempC = parsePercent(gpu.temp)
    fanSpeed = parsePercent(gpu.fan_speed)
    powerDraw = parseClock(gpu.power_draw)
    gpuClock = parseClock(gpu.gpu_clock)
    memClock = parseClock(gpu.mem_clock)
    vramUsedBytes = parseBytes(gpu.mem_used)
    vramTotalBytes = parseBytes(gpu.mem_total)
    encodePercent = parsePercent(gpu.encode)
    decodePercent = parsePercent(gpu.decode)
  else
    local s = noctalia.systemStats()
    if s ~= nil and s.gpu ~= nil then
      usagePercent = s.gpu.usagePercent or usagePercent
      tempC = s.gpu.tempC or tempC
      vramUsedBytes = s.gpu.vramUsedBytes or vramUsedBytes
      vramTotalBytes = s.gpu.vramTotalBytes or vramTotalBytes
    end
  end

  table.insert(history, usagePercent / 100)
  local vramPct = (vramUsedBytes ~= nil and vramTotalBytes ~= nil and vramTotalBytes > 0) and (vramUsedBytes / vramTotalBytes) or 0
  table.insert(vramHistory, vramPct)
  if #history > MAX_SAMPLES then
    table.remove(history, 1)
    table.remove(vramHistory, 1)
  end
end

local function formatBytes(bytes)
  if bytes == nil then return "N/A" end
  if bytes >= 1073741824 then
    return string.format("%.1f GiB", bytes / 1073741824)
  elseif bytes >= 1048576 then
    return string.format("%.1f MiB", bytes / 1048576)
  end
  return string.format("%.0f KiB", bytes / 1024)
end

local function formatClock(mhz)
  if mhz == nil then return "—" end
  if mhz >= 1000 then return string.format("%.2f GHz", mhz / 1000) end
  return string.format("%d MHz", mhz)
end

local function formatPower(watts)
  if watts == nil then return "—" end
  return string.format("%d W", watts)
end

local function buildGraph()
  return ui.column({ flexGrow = 1, gap = 4 }, {
    ui.column({ flexGrow = 1, gap = 4 }, {
      ui.graph({
        values = { table.unpack(history) },
        color = "secondary",
        values2 = { table.unpack(vramHistory) },
        color2 = "tertiary",
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
    { label = "Utilization", value = string.format("%d%%", usagePercent), highlight = true },
    { label = "Temperature", value = tempC ~= nil and string.format("%d°C", tempC) or "—" },
  }
  if gpuClock ~= nil then
    table.insert(stats, { label = "Clock Speed", value = formatClock(gpuClock) })
  end
  if fanSpeed ~= nil then
    table.insert(stats, { label = "Fan Speed", value = string.format("%d%%", fanSpeed) })
  end
  if powerDraw ~= nil then
    table.insert(stats, { label = "Power Draw", value = formatPower(powerDraw) })
  end
  if vramUsedBytes ~= nil and vramTotalBytes ~= nil then
    table.insert(stats, { label = "Memory Usage", value = string.format( formatBytes(vramUsedBytes), formatBytes(vramTotalBytes)) })
  end
  if memClock ~= nil then
    table.insert(stats, { label = "Memory Clock", value = formatClock(memClock) })
  end
  if encodePercent ~= nil then
    table.insert(stats, { label = "Encoder", value = string.format("%d%%", encodePercent) })
  end
  if decodePercent ~= nil then
    table.insert(stats, { label = "Decoder", value = string.format("%d%%", decodePercent) })
  end

  local rows = {}
  for _, s in ipairs(stats) do
    local valColor = s.highlight and "secondary" or nil
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
    width = 220,
  }, {
    ui.label({ text = "Statistics", fontSize = 12, fontWeight = "bold" }),
    ui.column({ gap = 4 }, rows),
  })
end

function M.build()
  local headerValue = string.format("%d%%", usagePercent)
  if tempC ~= nil then
    headerValue = headerValue .. string.format(" · %d°C", tempC)
  end
  return ui.column({ flexGrow = 1, gap = 0 }, {
    ui.row({ padding = 12, align = "center", justify = "space_between" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = deviceName, fontSize = 18, fontWeight = "bold" }),
        ui.label({ text = "Utilization over 1 minute", fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({ text = headerValue, fontSize = 18, fontWeight = "bold", color = "secondary" }),
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
