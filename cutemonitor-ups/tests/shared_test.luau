--!nonstrict
-- Tests for the pure parts of shared.luau (everything above "Words"). Run
-- from the plugin directory:
--   luau tests/shared_test.luau

local shared = require("../shared")

local checks, failures = 0, 0

local function eq(actual, expected, what: string)
  checks += 1
  if actual ~= expected then
    failures += 1
    print(`FAIL {what}: expected {tostring(expected)}, got {tostring(actual)}`)
  end
end

local function near(actual, expected, what: string)
  checks += 1
  if math.abs(actual - expected) > 1e-6 then
    failures += 1
    print(`FAIL {what}: expected {expected}, got {actual}`)
  end
end

local COLORS = { warning = "tertiary", alert = "error" }

-- Runtime text
eq(shared.formatRuntime(nil), "—", "runtime nil")
eq(shared.formatRuntime(0), "0 s", "runtime 0")
eq(shared.formatRuntime(40), "40 s", "runtime seconds")
eq(shared.formatRuntime(59.6), "1 min", "runtime rounds up to a minute")
eq(shared.formatRuntime(2220), "37 min", "runtime minutes")
eq(shared.formatRuntime(3600), "1 h", "runtime whole hour")
eq(shared.formatRuntime(4500), "1 h 15 min", "runtime hours and minutes")
eq(shared.formatRuntime(11400), "3 h 10 min", "runtime 190 min")

-- Stat text
local snap = {
  batteryPct = 100, loadPct = 18, loadW = 180, runtimeSec = 2700,
  inputV = 111.0, outputV = 110.6, inputHz = 60.0, outputHz = 59.94,
  ratingPowerW = 1000, ratingPowerVA = 1500,
}
eq(shared.formatStat("battery_pct", snap), "100%", "battery text")
eq(shared.formatStat("load_pct", snap), "18%", "load % text")
eq(shared.formatStat("load_w", snap), "180 W", "load W text")
eq(shared.formatStat("runtime", snap), "45 min", "runtime text")
eq(shared.formatStat("input_v", snap), "111 V", "input V text")
eq(shared.formatStat("output_v", snap), "111 V", "output V rounds")
eq(shared.formatStat("input_hz", snap), "60.0 Hz", "input Hz text")
eq(shared.formatStat("output_hz", snap), "59.9 Hz", "output Hz text")
eq(shared.formatStat("input_hz", {}), "—", "missing stat text")
eq(shared.formatLoad(snap), "180 W · 18%", "load pair")
eq(shared.formatLoad({ loadPct = 18 }), "18%", "load percent only")
eq(shared.formatLoad({}), nil, "load unknown")
eq(shared.formatRating(snap), "1000 W · 1500 VA", "rating pair")
eq(shared.formatRating({ ratingPowerW = 1000 }), "1000 W", "rating watts only")

-- Sentence case
eq(shared.sentenceCase("Over Voltage"), "Over voltage", "sentence case event")
eq(shared.sentenceCase("Utility Power"), "Utility power", "sentence case source")
eq(shared.sentenceCase("AVR Boost"), "AVR boost", "acronym kept")
eq(shared.sentenceCase("power failure"), "Power failure", "first word capitalized")

-- Watts from load % × rating
local e = shared.enrich({ loadPct = 18, ratingPowerW = 1000 })
eq(e.loadW, 180, "enrich watts")
eq(e.loadWEstimated, true, "enrich marks estimate")
e = shared.enrich({ loadPct = 18, loadW = 175, ratingPowerW = 1000 })
eq(e.loadW, 175, "enrich keeps reported watts")
eq(e.loadWEstimated, nil, "enrich leaves reported watts unmarked")

-- Levels
eq(shared.level(nil, nil), "none", "level none")
eq(shared.level({ status = "normal" }, { state = "lost" }), "lost", "level lost link")
eq(shared.level({ status = "lost_comm" }, { state = "ok" }), "lost", "level lost status")
eq(shared.level({ status = "on_battery", onBattery = true }, nil), "warning", "level on battery")
eq(shared.level({ status = "low_battery", onBattery = true, lowBattery = true }, nil), "alert", "level low battery")
eq(shared.level({ status = "normal", overload = true }, nil), "alert", "level overload flag")
eq(shared.level({ status = "replace_battery", replaceBattery = true }, nil), "alert", "level replace battery")
eq(shared.level({ status = "fault" }, nil), "alert", "level fault")
eq(shared.level({ status = "bypass" }, nil), "warning", "level bypass")
eq(shared.level({ status = "normal", lowBattery = true }, nil), "normal", "LB on utility is not an alert")
eq(shared.level({ status = "normal" }, { state = "ok" }), "normal", "level normal")

eq(shared.levelColor("alert", "secondary", COLORS), "error", "level color alert")
eq(shared.levelColor("warning", "secondary", COLORS), "tertiary", "level color warning")
eq(shared.levelColor("lost", "secondary", COLORS), "on_surface_variant", "level color lost")
eq(shared.levelColor("normal", "secondary", COLORS), "secondary", "level color normal")

-- Stat colors
eq(shared.statColor("load_pct", { loadPct = 80 }, "primary", COLORS, 80), "error", "load at threshold")
eq(shared.statColor("load_w", { loadPct = 79 }, "primary", COLORS, 80), "primary", "load below threshold")
eq(shared.statColor("load_w", { loadPct = 10, overload = true }, "primary", COLORS, 80), "error", "overload flag")
eq(shared.statColor("battery_pct", { onBattery = true }, "primary", COLORS, 80), "tertiary", "battery on battery")
eq(shared.statColor("runtime", { onBattery = true, lowBattery = true }, "primary", COLORS, 80), "error", "runtime low battery")
eq(shared.statColor("input_v", { onBattery = true }, "primary", COLORS, 80), "primary", "volts stay base")
eq(shared.statColor("battery_pct", nil, "primary", COLORS, 80), "primary", "no snapshot")

