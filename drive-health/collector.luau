--!nonstrict

-- Collection and normalization service. Raw device access lives in the small
-- POSIX script; this entry owns all platform-neutral SMART interpretation.

local SYSTEM_NAMESPACE = "noctalia-gustav0ar-drive-health"
local SYSTEM_LIBEXEC = "/usr/local/libexec/" .. SYSTEM_NAMESPACE
local RAW_CACHE = "/run/" .. SYSTEM_NAMESPACE .. "/raw.json"
local CACHE_MAX_AGE_SECONDS = 180
local NVME_DATA_UNIT_BYTES = 512000
local EXPECTED_COLLECTOR_VERSION = "2.0.0"
local PREFERENCES_FILE = "drive-preferences.json"

local collecting = false
local refreshNonce = 0
local loggedDependencySignature = nil
local notifiedCollectorUpgradeSignature = nil
local dependencyProbe = {
  checked = false,
  running = false,
  forcedPending = false,
  incompatible = {},
}
local dependencyProbeGeneration = tonumber(noctalia.state.get("dependency_probe_generation")) or 0
local drivePreferences = { schema = 1, order = {}, drives = {} }

local DEPENDENCIES = {
  {
    command = "lsblk",
    label = "lsblk",
    blocking = true,
    packages = {
      pacman = "util-linux", apt = "util-linux", dnf = "util-linux",
      zypper = "util-linux", apk = "util-linux", xbps = "util-linux",
      emerge = "sys-apps/util-linux",
    },
  },
  {
    command = "smartctl",
    label = "smartctl",
    blocking = false,
    packages = {
      pacman = "smartmontools", apt = "smartmontools", dnf = "smartmontools",
      zypper = "smartmontools", apk = "smartmontools", xbps = "smartmontools",
      emerge = "sys-apps/smartmontools",
    },
  },
}

local PACKAGE_MANAGERS = {
  { command = "pacman", id = "pacman", label = "pacman", prefix = "sudo pacman -S --needed " },
  { command = "apt-get", id = "apt", label = "APT", prefix = "sudo apt-get install " },
  { command = "dnf", id = "dnf", label = "DNF", prefix = "sudo dnf install " },
  { command = "zypper", id = "zypper", label = "Zypper", prefix = "sudo zypper install " },
  { command = "apk", id = "apk", label = "APK", prefix = "sudo apk add " },
  { command = "xbps-install", id = "xbps", label = "XBPS", prefix = "sudo xbps-install -S " },
  { command = "emerge", id = "emerge", label = "Portage", prefix = "sudo emerge --ask " },
}

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function systemCollectorEnabled()
  return noctalia.getConfig("system_collector_enabled") == true
end

local function numeric(value)
  if value == nil or type(value) == "boolean" then
    return nil
  end
  if type(value) == "number" then
    if value == value and value ~= math.huge and value ~= -math.huge then
      return value
    end
    return nil
  end
  if type(value) ~= "string" then
    return nil
  end
  local cleaned = value:gsub(",", "")
  local token = cleaned:match("%-?%d+%.?%d*")
  return token ~= nil and tonumber(token) or nil
end

local function integer(value)
  local parsed = numeric(value)
  return parsed ~= nil and math.floor(parsed) or nil
end

local function validCollectionId(value)
  if type(value) ~= "string" then
    return nil
  end
  local trimmed = noctalia.string.trim(value)
  if trimmed == "" or #trimmed > 128 or trimmed:find("[%c]") ~= nil then
    return nil
  end
  return trimmed
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function bitSet(value, bit)
  local parsed = integer(value)
  return parsed ~= nil and math.floor(parsed / (2 ^ bit)) % 2 == 1
end

local function validTemperature(value)
  local parsed = numeric(value)
  return parsed ~= nil and parsed >= -20 and parsed <= 150 and parsed or nil
end

local function smartDeviceFor(path)
  local controller = tostring(path):match("^/dev/(nvme%d+)n%d+$")
  return controller ~= nil and "/dev/" .. controller or tostring(path)
end

local function listDirectory(path)
  local entries = noctalia.listDir(path)
  return type(entries) == "table" and entries or {}
end

local function readTemperatureFile(path)
  local raw = noctalia.readFile(path)
  local value = raw ~= nil and tonumber(noctalia.string.trim(raw)) or nil
  if value == nil then
    return nil
  end
  local celsius = math.abs(value) >= 1000 and value / 1000 or value
  if celsius < -20 or celsius > 150 then
    return nil
  end
  return math.floor(celsius * 10 + 0.5) / 10
end

local function sysfsTemperature(devicePath)
  local name = tostring(devicePath):match("([^/]+)$") or tostring(devicePath)
  local candidates = {}
  local controller = name:match("^(nvme%d+)n%d+$")
  if controller ~= nil then
    local controllerPath = "/sys/class/nvme/" .. controller
    for _, entry in ipairs(listDirectory(controllerPath)) do
      if entry:match("^hwmon") then
        table.insert(candidates, controllerPath .. "/" .. entry .. "/temp1_input")
      end
    end
    local hwmonPath = controllerPath .. "/device/hwmon"
    for _, entry in ipairs(listDirectory(hwmonPath)) do
      if entry:match("^hwmon") then
        table.insert(candidates, hwmonPath .. "/" .. entry .. "/temp1_input")
      end
    end
  end

  for _, entry in ipairs(listDirectory("/sys/class/hwmon")) do
    if entry:match("^hwmon") then
      local root = "/sys/class/hwmon/" .. entry
      local sensorName = noctalia.readFile(root .. "/name")
      if sensorName ~= nil and noctalia.string.trim(sensorName) == "drivetemp"
          and noctalia.fileExists(root .. "/device/block/" .. name) then
        table.insert(candidates, root .. "/temp1_input")
      end
    end
  end

  for _, path in ipairs(candidates) do
    local temperature = readTemperatureFile(path)
    if temperature ~= nil then
      return temperature
    end
  end
  return nil
