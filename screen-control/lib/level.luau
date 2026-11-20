--!nonstrict
-- One scale for each monitor, from 0 to 1, shared by scrolling and IPC. The low part dims
-- the screen below its lowest brightness; the rest is the brightness. The panel shows the
-- two parts as two sliders.
--
--   0 ─────── DIM_SPAN ──────────────────── 1
--   darkest dim   lowest brightness   full brightness

local Level = {}

local DIM_SPAN = 0.25

Level.STEP = 0.05

function Level.maxDim()
  return (noctalia.getConfig("max_dim") or 75) / 100
end

-- The lowest brightness: Noctalia's own minimum, but never 0, which turns some backlights off.
function Level.minBrightness()
  return math.max(noctalia.getSetting("brightness.minimum_brightness") or 0, 0.01)
end

-- A monitor with no brightness control uses the whole scale for dimming.
function Level.fromScreen(brightness, dim)
  local maxDim = Level.maxDim()
  if brightness == nil then
    return 1 - math.clamp(dim / maxDim, 0, 1)
  end
  if dim > 0 then
    return DIM_SPAN * (1 - math.clamp(dim / maxDim, 0, 1))
  end
  local low = Level.minBrightness()
  local share = math.clamp((brightness - low) / (1 - low), 0, 1)
  return DIM_SPAN + share * (1 - DIM_SPAN)
end

-- Returns the brightness (nil for no control) and the dim for a point on the scale.
function Level.toScreen(level, hasBrightness)
  level = math.clamp(level, 0, 1)
  local maxDim = Level.maxDim()
  if not hasBrightness then
    return nil, maxDim * (1 - level)
  end
  local low = Level.minBrightness()
  if level < DIM_SPAN then
    return low, maxDim * (1 - level / DIM_SPAN)
  end
  return low + (level - DIM_SPAN) / (1 - DIM_SPAN) * (1 - low), 0
end

-- Where a brightness sits between the lowest and full brightness, from 0 to 1.
function Level.share(brightness)
  local low = Level.minBrightness()
  return math.clamp((brightness - low) / (1 - low), 0, 1)
end

-- The brightness for a point between the lowest and full brightness.
function Level.fromShare(share)
  local low = Level.minBrightness()
  return low + math.clamp(share, 0, 1) * (1 - low)
end

-- The lowest point a step can reach: the lowest brightness, so scrolling and keys never
-- start dimming by accident, unless the setting allows it. A monitor without brightness
-- control has only dimming, so it steps across the whole scale.
function Level.stepFloor(hasBrightness)
  if not hasBrightness or noctalia.getConfig("step_dims") == true then
    return 0
  end
  return DIM_SPAN
end

-- "54%", or "Dim 30%".
function Level.text(brightness, dim)
  if dim > 0.005 then
    return noctalia.tr("level.dim", { percent = math.floor(dim * 100 + 0.5) })
  end
  return `{math.floor((brightness or 1) * 100 + 0.5)}%`
end

return Level
