--!nonstrict

local MIB = 1024 * 1024
local NETWORK_MEGABYTE = 1000000
local PROCESS_POLL_INTERVAL_MS = 5000
local PROCESS_POLL_TIMEOUT_MS = 2000
local PROCESS_SNAPSHOT_COMMAND = "ps -eo pid:1=,rss:1=,cputimes:1="
local PROCESS_NAMES_PREFIX = "ps -p "
local CPU_FREQ_POLL_INTERVAL_MS = 5000
local CPU_FREQ_POLL_TIMEOUT_MS = 2000
local CPU_FREQ_SYSFS_COMMAND = "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
local CPU_FREQ_PROC_COMMAND = "cat /proc/cpuinfo"

local THRESHOLD_DEFAULTS = {
  cpu_usage = { 50, 90 }, cpu_temp = { 60, 85 },
  gpu_usage = { 50, 95 }, gpu_temp = { 60, 85 }, gpu_vram = { 50, 90 },
  ram_pct = { 60, 90 }, swap_pct = { 20, 80 }, disk_used_pct = { 80, 95 },
  net_rx = { 1, 50 }, net_tx = { 1, 50 },
}

local networkSession = { sampledAtMs = nil, aggregate = nil, interfaces = {} }
local processMonitor = {
  enabled = false, pending = false, lastPollStartedMs = nil,
  previous = nil, previousAtMs = nil, knownNames = {}, topCpu = nil, topRam = nil,
}
local psAvailable = nil
local cpuFreqMonitor = { enabled = false, pending = false, lastPollStartedMs = nil, freqMhz = nil }
local catAvailable = nil

local function trim(value)
  if type(value) ~= "string" then return "" end
  return string.match(value, "^%s*(.-)%s*$") or ""
end

local function formatPercent(value)
  if type(value) ~= "number" then return "—" end
  return string.format("%.0f%%", value)
end

local function formatTemperature(value)
  if type(value) ~= "number" then return "—" end
  return string.format("%.0f°C", value)
end

local function formatBinary(bytes)
  if type(bytes) ~= "number" or bytes < 0 then return "—" end
  local units = { "B", "K", "M", "G", "T", "P" }
  local index = 1
  local scaled = bytes
  while scaled >= 1024 and index < #units do
    scaled = scaled / 1024
    index = index + 1
  end
  if index == 1 or scaled >= 10 then
    return string.format("%.0f%s", scaled, units[index])
  end
  return string.format("%.1f%s", scaled, units[index])
end

local function formatRate(value, compact)
  if type(value) ~= "number" then return "—" end
  if value >= 1000000000 then
    return string.format(compact and "%.1fG/s" or "%.1f GB/s", value / 1000000000)
  elseif value >= 1000000 then
    return string.format(compact and "%.1fM/s" or "%.1f MB/s", value / 1000000)
  elseif value >= 1000 then
    return string.format(compact and "%.1fk/s" or "%.1f kB/s", value / 1000)
  end
  return string.format(compact and "%.0fB/s" or "%.0f B/s", value)
end

local function formatFrequency(value)
  if type(value) ~= "number" then return "—" end
  return string.format("%.1f GHz", value / 1000)
end

local function formatLoad(loadAvg)
  if type(loadAvg) ~= "table" or type(loadAvg[1]) ~= "number"
      or type(loadAvg[2]) ~= "number" or type(loadAvg[3]) ~= "number" then
    return "—"
  end
  return string.format("%.2f · %.2f · %.2f", loadAvg[1], loadAvg[2], loadAvg[3])
end

local function configBool(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then return value end
  return fallback
end

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) == "string" then return value end
  return fallback
end

local function configColor(key, fallback)
  local value = configString(key, fallback)
  if trim(value) == "" then return fallback end
  return value
end

local function configSelect(key, fallback)
  local value = noctalia.getConfig(key)
  if value == "percentage" or value == "used" or value == "available" then return value end
  return fallback
end

local function configTriState(key, fallback)
  local value = noctalia.getConfig(key)
  if value == "auto" or value == "on" or value == "off" then return value end
  return fallback
end

local function resolveTriState(mode, fieldPresent)
  if mode == "on" then return true end
  if mode == "off" then return false end
  return fieldPresent
end

local function percentage(used, total)
  if type(used) ~= "number" or type(total) ~= "number" or total <= 0 then return nil end
  return used / total * 100
