--!nonstrict
-- Positions y tamaños de las ventanas flotantes.
--
-- Cada widget puede tener su propia entrada en el ajuste `layouts`:
--   cava      = bottom-center, 1610x584
--   unimatrix = right-center, 869x1424
--   lavat     = bottom-left, 802x582, 0, -24   (desplazamiento desde el ancla)
--   pipes     = custom, 900x520, 120, 140      (coordenadas absolutas)
--   btop      = x=120 y=140 w=900 h=520

local util = require("./util.luau")

local M = {}

-- Anclas aceptadas. Se normalizan espacios, guiones y guiones bajos.
M.ANCHORS = {
  ["top-left"] = true,
  ["top-center"] = true,
  ["top-right"] = true,
  ["left-center"] = true,
  ["center"] = true,
  ["right-center"] = true,
  ["bottom-left"] = true,
  ["bottom-center"] = true,
  ["bottom-right"] = true,
}

M.ANCHOR_ALIASES = {
  ["topleft"] = "top-left",
  ["topcenter"] = "top-center",
  ["topright"] = "top-right",
  ["left"] = "left-center",
  ["leftcenter"] = "left-center",
  ["middle"] = "center",
  ["centre"] = "center",
  ["centro"] = "center",
  ["medio"] = "center",
  ["right"] = "right-center",
  ["rightcenter"] = "right-center",
  ["bottomleft"] = "bottom-left",
  ["bottomcenter"] = "bottom-center",
  ["bottomright"] = "bottom-right",
  ["top"] = "top-center",
  ["bottom"] = "bottom-center",
  ["arriba"] = "top-center",
  ["abajo"] = "bottom-center",
  ["izquierda"] = "left-center",
  ["derecha"] = "right-center",
  ["arriba-izquierda"] = "top-left",
  ["arriba-centro"] = "top-center",
  ["arriba-derecha"] = "top-right",
  ["izquierda-centro"] = "left-center",
  ["derecha-centro"] = "right-center",
  ["abajo-izquierda"] = "bottom-left",
  ["abajo-centro"] = "bottom-center",
  ["abajo-derecha"] = "bottom-right",
}

function M.normalizeAnchor(token)
  local key = util.trim(token):lower()
  key = key:gsub("%s+", "-"):gsub("_", "-")
  key = key:gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if M.ANCHORS[key] then
    return key
  end
  return M.ANCHOR_ALIASES[key]
end

-- Formatos admitidos:
--   bottom-center
--   bottom-center, 1610x584
--   right-center 869x1424
--   bottom-left, 802x582, 0, -24      (desplazamiento desde el ancla)
--   custom, 900x520, 120, 140         (coordenadas absolutas del monitor)
--   x=120 y=140 w=900 h=520
--   120,140 900x520
function M.parseLayout(value)
  if type(value) ~= "string" then
    return nil
  end
  local raw = util.trim(value)
  if raw == "" then
    return nil
  end
  raw = raw:gsub("×", "x")

  local spec = { dx = 0, dy = 0, valid = true }

  -- Formato explícito con clave=valor.
  local kv = {}
  for key, number in raw:gmatch("([%a_]+)%s*=%s*(-?%d+)") do
    kv[key:lower()] = tonumber(number)
  end
  if kv.x ~= nil or kv.y ~= nil or kv.w ~= nil or kv.h ~= nil then
    if kv.x == nil or kv.y == nil then
      return { valid = false }
    end
    spec.custom = true
    spec.dx = kv.x
    spec.dy = kv.y
    spec.width = kv.w
    spec.height = kv.h
    return spec
  end

  local width, height = raw:match("(%d+)%s*[xX]%s*(%d+)")
  if width ~= nil then
    spec.width = tonumber(width)
    spec.height = tonumber(height)
  end

  -- Quita el tamaño para quedarnos con ancla y desplazamientos.
  local cleaned = raw:gsub("%d+%s*[xX]%s*%d+", " ")
  local numbers = {}

  for token in cleaned:gmatch("[^,%s]+") do
    local lower = token:lower()
    local anchor = M.normalizeAnchor(token)
    if anchor ~= nil then
      if spec.anchor ~= nil then
        return { valid = false }
      end
      spec.anchor = anchor
    elseif lower == "auto" or lower == "libre" or lower == "free" then
      spec.auto = true
    elseif lower == "custom" or lower == "absolute" or lower == "abs" or lower == "at" then
      spec.custom = true
    else
      local number = tonumber(token)
      if number == nil then
        return { valid = false }
      end
      table.insert(numbers, number)
    end
  end

  if spec.auto then
    -- "auto" busca un hueco libre; opcionalmente "auto, 900x520".
    spec.anchor = "center"
  elseif spec.custom then
    if #numbers < 2 then
      return { valid = false }
    end
    spec.dx = numbers[1]
    spec.dy = numbers[2]
  elseif spec.anchor ~= nil then
    if #numbers >= 2 then
      spec.dx = numbers[1]
      spec.dy = numbers[2]
    elseif #numbers == 1 then
      spec.dx = numbers[1]
    end
  elseif #numbers >= 2 then
    -- "120, 140" sin ancla: coordenadas absolutas.
    spec.custom = true
    spec.dx = numbers[1]
    spec.dy = numbers[2]
  elseif spec.width ~= nil then
    spec.anchor = "center"
  else
    return { valid = false }
  end

  return spec
