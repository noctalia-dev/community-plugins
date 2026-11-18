--!nonstrict
-- NUT data source: parses `upsc <ups>` output ("variable: value" lines) into
-- the plugin's normalized snapshot, plus `upsc -l` discovery and the upscmd
-- commands behind the panel actions.
--
-- Like source_pwrstat.luau, this only parses text. It reads plain `upsc`
-- output rather than `upsc -j`, which only newer NUT clients support.
--
-- NUT reports status flags, not wording, and keeps no event history or test
-- timestamps; the service derives those from changes it observes.

local M = {}

-- upsname[@host[:port]], including bracketed IPv6 hosts
function M.isValidUps(ups: string): boolean
  return ups:match("^[%w_%.%-]+$") ~= nil or ups:match("^[%w_%.%-]+@[%w_%.:%[%]%-]+$") ~= nil
end

function M.statusArgv(ups: string)
  return { "upsc", ups }
end

function M.listArgv(host: string?)
  return { "upsc", "-l", host or "localhost" }
end

-- Instant commands behind the panel actions; all are listed for the
-- CP1500PFCLCD in NUT's device dumps.
M.INSTANT_COMMANDS = {
  test = "test.battery.start.quick",
  mute = "beeper.mute",
  alarm_on = "beeper.enable",
  alarm_off = "beeper.disable",
}

local function shellQuote(s: string): string
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Shell command for a terminal: upscmd asks for the NUT username and password
-- itself, then the terminal waits for Enter so the result stays readable.
function M.terminalCommand(ups: string, action: string): string?
  local command = M.INSTANT_COMMANDS[action]
  if command == nil or not M.isValidUps(ups) then
    return nil
  end
  return `upscmd {shellQuote(ups)} {command}; printf '\\nPress Enter to close'; read _`
end

-- Messages from NUT's client library (upsclient.c, 2.8.5)
local FAILURES = {
  { "Data stale", "stale" },
  { "Driver not connected", "driver" },
  { "Unknown UPS", "unknown_ups" },
  { "Connection failure", "unreachable" },
  { "No such host", "unreachable" },
  { "Access denied", "denied" },
}

-- Failure kind and the message to show for output that holds no status.
function M.classifyFailure(output: string)
  local message = output:match("Error:%s*([^\n]+)")
  if message then
    for _, failure in FAILURES do
      if message:find(failure[1], 1, true) then
        return failure[2], message
      end
    end
    return "no_data", message
  end
  local first = output:match("^%s*([^\n]+)")
  return "no_data", first or ""
end

-- UPS names from `upsc -l`, one per line.
function M.parseList(text: string): { string }
  local names = {}
  for line in text:gmatch("[^\n]+") do
    local name = line:match("^%s*([%w_%.%-]+)%s*$")
    if name then
      table.insert(names, name)
    end
  end
  return names
end

local function numberOf(value)
  return value and tonumber(value) or nil
end

-- Highest-priority condition first; the individual flags stay on the
-- snapshot so an overload on battery is still visible.
local function statusOf(flags)
  if flags.OFF then
    return "off"
  elseif flags.FSD then
    return "shutdown"
  elseif flags.OB and flags.LB then
    return "low_battery"
  elseif flags.OB then
    return "on_battery"
  elseif flags.OVER then
    return "overload"
  elseif flags.BYPASS then
    return "bypass"
  elseif flags.RB then
    return "replace_battery"
  elseif flags.CAL then
    return "calibrating"
  elseif flags.OL then
    return "normal"
  end
  return "other"
end

-- ups.test.result wording varies by driver; matched by substring, in order.
local TEST_RESULTS = {
  { "passed", "passed" },
  { "warning", "warning" },
  { "error", "failed" },
  { "fail", "failed" },
  { "abort", "aborted" },
  { "progress", "in_progress" },
  { "no test", "none" },
}

local function testResultOf(text: string): string
  local lower = text:lower()
  for _, entry in TEST_RESULTS do
    if lower:find(entry[1], 1, true) then
      return entry[2]
    end
  end
  return "other"
end

-- Snapshot from `upsc <ups>`, or nil plus a failure kind and message.
function M.parseStatus(text: string)
  local vars = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_.]+):%s*(.-)%s*$")
    if key then
      vars[key] = value
    end
  end
  local statusText = vars["ups.status"]
  if statusText == nil then
    return nil, M.classifyFailure(text)
  end

  local flags = {}
  for word in statusText:gmatch("%S+") do
    flags[word] = true
  end

  local snap = { source = "nut", statusText = statusText }
  snap.model = vars["device.model"] or vars["ups.model"]
  snap.firmware = vars["ups.firmware"]
  snap.ratingVoltage = numberOf(vars["input.voltage.nominal"])
  snap.ratingPowerW = numberOf(vars["ups.realpower.nominal"])
  snap.ratingPowerVA = numberOf(vars["ups.power.nominal"])

  snap.status = statusOf(flags)
  snap.supply = if flags.OB then "battery" elseif flags.OL then "utility" else nil
  snap.onBattery = flags.OB == true
  snap.lowBattery = flags.LB == true
  snap.overload = flags.OVER == true
  snap.replaceBattery = flags.RB == true

  snap.inputV = numberOf(vars["input.voltage"])
  snap.outputV = numberOf(vars["output.voltage"])
  snap.inputHz = numberOf(vars["input.frequency"])
  snap.outputHz = numberOf(vars["output.frequency"])
  snap.batteryPct = numberOf(vars["battery.charge"])
  snap.runtimeSec = numberOf(vars["battery.runtime"])
  snap.loadPct = numberOf(vars["ups.load"])
  snap.loadW = numberOf(vars["ups.realpower"])

  snap.line = if flags.BOOST then "boost" elseif flags.TRIM then "buck" else "none"

  local test = vars["ups.test.result"]
  if test then
    snap.test = { text = test, result = testResultOf(test) }
  end

  -- Readings pwrstat never shows (the Readout's NUT extras)
  snap.batteryVoltage = numberOf(vars["battery.voltage"])
  snap.charging = if flags.CHRG then "charging" elseif flags.DISCHRG then "discharging" else "idle"
  snap.beeper = vars["ups.beeper.status"]
  snap.transferLowV = numberOf(vars["input.transfer.low"])
  snap.transferHighV = numberOf(vars["input.transfer.high"])

  -- The UPS's own low-battery thresholds, for the panel's Protection section
  snap.lowBatteryChargePct = numberOf(vars["battery.charge.low"])
  snap.lowBatteryRuntimeSec = numberOf(vars["battery.runtime.low"])
  return snap
end

return M