end

local function walkBlockDevices(nodes, callback)
  for _, node in ipairs(nodes or {}) do
    callback(node)
    walkBlockDevices(node.children, callback)
  end
end

local function mountedUsage(root)
  local used = 0
  local available = 0
  local found = false
  local seen = {}
  local mountPoints = {}
  local seenMountPoints = {}
  walkBlockDevices({ root }, function(node)
    local hasMount = false
    for _, mountpoint in ipairs(node.mountpoints or {}) do
      if type(mountpoint) == "string" and mountpoint ~= "" and mountpoint ~= "[SWAP]" then
        hasMount = true
        if not seenMountPoints[mountpoint] then
          seenMountPoints[mountpoint] = true
          table.insert(mountPoints, mountpoint)
        end
      end
    end
    local identity = tostring(node.kname or node.path or "")
    local fsUsed = integer(node.fsused)
    local fsAvailable = integer(node.fsavail)
    if hasMount and identity ~= "" and not seen[identity] and fsUsed ~= nil and fsAvailable ~= nil then
      seen[identity] = true
      used += fsUsed
      available += fsAvailable
      found = true
    end
  end)
  table.sort(mountPoints, function(left, right)
    if left == right then return false end
    if left == "/" then return true end
    if right == "/" then return false end
    return left < right
  end)
  if not found then
    return nil, nil, nil, mountPoints
  end
  local total = used + available
  local percent = total > 0 and math.floor((used / total * 100) * 10 + 0.5) / 10 or 0
  return used, available, percent, mountPoints
end

local function attributeMap(smart)
  local result = {}
  local ata = type(smart.ata_smart_attributes) == "table" and smart.ata_smart_attributes or {}
  for _, item in ipairs(ata.table or {}) do
    if type(item) == "table" and item.name ~= nil then
      result[tostring(item.name):lower()] = item
    end
  end
  return result
end

local function rawAttribute(attribute)
  if type(attribute) ~= "table" then
    return nil
  end
  local raw = attribute.raw
  return type(raw) == "table" and integer(raw.value) or integer(raw)
end

local function firstAttribute(attributes, names)
  for _, name in ipairs(names) do
    local attribute = attributes[tostring(name):lower()]
    if attribute ~= nil then
      return attribute
    end
  end
  return nil
end

local function maximumRawAttribute(attributes, names)
  local maximum = nil
  for _, name in ipairs(names) do
    local value = rawAttribute(attributes[tostring(name):lower()])
    if value ~= nil then
      maximum = maximum == nil and value or math.max(maximum, value)
    end
  end
  return maximum
end

local function remainingLife(attributes)
  local remaining = firstAttribute(attributes, {
    "Percent_Lifetime_Remain", "SSD_Life_Left", "Media_Wearout_Indicator",
    "Wear_Leveling_Count", "Remaining_Lifetime_Perc", "Remaining_Life",
    "Lifetime_Remaining%", "Drive_Life_Remaining%",
  })
  if remaining ~= nil then
    local value = numeric(remaining.value)
    if value ~= nil then
      return math.floor(clamp(value, 0, 100) * 10 + 0.5) / 10, true
    end
  end
  local used = rawAttribute(firstAttribute(attributes, {
    "Percentage_Used_Endurance_Indicator", "Percent_Lifetime_Used", "SSD_Life_Used",
  }))
  return used ~= nil and math.floor(clamp(100 - used, 0, 100) * 10 + 0.5) / 10 or nil, used ~= nil
end

local function lbaBytes(attributes, names, blockSize)
  local count = rawAttribute(firstAttribute(attributes, names))
  return count ~= nil and count * blockSize or nil
end

local function ataDataBytes(attributes, direction, blockSize)
  local lbaNames
  local gibNames
  local chunkNames
  if direction == "written" then
    lbaNames = { "Total_LBAs_Written" }
    gibNames = { "Lifetime_Writes_GiB", "Host_Writes_GiB", "Total_Writes_GiB", "Total_NAND_Writes_GiB", "TLC_NAND_GB_Writes" }
    chunkNames = { "Host_Writes_32MiB" }
  else
    lbaNames = { "Total_LBAs_Read" }
    gibNames = { "Lifetime_Reads_GiB", "Host_Reads_GiB", "Total_Reads_GiB" }
    chunkNames = { "Host_Reads_32MiB" }
  end
  local bytes = lbaBytes(attributes, lbaNames, blockSize)
  if bytes ~= nil then
    return bytes
  end
  local gib = rawAttribute(firstAttribute(attributes, gibNames))
  if gib ~= nil then
    return gib * 1024 * 1024 * 1024
  end
  local chunks = rawAttribute(firstAttribute(attributes, chunkNames))
  return chunks ~= nil and chunks * 32 * 1024 * 1024 or nil
end

local function classifySelfTest(text, passed, value)
  local normalized = tostring(text or ""):lower()
  if passed == true or tonumber(value) == 0 then
    return "passed"
  elseif normalized:find("progress", 1, true) or normalized:find("in progress", 1, true) then
    return "running"
  elseif normalized:find("interrupt", 1, true) or normalized:find("abort", 1, true) then
    return "interrupted"
  elseif normalized ~= "" then
    return "failed"
  end
  return "unknown"
end

