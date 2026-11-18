--!nonstrict
-- Tests for tracker.luau: replays outages, line changes, self-tests and graph
-- history. Run from the plugin directory:
--   luau tests/tracker_test.luau

local tracker = require("../tracker")

local checks, failures = 0, 0

local function eq(actual, expected, what: string)
  checks += 1
  if actual ~= expected then
    failures += 1
    print(`FAIL {what}: expected {tostring(expected)}, got {tostring(actual)}`)
  end
end

local function keys(events)
  local out = {}
  for _, e in events do
    table.insert(out, e.key)
  end
  return table.concat(out, ",")
end

local function snap(fields)
  local s = { status = "normal", onBattery = false, line = "none", batteryPct = 100, runtimeSec = 2700 }
  for k, v in fields or {} do
    s[k] = v
  end
  return s
end

-- Outage replay
local st = tracker.newState(nil)
eq(keys(tracker.observe(st, snap(), 0)), "", "baseline is quiet")
eq(st.runtimeFullSec, 2700, "full-charge runtime recorded")

local onBattery = { status = "on_battery", onBattery = true, batteryPct = 95, runtimeSec = 2400 }
eq(keys(tracker.observe(st, snap(onBattery), 100)), "", "outage waits for a second reading")
local ev = tracker.observe(st, snap(onBattery), 101)
eq(keys(ev), "power_failure", "outage confirmed")
eq(ev[1].at, 100, "outage dated to its first reading")
eq(ev[1].category, "outages", "outage category")
eq(st.runtimeFullSec, 2700, "reference kept on battery")

ev = tracker.observe(st, snap({ status = "low_battery", onBattery = true, lowBattery = true, batteryPct = 30, runtimeSec = 300 }), 400)
eq(keys(ev), "low_battery", "low battery")
eq(keys(tracker.observe(st, snap({ status = "low_battery", onBattery = true, lowBattery = true, batteryPct = 29 }), 401)), "", "low battery once")

ev = tracker.observe(st, snap({ batteryPct = 31, runtimeSec = 900 }), 700)
eq(keys(ev), "power_restored", "power restored")
eq(ev[1].durationSec, 600, "outage duration")
eq(st.runtimeFullSec, 2700, "reference not updated below full")

tracker.observe(st, snap({ batteryPct = 100, runtimeSec = 2600 }), 800)
eq(st.runtimeFullSec, 2600, "reference updated at full charge")

-- Line correction
ev = tracker.observe(st, snap({ line = "boost" }), 900)
eq(keys(ev), "boost_on", "boost on")
eq(ev[1].category, "voltage", "voltage category")
ev = tracker.observe(st, snap({ line = "none" }), 960)
eq(keys(ev), "boost_off", "boost off")
eq(ev[1].durationSec, 60, "boost duration")
tracker.observe(st, snap({ line = "boost" }), 1000)
eq(keys(tracker.observe(st, snap({ line = "buck" }), 1030)), "boost_off,buck_on", "boost straight to buck")

-- Other critical flags
eq(keys(tracker.observe(st, snap({ line = "buck", overload = true }), 1100)), "overload", "overload")
eq(keys(tracker.observe(st, snap({ line = "buck", status = "fault" }), 1101)), "fault", "fault")
eq(keys(tracker.observe(st, snap({ line = "buck", replaceBattery = true }), 1102)), "replace_battery", "replace battery")

-- Self-tests run on battery but are not outages
local function outageKeys(events)
  local out = {}
  for _, e in events do
    if e.category == "outages" then
      table.insert(out, e.key)
    end
  end
  return table.concat(out, ",")
end
local PASSED_OLD = { result = "passed", text = "Passed", at = 1000 }
local RUNNING = { result = "in_progress", text = "In progress" }
local PASSED_NEW = { result = "passed", text = "Passed", at = 2000 }
local function freshState()
  local s = tracker.newState(nil)
  tracker.observe(s, snap({ test = PASSED_OLD }), 0)
  return s
end

st = freshState()
local seen = outageKeys(tracker.observe(st, snap({ onBattery = true, test = RUNNING }), 10))
  .. outageKeys(tracker.observe(st, snap({ onBattery = true, test = RUNNING }), 11))
  .. outageKeys(tracker.observe(st, snap({ test = PASSED_NEW }), 20))
eq(seen, "", "test in progress from the start is not an outage")

st = freshState()
seen = outageKeys(tracker.observe(st, snap({ onBattery = true, test = PASSED_OLD }), 10))
  .. outageKeys(tracker.observe(st, snap({ onBattery = true, test = RUNNING }), 11))
  .. outageKeys(tracker.observe(st, snap({ test = PASSED_NEW }), 20))
eq(seen, "", "test noticed on the second reading is not an outage")

st = freshState()
seen = outageKeys(tracker.observe(st, snap({ onBattery = true, test = PASSED_OLD }), 10))
  .. outageKeys(tracker.observe(st, snap({ test = PASSED_NEW }), 12))
eq(seen, "", "one-reading outage with a new test result is a test")

st = freshState()
eq(outageKeys(tracker.observe(st, snap({ onBattery = true, test = PASSED_OLD }), 10)), "", "short outage first reading")
ev = tracker.observe(st, snap({ test = PASSED_OLD }), 12)
eq(outageKeys(ev), "power_failure,power_restored", "short real outage logged at restoration")
eq(ev[1].at, 10, "short outage dated to its first reading")
eq(ev[2].durationSec, 2, "short outage duration")

