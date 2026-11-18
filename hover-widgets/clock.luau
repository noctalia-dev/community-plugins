--!nonstrict
-- Compact clock capsule; hovering animates open into the full weekday/ordinal-day/month.

local progress = 0.0 -- 0 = compact, 1 = fully expanded
local target = 0.0
local hovering = false

-- 0.16 @ 16ms decays at the same rate as the old 0.3 @ 33ms (same overall
-- open/close duration), just sampled twice as often so the steps are smaller.
local EASE = 0.16 -- lerp factor applied per animation tick
local ANIM_INTERVAL = 16 -- ms (~60fps, the host's floor) while progress is moving
local IDLE_INTERVAL = 1000 -- ms once settled

-- Remaps global progress into a field's own [start, end] window so fields
-- don't all grow in lockstep -- staggering the start/finish makes the reveal
-- read as a left-to-right ripple instead of one blocky jump every frame.
local function remap(t: number, a: number, b: number): number
  if t <= a then
    return 0
  elseif t >= b then
    return 1
  end
  return (t - a) / (b - a)
end

local function ordinalSuffix(day: number): string
  local rem100 = day % 100
  if rem100 < 11 or rem100 > 13 then
    local rem10 = day % 10
    if rem10 == 1 then
      return "st"
    elseif rem10 == 2 then
      return "nd"
    elseif rem10 == 3 then
      return "rd"
    end
  end
  return "th"
end

-- English abbreviations are always exact prefixes of the full name
-- ("Thu" -> "Thursday", "Jul" -> "July"), so revealing extra characters
-- reads as the word growing rather than being swapped out.
local function grow(short: string, full: string, t: number): string
  local shortLen = utf8.len(short) or #short
  local fullLen = utf8.len(full) or #full
  local len = shortLen + math.floor((fullLen - shortLen) * t + 0.5)
  local stop = utf8.offset(full, len + 1)
  return stop and full:sub(1, stop - 1) or full
end

local function render()
  local day = tonumber(noctalia.formatTime("%-d")) or 0
  local weekdayShort = noctalia.formatTime("%a")
  local weekdayFull = noctalia.formatTime("%A")
  local monthShort = noctalia.formatTime("%b")
  local monthFull = noctalia.formatTime("%B")
  local timeStr = noctalia.formatTime(hovering and "%-I:%M:%S" or "%-I:%M")
  local ampm = string.lower(noctalia.formatTime("%p"))

  local weekdayT = remap(progress, 0.0, 0.55)
  local dayT = remap(progress, 0.15, 0.75)
  local monthT = remap(progress, 0.35, 1.0)

  local suffix = ordinalSuffix(day)
  local suffixLen = math.floor(#suffix * dayT + 0.5)

  local weekdayText = grow(weekdayShort, weekdayFull, weekdayT)
  local monthText = grow(monthShort, monthFull, monthT)
  local dayText = tostring(day) .. suffix:sub(1, suffixLen)

  barWidget.setText(`{weekdayText} {dayText} {monthText} {timeStr} {ampm}`)
end

local function step()
  if math.abs(progress - target) < 0.01 then
    progress = target
    noctalia.setUpdateInterval(IDLE_INTERVAL)
  else
    progress = progress + (target - progress) * EASE
    noctalia.setUpdateInterval(ANIM_INTERVAL)
  end
  render()
end

function update()
  step()
end

function onHover(isHovering: boolean)
  hovering = isHovering
  target = isHovering and 1.0 or 0.0
  step()
end