local function normalizeSelfTest(smart)
  local ata = type(smart.ata_smart_self_test_log) == "table" and smart.ata_smart_self_test_log or {}
  local standard = type(ata.standard) == "table" and ata.standard or {}
  local ataLatest = type(standard.table) == "table" and standard.table[1] or nil
  if type(ataLatest) == "table" then
    local status = type(ataLatest.status) == "table" and ataLatest.status or {}
    local remaining = numeric(status.remaining_percent)
    return {
      supported = true,
      state = classifySelfTest(status.string, status.passed, status.value),
      status = tostring(status.string or "Unknown"),
      test_type = type(ataLatest.type) == "table" and ataLatest.type.string or nil,
      lifetime_hours = integer(ataLatest.lifetime_hours),
      completion_percent = remaining ~= nil and clamp(100 - remaining, 0, 100) or nil,
      error_count = integer(standard.error_count_total),
    }
  elseif next(standard) ~= nil then
    return { supported = true, state = "never", status = noctalia.tr("self_test.none_recorded") }
  end

  local nvme = type(smart.nvme_self_test_log) == "table" and smart.nvme_self_test_log or {}
  if next(nvme) ~= nil then
    local operation = type(nvme.current_self_test_operation) == "table" and nvme.current_self_test_operation or {}
    if integer(operation.value) ~= nil and integer(operation.value) ~= 0 then
      return {
        supported = true,
        state = "running",
        status = tostring(operation.string or noctalia.tr("self_test.in_progress")),
        completion_percent = numeric(nvme.current_self_test_completion_percent),
      }
    end
    local latest = type(nvme.table) == "table" and nvme.table[1] or nil
    if type(latest) == "table" then
      local result = type(latest.self_test_result) == "table" and latest.self_test_result or {}
      return {
        supported = true,
        state = classifySelfTest(result.string, result.passed, result.value),
        status = tostring(result.string or "Unknown"),
        test_type = type(latest.self_test_code) == "table" and latest.self_test_code.string or nil,
        lifetime_hours = integer(latest.power_on_hours),
      }
    end
    return { supported = true, state = "never", status = noctalia.tr("self_test.none_recorded") }
  end
  return { supported = false, state = "unsupported", status = noctalia.tr("self_test.log_unavailable") }
end

