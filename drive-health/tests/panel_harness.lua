-- Declarative panel smoke tests with a minimal Noctalia/UI host.

local state = {}
local rendered = nil
local terminalCommand = nil
local asyncCommand = nil
local asyncCallback = nil
local notifications = {}
local errors = {}
local writesSucceed = true
local configValues = {
  warning_temperature = 65,
  critical_temperature = 80,
  show_hdd = true,
  use_hotspot_temperature = true,
  system_collector_enabled = true,
}

local function translate(key, substitutions)
  if key == "metrics.mounted_at" then
    return key .. " " .. tostring(substitutions and substitutions.paths or "")
  elseif key == "metrics.serial" then
    return key .. " " .. tostring(substitutions and substitutions.value or "")
  end
  local value = key
  for name, replacement in pairs(substitutions or {}) do
    value = value:gsub("{" .. name .. "}", tostring(replacement))
  end
  return value
end

local function node(kind, props, children)
  return { kind = kind, props = props or {}, children = children or {} }
end

ui = setmetatable({}, {
  __index = function(_table, kind)
    return function(props, children) return node(kind, props, children) end
  end,
})

panel = {
  render = function(tree) rendered = tree end,
  close = function() end,
}

local watchers = {}
noctalia = {
  getConfig = function(key)
    return configValues[key]
  end,
  tr = translate,
  pluginDataDir = function() return "/mock/plugin-data" end,
  writeFile = function(_path, _contents) return writesSucceed end,
  renameFile = function(_from, _to) return true end,
  notify = function(title, body) table.insert(notifications, { title = title, body = body }) end,
  notifyError = function(title, body) table.insert(errors, { title = title, body = body }) end,
  runInTerminal = function(command) terminalCommand = command return true end,
  runAsync = function(command, callback, _timeout)
    asyncCommand = command
    asyncCallback = callback
    return true
  end,
  copyToClipboard = function(_text, _mime) return true end,
  string = { trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end },
  json = { encode = function(_value, _pretty) return "{}" end },
  state = {
    get = function(key) return state[key] end,
    set = function(key, value) state[key] = value end,
    watch = function(key, callback) watchers[key] = callback end,
  },
}

state.snapshot = {
  generated_at_local = "12:00:00",
  collector_error = nil,
  dependencies = { ready = true },
  system_collector = { enabled = true, installed = true, status = "healthy", version = "1.0.0",
    expected_version = "1.0.0", helper_available = true, authorization_available = true,
    enable_command = "sudo systemctl enable --now noctalia-gustav0ar-drive-health.timer",
    disable_command = "sudo systemctl disable --now noctalia-gustav0ar-drive-health.timer",
    install_command = "sudo '/mock/plugin/packaging/install-system-collector.sh'",
    uninstall_command = "sudo '/mock/plugin/packaging/uninstall-system-collector.sh'" },
  summary = { disk_count = 2, ssd_count = 1, hdd_count = 1, smart_available_count = 2,
    ssd_smart_available_count = 1, hottest_drive_temperature_c = 70,
    hottest_drive_name = "Fixture SSD", hottest_ssd_temperature_c = 70,
    hottest_ssd_drive_name = "Fixture SSD", worst_ssd_remaining_life_percent = 95,
    worst_ssd_life_drive_name = "Fixture SSD" },
  issues = {},
  disks = { {
    id = "SERIAL1", serial = "SERIAL1", model = "Fixture SSD", display_name = "Fixture SSD", device = "/dev/nvme0n1",
    smart_device = "/dev/nvme0", kind = "ssd", transport = "nvme", capacity_bytes = 2000000000,
    health = "passed", smart_available = true, smart_completeness = "full",
    temperature_c = 45, hotspot_temperature_c = 70, temperature_sensors_c = { 70, 45 },
    remaining_life_percent = 95, percentage_used = 5, available_spare_percent = 100,
    power_on_hours = 100, data_written_bytes = 1000, self_test_supported = true,
    self_test_state = "running", self_test_status = "Short self-test in progress",
    self_test_completion_percent = 37,
    mount_points = { "/", "/home/example" },
    alerts_enabled = true, presence_alert_enabled = true,
  }, {
    id = "HDD1", model = "Fixture HDD", display_name = "Fixture HDD", device = "/dev/sdb",
    smart_device = "/dev/sdb", kind = "hdd", transport = "sata", capacity_bytes = 2000000000000,
    health = "passed", smart_available = true, smart_completeness = "full",
    temperature_c = 36, hotspot_temperature_c = 36, power_on_hours = 113397, power_cycles = 2200,
    start_stop_count = 1423, load_cycle_count = 18421, reallocated_sectors = 0,
    pending_sectors = 0, uncorrectable_errors = 0, spin_retry_count = 0,
    command_timeout_count = 0, interface_crc_errors = 0, self_test_supported = true,
    self_test_state = "passed", self_test_status = "Completed without error",
    alerts_enabled = true, presence_alert_enabled = true,
  } },
}
state.drive_history = { schema = 1, drives = { SERIAL1 = { samples = {
  { epoch = 1, hotspot_temperature_c = 65, remaining_life_percent = 96 },
  { epoch = 2, hotspot_temperature_c = 67, remaining_life_percent = 96 },
  { epoch = 3, hotspot_temperature_c = 69, remaining_life_percent = 95 },
  { epoch = 4, hotspot_temperature_c = 70, remaining_life_percent = 95 },
} } } }
state.drive_preferences = { schema = 1, order = {}, drives = {} }

