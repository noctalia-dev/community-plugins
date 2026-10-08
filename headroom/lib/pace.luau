--!nonstrict
-- Pacing: where is this window heading by the time it resets?
--
-- A window that is 40% used but only 20% elapsed is on course to run out; one
-- that is 80% used with 10 minutes left is fine. Extrapolating the burn rate so
-- far turns a raw percentage into something you can act on: either "runs out
-- in 49m" or "≈ 56% by reset".

local M = {}

export type Pace = {
  elapsedFraction: number, -- 0..1 of the window that has passed
  status: string, -- "early" | "projected" | "runs_out" | "exhausted"
  projectedPercent: number?, -- usage at reset at the current rate ("projected")
  runsOutIn: number?, -- seconds until 100% at the current rate ("runs_out")
  lockoutSeconds: number?, -- time stuck at the limit before the reset ("runs_out")
  severity: string, -- "ok" | "warn" | "critical": how worrying the forecast is
}

-- Below this much elapsed time a projection is noise: usage is bursty (work
-- hours, nights, weekends), and one busy morning extrapolated across a week
-- predicts exhaustion that never comes. 15% is 45 minutes of a 5-hour window
-- and about a day of a weekly one.
local MIN_ELAPSED_FRACTION = 0.15
local MIN_ELAPSED_SECONDS = 15 * 60
-- Running out only matters when it costs real time: locked out for at least
-- this fraction of the window is a warning, not a footnote.
local LOCKOUT_WARN_FRACTION = 0.1

function M.compute(window, now: number): Pace?
  local period = window.periodSeconds
  local resetsAt = window.resetsAt
  if period == nil or resetsAt == nil or period <= 0 or resetsAt <= now then
    return nil -- no forecast for a window that has already reset
  end
  local remaining = math.clamp(resetsAt - now, 0, period)
  local elapsed = period - remaining
  local used = window.usedPercent

  local pace: Pace = {
    elapsedFraction = elapsed / period,
    status = "early",
    severity = "ok",
  }

  if used >= 100 or window.limitReached then
    pace.status = "exhausted"
    pace.severity = "critical"
    return pace
  end
  if pace.elapsedFraction < MIN_ELAPSED_FRACTION or elapsed < MIN_ELAPSED_SECONDS then
    return pace
  end

  local rate = used / elapsed -- percent per second
  if rate > 0 and used + rate * remaining >= 100 then
    pace.status = "runs_out"
    pace.runsOutIn = (100 - used) / rate
    pace.lockoutSeconds = remaining - pace.runsOutIn
    pace.severity = if pace.lockoutSeconds >= period * LOCKOUT_WARN_FRACTION then "warn" else "ok"
    return pace
  end

  pace.status = "projected"
  pace.projectedPercent = used + rate * remaining
  return pace
end

return M