local function normalizeSmart(smart, blockSize)
  smart = type(smart) == "table" and smart or {}
  blockSize = blockSize or 512
  local nvme = type(smart.nvme_smart_health_information_log) == "table"
      and smart.nvme_smart_health_information_log or {}
  local attributes = attributeMap(smart)
  local isNvme = next(nvme) ~= nil
  local smartctl = type(smart.smartctl) == "table" and smart.smartctl or {}
  local powerMode = type(smart.power_mode) == "table" and smart.power_mode or {}
  local powerModeText = tostring(powerMode.string or ""):lower()
  local smartSleeping = powerModeText:find("standby", 1, true) ~= nil
    or powerModeText:find("sleep", 1, true) ~= nil
  local smartExitStatus = integer(smartctl.exit_status) or integer(smart._collector_exit_code)
  local status = type(smart.smart_status) == "table" and smart.smart_status.passed or nil
  if bitSet(smartExitStatus, 3) or bitSet(smartExitStatus, 4) then
    status = false
  end
  local health = status == true and "passed" or (status == false and "failed" or "unknown")
  local temperatureTable = type(smart.temperature) == "table" and smart.temperature or {}
  local temperature = validTemperature(temperatureTable.current)
  if temperature == nil and isNvme then
    temperature = validTemperature(nvme.temperature)
  end
  if temperature == nil then
    temperature = rawAttribute(firstAttribute(attributes, {
      "Temperature_Celsius", "Airflow_Temperature_Cel", "Temperature_Internal",
    }))
  end
  temperature = validTemperature(temperature)
  local temperatureSensors = {}
  if type(nvme.temperature_sensors) == "table" then
    for _, sensor in ipairs(nvme.temperature_sensors) do
      local parsed = validTemperature(sensor)
      if parsed ~= nil then
        table.insert(temperatureSensors, parsed)
      end
    end
  end
  local hotspotTemperature = temperature
  for _, sensor in ipairs(temperatureSensors) do
    hotspotTemperature = hotspotTemperature == nil and sensor or math.max(hotspotTemperature, sensor)
  end
  local smartMessages = {}
  local hasCollectionError = bitSet(smartExitStatus, 0) or bitSet(smartExitStatus, 1) or bitSet(smartExitStatus, 2)
  for _, message in ipairs(smartctl.messages or {}) do
    if type(message) == "table" then
      local text = tostring(message.string or "")
      if text ~= "" then
        table.insert(smartMessages, { severity = tostring(message.severity or "info"), message = text })
        if tostring(message.severity or ""):lower() == "error" then
          hasCollectionError = true
        end
      end
    end
  end

  local percentageUsed
  local life
  local lifeEstimated = false
  local dataRead
  local dataWritten
  local powerOnHours
  local powerCycles
  local unsafeShutdowns
  local mediaErrors
  local errorEntries
  local spare
  local criticalWarning
  local spareThreshold
  local warningTemperatureTime
  local criticalTemperatureTime

  if isNvme then
    percentageUsed = numeric(nvme.percentage_used)
    life = percentageUsed ~= nil and math.floor(clamp(100 - percentageUsed, 0, 100) * 10 + 0.5) / 10 or nil
    local readUnits = integer(nvme.data_units_read)
    local writtenUnits = integer(nvme.data_units_written)
    dataRead = readUnits ~= nil and readUnits * NVME_DATA_UNIT_BYTES or nil
    dataWritten = writtenUnits ~= nil and writtenUnits * NVME_DATA_UNIT_BYTES or nil
    powerOnHours = integer(nvme.power_on_hours)
    powerCycles = integer(nvme.power_cycles)
    unsafeShutdowns = integer(nvme.unsafe_shutdowns)
    mediaErrors = integer(nvme.media_errors)
    errorEntries = integer(nvme.num_err_log_entries)
    spare = numeric(nvme.available_spare)
    spareThreshold = numeric(nvme.available_spare_threshold)
    criticalWarning = integer(nvme.critical_warning)
    warningTemperatureTime = integer(nvme.warning_temp_time)
    criticalTemperatureTime = integer(nvme.critical_comp_time)
  else
    life, lifeEstimated = remainingLife(attributes)
    if life == nil then
      local vendorHealth = firstAttribute(attributes, { "Perc_Write/Erase_Count" })
      local vendorValue = type(vendorHealth) == "table" and numeric(vendorHealth.value) or nil
      if vendorValue ~= nil then
        life = math.floor(clamp(vendorValue, 0, 100) * 10 + 0.5) / 10
        lifeEstimated = true
      end
    end
    percentageUsed = life ~= nil and math.floor((100 - life) * 10 + 0.5) / 10 or nil
    dataRead = ataDataBytes(attributes, "read", blockSize)
    dataWritten = ataDataBytes(attributes, "written", blockSize)
    local powerTime = type(smart.power_on_time) == "table" and smart.power_on_time or {}
    powerOnHours = integer(powerTime.hours)
    powerCycles = rawAttribute(firstAttribute(attributes, { "Power_Cycle_Count" }))
    unsafeShutdowns = rawAttribute(firstAttribute(attributes, {
      "Unsafe_Shutdown_Count", "POR_Recovery_Count", "Unexpect_Power_Loss_Ct",
    }))
    local ataLog = type(smart.ata_smart_error_log) == "table" and smart.ata_smart_error_log or {}
    local summary = type(ataLog.summary) == "table" and ataLog.summary or {}
    mediaErrors = nil
    errorEntries = integer(summary.count)
    local spareAttribute = firstAttribute(attributes, { "Perc_Avail_Resrvd_Space" })
    spare = type(spareAttribute) == "table" and numeric(spareAttribute.value) or nil
  end

  local selfTest = normalizeSelfTest(smart)
  if bitSet(smartExitStatus, 7) and selfTest.state ~= "failed" then
    selfTest.state = "failed"
    selfTest.status = noctalia.tr("self_test.log_failure")
  end

  return {
    health = health,
    temperature_c = temperature,
    hotspot_temperature_c = hotspotTemperature,
    temperature_sensors_c = #temperatureSensors > 0 and temperatureSensors or nil,
    device_warning_temperature_c = validTemperature(temperatureTable.op_limit_max),
    device_critical_temperature_c = validTemperature(temperatureTable.critical_limit_max),
    percentage_used = percentageUsed,
    remaining_life_percent = life,
    remaining_life_estimated = lifeEstimated,
    available_spare_percent = spare,
    available_spare_threshold_percent = spareThreshold,
    data_read_bytes = dataRead,
    data_written_bytes = dataWritten,
    power_on_hours = powerOnHours,
    power_on_hours_saturated = not isNvme and powerOnHours == 65535,
    power_cycles = powerCycles,
    unsafe_shutdowns = unsafeShutdowns,
    media_errors = mediaErrors,
    error_log_entries = errorEntries,
    critical_warning = criticalWarning,
    warning_temperature_time_minutes = warningTemperatureTime,
    critical_temperature_time_minutes = criticalTemperatureTime,
    smartctl_exit_status = smartExitStatus,
    smart_sleeping = smartSleeping,
    smart_power_mode = powerMode.string,
    smart_messages = #smartMessages > 0 and smartMessages or nil,
    smart_completeness = hasCollectionError and "partial" or "full",
    smart_error_log_present = bitSet(smartExitStatus, 6),
    smart_prefail_attribute_now = bitSet(smartExitStatus, 4),
    smart_past_threshold = bitSet(smartExitStatus, 5),
    smart_self_test_log_error = bitSet(smartExitStatus, 7),
    self_test_supported = selfTest.supported,
    self_test_state = selfTest.state,
    self_test_status = selfTest.status,
    self_test_type = selfTest.test_type,
    self_test_lifetime_hours = selfTest.lifetime_hours,
    self_test_completion_percent = selfTest.completion_percent,
    self_test_error_count = selfTest.error_count,
    reallocated_sectors = rawAttribute(firstAttribute(attributes, { "Reallocated_Sector_Ct", "Reallocated_Event_Count" })),
    pending_sectors = rawAttribute(firstAttribute(attributes, { "Current_Pending_Sector" })),
    uncorrectable_errors = maximumRawAttribute(attributes, {
      "Offline_Uncorrectable", "Reported_Uncorrect", "Uncorrectable_Error_Cnt",
    }),
    start_stop_count = rawAttribute(firstAttribute(attributes, { "Start_Stop_Count" })),
    load_cycle_count = rawAttribute(firstAttribute(attributes, { "Load_Cycle_Count" })),
    spin_retry_count = rawAttribute(firstAttribute(attributes, { "Spin_Retry_Count" })),
    command_timeout_count = rawAttribute(firstAttribute(attributes, { "Command_Timeout" })),
    interface_crc_errors = rawAttribute(firstAttribute(attributes, { "UDMA_CRC_Error_Count", "CRC_Error_Count" })),
  }
end

