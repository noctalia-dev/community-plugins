--!nonstrict
-- System info monitor: fastfetch-style system information display.

local refresh = nil
local sysInfo = {}
local loaded = false
local gpuInfo = nil

local M = {}

function M.attach(fn)
  refresh = fn
end

function M.getPreview()
  return { values = {}, color = "on_surface_variant" }
end

function M.getValue()
  return ""
end

function M.getSubtitle()
  return ""
end

local function readFile(path)
  local content = noctalia.readFile(path)
  if content == nil then
    return nil
  end
  return content:gsub("%s+$", "")
end

local function formatBytes(bytes)
  if bytes == nil then return "N/A" end
  if bytes >= 1073741824 then
    return string.format("%.2f GiB", bytes / 1073741824)
  elseif bytes >= 1048576 then
    return string.format("%.2f MiB", bytes / 1048576)
  elseif bytes >= 1024 then
    return string.format("%.2f KiB", bytes / 1024)
  end
  return string.format("%.0f B", bytes)
end

local function formatSpeed(bytesPerSec)
  if bytesPerSec >= 1073741824 then
    return string.format("%.2f GB/s", bytesPerSec / 1073741824)
  elseif bytesPerSec >= 1048576 then
    return string.format("%.2f MB/s", bytesPerSec / 1048576)
  elseif bytesPerSec >= 1024 then
    return string.format("%.2f KB/s", bytesPerSec / 1024)
  end
  return string.format("%.0f B/s", bytesPerSec)
end

-- Static info: read once, never changes
local staticInfo = nil

local function detectGpuDriver(deviceName)
  local vendor = (deviceName or ""):lower()
  local paths = {
    { k = "amdgpu", v = "/sys/module/amdgpu/version" },
    { k = "radeon", v = "/sys/module/radeon/version" },
    { k = "nvidia", v = "/sys/module/nvidia_drm/version" },
    { k = "intel", v = "/sys/module/i915/version" },
  }
  for _, p in ipairs(paths) do
    if vendor:find(p.k, 1, true) then
      local ver = readFile(p.v)
      if ver and ver ~= "" then return ver end
    end
  end
  local nv = readFile("/proc/driver/nvidia/version")
  if nv then
    local ver = nv:match("(%d+%.%d+%.%d+)")
    if ver then return ver end
  end
  return "N/A"
end

local function loadGpuInfo()
  if gpuInfo ~= nil then return gpuInfo end
  if not noctalia.commandExists("nvtop") then
    gpuInfo = { name = "GPU", vram = "N/A", driver = "N/A" }
    return gpuInfo
  end
  gpuInfo = { name = "GPU", vram = "N/A", driver = "N/A" }
  noctalia.runAsync("nvtop -s", function(result)
    if result == nil or result.exitCode ~= 0 or result.stdout == nil then return end
    local ok, data = pcall(noctalia.json.decode, result.stdout)
    if not ok or type(data) ~= "table" or data[1] == nil then return end
    local gpu = data[1]
    local name = gpu.device_name or "GPU"
    gpuInfo = {
      name = name,
      vram = formatBytes(tonumber(gpu.mem_total) or 0),
      driver = detectGpuDriver(name),
    }
  end, 5000)
  return gpuInfo
end

local function loadStaticInfo()
  if staticInfo then return staticInfo end

  local osName = "Unknown"
  for _, path in ipairs({"/etc/os-release", "/usr/lib/os-release"}) do
    local content = readFile(path)
    if content then
      for line in content:gmatch("[^\n]+") do
        if line:match("PRETTY_NAME") then
          local val = line:match("=(.+)")
          if val then
            osName = val:gsub("^\"", ""):gsub("\"$", "")
            break
          end
        end
      end
      if osName ~= "Unknown" then break end
    end
  end

  local kernel = "Unknown"
  local version = readFile("/proc/version")
  if version then
    local k = version:match("Linux%s+version%s+(%S+)")
    if k then kernel = k end
  end

  local hostname = "Unknown"
  local hn = readFile("/proc/sys/kernel/hostname")
  if hn then hostname = hn end

  local username = noctalia.getenv("USER") or "user"

  local shell = "Unknown"
  local sh = noctalia.getenv("SHELL")
  if sh then shell = sh:match("([^/]+)$") or sh end

  local wm = "Unknown"
  local w = noctalia.getenv("XDG_CURRENT_DESKTOP")
  if w and w ~= "" then wm = w
  else
    local w2 = noctalia.getenv("DESKTOP_SESSION")
    if w2 and w2 ~= "" then wm = w2 end
  end

  local terminal = "Unknown"
  local t = noctalia.getenv("TERM_PROGRAM")
  if t and t ~= "" then terminal = t
  else
    local t2 = noctalia.getenv("TERM")
    if t2 and t2 ~= "" then terminal = t2 end
  end

  local cpuModel = "Unknown"
  local cpuInfo = readFile("/proc/cpuinfo")
  if cpuInfo then
    for line in cpuInfo:gmatch("[^\n]+") do
      local model = line:match("^model name%s*:%s*(.+)$")
      if model then
        cpuModel = model
        break
      end
    end
  end

  local motherboard = "Unknown"
  local board = readFile("/sys/class/dmi/id/board_name")
  if board and board ~= "" then
    motherboard = board
  end

  staticInfo = {
    osName = osName,
    kernel = kernel,
    hostname = hostname,
    username = username,
    shell = shell,
    wm = wm,
    terminal = terminal,
    cpuModel = cpuModel,
    motherboard = motherboard,
  }
  return staticInfo
