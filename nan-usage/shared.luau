--!nonstrict
-- The model: what NaN's /v1/usage returns in, what the bar widget and the panel paint out.
--
-- Pure by construction. It calls nothing on `noctalia.*` and reads no clock of its
-- own: every derivation that depends on time takes it as an argument, in whole
-- seconds since the epoch, and the price table comes in as an argument too. That is
-- what lets `tests/shared_test.lua` run this file under a fixed clock with plain Lua,
-- and it is also why a countdown can be recomputed from data already held without
-- touching the network.
--
-- The readers are tolerant: numbers may arrive as strings, timestamps as ISO strings,
-- dates or epoch numbers, and anything unreadable degrades to a zero value rather
-- than throwing away the whole response.

local M = {}

-- ── Days the data changes meaning on ────────────────────────────────────────

-- The UTC day NaN began billing in credits. Rows before it bill nothing, so the
-- plugin neither counts them nor measures a pace across them.
M.CREDITS_SINCE = "2026-11-10"

-- The UTC day NaN began reporting cached input. Before it `cached_tokens` is 0
-- whatever happened, so the cache share and the token split start here.
M.CACHE_SINCE = "2026-11-11"

-- ── Levels ──────────────────────────────────────────────────────────────────

local RANK = { ok = 0, warn = 1, crit = 2 }

-- Share of the measured span that has to have passed before a pace means anything:
-- in the first hours the average is noise.
local MIN_ELAPSED_FRAC = 0.05

-- Share of the period that has to be spent without credits for that to count as
-- critical. Running out just before the renewal only warrants a warning.
local LOCKOUT_CRIT_FRAC = 0.10

local DAY = 86400

function M.rank(level)
  return RANK[level] or 0
end

-- The more alarming of two levels.
function M.maxLevel(a, b)
  if (RANK[a] or 0) >= (RANK[b] or 0) then
    return a
  end
  return b
end

-- How full the allowance is right now.
function M.utilLevel(util)
  if util >= 90 then
    return "crit"
  end
  if util >= 75 then
    return "warn"
  end
  return "ok"
end

-- ── Reading values the API is careless about ────────────────────────────────

-- A number that may arrive as a string ("8000000"), or as junk, which becomes 0.
local function num(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value) or 0
  end
  return 0
end

-- A string that may arrive as a number, trimmed; "" when absent.
local function str(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "number" then
    return tostring(value)
  end
  return ""
end

-- Local-minus-UTC in seconds at a given instant. Recomputed per instant so a
-- value that straddles a DST change is out by at most the one hour it crosses.
--
-- isdst must be cleared: os.date("!*t") sets it to false, and os.time honours it,
-- which would read a UTC breakdown back as standard time all summer.
local function utcOffset(at)
  local fields = os.date("!*t", at)
  fields.isdst = nil
  return os.time(fields) - at
end

-- A timestamp: ISO ("2026-10-01T00:00:00Z"), with an explicit offset, a bare date
-- ("2026-09-01"), epoch seconds, or a number-as-string. nil when unreadable.
local function unix(value)
  if type(value) == "number" then
    return value
  end
  local raw = str(value)
  if raw == "" then
    return nil
  end
  local plain = tonumber(raw)
  if plain then
    return plain
  end
  local year, month, day, hour, min, sec = raw:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ]?(%d*):?(%d*):?(%d*)")
  if not year then
    return nil
  end
  local fields = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour) or 0,
    min = tonumber(min) or 0,
    sec = tonumber(sec) or 0,
  })
  if not fields then
    return nil
  end
  -- os.time read those fields as local wall time; they are UTC unless the string
  -- says otherwise.
  if hour == "" then
    -- A bare date: a calendar day, so read it as local midnight rather than
    -- shifting it into the previous day for anyone west of UTC.
    return fields
  end
  local at = fields - utcOffset(fields)
  local sign, offh, offm = raw:match("([%+%-])(%d%d):(%d%d)%s*$")
  if sign then
    local shift = (tonumber(offh) * 60 + tonumber(offm)) * 60
    at = at - (sign == "+" and shift or -shift)
  end
  return at
