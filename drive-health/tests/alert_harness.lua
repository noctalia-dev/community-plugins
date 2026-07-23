-- Behavioral tests for the isolated alert service.

local state = {}
local watchers = {}
local notifications = {}
local stateWrites = {}
local stateRenames = {}
local successfulStateCommits = 0
local failNextStateWrite = false
local failNextStateRename = false
local fullSmartEnabled = false

local function translate(key, substitutions)
  local value = key
  for name, replacement in pairs(substitutions or {}) do
    value = value:gsub("{" .. name .. "}", tostring(replacement))
  end
  if substitutions ~= nil and substitutions.count ~= nil then
    value = value .. ":count=" .. tostring(substitutions.count)
  end
  return value
end

noctalia = {
  getConfig = function(key)
    local values = {
      alerts_enabled = true,
      notify_recovery = true,
      warning_temperature = 65,
      critical_temperature = 80,
      life_warning_percent = 20,
      show_hdd = false,
      alert_hdd = true,
      drive_missing_alerts = true,
      missing_grace_scans = 3,
      use_hotspot_temperature = true,
      system_collector_enabled = fullSmartEnabled,
    }
    return values[key]
  end,
  pluginDataDir = function() return "/mock/plugin-data" end,
  readFile = function(path)
    return path:match("alert%-state%.json$") and "{}" or nil
  end,
  writeFile = function(path, _contents)
    table.insert(stateWrites, path)
    if failNextStateWrite then
      failNextStateWrite = false
      return false, "fixture write failure"
    end
    return true
  end,
  renameFile = function(from, to)
    table.insert(stateRenames, { from = from, to = to })
    if failNextStateRename then
      failNextStateRename = false
      return false, "fixture rename failure"
    end
    successfulStateCommits = successfulStateCommits + 1
    return true
  end,
  log = function(_message) end,
  notify = function(title, body)
    table.insert(notifications, { severity = "warning", title = title, body = body })
  end,
  notifyError = function(title, body)
    table.insert(notifications, { severity = "critical", title = title, body = body })
  end,
  tr = translate,
  state = {
    get = function(key) return state[key] end,
    set = function(key, value) state[key] = value end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  json = {
    decode = function(_raw)
      return {
        active = {
          ["SERIAL1:interface-crc"] = {
            id = "SERIAL1:interface-crc", kind = "interface-crc",
            drive = "Fixture SSD", message = "historical CRC total", severity = "warning",
          },
        },
        counters = {}, inventory = {}, availability = {}, dismissed = {},
      }
    end,
    encode = function(_value, _pretty) return "{}" end,
  },
}

local handle = assert(io.open("service.luau", "rb"))
local source = handle:read("*a")
handle:close()
source = source:gsub("([%a_][%w_]*) %+%= ([^\n]+)", "%1 = %1 + %2")
assert(load(source, "@service.luau"))()

local publishSnapshot = assert(watchers.collector_snapshot, "alert service did not watch collector snapshots")
local function publish(value)
  state.collector_snapshot = value
  publishSnapshot(value)
end
local dismiss = assert(watchers.dismiss_alert_request, "alert service did not watch dismissal requests")
local function drive(temperature)
  return {
    id = "SERIAL1", device = "/dev/nvme0n1", model = "Fixture SSD",
    kind = "ssd", health = "passed", smart_available = true,
    temperature_c = temperature, hotspot_temperature_c = temperature, remaining_life_percent = 95,
    available_spare_percent = 100, critical_warning = 0,
    media_errors = 0, reallocated_sectors = 0, pending_sectors = 0,
    uncorrectable_errors = 0, spin_retry_count = 0, command_timeout_count = 0,
    interface_crc_errors = 0, unsafe_shutdowns = 12, error_log_entries = 5893,
    smart_completeness = "full", alerts_enabled = true, presence_alert_enabled = true,
    self_test_state = "passed",
  }
end

local function snapshot(disk, collectionId)
  return {
    collection_id = collectionId,
    disks = disk ~= nil and { disk } or {},
    dependencies = { ready = true, missing = {}, missing_text = "", signature = "" },
    summary = { ssd_count = disk ~= nil and 1 or 0 },
  }
end

local function findIssue(kind)
  for _, issue in ipairs(state.snapshot.issues or {}) do
    if issue.kind == kind then
      return issue
    end
  end
  return nil
end

publish(snapshot(drive(45)))
assert(#state.snapshot.issues == 0, "healthy drive produced an alert")
assert(#notifications == 0, "healthy baseline or legacy counter cleanup produced a notification")
assert(#stateWrites == 1 and #stateRenames == 1 and successfulStateCommits == 1,
  "first healthy baseline was not persisted as one atomic commit")

publish(snapshot(drive(45)))
onConfigChanged()
assert(#stateWrites == 1 and #stateRenames == 1,
  "identical or config-only processing rewrote alert state")

local writesBeforeNewAlert = #stateWrites
publish(snapshot(drive(70)))
assert(#state.snapshot.issues == 1 and state.snapshot.issues[1].kind == "temperature", "warning temperature was missed")
assert(#notifications == 1 and notifications[1].severity == "warning", "warning notification was not sent")
assert(#stateWrites == writesBeforeNewAlert + 1 and #stateRenames == writesBeforeNewAlert + 1,
  "new alert was not persisted as exactly one atomic commit")

publish(snapshot(drive(70)))
assert(#notifications == 1, "unchanged warning notification was duplicated")
assert(#stateWrites == writesBeforeNewAlert + 1,
  "unchanged active alert rewrote alert state")

publish(snapshot(drive(63)))
assert(#state.snapshot.issues == 1 and state.snapshot.issues[1].message == "alerts.temperature_cooling",
  "temperature hysteresis displayed a contradictory threshold message")
assert(#notifications == 1, "cooling hysteresis duplicated its warning notification")

publish(snapshot(drive(85)))
assert(state.snapshot.issues[1].severity == "critical", "critical escalation was missed")
assert(#notifications == 2 and notifications[2].severity == "critical", "critical escalation did not notify")

local writesBeforeRecovery = #stateWrites
publish(snapshot(drive(60)))
assert(#state.snapshot.issues == 0, "temperature recovery did not clear")
assert(#notifications == 3 and notifications[3].severity == "warning", "recovery did not notify")
assert(#stateWrites == writesBeforeRecovery + 1 and #stateRenames == writesBeforeRecovery + 1,
  "alert recovery was not persisted as exactly one atomic commit")

publish(snapshot(drive(70)))
assert(#notifications == 4, "recurring temperature issue did not notify")
publish(snapshot(drive(45)))
assert(#notifications == 5, "temperature recovery did not notify")

local retiredFixture = drive(45)
retiredFixture.presence_alert_enabled = false
publish(snapshot(retiredFixture))

local hddIssue = drive(35)
hddIssue.id = "HDD-SERIAL"
hddIssue.kind = "hdd"
hddIssue.remaining_life_percent = nil
hddIssue.presence_alert_enabled = false
hddIssue.interface_crc_errors = 2
local notificationsBeforeHddBaseline = #notifications
publish(snapshot(hddIssue))
assert(#state.snapshot.issues == 0 and #notifications == notificationsBeforeHddBaseline,
  "historical HDD interface CRC errors produced a false alert")
hddIssue.interface_crc_errors = 3
publish(snapshot(hddIssue))
assert(#state.snapshot.issues == 0, "new HDD interface CRC errors produced a persistent issue")
assert(#notifications == notificationsBeforeHddBaseline + 1
    and notifications[#notifications].severity == "warning"
    and notifications[#notifications].body:match("count=1"),
  "new HDD interface CRC error did not produce one delta notification")
publish(snapshot(hddIssue))
assert(#notifications == notificationsBeforeHddBaseline + 1,
  "unchanged HDD interface CRC total duplicated its notification")
hddIssue.interface_crc_errors = 0
publish(snapshot(hddIssue))
assert(#notifications == notificationsBeforeHddBaseline + 1,
  "decreased HDD interface CRC total produced a notification")

local historicalErrors = drive(45)
historicalErrors.id = "HISTORICAL-SERIAL"
historicalErrors.presence_alert_enabled = false
historicalErrors.media_errors = 8
historicalErrors.reallocated_sectors = 4
historicalErrors.pending_sectors = 2
historicalErrors.uncorrectable_errors = 3
historicalErrors.spin_retry_count = 1
historicalErrors.command_timeout_count = 6
historicalErrors.interface_crc_errors = 9
historicalErrors.error_log_entries = 20
local notificationsBeforeHistoricalBaseline = #notifications
publish(snapshot(historicalErrors))
assert(#state.snapshot.issues == 0 and #notifications == notificationsBeforeHistoricalBaseline,
  "first observation of historical SMART counters produced false alerts")

historicalErrors.uncorrectable_errors = 5
historicalErrors.error_log_entries = 21
historicalErrors.interface_crc_errors = 11
publish(snapshot(historicalErrors))
assert(#state.snapshot.issues == 0, "counter deltas produced persistent drive issues")
assert(#notifications == notificationsBeforeHistoricalBaseline + 3,
  "new SMART counter values did not produce exactly one notification per increase")
assert(notifications[notificationsBeforeHistoricalBaseline + 1].severity == "critical"
    and notifications[notificationsBeforeHistoricalBaseline + 1].body:match("count=2"),
  "uncorrectable-error delta notification was incorrect")
assert(notifications[notificationsBeforeHistoricalBaseline + 2].severity == "warning"
    and notifications[notificationsBeforeHistoricalBaseline + 2].body:match("count=2"),
  "interface CRC delta notification was incorrect")
assert(notifications[notificationsBeforeHistoricalBaseline + 3].severity == "warning"
    and notifications[notificationsBeforeHistoricalBaseline + 3].body:match("count=1"),
  "error-log delta notification was incorrect")
publish(snapshot(historicalErrors))
local unchangedCounterNotifications = {}
for index = notificationsBeforeHistoricalBaseline + 1, #notifications do
  table.insert(unchangedCounterNotifications, notifications[index].body)
end
assert(#notifications == notificationsBeforeHistoricalBaseline + 3,
  "unchanged SMART counter values duplicated notifications: " .. table.concat(unchangedCounterNotifications, ", "))
publish(snapshot(drive(45)))

local hotspot = drive(45)
hotspot.hotspot_temperature_c = 70
publish(snapshot(hotspot))
assert(state.snapshot.issues[1].kind == "temperature", "NVMe hotspot warning was missed")
publish(snapshot(drive(45)))

local customThreshold = drive(55)
customThreshold.warning_temperature = 50
customThreshold.critical_temperature = 70
publish(snapshot(customThreshold))
assert(state.snapshot.issues[1].kind == "temperature" and state.snapshot.issues[1].severity == "warning",
  "per-drive temperature threshold was ignored")
publish(snapshot(drive(45)))

local partial = drive(45)
partial.smart_completeness = "partial"
publish(snapshot(partial))
assert(#state.snapshot.issues == 0, "healthy partial SMART data produced an alert")
publish(snapshot(drive(45)))

local unavailable = drive(45)
unavailable.smart_available = false
publish(snapshot(unavailable))
assert(#state.snapshot.issues == 0,
  "Basic mode produced a false SMART-unavailable warning")
fullSmartEnabled = true
local notificationsBeforeUnavailable = #notifications
local writesBeforeUnavailable = #stateWrites
publish(snapshot(unavailable, "smart-unavailable-transient"))
assert(#state.snapshot.issues == 0 and #notifications == notificationsBeforeUnavailable,
  "a single transient SMART read failure produced an alert")
assert(#stateWrites == writesBeforeUnavailable + 1,
  "the first unavailable SMART scan did not persist its pending state")
publish(snapshot(unavailable, "smart-unavailable-transient"))
onConfigChanged()
assert(#state.snapshot.issues == 0 and #notifications == notificationsBeforeUnavailable,
  "reprocessing one unavailable SMART snapshot advanced its grace period")
assert(#stateWrites == writesBeforeUnavailable + 1,
  "reprocessing one unavailable SMART snapshot rewrote pending state")
publish(snapshot(drive(45), "smart-available-reset"))
assert(#state.snapshot.issues == 0 and #notifications == notificationsBeforeUnavailable,
  "transient SMART availability recovery produced a notification")

publish(snapshot(unavailable, "smart-unavailable-1"))
publish(snapshot(unavailable, "smart-unavailable-2"))
assert(#state.snapshot.issues == 0 and #notifications == notificationsBeforeUnavailable,
  "SMART unavailability alerted before three completed scans")
publish(snapshot(unavailable, "smart-unavailable-3"))
assert(#state.snapshot.issues == 1 and state.snapshot.issues[1].kind == "smart-unavailable",
  "sustained SMART unavailability did not alert after three completed scans")
assert(#notifications == notificationsBeforeUnavailable + 1,
  "sustained SMART unavailability did not produce exactly one notification")
local writesAfterConfirmedUnavailable = #stateWrites
publish(snapshot(unavailable, "smart-unavailable-4"))
assert(#notifications == notificationsBeforeUnavailable + 1,
  "continued SMART unavailability duplicated its notification")
assert(#stateWrites == writesAfterConfirmedUnavailable,
  "confirmed SMART unavailability rewrote stable alert state")
local sleeping = drive(45)
sleeping.smart_available = false
sleeping.smart_sleeping = true
publish(snapshot(sleeping, "smart-sleeping"))
assert(#state.snapshot.issues == 0, "sleeping drive produced a SMART-unavailable warning")
assert(#notifications == notificationsBeforeUnavailable + 2,
  "confirmed SMART-unavailable recovery did not notify exactly once")
fullSmartEnabled = false
publish(snapshot(drive(45)))

local selfTestFailure = drive(45)
selfTestFailure.self_test_state = "failed"
selfTestFailure.self_test_status = "Completed with read failure"
publish(snapshot(selfTestFailure))
assert(state.snapshot.issues[1].kind == "self-test" and state.snapshot.issues[1].severity == "critical",
  "self-test failure was missed")
publish(snapshot(drive(45)))

local counterIncrease = drive(45)
counterIncrease.unsafe_shutdowns = 13
local writesBeforeCounterIncrease = #stateWrites
local notificationsBeforeCounterIncrease = #notifications
publish(snapshot(counterIncrease))
assert(#stateWrites == writesBeforeCounterIncrease + 1
    and #stateRenames == writesBeforeCounterIncrease + 1,
  "counter increase was not persisted as exactly one atomic commit")
assert(#notifications == notificationsBeforeCounterIncrease + 1,
  "counter increase notification behavior changed")
publish(snapshot(counterIncrease))
assert(#stateWrites == writesBeforeCounterIncrease + 1,
  "unchanged diagnostic counter rewrote alert state")
publish(snapshot(drive(45)))

publish(snapshot(drive(45), "scan-100"))

local firstMissingScan = snapshot(nil, "scan-101")
local writesBeforeMissingScan = #stateWrites
publish(firstMissingScan)
assert(findIssue("drive-missing") == nil, "missing drive alerted before the grace period")
assert(#stateWrites == writesBeforeMissingScan + 1
    and #stateRenames == writesBeforeMissingScan + 1,
  "missing-drive inventory change was not persisted as exactly one atomic commit")
publish(firstMissingScan)
assert(findIssue("drive-missing") == nil, "reprocessing one snapshot advanced the grace period")
assert(#stateWrites == writesBeforeMissingScan + 1,
  "reprocessing one collection rewrote unchanged inventory state")
publish(snapshot(nil, "scan-101"))
assert(findIssue("drive-missing") == nil, "a repeated collection ID advanced the grace period")
assert(#stateWrites == writesBeforeMissingScan + 1,
  "a repeated collection ID rewrote unchanged inventory state")

onConfigChanged()
assert(findIssue("drive-missing") == nil, "a config refresh advanced the grace period")
assert(#stateWrites == writesBeforeMissingScan + 1,
  "config refresh rewrote unchanged missing-drive state")
local collectingSnapshot = snapshot(nil, "scan-collecting")
collectingSnapshot.collecting = true
publish(collectingSnapshot)
assert(findIssue("drive-missing") == nil, "an in-progress collection advanced the grace period")

local failedMissingScan = snapshot(nil, "scan-failed")
failedMissingScan.collector_error = "fixture failure"
publish(failedMissingScan)
assert(findIssue("drive-missing") == nil, "a failed collection advanced the grace period")

local blockedMissingScan = snapshot(nil, "scan-blocked")
blockedMissingScan.dependencies = {
  ready = false, blocking = true,
  missing = { "lsblk (lsblk)" }, missing_text = "lsblk (lsblk)", signature = "lsblk",
}
publish(blockedMissingScan)
assert(findIssue("drive-missing") == nil, "a blocked collection advanced the grace period")

publish(snapshot(nil, "scan-102"))
assert(findIssue("drive-missing") == nil, "missing drive alerted after only two completed scans")
publish(snapshot(nil, "scan-103"))
assert(findIssue("drive-missing") ~= nil, "three unique completed scans did not trigger a missing-drive alert")
publish(snapshot(nil, "scan-103"))
assert(findIssue("drive-missing") ~= nil, "reprocessing a snapshot removed an active missing-drive alert")

local writesBeforeReappearance = #stateWrites
publish(snapshot(drive(45), "scan-104"))
assert(findIssue("drive-missing") == nil, "drive reappearance did not clear its missing alert")
assert(#stateWrites == writesBeforeReappearance + 1
    and #stateRenames == writesBeforeReappearance + 1,
  "drive reappearance was not persisted as exactly one atomic commit")
publish(snapshot(nil, "scan-105"))
publish(snapshot(nil, "scan-106"))
assert(findIssue("drive-missing") == nil, "reappearance did not reset the missing-drive grace period")
publish(snapshot(nil, "scan-107"))
assert(findIssue("drive-missing") ~= nil, "three new scans after reappearance did not trigger an alert")

publish(snapshot(drive(45), "scan-108"))
local legacyMissingScan = snapshot(nil)
publish(legacyMissingScan)
publish(legacyMissingScan)
assert(findIssue("drive-missing") == nil, "a repeated legacy snapshot advanced the grace period")
publish(snapshot(nil))
assert(findIssue("drive-missing") == nil, "two legacy snapshot objects triggered an early alert")
publish(snapshot(nil))
assert(findIssue("drive-missing") ~= nil, "distinct legacy snapshot objects did not advance the grace period")

local missing = snapshot(nil)
missing.dependencies = {
  ready = false, blocking = true,
  missing = { "lsblk (lsblk)" }, missing_text = "lsblk (lsblk)", signature = "lsblk",
}
local notificationCountBeforeDependency = #notifications
publish(missing)
assert(findIssue("missing-dependencies") ~= nil, "dependency issue was missed")
assert(findIssue("drive-missing") ~= nil, "a blocking dependency removed an active missing-drive alert")
local dependencyCritical = false
for index = notificationCountBeforeDependency + 1, #notifications do
  if notifications[index].severity == "critical" then dependencyCritical = true end
end
assert(dependencyCritical, "blocking dependency was not critical")

local failed = snapshot(nil)
failed.collector_error = "fixture failure"
local notificationCountBeforeFailure = #notifications
publish(failed)
assert(findIssue("collector-error") ~= nil, "collector issue was missed")
assert(findIssue("drive-missing") ~= nil, "a collector failure removed an active missing-drive alert")
local collectorCritical = false
for index = notificationCountBeforeFailure + 1, #notifications do
  if notifications[index].severity == "critical" then
    collectorCritical = true
  end
end
assert(collectorCritical, "collector failure did not notify critically")

local writesBeforeWriteFailure = #stateWrites
local renamesBeforeWriteFailure = #stateRenames
local commitsBeforeWriteFailure = successfulStateCommits
failNextStateWrite = true
dismiss({ id = "collector:error", nonce = 8 })
assert(#stateWrites == writesBeforeWriteFailure + 1
    and #stateRenames == renamesBeforeWriteFailure
    and successfulStateCommits == commitsBeforeWriteFailure,
  "failed temporary write attempted a rename or lost the pending state")
publish(failed)
assert(#stateWrites == writesBeforeWriteFailure + 2
    and #stateRenames == renamesBeforeWriteFailure + 1
    and successfulStateCommits == commitsBeforeWriteFailure + 1,
  "unchanged snapshot did not retry a failed alert-state write")
publish(failed)
assert(#stateWrites == writesBeforeWriteFailure + 2,
  "successful write retry did not clear dirty alert state")

local writesBeforeRenameFailure = #stateWrites
local renamesBeforeRenameFailure = #stateRenames
local commitsBeforeRenameFailure = successfulStateCommits
failNextStateRename = true
dismiss({ all = true, nonce = 9 })
assert(#state.snapshot.issues == 0, "dismiss all did not hide every active issue")
assert(#stateWrites == writesBeforeRenameFailure + 1
    and #stateRenames == renamesBeforeRenameFailure + 1
    and successfulStateCommits == commitsBeforeRenameFailure,
  "failed atomic rename was treated as a successful commit")
onConfigChanged()
assert(#stateWrites == writesBeforeRenameFailure + 2
    and #stateRenames == renamesBeforeRenameFailure + 2
    and successfulStateCommits == commitsBeforeRenameFailure + 1,
  "unchanged processing did not retry a failed atomic rename")
onConfigChanged()
assert(#stateWrites == writesBeforeRenameFailure + 2,
  "successful rename retry did not clear dirty alert state")

publish(snapshot(drive(45), "scan-dismissal-baseline"))
publish(snapshot(drive(70), "scan-dismissal-warning"))
assert(findIssue("temperature") ~= nil, "permanent-dismissal fixture did not create an alert")
local notificationsBeforeDismissal = #notifications
local writesBeforeDismissal = #stateWrites
local renamesBeforeDismissal = #stateRenames
dismiss({ id = "SERIAL1:temperature", nonce = 10 })
assert(findIssue("temperature") == nil, "individual dismissal did not hide the active issue")
assert(#notifications == notificationsBeforeDismissal, "dismissing an issue emitted a notification")
assert(#stateWrites == writesBeforeDismissal + 1 and #stateRenames == renamesBeforeDismissal + 1,
  "dismissal was not persisted as exactly one atomic commit")
publish(snapshot(drive(85), "scan-dismissal-critical"))
assert(findIssue("temperature") == nil and #notifications == notificationsBeforeDismissal,
  "a dismissed alert returned or notified after escalating")
publish(snapshot(drive(45), "scan-dismissal-recovery"))
publish(snapshot(drive(70), "scan-dismissal-recurrence"))
assert(findIssue("temperature") == nil and #notifications == notificationsBeforeDismissal,
  "a dismissed alert returned or notified after recurring")

for _, path in ipairs(stateWrites) do
  assert(path:match("alert%-state%.json%.tmp$"),
    "alert state bypassed its temporary file")
end
for _, rename in ipairs(stateRenames) do
  assert(rename.from:match("alert%-state%.json%.tmp$")
      and rename.to:match("alert%-state%.json$"),
    "alert state was not committed with an atomic rename")
end

print("alert behavior tests passed")
