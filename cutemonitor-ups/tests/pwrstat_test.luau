--!nonstrict
-- Parser tests for source_pwrstat.luau. Run from the plugin directory:
--   luau tests/pwrstat_test.luau
-- (The standalone runner resolves extensionless paths; Noctalia never loads tests/.)

local pwrstat = require("../source_pwrstat")
local fixtures = require("./fixtures")

local checks, failures = 0, 0

local function eq(actual, expected, what: string)
  checks += 1
  if actual ~= expected then
    failures += 1
    print(`FAIL {what}: expected {tostring(expected)}, got {tostring(actual)}`)
  end
end

-- pwrstat prints local wall-clock time; a parsed epoch must read back the same
-- in local time, whatever the machine's timezone.
local function localText(at)
  return if at then os.date("%Y/%m/%d %H:%M:%S", at) else nil
end

-- Real capture, idle load
local s = pwrstat.parseStatus(fixtures.real_status_idle)
eq(s.source, "pwrstat", "idle source")
eq(s.model, "CP1500PFCLCDa", "idle model")
eq(s.firmware, "CR01802H1711", "idle firmware")
eq(s.ratingVoltage, 120, "idle rating voltage")
eq(s.ratingPowerW, 1000, "idle rating W")
eq(s.ratingPowerVA, 1500, "idle rating VA")
eq(s.stateText, "Normal", "idle state text")
eq(s.status, "normal", "idle status")
eq(s.supply, "utility", "idle supply")
eq(s.inputV, 119, "idle input V")
eq(s.outputV, 119, "idle output V")
eq(s.inputHz, nil, "idle has no frequency")
eq(s.batteryPct, 100, "idle battery")
eq(s.runtimeSec, 190 * 60, "idle runtime")
eq(s.loadW, 0, "idle load W")
eq(s.loadPct, 0, "idle load %")
eq(s.line, "none", "idle line")
eq(s.test.result, "passed", "idle test result")
eq(s.test.text, "Passed", "idle test text")
eq(localText(s.test.at), "2026/10/05 08:22:32", "idle test time")
eq(s.lastEvent.key, "over_voltage", "idle event key")
eq(s.lastEvent.text, "Over Voltage", "idle event text")
eq(localText(s.lastEvent.at), "2026/10/11 20:32:49", "idle event time")
eq(s.lastEvent.durationSec, 3, "idle event duration")
eq(s.onBattery, false, "idle on battery")
eq(s.lowBattery, false, "idle low battery")

-- Timestamps in every season read back as printed: winter time, both sides
-- of the US spring-forward and fall-back changes.
for _, printed in { "2026/01/15 07:05:09", "2026/03/08 01:30:00", "2026/03/08 03:30:00", "2026/11/01 00:30:00", "2026/11/01 03:30:00" } do
  local text = fixtures.real_status_idle:gsub("Passed at [%d/]+ [%d:]+", "Passed at " .. printed)
  eq(localText(pwrstat.parseStatus(text).test.at), printed, "test time " .. printed)
end

-- Real capture, under load
s = pwrstat.parseStatus(fixtures.real_status_loaded)
eq(s.inputV, 112, "loaded input V")
eq(s.runtimeSec, 37 * 60, "loaded runtime")
eq(s.loadW, 210, "loaded load W")
eq(s.loadPct, 21, "loaded load %")

-- Real daemon configuration
local c = pwrstat.parseConfig(fixtures.real_config)
eq(c.alarm, true, "config alarm")
eq(c.hibernate, false, "config hibernate")
eq(c.cloud, false, "config cloud")
eq(c.powerFail.delaySec, 60, "config power-fail delay")
eq(c.powerFail.runScript, true, "config power-fail script")
eq(c.powerFail.commandSec, 0, "config power-fail command time")
eq(c.powerFail.shutdown, true, "config power-fail shutdown")
eq(c.lowBattery.runtimeSec, 300, "config low-battery runtime")
eq(c.lowBattery.capacityPct, 35, "config low-battery capacity")
eq(c.lowBattery.shutdown, true, "config low-battery shutdown")

-- Synthesized outage states
s = pwrstat.parseStatus(fixtures.synth_on_battery)
eq(s.status, "on_battery", "on-battery status")
eq(s.supply, "battery", "on-battery supply")
eq(s.onBattery, true, "on-battery flag")
eq(s.inputV, 0, "on-battery input V")
eq(s.batteryPct, 87, "on-battery battery")
eq(s.runtimeSec, 38 * 60, "on-battery runtime")

s = pwrstat.parseStatus(fixtures.synth_low_battery)
eq(s.status, "low_battery", "low-battery status")
eq(s.lowBattery, true, "low-battery flag")
eq(s.onBattery, true, "low-battery on battery")

s = pwrstat.parseStatus(fixtures.synth_lost_comm)
eq(s.status, "lost_comm", "lost-comm status")
eq(s.model, "CP1500PFCLCDa", "lost-comm keeps properties")
eq(s.batteryPct, nil, "lost-comm has no battery")
eq(s.onBattery, false, "lost-comm not on battery")

-- Alternate row formats
s = pwrstat.parseStatus(fixtures.synth_other_model)
eq(s.ratingPowerW, 1000, "watt-only rating W")
eq(s.ratingPowerVA, nil, "watt-only rating VA")
eq(s.loadW, nil, "percent-only load W")
eq(s.loadPct, 18, "percent-only load %")
eq(s.inputHz, 60.0, "input frequency")
eq(s.outputHz, 59.9, "output frequency")
eq(s.line, "boost", "boost line")
eq(s.test.result, "low_battery", "misspelled test result")
eq(s.lastEvent.key, "under_voltage", "under-voltage event")
eq(s.lastEvent.durationSec, 120, "minute duration")

s = pwrstat.parseStatus(fixtures.synth_older_rating)
eq(s.ratingPowerW, 335, "older rating W")
eq(s.ratingPowerVA, 515, "older rating VA")

-- Failures
local snap, kind, message = pwrstat.parseStatus(fixtures.error_daemon)
eq(snap, nil, "daemon error snapshot")
eq(kind, "daemon", "daemon error kind")
eq(message, "Daemon service is not found", "daemon error message")
eq(select(2, pwrstat.parseStatus(fixtures.error_socket)), "daemon", "socket error kind")
eq(select(2, pwrstat.parseStatus(fixtures.error_empty)), "no_data", "empty output kind")
eq(select(3, pwrstat.parseStatus(fixtures.error_garbage)), "something unexpected", "garbage message")
eq(select(2, pwrstat.parseConfig(fixtures.error_daemon)), "daemon", "config daemon error")

print(`{checks - failures}/{checks} checks passed`)
if failures > 0 then
  error(`{failures} check(s) failed`)
end
