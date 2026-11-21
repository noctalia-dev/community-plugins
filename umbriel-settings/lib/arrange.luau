--!nonstrict
-- Display arrangement geometry (pure): rectangles {id, x, y, w, h} in logical pixels.
-- An arrangement is a tree: every display but the root sits on one side of its parent, and the displays on
-- one side of a parent form a group (a row above/below, a column left/right) centered on the parent's center
-- line. A display can instead hang off one half of that edge (its anchor: "start" = left/top half, "end" =
-- right/bottom half), with its edge on the parent's center line: dropped on a corner of the parent.
-- `infer` reads that tree back from positions, `layout` turns it into positions, `move` re-attaches one
-- display, `bands` splits rectangles into nested rows/columns for drawing (no absolute positioning in the UI).
local M = {}

local SIDES = { "above", "below", "left", "right" }
local TOLERANCE = 2  -- logical sizes are rounded; edges this close still touch

local function round(v) return math.floor(v + 0.5) end
local function horizontal(side) return side == "above" or side == "below" end

local function copyRect(r) return { id = r.id, x = r.x, y = r.y, w = r.w, h = r.h } end

-- The side of `p` that `u` lies on: the axis on which they are further apart, relative to their sizes.
local function sideOf(u, p)
  local dx = ((u.x + u.w / 2) - (p.x + p.w / 2)) / ((u.w + p.w) / 2)
  local dy = ((u.y + u.h / 2) - (p.y + p.h / 2)) / ((u.h + p.h) / 2)
  if math.abs(dy) >= math.abs(dx) then return dy < 0 and "above" or "below" end
  return dx < 0 and "left" or "right"
end

local function overlap(a1, a2, b1, b2) return math.min(a2, b2) - math.max(a1, b1) end

-- Whether `u` lies flush against `p`'s `side` edge and shares some of that edge.
local function touches(u, p, side)
  if side == "above" then
    return math.abs(u.y + u.h - p.y) <= TOLERANCE and overlap(u.x, u.x + u.w, p.x, p.x + p.w) > 0
  elseif side == "below" then
    return math.abs(u.y - (p.y + p.h)) <= TOLERANCE and overlap(u.x, u.x + u.w, p.x, p.x + p.w) > 0
  elseif side == "left" then
    return math.abs(u.x + u.w - p.x) <= TOLERANCE and overlap(u.y, u.y + u.h, p.y, p.y + p.h) > 0
  end
  return math.abs(u.x - (p.x + p.w)) <= TOLERANCE and overlap(u.y, u.y + u.h, p.y, p.y + p.h) > 0
end

-- Whether `v` continues a group member `g` along the group's line: same outer edge as the parent side, flush
-- next to `g` (so a row of three above a small display stays one group even where it overhangs).
local function continues(v, g, side)
  if side == "above" or side == "below" then
    local edge = side == "above" and math.abs(v.y + v.h - (g.y + g.h)) <= TOLERANCE
      or side == "below" and math.abs(v.y - g.y) <= TOLERANCE
    return edge and (math.abs(v.x + v.w - g.x) <= TOLERANCE or math.abs(v.x - (g.x + g.w)) <= TOLERANCE)
      and overlap(v.y, v.y + v.h, g.y, g.y + g.h) > 0
  end
  local edge = side == "left" and math.abs(v.x + v.w - (g.x + g.w)) <= TOLERANCE
    or side == "right" and math.abs(v.x - g.x) <= TOLERANCE
  return edge and (math.abs(v.y + v.h - g.y) <= TOLERANCE or math.abs(v.y - (g.y + g.h)) <= TOLERANCE)
    and overlap(v.x, v.x + v.w, g.x, g.x + g.w) > 0
end

local function gapBetween(u, p)
  local gx = math.max(0, p.x - (u.x + u.w), u.x - (p.x + p.w))
  local gy = math.max(0, p.y - (u.y + u.h), u.y - (p.y + p.h))
  return gx + gy
end

local function newTree(rootId)
  return { root = rootId, parent = {}, side = {}, anchor = {},
           kids = { [rootId] = { above = {}, below = {}, left = {}, right = {} } } }
end

