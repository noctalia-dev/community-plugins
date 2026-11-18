-- Tests for Antigravity local session quota parsing and enrichment

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
    tr = function(k) return k end,
}
local env = setmetatable({ noctalia = noctalia }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", env))()

print("--- Testing parseAgyStatuslineObservation ---")

local sampleObservation = {
    payload = {
        quota = {
            ["3p-5h"] = {
                remaining_fraction = 1.0,
                reset_in_seconds = 16200,
                reset_time = "2026-10-20T01:06:59Z",
            },
            ["3p-weekly"] = {
                remaining_fraction = 0.9927808,
                reset_in_seconds = 76000,
                reset_time = "2026-10-20T17:44:01Z",
            },
            ["gemini-5h"] = {
                remaining_fraction = 0.7086228,
                reset_in_seconds = 3402,
                reset_time = "2026-10-19T21:33:10Z",
            },
            ["gemini-weekly"] = {
                remaining_fraction = 0.25129282,
                reset_in_seconds = 383656,
                reset_time = "2026-10-24T07:10:44Z",
            },
        },
    },
}

local q1 = shared.parseAgyStatuslineObservation(sampleObservation)
assert(q1 ~= nil, "q1 should not be nil")
assert(q1.gemini_5h ~= nil, "gemini_5h should be present")
assert(q1.gemini_5h.percent == 29, "gemini_5h percent should be 29 (1 - 0.7086)")
assert(q1.gemini_5h.started == true, "gemini_5h started should be true")
assert(q1.gemini_5h.reset_at == "2026-10-19T21:33:10Z", "gemini_5h reset_at mismatch")
assert(q1.gemini_weekly.percent == 75, "gemini_weekly percent should be 75 (1 - 0.2513)")
assert(q1.gemini_weekly.reset_at == "2026-10-24T07:10:44Z", "gemini_weekly reset_at mismatch")
assert(q1.third_party_weekly.percent == 1, "third_party_weekly percent should be 1")

-- Fractional usage test (e.g. 0.2% used from a single prompt)
local smallPromptObservation = {
    payload = {
        quota = {
            ["gemini-5h"] = {
                remaining_fraction = 0.998,
                reset_in_seconds = 17800,
                reset_time = "2026-10-21T13:30:00Z",
            },
            ["3p-5h"] = {
                remaining_fraction = 1.0,
                reset_in_seconds = 18000,
                reset_time = "2026-10-21T13:30:00Z",
            },
        },
    },
}
local qSmall = shared.parseAgyStatuslineObservation(smallPromptObservation)
assert(qSmall ~= nil, "qSmall should not be nil")
assert(qSmall.gemini_5h.started == true, "small prompt (<0.5%) must be detected as started")
assert(qSmall.gemini_5h.percent == 1, "small prompt (<0.5%) must floor to at least 1% used")
assert(qSmall.third_party_5h.started == false, "100% remaining must not be marked as started")
assert(qSmall.third_party_5h.percent == 0, "100% remaining must be 0% used")

-- Fallback with snapshot.windows
local sampleSnapshot = {
    snapshot = {
        windows = {
            { kind = "five_hour", remaining_percent = 73.0, resets_at = 1792445590 },
            { kind = "weekly", used_percent = 74.0, resets_at = 1792825844 },
        },
    },
}
local q2 = shared.parseAgyStatuslineObservation(sampleSnapshot)
assert(q2 ~= nil, "q2 should not be nil")
assert(q2.gemini_5h.percent == 27, "q2 gemini_5h percent should be 27")
assert(q2.gemini_weekly.percent == 74, "q2 gemini_weekly percent should be 74")

print("--- Testing parseAgyCliQuota ---")

local cliOutput = [[
Quota:
Gemini Models          Weekly Limit Remaining     26%   2026-10-24 09:10 CEST
Gemini Models          Five Hour Limit Remaining  73%   2026-10-19 23:33 CEST
Claude and GPT models  Weekly Limit Remaining     99%   2026-10-20 19:44 CEST
Claude and GPT models  Five Hour Limit Remaining  100%  2026-10-20 03:04 CEST
]]

local qCli = shared.parseAgyCliQuota(cliOutput)
assert(qCli ~= nil, "qCli should not be nil")
assert(qCli.gemini_5h.percent == 27, "qCli gemini_5h percent should be 27 (100 - 73)")
assert(qCli.gemini_5h.reset_at:find("T21:33:00Z") or qCli.gemini_5h.reset_at:find("T"), "reset_at should be ISO")
assert(qCli.gemini_weekly.percent == 74, "qCli gemini_weekly percent should be 74 (100 - 26)")
assert(qCli.third_party_weekly.percent == 1, "qCli third_party_weekly percent should be 1")
assert(qCli.third_party_5h.percent == 0, "qCli third_party_5h percent should be 0")

print("--- Testing enrichAntigravityEntry ---")

local dummyAntigravity = {
    brand = "antigravity",
    id = "antigravity",
    name = "antigravity",
    plan = "Antigravity",
    metrics = {
        {
            detail = "Resets in 4h 59m",
            headline = "percent",
            label = "Gemini",
            percent = 0,
            reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 17900),
            severity = "low",
            value = "0%",
            window_secs = 18000,
        },
        {
            detail = "Resets in 4h 59m",
            headline = "percent",
            label = "Claude & GPT OSS",
            percent = 0,
            reset_at = "2026-10-20T01:00:05Z",
            severity = "low",
            value = "0%",
            window_secs = 18000,
        },
        {
            detail = "Resets in 6d 23h",
            headline = "percent",
            label = "Gemini",
            percent = 0,
            reset_at = "2026-10-26T20:00:05Z",
            severity = "low",
            value = "0%",
            window_secs = 604800,
        },
        {
            detail = "Resets in 21h 43m",
            headline = "percent",
            label = "Claude & GPT OSS",
            percent = 1,
            reset_at = "2026-10-20T17:44:01Z",
            severity = "low",
            value = "1%",
            window_secs = 604800,
        },
    },
    sections = {
        { type = "spacer" },
        { label = "Session", type = "text", value = "" },
        {
            detail = "Resets in 4h 59m",
            headline = "percent",
            label = "Gemini",
            percent = 0,
            reset_at = "2026-10-20T01:00:05Z",
            severity = "low",
            type = "metric",
            value = "0%",
            window_secs = 18000,
        },
        { label = "Source", type = "text", value = "Google API" },
    },
}

