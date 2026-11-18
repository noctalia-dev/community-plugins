--!nonstrict
-- Physical arrangement of matrix positions. Port of Geometry.swift, restated for a
-- flex layout: each half is a list of key columns (top stagger + keys, top to bottom)
-- plus an optional thumb row. Matrix indices are 0-based.

local M = {}

local function looksLikeCorne(file, vil)
  local function thumbRow(r)
    return vil.code(file, 0, r, 0) == "-1" and vil.code(file, 0, r, 1) == "-1" and vil.code(file, 0, r, 2) == "-1"
  end
  return thumbRow(3) and thumbRow(7)
end

-- splitkb Aurora Corne / crkbd: 3x6+3 per half, matrix 8 rows x 6 cols, columns counted
-- from the outer edge. Right half rows are 4..7.
local function corne()
  local stagger = { 0.3, 0.3, 0.1, 0.0, 0.1, 0.2 } -- indexed by matrix col + 1
  local function half(rowBase, mirrored)
    local cols = {}
    for c = 0, 5 do
      local keys = {}
      for r = 0, 2 do keys[r + 1] = { rowBase + r, c } end
      table.insert(cols, { stagger = stagger[c + 1], keys = keys })
    end
    local thumbs = { { rowBase + 3, 3 }, { rowBase + 3, 4 }, { rowBase + 3, 5 } }
    if mirrored then
      local rc, rt = {}, {}
      for i = #cols, 1, -1 do table.insert(rc, cols[i]) end
      for i = #thumbs, 1, -1 do table.insert(rt, thumbs[i]) end
      cols, thumbs = rc, rt
    end
    return {
      cols = cols,
      thumbs = thumbs,
      thumbOffset = 3.5,         -- key units from the outer edge
      thumbDrop = 0.45,          -- key units between the main block and the thumb row
      side = mirrored and "right" or "left",
    }
  end
  return { kind = "corne", halves = { half(0, false), half(4, true) }, halfGap = 0.8, unitsWide = 13.8 + 1.0 }
end

local function genericSplit(file, vil)
  local rows, cols = file.rows, file.cols
  local halfRows = rows / 2
  local function half(rowBase, mirrored)
    local list = {}
    for c = 0, cols - 1 do
      local keys = {}
      for r = 0, halfRows - 1 do
        keys[r + 1] = vil.code(file, 0, rowBase + r, c) ~= "-1" and { rowBase + r, c } or false
      end
      table.insert(list, { stagger = 0, keys = keys })
    end
    if mirrored then
      local rc = {}
      for i = #list, 1, -1 do table.insert(rc, list[i]) end
      list = rc
    end
    return { cols = list, side = mirrored and "right" or "left" }
  end
  return { kind = "split", halves = { half(0, false), half(halfRows, true) }, halfGap = 1.0, unitsWide = cols * 2 + 1 }
end

local function grid(file, vil)
  local list = {}
  for c = 0, file.cols - 1 do
    local keys = {}
    for r = 0, file.rows - 1 do
      keys[r + 1] = vil.code(file, 0, r, c) ~= "-1" and { r, c } or false
    end
    table.insert(list, { stagger = 0, keys = keys })
  end
  return { kind = "grid", halves = { { cols = list, side = "left" } }, halfGap = 0, unitsWide = file.cols }
end

function M.make(file, vil)
  if file.rows == 8 and file.cols == 6 and looksLikeCorne(file, vil) then return corne() end
  if file.rows >= 2 and file.rows % 2 == 0 and file.cols <= 8 then return genericSplit(file, vil) end
  return grid(file, vil)
end

return M
