-- lib/exclusion.luau — applications that must never be tracked.
--
-- What Did I Do runs inside the Noctalia shell itself, so the shell and its
-- surfaces are not "user activity". Exclusion happens at the tracking layer,
-- BEFORE any session is created, so shell time can never reach sessions,
-- aggregation, storage or the UI — there is intentionally no display-side
-- filter to undo it later.
--
-- Policy: EXACT identifier matches only. A hypothetical user application
-- named "nocturnal-notes" or "my-noctalia-theme" must still be tracked, so
-- substring matching on "noctalia" is deliberately not used.
--
-- Identifiers verified against live Hyprland metadata (hyprctl -j):
--   * toplevel windows of the shell report class/initialClass
--     "dev.noctalia.Noctalia"
--   * shell layer surfaces (bar, dock, wallpaper, panels, launcher, desktop
--     widgets) use layer-shell namespaces prefixed "noctalia-" — those never
--     become `activewindow` toplevels at all (the compositor reports
--     "Invalid"), so the provider already yields nil for them; the prefix is
--     listed here only as documentation of the surface taxonomy.

local M = {}

-- Exact application ids that belong to the Noctalia shell itself.
M.EXCLUDED_IDS = {
  ["dev.noctalia.Noctalia"] = true,
}

-- isExcludedApplication(app) -> boolean
--
-- `app` may be a provider sample ({ appId, appName, title, initialClass }) or
-- a stored session ({ appId, ... }); only identifier fields are read.
function M.isExcludedApplication(app)
  if type(app) ~= "table" then
    return false
  end
  if app.appId ~= nil and M.EXCLUDED_IDS[app.appId] then
    return true
  end
  if app.initialClass ~= nil and M.EXCLUDED_IDS[app.initialClass] then
    return true
  end
  return false
end

return M