local handle = assert(io.open("panel.luau", "rb"))
local source = handle:read("*a")
handle:close()
source = source:gsub("([%a_][%w_]*) %+%= ([^\n]+)", "%1 = %1 + %2")
source = source:gsub("([%a_][%w_]*) /%= ([^\n]+)", "%1 = %1 / %2")
assert(load(source, "@panel.luau"))()

local function containsText(value, target)
  if type(value) ~= "table" then return false end
  if type(value.props) == "table" and value.props.text == target then return true end
  for _, child in pairs(value.children or {}) do
    if containsText(child, target) then return true end
  end
  return false
end

local function countText(value, target)
  if type(value) ~= "table" then return 0 end
  local count = type(value.props) == "table" and value.props.text == target and 1 or 0
  for _, child in pairs(value.children or {}) do
    count = count + countText(child, target)
  end
  return count
end

local function findNode(value, kind)
  if type(value) ~= "table" then return nil end
  if value.kind == kind then return value end
  for _, child in pairs(value.children or {}) do
    local found = findNode(child, kind)
    if found ~= nil then return found end
  end
  return nil
end

local function findNodeWithProp(value, kind, property, expected)
  if type(value) ~= "table" then return nil end
  if value.kind == kind and type(value.props) == "table" and value.props[property] == expected then
    return value
  end
  for _, child in pairs(value.children or {}) do
    local found = findNodeWithProp(child, kind, property, expected)
    if found ~= nil then return found end
  end
  return nil
end

onOpen({})
assert(rendered ~= nil and not containsText(rendered, "collector.title"),
  "healthy collector consumed panel space")
assert(findNodeWithProp(rendered, "glyph", "name", "server-2") ~= nil,
  "panel header did not use the physical-storage icon")
assert(countText(rendered, "Fixture SSD") >= 3,
  "summary cards did not identify the hottest and lowest-life drives")
assert(not containsText(rendered, "metrics.mounted_at /  ·  /home/example"),
  "collapsed drive card exposed mount paths")
onToggleCollectorSettingsClicked()
assert(containsText(rendered, "collector.settings_title")
  and containsText(rendered, "collector.basic_features")
  and containsText(rendered, "collector.full_features"),
  "collector settings did not explain Basic and Full SMART capabilities")