end

local function thresholdPair(name)
  local defaults = THRESHOLD_DEFAULTS[name]
  local activity = noctalia.getSetting("system.monitor." .. name .. "_activity_threshold")
  local critical = noctalia.getSetting("system.monitor." .. name .. "_critical_threshold")
  if type(activity) ~= "number" or type(critical) ~= "number"
      or activity < 0 or critical < 0 or activity > critical then
    return defaults[1], defaults[2]
  end
  return activity, critical
end

local function metricColor(value, thresholds, colors)
  if not colors.highlightValues or type(value) ~= "number" or thresholds[2] == 0 then return "on_surface" end
  if value >= thresholds[2] then return colors.criticalColor end
  if value >= thresholds[1] then return colors.activityColor end
  return "on_surface"
end

local function appendDivider(children, key)
  local mark = barWidget.isVertical() and "─" or "│"
  table.insert(children, ui.label({ key = key, text = mark, color = "outline", fontWeight = "light" }))
end

local function appendGroup(children, group, key, showSeparators)
  if #group == 0 then return end
  if #children > 0 and showSeparators then appendDivider(children, "divider:" .. key) end
  for _, child in ipairs(group) do table.insert(children, child) end
end

local function appendMetric(group, key, glyph, text, value, thresholds, colors, highlightValue)
  if value == nil and colors.hideUnavailable then return false end
  local color = metricColor(highlightValue, thresholds, colors)
  table.insert(group, ui.glyph({ key = key .. ":glyph", name = glyph, size = 14, color = color }))
  table.insert(group, ui.label({ key = key .. ":label", text = text, fontWeight = "medium", color = color }))
  return true
end

local function renderFallback(glyph, label, tooltip, showTooltip)
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, {
    ui.glyph({ name = glyph, size = 14 }),
    ui.label({ text = label, fontWeight = "medium" }),
  }))
  if showTooltip then barWidget.setTooltip(tooltip) else barWidget.clearTooltip() end
end

local function ramDisplay(ram, mode)
  if type(ram) ~= "table" then return nil, "—" end
  local usedMb = ram.usedMb
  local totalMb = ram.totalMb
  if mode == "used" then
    return usedMb, formatBinary(type(usedMb) == "number" and usedMb * MIB or nil)
  elseif mode == "available" then
    local availableMb = nil
    if type(totalMb) == "number" and type(usedMb) == "number" then
      availableMb = math.max(0, totalMb - usedMb)
    end
    return availableMb, formatBinary(availableMb and availableMb * MIB or nil)
  end
  return ram.usagePercent, formatPercent(ram.usagePercent)
end

local function diskDisplay(disk, mode)
  if type(disk) ~= "table" then return nil, "—" end
  if mode == "used" then
    local usedBytes = nil
    if type(disk.totalBytes) == "number" and type(disk.freeBytes) == "number" then
      usedBytes = math.max(0, disk.totalBytes - disk.freeBytes)
    end
    return usedBytes, formatBinary(usedBytes)
  elseif mode == "available" then
    return disk.availableBytes, formatBinary(disk.availableBytes)
  end
  return disk.usagePercent, formatPercent(disk.usagePercent)
end

local function addTooltipRow(rows, shown, key, value)
  if shown then table.insert(rows, { key = key, value = value }) end
end

local function formatUsageAmounts(usagePercent, usedBytes, totalBytes)
  return string.format("%s · %s / %s", formatPercent(usagePercent),
    formatBinary(usedBytes), formatBinary(totalBytes))
end

local function emptyNetworkCounter()
  return { rxBytes = 0, txBytes = 0 }
end

local function accumulateNetworkCounter(counter, rates, elapsedSeconds)
  if type(rates.rxBytesPerSec) == "number" then
    counter.rxBytes = counter.rxBytes + rates.rxBytesPerSec * elapsedSeconds
  end
  if type(rates.txBytesPerSec) == "number" then
    counter.txBytes = counter.txBytes + rates.txBytesPerSec * elapsedSeconds
  end
end