local function conciseSmartError(smart)
  local smartctl = type(smart.smartctl) == "table" and smart.smartctl or {}
  for _, message in ipairs(smartctl.messages or {}) do
    local text = type(message) == "table" and tostring(message.string or "") or tostring(message)
    if text:lower():find("permission denied", 1, true) ~= nil then
      return "Permission denied; install the read-only system collector for full SMART data."
    elseif text ~= "" then
      return text
    end
  end
  return "SMART data unavailable."
end

local function copySmartAttributes(smart)
  local result = {}
  local ata = type(smart.ata_smart_attributes) == "table" and smart.ata_smart_attributes or {}
  for _, item in ipairs(ata.table or {}) do
    if type(item) == "table" then
      local raw = type(item.raw) == "table" and item.raw or {}
      table.insert(result, {
        id = integer(item.id), name = item.name, value = integer(item.value),
        worst = integer(item.worst), threshold = integer(item.thresh),
        raw_value = rawAttribute(item), raw_string = raw.string,
      })
    end
  end
  return result
end

local function hasSmartData(smart)
  return type(smart) == "table" and (
    smart.smart_status ~= nil or smart.nvme_smart_health_information_log ~= nil
      or smart.ata_smart_attributes ~= nil
  )
end

local function summarize(disks)
  local ssdCount = 0
  local hddCount = 0
  local smartAvailable = 0
  local ssdSmartAvailable = 0
  local unhealthy = 0
  local ssdUnhealthy = 0
  local partial = 0
  local ssdPartial = 0
  local selfTestFailures = 0
  local ssdSelfTestFailures = 0
  local sleeping = 0
  local hottest = nil
  local hottestDrive = nil
  local hottestSsd = nil
  local hottestSsdDrive = nil
  local lowestLife = nil
  local lowestLifeDrive = nil
  for _, disk in ipairs(disks) do
    local isSsd = disk.kind == "ssd"
    if isSsd then
      ssdCount += 1
    else
      hddCount += 1
    end
    if disk.smart_available then
      smartAvailable += 1
      if isSsd then ssdSmartAvailable += 1 end
    end
    if disk.smart_sleeping then
      sleeping += 1
    end
    if disk.smart_completeness == "partial" then
      partial += 1
      if isSsd then ssdPartial += 1 end
    end
    if disk.health == "failed" then
      unhealthy += 1
      if isSsd then ssdUnhealthy += 1 end
    end
    if disk.self_test_state == "failed" then
      selfTestFailures += 1
      if isSsd then ssdSelfTestFailures += 1 end
    end
    local temperature = tonumber(isSsd and noctalia.getConfig("use_hotspot_temperature") ~= false
      and disk.hotspot_temperature_c or disk.temperature_c)
    if temperature ~= nil and (hottest == nil or temperature > hottest) then
      hottest = temperature
      hottestDrive = disk
    end
    if isSsd then
      if temperature ~= nil and (hottestSsd == nil or temperature > hottestSsd) then
        hottestSsd = temperature
        hottestSsdDrive = disk
      end
      local life = tonumber(disk.remaining_life_percent)
      if life ~= nil and (lowestLife == nil or life < lowestLife) then
        lowestLife = life
        lowestLifeDrive = disk
      end
    end
  end
  return {
    disk_count = #disks,
    ssd_count = ssdCount,
    hdd_count = hddCount,
    smart_available_count = smartAvailable,
    smart_unavailable_count = #disks - smartAvailable - sleeping,
    sleeping_count = sleeping,
    unhealthy_count = unhealthy,
    partial_smart_count = partial,
    self_test_failure_count = selfTestFailures,
    hottest_drive_temperature_c = hottest,
    hottest_drive_id = hottestDrive and hottestDrive.id or nil,
    hottest_drive_name = hottestDrive and hottestDrive.display_name or nil,
    ssd_smart_available_count = ssdSmartAvailable,
    ssd_smart_unavailable_count = ssdCount - ssdSmartAvailable,
    hdd_smart_available_count = smartAvailable - ssdSmartAvailable,
    hdd_smart_unavailable_count = hddCount - (smartAvailable - ssdSmartAvailable),
    ssd_unhealthy_count = ssdUnhealthy,
    ssd_partial_smart_count = ssdPartial,
    ssd_self_test_failure_count = ssdSelfTestFailures,
    hottest_ssd_temperature_c = hottestSsd,
    hottest_ssd_drive_id = hottestSsdDrive and hottestSsdDrive.id or nil,
    hottest_ssd_drive_name = hottestSsdDrive and hottestSsdDrive.display_name or nil,
    worst_ssd_remaining_life_percent = lowestLife,
    worst_ssd_life_drive_id = lowestLifeDrive and lowestLifeDrive.id or nil,
    worst_ssd_life_drive_name = lowestLifeDrive and lowestLifeDrive.display_name or nil,
  }
end

local function loadDrivePreferences()
  local directory = noctalia.pluginDataDir()
  local path = directory ~= nil and directory .. "/" .. PREFERENCES_FILE or nil
  local encoded = path ~= nil and noctalia.readFile(path) or nil
  local decoded = encoded ~= nil and noctalia.json.decode(encoded) or nil
  if type(decoded) == "table" then
    drivePreferences = decoded
    drivePreferences.schema = 1
    drivePreferences.order = type(decoded.order) == "table" and decoded.order or {}
    drivePreferences.drives = type(decoded.drives) == "table" and decoded.drives or {}
  end
  noctalia.state.set("drive_preferences", drivePreferences)
end

local function preferenceFor(id)
  local preferences = type(drivePreferences.drives) == "table" and drivePreferences.drives or {}
  return type(preferences[id]) == "table" and preferences[id] or {}
end

local function orderFor(id)
  for index, value in ipairs(drivePreferences.order or {}) do
    if tostring(value) == tostring(id) then
      return index
    end
  end
  return 100000
