--!nonstrict
local layoutLib = require("./layout.luau")
local win = require("./windows.luau")
local M = {}

-- Edad máxima (ms) de un rectángulo impuesto para seguir suprimiéndolo.
M.IMPOSED_TTL_MS = 5000

local function thirdMargin(size)
  return size / 3
end

-- Ancla deducida del cuadrante del CENTRO de la ventana.
function M.anchorFromRect(rect, screen, margin)
  local centerX = rect.x + rect.w / 2
  local centerY = rect.y + rect.h / 2
  local column
  if centerX < screen.x + thirdMargin(screen.width) then
    column = "left"
  elseif centerX > screen.x + screen.width * 2 / 3 then
    column = "right"
  else
    column = "center"
  end
  local row
  if centerY < screen.y + thirdMargin(screen.height) then
    row = "top"
  elseif centerY > screen.y + screen.height * 2 / 3 then
    row = "bottom"
  else
    row = "center"
  end
  local anchor
  if row == "center" then
    if column == "center" then anchor = "center"
    elseif column == "left" then anchor = "left-center"
    else anchor = "right-center" end
  else
    anchor = row .. "-" .. column
  end
  local baseX, baseY = layoutLib.anchorPosition(anchor, rect.w, rect.h, screen.width, screen.height, margin)
  -- x/y relativos a la caja del output, igual que resolveGeometry().
  return {
    anchor = anchor,
    dx = math.floor((rect.x - screen.x) - baseX),
    dy = math.floor((rect.y - screen.y) - baseY),
    width = rect.w,
    height = rect.h,
  }
end

function M.layoutString(rect, screen, margin)
  local memory = M.anchorFromRect(rect, screen, margin)
  return string.format("%s, %dx%d, %d, %d", memory.anchor, memory.width, memory.height, memory.dx, memory.dy)
end

function M.geometryFromMemory(value, screenWidth, screenHeight, margin)
  local parsed = layoutLib.parseLayout(value)
  if parsed == nil or parsed.valid ~= true then return nil end
  if parsed.anchor == nil or parsed.auto == true or parsed.custom == true then return nil end
  local width = parsed.width
  local height = parsed.height
  if width == nil or height == nil then return nil end
  local baseX, baseY = layoutLib.anchorPosition(parsed.anchor, width, height, screenWidth, screenHeight, margin)
  return {
    x = baseX + (parsed.dx or 0),
    y = baseY + (parsed.dy or 0),
    width = width,
    height = height,
  }
end

local function sameRect(a, b)
  return a ~= nil and b ~= nil
    and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

-- Captura SOLO geometría manual (ver §5.4 del diseño): descarta lo que el
-- plugin impuso y exige dos sondeos consecutivos iguales.
function M.capture(clients, screen, margin, previous, imposed, pending)
  previous = previous or {}
  imposed = imposed or {}
  pending = pending or {}
  local now = noctalia.nowMs()
  local memory = {}
  local nextPending = {}
  local changed = false
  for _, client in ipairs(clients or {}) do
    if win.isPluginClass(client.class) and type(client.at) == "table" and type(client.size) == "table" then
      local rect = { x = client.at[1], y = client.at[2], w = client.size[1], h = client.size[2] }
      local stamp = imposed[client.class]
      local suppressed = stamp ~= nil
        and (now - (stamp.at or 0)) <= M.IMPOSED_TTL_MS
        and stamp.x == rect.x and stamp.y == rect.y and stamp.w == rect.w and stamp.h == rect.h
      if suppressed then
        -- La puso el plugin: no hay nada que memorizar y el pendiente se cancela.
        nextPending[client.class] = nil
      else
        if sameRect(pending[client.class], rect) then
          local value = M.layoutString(rect, screen, margin)
          if previous[client.class] ~= value then
            memory[client.class] = value
            changed = true
          end
        end
        nextPending[client.class] = rect
      end
    end
  end
  return { memory = memory, pending = nextPending, changed = changed }
end

return M