local function updateNetworkSession(stats, net)
  local sampledAtMs = stats.sampledAtMs
  if type(sampledAtMs) ~= "number" then return end

  if networkSession.sampledAtMs == nil or sampledAtMs < networkSession.sampledAtMs then
    networkSession = { sampledAtMs = sampledAtMs, aggregate = emptyNetworkCounter(), interfaces = {} }
    if type(net.interfaces) == "table" then
      for name, _rates in pairs(net.interfaces) do
        networkSession.interfaces[name] = emptyNetworkCounter()
      end
    end
    return
  end

  local elapsedSeconds = (sampledAtMs - networkSession.sampledAtMs) / 1000
  if elapsedSeconds <= 0 then return end
  networkSession.sampledAtMs = sampledAtMs
  if networkSession.aggregate == nil then networkSession.aggregate = emptyNetworkCounter() end
  accumulateNetworkCounter(networkSession.aggregate, net, elapsedSeconds)
  if type(net.interfaces) == "table" then
    for name, rates in pairs(net.interfaces) do
      local counter = networkSession.interfaces[name]
      if counter == nil then
        counter = emptyNetworkCounter()
        networkSession.interfaces[name] = counter
      end
      if type(rates) == "table" then accumulateNetworkCounter(counter, rates, elapsedSeconds) end
    end
  end
end

local function networkSessionAmounts(interfaceName, selectedNet)
  local counter = interfaceName == "" and networkSession.aggregate or networkSession.interfaces[interfaceName]
  if type(counter) ~= "table" then return nil, nil end
  local rxBytes = type(selectedNet.rxBytesPerSec) == "number" and counter.rxBytes or nil
  local txBytes = type(selectedNet.txBytesPerSec) == "number" and counter.txBytes or nil
  return rxBytes, txBytes
end

local function sanitizeProcessName(value)
  if type(value) ~= "string" then return "" end
  value = string.gsub(value, "%c", " ")
  value = string.gsub(value, "%s+", " ")
  return trim(value)
end

local function resetProcessMonitor()
  processMonitor = {
    enabled = false, pending = false, lastPollStartedMs = nil,
    previous = nil, previousAtMs = nil, knownNames = {}, topCpu = nil, topRam = nil,
  }
end

local function clearProcessResults(state)
  state.topCpu = nil
  state.topRam = nil
end

local function validProcessResult(result)
  return type(result) == "table" and result.exitCode == 0 and not result.timedOut
    and not result.stdoutTruncated and type(result.stdout) == "string"
end

local function parseProcessSnapshot(stdout)
  local snapshot = {}
  local topRam = nil
  for line in string.gmatch(stdout, "[^\r\n]+") do
    local pidText, rssText, cpuTimeText = string.match(line,
      "^%s*(%d+)%s+(%d+)%s+(%d+)%s*$")
    local pid, rssKb, cpuSeconds = tonumber(pidText), tonumber(rssText), tonumber(cpuTimeText)
    if pid ~= nil and rssKb ~= nil and cpuSeconds ~= nil then
      local entry = { pid = pid, rssBytes = rssKb * 1024, cpuSeconds = cpuSeconds }
      snapshot[pid] = entry
      if entry.rssBytes > 0 and (topRam == nil or entry.rssBytes > topRam.rssBytes
          or (entry.rssBytes == topRam.rssBytes and entry.pid < topRam.pid)) then
        topRam = entry
      end
    end
  end
  return snapshot, topRam
end

local function topCpuProcess(snapshot, previous, elapsedSeconds)
  if type(previous) ~= "table" or type(elapsedSeconds) ~= "number" or elapsedSeconds <= 0 then return nil end
  local topCpu = nil
  for pid, entry in pairs(snapshot) do
    local old = previous[pid]
    if type(old) == "table" and entry.cpuSeconds >= old.cpuSeconds then
      local cpuPercent = (entry.cpuSeconds - old.cpuSeconds) / elapsedSeconds * 100
      if cpuPercent > 0 and (topCpu == nil or cpuPercent > topCpu.cpuPercent
          or (cpuPercent == topCpu.cpuPercent and pid < topCpu.pid)) then
        topCpu = { pid = pid, cpuPercent = cpuPercent }
      end
    end
  end
  return topCpu
end

local function parseProcessNames(stdout)
  local names = {}
  for line in string.gmatch(stdout, "[^\r\n]+") do
    local pidText, name = string.match(line, "^%s*(%d+)%s+(.+)%s*$")
    local pid = tonumber(pidText)
    name = sanitizeProcessName(name)
    if pid ~= nil and name ~= "" then names[pid] = name end
  end
  return names
