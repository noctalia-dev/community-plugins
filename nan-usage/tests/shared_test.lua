--!nonstrict
-- Tests for shared.luau: the model, under a fixed clock and with no host at all.
--
-- Plain Lua, no Noctalia: the model is pure, so the numbers and the texts it
-- derives can be asserted exactly, including the countdowns, which would be
-- unassertable if it read the clock itself.
--
--   lua tests/shared_test.lua

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local model = dofile(here .. "/../shared.luau")

local checks, failures = 0, {}

local function check(ok, what)
  checks = checks + 1
  if not ok then
    failures[#failures + 1] = what
  end
end

local function eq(got, want, what)
  check(got == want, string.format("%s: got %s, want %s", what, tostring(got), tostring(want)))
end

local function near(got, want, slack, what)
  check(math.abs((got or 0) - want) <= slack, string.format("%s: got %s, want %s", what, tostring(got), tostring(want)))
end

-- ── formatting ──────────────────────────────────────────────────────────────

eq(model.fmtTokens(3e9), "3B", "3B")
eq(model.fmtTokens(1.5e9), "1.5B", "1.5B")
eq(model.fmtTokens(79.9e6), "79.9M", "79.9M")
eq(model.fmtTokens(500e6), "500M", "500M")
eq(model.fmtTokens(398000), "398K", "398K")
eq(model.fmtTokens(42.4), "42", "42")
eq(model.fmtTokens(0), "0", "zero")
eq(model.fmtTokens(-5), "0", "negative token count floors at zero")
eq(model.fmtTokens("1230000"), "1.2M", "a token count that arrives as a string")

eq(model.fmtPct(80, false), "80%", "whole percent")
eq(model.fmtPct(0.4, false), "0%", "coarse zero")
eq(model.fmtPct(0.4, true), "0.4%", "fine zero")
eq(model.fmtPct(7.55, true), "7.5%", "fine percent")

eq(model.humanDuration(20 * 86400, true), "20d", "20d compact")
eq(model.humanDuration(20 * 86400, false), "20d 0h", "20d long")
eq(model.humanDuration(4 * 3600 + 21 * 60, true), "4h21m", "4h21m compact")
eq(model.humanDuration(4 * 3600 + 21 * 60, false), "4h 21m", "4h 21m long")
eq(model.humanDuration(45 * 60, true), "45m", "45m compact")
eq(model.humanDuration(45 * 60, false), "45 min", "45 min long")
eq(model.humanDuration(30, false), "30 s", "seconds long")
eq(model.humanDuration(26 * 3600, false), "1d 2h", "26 hours")
eq(model.humanDuration(-10, true), "0s", "negative duration floors at zero")

eq(model.shortModel("deepseek-v4-flash"), "ds4f", "deepseek-v4-flash")
eq(model.shortModel("glm5.3-flash"), "glm5.3f", "glm5.3-flash")
eq(model.shortModel("glm5.3"), "glm5.3", "glm5.3 unchanged")

-- ── levels ──────────────────────────────────────────────────────────────────

eq(model.utilLevel(74.9), "ok", "74.9% is calm")
eq(model.utilLevel(75), "warn", "75% warns")
eq(model.utilLevel(89.9), "warn", "89.9% warns")
eq(model.utilLevel(90), "crit", "90% is critical")
eq(model.maxLevel("ok", "crit"), "crit", "crit beats ok")
eq(model.maxLevel("warn", "ok"), "warn", "warn beats ok")

-- ── timestamps ──────────────────────────────────────────────────────────────

eq(model.windows({})[1], nil, "no models, no windows")
eq(model.windows(nil)[1], nil, "no response, no windows")

local day = 86400
local t0 = os.time({ year = 2026, month = 9, day = 1, hour = 12 })

-- A fixed clock: every case below states elapsed and remaining itself.
local function window(opts)
  return {
    model = opts.model or "deepseek-v4-flash",
    used = opts.used,
    cap = opts.cap or 100,
    startsAt = opts.startsAt,
    resetsAt = opts.resetsAt,
    utilization = (opts.used or 0) / (opts.cap or 100) * 100,
    windowHours = opts.windowHours or 0,
    windowCap = opts.windowCap or 0,
  }
end

-- Twenty days into a thirty-day period with 40% used: the average projects to 60%,
-- which is under every threshold, so the window is calm and says nothing.
local steady = window({ used = 40, cap = 100, startsAt = t0, resetsAt = t0 + 30 * day })
eq(model.windowLevel(steady, t0 + 20 * day), "ok", "40% at two thirds of a month is calm")
near(model.projectedUtil(steady, t0 + 20 * day), 60, 0.5, "projection extrapolates the average")
eq(model.exhaustAfter(steady, t0 + 20 * day), nil, "no exhaustion at that rate")
eq(model.lockout(steady, t0 + 20 * day), nil, "no lockout without exhaustion")
eq(model.projectionNote(steady, t0 + 20 * day), "", "nothing to say at that rate")

-- Three days in, the same 40% is a 400% pace — and three days is past the 5% floor,
-- so it counts.
local sprint = window({ used = 40, cap = 100, startsAt = t0, resetsAt = t0 + 30 * day })
near(model.projectedUtil(sprint, t0 + 3 * day), 400, 0.5, "the projection scales with elapsed time")
eq(model.windowLevel(sprint, t0 + 3 * day), "crit", "a 400% pace exhausts early and locks the account out")

-- Inside the first 5% of a period the average is noise, whatever it says.
local fresh = window({ used = 40, cap = 100, startsAt = t0, resetsAt = t0 + 30 * day })
near(model.projectedUtil(fresh, t0 + day), 40, 0.001, "inside the 5% floor the projection is just the usage")

-- 80% twenty days into a thirty-day period: it runs out five days before the reset,
-- which is 5/30 of the period without quota — critical, by the lockout rule.
local burning = window({ used = 80, cap = 100, startsAt = t0, resetsAt = t0 + 30 * day })
near(model.exhaustAfter(burning, t0 + 20 * day), 5 * day, 60, "runs out five days before the reset")
near(model.lockout(burning, t0 + 20 * day), 5 * day, 60, "five days locked out")
eq(model.windowLevel(burning, t0 + 20 * day), "crit", "a long lockout is critical")
check(model.projectionNote(burning, t0 + 20 * day):find("runs out in ~5d", 1, true) ~= nil, "the note names the run-out")

-- 78% at 22/30 days: it does run out, but only 1.8 days before the reset — under
-- the tenth of a period that would make it critical.
local tight = window({ used = 78, cap = 100, startsAt = t0, resetsAt = t0 + 30 * day })
eq(model.windowLevel(tight, t0 + 22 * day), "warn", "a short lockout only warns")
eq(model.projectionNote(tight, t0 + 22 * day), "at this rate it runs out just before the reset",
  "the note says just before the reset")

-- 55% at 20/30 days: on track for 82.5%, no exhaustion — a warning from the rate.
local drifting = window({ used = 55, cap = 100, startsAt = t0, resetsAt = t0 + 30 * day })
eq(model.windowLevel(drifting, t0 + 20 * day), "warn", "an 82% track warns")
eq(model.projectionNote(drifting, t0 + 20 * day), "on track for ~83% at reset", "the note gives the projection")

-- Freshly started: the average is noise, so only the percentage counts.
local fresh = window({ used = 5, cap = 100, startsAt = t0, resetsAt = t0 + 30 * day })
eq(model.windowLevel(fresh, t0 + 120), "ok", "five percent in the first minutes stays calm")
eq(model.projectionNote(fresh, t0 + 120), "", "no projection before 5% of the period")

-- Already overshot: the API is allowed to let usage go past the cap, and that shows.
local over = window({ used = 110, cap = 100, startsAt = t0, resetsAt = t0 + 30 * day })
eq(model.windowLevel(over, t0 + 20 * day), "crit", "over the cap is critical")
near(model.projectedUtil(over, t0 + 20 * day), 165, 0.5, "the projection keeps extrapolating past the cap")
check(model.projectedUtil(over, t0 + 20 * day) >= over.utilization, "never below what is already used")
eq(model.exhaustAfter(over, t0 + 20 * day), 0, "already exhausted")

-- No period at all: the percentage is all there is.
local bare = window({ used = 79e6, cap = 100e6 })
eq(model.windowLevel(bare, t0), "warn", "without a period, only the percentage grades it")
eq(model.caption(bare, t0), "79M / 100M", "no period, no countdown")
eq(model.periodLine(bare, t0), "", "no period line without a period")

-- ── captions ────────────────────────────────────────────────────────────────

local rolling = window({
  model = "glm5.3", used = 2e9, cap = 3e9,
  startsAt = t0, resetsAt = t0 + 4 * day + 2 * 3600,
  windowHours = 4, windowCap = 4e8,
})
eq(model.caption(rolling, t0), "2B / 3B · resets in 4d 2h · window 4 h: 400M", "caption with a rolling window")
eq(model.periodLine(rolling, t0), "Period from 1 Sep · resets in 4d 2h", "period line")

-- ── selecting and filtering ─────────────────────────────────────────────────

local list = {
  window({ model = "a", used = 30, cap = 100 }),
  window({ model = "b", used = 95, cap = 100, startsAt = t0, resetsAt = t0 + 30 * day }),
  window({ model = "c", used = 0, cap = 100 }),
}

eq(model.selectPanelWindow(list, "worst", "", t0).model, "b", "worst picks the alarming one")
eq(model.selectPanelWindow(list, "max", "", t0).model, "b", "max picks the fullest")
eq(model.selectPanelWindow(list, "fixed", "a", t0).model, "a", "fixed pins the model")
eq(model.selectPanelWindow(list, "fixed", "nope", t0).model, "b", "fixed falls back when the pin is gone")

local unused = { window({ model = "a", used = 0, cap = 100 }), window({ model = "b", used = 0, cap = 100 }) }
eq(model.selectPanelWindow(unused, "worst", "", t0).model, "a", "with nothing used, the bar still says something")

eq(#model.visibleWindows(list, false, ""), 3, "hide_unused off keeps everything")
eq(#model.visibleWindows(list, true, ""), 2, "hide_unused drops the unused one")
eq(#model.visibleWindows(list, true, "c"), 3, "the pinned model stays even unused")

-- ── reading a response ──────────────────────────────────────────────────────

local parsed = model.windows({
  periodStart = "2026-09-01",
  models = {
    { model = "deepseek-v4-flash", tokensUsed = "2000000000", cap = "3000000000", periodEnd = "2026-10-01T00:00:00Z" },
    { model = "glm5.3", tokensUsed = 50, cap = 100, remaining = 30, periodEnd = t0 + 10 * day },
    { model = "no-cap", tokensUsed = 10 },
    { model = "", tokensUsed = 10, cap = 100 },
    "not a table",
  },
})
eq(#parsed, 2, "entries without a model or a cap are dropped, junk is ignored")
eq(parsed[1].model, "deepseek-v4-flash", "the busiest model sorts first")
eq(parsed[1].cap, 3e9, "a numeric string is read as a number")
eq(parsed[2].model, "glm5.3", "then by usage")
eq(parsed[2].remaining, 30, "the reported remaining wins over cap minus used")
eq(parsed[1].startsAt ~= nil, true, "the period start is shared by every window")
local shifted = model.windows({
  models = { { model = "x", tokensUsed = 1, cap = 2, periodEnd = "2026-10-01T00:00:00Z" } },
})
local offset = model.windows({
  models = { { model = "x", tokensUsed = 1, cap = 2, periodEnd = "2026-10-01T02:00:00+02:00" } },
})
eq(offset[1].resetsAt, shifted[1].resetsAt, "an explicit +02:00 offset names the same instant as its UTC form")
eq(os.date("!%Y-%m-%d", shifted[1].resetsAt), "2026-10-01", "an ISO timestamp lands on its UTC day")
eq(model.windows({
  models = { { model = "x", tokensUsed = 1, cap = 2, periodEnd = "junk" } },
})[1].resetsAt, nil, "an unreadable timestamp is simply absent")

-- The API may report a username and no handle; the fallback has to happen.
eq(model.accountSummary({ username = "someone" }), "someone", "a username stands in for a missing handle")
eq(model.accountSummary({ handle = "", username = "someone" }), "someone", "and for an empty one")
eq(model.accountSummary({ handle = "carlos-3", username = "ignored" }), "carlos-3", "the handle wins when it is there")
eq(model.accountSummary({}), "", "an account with nothing in it is empty")

-- ── aggregates ──────────────────────────────────────────────────────────────

local metrics = { last24h = { totalTokens = 5e6 }, monthToDate = { totalTokens = 4e7 }, last30d = 4.4e7 }
eq(model.metricsSummary(metrics), "24 h: 5M · month: 40M · 30 d: 44M", "aggregate line")
eq(model.metricsSummary({ last24h = { totalTokens = 5e6 } }), "24 h: 5M", "only the buckets that exist")
eq(model.metricsSummary(nil), "", "no metrics, no line")
local buckets = model.usageBuckets(metrics)
eq(#buckets, 3, "three buckets")
eq(buckets[1].label, "24 h", "labelled")
eq(buckets[1].text, "5M", "printed")
eq(buckets[1].tokens, 5e6, "and drawn")
eq(model.usageBuckets({}), nil, "an empty response gives no buckets")

-- ── the document ────────────────────────────────────────────────────────────

local cfg = {
  panelModel = "worst", panelModelId = "deepseek-v4-flash", gauge = "bar",
  hideUnused = false, showMetrics = true, showPercentage = true, showReset = true,
  showModel = true, pollSeconds = 300,
}
local record = model.build({
  quota = { periodStart = "2026-09-01", models = {
    { model = "deepseek-v4-flash", tokensUsed = 2.4e9, cap = 3e9, periodEnd = t0 + 4 * day },
    { model = "glm5.3-flash", tokensUsed = 0, cap = 3e9, periodEnd = t0 + 4 * day },
  } },
  me = { handle = "carlos-3", region = "EU", tier = "inference" },
  metrics = metrics,
  fetchedAt = t0,
}, cfg, t0)

eq(record.version, 1, "the document carries its version")
eq(record.ok, true, "with windows, it is ok")
eq(record.stale, false, "and not stale")
eq(record.error, "", "no error")
eq(record.totalWindows, 2, "every window counted, including hidden ones")
eq(#record.windows, 2, "both painted")
eq(record.windows[1].model, "deepseek-v4-flash", "busiest first")
eq(record.windows[1].percentText, "80%", "percent")
eq(record.windows[2].percentText, "0.0%", "a quiet model reads 0.0%")
eq(record.windows[1].note, "at this rate it runs out in ~3h 0m", "twelve hours into the period at 80%, the run-out is hours away")
eq(record.windows[1].level, "crit", "which is critical")
eq(record.panel.model, "deepseek-v4-flash", "the bar reflects the worst model")
eq(record.panel.level, "crit", "at the same level as the window")
eq(record.panel.percentText, "80%", "the bar is whole numbers")
eq(record.panel.resetsIn, "4d", "the bar counts down")
eq(record.panel.text, "80%·4d·ds4f", "and composes the whole indicator, tight")
eq(record.account.summary, "carlos-3 · EU", "account line")
eq(record.account.tier, "INFERENCE", "the tier is upper-cased")
eq(record.period, "Period from 1 Sep · resets in 4d 0h", "period line, in the long form")
eq(record.updated, "Updated at " .. os.date("%H:%M", t0), "updated stamp")
eq(record.metrics, "24 h: 5M · month: 40M · 30 d: 44M", "the aggregates ride along")
eq(#record.usage, 3, "and as data")
eq(record.gauge, "bar", "the gauge the bar should draw")

-- Failure shapes: nothing read yet, and last data with an error on top.
local empty = model.build({ error = "No API key at ~/.config/nan/api-key" }, cfg, t0)
eq(empty.ok, false, "no data is not ok")
eq(empty.panel, nil, "and no indicator")
eq(empty.updated, "No data", "which is said once")
eq(empty.error, "No API key at ~/.config/nan/api-key", "with the reason")
eq(empty.gauge, "bar", "still declares the gauge")

local degraded = model.build({
  quota = { models = { { model = "x", tokensUsed = 1, cap = 2 } } },
  fetchedAt = t0, error = "HTTP 500",
}, cfg, t0)
eq(degraded.ok, true, "last data still painted")
eq(degraded.stale, true, "flagged stale")
eq(degraded.updated, "Updated at " .. os.date("%H:%M", t0) .. " · with errors", "and said so")
eq(degraded.ageSeconds, 0, "the age of the data is known")

eq(model.build(nil, cfg, t0 + 90).ageSeconds, 0, "a record with no fetch has no age")

if #failures > 0 then
  io.stderr:write(("%d of %d checks failed:\n"):format(#failures, checks))
  for _, failure in ipairs(failures) do
    io.stderr:write("  " .. failure .. "\n")
  end
  os.exit(1)
end
print(("%d checks pass (model)"):format(checks))