end

-- Permutación para la rotación "opposite": cada ventana va al sitio de la
-- que está en el lado opuesto del grupo, midiendo la oposición por la posición
-- real de los centros (no por un centro global de monitor). Así funciona para
-- cualquier disposición, incluso si las cuatro ventanas están en una sola zona.
function M.oppositePairs(windows)
  local count = #windows
  local result = {}
  for index = 1, count do
    result[index] = index
  end
  if count < 2 then
    return result
  end

  -- Centro del grupo.
  local cx = 0
  local cy = 0
  local centers = {}
  for index, window in ipairs(windows) do
    local x = (window.x or 0) + (window.w or 0) / 2
    local y = (window.y or 0) + (window.h or 0) / 2
    centers[index] = { x = x, y = y }
    cx = cx + x
    cy = cy + y
  end
  cx = cx / count
  cy = cy / count

  -- Extensión del grupo (para normalizar).
  local extentX = 0
  local extentY = 0
  for index = 1, count do
    extentX = math.max(extentX, math.abs(centers[index].x - cx))
    extentY = math.max(extentY, math.abs(centers[index].y - cy))
  end
  if extentX == 0 then
    extentX = 1
  end
  if extentY == 0 then
    extentY = 1
  end

  -- Candidatos de emparejamiento ordenados por cuán opuestos son sus
  -- vectores desde el centro del grupo (suma cercana a cero en ambos ejes).
  local pairsList = {}
  for i = 1, count do
    for j = i + 1, count do
      local ax = (centers[i].x - cx) / extentX
      local ay = (centers[i].y - cy) / extentY
      local bx = (centers[j].x - cx) / extentX
      local by = (centers[j].y - cy) / extentY
      local score = (ax + bx) ^ 2 + (ay + by) ^ 2
      table.insert(pairsList, { i = i, j = j, score = score })
    end
  end
  table.sort(pairsList, function(a, b)
    return a.score < b.score
  end)

  local paired = {}
  for _, candidate in ipairs(pairsList) do
    if paired[candidate.i] == nil and paired[candidate.j] == nil then
      paired[candidate.i] = candidate.j
      paired[candidate.j] = candidate.i
    end
  end
  for index = 1, count do
    if paired[index] == nil then
      paired[index] = index
    end
  end

  for index = 1, count do
    result[index] = paired[index]
  end
  return result
end

function M.anchorPosition(anchor, width, height, screenWidth, screenHeight, margin)
  margin = math.max(0, math.floor(margin or 0))
  local x
  local y

  if anchor == "top-left" or anchor == "left-center" or anchor == "bottom-left" then
    x = margin
  elseif anchor == "top-right" or anchor == "right-center" or anchor == "bottom-right" then
    x = screenWidth - width - margin
  else
    x = math.floor((screenWidth - width) / 2)
  end

  if anchor == "top-left" or anchor == "top-center" or anchor == "top-right" then
    y = margin
  elseif anchor == "bottom-left" or anchor == "bottom-center" or anchor == "bottom-right" then
    y = screenHeight - height - margin
  else
    y = math.floor((screenHeight - height) / 2)
  end

  return x, y
end

return M