onPauseCollectorClicked()
assert(terminalCommand == "sudo systemctl disable --now noctalia-gustav0ar-drive-health.timer",
  "collector settings did not expose the explicit service pause command")
terminalCommand = nil
onOpenPluginSettingsClicked()
assert(asyncCommand == "noctalia msg settings-open plugins",
  "collector settings did not open Noctalia's Plugins section")
onToggleCollectorSettingsClicked()
state.snapshot.system_collector.status = "upgrade-required"
state.snapshot.system_collector.version = "0.6.0"
watchers.snapshot(state.snapshot)
assert(containsText(rendered, "collector.title"), "actionable collector state did not render")
onToggleCollectorSettingsClicked()
assert(not containsText(rendered, "collector.title") and containsText(rendered, "collector.settings_title"),
  "collector settings duplicated the actionable lifecycle card")
onToggleCollectorSettingsClicked()
state.snapshot.system_collector.status = "healthy"
state.snapshot.system_collector.version = "1.0.0"
watchers.snapshot(state.snapshot)
configValues.system_collector_enabled = false
state.snapshot.system_collector.enabled = false
state.snapshot.system_collector.status = "disabled"
state.snapshot.system_collector.helper_available = false
watchers.snapshot(state.snapshot)
assert(not containsText(rendered, "collector.title"),
  "disabled optional collector created a persistent main-panel warning")
onToggleCollectorSettingsClicked()
assert(containsText(rendered, "collector.status_disabled")
  and containsText(rendered, "collector.open_settings"),
  "disabled collector status or re-enable route was missing from collector settings")
onToggleCollectorSettingsClicked()
configValues.system_collector_enabled = true
state.snapshot.system_collector.enabled = true
state.snapshot.system_collector.status = "healthy"
state.snapshot.system_collector.helper_available = true
watchers.snapshot(state.snapshot)
onDrive1Clicked()
assert(containsText(rendered, "self_test.title"), "expanded self-test card did not render")
assert(containsText(rendered, "metrics.mounted_at /  ·  /home/example"),
  "expanded drive card omitted its mounted folders")
assert(containsText(rendered, "metrics.serial SERIAL1"),
  "expanded drive card omitted its serial")
assert(containsText(rendered, "self_test.progress"), "running self-test progress did not render")
state.snapshot.disks[1].smart_completeness = "partial"
watchers.snapshot(state.snapshot)
assert(containsText(rendered, "smart.partial_details"), "partial SMART status lost its inline explanation")
state.snapshot.disks[1].smart_completeness = "full"
watchers.snapshot(state.snapshot)
local testProgress = assert(findNodeWithProp(rendered, "progress", "progress", 0.37),
  "running self-test progress bar did not render")
assert(testProgress.props.progress == 0.37 and testProgress.props.value == nil,
  "running self-test used an invalid progress property")
assert(containsText(rendered, "history.title"), "expanded history graph did not render")
assert(containsText(rendered, "preferences.edit"), "drive preference action did not render")
onDrive1Clicked()
assert(not containsText(rendered, "self_test.title"), "drive details did not collapse")
assert(not containsText(rendered, "history.title"), "drive history remained visible after collapse")
onDrive1Clicked()
state.snapshot.disks[1].self_test_state = "passed"
state.snapshot.disks[1].self_test_status = "Previous test passed"
state.snapshot.disks[1].self_test_completion_percent = nil
state.snapshot.generated_at_epoch = 100
watchers.snapshot(state.snapshot)
onStartShortSelfTestClicked()
assert(containsText(rendered, "self_test.confirm_action"), "self-test confirmation did not render")
assert(terminalCommand == nil, "self-test started before confirmation")
onConfirmSelfTestClicked()
assert(asyncCommand:match("^pkexec /usr/local/libexec/noctalia%-gustav0ar%-drive%-health/smart%-action%.sh 'short' '/dev/nvme0'$"),
  "self-test did not use Polkit, the fixed helper, and normalized controller")
