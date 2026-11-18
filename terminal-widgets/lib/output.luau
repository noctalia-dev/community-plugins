--!nonstrict
-- Box (x, y, width, height) of the output where the widget lives.
--
-- A single selection source for the panel and the service: if each one
-- computed the screen on its own, an offset saved by one would not be
-- reconstructed the same way by the other.
--
-- Rule: `config.output` (if present), otherwise the focused output, otherwise
-- the first one. If there is no usable output or the box is tiny
-- (< 320x240), a 1920x1080 fallback at the origin is returned.

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

-- Return the chosen output's box (new table, never the mock's).
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