--!nonstrict

-- Alert service. Collection and SMART normalization are intentionally isolated
-- in collector.luau; this entry only evaluates normalized snapshots.

local alertState = { active = {}, counters = {}, inventory = {}, dismissed = {} }
local alertStateDirty = false
local legacyMissingSnapshots = {}

local function stateValuesEqual(left, right)
  if left == right then
    return true
  end
  local valueType = type(left)
  if valueType ~= type(right) or valueType ~= "table" then
    return false
  end
  for key, value in pairs(left) do
    if not stateValuesEqual(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

local function copyStateValue(value)
  if type(value) ~= "table" then
    return value
  end
  local copied = {}
  for key, child in pairs(value) do
    copied[key] = copyStateValue(child)
  end
  return copied
end

local function replaceAlertStateSection(section, value)
  if stateValuesEqual(alertState[section], value) then
    return false
  end
  alertState[section] = value
  alertStateDirty = true
  return true
end

local function number(value, fallback)
  local parsed = tonumber(value)
  return parsed ~= nil and parsed or fallback
end

local function boolConfig(key, fallback)
  local value = noctalia.getConfig(key)
  return value == nil and fallback or value == true
end

local function snapshotCollectionId(snapshot)
  local value = snapshot.collection_id
  if type(value) ~= "string" or value:match("^%s*$") ~= nil
      or #value > 128 or value:find("[%c]") ~= nil then
    return nil
  end
  return value
end

local function alertStatePath()
  local directory = noctalia.pluginDataDir()
  return directory ~= nil and directory .. "/alert-state.json" or nil
end

local function loadAlertState()
  local path = alertStatePath()
  local raw = path ~= nil and noctalia.readFile(path) or nil
  local decoded = raw ~= nil and noctalia.json.decode(raw) or nil
  if type(decoded) == "table" then
    alertState.active = type(decoded.active) == "table" and decoded.active or {}
    alertState.counters = type(decoded.counters) == "table" and decoded.counters or {}
    alertState.inventory = type(decoded.inventory) == "table" and decoded.inventory or {}
    alertState.dismissed = type(decoded.dismissed) == "table" and decoded.dismissed or {}
  end
  alertStateDirty = false
end

local function saveAlertState()
  local path = alertStatePath()
  if path == nil then
    return false
  end
  local encoded, encodeError = noctalia.json.encode(alertState, true)
  if encoded == nil then
    noctalia.log("Unable to encode SMART alert state: " .. tostring(encodeError))
    return false
  end
  local temporary = path .. ".tmp"
  local written, writeError = noctalia.writeFile(temporary, encoded)
  if not written then
    noctalia.log("Unable to persist SMART alert state: " .. tostring(writeError))
    return false
  end
  local renamed, renameError = noctalia.renameFile(temporary, path)
  if not renamed then
    noctalia.log("Unable to commit SMART alert state: " .. tostring(renameError))
    return false
  end
  return true
end

local function persistAlertState()
  if alertStateDirty and saveAlertState() then
    alertStateDirty = false
  end
end

local function severityRank(severity)
  return severity == "critical" and 2 or 1
end

local function sendIssueNotification(issue)
  if not boolConfig("alerts_enabled", true) then
    return
  end
  if issue.severity == "critical" then
    noctalia.notifyError(issue.title, issue.message)
  else
    noctalia.notify(issue.title, issue.message)
  end
end

local function driveIdentity(drive)
  return tostring(drive.id or drive.serial or drive.device or drive.model or "unknown-drive")
end

local function driveName(drive)
  return tostring(drive.display_name or drive.model or drive.device or noctalia.tr("alerts.unknown_drive"))
end

local function driveIssue(drive, kind, severity, message, value, monotonic)
  return {
    id = driveIdentity(drive) .. ":" .. kind,
    drive_id = driveIdentity(drive),
    kind = kind,
    drive = driveName(drive),
    severity = severity,
    title = noctalia.tr("alerts.drive_title", { drive = driveName(drive) }),
    message = message,
    value = value,
    monotonic = monotonic == true,
  }
end

local function evaluateDrive(drive, previousActive, fullSmartExpected)
  local issues = {}
  local name = driveName(drive)
  local warningTemperature = number(drive.warning_temperature, number(noctalia.getConfig("warning_temperature"), 65))
  local criticalTemperature = math.max(warningTemperature + 1,
    number(drive.critical_temperature, number(noctalia.getConfig("critical_temperature"), 80)))
  local lifeWarning = number(drive.life_warning_percent, number(noctalia.getConfig("life_warning_percent"), 20))

  if fullSmartExpected and drive.smart_available == false and drive.smart_sleeping ~= true then
    table.insert(issues, driveIssue(
      drive, "smart-unavailable", "warning",
      noctalia.tr("alerts.smart_unavailable", { drive = name }), 1, false
    ))
  end
  if drive.health == "failed" then
    table.insert(issues, driveIssue(
      drive, "health", "critical",
      noctalia.tr("alerts.health_failed", { drive = name }), 1, false
    ))
  end

  local temperature = tonumber(noctalia.getConfig("use_hotspot_temperature") == false
    and drive.temperature_c or drive.hotspot_temperature_c or drive.temperature_c)
  local temperatureId = driveIdentity(drive) .. ":temperature"
  local wasTemperatureAlert = previousActive[temperatureId] ~= nil
  local temperatureActive = temperature ~= nil and (
    temperature >= warningTemperature or (wasTemperatureAlert and temperature >= warningTemperature - 3)
  )
  if temperatureActive then
    local critical = temperature >= criticalTemperature
    local cooling = temperature < warningTemperature
    table.insert(issues, driveIssue(
      drive, "temperature", critical and "critical" or "warning",
      noctalia.tr(critical and "alerts.temperature_critical"
        or (cooling and "alerts.temperature_cooling" or "alerts.temperature_warning"), {
        drive = name,
        temperature = string.format("%.0f", temperature),
        threshold = string.format("%.0f", critical and criticalTemperature
          or (cooling and warningTemperature - 3 or warningTemperature)),
      }), temperature, false
    ))
  end

  local life = tonumber(drive.remaining_life_percent)
  if life ~= nil and life <= lifeWarning then
    local critical = life <= 10
    table.insert(issues, driveIssue(
      drive, "endurance", critical and "critical" or "warning",
      noctalia.tr(critical and "alerts.life_critical" or "alerts.life_warning", {
        drive = name, remaining = string.format("%.0f", life),
      }), life, false
    ))
  end

  local spare = tonumber(drive.available_spare_percent)
  local spareThreshold = number(drive.available_spare_threshold_percent, 10)
  if spare ~= nil and spare <= spareThreshold then
    table.insert(issues, driveIssue(
      drive, "available-spare", spare <= math.max(5, spareThreshold / 2) and "critical" or "warning",
      noctalia.tr("alerts.spare_low", { drive = name, spare = string.format("%.0f", spare) }), spare, false
    ))
  end

  if drive.self_test_state == "failed" then
    table.insert(issues, driveIssue(
      drive, "self-test", "critical",
      noctalia.tr("alerts.self_test_failed", { drive = name, status = tostring(drive.self_test_status or "failed") }),
      1, false
    ))
  end

  local criticalWarning = number(drive.critical_warning, 0)
  if criticalWarning > 0 then
    table.insert(issues, driveIssue(
      drive, "critical-warning", "critical",
      noctalia.tr("alerts.nvme_critical", {
        drive = name, value = string.format("0x%02X", math.floor(criticalWarning)),
      }), criticalWarning, true
    ))
  end

  local storage = tonumber(drive.storage_usage_percent)
  if storage ~= nil and storage >= 90 then
    local critical = storage >= 95
    table.insert(issues, driveIssue(
      drive, "storage", critical and "critical" or "warning",
      noctalia.tr(critical and "alerts.storage_critical" or "alerts.storage_warning", {
        drive = name, used = string.format("%.0f", storage),
      }), storage, false
    ))
  end
  return issues
end

local function dependencyIssue(dependencies)
  if type(dependencies) ~= "table" or dependencies.ready then
    return nil
  end
  return {
    id = "dependencies:missing",
    kind = "missing-dependencies",
    drive = noctalia.tr("panel.title"),
    severity = dependencies.blocking and "critical" or "warning",
    title = noctalia.tr("dependencies.alert_title"),
    message = noctalia.tr("dependencies.alert_body", { missing = dependencies.missing_text }),
    value = #(dependencies.missing or {}),
    revision = dependencies.signature,
  }
end

local function collectorIssue(snapshot)
  if snapshot.collector_error == nil or snapshot.collector_error == "" then
    return nil
  end
  return {
    id = "collector:error",
    kind = "collector-error",
    drive = noctalia.tr("panel.title"),
    severity = "critical",
    title = noctalia.tr("alerts.collector_title"),
    message = noctalia.tr("alerts.collector_error", { error = snapshot.collector_error }),
    value = 1,
    revision = tostring(snapshot.collector_error),
  }
end

local MONOTONIC_COUNTERS = {
  { key = "media-errors", field = "media_errors", translation = "alerts.media_errors", critical = true },
  { key = "reallocated", field = "reallocated_sectors", translation = "alerts.reallocated", critical = false },
  { key = "pending", field = "pending_sectors", translation = "alerts.pending", critical = true },
  { key = "uncorrectable", field = "uncorrectable_errors", translation = "alerts.uncorrectable", critical = true },
  { key = "spin-retry", field = "spin_retry_count", translation = "alerts.spin_retry", critical = true },
  { key = "command-timeout", field = "command_timeout_count", translation = "alerts.command_timeout", critical = false },
  { key = "interface-crc", field = "interface_crc_errors", translation = "alerts.interface_crc", critical = false },
  { key = "unsafe-shutdowns", field = "unsafe_shutdowns", translation = "alerts.unsafe_shutdown_increase", critical = false },
  { key = "error-log-entries", field = "error_log_entries", translation = "alerts.error_log_increase", critical = false },
  { key = "warning-temperature-time", field = "warning_temperature_time_minutes", translation = "alerts.warning_temperature_time_increase", critical = false },
  { key = "critical-temperature-time", field = "critical_temperature_time_minutes", translation = "alerts.critical_temperature_time_increase", critical = true },
}
local MONOTONIC_COUNTER_KINDS = {}
for _, counter in ipairs(MONOTONIC_COUNTERS) do
  MONOTONIC_COUNTER_KINDS[counter.key] = true
end

local function checkCounterIncrease(drive, counter)
  local key = driveIdentity(drive) .. ":" .. counter.key
  local current = tonumber(drive[counter.field])
  local previous = tonumber(alertState.counters[key])
  if current ~= nil and previous ~= nil and current > previous and boolConfig("alerts_enabled", true) then
    local title = noctalia.tr("alerts.drive_title", { drive = driveName(drive) })
    local message = noctalia.tr(counter.translation, {
        drive = driveName(drive), count = math.floor(current - previous),
      })
    if counter.critical then
      noctalia.notifyError(title, message)
    else
      noctalia.notify(title, message)
    end
  end
  if current ~= nil and current ~= previous then
    alertState.counters[key] = current
    alertStateDirty = true
  end
end

local function checkMonotonicCounters(drive)
  for _, counter in ipairs(MONOTONIC_COUNTERS) do
    checkCounterIncrease(drive, counter)
  end
end

local function processSnapshot(snapshot)
  if type(snapshot) ~= "table" then
    return
  end
  local previousActive = alertState.active or {}
  local dismissed = copyStateValue(alertState.dismissed or {})
  local active = {}
  local issues = {}
  local alertHdd = boolConfig("alert_hdd", true)
  local missingAlerts = boolConfig("drive_missing_alerts", true)
  local missingGrace = math.max(1, math.floor(number(noctalia.getConfig("missing_grace_scans"), 3)))
  local fullSmartExpected = noctalia.getConfig("system_collector_enabled") == true
  local inventory = copyStateValue(alertState.inventory or {})
  local seen = {}

  local globals = {}
  local missingDependency = dependencyIssue(snapshot.dependencies)
  local collectionFailure = collectorIssue(snapshot)
  if missingDependency ~= nil then
    table.insert(globals, missingDependency)
  end
  if collectionFailure ~= nil then
    table.insert(globals, collectionFailure)
  end
  for _, issue in ipairs(globals) do
    if issue ~= nil then
      active[issue.id] = issue
      table.insert(issues, issue)
    end
  end

  if type(snapshot.disks) == "table" then
    for _, drive in ipairs(snapshot.disks) do
      local id = driveIdentity(drive)
      local eligibleKind = drive.kind == "ssd" or alertHdd
      seen[id] = true
      if missingAlerts and eligibleKind and drive.presence_alert_enabled == true and drive.alerts_enabled ~= false then
        inventory[id] = {
          id = id,
          drive = driveName(drive),
          device = drive.device,
          kind = drive.kind,
          missing_scans = 0,
        }
        legacyMissingSnapshots[id] = nil
      else
        inventory[id] = nil
        legacyMissingSnapshots[id] = nil
      end
      if eligibleKind and drive.alerts_enabled ~= false then
        checkMonotonicCounters(drive)
        for _, issue in ipairs(evaluateDrive(drive, previousActive, fullSmartExpected)) do
          active[issue.id] = issue
          table.insert(issues, issue)
        end
      end
    end
  end

  local collectionHealthy = snapshot.collecting ~= true and snapshot.collector_error == nil
    and not (type(snapshot.dependencies) == "table" and snapshot.dependencies.blocking)
  local collectionId = snapshotCollectionId(snapshot)
  if missingAlerts then
    for id, known in pairs(inventory) do
      local eligibleKind = known.kind == "ssd" or alertHdd
      if not seen[id] and eligibleKind then
        local countScan = false
        if collectionHealthy and collectionId ~= nil then
          countScan = known.last_missing_collection_id ~= collectionId
          known.last_missing_collection_id = collectionId
          legacyMissingSnapshots[id] = nil
        elseif collectionHealthy and legacyMissingSnapshots[id] ~= snapshot then
          countScan = true
          legacyMissingSnapshots[id] = snapshot
        end
        if countScan then
          known.missing_scans = number(known.missing_scans, 0) + 1
        end
        if known.missing_scans >= missingGrace then
          local issue = {
            id = id .. ":missing",
            drive_id = id,
            kind = "drive-missing",
            drive = tostring(known.drive or known.device or id),
            severity = "warning",
            title = noctalia.tr("alerts.drive_title", { drive = tostring(known.drive or id) }),
            message = noctalia.tr("alerts.drive_missing", {
              drive = tostring(known.drive or known.device or id), count = known.missing_scans,
            }),
            value = known.missing_scans,
          }
          active[issue.id] = issue
          table.insert(issues, issue)
        end
      end
    end
  end

  for _, issue in ipairs(issues) do
    local previous = previousActive[issue.id]
    local isNew = previous == nil
    local escalated = previous ~= nil and severityRank(issue.severity) > severityRank(previous.severity)
    local worsened = previous ~= nil and issue.monotonic == true
      and tonumber(issue.value) ~= nil and tonumber(previous.value) ~= nil
      and tonumber(issue.value) > tonumber(previous.value)
    local changed = previous ~= nil and issue.revision ~= nil and issue.revision ~= previous.revision
    if dismissed[issue.id] == nil and (isNew or escalated or worsened or changed) then
      sendIssueNotification(issue)
    end
  end

  if boolConfig("alerts_enabled", true) and boolConfig("notify_recovery", true) then
    for id, previous in pairs(previousActive) do
      if active[id] == nil and dismissed[id] == nil
          and MONOTONIC_COUNTER_KINDS[previous.kind] ~= true then
        noctalia.notify(
          noctalia.tr("alerts.recovered_title", { drive = tostring(previous.drive or noctalia.tr("panel.title")) }),
          noctalia.tr("alerts.recovered_body", { issue = tostring(previous.message or id) })
        )
      end
    end
  end

  table.sort(issues, function(left, right)
    local difference = severityRank(left.severity) - severityRank(right.severity)
    if difference ~= 0 then
      return difference > 0
    end
    return tostring(left.title) < tostring(right.title)
  end)
  local visibleIssues = {}
  local criticalCount = 0
  for _, issue in ipairs(issues) do
    if dismissed[issue.id] == nil then
      table.insert(visibleIssues, issue)
      if issue.severity == "critical" then
        criticalCount += 1
      end
    end
    issue.monotonic = nil
  end

  replaceAlertStateSection("active", active)
  replaceAlertStateSection("inventory", inventory)
  replaceAlertStateSection("dismissed", dismissed)
  snapshot.issues = visibleIssues
  snapshot.summary = snapshot.summary or {}
  snapshot.summary.active_alert_count = #visibleIssues
  snapshot.summary.critical_alert_count = criticalCount
  snapshot.summary.dismissed_alert_count = nil
  persistAlertState()
  noctalia.state.set("snapshot", snapshot)
end

loadAlertState()

noctalia.state.watch("collector_snapshot", function(snapshot)
  processSnapshot(snapshot)
end)

noctalia.state.watch("dismiss_alert_request", function(request)
  if type(request) ~= "table" then
    return
  end
  local dismissed = copyStateValue(alertState.dismissed or {})
  if request.all == true then
    for id in pairs(alertState.active or {}) do
      dismissed[id] = {
        dismissed_at = os.time(),
      }
    end
  elseif request.id ~= nil then
    local id = tostring(request.id)
    local issue = (alertState.active or {})[id]
    if issue ~= nil then
      dismissed[id] = {
        dismissed_at = os.time(),
      }
    end
  else
    return
  end
  replaceAlertStateSection("dismissed", dismissed)

  local currentSnapshot = noctalia.state.get("collector_snapshot")
  if type(currentSnapshot) == "table" then
    processSnapshot(currentSnapshot)
  else
    persistAlertState()
  end
end)

local initialSnapshot = noctalia.state.get("collector_snapshot")
if initialSnapshot ~= nil then
  processSnapshot(initialSnapshot)
end

function onConfigChanged()
  processSnapshot(noctalia.state.get("collector_snapshot"))
end

function onIpc(event, _payload)
  if event == "test-alert" then
    noctalia.notify(noctalia.tr("alerts.test_title"), noctalia.tr("alerts.test_body"))
  end
end