end

local function systemCollectorState(raw, source)
  local pluginDirectory = noctalia.pluginDir()
  local enabled = systemCollectorEnabled()
  local installed = noctalia.fileExists(SYSTEM_LIBEXEC .. "/collect_raw.sh")
  local reportedVersion = type(raw) == "table" and tostring(raw.collector_version or "") or ""
  local version = source == "system-cache" and reportedVersion or ""
  local status
  if not enabled then
    status = "disabled"
  elseif source == "system-cache" and version == EXPECTED_COLLECTOR_VERSION then
    status = "healthy"
  elseif source == "system-cache" and version ~= EXPECTED_COLLECTOR_VERSION then
    status = "upgrade-required"
  elseif installed then
    status = "stale"
  else
    status = "not-installed"
  end
  return {
    enabled = enabled,
    installed = installed,
    status = status,
    version = version ~= "" and version or nil,
    expected_version = EXPECTED_COLLECTOR_VERSION,
    helper_installed = noctalia.fileExists(SYSTEM_LIBEXEC .. "/smart-action.sh"),
    helper_available = enabled
      and noctalia.fileExists(SYSTEM_LIBEXEC .. "/smart-action.sh"),
    authorization_available = noctalia.commandExists("pkexec"),
    install_command = pluginDirectory ~= nil and "sudo "
      .. shellQuote(pluginDirectory .. "/packaging/install-system-collector.sh") or nil,
    uninstall_command = pluginDirectory ~= nil and "sudo "
      .. shellQuote(pluginDirectory .. "/packaging/uninstall-system-collector.sh") or nil,
    enable_command = installed and noctalia.commandExists("systemctl")
      and "sudo systemctl enable --now " .. SYSTEM_NAMESPACE .. ".timer"
        .. " && sudo systemctl start " .. SYSTEM_NAMESPACE .. ".service" or nil,
    disable_command = installed and noctalia.commandExists("systemctl")
      and "sudo systemctl disable --now " .. SYSTEM_NAMESPACE .. ".timer"
        .. " && sudo systemctl stop " .. SYSTEM_NAMESPACE .. ".service" or nil,
  }
end

local function normalizeRaw(raw, source)
  if type(raw) ~= "table" or tonumber(raw.schema) ~= 2 then
    return nil, "Unsupported raw SMART cache schema."
  end
  local lsblk = type(raw.lsblk) == "table" and raw.lsblk or {}
  local smartByDevice = {}
  for _, entry in ipairs(raw.smart or {}) do
    if type(entry) == "table" then
      local smart = type(entry.payload) == "table" and entry.payload or entry
      smart._collector_exit_code = entry.exit_code
      local device = type(smart.device) == "table" and smart.device or {}
      if entry.requested_device ~= nil then
        smartByDevice[tostring(entry.requested_device)] = smart
      end
      if device.name ~= nil then
        smartByDevice[tostring(device.name)] = smart
      end
    end
  end

  local disks = {}
  for _, block in ipairs(lsblk.blockdevices or {}) do
    local device = tostring(block.path or ("/dev/" .. tostring(block.name or "")))
    local name = tostring(block.name or "")
    local virtual = name:match("^zram") or name:match("^loop") or name:match("^ram") or name:match("^sr")
    if block.type == "disk" and device:match("^/dev/") and not virtual then
      local smartDevice = smartDeviceFor(device)
      local smart = smartByDevice[smartDevice] or smartByDevice[device] or {}
      local smartAvailable = hasSmartData(smart)
      local blockSize = integer(smart.logical_block_size) or integer(block["log-sec"]) or 512
      local values = normalizeSmart(smart, blockSize)
      if not smartAvailable then
        values.smart_completeness = "unavailable"
      end
      if values.temperature_c == nil then
        values.temperature_c = sysfsTemperature(device)
      end
      if values.hotspot_temperature_c == nil then
        values.hotspot_temperature_c = values.temperature_c
      end
      local used, available, usagePercent, mountPoints = mountedUsage(block)
      local rotational = block.rota == true or tonumber(block.rota) == 1
      local serial = noctalia.string.trim(tostring(block.serial or ""))
      local model = noctalia.string.trim(tostring(block.model or ""))
      local namespace = name:match("^nvme%d+(n%d+)$")
      local id = serial ~= "" and serial .. (namespace ~= nil and ":" .. namespace or "")
        or tostring(block.kname or device)
      local preferences = preferenceFor(id)
      local removable = block.rm == true or tonumber(block.rm) == 1 or block.hotplug == true or tonumber(block.hotplug) == 1
      local transport = tostring(block.tran or "unknown")
      local defaultPresenceAlert = not removable and transport ~= "usb"
      local drive = {
        id = id,
        device = device,
        smart_device = smartDevice,
        model = model ~= "" and model or name,
        display_name = tostring(preferences.alias or "") ~= "" and tostring(preferences.alias) or (model ~= "" and model or name),
        serial = serial ~= "" and serial or nil,
        transport = transport,
        kind = rotational and "hdd" or "ssd",
        removable = removable,
        hidden = preferences.hidden == true,
        alerts_enabled = preferences.alerts_enabled ~= false,
        presence_alert_enabled = preferences.presence_alert_enabled == nil and defaultPresenceAlert
          or preferences.presence_alert_enabled == true,
        warning_temperature = numeric(preferences.warning_temperature),
        critical_temperature = numeric(preferences.critical_temperature),
        life_warning_percent = numeric(preferences.life_warning_percent),
        display_order = orderFor(id),
        capacity_bytes = integer(block.size),
        storage_used_bytes = used,
        storage_available_bytes = available,
        storage_usage_percent = usagePercent,
        mount_points = #mountPoints > 0 and mountPoints or nil,
        smart_available = smartAvailable,
        smart_error = not smartAvailable and not values.smart_sleeping and conciseSmartError(smart) or nil,
      }
      for key, value in pairs(values) do
        drive[key] = value
      end
      local attributes = copySmartAttributes(smart)
      if #attributes > 0 then
        drive.smart_attributes = attributes
      end
      table.insert(disks, drive)
    end
  end

  table.sort(disks, function(left, right)
    if left.display_order ~= right.display_order then
      return left.display_order < right.display_order
    elseif left.kind ~= right.kind then
      return left.kind == "ssd"
    elseif left.transport ~= right.transport then
      return left.transport < right.transport
    end
    return left.device < right.device
  end)

  local epoch = integer(raw.generated_at_epoch) or os.time()
  local smartCount = 0
  for _, disk in ipairs(disks) do
    if disk.smart_available then
      smartCount += 1
    end
  end
  return {
    schema = 1,
    collection_id = validCollectionId(raw.collection_id),
    generated_at = tostring(epoch),
    generated_at_epoch = epoch,
    generated_at_local = noctalia.formatTime("%H:%M:%S", epoch),
    collector_version = raw.collector_version,
    source = source or "direct",
    access = #disks > 0 and smartCount == #disks and "full"
      or (smartCount > 0 and "partial" or "unavailable"),
    disks = disks,
    summary = summarize(disks),
    system_collector = systemCollectorState(raw, source or "direct"),
  }, nil