end

local function finishProcessNames(state, topCpu, topRam, result)
  if processMonitor ~= state then return end
  state.pending = false
  if not validProcessResult(result) then
    clearProcessResults(state)
    return
  end

  local names = parseProcessNames(result.stdout)
  if topCpu ~= nil and state.knownNames[topCpu.pid] ~= nil
      and state.knownNames[topCpu.pid] ~= names[topCpu.pid] then
    topCpu = nil
  end
  for pid, name in pairs(names) do state.knownNames[pid] = name end
  if topCpu ~= nil and names[topCpu.pid] ~= nil then
    topCpu.name = names[topCpu.pid]
  else
    topCpu = nil
  end
  if topRam ~= nil and names[topRam.pid] ~= nil then
    topRam.name = names[topRam.pid]
  else
    topRam = nil
  end
  state.topCpu = topCpu
  state.topRam = topRam
end

local function handleProcessSnapshot(state, result)
  if processMonitor ~= state then return end
  if not validProcessResult(result) then
    state.pending = false
    clearProcessResults(state)
    return
  end

  local snapshot, topRam = parseProcessSnapshot(result.stdout)
  if next(snapshot) == nil then
    state.pending = false
    clearProcessResults(state)
    return
  end

  local nowMs = noctalia.nowMs()
  local elapsedSeconds = type(state.previousAtMs) == "number" and (nowMs - state.previousAtMs) / 1000 or nil
  local topCpu = topCpuProcess(snapshot, state.previous, elapsedSeconds)
  state.previous = snapshot
  state.previousAtMs = nowMs

  local pidSet = {}
  if topCpu ~= nil then pidSet[topCpu.pid] = true end
  if topRam ~= nil then pidSet[topRam.pid] = true end
  local pids = {}
  for pid, _present in pairs(pidSet) do table.insert(pids, pid) end
  table.sort(pids)
  if #pids == 0 then
    state.pending = false
    clearProcessResults(state)
    return
  end

  local namesCommand = PROCESS_NAMES_PREFIX .. table.concat(pids, ",") .. " -o pid:1=,comm:15="
  local accepted = noctalia.runAsync(namesCommand, function(namesResult)
    finishProcessNames(state, topCpu, topRam, namesResult)
  end, PROCESS_POLL_TIMEOUT_MS)
  if not accepted and processMonitor == state then
    state.pending = false
    clearProcessResults(state)
  end
end

local function pollTopProcesses(enabled)
  if not enabled then
    if processMonitor.enabled then resetProcessMonitor() end
    return
  end
  if not processMonitor.enabled then processMonitor.enabled = true end
  if psAvailable == nil then psAvailable = noctalia.commandExists("ps") == true end
  if not psAvailable then
    clearProcessResults(processMonitor)
    return
  end

  local nowMs = noctalia.nowMs()
  if processMonitor.pending or (type(processMonitor.lastPollStartedMs) == "number"
      and nowMs - processMonitor.lastPollStartedMs < PROCESS_POLL_INTERVAL_MS) then return end
  processMonitor.lastPollStartedMs = nowMs
  processMonitor.pending = true
  local state = processMonitor
  local accepted = noctalia.runAsync(PROCESS_SNAPSHOT_COMMAND, function(result)
    handleProcessSnapshot(state, result)
  end, PROCESS_POLL_TIMEOUT_MS)
  if not accepted and processMonitor == state then
    state.pending = false
    clearProcessResults(state)
  end
end

local function resetCpuFreqMonitor()
  cpuFreqMonitor = { enabled = false, pending = false, lastPollStartedMs = nil, freqMhz = nil }
end

local function parseProcCpuMhz(stdout)
  local mhzText = string.match(stdout, "[Cc]pu%s+MHz%s*:%s*([%d%.]+)")
  return mhzText and tonumber(mhzText) or nil
end

local function finishCpuFreqProc(state, result)
  if cpuFreqMonitor ~= state then return end
  state.pending = false
  if not validProcessResult(result) then
    state.freqMhz = nil
    return
  end
  state.freqMhz = parseProcCpuMhz(result.stdout)
end

