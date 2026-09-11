--!nonstrict
-- Arrangement map geometry for the Monitor Control panel, kept free of host
-- globals so it can be unit-tested outside Noctalia (see tests/run.lua).
--
-- Umbriel positions are top-left logical coordinates and y grows downward, so an
-- output sitting above another has the smaller y. A mode's logical size is its
-- pixel size divided by the output scale, which is the space `position` lives in.

local M = {}

-- Logical width, height and the current mode of an output (mode / scale), or
-- nil when the output has no usable mode.
function M.logicalSize(output)
  local scale = tonumber(output.scale) or 1
  if scale <= 0 then
    scale = 1
  end
  local modes = output.modes or {}
  local current = nil
  for _, mode in ipairs(modes) do
    if mode.current == true then
      current = mode
      break
    end
  end
  current = current or modes[1]
  if current == nil or type(current.width) ~= "number" or type(current.height) ~= "number" then
    return nil
  end
  return current.width / scale, current.height / scale, current
end

-- Enabled outputs as rectangles in logical space: name, x, y, w, h plus the
-- mode's own width, height and refresh for labelling. Disabled outputs take no
-- room in the arrangement, so they are not drawn.
function M.rects(outputs)
  local rects = {}
  for _, output in ipairs(outputs or {}) do
    if output.enabled == true and type(output.name) == "string" then
      local w, h, mode = M.logicalSize(output)
      if w ~= nil then
        local position = output.position or {}
        table.insert(rects, {
          name = output.name,
          x = tonumber(position.x) or 0,
          y = tonumber(position.y) or 0,
          w = w,
          h = h,
          mode_width = mode.width,
          mode_height = mode.height,
          refresh_mhz = mode.refresh_mhz,
        })
      end
    end
  end
  return rects
end

-- Bounding box of the arrangement, or nil when there is nothing to draw.
function M.bounds(rects)
  if #rects == 0 then
    return nil
  end
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for _, rect in ipairs(rects) do
    minX = math.min(minX, rect.x)
    minY = math.min(minY, rect.y)
    maxX = math.max(maxX, rect.x + rect.w)
    maxY = math.max(maxY, rect.y + rect.h)
  end
  return minX, minY, maxX, maxY
end

-- Scales the whole arrangement into width x height keeping its aspect ratio,
-- then centres it. Returns scale and the canvas-space origin of logical (0, 0).
function M.fit(rects, width, height)
  local minX, minY, maxX, maxY = M.bounds(rects)
  if minX == nil then
    return nil
  end
  local spanX = math.max(maxX - minX, 1)
  local spanY = math.max(maxY - minY, 1)
  local scale = math.min(width / spanX, height / spanY)
  local offsetX = (width - spanX * scale) / 2 - minX * scale
  local offsetY = (height - spanY * scale) / 2 - minY * scale
  return scale, offsetX, offsetY
end

-- One rectangle in canvas pixels: integers, and at least MIN_PX on each side so
-- a small monitor still shows a readable box.
M.MIN_PX = 3

function M.place(rect, scale, offsetX, offsetY)
  return {
    name = rect.name,
    x = math.floor(rect.x * scale + offsetX + 0.5),
    y = math.floor(rect.y * scale + offsetY + 0.5),
    w = math.max(math.floor(rect.w * scale + 0.5), M.MIN_PX),
    h = math.max(math.floor(rect.h * scale + 0.5), M.MIN_PX),
    rect = rect,
  }
end

-- The drawable map: rectangles in canvas pixels grouped into horizontal bands,
-- so a flex row/column layout can place every monitor without absolute
-- positioning. Rectangles that overlap vertically share a band (side-by-side
-- monitors), stacked ones get a band each. Bands and their items come back
-- sorted top-to-bottom, left-to-right.
function M.map(rects, width, height)
  local scale, offsetX, offsetY = M.fit(rects, width, height)
  if scale == nil then
    return { bands = {}, items = {}, width = width, height = height, scale = 1, offsetX = 0, offsetY = 0 }
  end

  local items = {}
  for _, rect in ipairs(rects) do
    table.insert(items, M.place(rect, scale, offsetX, offsetY))
  end
  table.sort(items, function(a, b)
    if a.y ~= b.y then
      return a.y < b.y
    end
    return a.x < b.x
  end)

  local bands = {}
  for _, item in ipairs(items) do
    local band = bands[#bands]
    if band ~= nil and item.y < band.bottom then
      band.bottom = math.max(band.bottom, item.y + item.h)
      table.insert(band.items, item)
    else
      table.insert(bands, { top = item.y, bottom = item.y + item.h, items = { item } })
    end
  end
  for _, band in ipairs(bands) do
    table.sort(band.items, function(a, b)
      return a.x < b.x
    end)
  end

  return {
    bands = bands,
    items = items,
    width = width,
    height = height,
    scale = scale,
    offsetX = offsetX,
    offsetY = offsetY,
  }
end

-- Drawing plan: the map as rows of offsets, so a flex layout can reproduce
-- absolute positions. Every offset is the empty space that precedes a row
-- (offsetY) or an item inside its row (offsetX), and a caller must emit it as a
-- NON-flexible spacer - a growing spacer swallows the free space and pushes
-- every monitor to the far edge.
function M.plan(map)
  local rows, cursorY = {}, 0
  for _, band in ipairs(map.bands) do
    local row = { height = band.bottom - band.top, offsetY = band.top - cursorY, items = {} }
    local cursorX = 0
    for _, item in ipairs(band.items) do
      table.insert(row.items, {
        name = item.name,
        x = item.x,
        y = item.y,
        w = item.w,
        h = item.h,
        offsetX = item.x - cursorX,
        offsetY = item.y - band.top,
      })
      cursorX = item.x + item.w
    end
    table.insert(rows, row)
    cursorY = band.bottom
  end
  return { rows = rows, width = map.width, height = map.height }
end

return M