end

function M.tick()
  local s = noctalia.systemStats()
  local si = loadStaticInfo()

  sysInfo = {
    { section = "System", items = {
      { label = "OS", value = si.osName },
      { label = "Kernel", value = si.kernel },
      { label = "Hostname", value = si.hostname },
      { label = "Shell", value = si.shell },
      { label = "WM", value = si.wm },
      { label = "Terminal", value = si.terminal },
    }},
  }

  if s then
    table.insert(sysInfo, {
      section = "Hardware",
      items = {
        { label = "CPU", value = si.cpuModel },
        { label = "Motherboard", value = si.motherboard },
      },
    })

    local gpu = loadGpuInfo()
    if gpu then
      table.insert(sysInfo, { section = "Graphics", items = {
        { label = "GPU", value = gpu.name },
        { label = "VRAM", value = gpu.vram },
        { label = "Driver", value = gpu.driver },
      }})
    end

    local disks = {}
    local mounts = noctalia.diskMounts()
    if mounts then
      for _, mount in ipairs(mounts) do
        local d = noctalia.diskStats(mount.path)
        if d then
          local used = d.totalBytes - d.freeBytes
          table.insert(disks, {
            label = mount.path,
            value = string.format("%s / %s (%.1f%%)", formatBytes(used), formatBytes(d.totalBytes), d.usagePercent or 0),
          })
        end
      end
    end
    if #disks > 0 then
      table.insert(sysInfo, { section = "Storage", items = disks })
    end

    local netItems = {}
    if s.net and s.net.interfaces then
      for name, data in pairs(s.net.interfaces) do
        if name ~= "lo" then
          local ip = data.address or "N/A"
          table.insert(netItems, {
            label = name,
            value = string.format("IP: %s", ip),
          })
        end
      end
    end
    if s.net then
      table.insert(netItems, {
        label = "Speed",
        value = string.format("↓%s ↑%s", formatSpeed(s.net.rxBytesPerSec or 0), formatSpeed(s.net.txBytesPerSec or 0)),
      })
    end
    if #netItems > 0 then
      table.insert(sysInfo, { section = "Network", items = netItems })
    end
  end

  loaded = true
end

local function buildInfoRow(label, value)
  return ui.row({ gap = 8, padding = { left = 8, right = 8, top = 2, bottom = 2 } }, {
    ui.label({ text = label .. ":", fontSize = 11, color = "on_surface_variant", width = 90 }),
    ui.label({ text = value, fontSize = 11, flexGrow = 1 }),
  })
end

local function buildSection(title, items)
  local rows = {}
  for _, item in ipairs(items) do
    table.insert(rows, buildInfoRow(item.label, item.value))
  end
  return ui.column({
    fill = "surface_variant/0.4",
    radius = 10,
    border = "outline/0.2",
    borderWidth = 1,
    padding = 12,
    gap = 4,
  }, {
    ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = "primary" }),
    ui.column({ gap = 2 }, rows),
  })
end

function M.build()
  if not loaded then
    M.tick()
  end

  local si = loadStaticInfo()

  local sections = {}
  for _, group in ipairs(sysInfo) do
    table.insert(sections, buildSection(group.section, group.items))
  end

  return ui.column({ flexGrow = 1, gap = 0 }, {
    ui.row({ padding = { left = 12, right = 12, top = 12, bottom = 4 }, align = "center", justify = "space_between" }, {
      ui.label({ text = "System Information", fontSize = 18, fontWeight = "bold" }),
      ui.label({ text = si.username .. "@" .. si.hostname, fontSize = 11, color = "on_surface_variant" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12, padding = { left = 12, right = 12, bottom = 12 } }, sections),
  })
end

return M