local function handleCpuFreqSysfs(state, result)
  if cpuFreqMonitor ~= state then return end
  local kHz = validProcessResult(result) and tonumber(trim(result.stdout)) or nil
  if kHz ~= nil then
    state.pending = false
    state.freqMhz = kHz / 1000
    return
  end

  local accepted = noctalia.runAsync(CPU_FREQ_PROC_COMMAND, function(procResult)
    finishCpuFreqProc(state, procResult)
  end, CPU_FREQ_POLL_TIMEOUT_MS)
  if not accepted and cpuFreqMonitor == state then
    state.pending = false
    state.freqMhz = nil
  end
end

local function pollCpuFrequency(enabled)
  if not enabled then
    if cpuFreqMonitor.enabled then resetCpuFreqMonitor() end
    return
  end
  if not cpuFreqMonitor.enabled then cpuFreqMonitor.enabled = true end
  if catAvailable == nil then catAvailable = noctalia.commandExists("cat") == true end
  if not catAvailable then
    cpuFreqMonitor.freqMhz = nil
    return
  end

  local nowMs = noctalia.nowMs()
  if cpuFreqMonitor.pending or (type(cpuFreqMonitor.lastPollStartedMs) == "number"
      and nowMs - cpuFreqMonitor.lastPollStartedMs < CPU_FREQ_POLL_INTERVAL_MS) then return end
  cpuFreqMonitor.lastPollStartedMs = nowMs
  cpuFreqMonitor.pending = true
  local state = cpuFreqMonitor
  local accepted = noctalia.runAsync(CPU_FREQ_SYSFS_COMMAND, function(result)
    handleCpuFreqSysfs(state, result)
  end, CPU_FREQ_POLL_TIMEOUT_MS)
  if not accepted and cpuFreqMonitor == state then
    state.pending = false
    state.freqMhz = nil
  end
end

local function formatTopCpu(entry)
  if type(entry) ~= "table" then return "—" end
  return entry.name .. " · " .. formatPercent(entry.cpuPercent)
end

local function formatTopRam(entry)
  if type(entry) ~= "table" then return "—" end
  return entry.name .. " · " .. formatBinary(entry.rssBytes)
end