end

-- The UTC day an instant falls on, the way the API names days: "2026-11-13".
function M.utcDate(at)
  return os.date("!%Y-%m-%d", at)
end

-- Midnight UTC at the start of a day named that way.
local function utcMidnight(date)
  return unix(date .. "T00:00:00Z")
end

-- ── Formatting ──────────────────────────────────────────────────────────────

-- 3.00 → 3, 1.50 → 1.5
local function trimZeros(text)
  if not text:find(".", 1, true) then
    return text
  end
  text = text:gsub("0+$", "")
  return (text:gsub("%.$", ""))
end

-- 6973 → 6,973
local function group(digits)
  local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

-- A token count in compact form: 3B, 1.5B, 79.9M, 398K, 42.
function M.fmtTokens(n)
  local v = math.max(0, num(n))
  if v >= 1e9 then
    return trimZeros(string.format("%.2f", v / 1e9)) .. "B"
  elseif v >= 1e6 then
    return trimZeros(string.format("%.2f", v / 1e6)) .. "M"
  elseif v >= 1e3 then
    return string.format("%.0f", math.floor(v / 1e3 + 0.5)) .. "K"
  end
  return string.format("%.0f", math.floor(v + 0.5))
end

-- A percentage: whole numbers, and one decimal below 10% when fine is set, where a
-- plain "0%" says nothing for weeks.
function M.fmtPct(util, fine)
  local v = math.max(0, num(util))
  if fine and v < 10 then
    return string.format("%.1f%%", v)
  end
  return string.format("%.0f%%", math.floor(v + 0.5))
end

-- Credits, which NaN reports to one decimal. form is "fixed" (always one decimal,
-- for figures that line up in a list), "whole" (rounded, for large figures in the
-- bar), or anything else for one decimal only when there is one: 26.5, 7,000.
function M.fmtCredits(n, form)
  local v = math.max(0, num(n))
  if form == "whole" then
    return group(string.format("%.0f", math.floor(v + 0.5)))
  end
  local text = string.format("%.1f", math.floor(v * 10 + 0.5) / 10)
  local whole, frac = text:match("^(%d+)%.(%d)$")
  if form ~= "fixed" and frac == "0" then
    return group(whole)
  end
  return group(whole) .. "." .. frac
end

-- Credits in the fewest characters, for a label over a chart column a few pixels
-- wide: 0.2, 5.6, 27, 1.2k. Empty for none, so a quiet day carries no label.
function M.fmtCreditsShort(n)
  local v = math.max(0, num(n))
  if v <= 0 then
    return ""
  end
  if v >= 1000 then
    return trimZeros(string.format("%.1f", v / 1000)) .. "k"
  end
  if v >= 10 then
    return string.format("%.0f", math.floor(v + 0.5))
  end
  return trimZeros(string.format("%.1f", math.floor(v * 10 + 0.5) / 10))
end

-- A duration with at most two units. compact is the bar form (20d, 4h21m, 45m);
-- the long form is 20d 4h, 4h 21m, 45 min.
function M.humanDuration(seconds, compact)
  local secs = math.floor(math.max(0, num(seconds)))
  if secs < 60 then
    return compact and (secs .. "s") or (secs .. " s")
  end
  local mins = math.floor(secs / 60 + 0.5)
  if mins < 60 then
    return compact and (mins .. "m") or (mins .. " min")
  end
  local hrs = math.floor(mins / 60)
  if hrs < 24 then
    if compact then
      return hrs .. "h" .. (mins % 60) .. "m"
    end
    return hrs .. "h " .. (mins % 60) .. "m"
  end
  local days = math.floor(hrs / 24)
  if compact then
    return days .. "d"
  end
  return days .. "d " .. (hrs % 24) .. "h"
end