st = tracker.newState(nil)
eq(keys(tracker.observe(st, snap({ onBattery = true }), 0)), "", "already on battery at start")
ev = tracker.observe(st, snap(), 30)
eq(keys(ev), "power_restored", "restoration after starting mid-outage")
eq(ev[1].durationSec, 30, "duration counted from when watching began")

-- Lost-communication snapshots are ignored
local before = st.prev
eq(keys(tracker.observe(st, { status = "lost_comm", onBattery = false }, 1200)), "", "lost comm quiet")
eq(st.prev, before, "lost comm keeps previous snapshot")

-- pwrstat self-test with timestamps
st = tracker.newState(nil)
local oct5 = 1759674152
tracker.observe(st, snap({ test = { result = "passed", text = "Passed", at = oct5 } }), 0)
eq(st.test.at, oct5, "baseline test recorded")
ev = tracker.observe(st, snap({ test = { result = "in_progress", text = "In progress" } }), 50)
eq(keys(ev), "test_in_progress", "test started")
eq(ev[1].category, "self_test", "test category")
ev = tracker.observe(st, snap({ test = { result = "passed", text = "Passed", at = 1760000000 } }), 60)
eq(keys(ev), "test_passed", "test passed")
eq(ev[1].at, 1760000000, "test uses pwrstat's time")
eq(keys(tracker.observe(st, snap({ test = { result = "passed", text = "Passed", at = 1760000000 } }), 61)), "", "same test once")

-- NUT self-test without timestamps
st = tracker.newState(nil)
tracker.observe(st, snap({ test = { result = "none", text = "No test initiated" } }), 0)
eq(st.test.at, nil, "baseline NUT test undated")
ev = tracker.observe(st, snap({ test = { result = "passed", text = "Done and passed" } }), 500)
eq(keys(ev), "test_passed", "NUT test passed")
eq(st.test.at, 500, "NUT test stamped when seen")

-- pwrstat line events and catch-up
st = tracker.newState(nil)
local e1 = { key = "over_voltage", text = "Over Voltage", at = 1000, durationSec = 3 }
eq(keys(tracker.observe(st, snap({ lastEvent = e1 }), 2000)), "", "first line event is baseline")
local e2 = { key = "over_voltage", text = "Over Voltage", at = 3000, durationSec = 3 }
ev = tracker.observe(st, snap({ lastEvent = e2 }), 3005)
eq(keys(ev), "over_voltage", "new line event")
eq(ev[1].at, 3000, "line event keeps pwrstat's time")
eq(ev[1].durationSec, 3, "line event duration")
eq(ev[1].category, "line_events", "line event category")

local saved = tracker.saved(st)
local restarted = tracker.newState(saved)
local e3 = { key = "blackout", text = "Blackout", at = 5000, durationSec = 120 }
ev = tracker.observe(restarted, snap({ lastEvent = e3 }), 9000)
eq(keys(ev), "blackout", "missed event caught up after restart")
restarted = tracker.newState(tracker.saved(restarted))
eq(keys(tracker.observe(restarted, snap({ lastEvent = e3 }), 9100)), "", "caught-up event not repeated")

-- Communication
st = tracker.newState(nil)
eq(keys(tracker.linkChange(st, "ok", "lost", 100)), "comm_lost", "comm lost")
ev = tracker.linkChange(st, "lost", "ok", 145)
eq(keys(ev), "comm_restored", "comm restored")
eq(ev[1].durationSec, 45, "comm outage duration")
eq(keys(tracker.linkChange(st, "starting", "ok", 150)), "", "startup is quiet")

-- Graph history
local stats = { load_w = "loadW", input_v = "inputV" }
local h = tracker.newHistory()
for t = 1, 120 do
  tracker.push(h, { loadW = t, inputV = 111 }, t, stats)
end
local s2 = tracker.series(h, 120, 120, 120, { "load_w", "input_v", "runtime" })
eq(#s2.load_w, 120, "2-minute series length")
eq(s2.load_w[1], 1, "oldest point")
eq(s2.load_w[120], 120, "newest point")
eq(s2.input_v[60], 111, "flat stat")
eq(s2.runtime, nil, "stat without samples left out")

h = tracker.newHistory()
for t = 1, 600, 5 do
  tracker.push(h, { loadW = t }, t, stats)
end
local s10 = tracker.series(h, 600, 600, 120, { "load_w" })
eq(s10.load_w[1], 1, "10-minute first bucket")
eq(s10.load_w[120], 596, "10-minute last bucket")

h = tracker.newHistory()
for t = 111, 120 do
  tracker.push(h, { loadW = 50 + t }, t, stats)
end
local partial = tracker.series(h, 120, 120, 120, { "load_w" })
eq(partial.load_w[1], 161, "leading buckets take the first value")
eq(partial.load_w[120], 170, "newest after restart")

h = tracker.newHistory()
tracker.push(h, { loadW = 1 }, 0, stats)
tracker.push(h, { loadW = 2 }, 3601, stats)
eq(#h.samples, 1, "history trimmed to an hour")

print(`{checks - failures}/{checks} checks passed`)
if failures > 0 then
  error(`{failures} check(s) failed`)
end
