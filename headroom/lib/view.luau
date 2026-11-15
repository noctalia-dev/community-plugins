--!nonstrict
-- Presentation helpers shared by the bar and the panel, so both surfaces word
-- and color the same window the same way.

local model = require("./model.luau")
local pace = require("./pace.luau")
local state = require("./state.luau")
local time = require("./time.luau")
local theme = require("./theme.luau")

local M = {}

function M.now(): number
  return os.time()
end

local RANK = { ok = 0, warn = 1, critical = 2 }

-- A window whose reset time has passed carries last cycle's numbers: they say
-- nothing about now, so surfaces show it as unknown until fresh data lands.
function M.isPastReset(window, now: number?): boolean
  return window.resetsAt ~= nil and window.resetsAt <= (now or M.now())
end

-- Usage severity, raised by the forecast: a window at 60% that will lock you
-- out for hours deserves the warning color now.
function M.severity(window, now: number): string
  if M.isPastReset(window, now) then
    return "ok"
  end
  local warn, critical = state.thresholds()
  local severity = model.severity(window.usedPercent, warn, critical)
  local p = pace.compute(window, now)
  if p and RANK[p.severity] > RANK[severity] then
    severity = p.severity
  end
  return severity
end

-- Text color for a percentage at a severity.
function M.textColor(severity: string): string
  return theme.severityColor(severity) or "on_surface"
end

-- "used" (default) or "remaining": which side of the limit numbers and meters
-- show. Severity is always computed from usage.
function M.showsRemaining(): boolean
  return state.config("display", "used") == "remaining"
end

-- The number shown for a window, 0..100, in the configured direction.
function M.shownPercent(window): number
  if M.isPastReset(window) then
    return 0 -- unknown: an empty meter, not last cycle's value
  end
  return if M.showsRemaining() then 100 - window.usedPercent else window.usedPercent
end

-- Whole percent, except that rounding never erases a difference: 0.4 is
-- "<1", 99.6 is ">99". A meter at "100% left" after real use reads as broken.
-- theme.ring applies the same rule to the arc.
function M.roundPercent(value: number): string
  if value > 0 and value < 1 then
    return "<1"
  elseif value > 99 and value < 100 then
    return ">99"
  end
  return tostring(math.floor(value + 0.5))
end

-- "38%". With `labelled`, says which side it is: "38% used" / "62% left".
function M.percent(window, labelled: boolean?): string
  if M.isPastReset(window) then
    return "—"
  end
  local value = M.roundPercent(M.shownPercent(window))
  if not labelled then
    return `{value}%`
  end
  return noctalia.tr(if M.showsRemaining() then "percent.left" else "percent.used", { percent = value })
end

-- Wall-clock time of a reset in the shell's own time format, with the weekday
-- when it is more than a day away: "20:19", "Sat 09:59".
function M.clock(at: number, now: number): string
  local clock = noctalia.formatTime(noctalia.timeFormat(), at)
  if at - now >= 86400 then
    return `{noctalia.formatTime("%a", at)} {clock}`
  end
  return clock
end

-- "3h 12m · 20:19" until the window resets, or nil when the vendor gave no
-- reset time or it has passed.
function M.untilReset(window, now: number): string?
  if window.resetsAt == nil or window.resetsAt <= now then
    return nil
  end
  return `{time.duration(window.resetsAt - now)} · {M.clock(window.resetsAt, now)}`
end

-- "Resets in 3h 12m · 20:19" / "Resetting now", or nil without a reset time.
function M.resetsIn(window, now: number): string?
  if window.resetsAt == nil then
    return nil
  end
  local untilReset = M.untilReset(window, now)
  if untilReset == nil then
    return noctalia.tr("reset.now")
  end
  return noctalia.tr("reset.in", { until_reset = untilReset })
end