end

local function detectedPackageManager()
  for _, manager in ipairs(PACKAGE_MANAGERS) do
    if noctalia.commandExists(manager.command) then
      return manager
    end
  end
  return nil
end

local startDependencyProbe

local function forceDependencyProbe()
  if dependencyProbe.running then
    dependencyProbe.forcedPending = true
    return
  end
  dependencyProbe.checked = false
  dependencyProbe.incompatible = {}
  startDependencyProbe()
end

startDependencyProbe = function()
  if dependencyProbe.checked or dependencyProbe.running
      or not noctalia.commandExists("lsblk") or not noctalia.commandExists("smartctl") then
    return
  end
  dependencyProbe.running = true
  local command = "if lsblk --json --bytes --output NAME,TYPE >/dev/null 2>&1; then "
    .. "printf 'lsblk=ok\\n'; else printf 'lsblk=bad\\n'; fi; "
    .. "if smartctl --json=c --version >/dev/null 2>&1; then "
    .. "printf 'smartctl=ok\\n'; else printf 'smartctl=bad\\n'; fi"
  local launched = noctalia.runAsync(command, function(result)
    dependencyProbe.running = false
    dependencyProbe.checked = true
    local output = tostring(result.stdout or "")
    local probeFailed = result.timedOut == true or tonumber(result.exitCode) ~= 0
    dependencyProbe.incompatible = {
      lsblk = probeFailed or output:find("lsblk=ok", 1, true) == nil,
      smartctl = probeFailed or output:find("smartctl=ok", 1, true) == nil,
    }
    dependencyProbeGeneration += 1
    noctalia.state.set("dependency_probe_generation", dependencyProbeGeneration)
    if dependencyProbe.forcedPending then
      dependencyProbe.forcedPending = false
      forceDependencyProbe()
    end
  end, 5000)
  if not launched then
    dependencyProbe.running = false
    dependencyProbe.checked = true
    dependencyProbe.incompatible = { lsblk = true, smartctl = true }
    if dependencyProbe.forcedPending then
      dependencyProbe.forcedPending = false
      forceDependencyProbe()
    end
  end
end

local function checkDependencies()
  startDependencyProbe()
  local missing = {}
  local blocking = false
  for _, dependency in ipairs(DEPENDENCIES) do
    local exists = noctalia.commandExists(dependency.command)
    if not exists or dependencyProbe.incompatible[dependency.command] == true then
      dependency.incompatible = exists
      table.insert(missing, dependency)
      blocking = blocking or dependency.blocking
    end
  end
  local manager = detectedPackageManager()
  local packages = {}
  local seen = {}
  local labels = {}
  local signatureParts = {}
  for _, dependency in ipairs(missing) do
    table.insert(labels, dependency.incompatible
      and dependency.label .. " (installed but incompatible)"
      or dependency.label .. " (" .. dependency.command .. ")")
    table.insert(signatureParts, dependency.command)
    local packageName = manager ~= nil and dependency.packages[manager.id] or nil
    if packageName ~= nil and not seen[packageName] then
      seen[packageName] = true
      table.insert(packages, packageName)
    end
  end
  table.sort(signatureParts)
  local installCommand = nil
  if manager ~= nil and #packages > 0 and noctalia.commandExists("sudo") then
    installCommand = manager.prefix .. table.concat(packages, " ")
  end
  local signature = table.concat(signatureParts, ",")
  local logSignature = signature == "" and "ready" or signature
  if logSignature ~= loggedDependencySignature then
    loggedDependencySignature = logSignature
    noctalia.log(signature == "" and "Dependency check passed: lsblk and smartctl are available."
      or "Dependency check found missing commands: " .. table.concat(labels, ", "))
  end
  return {
    ready = #missing == 0,
    blocking = blocking,
    missing = labels,
    missing_text = table.concat(labels, ", "),
    signature = signature,
    package_manager = manager ~= nil and manager.label or nil,
    install_command = installCommand,
    can_install = installCommand ~= nil,
    checking = dependencyProbe.running,
  }
end

