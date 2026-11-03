-- Regression tests for shared date parsing. Run with a timezone that observes DST:
--
--   TZ=America/New_York lua tests/shared_test.lua

assert(os.getenv("TZ") == "America/New_York", "run with TZ=America/New_York")

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local noctalia = {
    string = {
        trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
    },
}
local env = setmetatable({ noctalia = noctalia }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", env))()

local cases = {
    { "winter", "2024-01-10T12:00:00Z", 1704888000 },
    { "summer", "2024-07-10T12:00:00Z", 1720612800 },
    { "before spring transition", "2024-03-10T06:30:00Z", 1710052200 },
    { "after spring transition", "2024-03-10T07:30:00Z", 1710055800 },
}

for _, case in ipairs(cases) do
    local name, input, expected = case[1], case[2], case[3]
    local actual = shared.parseIso(input)
    assert(actual == expected,
        string.format("%s: expected %d for %s, got %s", name, expected, input, tostring(actual)))
end

assert(type(shared.terminalAuth) == "function", "terminal authentication classifier should exist")
assert(type(shared.transportError) == "function", "transport error classifier should exist")

local retired = {
    id = "anthropic",
    error = "",
    sections = {
        { type = "text", label = "HTTP 403", value = "authentication rejected" },
    },
}
assert(shared.terminalAuth(retired), "403 authentication rejection should be terminal")
assert(shared.terminalAuth({ error = "HTTP 401: authorization token expired" }),
       "401 expired authorization should be terminal")
assert(not shared.terminalAuth({ error = "HTTP 429 authentication rate limited" }),
       "rate limiting should stay transient")
assert(not shared.terminalAuth({ error = "HTTP 500 authentication service unavailable" }),
       "server errors should stay transient")
assert(not shared.terminalAuth({ error = "authentication rejected by local configuration" }),
       "authentication wording without HTTP 401 or 403 should stay visible")
assert(shared.transportError("HTTP 500: internal error"), "HTTP failures should be transport details")
assert(not shared.transportError("The weekly window resets soon"), "ordinary prose should remain content")

local filtered = shared.entries({ entries = {
    retired,
    { id = "openai", sections = {} },
} })
assert(#filtered == 1 and filtered[1].id == "openai",
       "terminal providers should be filtered from shared entries")

local function usageEntry(id, percent)
    return {
        id = id,
        status = "ready",
        stale = false,
        metrics = { { percent = percent } },
        sections = {},
    }
end

local parserFailure = { id = "openai", status = "error", metrics = {}, sections = {},
    error = "schema mismatch: openai usage response: invalid type: null, expected a sequence" }
assert(#shared.entries({ entries = { parserFailure } }) == 1,
       "a parser failure must remain visible because it does not prove the account is unavailable")
assert(shared.unavailable(parserFailure), "failed readings must not be drawn as live metrics")

local unavailable = usageEntry("anthropic", 0)
unavailable.stale = true
unavailable.sections = {
    { type = "text", label = "HTTP 429", value = "Rate limited" },
}
local ordered = shared.entries({ entries = {
    unavailable,
    usageEntry("openai", 32),
    usageEntry("antigravity", 99),
} })
assert(#ordered == 2, "providers with their own refresh failure should be removed")
assert(ordered[1].id == "antigravity" and ordered[2].id == "openai",
       "working providers should be ordered by highest usage")

local bottleneckEntry = {
    id = "openai",
    status = "ready",
    stale = false,
    metrics = {
        { label = "Codex 5h", percent = 0, severity = "low" },
        { label = "Codex weekly", percent = 100, severity = "critical" },
    },
    sections = {},
}
local headlineMetric = shared.headline(bottleneckEntry)
assert(headlineMetric ~= nil and headlineMetric.label == "Codex weekly" and headlineMetric.percent == 100,
       "headline should select the bottleneck/highest severity metric across windows")

local tieSeverityEntry = {
    id = "openai",
    status = "ready",
    stale = false,
    metrics = {
        { label = "Session", percent = 15, severity = "low" },
        { label = "Weekly", percent = 45, severity = "low" },
    },
    sections = {},
}
local tieMetric = shared.headline(tieSeverityEntry)
assert(tieMetric ~= nil and tieMetric.label == "Session" and tieMetric.percent == 15,
       "headline should prioritize active session when broader windows are not critical")

local reordered = shared.entries({ entries = {
    usageEntry("antigravity", 50),
    bottleneckEntry,
} })
assert(reordered[1].id == "openai" and reordered[2].id == "antigravity",
       "a provider with critical 100% weekly limit should rank above a 50% low severity provider")

local antigravityEntry = {
    id = "antigravity",
    status = "ready",
    stale = false,
    metrics = {
        { label = "Gemini", percent = 0, severity = "low" },
        { label = "Claude & GPT OSS", percent = 0, severity = "low" },
        { label = "Gemini", percent = 24, severity = "low" },
        { label = "Claude & GPT OSS", percent = 100, severity = "critical" },
    },
    sections = {},
}
assert(#shared.modelHeadlines(bottleneckEntry) == 0,
       "single-model providers should have no sub-model headlines")
local agyModels = shared.modelHeadlines(antigravityEntry)
assert(#agyModels == 2, "antigravity should extract both model headlines")
assert(agyModels[1].model == "Gemini" and agyModels[1].glyph == "brand-google" and agyModels[1].metric.percent == 0,
       "gemini should resolve to its active session")
assert(agyModels[2].model == "Claude & GPT OSS" and agyModels[2].glyph == "robot" and agyModels[2].displayName == "Claude & GPT OSS" and agyModels[2].metric.percent == 0 and agyModels[2].blockingMetric.percent == 100,
       "claude/oss should preserve its identity, session and exhausted quota")

local normalAgy = {
    id = "antigravity",
    status = "ready",
    stale = false,
    metrics = {
        { label = "Gemini", percent = 11, severity = "low" },
        { label = "Claude & GPT OSS", percent = 0, severity = "low" },
        { label = "Gemini", percent = 43, severity = "low" },
        { label = "Claude & GPT OSS", percent = 78, severity = "high" },
    },
    sections = {},
}
local normalHeadline = shared.headline(normalAgy)
assert(normalHeadline ~= nil and normalHeadline.percent == 11,
       "antigravity headline should pick highest active session (11%) when no metric is critical")

local session = { label = "Gemini", percent = 100, severity = "critical", reset_at = "2030-01-01T02:00:00Z" }
local weekly = { label = "Gemini", percent = 100, severity = "critical", reset_at = "2030-01-06T02:00:00Z" }
assert(shared.headline({ id = "openai", metrics = { session, weekly } }) == weekly,
       "two exhausted windows must use the latest reset")
weekly.percent = 90
local oneModel = { id = "antigravity", metrics = { session, weekly } }
assert(shared.headline(oneModel) == session, "critical but usable weekly quota must not block the session")
local oneHeadline = shared.modelHeadlines(oneModel)
assert(#oneHeadline == 1 and oneHeadline[1].blockingMetric == session,
       "a single model must retain its actual exhausted window")
session.percent, weekly.percent = 0, 100
assert(shared.headline(oneModel) == weekly, "one model must show its exhausted weekly quota")

assert(shared.providerDashboard("anthropic") == "https://claude.ai/settings/usage", "Claude plan usage URL")
assert(shared.providerDashboard("anthropic_api") == "https://console.anthropic.com/", "API usage stays in the console")
assert(shared.providerDashboard("openai@work") == "https://chatgpt.com/codex/settings/usage", "account suffix keeps Codex usage URL")
assert(shared.providerDashboard("antigravity") == "https://antigravity.google/", "Antigravity opens its own service")
assert(shared.providerDashboard("grok") == "https://console.x.ai/", "Grok API stays in the xAI console")
assert(shared.providerDashboard("supergrok") == "https://grok.com/", "SuperGrok opens the consumer service")
assert(shared.providerDashboard("unknown") == nil, "unknown provider returns nil dashboard")

local mShort, mWeekly = shared.dualMetrics({
    { label = "Weekly", percent = 90, window_secs = 604800 },
    { label = "Session", percent = 20, window_secs = 18000 },
})
assert(mShort.percent == 20 and mWeekly.percent == 90, "dualMetrics should sort 5h/session first regardless of input order")

local labelShort, labelWeekly = shared.dualMetrics({
    { label = "Codex weekly", percent = 80 },
    { label = "Codex 5h", percent = 15 },
})
assert(labelShort.percent == 15 and labelWeekly.percent == 80, "dualMetrics should detect 5h vs weekly from labels")

local singleWeeklyShort, singleWeeklyWeekly = shared.dualMetrics({
    { label = "Weekly only", percent = 70, window_secs = 604800 },
})
assert(singleWeeklyShort == nil and singleWeeklyWeekly.percent == 70, "dualMetrics should identify single weekly metric")

local singleSessionShort, singleSessionWeekly = shared.dualMetrics({
    { label = "5h only", percent = 30, window_secs = 18000 },
})
assert(singleSessionShort.percent == 30 and singleSessionWeekly == nil, "dualMetrics should identify single session metric")

local malformedShort, malformedWeekly = shared.dualMetrics({ 42, { label = "Weekly", percent = 90, window_secs = 604800 } })
assert(malformedShort == nil and malformedWeekly.percent == 90,
    "dualMetrics should discard malformed entries before choosing a window")
local onlyMalformedShort, onlyMalformedWeekly = shared.dualMetrics({ 42 })
assert(onlyMalformedShort == nil and onlyMalformedWeekly == nil,
    "dualMetrics should not return a scalar metric")

local reorderedModels = shared.modelHeadlines({ id = "antigravity", metrics = {
    { label = "Gemini", percent = 90, window_secs = 604800 },
    { label = "Gemini", percent = 20, window_secs = 18000 },
} })
assert(#reorderedModels == 1 and reorderedModels[1].metric.percent == 20,
    "Antigravity headline should use the session window when weekly arrives first")

local balanceDeepseek = {
    id = "deepseek", status = "ready", stale = false, metrics = {},
    sections = {
        { type = "spacer" },
        { type = "text", label = "Balance", value = "$2.90" },
        { type = "block", label = "Breakdown", body = { "granted $0.00 · topped-up $2.90" } },
    },
}
assert(shared.balanceText(balanceDeepseek) == "$2.90",
    "a balance section should surface as the capsule reading")

local balanceNous = {
    id = "nous", status = "ready", stale = false, metrics = {},
    sections = {
        { type = "text", label = "Subscription credits", value = "0.00 remaining" },
        { type = "text", label = "Top-up credits", value = "8.19 remaining" },
        { type = "text", label = "Total usable credits", value = "8.19" },
        { type = "text", label = "Renews", value = "25d 20h" },
    },
}
assert(shared.balanceText(balanceNous) == "8.19",
    "total usable credits should win over the reset countdown")
assert(shared.balanceText({ id = "nous", metrics = {}, sections = {
    { type = "text", label = "Top-up credits", value = "8.19 remaining" },
} }) == "8.19 remaining", "a lone credit line is still a balance")
assert(shared.balanceText(usageEntry("openai", 12)) == nil,
    "a percentage provider must keep its metric and report no balance text")
assert(shared.balanceText({ id = "deepseek", metrics = {}, sections = {
    { type = "text", label = "Balance", value = "credentials error: no API key" },
} }) == nil, "an error line is not a balance")

-- ── Mathematical triage optimization tests ──────────────────────────────────
local function isoIn(secondsAhead)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + secondsAhead)
end

-- 1. Hard constraints / lockouts
local unavailItem = { entry = { status = "error" }, sessionMetric = { percent = 0 }, weeklyMetric = { percent = 0 } }
assert(shared.calculateModelTriageScore(unavailItem) == -1000, "unavailable model must receive -1000")

local weeklyExhaustedItem = {
    entry = { status = "ready" },
    sessionMetric = { percent = 10 },
    weeklyMetric = { percent = 100 },
}
assert(shared.calculateModelTriageScore(weeklyExhaustedItem) <= -500, "100% weekly exhausted must lockout <= -500")

local sessionExhaustedItem = {
    entry = { status = "ready" },
    sessionMetric = { percent = 100 },
    weeklyMetric = { percent = 50 },
}
assert(shared.calculateModelTriageScore(sessionExhaustedItem) <= -300, "100% session exhausted must lockout <= -300")

-- 2. Weekly reset imminence bonus (Double-quota opportunity)
-- An item with weekly reset in 12h vs 5 days, same 30% free weekly quota:
local weeklyImminent = {
    entry = { status = "ready" },
    sessionMetric = { percent = 0, window_secs = 18000, reset_at = nil },
    weeklyMetric = { percent = 70, window_secs = 604800, reset_at = isoIn(12 * 3600) },
}
local weeklyFar = {
    entry = { status = "ready" },
    sessionMetric = { percent = 0, window_secs = 18000, reset_at = nil },
    weeklyMetric = { percent = 70, window_secs = 604800, reset_at = isoIn(120 * 3600) },
}
local scoreImminent = shared.calculateModelTriageScore(weeklyImminent)
local scoreFar = shared.calculateModelTriageScore(weeklyFar)
assert(scoreImminent > scoreFar,
    string.format("imminent weekly reset (%f) must outrank far reset (%f) to enable double-quota consumption", scoreImminent, scoreFar))

-- 3. Session pacing: active session expiring soon with unused quota
local sessionExpiringSoon = {
    entry = { status = "ready" },
    sessionMetric = { percent = 5, window_secs = 18000, reset_at = isoIn(20 * 60) }, -- 20 min left, 95% free
    weeklyMetric = { percent = 30, window_secs = 604800, reset_at = isoIn(80 * 3600) },
}
local sessionJustStarted = {
    entry = { status = "ready" },
    sessionMetric = { percent = 5, window_secs = 18000, reset_at = isoIn(280 * 60) }, -- 4h 40m left, 95% free
    weeklyMetric = { percent = 30, window_secs = 604800, reset_at = isoIn(80 * 3600) },
}
local scoreExpiring = shared.calculateModelTriageScore(sessionExpiringSoon)
local scoreJustStarted = shared.calculateModelTriageScore(sessionJustStarted)
assert(scoreExpiring > scoreJustStarted,
    string.format("session about to expire with quota (%f) must be prioritized over freshly started (%f)", scoreExpiring, scoreJustStarted))

-- 4. Coupling between weekly health and session consumption:
-- Given two models with identical 5h session metrics, the one with ample weekly headroom
-- must heavily outrank the one at risk of weekly starvation.
local modelHealthyWeekly = {
    entry = { status = "ready" },
    sessionMetric = { percent = 20, window_secs = 18000, reset_at = isoIn(3 * 3600) },
    weeklyMetric = { percent = 20, window_secs = 604800, reset_at = isoIn(100 * 3600) }, -- 80% weekly free
}
local modelDepletedWeekly = {
    entry = { status = "ready" },
    sessionMetric = { percent = 20, window_secs = 18000, reset_at = isoIn(3 * 3600) },
    weeklyMetric = { percent = 92, window_secs = 604800, reset_at = isoIn(100 * 3600) }, -- only 8% weekly free with 4 days to go!
}
local scoreHealthy = shared.calculateModelTriageScore(modelHealthyWeekly)
local scoreDepleted = shared.calculateModelTriageScore(modelDepletedWeekly)
assert(scoreHealthy > scoreDepleted * 3,
    string.format("healthy weekly quota (%f) must dominate depleted weekly quota (%f)", scoreHealthy, scoreDepleted))

-- 5. Reset credit analysis, collision detection, and staggering plan
local mockCandidates = {
    {
        id = "anthropic",
        display_name = "Claude",
        metrics = {
            { label = "Session (5h)", percent = 0, reset_at = isoIn(3 * 3600), window_secs = 18000 },
            { label = "Weekly (7d)", percent = 74, reset_at = isoIn(50 * 3600), window_secs = 604800 },
        },
        reset_credits = {
            available = 1,
            credits = {
                { title = "Claude Opus 5.5 launch reset", expires_at = isoIn(11.7 * 86400) },
            },
        },
    },
    {
        id = "openai",
        display_name = "Codex",
        metrics = {
            { label = "Codex 5h", percent = 2, reset_at = isoIn(3 * 3600), window_secs = 18000 },
            { label = "Codex weekly", percent = 29, reset_at = isoIn(80 * 3600), window_secs = 604800 },
        },
        reset_credits = {
            available = 3,
            credits = {
                { title = "Full reset 1", expires_at = isoIn(11.8 * 86400) },
                { title = "Full reset 2", expires_at = isoIn(18.8 * 86400) },
                { title = "Full reset 3", expires_at = isoIn(26.8 * 86400) },
            },
        },
    },
}

-- Calendar hours keep the claim arithmetic independent of the time of day the test runs at
local calendarHours = { scheduleAware = false }
local plan, stats = shared.analyzeResetCredits(mockCandidates, os.time(), calendarHours)
assert(plan.hasCollision == true, "collision must be detected between Claude and Codex expiring in ~11.7d")
assert(plan.advanceProviderId == "anthropic", "claude must be chosen to advance due to higher weekly progress and single credit constraint")
assert(plan.deferProviderId == "openai", "codex must be chosen to defer")
assert(plan.advanceNow == true and plan.fastTrack["anthropic"] == true,
    "claude has 50h left to burn 26% and still use the refill, so it advances this cycle")
assert(stats["openai"].advice.status == "hold", "the deferred credit waits for a later cycle")

-- Verify stagger pacing elevates advance provider score
local claudeItem = {
    providerId = "anthropic",
    entry = mockCandidates[1],
    sessionMetric = mockCandidates[1].metrics[1],
    weeklyMetric = mockCandidates[1].metrics[2],
}
local normalClaudeScore = shared.calculateModelTriageScore(claudeItem, nil)
local staggeredClaudeScore = shared.calculateModelTriageScore(claudeItem, plan)
assert(staggeredClaudeScore > normalClaudeScore,
    string.format("staggered score (%f) must exceed normal score (%f) to accelerate mid-cycle burn", staggeredClaudeScore, normalClaudeScore))

-- A claim is only worth it with enough active hours left before the natural renewal
local function creditCandidate(weeklyPct, renewHours, expiryHours)
    return {
        id = "anthropic",
        display_name = "Claude",
        metrics = {
            { label = "Weekly (7d)", percent = weeklyPct, reset_at = isoIn(renewHours * 3600), window_secs = 604800 },
        },
        reset_credits = {
            available = 1,
            credits = { { title = "Launch reset", expires_at = isoIn(expiryHours * 3600) } },
        },
    }
end
local function adviseFor(weeklyPct, renewHours, expiryHours)
    local p, st = shared.analyzeResetCredits({ creditCandidate(weeklyPct, renewHours, expiryHours) }, os.time(), calendarHours)
    return st["anthropic"], p
end

-- 97% with the renewal 5h away: a claim buys back one session at most, the credit is worth a full week next cycle
local nearRenewal, nearPlan = adviseFor(97, 5, 240)
assert(nearRenewal.advice.status == "hold", "a reset right before the weekly renewal must be held, got " .. nearRenewal.advice.status)
assert(nearRenewal.canClaimNow == false and nearPlan.optimalClaimProviders["anthropic"] == nil,
    "no claim may be flagged 5h before the weekly renewal")
assert(nearPlan.fastTrack["anthropic"] == nil, "no fast-track when the cycle ends before a claim pays off")
assert(nearRenewal.advice.laterGain > 90 and nearRenewal.advice.cycleGain < 15,
    string.format("later gain %.1f must dwarf the %.1f available now", nearRenewal.advice.laterGain, nearRenewal.advice.cycleGain))
local spentNearRenewal = adviseFor(100, 5, 240)
assert(spentNearRenewal.advice.status == "hold", "even a spent week keeps the reset when the renewal is 5h away")

-- Spent with four days left: the refill can be burnt in full before the renewal
local spentEarly, spentPlan = adviseFor(100, 96, 240)
assert(spentEarly.advice.status == "claim" and spentEarly.canClaimNow == true, "a week spent with 4 days left must claim")
assert(spentPlan.optimalClaimProviders["anthropic"] == true, "plan must register anthropic in optimalClaimProviders")

-- Spent and the credit expires before the renewal: any gain beats losing it
local expiring = adviseFor(100, 20, 10)
assert(expiring.advice.status == "claim", "a credit that dies before the renewal must be claimed while the week is spent")

-- Not spent yet with time to spare: claim once the week runs out, not before
local midWeek, midPlan = adviseFor(60, 96, 216)
assert(midWeek.advice.status == "advance" and midWeek.canClaimNow == false, "a 60% week must not claim yet")
assert(midPlan.fastTrack["anthropic"] == nil, "without a collision the next cycle still pays, so no fast-track")

-- The credit expires before the renewal: this cycle is its last chance, so it is fast-tracked
local lastChance, lastPlan = adviseFor(60, 96, 84)
assert(lastChance.advice.status == "advance" and lastChance.advice.lastChance == true, "a credit expiring this cycle is a last chance")
assert(lastPlan.fastTrack["anthropic"] == true, "the last payable cycle must be fast-tracked")

-- Only the next credit to spend carries the claim badge and the advice
local multiCredit = creditCandidate(100, 96, 240)
multiCredit.reset_credits = {
    available = 2,
    credits = {
        { title = "First reset", expires_at = isoIn(240 * 3600) },
        { title = "Second reset", expires_at = isoIn(400 * 3600) },
    },
}
multiCredit.sections = { { type = "block", label = "Reset credits", body = { "First reset · expires in 10d", "Second reset · expires in 16d" } } }
local multiPlan = shared.analyzeResetCredits({ multiCredit }, os.time(), calendarHours)
local multiCards = shared.collectResetCredits({ multiCredit }, multiPlan)
assert(#multiCards == 2, "both credits are listed")
assert(multiCards[1].role == "claim" and multiCards[1].advice ~= nil, "the earliest credit is the one to claim")
assert(multiCards[2].role == nil and multiCards[2].advice == nil, "later credits stay unclaimed")

-- Same-day renewal and credit expiration (e.g. Codex renewing in 5d on Oct 22 and expiring on Oct 22)
local sameDayCandidate = {
    id = "openai",
    display_name = "Codex",
    metrics = {
        { label = "Codex weekly", percent = 20, reset_at = isoIn(120 * 3600), window_secs = 604800 },
    },
    reset_credits = {
        available = 3,
        credits = {
            { title = "Credit 1", expires_at = isoIn(120 * 3600) },
            { title = "Credit 2", expires_at = isoIn(288 * 3600) },
        },
    },
}
local sameDayPlan, sameDayStats = shared.analyzeResetCredits({ sameDayCandidate }, os.time(), calendarHours)
local sameDayCodex = sameDayStats["openai"]
assert(sameDayCodex.advice.lastChance == true, "credit expiring on the same day as renewal must be flagged lastChance")
assert(sameDayCodex.advice.status == "advance", "must advance to burn quota before renewal, not hold")
assert(sameDayCodex.advice.laterGain == 0.0, "cannot defer to next cycle when expiring on renewal day")
assert(sameDayPlan.fastTrack["openai"] == true, "same-day expiring credit must be fast-tracked")

-- Collision between a provider with runway in next cycle (Claude) and one expiring on renewal day (Codex):
-- Codex must be chosen as advance leader despite having more credits in reserve (3 vs 1)
local collisionRunwayReport = {
    {
        id = "anthropic",
        display_name = "Claude",
        metrics = {
            { label = "Weekly", percent = 70, reset_at = isoIn(72 * 3600), window_secs = 604800 },
        },
        reset_credits = {
            available = 1,
            credits = { { title = "Claude reset", expires_at = isoIn(260 * 3600) } },
        },
    },
    sameDayCandidate,
}
local colRunwayPlan, colRunwayStats = shared.analyzeResetCredits(collisionRunwayReport, os.time(), calendarHours)
assert(colRunwayPlan.advanceName == "Codex", "Codex with imminent same-day expiry must be chosen to advance over Claude")
assert(colRunwayStats["openai"].advice.status == "advance", "Codex must remain in advance")
assert(colRunwayPlan.fastTrack["openai"] == true, "Codex must be fast-tracked in collision")

-- 6. Schedule-aware active working hours calculation
local cfg = {
    scheduleAware = true,
    sleepStartHour = 0,
    sleepEndHour = 8,
    weekendSleepStartHour = 1,
    weekendSleepEndHour = 9,
    mealPauseHours = 1,
    burstDurationHours = 2.0,
}

-- Baseline: Monday 08:00 to Tuesday 08:00 (24 calendar hours)
local monMorning = os.time({ year = 2026, month = 10, day = 12, hour = 8, min = 0, sec = 0 })
local tueMorning = os.time({ year = 2026, month = 10, day = 13, hour = 8, min = 0, sec = 0 })
local active24h = shared.calculateActiveHours(monMorning, tueMorning, cfg, true)
assert(math.abs(active24h - 15.0) < 0.000001,
    string.format("active hours in 24h should discount sleep and meal pause, got %f", active24h))

-- Out-of-schedule awake burst within weekend sleep window (01:00 to 09:00):
local sun2am = os.time({ year = 2026, month = 10, day = 11, hour = 2, min = 0, sec = 0 })
local sun8am = os.time({ year = 2026, month = 10, day = 11, hour = 8, min = 0, sec = 0 })
local burstActive = shared.calculateActiveHours(sun2am, sun8am, cfg, true)
local noBurstActive = shared.calculateActiveHours(sun2am, sun8am, cfg, false)
assert(burstActive >= 2.0, "user active out-of-schedule must receive the 2h awake burst")
assert(noBurstActive == 0.25, "user inactive during sleep hours must receive 0 active hours (clamped to 0.25)")

-- Disabled schedule fallback:
local disabledCfg = { scheduleAware = false }
local rawCalendar = shared.calculateActiveHours(monMorning, tueMorning, disabledCfg)
assert(rawCalendar == 24.0, "when scheduleAware is false, calculateActiveHours must return raw 24 calendar hours")

-- 7. Imminent weekly expiration triage prioritization (Gemini vs multi-day buffer)
-- Gemini: 84% used (16% free), reset in 16.7h calendar (~9.9h active working time)
-- Codex: 29% used (71% free), reset in 80h calendar (~47h active working time)
local function isoAt(ts)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end
local geminiSunday = {
    providerId = "gemini",
    entry = { status = "ready" },
    sessionMetric = { percent = 45, window_secs = 18000, reset_at = isoAt(sun2am + 2.2 * 3600) },
    weeklyMetric = { percent = 84, window_secs = 604800, reset_at = isoAt(sun2am + 16.7 * 3600) },
}
local codexSunday = {
    providerId = "openai",
    entry = { status = "ready" },
    sessionMetric = { percent = 2, window_secs = 18000, reset_at = isoAt(sun2am + 2.8 * 3600) },
    weeklyMetric = { percent = 29, window_secs = 604800, reset_at = isoAt(sun2am + 80 * 3600) },
}
local geminiScore = shared.calculateModelTriageScore(geminiSunday, nil, sun2am, cfg, true)
local codexScore = shared.calculateModelTriageScore(codexSunday, nil, sun2am, cfg, true)
assert(geminiScore > codexScore,
    string.format("Gemini with imminent reset in ~9.9h active hours (%f) must outrank Codex with 4-day buffer (%f)", geminiScore, codexScore))

-- 8. Model Quota Gearing Ratios (K_m = L_weekly / L_session)
assert(shared.getModelGearing("claude-oss", "Claude & GPT OSS") == 2.5, "claude-oss gearing must be 2.5")
assert(shared.getModelGearing("gemini", "Gemini") == 8.0, "gemini gearing must be 8.0")
assert(shared.getModelGearing("anthropic", "Claude") == 7.0, "anthropic gearing must be 7.0")
assert(shared.getModelGearing("openai", "Codex") == 6.3, "codex gearing must reflect the observed 6.3 full sessions per weekly quota")
assert(shared.getModelGearing("custom_provider", "Custom Model") == 10.0, "default gearing must be 10.0")

-- Empirical telemetry calibration test (delta S = 70%, delta W = 10% -> K_obs = 7.0):
local testClaudeItem = {
    providerId = "anthropic",
    name = "Claude",
    sessionMetric = { percent = 0, reset_at = "2026-10-12T05:00:00Z" },
    weeklyMetric = { percent = 73, reset_at = "2026-10-18T00:00:00Z" },
}
shared.recordTelemetrySample(testClaudeItem)
testClaudeItem.sessionMetric.percent = 70
testClaudeItem.weeklyMetric.percent = 83
shared.recordTelemetrySample(testClaudeItem)
local calibratedK, isCal = shared.getModelGearing("anthropic", "Claude", testClaudeItem)
assert(isCal == true, "gearing should be marked as empirically calibrated")
assert(calibratedK == 7.0, "calibrated gearing for 70% session / 10% weekly must be 7.0")

-- Manual override via double config in plugin settings:
noctalia.getConfig = function(k)
    if k == "gearing_gemini" then return 5.5 end
    return nil
end
local geminiOverridden, isOverCal = shared.getModelGearing("gemini", "Gemini")
assert(geminiOverridden == 5.5 and isOverCal == false, "gearing_gemini override via double config should be 5.5")
noctalia.getConfig = nil

-- Midweek comparison:
-- Codex (K=6.3, 1 full session burns ~15.9% of the week; needs 3.78 sessions for the remaining 60%)
-- Claude & GPT OSS (K=2.5, 1 session burns 40% of the week; needs only 1.5 sessions to finish remaining 60% weekly quota)
-- With 80h calendar buffer (~48h active hours = ~9.6 available 5h slots):
-- Codex needs more sessions than Claude OSS, while Claude OSS burns 40% of the entire
-- week in just one 5h session and must be strictly conserved so as not to exhaust the user's weekly budget mid-week.
local codexMidweek = {
    providerId = "openai",
    name = "Codex",
    entry = { status = "ready" },
    sessionMetric = { percent = 0, window_secs = 18000, reset_at = nil },
    weeklyMetric = { percent = 40, window_secs = 604800, reset_at = isoIn(80 * 3600) },
}
local claudeOssMidweek = {
    providerId = "claude-oss",
    name = "Claude & GPT OSS",
    entry = { status = "ready" },
    sessionMetric = { percent = 0, window_secs = 18000, reset_at = nil },
    weeklyMetric = { percent = 40, window_secs = 604800, reset_at = isoIn(80 * 3600) },
}
local codexMidweekScore = shared.calculateModelTriageScore(codexMidweek, nil, os.time(), cfg, true)
local claudeOssMidweekScore = shared.calculateModelTriageScore(claudeOssMidweek, nil, os.time(), cfg, true)
assert(codexMidweekScore > claudeOssMidweekScore,
    string.format("Codex with moderate session gearing (%f) must outrank Claude OSS with low gearing (%f) mid-week", codexMidweekScore, claudeOssMidweekScore))

-- 9. Temporal distribution anti-burst smoothing test
-- When two models have identical session metrics and gearing, but one is severely ahead of weekly pace
-- (e.g. 70% burnt when only 20% of the week has elapsed), while the other is on pace:
local aheadOfPaceModel = {
    providerId = "gemini",
    name = "Gemini",
    entry = { status = "ready" },
    sessionMetric = { percent = 10, window_secs = 18000, reset_at = nil },
    weeklyMetric = { percent = 70, window_secs = 604800, reset_at = isoIn(483840) }, -- 20% elapsed (~134h left)
}
local onPaceModel = {
    providerId = "gemini",
    name = "Gemini",
    entry = { status = "ready" },
    sessionMetric = { percent = 10, window_secs = 18000, reset_at = nil },
    weeklyMetric = { percent = 20, window_secs = 604800, reset_at = isoIn(483840) }, -- 20% elapsed, 20% burnt
}
local aheadScore = shared.calculateModelTriageScore(aheadOfPaceModel, nil, os.time(), cfg, true)
local onPaceScore = shared.calculateModelTriageScore(onPaceModel, nil, os.time(), cfg, true)
assert(onPaceScore > aheadScore,
    string.format("model on pace (%f) must outrank severely over-consumed model (%f) to prevent weekly void", onPaceScore, aheadScore))

-- 10. Locked-out session unlock proximity ranking
-- Two models with 100% session usage: the one unlocking in 15 minutes must rank higher than one unlocking in 4 hours
local unlockSoonModel = {
    providerId = "openai",
    entry = { status = "ready" },
    sessionMetric = { percent = 100, window_secs = 18000, reset_at = isoIn(15 * 60) },
    weeklyMetric = { percent = 30, window_secs = 604800, reset_at = isoIn(80 * 3600) },
}
local unlockLaterModel = {
    providerId = "openai",
    entry = { status = "ready" },
    sessionMetric = { percent = 100, window_secs = 18000, reset_at = isoIn(4 * 3600) },
    weeklyMetric = { percent = 30, window_secs = 604800, reset_at = isoIn(80 * 3600) },
}
local unlockSoonScore = shared.calculateModelTriageScore(unlockSoonModel, nil, os.time(), cfg, true)
local unlockLaterScore = shared.calculateModelTriageScore(unlockLaterModel, nil, os.time(), cfg, true)
assert(unlockSoonScore > unlockLaterScore,
    string.format("session unlocking in 15m (%f) must rank higher than session unlocking in 4h (%f)", unlockSoonScore, unlockLaterScore))

-- 11. Domain Helper & Transformation Unit Tests
assert(shared.WINDOW_5H == 18000, "WINDOW_5H must be 18000s")
assert(shared.WINDOW_7D == 604800, "WINDOW_7D must be 604800s")
assert(shared.isConfigured({ status = "ready" }) == true, "ready provider is configured")
assert(shared.isConfigured({ status = "error", error = "credentials error: no api key found" }) == false, "no api key error is not configured")
assert(shared.isConfigured({ status = "error", error = "credentials error: invalid token" }) == true, "invalid token is configured but failing")

assert(shared.kickstartTarget({ providerId = "anthropic", name = "Claude" }) == "claude", "anthropic target is claude")
assert(shared.kickstartTarget({ providerId = "openai", name = "Codex" }) == "codex", "openai target is codex")
assert(shared.kickstartTarget({ providerId = "gemini", name = "Gemini" }) == "gemini", "gemini target is gemini")
assert(shared.kickstartTarget({ providerId = "claude-oss", name = "Claude & GPT OSS" }) == "claude-oss", "claude-oss target is claude-oss")
assert(shared.kickstartTarget("openai", "codex") == "codex", "direct string pair target is codex")
assert(shared.kickstartTarget({ providerId = "openrouter", name = "OpenRouter" }) == nil, "openrouter has no kickstart target")

-- Test collectModelItems with Antigravity unpacking
local mockCandidates = {
    {
        id = "openai",
        display_name = "Codex",
        status = "ready",
        metrics = {
            { label = "5h", percent = 10, window_secs = 18000 },
            { label = "7d", percent = 25, window_secs = 604800 },
        },
    },
    {
        id = "antigravity",
        display_name = "Antigravity",
        status = "ready",
        metrics = {
            { label = "Gemini", percent = 20, window_secs = 18000 },
            { label = "Gemini", percent = 40, window_secs = 604800 },
            { label = "Claude & GPT OSS", percent = 0, window_secs = 18000 },
            { label = "Claude & GPT OSS", percent = 30, window_secs = 604800 },
        },
    },
}
local modelItems = shared.collectModelItems(mockCandidates)
assert(#modelItems == 3, string.format("Expected 3 unpacked model items, got %d", #modelItems))
assert(modelItems[1].name == "Codex", "First item must be Codex")
assert(modelItems[2].name == "Gemini", "Second item must be Gemini")
assert(modelItems[3].name == "Claude & GPT OSS", "Third item must be Claude & GPT OSS")

-- Test collectResetCredits
local mockCreditCandidates = {
    {
        id = "anthropic",
        display_name = "Claude",
        status = "ready",
        sections = {
            {
                type = "block",
                label = "Reset Credits",
                body = {
                    "Weekly Reset · Expires in 5d",
                },
            },
        },
    },
}
local parsedCredits = shared.collectResetCredits(mockCreditCandidates, nil)
assert(#parsedCredits == 1, "Expected 1 parsed reset credit")
assert(parsedCredits[1].providerName == "Claude", "Parsed credit provider must be Claude")
-- 10. Imminent weekly reset sprint test:
-- When a model has only 4% weekly quota left, but resets in ~1.2h (and session has 90% free),
-- it must outrank models with >20h left (like Claude at 74%) and days left (like Codex at 0%),
-- because unspent weekly quota is immediately perishable.
local imminentGemini = {
    name = "Gemini",
    providerId = "gemini",
    entry = { status = "ready" },
    sessionMetric = { percent = 10, window_secs = 18000, reset_at = isoIn(17000) },
    weeklyMetric = { percent = 96, window_secs = 604800, reset_at = isoIn(4200) },
}
local distantClaude = {
    name = "Claude",
    providerId = "anthropic",
    entry = { status = "ready" },
    sessionMetric = { percent = 0, window_secs = 18000, reset_at = isoIn(16800) },
    weeklyMetric = { percent = 74, window_secs = 604800, reset_at = isoIn(120000) },
}
local distantCodex = {
    name = "Codex",
    providerId = "openai",
    entry = { status = "ready" },
    sessionMetric = { percent = 0, window_secs = 18000, reset_at = isoIn(18000) },
    weeklyMetric = { percent = 0, window_secs = 604800, reset_at = isoIn(580000) },
}
local stagger = { hasCollision = true, advanceProviderId = "anthropic" }
local geminiSprintScore = shared.calculateModelTriageScore(imminentGemini, stagger, os.time(), cfg, true)
local claudeSprintScore = shared.calculateModelTriageScore(distantClaude, stagger, os.time(), cfg, true)
local codexSprintScore = shared.calculateModelTriageScore(distantCodex, stagger, os.time(), cfg, true)
assert(geminiSprintScore > claudeSprintScore and geminiSprintScore > codexSprintScore,
    string.format("Gemini with imminent reset in ~1h (score %.1f) must outrank Claude (%.1f) and Codex (%.1f)", geminiSprintScore, claudeSprintScore, codexSprintScore))
-- 11. Typography scaling & preset proportionality test:
local tDefault = shared.getTypography()
assert(tDefault.factor == 1.00, "Default typography factor must be 1.00")
assert(tDefault.fontSize(19) == 19 and tDefault.fontSize(15) == 15 and tDefault.fontSize(9) == 9,
    "Default typography must preserve exact base font sizes")
assert(tDefault.glyphSize(20) == 20 and tDefault.glyphSize(14) == 14,
    "Default typography must preserve exact base glyph sizes")

local tCompact = shared.getTypography("compact")
assert(tCompact.factor == 0.85, "Compact preset factor must be 0.85")
assert(tCompact.fontSize(19) == 16, "Compact 19px should scale to 16px")
assert(tCompact.fontSize(15) == 13, "Compact 15px should scale to 13px")
assert(tCompact.fontSize(9) == 8, "Compact 9px should scale to 8px")
assert(tCompact.glyphSize(20) == 17, "Compact 20px glyph should scale to 17px")

local tSmall = shared.getTypography("small")
assert(tSmall.factor == 0.85, "Small alias must match compact factor")

local tLarge = shared.getTypography("large")
assert(tLarge.factor == 1.15, "Large preset factor must be 1.15")
assert(tLarge.fontSize(19) == 22, "Large 19px should scale to 22px")
assert(tLarge.fontSize(15) == 17, "Large 15px should scale to 17px")
assert(tLarge.fontSize(9) == 10, "Large 9px should scale to 10px")

local tHuge = shared.getTypography("huge")
assert(tHuge.factor == 1.30, "Huge preset factor must be 1.30")
assert(tHuge.fontSize(19) == 25, "Huge 19px should scale to 25px")
assert(tHuge.fontSize(15) == 20, "Huge 15px should scale to 20px")
assert(tHuge.fontSize(9) == 12, "Huge 9px should scale to 12px")

-- Verify strict monotonicity / proportionality across all presets
for _, preset in ipairs({ "compact", "normal", "large", "huge" }) do
    local t = shared.getTypography(preset)
    local sizes = { 9, 10, 11, 12, 13, 14, 15, 18, 19 }
    local prev = 0
    for _, s in ipairs(sizes) do
        local scaled = t.fontSize(s)
        assert(scaled >= prev, string.format("Preset %s: fontSize(%d) = %d must be >= prev %d", preset, s, scaled, prev))
        prev = scaled
    end
    assert(t.fontSize(19) > t.fontSize(9), string.format("Preset %s: title (19) must be strictly larger than microbadge (9)", preset))
end

-- ============================================================================
-- Service and Model Visibility Filtering (hide_claude_oss & hidden_services)
-- ============================================================================
-- 1. Default configuration: no services or models hidden
assert(shared.isModelHidden("antigravity", "Claude & GPT OSS") == false,
    "Claude & GPT OSS must not be hidden by default")
assert(shared.isModelHidden("antigravity", "Gemini") == false,
    "Gemini must not be hidden by default")
assert(shared.isModelHidden("anthropic", "Claude") == false,
    "Anthropic Claude must not be hidden by default")

-- 2. hide_claude_oss enabled
noctalia.getConfig = function(k)
    if k == "hide_claude_oss" then return true end
    return nil
end

assert(shared.isModelHidden("antigravity", "Claude & GPT OSS") == true,
    "Claude & GPT OSS must be hidden when hide_claude_oss is true")
assert(shared.isModelHidden("claude-oss", "Claude & GPT OSS") == true,
    "claude-oss id must be hidden when hide_claude_oss is true")
assert(shared.isModelHidden("antigravity", "Gemini") == false,
    "Gemini must remain visible when hide_claude_oss is true")
assert(shared.isModelHidden("anthropic", "Claude") == false,
    "Anthropic Claude Pro must NOT be hidden by hide_claude_oss")

-- Test modelHeadlines filtering
local agyFilteredModels = shared.modelHeadlines(antigravityEntry)
assert(#agyFilteredModels == 1, "modelHeadlines must return only 1 model when Claude & GPT OSS is hidden")
assert(agyFilteredModels[1].model == "Gemini", "only Gemini must be returned in modelHeadlines")

-- Test headline filtering: Antigravity should not block on Claude & GPT OSS when hidden
local agyWithExhaustedOss = {
    id = "antigravity",
    status = "ready",
    metrics = {
        { label = "Gemini", percent = 15, severity = "low" },
        { label = "Claude & GPT OSS", percent = 100, severity = "critical" },
    },
}
local chosenHeadline = shared.headline(agyWithExhaustedOss)
assert(chosenHeadline.label == "Gemini" and chosenHeadline.percent == 15,
    "Antigravity headline must follow visible Gemini (15%) and ignore hidden exhausted Claude OSS")

-- Test collectModelItems filtering
local mockAgyCandidates = {
    {
        id = "antigravity",
        display_name = "Antigravity",
        status = "ready",
        metrics = {
            { label = "Gemini", percent = 10, window_secs = 18000 },
            { label = "Claude & GPT OSS", percent = 50, window_secs = 18000 },
            { label = "Gemini", percent = 20, window_secs = 604800 },
            { label = "Claude & GPT OSS", percent = 90, window_secs = 604800 },
        },
    },
    {
        id = "openai",
        display_name = "Codex",
        status = "ready",
        metrics = {
            { label = "Session", percent = 30, window_secs = 18000 },
            { label = "Weekly", percent = 40, window_secs = 604800 },
        },
    },
}
local filteredItems = shared.collectModelItems(mockAgyCandidates)
assert(#filteredItems == 2, "collectModelItems must collect 2 items: Gemini and Codex")
assert(filteredItems[1].name == "Gemini" and filteredItems[2].name == "Codex",
    "collected items must be Gemini and Codex, omitting Claude & GPT OSS")

-- 3. hidden_services comma-separated list
noctalia.getConfig = function(k)
    if k == "hidden_services" then return "openai, claude-oss" end
    return nil
end

assert(shared.isModelHidden("openai", "Codex") == true, "openai must be hidden via hidden_services")
assert(shared.isModelHidden("claude-oss", "Claude & GPT OSS") == true, "claude-oss must be hidden via hidden_services")
assert(shared.isModelHidden("anthropic", "Claude") == false, "anthropic must not be hidden")

local hiddenEntriesReport = {
    entries = {
        { id = "openai", display_name = "Codex", status = "ready", metrics = { { percent = 50 } } },
        { id = "anthropic", display_name = "Claude", status = "ready", metrics = { { percent = 20 } } },
    },
}
local visibleEntries = shared.entries(hiddenEntriesReport)
assert(#visibleEntries == 1 and visibleEntries[1].id == "anthropic",
    "shared.entries must filter out providers listed in hidden_services")

noctalia.getConfig = nil

-- 4. ai-usagebar 1.40 compatibility tests: model_pool, modelDisplayName, and window_secs
local agyWithModelPool = {
    id = "antigravity",
    status = "ready",
    metrics = {
        { label = "Gemini", percent = 25, severity = "low", window_secs = 18000 },
        { label = "Gemini 4 Argon", percent = 100, severity = "critical", model_pool = true },
    },
}
local poolHeadline = shared.headline(agyWithModelPool)
assert(poolHeadline.label == "Gemini" and poolHeadline.percent == 25,
    "model_pool at 100% must not block shared provider windows in headline")

assert(shared.modelDisplayName("Gemini 4 Argon") == "Gemini 4 Argon",
    "modelDisplayName must preserve Argon pool names")
assert(shared.modelDisplayName("Gemini") == "Gemini",
    "modelDisplayName must preserve Gemini")

local zeroWindowMetrics = {
    { label = "Zero", percent = 10, window_secs = 0 },
    { label = "Session", percent = 20, window_secs = 18000 },
    { label = "Weekly", percent = 30, window_secs = 604800 },
}
local shortM, weeklyM = shared.dualMetrics(zeroWindowMetrics)
assert(shortM.label == "Session" and weeklyM.label == "Weekly",
    "dualMetrics must ignore non-positive window_secs")

-- 5. Upstream dynamic weekly reset & allowance advancement tests
local now = os.time()

-- Scenario A: Post-reset entry has 7d horizon, 0% weekly usage
local postResetCodex = {
    id = "openai",
    display_name = "Codex",
    metrics = {
        { label = "Codex 5h", percent = 0, window_secs = 18000, reset_at = isoIn(604800) },
        { label = "Codex weekly", percent = 0, window_secs = 604800, reset_at = isoIn(604800), detail = "Resets in 7d 0h · 0% elapsed · on track" },
    },
    reset_credits = {
        available = 1,
        credits = {
            { title = "Full reset", expires_at = isoIn(246 * 3600) },
        },
    },
}

-- Reconciler must preserve the authentic upstream 7d reset_at without artificial truncation
local report = { entries = { postResetCodex } }
shared.reconcileReportCycles(report, now)
local _, wMetric = shared.dualMetrics(postResetCodex.metrics)
assert(wMetric.reset_at == isoIn(604800), "upstream 7d reset_at must be preserved as authoritative")
assert(wMetric.detail:find("7d"), "detail must retain authentic 7d countdown")

-- Scenario B: Triage scoring respects authentic 7d active hours
local item = {
    providerId = "openai",
    name = "gpt-5-codex",
    entry = postResetCodex,
    sessionMetric = postResetCodex.metrics[1],
    weeklyMetric = postResetCodex.metrics[2],
}
local scheduleConfig = {
    active_days = { mon = true, tue = true, wed = true, thu = true, fri = true, sat = true, sun = true },
    active_start_hour = 8,
    active_end_hour = 21,
}
local score = shared.calculateModelTriageScore(item, nil, now, scheduleConfig, true)
-- With 100% free quota and 7d (many active hours), weekly burn pace is 0, so no false sprint urgency
assert(score > 0 and score < 100, "post-reset model triage score must be balanced, got " .. tostring(score))

-- Scenario C: analyzeResetCredits accurately measures remaining credits against 7d renewal
local creditPlan = shared.analyzeResetCredits({ postResetCodex }, now, scheduleConfig)
assert(creditPlan ~= nil, "credit plan must be generated")
assert(creditPlan.creditAdvice["openai"] ~= nil, "openai credit advice must be generated")
assert(creditPlan.hasCollision == false, "single provider should not have collision")

-- ai-usagebar 1.43: context/group rows are supplementary, never account quota.
local contextOnly = { label = "chat", percent = 100, severity = "critical", group = "Sessions" }
local quotaSession = { label = "Session (5h)", percent = 12, severity = "low", window_secs = 18000 }
local quotaWeekly = { label = "Weekly (7d)", percent = 34, severity = "low", window_secs = 604800 }
local contextEntry = { id = "anthropic", metrics = { quotaSession, contextOnly } }
assert(shared.headline(contextEntry) == quotaSession, "a full context window must not exhaust Claude quota")
local cs, cw = shared.dualMetrics(contextEntry.metrics)
assert(cs == quotaSession and cw == nil, "context must not fill an unreported weekly window")
assert(shared.headline({ id = "anthropic", metrics = { contextOnly } }) == nil,
    "context-only reports must not invent quota")
cs, cw = shared.dualMetrics({ quotaWeekly, contextOnly })
assert(cs == nil and cw == quotaWeekly, "context must not fill an unreported 5h window")

-- Several metrics from the same explicit window are not a second window.
cs, cw = shared.dualMetrics({ quotaSession, { label = "Other session", percent = 10, window_secs = 18000 } })
assert(cs == quotaSession and cw == nil, "two short limits must not fabricate a weekly limit")
cs, cw = shared.dualMetrics({ quotaWeekly, { label = "Other weekly", percent = 10, window_secs = 604800 } })
assert(cs == nil and cw == quotaWeekly, "two long limits must not fabricate a session")

-- Per-model pools keep their own identity and never become Claude/GPT OSS.
local argonEntry = { id = "antigravity", metrics = {
    quotaSession,
    { label = "Gemini 4 Argon", percent = 20, window_secs = 18000, model_pool = true },
} }
local argonItems = shared.collectModelItems({ argonEntry })
assert(argonItems[2].providerId ~= "claude-oss", "Argon must not inherit the Claude/OSS identity")
assert(shared.kickstartTarget({ providerId = "anthropic@work", name = "Claude · work" }) == nil,
    "named accounts cannot be kickstarted with the default CLI login")

io.write("ok: shared timestamps, availability, provider order, mathematical triage score, reset staggering, typography scale presets, and 1.40 compat\n")


