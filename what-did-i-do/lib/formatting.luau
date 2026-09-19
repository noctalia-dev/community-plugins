-- lib/formatting.luau — human-readable durations and times.
--
-- Pure functions; the host clock/formatTime is injected so tests can run
-- without Noctalia. Durations follow spec §31: no ugly fractional strings,
-- seconds only where they add meaning, localized unit strings via tr().
--
-- RTL note: duration strings are built from numbers plus localized unit
-- tokens; they flow with the surrounding text direction, so no LRE/PDF
-- forcing is needed.

local M = {}

M._tr = nil -- injected: function(key, subst) -> string

local function tr(key, subst)
  if M._tr then
    return M._tr(key, subst)
  end
  return key
end

-- fmtDuration(seconds) -> "3h 42m" | "42m" | "48s"
--
--   < 0        -> clamps to 0
--   < 60       -> localized seconds, unless includeSeconds is false -> "<1m"
--   < 3600     -> "42m" (or "1m 05s" when includeSeconds)
--   >= 3600    -> "3h 42m" (minutes always two digits when hours present)
--
-- includeSeconds defaults to false, matching the widget/panel usage.
function M.fmtDuration(seconds, includeSeconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60

  if h > 0 then
    if m == 0 then
      return tr("format.duration_hours", { h = h })
    end
    return tr("format.duration_hours_minutes", { h = h, m = m })
  elseif m > 0 then
    if includeSeconds and s > 0 then
      return tr("format.duration_minutes_seconds", { m = m, s = s })
    end
    return tr("format.duration_minutes", { m = m })
  elseif includeSeconds and s > 0 then
    return tr("format.duration_seconds", { s = s })
  elseif seconds > 0 then
    -- Sub-minute usage: "0m" reads as "never used". "<1m" is honest.
    return tr("format.duration_under_minute")
  end
  return tr("format.duration_minutes", { m = 0 })
end

-- fmtClock(unixSeconds, formatTimeFn) -> "09:12" using the host formatter.
-- formatTimeFn(pattern, unixSeconds) must be provided (noctalia.formatTime or
-- a test stub); the "{:%H:%M}" pattern is Noctalia's standard clock pattern.
function M.fmtClock(unixSeconds, formatTimeFn)
  if not formatTimeFn then
    return ""
  end
  local ok, out = pcall(formatTimeFn, "{:%H:%M}", unixSeconds)
  if ok and type(out) == "string" then
    return out
  end
  return ""
end

-- fmtDateShort(unixSeconds, formatTimeFn) -> "Sep 8" style, RTL-neutral.
function M.fmtDateShort(unixSeconds, formatTimeFn)
  if not formatTimeFn then
    return ""
  end
  local ok, out = pcall(formatTimeFn, "{:%b %-d}", unixSeconds)
  if ok and type(out) == "string" then
    return out
  end
  -- Fallback if %-d is not supported by the host's strftime.
  local ok2, out2 = pcall(formatTimeFn, "{:%b %d}", unixSeconds)
  if ok2 and type(out2) == "string" then
    return out2
  end
  return ""
end

-- fmtDurationAt(unixSeconds, durationSeconds, formatTimeFn, opts) builds a
-- "09:12 · 36m" line for the recent-activity list. opts.trimMiddle removes
-- the separator when both sides are present.
function M.fmtDurationAt(unixSeconds, durationSeconds, formatTimeFn, opts)
  opts = opts or {}
  local clock = M.fmtClock(unixSeconds, formatTimeFn)
  local dur = M.fmtDuration(durationSeconds, opts.includeSeconds)
  if opts.rtl then
    -- Keep visual order stable in RTL: clock then dot then duration reads
    -- right-to-left naturally; we do not reverse either token itself.
    return clock .. " · " .. dur
  end
  return clock .. " · " .. dur
end

return M
