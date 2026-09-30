--!nonstrict
-- Parsed Vial keymap export (.vil). Port of VilFile.swift from egno/vial_helper.
-- Matrix indices in the returned structure are 0-based like QMK; use M.code().

local keycode = require("./keycode.luau")

local M = {}

local function keycodeString(v)
  if type(v) == "string" then return v end
  if type(v) == "number" then
    if v < 0 then return "-1" end
    return "KC_" .. tostring(math.floor(v))
  end
  return "KC_NO"
end

local function mapLayers(raw)
  local out = {}
  for li, layer in ipairs(raw) do
    local rows = {}
    for ri, row in ipairs(layer) do
      local cols = {}
      for ci, v in ipairs(row) do cols[ci] = keycodeString(v) end
      rows[ri] = cols
    end
    out[li] = rows
  end
  return out
end

-- Keycode at 0-based (layer, row, col); "-1" when the position does not exist.
function M.code(file, layer, row, col)
  local l = file.layers[layer + 1]
  if l == nil then return "-1" end
  local r = l[row + 1]
  if r == nil then return "-1" end
  return r[col + 1] or "-1"
end

function M.isLayerEmpty(file, layer)
  local l = file.layers[layer + 1]
  if l == nil then return true end
  for _, row in ipairs(l) do
    for _, code in ipairs(row) do
      if not (keycode.isEmpty(code) or keycode.isTransparent(code)) then return false end
    end
  end
  return true
end

-- 0-based indices of layers with at least one real binding.
function M.nonEmptyLayers(file)
  local out = {}
  for i = 0, #file.layers - 1 do
    if not M.isLayerEmpty(file, i) then table.insert(out, i) end
  end
  return out
end

-- Returns file or nil, err.
function M.load(path)
  if not noctalia.fileExists(path) then return nil, "File not found: " .. path end
  local raw, rerr = noctalia.readFile(path)
  if raw == nil then return nil, "Cannot read: " .. tostring(rerr) end
  local root, jerr = noctalia.json.decode(raw)
  if root == nil then return nil, "Invalid .vil file: not JSON (" .. tostring(jerr) .. ")" end
  if type(root) ~= "table" then return nil, "Invalid .vil file: root is not an object" end
  if type(root.layout) ~= "table" then return nil, 'Invalid .vil file: missing "layout"' end

  local layers = mapLayers(root.layout)
  if #layers == 0 or #layers[1] == 0 then return nil, "Invalid .vil file: no layers" end

  local encoders = {}
  if type(root.encoder_layout) == "table" then encoders = mapLayers(root.encoder_layout) end

  local combos = {}
  if type(root.combo) == "table" then
    for _, rawCombo in ipairs(root.combo) do
      local items = {}
      for _, v in ipairs(rawCombo) do table.insert(items, keycodeString(v)) end
      if #items >= 2 then
        local result = items[#items]
        local keys = {}
        for i = 1, #items - 1 do
          if not keycode.isEmpty(items[i]) then table.insert(keys, items[i]) end
        end
        if #keys > 0 and not keycode.isEmpty(result) then
          table.insert(combos, { keys = keys, result = result })
        end
      end
    end
  end

  local tapDances = {}
  if type(root.tap_dance) == "table" then
    for _, rawTd in ipairs(root.tap_dance) do
      local s = {}
      for i = 1, 4 do s[i] = rawTd[i] ~= nil and keycodeString(rawTd[i]) or "KC_NO" end
      table.insert(tapDances, {
        tap = s[1], hold = s[2], doubleTap = s[3], tapHold = s[4],
        term = type(rawTd[5]) == "number" and rawTd[5] or 200,
      })
    end
  end

  local fileName = path:match("([^/]+)$") or path
  return {
    path = path,
    fileName = fileName,
    layers = layers,        -- [layer][row][col] 1-based tables of keycode strings
    encoders = encoders,    -- [layer][encoder] = { ccw, cw }
    combos = combos,        -- { keys = {...}, result = "..." }
    tapDances = tapDances,
    layoutOptions = type(root.layout_options) == "number" and root.layout_options or 0,
    rows = #layers[1],
    cols = #layers[1][1],
  }
end

return M