assert(terminalCommand == nil, "background self-test opened a terminal")
assert(containsText(rendered, "self_test.authorizing"), "authorization state did not render")
assert(asyncCallback ~= nil, "background self-test callback was not registered")
-- Bit 3 is an existing SMART health finding; it must not hide an accepted test request.
asyncCallback({ exitCode = 8, stdout = "accepted", stderr = "", timedOut = false })
assert(containsText(rendered, "self_test.starting"), "accepted self-test did not render startup state")
assert(state.refresh_nonce == 1, "accepted self-test did not request an immediate SMART refresh")
assert(notifications[#notifications].body == "self_test.started_background",
  "accepted self-test did not notify that it is running in the background")

state.snapshot.generated_at_epoch = 101
state.snapshot.disks[1].self_test_state = "running"
state.snapshot.disks[1].self_test_status = "Short self-test in progress"
state.snapshot.disks[1].self_test_completion_percent = 52
watchers.snapshot(state.snapshot)
assert(containsText(rendered, "Short self-test in progress"), "firmware self-test state did not replace startup state")
assert(findNodeWithProp(rendered, "progress", "progress", 0.52) ~= nil,
  "background self-test progress did not update")

state.snapshot.generated_at_epoch = 102
state.snapshot.disks[1].self_test_state = "passed"
state.snapshot.disks[1].self_test_status = "Completed without error"
state.snapshot.disks[1].self_test_completion_percent = nil
watchers.snapshot(state.snapshot)
assert(containsText(rendered, "Completed without error"), "completed background self-test result did not render")

asyncCommand = nil
asyncCallback = nil
onStartLongSelfTestClicked()
onConfirmSelfTestClicked()
assert(asyncCommand:match("smart%-action%.sh 'long' '/dev/nvme0'"),
  "extended self-test did not use the long action")
asyncCallback({ exitCode = 126, stdout = "", stderr = "", timedOut = false })
assert(containsText(rendered, "self_test.authorization_cancelled"),
  "cancelled authorization did not render a useful inline result")
assert(errors[#errors].body == "self_test.authorization_cancelled",
  "cancelled authorization did not produce an error notification")

state.snapshot.system_collector.authorization_available = false
watchers.snapshot(state.snapshot)
assert(containsText(rendered, "self_test.authorization_required"),
  "missing Polkit dependency was not explained")
state.snapshot.system_collector.authorization_available = true
watchers.snapshot(state.snapshot)
onEditExpandedDriveClicked()
assert(containsText(rendered, "preferences.title"), "drive preference editor did not render")
onDriveAlertsChanged(false)
onPresenceAlertsChanged(false)
onCancelDrivePreferencesClicked()
local cancelled = state.drive_preferences.drives.SERIAL1
assert(cancelled.alerts_enabled == nil and cancelled.presence_alert_enabled == nil,
  "cancelled alert preference changes leaked into shared state")
onEditExpandedDriveClicked()
onAliasChanged("Workspace")
onWarningThresholdChanged("68")
onCriticalThresholdChanged("82")
onLifeThresholdChanged("15")
onSaveDrivePreferencesClicked()
local saved = state.drive_preferences.drives.SERIAL1
assert(saved.alias == "Workspace" and saved.warning_temperature == 68
  and saved.critical_temperature == 82 and saved.life_warning_percent == 15,
  "drive preferences were not persisted to shared state")

onEditExpandedDriveClicked()
onAliasChanged("Should not persist")
writesSucceed = false
onSaveDrivePreferencesClicked()
writesSucceed = true
assert(saved.alias == "Workspace", "failed preference write leaked changes into shared state")
onCancelDrivePreferencesClicked()

onEditExpandedDriveClicked()
writesSucceed = false
onHideDriveClicked()
writesSucceed = true
assert(saved.hidden == nil and containsText(rendered, "preferences.title"),
  "failed hide write changed visibility or closed the editor")
onCancelDrivePreferencesClicked()

state.drive_history.drives.SERIAL1.samples = {
  { epoch = 1, hotspot_temperature_c = 65 },
  { epoch = 2, hotspot_temperature_c = 67 },
  { epoch = 3, hotspot_temperature_c = 69 },
}
watchers.drive_history(state.drive_history)
assert(findNode(rendered, "graph") == nil and not containsText(rendered, "history.title"),
  "trend section rendered before a graph-compatible series had four samples")
state.drive_history.drives.SERIAL1.samples = {
  { epoch = 1, hotspot_temperature_c = 65 },
  { epoch = 2, hotspot_temperature_c = 67 },
  { epoch = 3, hotspot_temperature_c = 69 },
  { epoch = 4, hotspot_temperature_c = 70 },
}
watchers.drive_history(state.drive_history)
local graph = assert(findNode(rendered, "graph"), "temperature-only history graph did not render")
assert(graph.props.values2 == nil, "missing endurance history was rendered as a zero-percent series")
assert(graph.props.height == 44, "rendered trend graph did not use the compact height")
assert(not containsText(rendered, "● history.life"), "missing endurance history kept a misleading legend")

state.snapshot.issues = {
  { id = "SERIAL1:temperature", severity = "warning", message = "Fixture temperature warning" },
  { id = "SERIAL1:interface-crc", severity = "warning", message = "Fixture interface CRC warning" },
}
state.snapshot.summary.active_alert_count = 2
watchers.snapshot(state.snapshot)
assert(containsText(rendered, "alerts.dismiss_all"), "dismiss-all alert action did not render")
assert(findNodeWithProp(rendered, "button", "tooltip", "alerts.dismiss") ~= nil,
  "per-alert dismiss action did not render")
onDismissAlert1Clicked()
assert(state.dismiss_alert_request.id == "SERIAL1:temperature",
  "per-alert dismiss action targeted the wrong issue")
onDismissAllAlertsClicked()
assert(state.dismiss_alert_request.all == true, "dismiss-all action did not request all active issues")

state.snapshot.issues = {}
state.snapshot.summary.active_alert_count = 0
watchers.snapshot(state.snapshot)
assert(not containsText(rendered, "alerts.active_title")
    and findNodeWithProp(rendered, "button", "tooltip", "alerts.dismiss") == nil,
  "empty alert state kept an alert card or dismiss controls")

onDrive2Clicked()
assert(containsText(rendered, "metrics.start_stop_count")
  and containsText(rendered, "metrics.load_cycle_count")
  and containsText(rendered, "metrics.interface_crc_errors"),
  "expanded HDD card omitted mechanical or interface health details")
assert(countText(rendered, "metrics.life_remaining") == 1,
  "HDD card rendered a meaningless SSD endurance metric")
onEditExpandedDriveClicked()
assert(not containsText(rendered, "preferences.life_warning"),
  "HDD preference editor exposed an SSD-only endurance threshold")
onCancelDrivePreferencesClicked()

state.snapshot.dependencies = {
  ready = false, blocking = true, missing_text = "lsblk (util-linux)",
  install_command = "sudo pacman -S --needed util-linux", package_manager = "pacman", can_install = true,
}
watchers.snapshot(state.snapshot)
assert(containsText(rendered, "dependencies.title"), "missing dependency card did not render")

state.snapshot.dependencies = { ready = true }
state.snapshot.disks = { state.snapshot.disks[2] }
state.snapshot.summary = {
  disk_count = 1, ssd_count = 0, hdd_count = 1, smart_available_count = 1,
  hdd_smart_available_count = 1, hottest_drive_temperature_c = 36,
  hottest_drive_name = "Fixture HDD",
}
watchers.snapshot(state.snapshot)
assert(not containsText(rendered, "summary.lowest_ssd_life"),
  "HDD-only system rendered the SSD-life summary card")
assert(countText(rendered, "Fixture HDD") >= 2,
  "HDD-only temperature summary did not identify its drive")

print("panel rendering tests passed")
