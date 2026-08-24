--!nonstrict

local function formatPercent(value)
  if type(value) ~= "number" then
    return "—"
  end

  return string.format("%.0f%%", value)
end

local function formatTemperature(value)
  if type(value) ~= "number" then
    return "—"
  end

  return string.format("%.0f°C", value)
end

local function formatRate(value, compact)
  if type(value) ~= "number" then
    return "—"
  end

  if value >= 1000000000 then
    return string.format(compact and "%.1fG/s" or "%.1f GB/s", value / 1000000000)
  elseif value >= 1000000 then
    return string.format(compact and "%.1fM/s" or "%.1f MB/s", value / 1000000)
  elseif value >= 1000 then
    return string.format(compact and "%.1fk/s" or "%.1f kB/s", value / 1000)
  end

  return string.format(compact and "%.0fB/s" or "%.0f B/s", value)
end

local function configBool(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then
    return value
  end

  return fallback
end

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "string" and value ~= "" then
    return value
  end

  return fallback
end

local function swapPercent(swap)
  if type(swap) ~= "table"
      or type(swap.usedMb) ~= "number"
      or type(swap.totalMb) ~= "number"
      or swap.totalMb <= 0 then
    return nil
  end

  return swap.usedMb / swap.totalMb * 100
end

local function appendMetric(children, glyph, text)
  table.insert(children, ui.glyph({ name = glyph, size = 14 }))
  table.insert(children, ui.label({ text = text, fontWeight = "medium" }))
end

local function appendDivider(children)
  local mark = barWidget.isVertical() and "─" or "│"
  table.insert(children, ui.label({ text = mark, color = "outline", fontWeight = "light" }))
end

local function appendGroup(children, group, showSeparators)
  if #group == 0 then
    return
  end

  if #children > 0 and showSeparators then
    appendDivider(children)
  end

  for _, child in ipairs(group) do
    table.insert(children, child)
  end
end

local function metric(glyph, text)
  return {
    ui.glyph({ name = glyph, size = 14 }),
    ui.label({ text = text, fontWeight = "medium" }),
  }
end

local function appendMetricToGroup(group, glyph, text)
  for _, child in ipairs(metric(glyph, text)) do
    table.insert(group, child)
  end
end

local function renderUnavailable(showTooltip)
  barWidget.render(ui.row({ gap = 4, align = "center" }, {
    ui.glyph({ name = "cpu", size = 14 }),
    ui.label({ text = "System data unavailable", fontWeight = "medium" }),
  }))
  if showTooltip then
    barWidget.setTooltip("System monitoring is disabled or no sample is available yet.")
  else
    barWidget.clearTooltip()
  end
end

function update()
  noctalia.setUpdateInterval(1000)

  local showCpuUsage = configBool("show_cpu_usage", true)
  local showCpuTemperature = configBool("show_cpu_temperature", true)
  local showRam = configBool("show_ram", true)
  local showSwap = configBool("show_swap", true)
  local showDisk = configBool("show_disk", true)
  local showDownload = configBool("show_download", true)
  local showUpload = configBool("show_upload", true)
  local showSeparators = configBool("show_separators", true)
  local showTooltip = configBool("show_tooltip", true)
  local compactNetwork = configBool("compact_network", true)
  local diskPath = configString("disk_path", "/")

  local stats = noctalia.systemStats()
  if stats == nil then
    renderUnavailable(showTooltip)
    return
  end

  local disk = showDisk and noctalia.diskStats(diskPath) or nil
  local cpuUsage = stats.cpu and stats.cpu.usagePercent or nil
  local cpuTemp = stats.cpu and stats.cpu.tempC or nil
  local ramUsage = stats.ram and stats.ram.usagePercent or nil
  local swapUsage = swapPercent(stats.swap)
  local diskUsage = disk and disk.usagePercent or nil
  local rx = stats.net and stats.net.rxBytesPerSec or nil
  local tx = stats.net and stats.net.txBytesPerSec or nil

  local cpuText = formatPercent(cpuUsage)
  local tempText = formatTemperature(cpuTemp)
  local ramText = formatPercent(ramUsage)
  local swapText = formatPercent(swapUsage)
  local diskText = formatPercent(diskUsage)
  local rxText = formatRate(rx, compactNetwork)
  local txText = formatRate(tx, compactNetwork)

  local children = {}
  local processor = {}
  local memory = {}
  local storage = {}
  local network = {}

  if showCpuUsage then appendMetricToGroup(processor, "cpu", cpuText) end
  if showCpuTemperature then appendMetricToGroup(processor, "temperature", tempText) end
  if showRam then appendMetricToGroup(memory, "server-2", ramText) end
  if showSwap then appendMetricToGroup(memory, "arrows-exchange", swapText) end
  if showDisk then appendMetricToGroup(storage, "database", diskText) end
  if showDownload then appendMetricToGroup(network, "arrow-down", rxText) end
  if showUpload then appendMetricToGroup(network, "arrow-up", txText) end

  appendGroup(children, processor, showSeparators)
  appendGroup(children, memory, showSeparators)
  appendGroup(children, storage, showSeparators)
  appendGroup(children, network, showSeparators)

  if #children == 0 then
    barWidget.render(ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "adjustments", size = 14 }),
      ui.label({ text = "No metrics", fontWeight = "medium" }),
    }))
    if showTooltip then
      barWidget.setTooltip("Enable at least one metric in the widget settings.")
    else
      barWidget.clearTooltip()
    end
    return
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))

  if showTooltip then
    local lines = {}
    if showCpuUsage then table.insert(lines, "CPU: " .. cpuText) end
    if showCpuTemperature then table.insert(lines, "Temperature: " .. tempText) end
    if showRam then table.insert(lines, "RAM: " .. ramText) end
    if showSwap then table.insert(lines, "Swap: " .. swapText) end
    if showDisk then table.insert(lines, "Disk " .. diskPath .. ": " .. diskText) end
    if showDownload then table.insert(lines, "Download: " .. rxText) end
    if showUpload then table.insert(lines, "Upload: " .. txText) end
    barWidget.setTooltip(table.concat(lines, "\n"))
  else
    barWidget.clearTooltip()
  end
end
