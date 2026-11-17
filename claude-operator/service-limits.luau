--!nonstrict
-- Plan limits: each account's usage windows from limits.sh (api/oauth/usage), shaped with
-- a sample history so the panel can project from the recent burn rate, warned about once
-- per window, saved to limits.json so a restart keeps them, and fetched again on the
-- account's timer with a backoff while Anthropic rate-limits the token.

local shared = require("./shared.luau")
local core = require("./service-core.luau")
local acc = require("./service-accounts.luau")
local accounts = core.accounts
local cfg, runJson, script, isoToMs = core.cfg, core.runJson, core.script, core.isoToMs
local SAVED_LIMITS, HOUR_MS, DAY_MS = core.SAVED_LIMITS, core.HOUR_MS, core.DAY_MS
local M = {}

local WINDOW_MS = { session = 5 * HOUR_MS }

local function windowLabel(w)
  if w.kind == "session" then return "5h" end
  if w.kind == "weekly_all" then return "7d" end
  return (w.model or w.kind or "?") .. (w.group == "weekly" and " 7d" or "")
end

-- Usage samples per window, so the UI can project from the recent burn rate rather than
-- the window's average: the 5-hour window is mostly about the last half hour. A sample
-- is added on every successful fetch; a new resetsAt means a new window, which starts
-- an empty list. Lookback per window kind, and the shortest span a rate is trusted from.
local LOOKBACK = { session = HOUR_MS, weekly = DAY_MS }
local MIN_SPAN = { session = 30 * 60000, weekly = 3 * HOUR_MS }
-- Samples cover the whole window, for the Usage tab's forecast graph; weekly ones are
-- thinned to one per half hour (the newest wins), at most ~340 per window.
local THIN = { session = 0, weekly = 30 * 60000 }

-- The API's resets_at wobbles between fetches, so "same window" allows ten minutes.
local function sameWindow(prev, w)
  return prev ~= nil and prev.resetsAt ~= nil and w.resetsAt ~= nil and math.abs(prev.resetsAt - w.resetsAt) < 10 * 60000
end

local function addSample(w, prev, now)
  local kind = w.kind == "session" and "session" or "weekly"
  local same = sameWindow(prev, w)
  local start = (w.resetsAt or now) - (w.durationMs or 7 * DAY_MS)
  local samples = {}
  for _, smp in ipairs(same and type(prev.samples) == "table" and prev.samples or {}) do
    if smp[1] >= start then samples[#samples + 1] = smp end
  end
  local last = samples[#samples]
  if last and now - last[1] < THIN[kind] then samples[#samples] = nil end
  samples[#samples + 1] = { now, w.percent }
  w.samples = samples
  -- Recent rate: from the oldest sample inside the lookback to now.
  local first
  for _, smp in ipairs(samples) do
    if now - smp[1] <= LOOKBACK[kind] then first = smp break end
  end
  local span = first and now - first[1] or 0
  if span >= MIN_SPAN[kind] then
    w.rate = math.max(0, (w.percent - first[2]) / (span / HOUR_MS)) -- percent per hour
    w.rateSpanMs = span
  end
end

local function shapeLimits(raw, previous)
  local now = noctalia.nowMs()
  local prevById = {}
  for _, w in ipairs(previous and previous.windows or {}) do prevById[w.id] = w end
  local windows = {}
  for _, w in ipairs(type(raw.windows) == "table" and raw.windows or {}) do
    if type(w) == "table" and tonumber(w.percent) then
      local shaped = {
        id = `{w.kind or "window"}:{w.model or ""}`, label = windowLabel(w),
        kind = w.kind, group = w.group, model = w.model,
        percent = tonumber(w.percent), resetsAt = isoToMs(w.resets_at),
        durationMs = WINDOW_MS[w.kind] or 7 * DAY_MS, severity = w.severity,
      }
      local prev = prevById[shaped.id]
      addSample(shaped, prev, now)
      -- Saved with the limits, so a restart never repeats a window's notice.
      if sameWindow(prev, shaped) then
        shaped.warned = prev.warned
        shaped.rose = shaped.percent > (tonumber(prev.percent) or 0)
      end
      windows[#windows + 1] = shaped
    end
  end
  return { updated = now, stale = false, subscription = raw.subscription, tier = raw.tier, windows = windows }
end

-- One notice per window when the current rate reaches the limit within the hour (5-hour
-- window) or the day (weekly ones), and only while usage is still rising: a weekly
-- average can say "soon" for days after the last session.
local function warnLimits(a)
  if not cfg("notify_limits", true) then return end
  for _, w in ipairs(a.limits.windows) do
    local p = shared.pace(w)
    if p.status == "soon" and w.rose and not w.warned then
      w.warned = true
      local headline = shared.paceText(w, p)
      noctalia.notify(`Claude: {w.label} limit soon`, `{headline}. {w.label} is at {shared.round(w.percent)}%.`)
    end
  end
end

local function saveLimits()
  local out = {}
  for dir, a in pairs(accounts) do if a.limits then out[dir] = a.limits end end
  noctalia.writeFile(SAVED_LIMITS, noctalia.json.encode(out))
end

-- An expired token (Claude Code refreshes it on its next start) keeps the last limits,
-- marked stale with the reason; the reason is logged once per change, not every fetch.
-- api/oauth/usage is rate limited, and Claude Code's statusline and other tools may use
-- the same token. On a 429 the next try waits for the server's Retry-After, or a backoff
-- from 10 minutes doubling to an hour; a success resets it.
local BACKOFF_MS, BACKOFF_MAX_MS = 10 * 60000, HOUR_MS
-- Manual refreshes and settings changes never fetch sooner than this after the last try.
M.MIN_GAP_MS = 2 * 60000

function M.fetchLimits(a)
  if a.limitsPending or noctalia.nowMs() < (a.limitsHold or 0) then return end
  a.limitsPending, a.limitsAt = true, noctalia.nowMs()
  local started = runJson(script("limits.sh", a.dir), 20000, function(raw, r)
    a.limitsPending = false
    local err = nil
    if raw then
      a.limits = shapeLimits(raw, a.limits)
      warnLimits(a)
      saveLimits()
      a.limitsBackoff, a.limitsHold = nil, nil
    elseif r.exitCode == 4 then
      local wait = (tonumber(noctalia.string.trim(r.stdout or "")) or 0) * 1000
      a.limitsBackoff = math.min(BACKOFF_MAX_MS, a.limitsBackoff and a.limitsBackoff * 2 or BACKOFF_MS)
      a.limitsHold = noctalia.nowMs() + math.max(wait, a.limitsBackoff)
      err = `rate limited by Anthropic, next try {os.date("%H:%M", a.limitsHold // 1000)}`
      if a.limits then a.limits.stale, a.limits.error = true, err end
    else
      err = noctalia.string.trim(r.stderr or "")
      if err == "" then err = r.timedOut and "timed out" or `exit {r.exitCode}` end
      if a.limits then a.limits.stale, a.limits.error = true, err end
    end
    if err ~= a.limitsErr and err then noctalia.log(`claude-operator: limits ({a.label}): {err}`) end
    a.limitsErr = err
    acc.publishAccounts()
  end)
  if not started then a.limitsPending = false end
end

return M