local function freshJson(path)
  local info = noctalia.fileInfo(path)
  if type(info) ~= "table" or info.isDir or tonumber(info.mtime) == nil then
    return nil
  end
  local age = os.time() - tonumber(info.mtime)
  if age < 0 or age > CACHE_MAX_AGE_SECONDS then
    return nil
  end
  local encoded = noctalia.readFile(path)
  if encoded == nil then
    return nil
  end
  return noctalia.json.decode(encoded)
end

local function publishError(message, dependencies)
  local snapshot = noctalia.state.get("collector_snapshot") or {}
  snapshot.collecting = false
  snapshot.collector_error = message
  snapshot.dependencies = dependencies
  snapshot.summary = snapshot.summary or {}
  snapshot.system_collector = systemCollectorState(nil, "error")
  noctalia.state.set("collector_snapshot", snapshot)
end

local function publish(snapshot, dependencies)
  snapshot.collecting = false
  snapshot.collector_error = nil
  snapshot.dependencies = dependencies
  local collector = snapshot.system_collector
  if type(collector) == "table" and collector.enabled == true
      and collector.status == "upgrade-required" then
    local signature = tostring(collector.version or "unknown")
      .. "->" .. tostring(collector.expected_version or "unknown")
    if signature ~= notifiedCollectorUpgradeSignature then
      notifiedCollectorUpgradeSignature = signature
      noctalia.notify(noctalia.tr("collector.update_title"), noctalia.tr("collector.update_body", {
        current = tostring(collector.version or noctalia.tr("common.unknown")),
        expected = tostring(collector.expected_version or noctalia.tr("common.unknown")),
      }))
    end
  end
  noctalia.state.set("collector_snapshot", snapshot)
end

local function collect()
  if collecting then
    return
  end
  local dependencies = checkDependencies()
  if dependencies.blocking then
    publishError(noctalia.tr("dependencies.collection_blocked", { missing = dependencies.missing_text }), dependencies)
    return
  end

  if systemCollectorEnabled() then
    local rawCache = freshJson(RAW_CACHE)
    if type(rawCache) == "table" and tonumber(rawCache.schema) == 2 then
      local snapshot, normalizeError = normalizeRaw(rawCache, "system-cache")
      if snapshot ~= nil then
        publish(snapshot, dependencies)
        return
      end
      noctalia.log("Raw SMART cache rejected: " .. tostring(normalizeError))
    end
  end

  local pluginDir = noctalia.pluginDir()
  if pluginDir == nil or pluginDir == "" then
    publishError("Cannot resolve the plugin directory.", dependencies)
    return
  end

  collecting = true
  local current = noctalia.state.get("collector_snapshot") or {}
  current.collecting = true
  current.dependencies = dependencies
  noctalia.state.set("collector_snapshot", current)
  local command = "sh " .. shellQuote(pluginDir .. "/scripts/collect_raw.sh")
  local launched = noctalia.runAsync(command, function(result)
    collecting = false
    local resolvedDependencies = checkDependencies()
    if result.timedOut then
      publishError("SMART collection timed out.", resolvedDependencies)
      return
    elseif result.exitCode ~= 0 then
      local reason = noctalia.string.trim(result.stderr or "")
      publishError(reason ~= "" and reason or "SMART collection failed.", resolvedDependencies)
      return
    end
    local raw, decodeError = noctalia.json.decode(result.stdout or "")
    if raw == nil then
      publishError("Invalid raw collector response: " .. tostring(decodeError or "unknown JSON error"), resolvedDependencies)
      return
    end
    local snapshot, normalizeError = normalizeRaw(raw, "direct")
    if snapshot == nil then
      publishError(tostring(normalizeError or "SMART normalization failed."), resolvedDependencies)
      return
    end
    publish(snapshot, resolvedDependencies)
  end, 60000)
  if not launched then
    collecting = false
    publishError("Noctalia could not start the SMART collector.", dependencies)
  end
end

loadDrivePreferences()

noctalia.state.watch("drive_preferences", function(value)
  if type(value) == "table" then
    drivePreferences = value
    drivePreferences.order = type(value.order) == "table" and value.order or {}
    drivePreferences.drives = type(value.drives) == "table" and value.drives or {}
    collect()
  end
end)

noctalia.state.watch("refresh_nonce", function(value)
  local nextNonce = tonumber(value) or 0
  if nextNonce ~= refreshNonce then
    refreshNonce = nextNonce
    forceDependencyProbe()
    collect()
  end
end)

noctalia.state.watch("dependency_probe_generation", function(value)
  local generation = tonumber(value) or 0
  if generation > dependencyProbeGeneration then
    dependencyProbeGeneration = generation
  end
  collect()
end)

noctalia.setUpdateInterval(30000)

function update()
  collect()
end

function onConfigChanged()
  local seconds = tonumber(noctalia.getConfig("refresh_seconds")) or 30
  noctalia.setUpdateInterval(math.max(15, math.min(300, seconds)) * 1000)
  collect()
end

function onIpc(event, _payload)
  if event == "check-dependencies" then
    forceDependencyProbe()
    collect()
  elseif event == "refresh" then
    collect()
  elseif event == "test-alert" then
    noctalia.notify(noctalia.tr("alerts.test_title"), noctalia.tr("alerts.test_body"))
  elseif event == "export-snapshot" then
    local snapshot = noctalia.state.get("collector_snapshot")
    local directory = noctalia.pluginDataDir()
    local encoded = snapshot ~= nil and noctalia.json.encode(snapshot, true) or nil
    if directory ~= nil and encoded ~= nil then
      noctalia.writeFile(directory .. "/last-collector-snapshot.json", encoded)
    end
  end
end

onConfigChanged()
