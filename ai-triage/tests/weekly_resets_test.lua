-- Weekly reset observations: no network, filesystem, or synthetic calendar.
local function read(path)
    local f = assert(io.open(path))
    local s = f:read("*a")
    f:close()
    return s
end
local env = setmetatable({ noctalia = {
    string = { trim = function(s) return tostring(s):match("^%s*(.-)%s*$") end },
    getConfig = function() return nil end,
} }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", env))()
local function iso(at) return os.date("!%Y-%m-%dT%H:%M:%SZ", at) end
local now = shared.parseIso("2026-10-22T12:04:37Z")
local oldReset = shared.parseIso("2026-10-27T06:37:01Z")
local newReset = shared.parseIso("2026-10-30T04:00:54Z")
local function entry(at, reset, percent, id, label)
    return { id = id or "openai", status = "ready", fetched_at = iso(at),
        reset_credits = { available = 2 },
        metrics = { { label = label or "Codex weekly", percent = percent, window_secs = 604800, reset_at = iso(reset) } } }
end
local function track(e, history, at)
    return shared.trackWeeklyResets({ entries = { e } }, history, at or shared.parseIso(e.fetched_at))
end

-- Replay Oct 22 -> 23. Zero usage + a later deadline means an early renewal,
-- not a prediction that the old deadline must still occur.
local before = entry(now, oldReset, 50)
local history = track(before)
assert(#history.events == 0 and before.metrics[1].reset_at == iso(oldReset))
local today = shared.parseIso("2026-10-23T06:51:59Z")
local after = entry(today, newReset, 0)
history = track(after, history)
assert(#history.events == 1 and history.events[1].change.kind == "early_renewal")
assert(not history.events[1].change.fewer_credits, "a quota drop must not imply a credit was spent")
assert(after.metrics[1].reset_at == iso(newReset), "never override the upstream date")
local observed = after.metrics[1].reset_observation.event
assert(observed.previous_at == now and observed.previous_source == "ai-usagebar"
    and observed.source == "ai-usagebar" and observed.previous_credits == 2 and observed.credits == 2
    and observed.previous_reset_at_raw == iso(oldReset) and observed.reset_at_raw == iso(newReset),
    "events must retain the two readings used to infer a renewal")
assert(shared.weeklyResetChange(after.metrics[1], today) == observed)
assert(shared.weeklyResetChange(after.metrics[1], today + 86400) == nil, "the notice expires at exactly 24h")
assert(shared.weeklyResetChange(after.metrics[1], today - 1) == nil, "future events must not appear")
local tip = shared.weeklyResetTooltip(after.metrics[1], after, today)
assert(tip:find("Early renewal detected", 1, true) and tip:find("Previously announced", 1, true))
assert(shared.weeklyResetStatus(after.metrics[1], after, today) == "announced")

-- A later unchanged read retains the explanation; duplicates never add events.
local later = entry(today + 300, newReset, 2)
history = track(later, history)
history = track(later, history)
assert(#history.events == 1 and later.metrics[1].reset_observation.event.kind == "early_renewal")
assert(not shared.weeklyResetTooltip(later.metrics[1], later, today + 86401):find("Early renewal detected", 1, true))

-- Old, cached and failed reports cannot replace the baseline or get a new date.
local baseline = history.samples.openai["Codex weekly/604800"]
for _, state in ipairs({ "stale", "error", "older" }) do
    local e = entry(state == "older" and now or today + 600, oldReset, 40)
    e.stale, e.status = state == "stale", state == "error" and "error" or "ready"
    history = track(e, history, today + 600)
    assert(history.samples.openai["Codex weekly/604800"] == baseline, state .. " read must not change history")
    assert(e.metrics[1].reset_observation.event == nil, "an old calendar must not inherit a new renewal")
end
local older = entry(now, newReset, 0)
track(older, history, today)
assert(older.metrics[1].reset_observation.at == now, "an older reading must keep its own age")
assert(shared.weeklyResetStatus(older.metrics[1], older, today) == "stale")
assert(shared.weeklyResetStatus(later.metrics[1], later, today + 1201) == "stale")
assert(shared.weeklyResetStatus(after.metrics[1], after, newReset) == "pending")
assert(shared.weeklyResetStatus({}, after, today) == "pending", "missing deadline must not mean 7d")

-- A scheduled renewal, a date correction, and a source change stay distinct.
local scheduled = entry(oldReset + 1, oldReset + 604800, 0)
local scheduledHistory = track(scheduled, track(before))
assert(scheduledHistory.events[1].change.kind == "renewal")
assert(scheduledHistory.events[1].change.expected == true)
local dateOnly = entry(oldReset + 1, oldReset + 604800, 50)
local dateOnlyHistory = track(dateOnly, track(before))
assert(dateOnlyHistory.events[1].change.expected == true
    and shared.weeklyResetChange(dateOnly.metrics[1], oldReset + 1) == nil,
    "a scheduled rollover without a usage drop is not an unexpected change")
local correction = entry(now + 300, oldReset + 7200, 50)
local corrected = track(correction, track(before))
assert(corrected.events[1].change.kind == "schedule_changed")
local sourceChange = entry(now + 300, newReset, 0)
sourceChange.sections = { { label = "Source", value = "Local agy session" } }
assert(track(sourceChange, track(before)).events[1].change.kind == "schedule_changed",
    "a source switch alone cannot confirm a renewal")
assert(sourceChange.metrics[1].reset_observation.event.previous_source == "ai-usagebar"
    and sourceChange.metrics[1].reset_observation.event.source == "Local agy session")
local drift = entry(now + 300, oldReset + 1, 49)
assert(#track(drift, track(before)).events == 0, "ignore second-level timestamp drift")
local credit = entry(today, newReset, 0)
credit.reset_credits.available = 1
assert(track(credit, track(before)).events[1].change.fewer_credits)

-- Idle now+7d timers and stale cache replays must not produce false alerts.
local idle = entry(now, now + 604800, 0)
local idleLater = entry(now + 7200, now + 7200 + 604800, 0)
local idleHistory = track(idleLater, track(idle))
assert(idleHistory.events[1].change.floating
    and shared.weeklyResetChange(idleLater.metrics[1], now + 7200) == nil)
local activeBefore = entry(now, oldReset, 30)
local wakeup0 = entry(today, today + 604800, 0)
local wakeupHistory = track(wakeup0, track(activeBefore), today)
assert(#wakeupHistory.events == 1 and wakeupHistory.events[1].change.floating == true,
    "active usage dropping to 0% with a now+7d deadline must be treated as a floating idle timer")
assert(shared.weeklyResetChange(wakeup0.metrics[1], today) == nil,
    "floating wake-up at 0% must not trigger an unexpected-change notice")
assert(not shared.weeklyResetTooltip(wakeup0.metrics[1], wakeup0, today):find("Early renewal detected", 1, true),
    "floating wake-up at 0% must not show early renewal in tooltip")
local staleFreshFlag = entry(today, newReset, 0)
local staleHistory = track(staleFreshFlag, track(before), today + 3600)
assert(#staleHistory.events == 0, "an old timestamp cannot acquire a new detection time even if stale=false")
local collected = {}
shared.trackWeeklyResets({ entries = { after } }, track(before), today, collected)
assert(#collected == 1 and collected[1].change.detected_at == today,
    "the service must receive new events separately from the bounded recent history")

-- Baselines remain separate for accounts and model pools, including hidden ones.
local separate = shared.trackWeeklyResets({ entries = {
    entry(now, oldReset, 60, "antigravity@work", "Gemini"),
    entry(now, oldReset, 90, "antigravity@home", "Gemini"),
} }, nil, now)
local pools = entry(now + 300, newReset, 0, "antigravity@work", "Claude & GPT OSS")
separate = track(pools, separate)
assert(#separate.events == 0, "models/accounts must not share a renewal baseline")
assert(separate.samples["antigravity@work"]["Gemini/604800"].percent == 60)
assert(separate.samples["antigravity@home"]["Gemini/604800"].percent == 90)

-- Corrupt state and partial/non-quota metrics are harmless. History is bounded.
local partial = { entries = { 42, { id = "openai", metrics = { 42,
    { label = "Context", group = "context", window_secs = 604800, percent = 50 },
    { label = "Weekly", window_secs = 604800 },
} } } }
assert(#shared.trackWeeklyResets(partial, { version = 1, samples = false, events = false }, now).events == 0)
local bounded = track(before)
for i = 1, 40 do bounded = track(entry(now + i * 300, oldReset + i * 7200, 50), bounded) end
assert(#bounded.events == 32)
shared.trackWeeklyResets({ entries = {} }, bounded, now + 31 * 86400)
assert(next(bounded.samples) == nil, "discard abandoned baselines after 30d")

-- Unknown/old schedules cannot trigger credit claims or weekly sprint urgency.
local pending = entry(now, now - 1, 50)
pending.reset_credits = { available = 1, credits = { { expires_at = iso(now + 86400) } } }
local plan = shared.analyzeResetCredits({ pending }, now)
assert(plan.creditAdvice.openai.status == "hold")
local score = shared.calculateModelTriageScore({ providerId = "openai", entry = pending,
    weeklyMetric = pending.metrics[1] }, nil, now)
assert(score < 100, "an unconfirmed renewal must not cause a weekly sprint")
io.write("ok: weekly renewal replay, stale/out-of-order reads, sources, account isolation and bounded history\n")
