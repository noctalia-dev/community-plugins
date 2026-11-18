--!nonstrict
-- pwrstat data source: parses CyberPower PowerPanel's `pwrstat -status` and
-- `pwrstat -config` output into the plugin's normalized snapshot.
--
-- The service runs the commands and passes the text in. Nothing here touches
-- Noctalia, so the tests can load it with the plain `luau` runner.
--
-- pwrstat prints rows as "<tab><tab>Label<dots> Value" and lists only the rows
-- the UPS model supports, so every snapshot field may be nil.

local M = {}

M.STATUS_ARGV = { "pwrstat", "-status" }
M.CONFIG_ARGV = { "pwrstat", "-config" }
M.TEST_ARGV = { "pwrstat", "-test" }
M.MUTE_ARGV = { "pwrstat", "-mute" }

function M.alarmArgv(enabled: boolean)
  return { "pwrstat", "-alarm", if enabled then "on" else "off" }
end

-- "Label.... Value" with at least two dots; label and value trimmed.
local ROW_PATTERN = "^%s*(.-)%s*%.%.+%s*(.-)%s*$"

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "Over Voltage" -> "over_voltage"
local function keyOf(text)
  return (text:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

local function numberOf(value)
  local n = value and value:match("%-?%d+%.?%d*")
  return n and tonumber(n) or nil
end

-- Local UTC offset in seconds at epoch `t` (e.g. -21600 for MDT).
local function utcOffsetAt(t: number): number
  return os.time(os.date("*t", t)) - t
end

-- "2026/10/05 08:22:32", local time -> epoch seconds. Luau's os.time reads a
-- date table as UTC (unlike Lua's mktime), so the local offset at that moment
-- is taken off; asking twice settles a time near a DST change.
local function parseTimestamp(text)
  local y, mo, d, h, mi, s = text:match("(%d+)/(%d+)/(%d+)%s+(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local asUtc = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  return asUtc - utcOffsetAt(asUtc - utcOffsetAt(asUtc))
end

local UNIT_SECONDS = { sec = 1, min = 60, hour = 3600, day = 86400 }

-- "3 sec." / "2 min" -> seconds
local function parseDuration(text)
  local n, unit = text:match("(%d+)%s*(%a+)")
  if not n then
    return nil
  end
  unit = unit:lower()
  for prefix, seconds in UNIT_SECONDS do
    if unit:sub(1, #prefix) == prefix then
      return tonumber(n) * seconds
    end
  end
  return nil
end

-- "<what> at <timestamp>[ for <duration>]", used by Test Result and Last Power
-- Event. `text` keeps pwrstat's own wording for display.
local function parseEvent(value)
  local what, rest = value:match("^(.-)%s+at%s+(.*)$")
  if not what then
    return { text = value, key = keyOf(value) }
  end
  local stamp, duration = rest:match("^(.-)%s+for%s+(.*)$")
  return {
    text = what,
    key = keyOf(what),
    at = parseTimestamp(stamp or rest),
    durationSec = duration and parseDuration(duration) or nil,
  }
end

-- pwrstat "State" wording -> normalized status
local STATES = {
  normal = "normal",
  power_failure = "on_battery",
  power_failure_restore = "normal",
  low_battery = "low_battery",
  low_battery_restore = "normal",
  lost_communication = "lost_comm",
  communication_established = "normal",
  fault = "fault",
}

local TEST_RESULTS = {
  passed = "passed",
  failed = "failed",
  aborted = "aborted",
  in_progress = "in_progress",
  interrupted = "interrupted",
  unknown = "unknown",
  low_battery = "low_battery",
  low_battert = "low_battery", -- pwrstat 1.4.2 prints "Low Battert"
}

local LINE_MODES = { none = "none", boost = "boost", buck = "buck" }

-- Messages pwrstat prints when it cannot reach a UPS, from the 1.4.2 binary.
local FAILURES = {
  { "Daemon service is not found", "daemon" },
  { "Create socket fail", "daemon" },
  { "send data fail", "daemon" },
  { "recv buffer fail", "daemon" },
  { "Parse daemon response fail", "daemon" },
  { "Permission denied", "permission" },
}

-- Failure kind and the message to show for output that holds no status.
function M.classifyFailure(output: string)
  for _, failure in FAILURES do
    if output:find(failure[1], 1, true) then
      return failure[2], failure[1]
    end
  end
  return "no_data", trim(output):match("[^\n]+") or ""
end

-- Snapshot from `pwrstat -status`, or nil plus a failure kind and message.
function M.parseStatus(text: string)
  if not text:find("Current UPS status", 1, true) then
    return nil, M.classifyFailure(text)
  end

  local rows = {}
  for line in text:gmatch("[^\n]+") do
    local label, value = line:match(ROW_PATTERN)
    if label and label ~= "" then
      rows[label] = value
    end
  end

  local snap = { source = "pwrstat" }
  snap.model = rows["Model Name"]
  snap.firmware = rows["Firmware Number"]
  snap.ratingVoltage = numberOf(rows["Rating Voltage"])
  local rating = rows["Rating Power"]
  if rating then
    -- "1000 Watt(1500 VA)", "1000 Watt", or older "515 VA (335 Watt)"
    snap.ratingPowerW = tonumber(rating:match("(%d+)%s*Watt"))
    snap.ratingPowerVA = tonumber(rating:match("(%d+)%s*VA"))
  end

  local state = rows["State"]
  if state then
    snap.stateText = state
    snap.status = STATES[keyOf(state)] or "other"
  end
  local supply = rows["Power Supply by"]
  if supply then
    local key = keyOf(supply)
    snap.supply = if key == "battery_power" then "battery" elseif key == "utility_power" then "utility" else nil
  end

  snap.inputV = numberOf(rows["Utility Voltage"])
  snap.outputV = numberOf(rows["Output Voltage"])
  snap.inputHz = numberOf(rows["Utility Frequency"])
  snap.outputHz = numberOf(rows["Output Frequency"])
  snap.batteryPct = numberOf(rows["Battery Capacity"])
  local runtimeMin = numberOf(rows["Remaining Runtime"])
  snap.runtimeSec = runtimeMin and runtimeMin * 60 or nil

  local load = rows["Load"]
  if load then
    -- "180 Watt(18 %)" or "18 %"
    snap.loadW = tonumber(load:match("(%d+)%s*Watt"))
    snap.loadPct = tonumber(load:match("(%d+)%s*%%"))
  end

  local line = rows["Line Interaction"]
  if line then
    snap.lineText = line
    snap.line = LINE_MODES[keyOf(line)] or "other"
  end

  if rows["Test Result"] then
    local test = parseEvent(rows["Test Result"])
    test.result = TEST_RESULTS[test.key] or "other"
    snap.test = test
  end
  if rows["Last Power Event"] then
    snap.lastEvent = parseEvent(rows["Last Power Event"])
  end

  snap.onBattery = snap.supply == "battery" or (snap.supply == nil and snap.status == "on_battery")
  snap.lowBattery = snap.status == "low_battery"
  return snap
end

-- `pwrstat -config` labels -> field names, per section
local CONFIG_FIELDS = {
  top = { ["Alarm"] = "alarm", ["Hibernate"] = "hibernate", ["Cloud"] = "cloud" },
  powerFail = {
    ["Delay time since Power failure"] = "delaySec",
    ["Run script command"] = "runScript",
    ["Duration of command running"] = "commandSec",
    ["Enable shutdown system"] = "shutdown",
  },
  lowBattery = {
    ["Remaining runtime threshold"] = "runtimeSec",
    ["Battery capacity threshold"] = "capacityPct",
    ["Run script command"] = "runScript",
    ["Duration of command running"] = "commandSec",
    ["Enable shutdown system"] = "shutdown",
  },
}

-- Daemon policy from `pwrstat -config`, or nil plus a failure kind and message.
-- On/Off values become booleans; numeric values become numbers.
function M.parseConfig(text: string)
  if not text:find("Daemon Configuration", 1, true) then
    return nil, M.classifyFailure(text)
  end
  local config = { powerFail = {}, lowBattery = {} }
  local section = "top"
  for line in text:gmatch("[^\n]+") do
    if line:find("Action for Power Failure", 1, true) then
      section = "powerFail"
    elseif line:find("Action for Battery Low", 1, true) then
      section = "lowBattery"
    else
      local label, value = line:match(ROW_PATTERN)
      local field = label and CONFIG_FIELDS[section][label]
      if field then
        local target = if section == "top" then config else config[section]
        if value == "On" or value == "Off" then
          target[field] = value == "On"
        else
          target[field] = numberOf(value)
        end
      end
    end
  end
  return config
end

return M
