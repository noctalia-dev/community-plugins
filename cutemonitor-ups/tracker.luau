--!nonstrict
-- Tracks the UPS over time: sample history and graph series, the events
-- implied by changes between snapshots, the last full-charge runtime, and the
-- last self-test.
--
-- The service feeds it snapshots and saves what it keeps. Nothing here
-- touches Noctalia, so the tests can replay whole outages offline.

local M = {}

M.HISTORY_SEC = 3600

-- History and graph series

function M.newHistory()
  return { samples = {} }
end

-- Records one sample; `stats` maps stat keys to snapshot fields. Samples older
-- than an hour are dropped.
function M.push(history, snap, t: number, stats: { [string]: string })
  local sample = { t = t }
  for key, field in stats do
    sample[key] = snap[field]
  end
  local samples = history.samples
  table.insert(samples, sample)
  local cutoff = t - M.HISTORY_SEC
  while samples[1] ~= nil and samples[1].t <= cutoff do
    table.remove(samples, 1)
  end
end

-- `points` values per stat for the last `spanSec` seconds, oldest first. Each
-- point averages the samples in its time bucket; an empty bucket repeats the
-- point before it, and buckets before the first sample take that sample's
-- value, so lines stay continuous after a restart. Stats with no values in the
-- span are left out.
function M.series(history, now: number, spanSec: number, points: number, statKeys: { string })
  local start = now - spanSec
  local bucketSec = spanSec / points
  local sums, counts = {}, {}
  for _, key in statKeys do
    sums[key] = table.create(points, 0)
    counts[key] = table.create(points, 0)
  end
  for _, sample in history.samples do
    if sample.t > start then
      local index = math.clamp(math.ceil((sample.t - start) / bucketSec), 1, points)
      for _, key in statKeys do
        local value = sample[key]
        if value ~= nil then
          sums[key][index] += value
          counts[key][index] += 1
        end
      end
    end
  end

  local out = {}
  for _, key in statKeys do
    local values = {}
    local first = nil
    for i = 1, points do
      if counts[key][i] > 0 then
        values[i] = sums[key][i] / counts[key][i]
        first = first or values[i]
      end
    end
    if first ~= nil then
      local last = first
      for i = 1, points do
        if values[i] == nil then
          values[i] = last
        else
          last = values[i]
        end
      end
      out[key] = values
    end
  end
  return out
end

-- Events
-- Event: { key, at, category, durationSec?, text? }. Categories match the log
-- switches: outages, communication, self_test, voltage, line_events.

-- Tracker state; `saved` is what the service persisted last time.
function M.newState(saved)
  saved = saved or {}
  return {
    runtimeFullSec = saved.runtimeFullSec,
    test = saved.test, -- { result, text, at }
    lastLineEventAt = saved.lastLineEventAt, -- newest pwrstat "Last Power Event" seen
    prev = nil,
    outage = nil, -- { start, logged, isTest, testKey } while on battery
    lineSince = nil,
    lostSince = nil,
  }
end

-- The parts of the state worth keeping across restarts.
function M.saved(state)
  return {
    runtimeFullSec = state.runtimeFullSec,
    test = state.test,
    lastLineEventAt = state.lastLineEventAt,
  }
end

local function isCorrecting(line)
  return line == "boost" or line == "buck"
end

-- Identity of a self-test result, to notice a test that ran during an outage.
local function testKey(test): string
  if test == nil then
    return ""
  end
  return `{test.result or ""}|{test.text or ""}|{test.at or ""}`
end

-- Power failures and restorations. A self-test also runs on battery for a few
-- seconds, so an outage is logged on its second reading without a self-test
-- in progress (dated to the first reading); one that ends after a single
-- reading is logged at the restoration, unless the self-test result changed
-- meanwhile.
local function trackOutage(state, prev, snap, now: number, events)
  local testing = snap.test ~= nil and snap.test.result == "in_progress"
  local outage = state.outage
  if snap.onBattery then
    if outage == nil then
      state.outage = { start = now, logged = false, isTest = testing, testKey = testKey(prev.test) }
      return
    end
    outage.isTest = outage.isTest or testing
    if not outage.logged and not outage.isTest then
      outage.logged = true
      table.insert(events, { key = "power_failure", at = outage.start, category = "outages" })
    end
  elseif outage ~= nil then
    state.outage = nil
    local durationSec = now - outage.start
    if outage.logged then
      table.insert(events, { key = "power_restored", at = now, durationSec = durationSec, category = "outages" })
    elseif not outage.isTest and testKey(snap.test) == outage.testKey then
      table.insert(events, { key = "power_failure", at = outage.start, category = "outages" })
      table.insert(events, { key = "power_restored", at = now, durationSec = durationSec, category = "outages" })
    end
  end
