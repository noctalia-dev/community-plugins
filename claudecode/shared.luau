--!nonstrict
-- Claude Code Usage — helpers shared by the bar widget, the panel and the desktop
-- widget (require("./shared.luau"), plugin_api 26). Entries run in isolated VMs, so
-- this module is the one copy of the formatters, the countdown math and the pacing
-- model; the three surfaces cannot drift apart on how a number reads.

local M = {}

-- ── formatters (ported from ClaudeCodeUsageWidget.qml) ─────────────────────

function M.formatTokens(n)
  n = tonumber(n) or 0
  if n >= 1000000000 then return string.format("%.1fB", n / 1000000000) end
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 1000 then return string.format("%.1fK", n / 1000) end
  return tostring(math.floor(n + 0.5))
end

-- "auto" currency follows the active UI language via a translation-resolved hint.
function M.currencyMode()
  local c = noctalia.getConfig("currency")
  if c == "usd" or c == "eur" then return c end
  return noctalia.tr("currency.auto_default")
end

function M.formatCost(usd, rate)
  usd = tonumber(usd) or 0
  rate = tonumber(rate) or 0
  local useEur = M.currencyMode() == "eur" and rate > 0
  local n = useEur and usd * rate or usd
  local sym = useEur and "" or "$"
  local suffix = useEur and " €" or ""
  if n >= 1000 then return `{sym}{string.format("%.1f", n / 1000)}K{suffix}` end
  if n >= 100 then return `{sym}{math.floor(n + 0.5)}{suffix}` end
  if n >= 10 then return `{sym}{string.format("%.1f", n)}{suffix}` end
  return `{sym}{string.format("%.2f", n)}{suffix}`
end

function M.shortModelName(name)
  if type(name) ~= "string" or #name == 0 then return tostring(name) end
  return name:sub(1, 1):upper() .. name:sub(2)
end

function M.round(x)
  return math.floor((tonumber(x) or 0) + 0.5)
end

-- ── plan naming ────────────────────────────────────────────────────────────
-- The credentials file reports the plan as machine tokens: subscriptionType is
-- "team", rateLimitTier is "default_claude_max_5x". Neither is meant to be read
-- by a person, so they are rebuilt into "Claude Team 5x".

-- Words that name a plan, in the form they should be shown.
local PLAN_WORDS = {
  free = "Free", pro = "Pro", max = "Max", team = "Team",
  enterprise = "Enterprise", business = "Business",
}

local function titleCase(word)
  -- "5x" and the like are already written the way they should read.
  if word:match("^%d") then return word end
  return word:sub(1, 1):upper() .. word:sub(2)
end

-- "team" + "default_claude_max_5x" → "Claude Team 5x". An unrecognized tier is
-- title-cased word by word rather than dropped, so a plan we have never seen
-- still reads as words instead of disappearing.
function M.planName(subscription, tier)
  local function clean(v)
    if type(v) ~= "string" then return nil end
    v = v:lower()
    if v == "" or v == "unknown" then return nil end
    return v
  end

  subscription, tier = clean(subscription), clean(tier)
  if not subscription and not tier then return "Claude Code" end

  -- Strip the tier's bookkeeping prefixes: "default_", a "t1_"-style rank, and
  -- the vendor name we are about to put back at the front anyway.
  local rest = tier or ""
  rest = rest:gsub("^default_", ""):gsub("^t%d+_", ""):gsub("^claude_", "")

  local words, multiplier, family = {}, nil, nil
  for word in rest:gmatch("[^_]+") do
    if word:match("^%d+x$") then
      multiplier = word
    else
      if PLAN_WORDS[word] and not family then family = word end
      table.insert(words, word)
    end
  end

  -- The subscription is the plan the account is actually on; the tier's own
  -- family word is the fallback when it says nothing useful.
  local plan = PLAN_WORDS[subscription or ""] or (family and PLAN_WORDS[family])
  if not plan then
    if #words > 0 then
      local shown = {}
      for _, w in words do table.insert(shown, titleCase(w)) end
      plan = table.concat(shown, " ")
    elseif subscription then
      plan = titleCase(subscription)
    end
  end

  local parts = { "Claude" }
  if plan and plan ~= "" then table.insert(parts, plan) end
  if multiplier then table.insert(parts, multiplier) end
  return table.concat(parts, " ")
end

-- ── time (reset timestamps are ISO-8601 UTC) ───────────────────────────────

-- Seconds the local clock is ahead of UTC (DST-aware for the current instant).
function M.tzOffset()
  local now = os.time()
  return os.difftime(now, os.time(os.date("!*t", now)))
end

-- Parse an ISO-8601 UTC string to a real epoch, or nil.
function M.resetEpoch(iso)
  if type(iso) ~= "string" or iso == "" then return nil end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  local asLocal = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  if not asLocal then return nil end
  return asLocal + M.tzOffset()
end

function M.formatCountdown(iso)
  local epoch = M.resetEpoch(iso)
  if not epoch then return nil end
  local secs = epoch - os.time()
  if secs <= 0 then return noctalia.tr("resetting") end
  local d = secs // 86400
  local h = (secs % 86400) // 3600
  local m = (secs % 3600) // 60
  if d > 0 then return `{d}d {h}h {m}m` end
  if h > 0 then return `{h}h {m}m` end
  return `{m}m`
