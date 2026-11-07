--!nonstrict
-- Turns the tiled windows of a workspace into a tree of rows and columns, so the panel can
-- draw them with flex containers, which have no absolute positions.
--
-- Tiling layouts split the screen again and again, so some straight line always parts the
-- windows into two groups, one on each side. The tree follows those lines. Windows that
-- overlap, which no line parts, share the space in a row.

local Layout = {}

-- Gaps between windows are a few pixels; anything closer counts as touching.
local TOLERANCE = 24

local function bounds(windows)
  local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
  for _, w in ipairs(windows) do
    left = math.min(left, w.x)
    top = math.min(top, w.y)
    right = math.max(right, w.x + w.width)
    bottom = math.max(bottom, w.y + w.height)
  end
  return { x = left, y = top, width = right - left, height = bottom - top }
end

-- axis "x" looks for a vertical line, "y" for a horizontal one.
local function cut(windows, axis)
  local size = axis == "x" and "width" or "height"
  for _, candidate in ipairs(windows) do
    local line = candidate[axis] + candidate[size]
    local before, after = {}, {}
    local clean = true
    for _, w in ipairs(windows) do
      if w[axis] + w[size] <= line + TOLERANCE then
        table.insert(before, w)
      elseif w[axis] >= line - TOLERANCE then
        table.insert(after, w)
      else
        clean = false
        break
      end
    end
    if clean and #before > 0 and #after > 0 then
      return before, after
    end
  end
  return nil
end

-- A node is { window = w }, or { direction = "row" | "column", children = { node },
-- shares = { number } }, where shares are the children's widths or heights.
function Layout.tree(windows)
  if #windows == 1 then
    return { window = windows[1] }
  end
  local direction, groups = "row", nil
  local before, after = cut(windows, "x")
  if before then
    groups = { before, after }
  else
    before, after = cut(windows, "y")
    if before then
      direction, groups = "column", { before, after }
    end
  end
  if groups == nil then
    groups = {}
    for _, w in ipairs(windows) do
      table.insert(groups, { w })
    end
  end
  local node = { direction = direction, children = {}, shares = {} }
  for _, group in ipairs(groups) do
    local box = bounds(group)
    table.insert(node.children, Layout.tree(group))
    table.insert(node.shares, direction == "row" and box.width or box.height)
  end
  return node
end

-- Splits length among shares, leaving gap between them, in whole pixels.
function Layout.sizes(length, shares, gap)
  local total = 0
  for _, share in ipairs(shares) do
    total += math.max(share, 1)
  end
  local free = length - gap * (#shares - 1)
  local sizes, used = {}, 0
  for index, share in ipairs(shares) do
    local size = index == #shares and free - used or math.floor(free * math.max(share, 1) / total)
    table.insert(sizes, size)
    used += size
  end
  return sizes
end

return Layout
