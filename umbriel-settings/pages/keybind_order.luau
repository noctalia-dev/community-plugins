--!nonstrict
-- Keybind order for sorting by drag and drop or the arrow buttons. Rows are kept in display order (groups in
-- order, Ungrouped last), which is also the order the file gets.
local M = {}

-- Rows are kept in display order (groups in order, Ungrouped last), which is also the order the file gets.
local function sortRows(kb)
  local rank, buckets = {}, {}
  for i, name in ipairs(kb.groups) do rank[name] = i end
  for i = 1, #kb.groups + 1 do buckets[i] = {} end
  for _, row in ipairs(kb.rows) do
    local bucket = buckets[rank[row.group or ""] or (#kb.groups + 1)]
    bucket[#bucket + 1] = row
  end
  local i = 0
  for _, bucket in ipairs(buckets) do
    for _, row in ipairs(bucket) do i = i + 1; kb.rows[i] = row end
  end
end

-- Moves row `from` into `group`, before row `before` (an index of the list as it was) or at the group's end.
function M.moveRow(kb, from, group, before)
  local row = table.remove(kb.rows, from)
  if (row.group or "") ~= group then row.group = group end
  if before then
    if before > from then before = before - 1 end
    table.insert(kb.rows, before, row)
  else
    local at = #kb.rows
    for i, other in ipairs(kb.rows) do if (other.group or "") == group then at = i end end
    table.insert(kb.rows, at + 1, row)
  end
  sortRows(kb)
end

-- Moves group `from` before group `before` (an index of the list as it was), or last when nil.
function M.moveGroup(kb, from, before)
  local name = table.remove(kb.groups, from)
  if before then
    if before > from then before = before - 1 end
    table.insert(kb.groups, before, name)
  else
    table.insert(kb.groups, name)
  end
  sortRows(kb)
end

local function signature(kb)
  local parts = { table.concat(kb.groups, "\0") }
  for _, row in ipairs(kb.rows) do parts[#parts + 1] = row.key .. "\0" .. (row.group or "") end
  return table.concat(parts, "\1")
end

-- Payloads and zone values are "r|<row index>|<key>" or "g|<group index>|<name>" (0 = Ungrouped); the name
-- guards against a list that changed since the drag began (undo, a reload).
local function parseDrag(text)
  local kind, index, name = string.match(text, "^([rg])|(%d+)|(.*)$")
  return kind, tonumber(index), name
end

-- A row onto a row: before it, in its group. A row onto a group: at its end. A group onto a group: before
-- it (Ungrouped: last).
function M.drop(ctx, payload, value)
  local kb = ctx.store.keybinds
  local kind, index, name = parseDrag(payload)
  local target, targetIndex, targetName = parseDrag(value)
  if not (kb and kind and target) then return end
  local before = signature(kb)
  local function groupAt(i)
    if i == 0 then return "" end
    return kb.groups[i] == targetName and kb.groups[i] or nil
  end
  if kind == "r" then
    local row = kb.rows[index]
    if not row or row.key ~= name or row.locked then ctx.render(); return end
    if target == "r" then
      local anchor = kb.rows[targetIndex]
      if not anchor or anchor.key ~= targetName then ctx.render(); return end
      M.moveRow(kb, index, anchor.group or "", targetIndex)
    else
      local group = groupAt(targetIndex)
      if not group then ctx.render(); return end
      M.moveRow(kb, index, group, nil)
    end
  else
    if index == 0 or kb.groups[index] ~= name or target ~= "g" then ctx.render(); return end
    if targetIndex > 0 and not groupAt(targetIndex) then ctx.render(); return end
    M.moveGroup(kb, index, targetIndex > 0 and targetIndex or nil)
  end
  if signature(kb) ~= before then ctx.store.keybindsChanged() end
  ctx.render()
end

return M