end

-- Same countdown, narrowed for somewhere with a column to fit: once a window is
-- days out the minutes are noise, and the tooltip's value column is not wide
-- enough to spend eight characters on them.
function M.formatCountdownShort(iso)
  local epoch = M.resetEpoch(iso)
  if not epoch then return nil end
  local secs = epoch - os.time()
  if secs <= 0 then return noctalia.tr("resetting") end
  local d = secs // 86400
  if d > 0 then return `{d}d {(secs % 86400) // 3600}h` end
  local h = secs // 3600
  if h > 0 then return `{h}h {(secs % 3600) // 60}m` end
  return `{secs // 60}m`
end

-- 1-based index into the Mon..Sun daily arrays for today (Lua wday: Sun=1).
function M.todayIndex()
  local t = os.date("*t")
  return (t.wday == 1) and 7 or (t.wday - 1)
end

-- ── pacing (usage vs. time elapsed through the window) ─────────────────────
-- Are we burning quota faster than the clock? Windows are treated as fixed-length
-- and elapsed time is derived from the reset timestamp — an approximation of
-- Anthropic's rolling limits, good enough as a cue.

M.FIVE_HOUR_SECS = 5 * 3600
M.SEVEN_DAY_SECS = 7 * 86400
M.PACE_MARGIN = 5 -- % points around parity that still read as "on pace"

-- Severity ordering for "worst of several windows" decisions.
M.SEVERITY = { unknown = 0, under = 0, on = 0, over = 1, over_quota = 2 }

-- → { timeFrac?, delta?, status } ; status: over_quota | over | under | on | unknown
function M.pace(util, resetIso, durationSecs)
  util = tonumber(util) or 0
  local epoch = M.resetEpoch(resetIso)
  if not epoch then
    if util >= 100 then return { timeFrac = 1, delta = util, status = "over_quota" } end
    return { status = "unknown" }
  end
  local remaining = epoch - os.time()
  local timeFrac = (durationSecs - remaining) / durationSecs
  if timeFrac < 0 then timeFrac = 0 elseif timeFrac > 1 then timeFrac = 1 end
  local delta = util - timeFrac * 100
  local status
  if util >= 100 then status = "over_quota"
  elseif delta >= M.PACE_MARGIN then status = "over"
  elseif delta <= -M.PACE_MARGIN then status = "under"
  else status = "on" end
  return { timeFrac = timeFrac, delta = delta, status = status }
end

-- Human pace phrase, or nil when unknown.
function M.paceLabel(p)
  if p.status == "over_quota" then return noctalia.tr("pace.over_quota") end
  if p.status == "over" then return `{M.round(p.delta)}% {noctalia.tr("pace.over")}` end
  if p.status == "under" then return `{M.round(-p.delta)}% {noctalia.tr("pace.under")}` end
  if p.status == "on" then return noctalia.tr("pace.on") end
  return nil
end

-- Palette role for a pace status; `calm` is the color when on/under pace or unknown.
function M.paceColor(status, calm)
  if status == "over_quota" then return "error" end
  if status == "over" then return "tertiary" end
  return calm
end

-- ── rate windows ───────────────────────────────────────────────────────────
-- The API reports every window it enforces in `limits`: the 5-hour session, the
-- plan-wide week, and — on plans that scope one — a week for a single model
-- ("Fable"). Older payloads carry only the first two, as five_hour_* /
-- seven_day_*, so those are synthesized when `limits` is absent and the two
-- shapes reach a renderer identically.

M.SEVERITY_RANK = { normal = 0, high = 1, critical = 2 }

-- The vendor's own severity, mapped onto the pace vocabulary so one comparison
-- covers both. Anthropic calling a window "high" outranks our own arithmetic
-- saying it is merely over pace, and we never read calmer than the vendor does.
local function severityStatus(severity)
  if severity == "critical" then return "over_quota" end
  if severity == "high" then return "over" end
  return nil
end

local function windowLabel(row)
  local model = row.model
  if type(model) == "string" and model ~= "" then
    return noctalia.tr("window.scoped", { model = model })
  end
  if row.kind == "session" then return noctalia.tr("window.session") end
  if row.group == "weekly" then return noctalia.tr("window.weekly") end
  return noctalia.tr("window.other")
end