local function attach(tree, id, parent, side, at, anchor)
  tree.parent[id], tree.side[id], tree.anchor[id] = parent, side, anchor or "center"
  tree.kids[id] = tree.kids[id] or { above = {}, below = {}, left = {}, right = {} }
  local list = tree.kids[parent][side]
  table.insert(list, at or (#list + 1), id)
end

-- The arrangement tree behind `rects` (list order = display numbers). The root is the largest display.
local function infer(rects)
  if #rects == 0 then return nil end
  local byId, root = {}, rects[1]
  for _, r in ipairs(rects) do
    byId[r.id] = r
    if r.w * r.h > root.w * root.h then root = r end
  end
  local tree = newTree(root.id)
  local placed, order, done = { [root.id] = true }, { root }, 1
  local function unplaced()
    local list = {}
    for _, r in ipairs(rects) do if not placed[r.id] then table.insert(list, r) end end
    return list
  end
  while done < #rects do
    local found = false
    -- breadth first: the earliest placed display takes everything that touches it, side by side
    for _, p in ipairs(order) do
      for _, side in ipairs(SIDES) do
        local group = {}
        for _, u in ipairs(unplaced()) do
          if touches(u, p, side) then table.insert(group, u); placed[u.id] = true end
        end
        local grew = #group > 0
        while grew do
          grew = false
          for _, v in ipairs(unplaced()) do
            for _, g in ipairs(group) do
              if not placed[v.id] and continues(v, g, side) then
                table.insert(group, v); placed[v.id] = true; grew = true
              end
            end
          end
        end
        if #group > 0 then
          local axis = horizontal(side) and "x" or "y"
          local size = horizontal(side) and "w" or "h"
          table.sort(group, function(a, b) return a[axis] < b[axis] end)
          -- a group centered on the parent is one centered row; otherwise displays from the one whose edge
          -- sits on the parent's center line outward hang off that half
          local center = p[axis] + p[size] / 2
          local first, last = group[1], group[#group]
          local anchors = {}
          if math.abs((first[axis] + last[axis] + last[size]) / 2 - center) > TOLERANCE then
            local startAt, endAt = nil, nil
            for i, u in ipairs(group) do
              if math.abs(u[axis] + u[size] - center) <= TOLERANCE then startAt = i end
              if not endAt and math.abs(u[axis] - center) <= TOLERANCE then endAt = i end
            end
            for i = 1, #group do
              if startAt and i <= startAt then anchors[i] = "start"
              elseif endAt and i >= endAt then anchors[i] = "end" end
            end
          end
          for i, u in ipairs(group) do
            attach(tree, u.id, p.id, side, nil, anchors[i])
            table.insert(order, u)
            done = done + 1
          end
          found = true
        end
      end
      if found then break end
    end
    if not found then
      -- nothing touches: the closest pair of a placed and an unplaced display
      local best, bestP, bestGap = nil, nil, math.huge
      for _, p in ipairs(order) do
        for _, u in ipairs(unplaced()) do
          local gap = gapBetween(u, p)
          if gap < bestGap then best, bestP, bestGap = u, p, gap end
        end
      end
      attach(tree, best.id, bestP.id, sideOf(best, bestP))
      placed[best.id] = true
      table.insert(order, best)
      done = done + 1
    end
  end
  return tree
end

local function intersects(a, b)
  return overlap(a.x, a.x + a.w, b.x, b.x + b.w) > 0 and overlap(a.y, a.y + a.h, b.y, b.y + b.h) > 0
end

-- Moves `group` outward from its parent's `side` until it overlaps nothing in `placed`.
local function pushOut(group, side, placed)
  for _ = 1, #placed + 1 do
    local shift = 0
    for _, r in ipairs(group) do
      for _, q in ipairs(placed) do
        if intersects(r, q) then
          local need
          if side == "above" then need = r.y + r.h - q.y
          elseif side == "below" then need = q.y + q.h - r.y
          elseif side == "left" then need = r.x + r.w - q.x
          else need = q.x + q.w - r.x end
          if need > shift then shift = need end
        end
      end
    end
    if shift <= 0 then return end
    for _, r in ipairs(group) do
      if side == "above" then r.y = r.y - shift
      elseif side == "below" then r.y = r.y + shift
      elseif side == "left" then r.x = r.x - shift
      else r.x = r.x + shift end
    end
  end
end

-- Positions {id → {x, y}} for `tree` with sizes {id → {w, h}}: groups flush against their parent's edge and
-- centered on its center line, pushed outward past displays they would overlap, top-left at 0,0.
local function layout(tree, sizes)
  local rects = {}
  local placedList = {}
  local root = sizes[tree.root]
  rects[tree.root] = { id = tree.root, x = 0, y = 0, w = root.w, h = root.h }
  table.insert(placedList, rects[tree.root])
  local queue, head = { tree.root }, 1
  while head <= #queue do
    local pid = queue[head]
    head = head + 1
    local p = rects[pid]
    for _, side in ipairs(SIDES) do
      local lists = { center = {}, start = {}, ["end"] = {} }
      for _, id in ipairs(tree.kids[pid] and tree.kids[pid][side] or {}) do
        table.insert(lists[tree.anchor[id] or "center"], id)
      end
      local function length(id) return horizontal(side) and sizes[id].w or sizes[id].h end
      local middle = horizontal(side) and p.x + p.w / 2 or p.y + p.h / 2
      for _, anchor in ipairs({ "center", "end", "start" }) do
        local ids = lists[anchor]
        if #ids > 0 then
          local total = 0
          for _, id in ipairs(ids) do total = total + length(id) end
          -- centered on the middle, starting at it, or ending at it
          local along = round(anchor == "center" and middle - total / 2 or anchor == "end" and middle or middle - total)
          local group = {}
          for _, id in ipairs(ids) do
            local sz = sizes[id]
            local r = { id = id, w = sz.w, h = sz.h }
            if side == "above" then r.x, r.y = along, p.y - sz.h
            elseif side == "below" then r.x, r.y = along, p.y + p.h
            elseif side == "left" then r.x, r.y = p.x - sz.w, along
            else r.x, r.y = p.x + p.w, along end
            along = along + length(id)
            table.insert(group, r)
          end
          pushOut(group, side, placedList)
          for _, r in ipairs(group) do
            rects[r.id] = r
            table.insert(placedList, r)
            table.insert(queue, r.id)
          end
        end
      end
    end
  end
  local minX, minY = math.huge, math.huge
  for _, r in pairs(rects) do minX, minY = math.min(minX, r.x), math.min(minY, r.y) end
  local positions = {}
  for id, r in pairs(rects) do positions[id] = { x = r.x - minX, y = r.y - minY } end
  return positions
end

-- Sizes {id → {w, h}} of `rects`.
local function sizesOf(rects)
  local sizes = {}
  for _, r in ipairs(rects) do sizes[r.id] = { w = r.w, h = r.h } end
  return sizes
end

-- Positions after dropping display `id` on `side` of display `target` (`rects` = the current arrangement).
-- The display leaves its place first (what was attached to it closes up). On a side across the target's
-- group (left/right of a display in a row above/below, above/below one in a column) it joins that group next
-- to the target; otherwise it goes to the end of the target's group on that side. A corner ("above-start",
-- "below-end", ...) hangs it off that half of the target's edge.
function M.move(rects, id, target, where)
  local side, anchor = string.match(tostring(where), "^(%a+)%-?(%a*)$")
  if not side then return nil end
  local rest = {}
  for _, r in ipairs(rects) do if r.id ~= id then table.insert(rest, copyRect(r)) end end
  local sizes = sizesOf(rects)
  if #rest == 0 or id == target or not sizes[target] then return nil end
  -- the tree of the others: laid out again, it has no hole where the display was
  local tree = infer(rest)
  local parent, groupSide = tree.parent[target], tree.side[target]
  if anchor == "start" or anchor == "end" then
    attach(tree, id, target, side, nil, anchor)
  elseif parent and horizontal(groupSide) ~= horizontal(side) then
    local list = tree.kids[parent][groupSide]
    local at = 1
    for i, other in ipairs(list) do if other == target then at = i end end
    if side == "right" or side == "below" then at = at + 1 end
    attach(tree, id, parent, groupSide, at, tree.anchor[target])
  else
    attach(tree, id, target, side)
  end
  return layout(tree, sizes)
end

-- Positions with the current tree laid out again (recentered, flush, top-left at 0,0).
function M.tidy(rects)
  if #rects == 0 then return {} end
  return layout(infer(rects), sizesOf(rects))
end

-- Nested drawing bands for non-overlapping `rects`: {rect = r} for one display, or
-- {dir = "row"|"column", x, y, w, h, parts = {band…}} where the parts follow each other along `dir` without
-- overlapping it. nil when no straight cut separates the displays (a pinwheel).
function M.bands(rects)
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for _, r in ipairs(rects) do
    minX, minY = math.min(minX, r.x), math.min(minY, r.y)
    maxX, maxY = math.max(maxX, r.x + r.w), math.max(maxY, r.y + r.h)
  end
  if #rects == 1 then return { rect = rects[1], x = minX, y = minY, w = maxX - minX, h = maxY - minY } end
  for _, dir in ipairs({ "row", "column" }) do
    local start, size = dir == "row" and "x" or "y", dir == "row" and "w" or "h"
    local sorted = { table.unpack(rects) }
    table.sort(sorted, function(a, b) return a[start] < b[start] end)
    local groups, current, reach = {}, {}, -math.huge
    for _, r in ipairs(sorted) do
      if #current > 0 and r[start] >= reach then
        table.insert(groups, current)
        current = {}
      end
      table.insert(current, r)
      reach = math.max(reach, r[start] + r[size])
    end
    table.insert(groups, current)
    if #groups > 1 then
      local parts = {}
      for _, group in ipairs(groups) do
        local band = M.bands(group)
        if not band then return nil end
        table.insert(parts, band)
      end
      return { dir = dir, x = minX, y = minY, w = maxX - minX, h = maxY - minY, parts = parts }
    end
  end
  return nil
end

return M