-- Icons
eq(shared.batteryIcon(nil), "battery", "battery icon unknown")
eq(shared.batteryIcon(100), "battery-4", "battery icon full")
eq(shared.batteryIcon(75), "battery-4", "battery icon 75")
eq(shared.batteryIcon(74), "battery-3", "battery icon 74")
eq(shared.batteryIcon(50), "battery-3", "battery icon 50")
eq(shared.batteryIcon(49), "battery-2", "battery icon 49")
eq(shared.batteryIcon(25), "battery-2", "battery icon 25")
eq(shared.batteryIcon(24), "battery-1", "battery icon 24")
eq(shared.statIcon("battery_pct", { batteryPct = 60, charging = "charging" }), "battery-charging", "charging icon")
eq(shared.statIcon("battery_pct", { batteryPct = 60 }), "battery-3", "battery stat icon")
eq(shared.statIcon("load_w", snap), "bolt", "load icon")
eq(shared.statIcon("output_v", snap), "outlet", "output icon")
eq(shared.powerIcon(nil, "none"), "plug-off", "power icon none")
eq(shared.powerIcon(snap, "lost"), "plug-x", "power icon lost")
eq(shared.powerIcon({ onBattery = true, batteryPct = 60 }, "warning"), "battery-3", "power icon on battery")
eq(shared.powerIcon(snap, "normal"), "plug-connected", "power icon utility")

-- Graph ranges
local lo, hi = shared.graphRange("battery_pct", { 50, 60 }, snap)
eq(lo, 0, "percent range lo")
eq(hi, 100, "percent range hi")
lo, hi = shared.graphRange("load_w", { 150, 210 }, snap)
eq(hi, 1000, "rating range hi")
lo, hi = shared.graphRange("load_w", { 150, 210 }, {})
eq(lo, 150, "watts without rating auto lo")
eq(hi, 210, "watts without rating auto hi")
lo, hi = shared.graphRange("input_v", { 110, 112, 111 }, snap)
eq(lo, 110, "auto range lo")
eq(hi, 112, "auto range hi")
lo, hi = shared.graphRange("input_v", { 111, 111 }, snap)
eq(lo, 110, "flat range centers lo")
eq(hi, 112, "flat range centers hi")
lo, hi = shared.graphRange("input_v", {}, snap)
eq(hi, 1, "empty range")
local n = shared.normalize({ 0, 50, 100, 150 }, 0, 100)
near(n[2], 0.5, "normalize mid")
near(n[4], 1, "normalize clamps")

-- Gauge fill
near(shared.gaugeFraction("battery_pct", { batteryPct = 87 }), 0.87, "gauge battery")
near(shared.gaugeFraction("load_w", snap), 0.18, "gauge watts")
near(shared.gaugeFraction("runtime", { runtimeSec = 1140, runtimeFullSec = 2280 }), 0.5, "gauge runtime half")
near(shared.gaugeFraction("runtime", { runtimeSec = 2280 }), 1, "gauge runtime without reference")
near(shared.gaugeFraction("input_v", { inputV = 111, transferLowV = 88, transferHighV = 139 }), 23 / 51, "gauge volts transfer")
near(shared.gaugeFraction("input_v", { inputV = 120, ratingVoltage = 120 }), 0.5, "gauge volts nominal")
near(shared.gaugeFraction("input_hz", { inputHz = 60 }), 0.5, "gauge 60 Hz")
near(shared.gaugeFraction("input_hz", { inputHz = 50 }), 0.5, "gauge 50 Hz")
near(shared.gaugeFraction("input_v", {}), 0, "gauge missing")

-- Relative age
local key, count = shared.relativeParts(1000, 1030)
eq(key, "time.just_now", "relative just now")
key, count = shared.relativeParts(0, 600)
eq(key, "time.minutes_ago", "relative minutes key")
eq(count, 10, "relative minutes")
key, count = shared.relativeParts(0, 7200)
eq(count, 2, "relative hours")
key, count = shared.relativeParts(0, 3 * 86400)
eq(key, "time.days_ago", "relative days key")
eq(count, 3, "relative days")
eq(shared.relativeParts(100, 50), "time.just_now", "future time is just now")

-- Big-number parts
local function parts(statKey, s)
  local a, b = shared.heroParts(statKey, s)
  return `{a}|{b}`
end
eq(parts("battery_pct", snap), "100%|", "hero battery")
eq(parts("load_w", snap), "180|W", "hero watts")
eq(parts("runtime", { runtimeSec = 2700 }), "45|min", "hero minutes")
eq(parts("runtime", { runtimeSec = 4500 }), "1:15|h", "hero hours")
eq(parts("runtime", { runtimeSec = 40 }), "40|s", "hero seconds")
eq(parts("input_v", { inputV = 111.4 }), "111|V", "hero volts")
eq(parts("output_hz", snap), "59.9|Hz", "hero hertz")
eq(parts("input_v", {}), "—|", "hero missing")

-- Last power event
local log = {
  { key = "boost_on", category = "voltage" },
  { key = "comm_lost", category = "communication" },
  { key = "power_restored", category = "outages" },
  { key = "over_voltage", category = "line_events" },
}
eq(shared.lastPowerEvent(log).key, "power_restored", "skips voltage and communication events")
eq(shared.lastPowerEvent({ log[4] }).key, "over_voltage", "line events count")
eq(shared.lastPowerEvent({ log[1] }), nil, "no power event")
eq(shared.lastPowerEvent(nil), nil, "no log")

print(`{checks - failures}/{checks} checks passed`)
if failures > 0 then
  error(`{failures} check(s) failed`)
end