-- → { { id, label, percent, resetIso, durationSecs, isActive, pace, status }, … }
-- `status` is the worse of the pace reading and the vendor's severity, so it
-- feeds M.paceColor and M.SEVERITY exactly like a plain pace status does.
function M.windows(proj)
  if type(proj) ~= "table" then return {} end

  local rows = {}
  if type(proj.limits) == "table" and #proj.limits > 0 then
    for _, row in proj.limits do
      if type(row) == "table" then
        local secs = (row.kind == "session") and M.FIVE_HOUR_SECS or M.SEVEN_DAY_SECS
        table.insert(rows, {
          kind = row.kind, model = row.model, group = row.group,
          percent = tonumber(row.percent) or 0,
          resetIso = row.resets_at, durationSecs = secs,
          severity = row.severity, isActive = row.is_active == true,
        })
      end
    end
  else
    -- Legacy shape: the same two windows, without severity or an active flag.
    rows = {
      { kind = "session", group = "session", percent = tonumber(proj.five_hour_util) or 0,
        resetIso = proj.five_hour_reset, durationSecs = M.FIVE_HOUR_SECS, isActive = false },
      { kind = "weekly_all", group = "weekly", percent = tonumber(proj.seven_day_util) or 0,
        resetIso = proj.seven_day_reset, durationSecs = M.SEVEN_DAY_SECS, isActive = false },
    }
  end

  for i, row in rows do
    row.id = `{row.kind or "window"}:{row.model or ""}:{i}`
    row.label = windowLabel(row)
    row.pace = M.pace(row.percent, row.resetIso, row.durationSecs)
    local vendor = severityStatus(row.severity)
    if vendor and (M.SEVERITY[vendor] or 0) > (M.SEVERITY[row.pace.status] or 0) then
      row.status = vendor
    else
      row.status = row.pace.status
    end
  end
  return rows
end

-- The wall-clock time a window resets at, in the shell's own time format.
-- `withDay` prefixes the weekday for a reset more than a day out ("Sat 15:00");
-- without it the time stands alone, which is what a narrow column wants — the
-- countdown beside it already says how many days away that is. nil when the
-- stamp is unusable.
function M.formatResetClock(iso, withDay)
  local epoch = M.resetEpoch(iso)
  if not epoch then return nil end
  -- noctalia.timeFormat() is "{:%H:%M}" or "{:%I:%M %p}"; take the strftime part
  -- so a 12-hour shell reads 7:30 PM here too.
  local fmt = "%H:%M"
  local ok, shellFmt = pcall(noctalia.timeFormat)
  if ok and type(shellFmt) == "string" then
    local inner = shellFmt:match("{:(.-)}")
    if inner and inner ~= "" then fmt = inner end
  end
  if withDay and epoch - os.time() >= 86400 then return os.date(`%a {fmt}`, epoch) end
  return os.date(fmt, epoch)
end

-- ── profile projection ─────────────────────────────────────────────────────

function M.findProfile(usage, name)
  if type(usage) ~= "table" or type(usage.profile_data) ~= "table" then return nil end
  for _, p in usage.profile_data do
    if type(p) == "table" and p.name == name then return p end
  end
  return nil
end

-- Unify the "all" aggregate (top-level fields) and a single profile object into
-- one shape a renderer can read. nil when usage is missing or the profile is gone.
function M.projection(usage, selected)
  if type(usage) ~= "table" then return nil end
  if selected == nil or selected == "all" then
    return {
      subscription = usage.subscription_type, tier = usage.rate_limit_tier,
      five_hour_util = usage.five_hour_util, seven_day_util = usage.seven_day_util,
      five_hour_reset = usage.five_hour_reset, seven_day_reset = usage.seven_day_reset,
      limits = usage.limits,
      week_tokens = usage.week_tokens, month_tokens = usage.month_tokens,
      week_messages = usage.week_messages, week_sessions = usage.week_sessions,
      today_cost = usage.today_cost, week_cost = usage.week_cost, month_cost = usage.month_cost,
      daily = usage.daily, daily_costs = usage.daily_costs, week_models = usage.week_models,
      is_all = true,
    }
  end
  local p = M.findProfile(usage, selected)
  if not p then return nil end
  return {
    subscription = p.subscription, tier = p.tier,
    five_hour_util = p.five_hour_util, seven_day_util = p.seven_day_util,
    five_hour_reset = p.five_hour_reset, seven_day_reset = p.seven_day_reset,
    limits = p.limits,
    week_tokens = p.week_tokens, month_tokens = p.month_tokens,
    week_messages = p.week_messages, week_sessions = p.week_sessions,
    today_cost = p.today_cost, week_cost = p.week_cost, month_cost = p.month_cost,
    daily = p.daily, daily_costs = p.daily_costs, week_models = p.week_models,
    is_all = false,
  }
end

-- ["all", <profiles…>] — the cycle / tab order shared by panel and desktop widget.
function M.profileOrder(usage)
  local order = { "all" }
  if type(usage) == "table" and type(usage.profiles) == "table" then
    for _, name in usage.profiles do
      if type(name) == "string" and name ~= "" then table.insert(order, name) end
    end
  end
  return order
end

-- Sorted { {name, tokens}, … } from a week_models map, desc.
function M.modelList(weekModels)
  local list = {}
  if type(weekModels) ~= "table" then return list end
  for name, tok in weekModels do
    table.insert(list, { name = name, tokens = tonumber(tok) or 0 })
  end
  table.sort(list, function(a, b) return a.tokens > b.tokens end)
  return list
end

-- ── commands to the service ────────────────────────────────────────────────

-- Ask the service for an out-of-band fetch (it watches refresh_nonce).
function M.requestRefresh()
  local nonce = noctalia.state.get("refresh_nonce")
  noctalia.state.set("refresh_nonce", (tonumber(nonce) or 0) + 1)
end

return M
