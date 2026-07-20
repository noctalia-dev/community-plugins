-- Unit and initialization tests for collector.luau using a minimal Noctalia
-- host mock. This runs with stock Lua after lowering Luau compound assignment.

local mode = arg[1] or "ready"
local state = {}
local launchedCommand = nil
local launchedCommands = {}
local logs = {}
local notifications = {}
local files = {}
local directories = {}
local watchers = {}
local pendingProbeCallback = nil
local probeCalls = 0
local probeAction = nil
local collectorEnabled = mode == "raw-cache" or mode == "outdated-raw-cache"
  or mode == "legacy-raw-cache" or mode == "legacy-cache"

local available = {
  lsblk = mode ~= "missing-lsblk",
  smartctl = mode ~= "missing-smartctl",
  pacman = true,
  sudo = true,
  pkexec = true,
  systemctl = true,
}

local rawFixture = {
  schema = 2,
  collector_version = mode == "outdated-raw-cache" and "0.6.0"
    or mode == "legacy-raw-cache" and "1.0.0" or "2.0.0",
  collection_id = "fixture-collection-id",
  generated_at_epoch = 1700000000,
  lsblk = { blockdevices = {} },
  smart = {},
}

local legacyFixture = {
  schema = 1,
  generated_at_epoch = 1700000000,
  disks = {},
  summary = { disk_count = 0, ssd_count = 0, smart_available_count = 0 },
}

local function translate(key, substitutions)
  local value = key
  for name, replacement in pairs(substitutions or {}) do
    value = value:gsub("{" .. name .. "}", tostring(replacement))
  end
  return value
end