end

-- Folds a good snapshot into `state` and returns the events it implies,
-- oldest first. The first snapshot only sets the baseline, except for a
-- pwrstat event newer than the one saved: it happened while nothing was
-- watching, so it is caught up. Lost-communication snapshots carry no
-- readings and are ignored.
function M.observe(state, snap, now: number)
  local events = {}
  if snap.status == "lost_comm" then
    return events
  end
  local prev = state.prev

  local function add(key: string, category: string, durationSec: number?)
    table.insert(events, { key = key, at = now, category = category, durationSec = durationSec })
  end

  -- The runtime reported the last time the battery was full, on utility power.
  if snap.batteryPct ~= nil and snap.batteryPct >= 100 and not snap.onBattery and snap.runtimeSec ~= nil then
    state.runtimeFullSec = snap.runtimeSec
  end

  if prev == nil then
    if snap.onBattery then
      -- Already on battery when watching began: the start is unknown, so only
      -- the restoration is logged, timed from now.
      state.outage = { start = now, logged = true, isTest = false, testKey = testKey(snap.test) }
    end
    if isCorrecting(snap.line) then
      state.lineSince = now
    end
  else
    trackOutage(state, prev, snap, now, events)
    if (snap.lowBattery and snap.onBattery) and not (prev.lowBattery and prev.onBattery) then
      add("low_battery", "outages")
    end
    if snap.overload and not prev.overload then
      add("overload", "outages")
    end
    if snap.status == "fault" and prev.status ~= "fault" then
      add("fault", "outages")
    end
    if snap.replaceBattery and not prev.replaceBattery then
      add("replace_battery", "outages")
    end
    if snap.line ~= nil and prev.line ~= nil and snap.line ~= prev.line then
      if isCorrecting(prev.line) then
        add(prev.line .. "_off", "voltage", if state.lineSince then now - state.lineSince else nil)
      end
      if isCorrecting(snap.line) then
        add(snap.line .. "_on", "voltage")
        state.lineSince = now
      else
        state.lineSince = nil
      end
    end
  end

  -- Self-test: pwrstat reports when it ran; NUT doesn't, so a new result is
  -- stamped when it is first seen (and left undated on the baseline).
  local test = snap.test
  if test ~= nil and test.result ~= nil then
    local known = state.test
    local changed = known == nil
      or known.result ~= test.result
      or known.text ~= test.text
      or (test.at ~= nil and known.at ~= test.at)
    if changed then
      local at = test.at or (if prev ~= nil then now else nil)
      state.test = { result = test.result, text = test.text, at = at }
      if prev ~= nil and test.result ~= "none" then
        table.insert(events, { key = "test_" .. test.result, text = test.text, at = at or now, category = "self_test" })
      end
    end
  end

  -- pwrstat's own "Last Power Event" (over/under voltage, blackout)
  local last = snap.lastEvent
  if last ~= nil and last.at ~= nil then
    if state.lastLineEventAt == nil then
      state.lastLineEventAt = last.at
    elseif last.at > state.lastLineEventAt then
      state.lastLineEventAt = last.at
      table.insert(events, {
        key = last.key,
        text = last.text,
        at = last.at,
        durationSec = last.durationSec,
        category = "line_events",
      })
    end
  end

  state.prev = snap
  return events
end

-- Events for the link moving between "ok" and "lost".
function M.linkChange(state, from: string, to: string, now: number)
  if from == "ok" and to == "lost" then
    state.lostSince = now
    return { { key = "comm_lost", at = now, category = "communication" } }
  elseif from == "lost" and to == "ok" then
    local durationSec = if state.lostSince then now - state.lostSince else nil
    state.lostSince = nil
    return { { key = "comm_restored", at = now, category = "communication", durationSec = durationSec } }
  end
  return {}
end

return M