-- Forecast as (text, color role, pace), or nil when it is too early to say.
function M.pace(window, now: number): (string?, string?, pace.Pace?)
  local p = pace.compute(window, now)
  if p == nil then
    return nil, nil, nil
  end
  if p.status == "exhausted" then
    return noctalia.tr("pace.exhausted"), "error", p
  elseif p.status == "runs_out" then
    local color = if p.severity == "ok" then "on_surface_variant" else M.textColor(p.severity)
    return noctalia.tr("pace.runs_out", { duration = time.duration(p.runsOutIn or 0) }), color, p
  elseif p.status == "projected" then
    local projected = p.projectedPercent or 0
    if M.showsRemaining() then
      return noctalia.tr("pace.projected_left", { percent = M.roundPercent(100 - projected) }), "on_surface_variant", p
    end
    return noctalia.tr("pace.projected", { percent = M.roundPercent(projected) }), "on_surface_variant", p
  end
  return nil, nil, p
end

-- Numbers worth dimming and marking "cached": the last fetch failed, or they
-- are more than two intervals old.
function M.isStale(account, interval: number, now: number): boolean
  local snapshot = account.snapshot
  return account.phase == "failing" or (snapshot ~= nil and now - snapshot.fetchedAt > 2 * interval)
end

-- The name an account goes by on compact surfaces: the provider's alone when
-- it has one account, "Claude · Work" when it has several.
function M.accountName(provider, account): string
  if #provider.accounts <= 1 then
    return provider.name
  end
  return `{provider.name} · {account.name}`
end

local function isShown(account): boolean
  return account.phase ~= "signed_out" and account.duplicateOf == nil
end

-- What a bar capsule shows: a list of { provider, account, name, window? },
-- in display order.
--   shown(id):    whether the user wants this provider in the bar
--   windowPref:   "tightest" | "session" | "weekly"
--   maxItems:     when more match, the most urgent ones are kept
--                 (forecast-aware severity first, then usage)
--   allAccounts:  every signed-in account, or one per provider: the default,
--                 else the first signed-in one
function M.barItems(report, shown: (string) -> boolean, windowPref: string, maxItems: number, now: number, allAccounts: boolean?): { any }
  local items = {}
  for _, provider in (if type(report) == "table" and report.providers then report.providers else {}) do
    if shown(provider.id) then
      for _, account in provider.accounts do
        if isShown(account) then
          local window = model.pick(account.snapshot and account.snapshot.windows or {}, windowPref)
          table.insert(items, {
            provider = provider,
            account = account,
            name = M.accountName(provider, account),
            window = window,
            order = #items + 1,
            urgency = if window then RANK[M.severity(window, now)] * 1000 + window.usedPercent else -1,
          })
          if not allAccounts then
            break
          end
        end
      end
    end
  end
  if #items <= maxItems then
    return items
  end
  table.sort(items, function(a, b)
    if a.urgency ~= b.urgency then
      return a.urgency > b.urgency
    end
    return a.order < b.order
  end)
  local kept = table.move(items, 1, maxItems, 1, {})
  table.sort(kept, function(a, b)
    return a.order < b.order
  end)
  return kept
end

-- ── Reset credits ─────────────────────────────────────────────────────────

-- How many resets an account holds, over all its credits.
function M.creditCount(snapshot): number
  local n = 0
  for _, credit in (snapshot and snapshot.resetCredits) or {} do
    n += credit.count
  end
  return n
end

-- When a credit expires: "in 6d · Tue 17 Nov" (the date in the shell's own
-- format), "in 5h · 20:19" within a day.
function M.expiry(at: number, now: number): string
  local when = if at - now < 86400
    then noctalia.formatTime(noctalia.timeFormat(), at)
    else noctalia.formatTime(noctalia.dateFormat(), at)
  return noctalia.tr("resets.expires", { duration = time.duration(at - now), when = when })
end

-- Expiring within this long: worth the warning color.
M.CREDIT_SOON = 48 * 3600

-- "2 resets", and the soonest expiry when there is one.
function M.creditSummary(snapshot, now: number): (string, string?, boolean)
  local count = M.creditCount(snapshot)
  local first = snapshot.resetCredits[1]
  local expiresAt = first and first.expiresAt
  return noctalia.trp("resets.count", count),
    if expiresAt then M.expiry(expiresAt, now) else nil,
    expiresAt ~= nil and expiresAt - now <= M.CREDIT_SOON
end

return M
