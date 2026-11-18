--!nonstrict
-- Parser tests for source_nut.luau. Run from the plugin directory:
--   luau tests/nut_test.luau

local nut = require("../source_nut")
local fixtures = require("./nut_fixtures")

local checks, failures = 0, 0

local function eq(actual, expected, what: string)
  checks += 1
  if actual ~= expected then
    failures += 1
    print(`FAIL {what}: expected {tostring(expected)}, got {tostring(actual)}`)
  end
end

-- Real device dump, on line, test passed
local s = nut.parseStatus(fixtures.real_ddl_01)
eq(s.source, "nut", "ddl01 source")
eq(s.statusText, "OL", "ddl01 status text")
eq(s.status, "normal", "ddl01 status")
eq(s.supply, "utility", "ddl01 supply")
eq(s.onBattery, false, "ddl01 on battery")
eq(s.lowBattery, false, "ddl01 low battery")
eq(s.model, "CP1500PFCLCD", "ddl01 model")
eq(s.firmware, nil, "ddl01 has no firmware")
eq(s.ratingVoltage, 120, "ddl01 rating V")
eq(s.ratingPowerW, 900, "ddl01 rating W")
eq(s.ratingPowerVA, nil, "ddl01 has no VA rating")
eq(s.inputV, 116, "ddl01 input V")
eq(s.outputV, 140, "ddl01 output V (2.7.4 misreport, kept as reported)")
eq(s.batteryPct, 100, "ddl01 battery")
eq(s.runtimeSec, 1530, "ddl01 runtime")
eq(s.loadPct, 25, "ddl01 load %")
eq(s.loadW, nil, "ddl01 has no real power")
eq(s.line, "none", "ddl01 line")
eq(s.test.result, "passed", "ddl01 test result")
eq(s.test.text, "Done and passed", "ddl01 test text")
eq(s.batteryVoltage, 24, "ddl01 battery voltage")
eq(s.charging, "idle", "ddl01 charging")
eq(s.beeper, "enabled", "ddl01 beeper")
eq(s.transferLowV, 88, "ddl01 transfer low")
eq(s.transferHighV, 139, "ddl01 transfer high")
eq(s.lowBatteryChargePct, 10, "ddl01 low-battery charge")
eq(s.lowBatteryRuntimeSec, 300, "ddl01 low-battery runtime")

-- Real device dump, charging, no test yet
s = nut.parseStatus(fixtures.real_ddl_02)
eq(s.status, "normal", "ddl02 status")
eq(s.charging, "charging", "ddl02 charging")
eq(s.batteryPct, 58, "ddl02 battery")
eq(s.test.result, "none", "ddl02 no test")
eq(s.beeper, "disabled", "ddl02 beeper")

-- 2.8.5 variables
s = nut.parseStatus(fixtures.synth_nut285)
eq(s.model, "CP1500PFCLCDa", "285 model")
eq(s.firmware, "CR01802H1711", "285 firmware")
eq(s.ratingPowerW, 1000, "285 rating W")
eq(s.ratingPowerVA, 1500, "285 rating VA")
eq(s.loadW, 180, "285 real power")
eq(s.inputHz, 60, "285 input frequency")
eq(s.outputHz, 60, "285 output frequency")
eq(s.outputV, 111, "285 output V")

-- Outage states
s = nut.parseStatus(fixtures.synth_on_battery)
eq(s.status, "on_battery", "OB status")
eq(s.supply, "battery", "OB supply")
eq(s.onBattery, true, "OB flag")
eq(s.charging, "discharging", "OB discharging")
eq(s.inputV, 0, "OB input V")

s = nut.parseStatus(fixtures.synth_low_battery)
eq(s.status, "low_battery", "OB LB status")
eq(s.lowBattery, true, "OB LB flag")
eq(s.runtimeSec, 240, "OB LB runtime")

eq(nut.parseStatus(fixtures.synth_boost).line, "boost", "boost line")
eq(nut.parseStatus(fixtures.synth_trim).line, "buck", "trim is buck")

s = nut.parseStatus(fixtures.synth_overload_on_battery)
eq(s.status, "on_battery", "OB OVER status")
eq(s.overload, true, "OB OVER keeps overload flag")

s = nut.parseStatus(fixtures.synth_replace_battery)
eq(s.status, "replace_battery", "RB status")
eq(s.replaceBattery, true, "RB flag")

eq(nut.parseStatus(fixtures.synth_off).status, "off", "OFF status")

-- Failures
local snap, kind, message = nut.parseStatus(fixtures.real_error_refused)
eq(snap, nil, "refused snapshot")
eq(kind, "unreachable", "refused kind")
eq(message, "Connection failure: Connection refused", "refused message")
eq(select(2, nut.parseStatus(fixtures.real_error_nohost)), "unreachable", "no-host kind")
eq(select(3, nut.parseStatus(fixtures.real_error_nohost)), "No such host", "no-host message")
eq(select(2, nut.parseStatus(fixtures.synth_error_stale)), "stale", "stale kind")
eq(select(2, nut.parseStatus(fixtures.synth_error_driver)), "driver", "driver kind")
eq(select(2, nut.parseStatus(fixtures.synth_error_unknown)), "unknown_ups", "unknown-ups kind")
eq(select(2, nut.parseStatus("")), "no_data", "empty output kind")

-- Discovery
local names = nut.parseList(fixtures.synth_list)
eq(#names, 2, "list count")
eq(names[1], "cyberpower", "list first")
eq(names[2], "router-ups", "list second")
names = nut.parseList(fixtures.synth_list_with_noise)
eq(#names, 1, "noisy list count")
eq(names[1], "cyberpower", "noisy list name")

-- UPS address validation
eq(nut.isValidUps("cyberpower"), true, "plain name")
eq(nut.isValidUps("cyberpower@localhost"), true, "name@host")
eq(nut.isValidUps("cyberpower@nas.local:3493"), true, "name@host:port")
eq(nut.isValidUps("ups@[fe80::1]:3493"), true, "IPv6 host")
eq(nut.isValidUps("ups@192.168.1.68"), true, "IPv4 host")
eq(nut.isValidUps(""), false, "empty rejected")
eq(nut.isValidUps("cyber power"), false, "space rejected")
eq(nut.isValidUps("ups'; rm -rf ~"), false, "quote rejected")
eq(nut.isValidUps("ups@host;reboot"), false, "semicolon rejected")

-- Terminal command
eq(
  nut.terminalCommand("cyberpower@localhost", "test"),
  "upscmd 'cyberpower@localhost' test.battery.start.quick; printf '\\nPress Enter to close'; read _",
  "test command"
)
eq(nut.terminalCommand("cyberpower", "nope"), nil, "unknown action")
eq(nut.terminalCommand("bad name", "mute"), nil, "invalid ups")

print(`{checks - failures}/{checks} checks passed`)
if failures > 0 then
  error(`{failures} check(s) failed`)
end
