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

-- An instant given as UTC wall time, whatever zone the tests run in.
local function utc(year, month, day, hour, min, sec)
  local guess = os.time({ year = year, month = month, day = day, hour = hour or 0, min = min or 0, sec = sec or 0 })
  local fields = os.date("!*t", guess)
  fields.isdst = nil
  return guess - (os.time(fields) - guess)
end

local DAY = 86400

-- ── formatting ──────────────────────────────────────────────────────────────

eq(model.fmtTokens(3e9), "3B", "3B")
eq(model.fmtTokens(1.5e9), "1.5B", "1.5B")
eq(model.fmtTokens(79.9e6), "79.9M", "79.9M")
eq(model.fmtTokens(10650734), "10.65M", "millions keep two decimals")
eq(model.fmtTokens(398000), "398K", "398K")
eq(model.fmtTokens(42.4), "42", "42")
eq(model.fmtTokens(0), "0", "zero")
eq(model.fmtTokens(-5), "0", "negative token count floors at zero")
eq(model.fmtTokens("1230000"), "1.23M", "a token count that arrives as a string")

eq(model.fmtPct(80, false), "80%", "whole percent")
eq(model.fmtPct(0.4, false), "0%", "coarse zero")
eq(model.fmtPct(0.4, true), "0.4%", "fine zero")
eq(model.fmtPct(7.55, true), "7.5%", "fine percent")

eq(model.fmtCredits(26.5), "26.5", "credits with a decimal")
eq(model.fmtCredits(7000), "7,000", "whole credits drop the decimal and are grouped")
eq(model.fmtCredits(6973.2), "6,973.2", "a large figure keeps its decimal")
eq(model.fmtCredits(9, "fixed"), "9.0", "fixed always shows one decimal, for lists")
eq(model.fmtCredits(6973.5, "whole"), "6,974", "whole rounds, for the bar")
eq(model.fmtCredits(0), "0", "no credits")
eq(model.fmtCredits("16.7"), "16.7", "credits that arrive as a string")

eq(model.fmtCreditsShort(0), "", "a chart column with no credits carries no label")
eq(model.fmtCreditsShort(0.2), "0.2", "small figures keep their decimal")
eq(model.fmtCreditsShort(26.5), "27", "from 10 on, whole credits")
eq(model.fmtCreditsShort(1240), "1.2k", "and thousands in k")

eq(model.humanDuration(20 * DAY, true), "20d", "20d compact")
eq(model.humanDuration(20 * DAY, false), "20d 0h", "20d long")
eq(model.humanDuration(4 * 3600 + 21 * 60, true), "4h21m", "4h21m compact")
eq(model.humanDuration(4 * 3600 + 21 * 60, false), "4h 21m", "4h 21m long")
eq(model.humanDuration(45 * 60, false), "45 min", "45 min long")
eq(model.humanDuration(-10, true), "0s", "negative duration floors at zero")

eq(model.dayLabel("2026-11-10"), "10 Nov", "a day the API names, as the panel prints it")
eq(model.utcDate(utc(2026, 11, 13, 23, 30)), "2026-11-13", "the UTC day of an instant")

-- ── the request window ──────────────────────────────────────────────────────

local now = utc(2026, 11, 13, 15, 40)
eq(model.windowStart(nil, now), "2026-11-10", "before the period is known, 31 days back, but not before credits began")
eq(model.windowStart("2026-10-26T14:52:52Z", now), "2026-11-10", "this period started before credit billing did")
eq(model.windowStart("2026-11-26T14:52:52Z", utc(2026, 12, 3, 9)), "2026-11-26", "the next period starts on its own day")
eq(model.windowStart(nil, utc(2027, 1, 20)), "2026-12-20", "and without it, 31 days back")

-- ── reading a response ──────────────────────────────────────────────────────

eq(model.account(nil), nil, "an account not billed in credits has no credits block")
local parsed = model.account({
  period_start = "2026-10-26T14:52:52Z", period_end = "2026-11-26T14:52:52Z",
  allowance = "7000", used = 26.8, pack_credits = 0, pack_expires_at = nil, frozen = false,
})
eq(parsed.allowance, 7000, "a numeric string is read as a number")
near(parsed.remaining, 6973.2, 1e-9, "remaining defaults to allowance minus used")
eq(parsed.resetsAt - parsed.startsAt, 31 * DAY, "the period's ends are read as instants")
eq(model.account({ allowance = 100, used = 10, remaining = 5 }).remaining, 5, "the reported remaining wins")

