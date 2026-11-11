--!nonstrict
-- Severity colors, and the ring gauge as a glyph.

local M = {}

-- Material palettes have an error role but no warning role, and `tertiary`
-- is often blue or pink, which does not read as "careful". So warning is a
-- fixed amber, tuned for contrast against dark and light surfaces.
local WARN_DARK = "#f2b84b"
local WARN_LIGHT = "#a86400"

-- Color for a severity, or nil for "ok" (callers use the theme's primary or
-- the default text color).
function M.severityColor(severity: string): string?
  if severity == "critical" then
    return "error"
  elseif severity == "warn" then
    return if noctalia.isDarkMode() then WARN_DARK else WARN_LIGHT
  end
  return nil
end

-- Meter color at a severity. Healthy meters use the theme's primary, not a
-- vendor color: brand oranges and greens sit too close to warning amber and
-- error red, and the logo already says whose meter it is.
function M.meterColor(severity: string): string
  return M.severityColor(severity) or "primary"
end

-- The steps Tabler's percentage-N glyphs come in.
local RING_STEPS = { 0, 10, 20, 25, 30, 33, 40, 50, 60, 66, 70, 75, 80, 90, 100 }

-- The glyph closest to `percent`. As with view.roundPercent, a real
-- difference never rounds to an empty or a full ring.
function M.ring(percent: number): string
  local best = 0
  for _, step in RING_STEPS do
    if math.abs(step - percent) < math.abs(best - percent) then
      best = step
    end
  end
  if percent > 0 and best == 0 then
    best = 10
  elseif percent < 100 and best == 100 then
    best = 90
  end
  return `percentage-{best}`
end

return M
