--!nonstrict
-- Caja (x, y, ancho, alto) del output donde vive el widget.
--
-- Una sola fuente de selección para el panel y el servicio: si cada uno
-- calculara la pantalla por su cuenta, un desplazamiento guardado por uno no
-- se reconstruiría igual en el otro.
--
-- Regla: `config.output` (si existe), si no el output enfocado, si no el
-- primero. Si no hay ningún output utilizable o la caja es diminuta
-- (< 320x240), se devuelve un respaldo de 1920x1080 en el origen.

local M = {}

local FALLBACK = { x = 0, y = 0, width = 1920, height = 1080, name = "" }
local MIN_WIDTH = 320
local MIN_HEIGHT = 240

local function fallbackBox()
  return {
    x = FALLBACK.x,
    y = FALLBACK.y,
    width = FALLBACK.width,
    height = FALLBACK.height,
    name = FALLBACK.name,
  }
end

-- Devuelve la caja del output elegido (tabla nueva, nunca la del mock).
function M.outputBox(config)
  local outputs = noctalia.outputs() or {}
  local wanted = tostring(config and config.output or "")
  local chosen = nil

  if wanted ~= "" then
    for _, output in ipairs(outputs) do
      if output.name == wanted then chosen = output break end
    end
  end

  if chosen == nil then
    for _, output in ipairs(outputs) do
      if output.focused == true then chosen = output break end
    end
  end

  if chosen == nil then chosen = outputs[1] end
  if chosen == nil then return fallbackBox() end

  local width = math.floor(tonumber(chosen.width) or 0)
  local height = math.floor(tonumber(chosen.height) or 0)
  if width < MIN_WIDTH or height < MIN_HEIGHT then
    return fallbackBox()
  end

  return {
    x = math.floor(tonumber(chosen.x) or 0),
    y = math.floor(tonumber(chosen.y) or 0),
    width = width,
    height = height,
    name = chosen.name or "",
  }
end

return M