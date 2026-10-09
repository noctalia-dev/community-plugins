--!nonstrict
-- The normalized data model every provider adapter produces and every surface
-- consumes. Providers translate vendor JSON into these shapes; the bar and panel
-- never see a vendor field. Keep this file the single definition of the schema.

local M = {}

-- The two window lengths every vendor so far uses; pacing needs them.
M.SESSION_SECONDS = 5 * 3600
M.WEEK_SECONDS = 7 * 86400

-- One rate-limit window, e.g. "5-hour session" or "weekly, all models".
export type Window = {
  id: string, -- stable within its provider ("session", "weekly", "weekly:Opus")
  kind: string, -- "session" | "weekly" | "model" | "other"; drives bar selection
  label: string, -- human, already translated
  usedPercent: number, -- 0..100 (clamped)
  resetsAt: number?, -- Unix seconds
  periodSeconds: number?, -- window length; enables pacing
  limitReached: boolean?,
}

-- A secondary fact shown under the windows: credits, extra usage, ...
export type Note = {
  label: string,
  value: string,
}

export type Snapshot = {
  plan: string?,
  windows: { Window },
  notes: { Note },
  fetchedAt: number, -- Unix seconds
}

-- Error codes the surfaces know how to explain. Anything a provider reports is
-- mapped onto one of these so the UI can offer the right recovery hint.
M.ErrorCode = {
  NotConfigured = "not_configured", -- no credentials on disk
  Expired = "expired", -- credentials present but the token has expired
  Auth = "auth", -- the vendor rejected the credentials (401/403)
  RateLimited = "rate_limited", -- the usage endpoint itself throttled us (429)
  NoPlan = "no_plan", -- signed in, but the account's plan has no quota for this product
  Network = "network", -- transport failure / offline
  Server = "server", -- 5xx or unexpected status
  Parse = "parse", -- response did not match the expected shape
}

export type ProviderError = {
  code: string,
  detail: string?, -- short technical detail for the tooltip, never a secret
  hint: string?, -- recovery hint, filled in by the service from the provider
}

function M.err(code: string, detail: string?): ProviderError
  return { code = code, detail = detail }
end

local function clampPercent(value: any): number
  local n = tonumber(value) or 0
  if n ~= n then -- NaN
    return 0
  end
  return math.clamp(n, 0, 100)
end

function M.window(fields): Window
  return {
    id = tostring(fields.id),
    kind = fields.kind or "other",
    label = fields.label or tostring(fields.id),
    usedPercent = clampPercent(fields.usedPercent),
    resetsAt = fields.resetsAt,
    periodSeconds = fields.periodSeconds,
    limitReached = fields.limitReached == true or clampPercent(fields.usedPercent) >= 100,
  }
end

function M.snapshot(fields): Snapshot
  return {
    plan = fields.plan,
    windows = fields.windows or {},
    notes = fields.notes or {},
    fetchedAt = fields.fetchedAt,
  }
end

-- The window closest to its limit. Ties prefer the one that resets later,
-- since that is the one that will stay painful for longer.
function M.tightest(windows: { Window }): Window?
  local best = nil
  for _, w in windows do
    if best == nil
      or w.usedPercent > best.usedPercent
      or (w.usedPercent == best.usedPercent and (w.resetsAt or 0) > (best.resetsAt or 0))
    then
      best = w
    end
  end
  return best
end

-- Picks the window a compact surface should show for a provider.
-- preference: "tightest" | "session" | "weekly".
function M.pick(windows: { Window }, preference: string?): Window?
  if preference == "session" or preference == "weekly" then
    for _, w in windows do
      if w.kind == preference then
        return w
      end
    end
  end
  return M.tightest(windows)
end

-- "ok" | "warn" | "critical" for a usage percentage.
function M.severity(percent: number, warnAt: number, criticalAt: number): string
  if percent >= criticalAt then
    return "critical"
  elseif percent >= warnAt then
    return "warn"
  end
  return "ok"
end

return M
