--!nonstrict
-- The layout of the screens, as plain data that the service and the panel share. A screen
-- is known by its id: its make, model and serial, never its connector (DESIGN.md, 10.9).

local Layout = {}

-- What a layout remembers of each screen; the rest comes from the screen itself.
Layout.FIELDS = { "mode", "x", "y", "scale", "transform", "enabled", "vrr", "hdr", "sdrBrightness", "mirror", "workspaces", "tenBit" }

-- Changes that can leave a screen dark wait to be kept.
local RISKY = { mode = true, enabled = true, mirror = true, hdr = true, vrr = true }

local SCALES = { 1, 1.2, 1.25, 4 / 3, 1.5, 1.6, 5 / 3, 1.75, 2, 2.4, 2.5, 3 }

function Layout.copy(screens)
  local copy = {}
  for _, screen in ipairs(screens) do
    local item = {}
    for key, value in pairs(screen) do
      item[key] = value
    end
    table.insert(copy, item)
  end
  return copy
end

function Layout.find(screens, id)
  for _, screen in ipairs(screens) do
    if screen.id == id then
      return screen
    end
  end
  return nil
end

-- The set of screens connected now, as one key.
function Layout.key(screens)
  local ids = {}
  for _, screen in ipairs(screens) do
    table.insert(ids, screen.id)
  end
  table.sort(ids)
  return table.concat(ids, "\n")
end

-- What the screens look like, to notice when something else changes them.
function Layout.signature(screens)
  local parts = {}
  for _, screen in ipairs(screens) do
    table.insert(parts, table.concat({ screen.id, screen.mode, screen.x, screen.y, screen.scale, screen.transform,
      tostring(screen.enabled), screen.vrr, tostring(screen.hdr), screen.mirror }, "|"))
  end
  table.sort(parts)
  return table.concat(parts, "\n")
end

-- The pixel size of a mode such as "1920x1080@60.00".
function Layout.pixels(mode)
  local width, height = (mode or ""):match("^(%d+)x(%d+)")
  return tonumber(width) or 0, tonumber(height) or 0
end

-- The screen's size in the layout, after its rotation and scale.
function Layout.size(screen)
  local width, height = Layout.pixels(screen.mode)
  if screen.transform % 2 == 1 then
    width, height = height, width
  end
  local scale = tonumber(screen.scale) or 1
  return math.floor(width / scale + 0.5), math.floor(height / scale + 0.5)
end

-- Whether the screen takes a place of its own: it is on and mirrors no other screen.
function Layout.placed(screen)
  return screen.enabled and (screen.mirror or "") == ""
end

-- Moves the screens so the layout starts at 0,0.
function Layout.normalize(screens)
  local minX, minY = math.huge, math.huge
  for _, screen in ipairs(screens) do
    if Layout.placed(screen) then
      minX, minY = math.min(minX, screen.x), math.min(minY, screen.y)
    end
  end
  if minX == math.huge then
    return
  end
  for _, screen in ipairs(screens) do
    screen.x -= minX
    screen.y -= minY
  end
end

-- Puts screen <id> on <edge> ("left" | "right" | "above" | "below") of screen <target>,
-- lined up at <align> ("start" | "middle" | "end") of that edge.
function Layout.place(screens, id, target, edge, align)
  local screen, other = Layout.find(screens, id), Layout.find(screens, target)
  if not screen or not other or screen == other then
    return false
  end
  local width, height = Layout.size(screen)
  local otherWidth, otherHeight = Layout.size(other)
  local function along(start, length, own)
    if align == "middle" then
      return start + math.floor((length - own) / 2)
    elseif align == "end" then
      return start + length - own
    end
    return start
  end
  if edge == "left" or edge == "right" then
    screen.x = edge == "left" and other.x - width or other.x + otherWidth
    screen.y = along(other.y, otherHeight, height)
  else
    screen.y = edge == "above" and other.y - height or other.y + otherHeight
    screen.x = along(other.x, otherWidth, width)
  end
  screen.mirror = ""
  Layout.normalize(screens)
  return true
end

-- Scales that give the screen whole pixels, with its own.
function Layout.scales(screen)
  local width, height = Layout.pixels(screen.mode)
  local list, seen = {}, false
  for _, scale in ipairs(SCALES) do
    local w, h = width / scale, height / scale
    if math.abs(w - math.floor(w + 0.5)) < 0.01 and math.abs(h - math.floor(h + 0.5)) < 0.01 then
      table.insert(list, scale)
      seen = seen or math.abs(scale - screen.scale) < 0.001
    end
  end
  if not seen then
    table.insert(list, screen.scale)
    table.sort(list)
  end
  return list
end

-- Whether the change of <field> can leave a screen dark.
function Layout.risky(field)
  return RISKY[field] == true
end

-- How many screens are on.
function Layout.enabledCount(screens)
  local count = 0
  for _, screen in ipairs(screens) do
    if screen.enabled then
      count += 1
    end
  end
  return count
end

return Layout