local rows = model.rows({ data = {
  { date = "2026-11-08", model = "deepseek-v4-flash", prompt_tokens = 10, credits = 0 },
  { date = "2026-11-10", model = "glm5.3", prompt_tokens = "100", cached_tokens = 500, completion_tokens = 5, credits = "9" },
  { date = "junk", model = "x" },
  { date = "2026-11-12", model = "" },
  "not a table",
} }, "2026-11-10")
eq(#rows, 1, "rows before the window, without a day or a model, and junk are dropped")
eq(rows[1].prompt, 100, "token counts that arrive as strings are read")
eq(rows[1].cached, 100, "cached input never exceeds the input it is part of")
eq(rows[1].credits, 9, "credits are read")

-- ── pace and levels ─────────────────────────────────────────────────────────

-- A thirty-day period well after credit billing began, so the whole period is
-- measured. Every case states how far in it is.
local p0 = utc(2027, 1, 1)
local function acct(opts)
  return {
    allowance = opts.allowance or 7000,
    used = opts.used,
    remaining = opts.remaining or ((opts.allowance or 7000) - opts.used),
    packs = opts.packs or 0,
    frozen = opts.frozen == true,
    startsAt = p0,
    resetsAt = p0 + 30 * DAY,
  }
end

local steady = acct({ used = 2800 })
eq(model.accountLevel(steady, p0 + 20 * DAY), "ok", "40% at two thirds of the period is calm")
near(model.projectedUsed(steady, p0 + 20 * DAY), 4200, 0.5, "the pace extrapolates the average")
eq(model.paceNote(steady, p0 + 20 * DAY), "at this pace ~4,200 (60%) by the reset", "and says where it lands")

local drifting = acct({ used = 3850 })
eq(model.accountLevel(drifting, p0 + 20 * DAY), "warn", "a pace landing at 82.5% warns")
eq(model.paceNote(drifting, p0 + 20 * DAY), "at this pace ~5,775 (83%) by the reset", "with the landing figure")

local burning = acct({ used = 5600 })
near(model.creditsOutIn(burning, p0 + 20 * DAY), 5 * DAY, 60, "80% on day 20 runs out five days later")
near(model.lockout(burning, p0 + 20 * DAY), 5 * DAY, 60, "and waits five days for the renewal")
eq(model.accountLevel(burning, p0 + 20 * DAY), "crit", "a lockout of a sixth of the period is critical")
eq(model.paceNote(burning, p0 + 20 * DAY), "at this pace the credits run out in ~5d 0h", "the note names the run-out")

local tight = acct({ used = 6000 })
eq(model.accountLevel(tight, p0 + 25 * DAY), "warn", "running out under a day before the renewal only warns")

local fresh = acct({ used = 2000 })
eq(model.projectedUsed(fresh, p0 + 3600), nil, "inside the first 5% the pace means nothing")
eq(model.accountLevel(fresh, p0 + 3600), "ok", "so only the percentage counts")
eq(model.paceNote(fresh, p0 + 3600), "", "and there is nothing to say")

local nearlyOut = acct({ used = 6440 })
eq(model.accountLevel(nearlyOut, p0 + 29.5 * DAY), "crit", "92% with no packs is critical")

local packed = acct({ used = 6300, packs = 5000 })
eq(model.accountLevel(packed, p0 + 28 * DAY), "warn", "90% with packs in hand only warns")

local onPacks = acct({ used = 7000, remaining = 0, packs = 1240 })
eq(model.allowanceOutIn(onPacks, p0 + 24 * DAY), 0, "a spent allowance has run out")
eq(model.accountLevel(onPacks, p0 + 24 * DAY), "warn", "drawing on packs that last almost to the renewal warns")
eq(model.paceNote(onPacks, p0 + 24 * DAY), "the packs last about 4d 6h at this pace", "and says how long the packs last")

local thinPacks = acct({ used = 7000, remaining = 0, packs = 500 })
eq(model.accountLevel(thinPacks, p0 + 24 * DAY), "crit", "packs that run out days before the renewal are critical")

local spent = acct({ used = 7000, remaining = 0 })
eq(model.accountLevel(spent, p0 + 24 * DAY), "crit", "no credits at all is critical")
eq(model.paceNote(spent, p0 + 24 * DAY), "no credits left until the renewal", "and said plainly")

local paused = acct({ used = 10, frozen = true })
eq(model.accountLevel(paused, p0 + 10 * DAY), "crit", "a paused subscription is critical")
eq(model.paceNote(paused, p0 + 10 * DAY), "the subscription is paused", "whatever the pace")

-- ── where the credits went ──────────────────────────────────────────────────

local DS = { input = 10.5, cachedInput = 0.21, output = 42 }
local split = model.creditSplit({ new = 4169800, cached = 6480934, output = 118012 }, 16.7, DS)
near(split.new + split.cached + split.output, 16.7, 1e-9, "the estimate adds up to what NaN billed")
near(split.new / 16.7, 0.874, 0.001, "new input carries most of the credits")
near(split.cached / 16.7, 0.027, 0.001, "cached input, most of the tokens, a sliver of them")
near(split.output / 16.7, 0.099, 0.001, "output, a percent of the tokens, a tenth of the credits")
local unscaled = model.creditSplit({ new = 21271, cached = 27392, output = 287 }, 0, DS)
near(unscaled.total, 0.2412, 0.0001, "with nothing billed, the prices alone")
eq(model.creditSplit({ new = 1, cached = 0, output = 0 }, 1, nil), nil, "no price, no estimate")
eq(model.creditSplit({ new = 0, cached = 0, output = 0 }, 1, DS), nil, "no tokens, no estimate")

-- The dashboard's own "saved by cache" for 13 Nov was 0.281854: the same
-- arithmetic, to four decimals.
near(model.cacheSaved(27392, DS), 0.281854, 0.00005, "the cache saving matches the dashboard's figure")
eq(model.cacheSaved(27392, nil), 0, "and nothing without a price")

-- ── the document ────────────────────────────────────────────────────────────

-- The live answer of 13 Nov 2026, trimmed to what the model reads.
local USAGE = {
  object = "usage.report",
  data = {
    { date = "2026-11-08", model = "deepseek-v4-flash", prompt_tokens = 3791660, completion_tokens = 46177, cached_tokens = 0, api_requests = 55, credits = 0 },
    { date = "2026-11-10", model = "deepseek-v4-flash", prompt_tokens = 10650734, completion_tokens = 118012, cached_tokens = 0, api_requests = 113, credits = 16.7 },
    { date = "2026-11-10", model = "glm5.3", prompt_tokens = 545756, completion_tokens = 1512, cached_tokens = 0, api_requests = 18, credits = 9 },
    { date = "2026-11-10", model = "glm5.3-flash", prompt_tokens = 448897, completion_tokens = 213, cached_tokens = 0, api_requests = 11, credits = 0.8 },
    { date = "2026-11-13", model = "deepseek-v4-flash", prompt_tokens = 48663, completion_tokens = 287, cached_tokens = 27392, api_requests = 10, credits = 0.2 },
  },
  all_time = { total_tokens = 1014906875, api_requests = 5152 },
  credits = {
    period_start = "2026-10-26T14:52:52Z", period_end = "2026-11-26T14:52:52Z",
    allowance = 7000, used = 26.8, remaining = 6973.2, pack_credits = 0, frozen = false,
  },
}
local PRICES = {
  readAt = "2026-11-13T15:32:46Z",
  models = {
    ["deepseek-v4-flash"] = DS,
    ["glm5.3"] = { input = 49, cachedInput = 9.1, output = 154 },
  },
}

local record = model.build({ usage = USAGE, fetchedAt = now }, { gauge = "bar" }, now, PRICES)
eq(record.version, 2, "the document carries its version")
eq(record.ok, true, "with an answer, it is ok")
eq(record.billed, true, "and billed in credits")
eq(record.error, "", "no error")
eq(record.stale, false, "not stale")

local account = record.account
eq(account.pctText, "0.4%", "the share of the allowance, with a decimal below 10%")
eq(account.level, "ok", "a calm level")
eq(account.usedText, "26.8", "credits used")
eq(account.allowanceText, "7,000", "of the allowance")
eq(account.remainingText, "6,973.2", "and left")
eq(account.resetsIn, "12d", "the bar's countdown")
eq(account.resetsInLong, "12d 23h", "the long countdown")
check(account.resetsAtText:match("^26 Nov %d%d:52$") ~= nil, "the renewal in local time: " .. account.resetsAtText)
eq(account.periodText, "26 Oct – 26 Nov", "the period")
eq(account.projectedText, "~122", "the pace is measured from 10 Nov, when credit billing began")
eq(account.projectedPctText, "1.7%", "as a share of the allowance")
eq(account.paceNote, "at this pace ~122 (1.7%) by the reset", "and as a sentence")

eq(model.barFigure(account, "percent"), "0.4%", "the bar shows the percentage")
eq(model.barFigure(account, "used"), "26.8", "or the credits used")
eq(model.barFigure(account, "remaining"), "6,973", "or the credits left")

eq(#record.models, 3, "the models used since credit billing began")
eq(record.models[1].model, "deepseek-v4-flash", "the costliest first")
eq(record.models[1].creditsText, "16.9", "its credits across the period's days")
eq(record.models[1].shareText, "63%", "its share")
eq(record.models[2].creditsText, "9.0", "fixed decimals line up in the list")
eq(record.models[3].shareText, "3%", "down to the smallest")
eq(record.models[1].tokensText, "10.82M", "tokens since credit billing began, not the 8 Nov row")
eq(record.models[1].requestsText, "123", "requests")
eq(record.models[1].tokenSplit.cachedPctText, "56%", "the cache share from 11 Nov on")
eq(record.models[2].tokenSplit.cachedPctText, "", "no cache share for a model with no input since 11 Nov")

local dsSplit = record.models[1].creditSplit
eq(dsSplit.newPct, "93%", "new input's share of the estimated credits")
eq(dsSplit.cachedPct, "2%", "cached input's")
eq(dsSplit.outputPct, "5%", "output's")
eq(dsSplit.newText, "0.19", "an estimate under one credit gets two decimals")
eq(dsSplit.cachedText, "<0.01", "and under a hundredth it says so rather than print a zero")
eq(dsSplit.totalText, "0.20", "the split adds up to the credits billed since 11 Nov, not the period's 16.9")
eq(record.models[1].tokenSplit.totalText, "49K", "the token split's total, over the same days")
eq(record.modelsTotalText, "26.7", "the breakdown by model adds up to its rows")
eq(record.models[2].creditSplit, nil, "no split where there are no tokens to split")
eq(record.models[3].creditSplit, nil, "nor without a price")

eq(record.tokensSince, "11 Nov", "the token split says where it starts")
eq(record.tokens.cachedPctText, "56%", "the period's cache share")
eq(record.tokens.newText, "21K", "new input")
eq(record.tokens.cachedText, "27K", "cached input")
eq(record.tokens.outputText, "287", "output")
eq(record.savedText, "~0.3", "what the cache saved")

eq(#record.days, 17, "one bar per day from 10 Nov to the renewal")
eq(record.days[1].label, "10 Nov", "the chart starts with credit billing")
eq(record.days[4].today, true, "today is marked")
near(record.days[4].credits, 0.2, 1e-9, "with today's credits")
eq(record.days[5].future, true, "the days to come are marked")
eq(record.days[4].valueText, "0.2", "each day carries its label")
eq(record.days[1].valueText, "27", "a busy day in whole credits")
eq(record.days[1].day, "10", "and its day of the month")
eq(record.days[17].label, "26 Nov", "up to the renewal")
eq(record.peak.label, "10 Nov", "the busiest day")
near(record.peak.credits, 26.5, 1e-9, "and its credits")
eq(record.todayText, "0.2", "today's credits")
eq(record.models[1].peak.label, "10 Nov", "each model has its own series")

eq(record.allTime, "1.01B tokens · 5,152 requests", "the lifetime line")
eq(record.pricesDate, "13 Nov", "the date of the prices")
eq(record.updated, "Updated at " .. os.date("%H:%M", now), "updated stamp")

local listed = model.build({ usage = USAGE, fetchedAt = now }, {}, now, {
  readAt = PRICES.readAt,
  models = { ["deepseek-v4-flash"] = DS, ["qwen3.8-max"] = { input = 100, cachedInput = 12.5, output = 300 } },
})
eq(#listed.models, 4, "every model on the price list is listed, used or not")
eq(listed.models[4].model, "qwen3.8-max", "the unused ones after the used")
eq(listed.models[4].used, false, "marked unused")
eq(listed.models[1].used, true, "while a used one is marked used")
eq(listed.models[4].price.cachedText, "12.5", "with its prices")
eq(listed.models[1].price.cachedText, "0.21", "two decimals where a price has them")
eq(listed.models[1].price.outputText, "42", "and none where it does not")
eq(listed.modelsTotalText, "26.7", "an unused model adds nothing to the breakdown")

local unbilled = model.build({ usage = { data = USAGE.data }, fetchedAt = now }, {}, now, PRICES)
eq(unbilled.ok, true, "an account not billed in credits still has an answer")
eq(unbilled.billed, false, "but no credits")
eq(unbilled.account, nil, "and no account block to paint")

local empty = model.build({ error = "No API key at ~/.config/nan/api-key" }, {}, now, PRICES)
eq(empty.ok, false, "no data is not ok")
eq(empty.account, nil, "and nothing to paint")
eq(empty.updated, "No data", "which is said once")
eq(empty.error, "No API key at ~/.config/nan/api-key", "with the reason")

local degraded = model.build({ usage = USAGE, fetchedAt = now, error = "NaN answered 500 for /v1/usage" }, {}, now + 90, PRICES)
eq(degraded.ok, true, "last data still painted")
eq(degraded.stale, true, "flagged stale")
eq(degraded.updated, "Updated at " .. os.date("%H:%M", now) .. " · with errors", "and said so")
eq(degraded.ageSeconds, 90, "the age of the data is known")

if #failures > 0 then
  io.stderr:write(("%d of %d checks failed:\n"):format(#failures, checks))
  for _, failure in ipairs(failures) do
    io.stderr:write("  " .. failure .. "\n")
  end
  os.exit(1)
end
print(("%d checks pass (model)"):format(checks))