noctalia = {
  commandExists = function(command) return available[command] == true end,
  getConfig = function(key)
    if key == "system_collector_enabled" then
      return collectorEnabled
    end
    return nil
  end,
  pluginDir = function() return "/mock/plugin" end,
  pluginDataDir = function() return "/mock/plugin-data" end,
  fileInfo = function(path)
    if mode == "legacy-raw-cache" and path == "/run/noctalia-smart-monitor/raw.json" then
      return { isDir = false, mtime = os.time() }
    end
    if (mode == "raw-cache" or mode == "outdated-raw-cache" or mode == "collector-disabled")
        and path ~= "/run/noctalia-smart-monitor/raw.json" and path:match("raw%.json$") then
      return { isDir = false, mtime = os.time() }
    elseif mode == "legacy-cache" and path:match("smart%.json$") then
      return { isDir = false, mtime = os.time() }
    end
    return nil
  end,
  fileExists = function(path) return files[path] ~= nil end,
  listDir = function(path) return directories[path] or {} end,
  readFile = function(path)
    if mode == "legacy-raw-cache" and path == "/run/noctalia-smart-monitor/raw.json" then
      return "raw-cache"
    end
    if (mode == "raw-cache" or mode == "outdated-raw-cache" or mode == "collector-disabled")
        and path ~= "/run/noctalia-smart-monitor/raw.json" and path:match("raw%.json$") then
      return "raw-cache"
    end
    if mode == "legacy-cache" and path:match("smart%.json$") then return "legacy-cache" end
    return files[path]
  end,
  writeFile = function(path, contents) files[path] = contents return true end,
  log = function(message) table.insert(logs, message) end,
  notify = function(title, body) table.insert(notifications, { title = title, body = body }) end,
  tr = translate,
  formatTime = function(_pattern, _epoch) return "22:13:20" end,
  setUpdateInterval = function(_milliseconds) end,
  state = {
    get = function(key) return state[key] end,
    set = function(key, value)
      state[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  json = {
    decode = function(raw)
      if raw == "legacy-cache" then return legacyFixture end
      return rawFixture
    end,
    encode = function(_value, _pretty) return "{}" end,
  },
  string = {
    trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
  },
  runAsync = function(command, callback, _timeout)
    launchedCommand = command
    table.insert(launchedCommands, command)
    if command:match("lsblk=ok") then
      probeCalls = probeCalls + 1
      if probeAction == "pending" then
        assert(pendingProbeCallback == nil, "dependency probes overlapped")
        pendingProbeCallback = callback
        return true
      end
      if probeAction == "launch-failure" then
        probeAction = nil
        return false
      end
      if type(probeAction) == "table" then
        local response = probeAction
        probeAction = nil
        callback(response)
        return true
      end
      if mode == "async-incompatible-lsblk" or mode == "probe-completes-during-collection" then
        pendingProbeCallback = callback
        return true
      end
      if mode == "probe-timeout" then
        callback({ exitCode = 124, stdout = "", stderr = "", timedOut = true })
        return true
      end
      local lsblk = mode == "incompatible-lsblk" and "bad" or "ok"
      local smartctl = mode == "incompatible-smartctl" and "bad" or "ok"
      callback({ exitCode = 0, stdout = "lsblk=" .. lsblk .. "\nsmartctl=" .. smartctl .. "\n",
        stderr = "", timedOut = false })
    else
      if mode == "probe-completes-during-collection" and pendingProbeCallback ~= nil then
        local probe = pendingProbeCallback
        pendingProbeCallback = nil
        probe({ exitCode = 0, stdout = "lsblk=bad\nsmartctl=ok\n", stderr = "", timedOut = false })
      end
      callback({ exitCode = 0, stdout = "{}", stderr = "", timedOut = false })
    end
    return true
  end,
}

local handle = assert(io.open("collector.luau", "rb"))
local source = handle:read("*a")
handle:close()
source = source:gsub("local function mountedUsage", "function mountedUsage")
source = source:gsub("local function normalizeSmart", "function normalizeSmart")
source = source:gsub("local function normalizeRaw", "function normalizeRaw")
source = source:gsub("local function publishError", "function publishError")
source = source:gsub("([%a_][%w_]*) %+%= ([^\n]+)", "%1 = %1 + %2")
assert(load(source, "@collector.luau"))()

local snapshot = assert(state.collector_snapshot, "collector did not publish an initialization snapshot")
local dependencies = assert(snapshot.dependencies, "snapshot has no dependency state")

if mode == "probe-completes-during-collection" then
  assert(dependencies.ready == false and dependencies.blocking == true,
    "collector published stale dependency state when the probe completed during collection")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "async-incompatible-lsblk" then
  assert(dependencies.ready == true and pendingProbeCallback ~= nil,
    "asynchronous capability probe was not pending")
  pendingProbeCallback({ exitCode = 0, stdout = "lsblk=bad\nsmartctl=ok\n", stderr = "", timedOut = false })
  dependencies = assert(state.collector_snapshot.dependencies)
  assert(dependencies.ready == false and dependencies.blocking == true,
    "completed capability probe did not immediately refresh dependency state")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "probe-timeout" then
  assert(dependencies.ready == false and dependencies.blocking == true,
    "failed capability probe incorrectly reported dependencies ready")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "missing-lsblk" then
  assert(dependencies.ready == false and dependencies.blocking == true, "missing lsblk was not blocking")
  assert(dependencies.install_command == "sudo pacman -S --needed util-linux", "wrong lsblk install command")
  assert(launchedCommand == nil, "collector launched without lsblk")
  assert(snapshot.collector_error ~= nil, "blocking dependency did not publish an error")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "missing-smartctl" then
  assert(dependencies.ready == false and dependencies.blocking == false, "missing smartctl blocked inventory")
  assert(dependencies.install_command == "sudo pacman -S --needed smartmontools", "wrong smartctl install command")
  assert(launchedCommand and launchedCommand:match("collect_raw%.sh"), "fallback collector did not launch")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "raw-cache" then
  assert(snapshot.source == "system-cache", "raw cache was not normalized")
  assert(snapshot.collection_id == "fixture-collection-id", "raw cache lost its collection ID")
  assert(snapshot.system_collector.status == "healthy"
    and snapshot.system_collector.version == "2.0.0"
    and snapshot.system_collector.expected_version == "2.0.0",
    "current system collector was not reported healthy")
  assert(not (launchedCommand or ""):match("collect_raw%.sh"), "collector launched despite a fresh raw cache")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "outdated-raw-cache" then
  assert(snapshot.source == "system-cache", "outdated raw cache was not normalized")
  assert(snapshot.system_collector.status == "upgrade-required"
    and snapshot.system_collector.version == "0.6.0"
    and snapshot.system_collector.expected_version == "2.0.0",
    "older system collector did not request an upgrade")
  assert(not (launchedCommand or ""):match("collect_raw%.sh"), "collector launched despite a fresh raw cache")
  assert(#notifications == 1 and notifications[1].title == "collector.update_title"
    and notifications[1].body == "collector.update_body",
    "enabled outdated collector did not produce one coordinated update notice")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "legacy-raw-cache" then
  assert(snapshot.source == "system-cache", "legacy raw cache was not normalized")
  assert(snapshot.system_collector.status == "upgrade-required"
    and snapshot.system_collector.version == "1.0.0"
    and snapshot.system_collector.expected_version == "2.0.0",
    "legacy raw collector cache did not request an upgrade")
  assert(not (launchedCommand or ""):match("collect_raw%.sh"),
    "collector launched despite a fresh legacy raw cache")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "collector-disabled" then
  assert(snapshot.source == "direct", "disabled collector still consumed the privileged cache")
  assert(snapshot.system_collector.enabled == false and snapshot.system_collector.status == "disabled",
    "disabled collector did not publish Basic-mode state")
  assert((launchedCommand or ""):match("collect_raw%.sh"),
    "disabled collector did not fall back to direct Basic collection")
  assert(#notifications == 0, "disabled collector produced an update or installation notification")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "legacy-cache" then
  assert(snapshot.source == "legacy-system-cache", "legacy cache migration failed")
  assert(not (launchedCommand or ""):match("collect_raw%.sh"), "collector launched despite a fresh legacy cache")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "incompatible-lsblk" then
  assert(dependencies.ready == false and dependencies.blocking == true, "incompatible lsblk was not blocking")
  assert(dependencies.missing_text:match("incompatible"), "incompatible lsblk was not explained")
  assert(not (launchedCommand or ""):match("collect_raw%.sh"), "collector launched with incompatible lsblk")
  print("collector initialization test passed: " .. mode)
  return
elseif mode == "incompatible-smartctl" then
  assert(dependencies.ready == false and dependencies.blocking == false, "incompatible smartctl blocked inventory")
  assert(dependencies.missing_text:match("incompatible"), "incompatible smartctl was not explained")
  assert((launchedCommand or ""):match("collect_raw%.sh"), "fallback inventory did not launch")
  print("collector initialization test passed: " .. mode)
  return
end

assert(dependencies.ready == true, "available dependencies were reported missing")
assert(launchedCommand and launchedCommand:match("collect_raw%.sh"), "raw collector was not launched")
assert(snapshot.system_collector.authorization_available == true,
  "available Polkit authorization was not exposed to the panel")

local nvme = normalizeSmart({
  smart_status = { passed = true },
  temperature = { current = 55 },
  nvme_smart_health_information_log = {
    available_spare = 100, available_spare_threshold = 25, percentage_used = 3,
    temperature_sensors = { 74, 59, 55 },
    data_units_read = 10, data_units_written = 20,
    power_cycles = 7, power_on_hours = 100, unsafe_shutdowns = 2,
    media_errors = 0, num_err_log_entries = 0, critical_warning = 0,
    warning_temp_time = 4, critical_comp_time = 1,
  },
  nvme_self_test_log = {
    current_self_test_operation = { value = 0, string = "No self-test in progress" },
    table = { { self_test_code = { value = 1, string = "Short" },
      self_test_result = { value = 0, string = "Completed without error" }, power_on_hours = 99 } },
  },
})
assert(nvme.health == "passed" and nvme.temperature_c == 55, "NVMe health normalization failed")
assert(nvme.hotspot_temperature_c == 74 and #nvme.temperature_sensors_c == 3, "NVMe hotspot normalization failed")
assert(nvme.remaining_life_percent == 97, "NVMe endurance normalization failed")
assert(nvme.data_written_bytes == 20 * 512000, "NVMe data-unit conversion failed")
assert(nvme.available_spare_threshold_percent == 25, "NVMe spare threshold normalization failed")
assert(nvme.self_test_state == "passed" and nvme.self_test_supported, "NVMe self-test normalization failed")

local runningNvme = normalizeSmart({
  smart_status = { passed = true },
  nvme_smart_health_information_log = { percentage_used = 1 },
  nvme_self_test_log = {
    current_self_test_operation = { value = 1, string = "Short self-test in progress" },
    current_self_test_completion_percent = 37,
  },
})
assert(runningNvme.self_test_state == "running" and runningNvme.self_test_completion_percent == 37,
  "NVMe self-test completion was not normalized")

local runningAta = normalizeSmart({
  smart_status = { passed = true },
  ata_smart_self_test_log = { standard = { table = { {
    status = { value = 249, string = "Self-test routine in progress", remaining_percent = 80 },
  } } } },
})
assert(runningAta.self_test_state == "running" and runningAta.self_test_completion_percent == 20,
  "ATA remaining self-test percentage was not converted to completion")

local samsung = normalizeSmart({
  smart_status = { passed = true },
  power_on_time = { hours = 83062 },
  ata_smart_error_log = { summary = { count = 5 } },
  ata_smart_attributes = { table = {
    { name = "Wear_Leveling_Count", value = 90, raw = { value = 194 } },
    { name = "Total_LBAs_Written", value = 99, raw = { value = 210090409618 } },
    { name = "Airflow_Temperature_Cel", value = 61, raw = { value = 39 } },
    { name = "Reallocated_Sector_Ct", value = 100, raw = { value = 0 } },
  } },
})
assert(samsung.remaining_life_percent == 90, "Samsung wear normalization failed")
assert(samsung.remaining_life_estimated == true, "vendor ATA life was not marked estimated")
assert(samsung.temperature_c == 39, "Samsung temperature normalization failed")
assert(samsung.data_written_bytes == 210090409618 * 512, "Samsung LBA conversion failed")
assert(samsung.reallocated_sectors == 0, "Samsung integrity counter normalization failed")
assert(samsung.media_errors == nil and samsung.error_log_entries == 5, "ATA error log was misclassified as media errors")

local hdd = normalizeSmart({
  smart_status = { passed = true },
  power_on_time = { hours = 113397 },
  ata_smart_attributes = { table = {
    { name = "Start_Stop_Count", value = 98, raw = { value = 1423 } },
    { name = "Load_Cycle_Count", value = 92, raw = { value = 18421 } },
    { name = "Spin_Retry_Count", value = 100, raw = { value = 0 } },
    { name = "Command_Timeout", value = 100, raw = { value = 3 } },
    { name = "UDMA_CRC_Error_Count", value = 200, raw = { value = 2 } },
    { name = "Offline_Uncorrectable", value = 100, raw = { value = 0 } },
    { name = "Reported_Uncorrect", value = 100, raw = { value = 4 } },
  } },
})
assert(hdd.start_stop_count == 1423 and hdd.load_cycle_count == 18421,
  "HDD mechanical cycle counters were not normalized")
assert(hdd.spin_retry_count == 0 and hdd.command_timeout_count == 3 and hdd.interface_crc_errors == 2,
  "HDD transport and spindle counters were not normalized")
assert(hdd.uncorrectable_errors == 4,
  "HDD uncorrectable normalization ignored a nonzero counter after a zero counter")

local partial = normalizeSmart({
  smart_status = { passed = true },
  smartctl = { exit_status = 4, messages = { { severity = "error", string = "Optional log unavailable" } } },
  nvme_smart_health_information_log = { percentage_used = 1 },
})
assert(partial.health == "passed" and partial.smart_completeness == "partial", "partial SMART result was not preserved")
assert(partial.smart_messages[1].message == "Optional log unavailable", "SMART diagnostic message was lost")

local currentPrefail = normalizeSmart({
  smart_status = { passed = true }, smartctl = { exit_status = 16 },
})
assert(currentPrefail.health == "failed" and currentPrefail.smart_prefail_attribute_now == true,
  "current pre-failure threshold bit did not fail health")
local historicalThreshold = normalizeSmart({
  smart_status = { passed = true }, smartctl = { exit_status = 32 },
})
assert(historicalThreshold.health == "passed" and historicalThreshold.smart_past_threshold == true,
  "historical threshold bit incorrectly failed current health")
local failedSelfTestLog = normalizeSmart({
  smart_status = { passed = true }, smartctl = { exit_status = 128 },
})
assert(failedSelfTestLog.self_test_state == "failed" and failedSelfTestLog.smart_self_test_log_error == true,
  "failed self-test log bit was ignored")

local sandisk = normalizeSmart({
  smart_status = { passed = true },
  ata_smart_attributes = { table = {
    { name = "Lifetime_Remaining%", value = 99, raw = { value = 99 } },
    { name = "Total_Writes_GiB", value = 253, raw = { value = 43210 } },
    { name = "Total_Reads_GiB", value = 253, raw = { value = 8765 } },
    { name = "Unexpect_Power_Loss_Ct", value = 100, raw = { value = 12 } },
  } },
})
assert(sandisk.remaining_life_percent == 99, "SanDisk endurance normalization failed")
assert(sandisk.data_written_bytes == 43210 * 1024 ^ 3, "SanDisk write conversion failed")
assert(sandisk.data_read_bytes == 8765 * 1024 ^ 3, "SanDisk read conversion failed")
assert(sandisk.unsafe_shutdowns == 12, "SanDisk unsafe shutdown normalization failed")

local ambiguousHostWrites = normalizeSmart({
  smart_status = { passed = true },
  ata_smart_attributes = { table = {
    { name = "Host_Writes", value = 99, raw = { value = 123456 } },
    { name = "Host_Reads", value = 99, raw = { value = 654321 } },
  } },
})
assert(ambiguousHostWrites.data_written_bytes == nil and ambiguousHostWrites.data_read_bytes == nil,
  "unitless ATA host counters were incorrectly treated as LBAs")

local estimated = normalizeSmart({
  smart_status = { passed = true },
  ata_smart_attributes = { table = {
    { name = "Perc_Write/Erase_Count", value = 83, raw = { value = 590 } },
  } },
})
assert(estimated.remaining_life_percent == 83 and estimated.remaining_life_estimated, "vendor life fallback failed")
assert(estimated.percentage_used == 17, "vendor life usage calculation failed")

local reserveOnly = normalizeSmart({
  smart_status = { passed = true },
  ata_smart_attributes = { table = {
    { name = "Perc_Avail_Resrvd_Space", value = 97, raw = { value = 97 } },
  } },
})
assert(reserveOnly.remaining_life_percent == nil, "reserve space must not be treated as remaining life")
assert(reserveOnly.percentage_used == nil, "reserve space must not produce a used-life percentage")
assert(not reserveOnly.remaining_life_estimated, "reserve space must not be marked as estimated life")
assert(reserveOnly.available_spare_percent == 97, "vendor spare normalization failed")

local used, availableBytes, usage, mountPoints = mountedUsage({ children = {
  { kname = "nvme0n1p1", mountpoints = { "/home", "/", "/home" }, fsused = 25, fsavail = 75 },
} })
assert(used == 25 and availableBytes == 75 and usage == 25, "mounted usage aggregation failed")
assert(#mountPoints == 2 and mountPoints[1] == "/" and mountPoints[2] == "/home",
  "mount points were not deduplicated and normalized")

files["/sys/class/nvme/nvme9/device/hwmon/hwmon9/temp1_input"] = "47000\n"
directories["/sys/class/nvme/nvme9/device/hwmon"] = { "hwmon9" }
local normalized, normalizeError = normalizeRaw({
  schema = 2,
  collection_id = "fixture-normalized-id",
  generated_at_epoch = 1700000000,
  lsblk = { blockdevices = {
    {
      name = "nvme9n1", kname = "nvme9n1", path = "/dev/nvme9n1", type = "disk",
      tran = "nvme", rota = false, size = 2000000000, model = "Fixture NVMe", serial = "FIXTURE1",
      mountpoints = {}, children = {
        { name = "nvme9n1p1", kname = "nvme9n1p1", path = "/dev/nvme9n1p1", type = "part",
          mountpoints = { "/mnt/work" }, fsused = 250, fsavail = 750 },
      },
    },
  } },
  smart = {
    {
      requested_device = "/dev/nvme9",
      payload = { smartctl = { messages = { { string = "Permission denied" } } } },
    },
  },
}, "test")
assert(normalized ~= nil and normalizeError == nil, "raw normalization failed")
assert(normalized.collection_id == "fixture-normalized-id", "raw normalization lost its collection ID")
assert(normalized.summary.ssd_count == 1 and normalized.disks[1].id == "FIXTURE1:n1", "drive discovery failed")
assert(normalized.disks[1].temperature_c == 47, "sysfs temperature fallback failed")
assert(normalized.disks[1].mount_points[1] == "/mnt/work",
  "normalized drive omitted its mounted folder")
assert(normalized.disks[1].smart_available == false, "permission failure incorrectly marked SMART available")
assert(normalized.disks[1].smart_error:match("Permission denied"), "permission error was not preserved")

local mixed = assert(normalizeRaw({
  schema = 2,
  generated_at_epoch = 1700000000,
  lsblk = { blockdevices = {
    { name = "sda", kname = "sda", path = "/dev/sda", type = "disk", tran = "sata",
      rota = false, size = 1000000000, model = "Fixture SSD", serial = "SSD1", children = {} },
    { name = "sdb", kname = "sdb", path = "/dev/sdb", type = "disk", tran = "sata",
      rota = true, size = 2000000000, model = "Fixture HDD", serial = "HDD1", children = {} },
  } },
  smart = {
    { requested_device = "/dev/sda", payload = {
      smart_status = { passed = true }, temperature = { current = 42 },
      nvme_smart_health_information_log = { percentage_used = 12 },
      ata_smart_attributes = { table = {} },
    } },
    { requested_device = "/dev/sdb", payload = {
      smart_status = { passed = true }, temperature = { current = 36 },
      ata_smart_attributes = { table = {} },
    } },
  },
}, "test"))
assert(mixed.summary.disk_count == 2 and mixed.summary.ssd_count == 1 and mixed.summary.hdd_count == 1,
  "mixed SSD/HDD summary counts were incorrect")
assert(mixed.summary.smart_available_count == 2 and mixed.summary.hottest_drive_temperature_c == 42,
  "mixed-drive SMART or temperature summary was incorrect")
assert(mixed.summary.hottest_drive_id == "SSD1" and mixed.summary.hottest_drive_name == "Fixture SSD"
    and mixed.summary.hottest_ssd_drive_id == "SSD1",
  "temperature summary omitted the responsible drive")
assert(mixed.summary.worst_ssd_remaining_life_percent == 88
    and mixed.summary.worst_ssd_life_drive_id == "SSD1"
    and mixed.summary.worst_ssd_life_drive_name == "Fixture SSD",
  "SSD-life summary omitted the responsible drive")

local healthyRaw = assert(normalizeRaw({
  schema = 2,
  generated_at_epoch = 1700000000,
  lsblk = { blockdevices = { {
    name = "sda", kname = "sda", path = "/dev/sda", type = "disk", tran = "sata",
    rota = false, size = 1000000000, model = "Healthy SSD", serial = "HEALTHY1",
    mountpoints = {}, children = {},
  } } },
  smart = { {
    requested_device = "/dev/sda",
    payload = { smart_status = { passed = true }, ata_smart_attributes = { table = {} } },
  } },
}, "test"))
assert(healthyRaw.disks[1].smart_available == true and healthyRaw.disks[1].smart_error == nil,
  "healthy SMART data retained a contradictory error message")

local sleeping = assert(normalizeRaw({
  schema = 2, generated_at_epoch = 1700000000,
  lsblk = { blockdevices = { {
    name = "sdb", kname = "sdb", path = "/dev/sdb", type = "disk", tran = "sata",
    rota = true, size = 1000000000, model = "Sleeping HDD", serial = "SLEEP1",
    mountpoints = {}, children = {},
  } } },
  smart = { { requested_device = "/dev/sdb", payload = {
    power_mode = { value = 128, string = "STANDBY" },
    smartctl = { exit_status = 2 },
  } } },
}, "test"))
assert(sleeping.disks[1].smart_sleeping == true and sleeping.disks[1].smart_error == nil,
  "sleeping HDD was reported as a SMART access failure")
assert(sleeping.summary.sleeping_count == 1 and sleeping.summary.smart_unavailable_count == 0,
  "sleeping HDD was counted as unavailable")

local namespaces = assert(normalizeRaw({
  schema = 2, generated_at_epoch = 1700000000,
  lsblk = { blockdevices = {
    { name = "nvme0n1", kname = "nvme0n1", path = "/dev/nvme0n1", type = "disk",
      tran = "nvme", rota = false, serial = "SHARED", children = {} },
    { name = "nvme0n2", kname = "nvme0n2", path = "/dev/nvme0n2", type = "disk",
      tran = "nvme", rota = false, serial = "SHARED", children = {} },
  } }, smart = {},
}, "test"))
assert(namespaces.disks[1].id ~= namespaces.disks[2].id
    and namespaces.disks[1].id:match(":n%d+$") and namespaces.disks[2].id:match(":n%d+$"),
  "NVMe namespaces sharing a controller serial did not receive unique IDs")

local empty = assert(normalizeRaw({
  schema = 2, collection_id = "   ", generated_at_epoch = 1700000000,
  lsblk = { blockdevices = {} }, smart = {},
}, "test"))
assert(empty.access == "unavailable", "an empty drive inventory incorrectly reported full SMART access")
assert(empty.collection_id == nil, "invalid collection ID was preserved")

local oversizedId = assert(normalizeRaw({
  schema = 2, collection_id = string.rep("x", 129), generated_at_epoch = 1700000000,
  lsblk = { blockdevices = {} }, smart = {},
}, "test"))
assert(oversizedId.collection_id == nil, "oversized collection ID was preserved")

files["/usr/local/libexec/noctalia-gustav0ar-drive-health/collect_raw.sh"] = "installed"
collectorEnabled = true
state.collector_snapshot = { summary = {}, system_collector = { status = "healthy" } }
publishError("fixture failure", { ready = true, blocking = false })
assert(state.collector_snapshot.system_collector.status == "stale",
  "collector failure retained a stale healthy lifecycle status")
collectorEnabled = false

local compatibleProbe = {
  exitCode = 0, stdout = "lsblk=ok\nsmartctl=ok\n", stderr = "", timedOut = false,
}
local incompatibleProbe = {
  exitCode = 0, stdout = "lsblk=bad\nsmartctl=ok\n", stderr = "", timedOut = false,
}

probeAction = incompatibleProbe
watchers.refresh_nonce(1)
assert(state.collector_snapshot.dependencies.ready == false,
  "manual dependency probe did not cache an incompatible result")
probeAction = "pending"
watchers.refresh_nonce(2)
assert(pendingProbeCallback ~= nil, "manual recheck did not launch a fresh dependency probe")
local manualRecheck = pendingProbeCallback
pendingProbeCallback = nil
manualRecheck(compatibleProbe)
assert(state.collector_snapshot.dependencies.ready == true,
  "manual recheck did not recover a cached incompatible dependency")
local completedProbeCalls = probeCalls
update()
onIpc("refresh")
assert(probeCalls == completedProbeCalls,
  "routine collection reran a completed dependency probe")

probeAction = incompatibleProbe
watchers.refresh_nonce(3)
assert(state.collector_snapshot.dependencies.ready == false,
  "IPC recheck fixture did not cache an incompatible result")
probeAction = "pending"
onIpc("check-dependencies")
assert(pendingProbeCallback ~= nil, "dependency-check IPC did not launch a fresh probe")
local ipcRecheck = pendingProbeCallback
pendingProbeCallback = nil
ipcRecheck(compatibleProbe)
assert(state.collector_snapshot.dependencies.ready == true,
  "dependency-check IPC did not recover a cached incompatible dependency")

probeAction = "pending"
local callsBeforeQueuedRecheck = probeCalls
watchers.refresh_nonce(4)
onIpc("check-dependencies")
assert(probeCalls == callsBeforeQueuedRecheck + 1 and pendingProbeCallback ~= nil,
  "recheck during a running probe launched an overlapping probe")
local runningRecheck = pendingProbeCallback
pendingProbeCallback = nil
runningRecheck(compatibleProbe)
assert(probeCalls == callsBeforeQueuedRecheck + 2 and pendingProbeCallback ~= nil,
  "pending rechecks were not coalesced into one follow-up probe")
local queuedRecheck = pendingProbeCallback
pendingProbeCallback = nil
probeAction = nil
queuedRecheck(compatibleProbe)
assert(probeCalls == callsBeforeQueuedRecheck + 2,
  "queued recheck launched more than one follow-up probe")

probeAction = "launch-failure"
local callsBeforeLaunchFailure = probeCalls
watchers.refresh_nonce(5)
assert(probeCalls == callsBeforeLaunchFailure + 1
    and state.collector_snapshot.dependencies.ready == false,
  "probe launch failure did not publish an incompatible state")
update()
assert(probeCalls == callsBeforeLaunchFailure + 1,
  "routine collection retried a failed probe launch")
probeAction = compatibleProbe
watchers.refresh_nonce(6)
assert(probeCalls == callsBeforeLaunchFailure + 2
    and state.collector_snapshot.dependencies.ready == true,
  "manual recheck did not recover after a probe launch failure")

print("collector normalization tests passed")
