--!nonstrict
-- The contract between the service (the only entry that fetches) and the
-- presentation entries (bar, panel). Each entry runs in its own Luau VM, so
-- they share data exclusively through these noctalia.state keys.

local M = {}

M.PANEL_ID = "ayagmar/headroom:panel"
M.VERSION = "0.1.0"

-- Published by the service:
--   {
--     lastRefreshAt: number?,      Unix seconds of the last completed fetch
--     providers: { ProviderView }, registry order, providers set to "off" left out
--   }
-- ProviderView:
--   { id, name, brand, hint,       hint: how to sign in, already translated
--     status: "loading" | "ok" | "error" | "absent",   absent = not signed in
--     snapshot: Snapshot?,         last good data, kept through errors
--     error: ProviderError?,       current failure, with `hint` filled in
--     stale: boolean,              snapshot is from the disk cache or predates an error
--     busy: boolean }              a fetch is in flight
M.REPORT = "report"

-- Written by bar/panel, watched by the service: { action = "refresh", at = ms }.
M.COMMAND = "command"

-- Asks the service for fresh data. `maxAge` (seconds) skips providers fetched
-- more recently than that; without it every provider is fetched.
function M.requestRefresh(maxAge: number?)
  noctalia.state.set(M.COMMAND, { action = "refresh", maxAge = maxAge, at = noctalia.nowMs() })
end

-- Where a provider appears (its "Providers ·" setting): "bar" (bar and panel),
-- "panel" (panel only) or "off" (never fetched, never shown).
function M.providerMode(id: string): string
  local mode = M.config(`provider_{id}`, "bar")
  return if mode == "panel" or mode == "off" then mode else "bar"
end

-- Reads a config value with a fallback for unset or mistyped values.
function M.config(key: string, fallback: any): any
  local value = noctalia.getConfig(key)
  if value == nil or type(value) ~= type(fallback) then
    return fallback
  end
  return value
end

function M.thresholds(): (number, number)
  local warn = M.config("warn_percent", 70)
  local critical = M.config("critical_percent", 90)
  return math.min(warn, critical), critical
end

return M