function update()
  noctalia.setUpdateInterval(1000)

  local settings = {
    showCpuUsage = configBool("show_cpu_usage", true),
    showCpuTemperature = configBool("show_cpu_temperature", true),
    showCpuDetailsInTooltip = configBool("show_cpu_details_in_tooltip", false),
    showGpuUsageMode = configTriState("show_gpu_usage", "auto"),
    showGpuTemperatureMode = configTriState("show_gpu_temperature", "auto"),
    showGpuVramMode = configTriState("show_gpu_vram", "auto"),
    showRam = configBool("show_ram", true), showSwap = configBool("show_swap", true),
    showDisk = configBool("show_disk", true), showDownload = configBool("show_download", true),
    showUpload = configBool("show_upload", true), showSeparators = configBool("show_separators", true),
    showTooltip = configBool("show_tooltip", true), compactNetwork = configBool("compact_network", true),
    showTopProcesses = configBool("show_top_processes", true),
    highlightValues = configBool("highlight_values", true), hideUnavailable = configBool("hide_unavailable", false),
    activityColor = configColor("activity_color", "primary"), criticalColor = configColor("critical_color", "error"),
    networkInterface = trim(configString("network_interface", "")),
    ramDisplayMode = configSelect("ram_display_mode", "percentage"),
    diskDisplayMode = configSelect("disk_display_mode", "percentage"),
    diskPath = trim(configString("disk_path", "/")),
  }
  if settings.diskPath == "" then settings.diskPath = "/" end

  local thresholds = {}
  for name, _defaults in pairs(THRESHOLD_DEFAULTS) do
    local activity, critical = thresholdPair(name)
    thresholds[name] = { activity, critical }
  end

  local enabledCount = 0
  for _, enabled in ipairs({ settings.showCpuUsage, settings.showCpuTemperature,
      settings.showGpuUsageMode ~= "off", settings.showGpuTemperatureMode ~= "off", settings.showGpuVramMode ~= "off",
      settings.showRam, settings.showSwap, settings.showDisk,
      settings.showDownload, settings.showUpload }) do
    if enabled then enabledCount = enabledCount + 1 end
  end
  if enabledCount == 0 then
    pollTopProcesses(false)
    pollCpuFrequency(false)
    renderFallback("adjustments", "No metrics", "Enable at least one metric in the widget settings.", settings.showTooltip)
    return
  end

  local stats = noctalia.systemStats()
  if stats == nil then
    pollTopProcesses(false)
    pollCpuFrequency(false)
    renderFallback("cpu", "System data unavailable",
      "System monitoring is disabled or no sample is available yet.", settings.showTooltip)
    return
  end
  pollTopProcesses(settings.showTooltip and settings.showTopProcesses)

  local disk = settings.showDisk and noctalia.diskStats(settings.diskPath) or nil
  local gpu = type(stats.gpu) == "table" and stats.gpu or {}
  local ram = type(stats.ram) == "table" and stats.ram or {}
  local swap = type(stats.swap) == "table" and stats.swap or {}
  local cpu = type(stats.cpu) == "table" and stats.cpu or {}
  local net = type(stats.net) == "table" and stats.net or {}
  settings.showGpuUsage = resolveTriState(settings.showGpuUsageMode, type(gpu.usagePercent) == "number")
  settings.showGpuTemperature = resolveTriState(settings.showGpuTemperatureMode, type(gpu.tempC) == "number")
  settings.showGpuVram = resolveTriState(settings.showGpuVramMode,
    type(gpu.vramUsedBytes) == "number" and type(gpu.vramTotalBytes) == "number")
  pollCpuFrequency(settings.showTooltip and settings.showCpuDetailsInTooltip and type(cpu.freqMhz) ~= "number")
  updateNetworkSession(stats, net)
  local selectedNet = net
  local networkLabel = "Network session"
  if settings.networkInterface ~= "" then
    networkLabel = "Network session (" .. settings.networkInterface .. ")"
    selectedNet = type(net.interfaces) == "table" and net.interfaces[settings.networkInterface] or nil
    if type(selectedNet) ~= "table" then selectedNet = {} end
  end

  local cpuUsage, cpuTemp = cpu.usagePercent, cpu.tempC
  local gpuUsage, gpuTemp = gpu.usagePercent, gpu.tempC
  local gpuVram = percentage(gpu.vramUsedBytes, gpu.vramTotalBytes)
  local ramUsage = ram.usagePercent
  local swapUsage = percentage(swap.usedMb, swap.totalMb)
  local diskUsage = disk and disk.usagePercent or nil
  local rx, tx = selectedNet.rxBytesPerSec, selectedNet.txBytesPerSec
  local sessionRx, sessionTx = networkSessionAmounts(settings.networkInterface, selectedNet)
  local ramValue, ramText = ramDisplay(ram, settings.ramDisplayMode)
  local diskValue, diskText = diskDisplay(disk, settings.diskDisplayMode)

  local colors = { highlightValues = settings.highlightValues, hideUnavailable = settings.hideUnavailable,
    activityColor = settings.activityColor, criticalColor = settings.criticalColor }
  local children, processor, graphics, memory, storage, network = {}, {}, {}, {}, {}, {}
  local shown = {}

  if settings.showCpuUsage then shown.cpuUsage = appendMetric(processor, "cpu-usage", "cpu", formatPercent(cpuUsage), cpuUsage, thresholds.cpu_usage, colors, cpuUsage) end
  if settings.showCpuTemperature then shown.cpuTemperature = appendMetric(processor, "cpu-temperature", "temperature", formatTemperature(cpuTemp), cpuTemp, thresholds.cpu_temp, colors, cpuTemp) end
  if settings.showGpuUsage then shown.gpuUsage = appendMetric(graphics, "gpu-usage", "device-desktop", formatPercent(gpuUsage), gpuUsage, thresholds.gpu_usage, colors, gpuUsage) end
  if settings.showGpuTemperature then shown.gpuTemperature = appendMetric(graphics, "gpu-temperature", "temperature", formatTemperature(gpuTemp), gpuTemp, thresholds.gpu_temp, colors, gpuTemp) end
  if settings.showGpuVram then shown.gpuVram = appendMetric(graphics, "gpu-vram", "memory", formatPercent(gpuVram), gpuVram, thresholds.gpu_vram, colors, gpuVram) end
  if settings.showRam then shown.ram = appendMetric(memory, "ram", "server-2", ramText, ramValue, thresholds.ram_pct, colors, ramUsage) end
  if settings.showSwap then shown.swap = appendMetric(memory, "swap", "arrows-exchange", formatPercent(swapUsage), swapUsage, thresholds.swap_pct, colors, swapUsage) end
  if settings.showDisk then shown.disk = appendMetric(storage, "disk", "database", diskText, diskValue, thresholds.disk_used_pct, colors, diskUsage) end
  if settings.showDownload then shown.download = appendMetric(network, "download", "arrow-down", formatRate(rx, settings.compactNetwork), rx, thresholds.net_rx, colors, rx and rx / NETWORK_MEGABYTE or nil) end
  if settings.showUpload then shown.upload = appendMetric(network, "upload", "arrow-up", formatRate(tx, settings.compactNetwork), tx, thresholds.net_tx, colors, tx and tx / NETWORK_MEGABYTE or nil) end

  appendGroup(children, processor, "processor", settings.showSeparators)
  appendGroup(children, graphics, "graphics", settings.showSeparators)
  appendGroup(children, memory, "memory", settings.showSeparators)
  appendGroup(children, storage, "storage", settings.showSeparators)
  appendGroup(children, network, "network", settings.showSeparators)
  if #children == 0 then
    renderFallback("alert-circle", "No data", "All enabled metrics are currently unavailable.", settings.showTooltip)
    return
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 4, align = "center" }, children))
  if not settings.showTooltip then barWidget.clearTooltip() return end

  local rows = {}
  if settings.showCpuDetailsInTooltip and (shown.cpuUsage or shown.cpuTemperature) then
    addTooltipRow(rows, shown.cpuUsage, "CPU usage", formatPercent(cpuUsage))
    addTooltipRow(rows, shown.cpuTemperature, "CPU temperature", formatTemperature(cpuTemp))
    table.insert(rows, { key = "CPU frequency", value = formatFrequency(cpu.freqMhz or cpuFreqMonitor.freqMhz) })
    table.insert(rows, { key = "Load 1 / 5 / 15", value = formatLoad(stats.loadAvg) })
  end
  if shown.gpuUsage or shown.gpuTemperature or shown.gpuVram then
    addTooltipRow(rows, shown.gpuUsage, "GPU usage", formatPercent(gpuUsage))
    addTooltipRow(rows, shown.gpuTemperature, "GPU temperature", formatTemperature(gpuTemp))
    addTooltipRow(rows, shown.gpuVram, "GPU VRAM",
      formatUsageAmounts(gpuVram, gpu.vramUsedBytes, gpu.vramTotalBytes))
  end
  local ramUsedBytes = type(ram.usedMb) == "number" and ram.usedMb * MIB or nil
  local ramTotalBytes = type(ram.totalMb) == "number" and ram.totalMb * MIB or nil
  local swapUsedBytes = type(swap.usedMb) == "number" and swap.usedMb * MIB or nil
  local swapTotalBytes = type(swap.totalMb) == "number" and swap.totalMb * MIB or nil
  local diskUsedBytes = disk and type(disk.totalBytes) == "number" and type(disk.freeBytes) == "number"
    and math.max(0, disk.totalBytes - disk.freeBytes) or nil
  addTooltipRow(rows, shown.ram, "RAM", formatUsageAmounts(ramUsage, ramUsedBytes, ramTotalBytes))
  addTooltipRow(rows, shown.swap, "Swap", formatUsageAmounts(swapUsage, swapUsedBytes, swapTotalBytes))
  addTooltipRow(rows, shown.disk, "Disk " .. settings.diskPath,
    formatUsageAmounts(diskUsage, diskUsedBytes, disk and disk.totalBytes or nil))
  if shown.download or shown.upload then
    local parts = {}
    if shown.download then table.insert(parts, "RX " .. formatBinary(sessionRx)) end
    if shown.upload then table.insert(parts, "TX " .. formatBinary(sessionTx)) end
    table.insert(rows, { key = networkLabel, value = table.concat(parts, " · ") })
  end
  if settings.showTopProcesses then
    addTooltipRow(rows, processMonitor.topCpu ~= nil or not settings.hideUnavailable,
      "Top CPU", formatTopCpu(processMonitor.topCpu))
    addTooltipRow(rows, processMonitor.topRam ~= nil or not settings.hideUnavailable,
      "Top RAM", formatTopRam(processMonitor.topRam))
  end
  barWidget.setTooltip(rows)
end