-- Time of day, in the shell's own timezone.
function M.clockTime(at)
  if not at then
    return ""
  end
  return os.date("%H:%M", at)
end

-- Day and month, the Go layout "2 Jan" with its unpadded day.
function M.shortDate(at)
  if not at then
    return ""
  end
  local day = os.date("%d", at):gsub("^0", "")
  return day .. " " .. os.date("%b", at)
end

-- A day the API names ("2026-11-10") the same way: "10 Nov".
function M.dayLabel(date)
  return M.shortDate(unix(date))
end

-- ── The request window ──────────────────────────────────────────────────────

-- The first day to ask /v1/usage for: the UTC day the billing period started, or
-- 31 days back while the period is not known yet, and never before credit billing
-- began. periodStart is the previous answer's `credits.period_start`, or nil.
function M.windowStart(periodStart, now)
  local at = unix(periodStart)
  local from = M.utcDate(at or (now - 31 * DAY))
  if from < M.CREDITS_SINCE then
    from = M.CREDITS_SINCE
  end
  return from
end

-- ── Reading a response ──────────────────────────────────────────────────────

-- The `credits` block: the current billing period, whatever window was asked for.
-- nil when the account is not billed in credits (the API sends null).
function M.account(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local allowance = math.max(0, num(raw.allowance))
  local used = math.max(0, num(raw.used))
  local remaining = allowance - used
  if raw.remaining ~= nil then
    remaining = num(raw.remaining)
  end
  return {
    allowance = allowance,
    used = used,
    remaining = remaining,
    packs = math.max(0, num(raw.pack_credits)),
    packsExpireAt = unix(raw.pack_expires_at),
    frozen = raw.frozen == true,
    startsAt = unix(raw.period_start),
    resetsAt = unix(raw.period_end),
  }
end

-- The (day, model) rows from `from` on, normalised. cached never exceeds the input
-- it is part of.
function M.rows(raw, from)
  local data = raw and raw.data
  if type(data) ~= "table" then
    return {}
  end
  local out = {}
  for _, entry in ipairs(data) do
    if type(entry) == "table" then
      local date, model = str(entry.date), str(entry.model)
      if date:match("^%d%d%d%d%-%d%d%-%d%d$") and model ~= "" and (from == nil or date >= from) then
        local prompt = math.max(0, num(entry.prompt_tokens))
        out[#out + 1] = {
          date = date,
          model = model,
          prompt = prompt,
          cached = math.min(prompt, math.max(0, num(entry.cached_tokens))),
          output = math.max(0, num(entry.completion_tokens)),
          requests = math.max(0, num(entry.api_requests)),
          credits = math.max(0, num(entry.credits)),
        }
      end
    end
  end
  return out
end

-- ── Pace ────────────────────────────────────────────────────────────────────

-- The span the average rate is measured over: from the later of the period start
-- and the day credit billing began, to the renewal. nil until enough of it has
-- passed to mean something, and once the period is over.
local function span(acct, now)
  if not acct.startsAt or not acct.resetsAt or acct.resetsAt <= acct.startsAt then
    return nil
  end
  local from = math.max(acct.startsAt, utcMidnight(M.CREDITS_SINCE))
  local total = acct.resetsAt - from
  local elapsed = now - from
  local remaining = acct.resetsAt - now
  if total <= 0 or remaining <= 0 or elapsed <= 0 or elapsed < total * MIN_ELAPSED_FRAC then
    return nil
  end
  return { total = total, elapsed = elapsed, remaining = remaining }
end

-- The credits the period would end at if the average rate held until the renewal.
-- Never below what is already used.
function M.projectedUsed(acct, now)
  local s = span(acct, now)
  if not s then
    return nil
  end
  return math.max(acct.used, acct.used * s.total / s.elapsed)
end

-- How long `left` credits last at the average rate, and only when they run out
-- before the renewal.
local function lastsFor(acct, left, now)
  if left <= 0 then
    return 0
  end
  local s = span(acct, now)
  if not s or acct.used <= 0 then
    return nil
  end
  local after = left * s.elapsed / acct.used
  if after < s.remaining then
    return after
  end
  return nil
end

-- When the plan's allowance runs out at the average rate, if before the renewal.
function M.allowanceOutIn(acct, now)
  return lastsFor(acct, math.max(0, acct.remaining), now)
end

-- When every credit, the allowance and then the packs, runs out at the average
-- rate, if before the renewal.
function M.creditsOutIn(acct, now)
  return lastsFor(acct, math.max(0, acct.remaining) + acct.packs, now)
end

-- How long the account would wait for the renewal with no credits at all.
function M.lockout(acct, now)
  local out = M.creditsOutIn(acct, now)
  if out == nil or not acct.resetsAt then
    return nil
  end
  return math.max(0, (acct.resetsAt - now) - out)
end

-- Level by the consequence of the pace, not by the percentage alone. Packs are
-- credits that can still be spent, so 90% with packs in hand is not critical.
function M.accountLevel(acct, now)
  if acct.frozen then
    return "crit"
  end
  if math.max(0, acct.remaining) + acct.packs <= 0 then
    return "crit"
  end
  local pct = acct.allowance > 0 and acct.used / acct.allowance * 100 or 100
  local level = "ok"
  if acct.packs <= 0 then
    level = M.utilLevel(pct)
  elseif pct >= 75 then
    level = "warn"
  end
  local lock = M.lockout(acct, now)
  if lock ~= nil and acct.startsAt and acct.resetsAt then
    if lock >= (acct.resetsAt - acct.startsAt) * LOCKOUT_CRIT_FRAC then
      return "crit"
    end
    level = M.maxLevel(level, "warn")
  end
  -- Drawing on packs, or heading there before the renewal.
  if M.allowanceOutIn(acct, now) ~= nil then
    level = M.maxLevel(level, "warn")
  end
  local projected = M.projectedUsed(acct, now)
  if projected and acct.allowance > 0 and projected / acct.allowance * 100 >= 75 then
    level = M.maxLevel(level, "warn")
  end
  return level
end

-- The pace as a sentence, tied to the same thresholds as accountLevel. Empty when
-- there is too little of the period to judge.
function M.paceNote(acct, now)
  if acct.frozen then
    return "the subscription is paused"
  end
  if math.max(0, acct.remaining) + acct.packs <= 0 then
    return "no credits left until the renewal"
  end
  local out = M.creditsOutIn(acct, now)
  if out then
    if acct.remaining <= 0 then
      return "the packs last about " .. M.humanDuration(out, false) .. " at this pace"
    end
    return "at this pace the credits run out in ~" .. M.humanDuration(out, false)
  end
  local projected = M.projectedUsed(acct, now)
  if projected and acct.allowance > 0 then
    return "at this pace ~" .. M.fmtCredits(projected, "whole") .. " ("
      .. M.fmtPct(projected / acct.allowance * 100, true) .. ") by the reset"
  end
  return ""
end

-- ── Where the credits went ──────────────────────────────────────────────────

-- The credits a model's tokens cost, split by type, from NaN's prices, then scaled
-- so the three add up to what NaN billed. The scaling absorbs NaN's rounding to one
-- decimal, and means only the ratio between a model's three prices matters. nil
-- without a price or without tokens.
function M.creditSplit(tokens, billed, price)
  if type(price) ~= "table" then
    return nil
  end
  local new = tokens.new * num(price.input) / 1e6
  local cached = tokens.cached * num(price.cachedInput) / 1e6
  local output = tokens.output * num(price.output) / 1e6
  local raw = new + cached + output
  if raw <= 0 then
    return nil
  end
  local scale = billed > 0 and billed / raw or 1
  return {
    new = new * scale,
    cached = cached * scale,
    output = output * scale,
    total = raw * scale,
  }
end

-- A model's three prices as the panel prints them, in credits per 1M tokens: up to
-- two decimals, since some are fractions of a credit (0.21). nil without a price.
function M.priceView(price)
  if type(price) ~= "table" then
    return nil
  end
  local function text(value)
    return trimZeros(string.format("%.2f", num(value)))
  end
  return { newText = text(price.input), cachedText = text(price.cachedInput), outputText = text(price.output) }
end

-- What the cache saved: the cached tokens at the input price, less what they cost
-- at the cached price. The same arithmetic as the dashboard's own figure.
function M.cacheSaved(cached, price)
  if type(price) ~= "table" then
    return 0
  end
  return cached * math.max(0, num(price.input) - num(price.cachedInput)) / 1e6
end

local function tokenView(t)
  local input = t.new + t.cached
  local view = {
    new = t.new,
    cached = t.cached,
    output = t.output,
    newText = M.fmtTokens(t.new),
    totalText = M.fmtTokens(t.new + t.cached + t.output),
    cachedText = M.fmtTokens(t.cached),
    outputText = M.fmtTokens(t.output),
    cachedPct = nil,
    cachedPctText = "",
  }
  if input > 0 then
    view.cachedPct = t.cached / input * 100
    view.cachedPctText = M.fmtPct(view.cachedPct, false)
  end
  return view
end

local function splitView(s)
  if s == nil then
    return nil
  end
  local function share(part)
    return s.total > 0 and part / s.total * 100 or 0
  end
  -- An estimate under one credit gets two decimals: "0.0" would hide that the
  -- cached input cost anything at all. Under a hundredth, two decimals would still
  -- print zero next to a share that is not, so it says so instead.
  local function amount(part)
    if part > 0 and part < 0.01 then
      return "<0.01"
    end
    if part > 0 and part < 1 then
      return string.format("%.2f", part)
    end
    return M.fmtCredits(part, "fixed")
  end
  return {
    new = s.new,
    cached = s.cached,
    output = s.output,
    newText = amount(s.new),
    totalText = amount(s.total),
    cachedText = amount(s.cached),
    outputText = amount(s.output),
    newPct = M.fmtPct(share(s.new), false),
    cachedPct = M.fmtPct(share(s.cached), false),
    outputPct = M.fmtPct(share(s.output), false),
  }
end

-- The days a chart draws: every UTC day from the window start to the renewal.
local function dayList(from, resetsAt, today)
  local last = resetsAt and M.utcDate(resetsAt - 1) or today
  if last < today then
    last = today
  end
  local out = {}
  local at = utcMidnight(from)
  while at ~= nil and #out < 45 do
    local date = M.utcDate(at)
    if date > last then
      break
    end
    out[#out + 1] = date
    at = at + DAY
  end
  return out
end

local function series(dates, byDate, today)
  local out, peak = {}, nil
  for _, date in ipairs(dates) do
    local credits = byDate[date] or 0
    local entry = {
      date = date,
      label = M.dayLabel(date),
      day = tostring(tonumber(date:sub(9, 10))),
      credits = credits,
      valueText = M.fmtCreditsShort(credits),
      today = date == today,
      future = date > today,
    }
    out[#out + 1] = entry
    if credits > 0 and (peak == nil or credits > peak.credits) then
      peak = entry
    end
  end
  return out, peak
end

-- ── The document the surfaces paint ─────────────────────────────────────────

-- What the bar's figure says, for a `bar_value` of percent, used or remaining. A
-- paused subscription and an account drawing on packs override it, because the
-- usual figure would hide what matters.
function M.barFigure(acct, barValue)
  if acct.frozen then
    return "paused"
  end
  if acct.usingPacks then
    return "packs " .. M.fmtCredits(acct.packs, "whole")
  end
  if barValue == "used" then
    return acct.used < 100 and M.fmtCredits(acct.used) or M.fmtCredits(acct.used, "whole")
  end
  if barValue == "remaining" then
    return M.fmtCredits(math.max(0, acct.remaining), "whole")
  end
  return acct.pctText
end

local function accountView(acct, now)
  local pct = acct.allowance > 0 and acct.used / acct.allowance * 100 or 100
  local view = {
    allowance = acct.allowance,
    used = acct.used,
    remaining = acct.remaining,
    packs = acct.packs,
    frozen = acct.frozen,
    usingPacks = acct.remaining <= 0 and acct.packs > 0,
    outOfCredits = math.max(0, acct.remaining) + acct.packs <= 0,
    pct = pct,
    pctText = M.fmtPct(pct, true),
    level = M.accountLevel(acct, now),
    usedText = M.fmtCredits(acct.used),
    allowanceText = M.fmtCredits(acct.allowance),
    remainingText = M.fmtCredits(math.max(0, acct.remaining)),
    packsText = M.fmtCredits(acct.packs),
    packsExpire = M.shortDate(acct.packsExpireAt),
    resetsIn = "",
    resetsInLong = "",
    resetsAtText = "",
    periodText = "",
    projected = M.projectedUsed(acct, now),
    projectedText = "",
    projectedPctText = "",
    paceNote = M.paceNote(acct, now),
  }
  if acct.resetsAt then
    view.resetsIn = M.humanDuration(acct.resetsAt - now, true)
    view.resetsInLong = M.humanDuration(acct.resetsAt - now, false)
    view.resetsAtText = M.shortDate(acct.resetsAt) .. " " .. M.clockTime(acct.resetsAt)
  end
  if acct.startsAt and acct.resetsAt then
    view.periodText = M.shortDate(acct.startsAt) .. " – " .. M.shortDate(acct.resetsAt)
  end
  if view.projected and acct.allowance > 0 then
    view.projectedText = "~" .. M.fmtCredits(view.projected, "whole")
    view.projectedPctText = M.fmtPct(view.projected / acct.allowance * 100, true)
  end
  return view
end

-- Assembles the record the widget and the panel paint.
--
-- `state` is what the service holds: the last /v1/usage answer, when it was read,
-- and any error. `prices` is prices.luau. `now` is the clock, so every countdown is
-- recomputed from the same data on each repaint rather than only on each poll.
function M.build(state, cfg, now, prices)
  state = state or {}
  cfg = cfg or {}
  local priceTable = (type(prices) == "table" and type(prices.models) == "table") and prices.models or {}
  local record = {
    version = 2,
    ok = false,
    billed = false,
    stale = false,
    error = state.error or "",
    fetchedAt = state.fetchedAt,
    ageSeconds = state.fetchedAt and math.max(0, now - state.fetchedAt) or 0,
    updated = "",
    account = nil,
    models = {},
    days = {},
    peak = nil,
    today = 0,
    todayText = "0",
    tokens = nil,
    tokensSince = "",
    saved = 0,
    savedText = "",
    allTime = "",
    modelsTotalText = "0.0",
    pricesDate = "",
    gauge = cfg.gauge or "bar",
    pollSeconds = cfg.pollSeconds or 300,
  }
  if type(prices) == "table" and prices.readAt then
    record.pricesDate = M.shortDate(unix(prices.readAt))
  end

  local usage = state.usage
  if type(usage) == "table" then
    record.ok = true
    local acct = M.account(usage.credits)
    local from = M.windowStart(acct and acct.startsAt, now)
    local today = M.utcDate(now)
    local cacheFrom = from < M.CACHE_SINCE and M.CACHE_SINCE or from
    if from < M.CACHE_SINCE then
      record.tokensSince = M.dayLabel(M.CACHE_SINCE)
    end

    if acct then
      record.billed = true
      record.account = accountView(acct, now)
    end

    -- One pass over the rows: per model, per day, and the cache-era totals.
    local byModel, order = {}, {}
    local byDate = {}
    local totalCredits = 0
    local all = { new = 0, cached = 0, output = 0 }
    for _, row in ipairs(M.rows(usage, from)) do
      local m = byModel[row.model]
      if m == nil then
        m = {
          model = row.model, credits = 0, tokens = 0, requests = 0,
          split = { new = 0, cached = 0, output = 0, credits = 0 }, byDate = {},
        }
        byModel[row.model] = m
        order[#order + 1] = m
      end
      m.credits = m.credits + row.credits
      m.tokens = m.tokens + row.prompt + row.output
      m.requests = m.requests + row.requests
      m.byDate[row.date] = (m.byDate[row.date] or 0) + row.credits
      if row.date >= cacheFrom then
        m.split.new = m.split.new + row.prompt - row.cached
        m.split.cached = m.split.cached + row.cached
        m.split.output = m.split.output + row.output
        m.split.credits = m.split.credits + row.credits
      end
      byDate[row.date] = (byDate[row.date] or 0) + row.credits
      totalCredits = totalCredits + row.credits
      if row.date == today then
        record.today = record.today + row.credits
      end
    end
    record.todayText = M.fmtCredits(record.today)
    -- What the models' rows add up to. NaN rounds each row on its own, so this can
    -- be a tenth off the account's own total; the breakdown sums to this one.
    record.modelsTotalText = M.fmtCredits(totalCredits, "fixed")

    -- Every model on NaN's price list is listed, used or not, so the panel can show
    -- what each costs before it has been used. A used model that is not on the list
    -- (one added after the prices were read) is listed all the same.
    for name in pairs(priceTable) do
      if byModel[name] == nil then
        byModel[name] = {
          model = name, credits = 0, tokens = 0, requests = 0,
          split = { new = 0, cached = 0, output = 0, credits = 0 }, byDate = {},
        }
        order[#order + 1] = byModel[name]
      end
    end

    table.sort(order, function(a, b)
      if a.credits ~= b.credits then
        return a.credits > b.credits
      end
      if a.tokens ~= b.tokens then
        return a.tokens > b.tokens
      end
      return a.model < b.model
    end)

    local dates = dayList(from, acct and acct.resetsAt, today)
    record.days, record.peak = series(dates, byDate, today)

    for _, m in ipairs(order) do
      local price = priceTable[m.model]
      local share = totalCredits > 0 and m.credits / totalCredits * 100 or 0
      local saved = M.cacheSaved(m.split.cached, price)
      local view = {
        model = m.model,
        credits = m.credits,
        creditsText = M.fmtCredits(m.credits, "fixed"),
        share = share,
        shareText = M.fmtPct(share, false),
        tokens = m.tokens,
        tokensText = M.fmtTokens(m.tokens),
        requests = m.requests,
        requestsText = group(string.format("%.0f", m.requests)),
        tokenSplit = tokenView(m.split),
        creditSplit = splitView(M.creditSplit(m.split, m.split.credits, price)),
        saved = saved,
        priced = price ~= nil,
        used = m.credits > 0 or m.tokens > 0,
        price = M.priceView(price),
      }
      view.days, view.peak = series(dates, m.byDate, today)
      record.models[#record.models + 1] = view
      all.new = all.new + m.split.new
      all.cached = all.cached + m.split.cached
      all.output = all.output + m.split.output
      record.saved = record.saved + saved
    end
    record.tokens = tokenView(all)
    if record.saved > 0 then
      record.savedText = "~" .. M.fmtCredits(record.saved, "fixed")
    end

    local lifetime = usage.all_time
    if type(lifetime) == "table" then
      record.allTime = M.fmtTokens(lifetime.total_tokens) .. " tokens · "
        .. group(string.format("%.0f", math.max(0, num(lifetime.api_requests)))) .. " requests"
    end
  end

  record.stale = record.error ~= "" and record.ok
  if state.fetchedAt then
    record.updated = "Updated at " .. M.clockTime(state.fetchedAt)
    if record.error ~= "" then
      record.updated = record.updated .. " · with errors"
    end
  elseif record.error ~= "" then
    record.updated = "No data"
  end
  return record
end

return M