-- Before enrichment: isSessionStarted is FALSE because percent == 0 and remaining >= 90%
assert(shared.isSessionStarted(dummyAntigravity.metrics[1]) == false,
    "Gemini 5h should be unstarted before enrichment")

-- Apply enrichment
shared.enrichAntigravityEntry(dummyAntigravity, q1)

local mGemini5h = dummyAntigravity.metrics[1]
assert(mGemini5h.percent == 29, "Gemini 5h percent should now be 29")
assert(mGemini5h.value == "29%", "Gemini 5h value should be 29%")
assert(mGemini5h.reset_at == "2026-10-19T21:33:10Z", "Gemini 5h reset_at should be updated")

-- Now: isSessionStarted MUST BE TRUE!
assert(shared.isSessionStarted(mGemini5h) == true,
    "Gemini 5h MUST be detected as started after enrichment!")

-- Weekly metric
local mGeminiWeekly = dummyAntigravity.metrics[3]
assert(mGeminiWeekly.percent == 75, "Gemini weekly percent should now be 75")
assert(mGeminiWeekly.severity == "high", "Gemini weekly severity should be high (>= 75)")

-- Source in sections
local sourceSection = dummyAntigravity.sections[4]
assert(sourceSection.value == "Local agy session", "Source section should be updated to Local agy session")

print("--- Testing enrichment when Gemini is omitted by ai-usagebar ---")

local omittedGeminiEntry = {
    brand = "antigravity",
    id = "antigravity",
    name = "antigravity",
    plan = "Antigravity",
    metrics = {
        {
            detail = "Resets in 4h 59m",
            headline = "percent",
            label = "Claude & GPT OSS",
            percent = 0,
            reset_at = "2026-10-21T14:00:00Z",
            severity = "low",
            value = "0%",
            window_secs = 18000,
        },
        {
            detail = "Resets in 6d 9h",
            headline = "percent",
            label = "Claude & GPT OSS",
            percent = 0,
            reset_at = "2026-10-27T17:44:01Z",
            severity = "low",
            value = "0%",
            window_secs = 604800,
        },
    },
}

shared.enrichAntigravityEntry(omittedGeminiEntry, qSmall)
assert(#omittedGeminiEntry.metrics >= 3, "Gemini metrics should be inserted when missing")
local insertedGemini5h = omittedGeminiEntry.metrics[1]
assert(insertedGemini5h.label == "Gemini", "First metric should be Gemini")
assert(insertedGemini5h.window_secs == 18000, "Should be 5h window")
assert(insertedGemini5h.percent == 1, "Should have 1% used")
assert(insertedGemini5h.started == true, "Should be started")
assert(shared.isSessionStarted(insertedGemini5h) == true, "Inserted Gemini 5h must be started")

print("ok: all Antigravity enrichment tests passed!")
