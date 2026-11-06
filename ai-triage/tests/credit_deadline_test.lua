-- Deadline/value behavior and isolation from ordinary weekly/session urgency.
noctalia = { getConfig = function() return nil end, string = { trim = function(s) return s end } }
local shared = dofile("shared.luau")
local calendar = { scheduleAware = false }
local schedule = {
    scheduleAware = true, sleepStartHour = 22, sleepEndHour = 8.5,
    weekendSleepStartHour = 22, weekendSleepEndHour = 8.5, mealPauseHours = 5,
    burstDurationHours = 2,
}
local function at(day, hour, month)
    return os.time({ year = 2026, month = month or 10, day = day,
        hour = math.floor(hour), min = (hour % 1) * 60, sec = 0 })
end
local now = at(25, 12)
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
local function clone(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do copy[k] = clone(v) end
    return copy
end
local function entry(percent, renewal, expiry, id)
    return { id = id or "openai", display_name = "Codex", status = "ready", fetched_at = iso(now),
        metrics = {
            { label = "Codex 5h", percent = 10, window_secs = 18000, reset_at = iso(now + 3600) },
            { label = "Codex weekly", percent = percent, window_secs = 604800, reset_at = iso(renewal) },
        },
        reset_credits = { available = 1, credits = { { title = "Full reset", expires_at = iso(expiry) } } },
    }
end
local function analyze(e, config)
    local p, stats = shared.analyzeResetCredits({ e }, now, config or calendar)
    local s, w = shared.dualMetrics(e.metrics)
    local item = { entry = e, providerId = e.id, name = e.display_name, sessionMetric = s, weeklyMetric = w }
    local advice = stats[e.id] and stats[e.id].advice
    local base = shared.calculateModelTriageScore(item, nil, now, config or calendar)
    local score = shared.calculateModelTriageScore(item, p, now, config or calendar)
    return advice, score - base, p, item, score
end
local function close(a, b, message)
    assert(math.abs(a - b) < 0.000001, message .. ": " .. tostring(a) .. " vs " .. tostring(b))
end

-- Replay the real dates using the configured 22:00–08:30 + 5h/day allowance.
local renewal, expiry = at(1, 10.25, 11), at(29, 18.75)
local actual = entry(5, renewal, expiry)
local advice, bonus, plan, item = analyze(actual, schedule)
local u = assert(advice.urgency)
assert(advice.status == "advance" and plan.fastTrack.openai)
assert(u.deadlineAt == expiry and u.expiresAt == expiry, "the credit must use Oct 29, not the Nov 1 renewal")
assert(u.availableHours <= shared.calculateActiveHours(now, expiry, schedule, true) - 1,
    "claim budget must fit before expiry with one available-hour margin")
close(u.neededHours, 28.35, "work remaining to reach 95% at gearing 6.3")
assert(bonus > 0 and bonus <= shared.CREDIT_MAX_BONUS, "credit boost must be positive and bounded")
assert(advice.summary:find(os.date("%b %d %H:%M %Z", expiry), 1, true), "advice must name the actual expiry")

-- The old half-week formula ran past the credit's deadline on Thursday morning.
now = at(29, 8.5)
local thursday = entry(80, renewal, expiry)
local thuAdvice = analyze(thursday, schedule)
local thu = assert(thuAdvice.urgency)
assert(thu.availableHours < 6 and thu.deadlineAt == expiry,
    "a six-hour minimum must not extend the claim target beyond the real deadline")
assert(thu.feasible, "80% spent still leaves enough scheduled time to reach 95%")

-- Urgency rises as a deadline tightens, given the same work and refill value.
now = at(25, 12)
local far, farBonus = analyze(entry(60, now + 168 * 3600, now + 72 * 3600))
local near, nearBonus = analyze(entry(60, now + 168 * 3600, now + 24 * 3600))
close(far.cycleGain, near.cycleGain, "equal-value credits")
assert(near.urgency.pressure > far.urgency.pressure and nearBonus > farBonus,
    "earlier expiry must increase pressure rather than reuse half the weekly horizon")
local weaker, weakerBonus = analyze(entry(60, now + 32 * 3600, now + 24 * 3600))
assert(weaker.cycleGain < near.cycleGain and weakerBonus < nearBonus,
    "a smaller useful refill must receive a smaller incentive")

-- Expiry after renewal still leaves a session to use the refill before renewal.
local afterRenewal = analyze(entry(60, now + 48 * 3600, now + 60 * 3600))
assert(afterRenewal.urgency.deadlineAt == now + 48 * 3600)
assert(afterRenewal.urgency.availableHours <= 42,
    "a surviving credit must not recommend claiming too late to use a refill")

-- Limited session allowance reduces the capacity available to reach the threshold.
local blocked = entry(60, now + 168 * 3600, now + 24 * 3600)
blocked.metrics[1].percent, blocked.metrics[1].reset_at = 100, iso(now + 4 * 3600)
local blockedAdvice, _, blockedPlan, blockedItem, blockedScore = analyze(blocked)
close(blockedAdvice.urgency.blockedHours, 4, "current exhausted session wait")
assert(blockedAdvice.urgency.availableHours < near.urgency.availableHours)
assert(blockedScore <= -300, "credit incentives must never override a session lockout")
blocked.metrics[1].percent = 90
local partial = analyze(blocked)
close(partial.urgency.blockedHours, 3.5, "partly available current session")
local impossible = analyze(entry(10, now + 168 * 3600, now + 5.5 * 3600))
assert(impossible.status == "advance" and not impossible.urgency.feasible
    and impossible.urgency.availableHours < 6, "insufficient time must not be presented as a feasible sprint")

-- No opportunity means no score change; deferred/unknown/expired credits stay quiet.
local cases = {
    function(e) e.reset_credits = nil end,
    function(e) e.reset_credits.available = 0 end,
    function(e) e.reset_credits.credits = {} end,
    function(e) e.reset_credits.credits[1].expires_at = iso(now - 1) end,
    function(e) e.stale = true end,
    function(e) e.status = "error" end,
    function(e) e.fetched_at = iso(now - 3600) end,
    function(e) e.metrics[2].reset_at = nil end,
    function(e) table.remove(e.metrics, 2) end,
}
for index, mutate in ipairs(cases) do
    local e = entry(60, now + 168 * 3600, now + 24 * 3600)
    mutate(e)
    local _, delta = analyze(e)
    close(delta, 0, "no false bonus for invalid/unavailable opportunity " .. index)
end
local _, nearRenewalBonus, heldPlan = analyze(entry(97, now + 5 * 3600, now + 240 * 3600))
assert(not heldPlan.fastTrack.openai and nearRenewalBonus == 0,
    "valuable future credits must remain deferred near a natural renewal")
local spent, _, spentPlan, _, spentScore = analyze(entry(100, now + 96 * 3600, now + 24 * 3600))
assert(spent.status == "claim" and spentPlan.optimalClaimProviders.openai and spentScore <= -500,
    "spent weeks must offer a manual claim while retaining their quota lockout")
assert(shared.resetCreditUrgency(item, advice, expiry, schedule, false) == nil,
    "a saved plan must lose its incentive immediately when the credit expires")

-- Named-account and earliest-credit isolation, plus two last-chance providers.
local named = entry(60, now + 168 * 3600, now + 24 * 3600, "openai@work")
local _, namedBonus, namedPlan = analyze(named)
assert(namedBonus > 0 and namedPlan.fastTrack["openai@work"] and not namedPlan.fastTrack.openai)
local default = entry(60, now + 168 * 3600, now + 24 * 3600)
local _, _, _, defaultItem = analyze(default)
close(shared.calculateModelTriageScore(defaultItem, namedPlan, now, calendar),
    shared.calculateModelTriageScore(defaultItem, nil, now, calendar), "named account cannot boost default login")
local two = clone(default)
two.reset_credits.available = 2
table.insert(two.reset_credits.credits, 1, { title = "Later credit", expires_at = iso(now + 240 * 3600) })
local twoAdvice = analyze(two)
assert(twoAdvice.expiresAt == now + 24 * 3600, "only the earliest valid credit sets the deadline")
local other = entry(60, now + 168 * 3600, now + 25 * 3600, "anthropic")
other.display_name = "Claude"
local both, bothStats = shared.analyzeResetCredits({ default, other }, now, calendar)
assert(both.hasCollision and both.fastTrack.openai and both.fastTrack.anthropic
    and bothStats.openai.advice.urgency and bothStats.anthropic.advice.urgency,
    "collisions must not defer either provider's last viable credit")
print("ok: real credit deadlines, bounded value weighting, session capacity, claim guards and account isolation")
