-- Helpers for search-by-color filtering in wallpaper-deck.

local M = {}

local function rgbToHls(r, g, b)
  local maxc = math.max(r, g, b)
  local minc = math.min(r, g, b)
  local l = (maxc + minc) / 2
  if maxc == minc then
    return 0, l, 0
  end
  local d = maxc - minc
  local s = (l > 0.5) and (d / (2 - maxc - minc)) or (d / (maxc + minc))
  local h
  if maxc == r then
    h = (g - b) / d
    if g < b then h = h + 6 end
  elseif maxc == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  h = h / 6
  return h, l, s
end

local function hexToRgb(hex)
  if not hex or type(hex) ~= "string" then return nil end
  local clean = (string.byte(hex, 1) == 35) and string.sub(hex, 2) or hex
  if #clean == 8 then clean = string.sub(clean, 1, 6) end
  if #clean ~= 6 then return nil end
  local r = tonumber(string.sub(clean, 1, 2), 16)
  local g = tonumber(string.sub(clean, 3, 4), 16)
  local b = tonumber(string.sub(clean, 5, 6), 16)
  if not r or not g or not b then return nil end
  return r, g, b
end

function M.colorToHueKey(hex)
  local r, g, b = hexToRgb(hex)
  if not r then return nil end
  r, g, b = r / 255, g / 255, b / 255
  local h, l, s = rgbToHls(r, g, b)
  local hexLower = string.lower(hex or "")
  if s < 0.12 or hexLower == "#4285f4" or hexLower == "#000000" or hexLower == "#ffffff" then
    return 1.0 + l
  end
  return (h + 0.035) % 1.0
end

local HUE_THRESHOLD = 0.08

local function hueClose(a, b)
  if type(a) ~= "number" or type(b) ~= "number" then return false end
  -- hueKey values in [1,2] represent grayscale/desaturated colors (1 + lightness);
  -- they must not be wrapped against chromatic hues in [0,1].
  if a > 1 or b > 1 then
    return math.abs(a - b) <= HUE_THRESHOLD
  end
  local diff = math.abs(a - b)
  if diff > 0.5 then diff = 1 - diff end
  return diff <= HUE_THRESHOLD
end

-- Returns priority 0=primary, 1=secondary, 2=tertiary, 3=container, 4=surface, or nil if no match.
-- Memoizes computed hue keys back onto the item table so repeated calls are O(1).
function M.matchPriority(item, targetHue)
  if targetHue == nil or not item then return nil end
  local c = item.colors
  if type(c) ~= "table" then return nil end

  -- NOTE: item.hueKey is derived from source_color (used by sort-by-colour), so
  -- it must NOT be used for matching the primary palette entry.
  local primaryHue = item.hueKeyPrimary
  if type(primaryHue) ~= "number" then
    primaryHue = M.colorToHueKey(c.primary)
    if primaryHue then item.hueKeyPrimary = primaryHue end
  end
  if hueClose(primaryHue, targetHue) then return 0 end

  local secHue = item.hueKeySecondary
  if type(secHue) ~= "number" then
    secHue = M.colorToHueKey(c.secondary)
    if secHue then item.hueKeySecondary = secHue end
  end
  if hueClose(secHue, targetHue) then return 1 end

  local terHue = item.hueKeyTertiary
  if type(terHue) ~= "number" then
    terHue = M.colorToHueKey(c.tertiary or c.secondary)
    if terHue then item.hueKeyTertiary = terHue end
  end
  if hueClose(terHue, targetHue) then return 2 end

  local contHue = item.hueKeyContainer
  if type(contHue) ~= "number" then
    contHue = M.colorToHueKey(c.primary_container)
    if contHue then item.hueKeyContainer = contHue end
  end
  if hueClose(contHue, targetHue) then return 3 end

  local surfHue = item.hueKeySurface
  if type(surfHue) ~= "number" then
    surfHue = M.colorToHueKey(c.surface_container_highest)
    if surfHue then item.hueKeySurface = surfHue end
  end
  if hueClose(surfHue, targetHue) then return 4 end

  return nil
end

-- Batched async color filter to avoid CPU budget overruns.
-- Processes `source` in chunks of BATCH_SIZE items per noctalia.runAsync tick.
--
-- Parameters:
--   token      - a cancellation token; if isCancelled() returns true, the filter stops
--   targetHue  - the hue key to match against (from colorToHueKey)
--   nameQuery  - optional name sub-string filter (empty string = no name filter)
--   source     - flat array of wallpaper items to filter
--   isCancelled - function() -> bool; called each batch to check for cancellation
--   onProgress  - function(partial: {any}, done: bool); called after each batch with
--                 sorted partial results (and done=true when all batches complete)
local BATCH_SIZE = 200
function M.runColorFilter(token, targetHue, nameQuery, source, isCancelled, onProgress)
  local q = string.lower(nameQuery or "")
  local filtered = {}
  local idx = 1
  local total = #source

  local function step()
    if isCancelled() then return end
    local endIdx = math.min(total, idx + BATCH_SIZE - 1)
    for i = idx, endIdx do
      local item = source[i]
      if item then
        local nameOk = (q == "")
          or string.find(item.lowerName or string.lower(item.name or ""), q, 1, true)
          or (item.relDir and string.find(string.lower(item.relDir), q, 1, true))
        if nameOk then
          local p = M.matchPriority(item, targetHue)
          if p ~= nil then
            item._colorPriority = p
            table.insert(filtered, item)
          end
        end
      end
    end
    idx = endIdx + 1

    -- Build a sorted snapshot of what we have so far
    local snapshot = {}
    for _, v in ipairs(filtered) do table.insert(snapshot, v) end
    table.sort(snapshot, function(a, b) return (a._colorPriority or 9) < (b._colorPriority or 9) end)

    local done = (idx > total)
    onProgress(snapshot, done)

    if not done and not isCancelled() then
      noctalia.runAsync({ "true" }, step)
    end
  end

  noctalia.runAsync({ "true" }, step)
end

return M
