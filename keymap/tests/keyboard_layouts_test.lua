local sourceFile = assert(io.open("panel.luau", "rb"))
local source = sourceFile:read("*a")
sourceFile:close()

local beginMarker = "-- BEGIN KEYBOARD LAYOUT DATA"
local endMarker = "-- END KEYBOARD LAYOUT DATA"
local beginAt = assert(source:find(beginMarker, 1, true), "layout data start marker missing")
local bodyAt = assert(source:find("\n", beginAt, true)) + 1
local endAt = assert(source:find(endMarker, bodyAt, true), "layout data end marker missing")
local layoutSource = source:sub(bodyAt, endAt - 1)
local loader = assert(load(layoutSource .. [[
return {
  order = KEYBOARD_LAYOUT_ORDER,
  layouts = KEYBOARD_LAYOUTS,
}
]], "keyboard layout data", "t", _G))
local data = loader()

local expectedOrder = { "100", "96", "80", "75", "65", "60" }
local expectedRows = { ["100"] = 6, ["96"] = 6, ["80"] = 6, ["75"] = 6, ["65"] = 5, ["60"] = 5 }
local expectedPixels = { ["100"] = 1100, ["96"] = 908, ["80"] = 884, ["75"] = 764, ["65"] = 764, ["60"] = 716 }

local function keyWidth(units)
  return math.floor(units * 44 + (units - 1) * 4 + 0.5)
end

local globalIds = {}
for orderIndex, layoutId in ipairs(expectedOrder) do
  assert(data.order[orderIndex] == layoutId, "unexpected layout order at " .. orderIndex)
  local layout = assert(data.layouts[layoutId], "missing layout " .. layoutId)
  assert(layout.id == layoutId)
  assert(#layout.rows == expectedRows[layoutId], "unexpected row count for " .. layoutId)
  assert(keyWidth(layout.rowUnits) == expectedPixels[layoutId], "unexpected pixel width for " .. layoutId)

  local layoutIds = {}
  local hasLetters, hasDigits = {}, {}
  for rowIndex, row in ipairs(layout.rows) do
    local units = 0
    assert(#row > 0, "empty row in " .. layoutId)
    for _, spec in ipairs(row) do
      local isSpacer = spec.spacer ~= nil
      local isKey = spec.id ~= nil
      assert(isSpacer ~= isKey, "spec must be exactly one of spacer or key in " .. layoutId)
      local width = tonumber(isSpacer and spec.spacer or spec.units)
      assert(width and width > 0 and width * 4 % 1 == 0, "invalid quarter-unit width in " .. layoutId)
      units = units + width
      if isKey then
        assert(type(spec.id) == "string" and spec.id:match("^[a-z0-9_]+$"), "invalid key id")
        assert(not layoutIds[spec.id], "duplicate key id " .. spec.id .. " in " .. layoutId)
        layoutIds[spec.id] = true
        assert(type(spec.label) == "string" and spec.label ~= "", "key label missing for " .. spec.id)
        if spec.bindable == false then
          assert(spec.code == nil, "passive key must not expose a compositor code")
        else
          assert(type(spec.code) == "string" and spec.code ~= "", "bindable code missing for " .. spec.id)
        end
        if globalIds[spec.id] ~= nil then
          assert(globalIds[spec.id] == spec.code, "key id changed semantic code: " .. spec.id)
        else
          globalIds[spec.id] = spec.code or false
        end
        local letter = spec.id:match("^key_([a-z])$")
        local digit = spec.id:match("^digit_(%d)$")
        if letter then hasLetters[letter] = true end
        if digit then hasDigits[digit] = true end
      end
    end
    assert(math.abs(units - layout.rowUnits) < 0.0001,
      string.format("%s row %d is %.2fu instead of %.2fu", layoutId, rowIndex, units, layout.rowUnits))
  end
  for byte = string.byte("a"), string.byte("z") do
    assert(hasLetters[string.char(byte)], "letter missing from " .. layoutId)
  end
  for digit = 0, 9 do assert(hasDigits[tostring(digit)], "digit missing from " .. layoutId) end
end
assert(#data.order == #expectedOrder, "unexpected extra keyboard layout")

local function hasId(layoutId, wanted)
  for _, row in ipairs(data.layouts[layoutId].rows) do
    for _, spec in ipairs(row) do if spec.id == wanted then return true end end
  end
  return false
end

local function keyX(layoutId, rowIndex, wanted)
  local x = 0
  for _, spec in ipairs(data.layouts[layoutId].rows[rowIndex]) do
    if spec.id == wanted then return x end
    x = x + tonumber(spec.spacer or spec.units)
  end
  return nil
end

assert(hasId("100", "kp_1") and hasId("96", "kp_1"), "full layouts need a numpad")
for _, layoutId in ipairs({ "80", "75", "65", "60" }) do
  assert(not hasId(layoutId, "kp_1"), layoutId .. " unexpectedly contains a numpad")
end
for _, layoutId in ipairs({ "100", "96", "80", "75" }) do
  assert(hasId(layoutId, "f1"), layoutId .. " needs a function row")
end
assert(not hasId("65", "f1") and not hasId("60", "f1"))
assert(hasId("65", "arrow_up") and not hasId("60", "arrow_up"))
assert(hasId("65", "fn") and not hasId("75", "fn"), "Fn must be passive and limited to the 65% view")

assert(keyX("96", 5, "arrow_up") == 14 and keyX("96", 5, "kp_1") == 15)
assert(keyX("96", 6, "arrow_left") == 13 and keyX("96", 6, "arrow_down") == 14)
assert(keyX("96", 6, "arrow_right") == 15 and keyX("96", 6, "kp_0") == 16)
for _, layoutId in ipairs({ "75", "65" }) do
  local shiftRow = layoutId == "75" and 5 or 4
  local bottomRow = layoutId == "75" and 6 or 5
  assert(keyX(layoutId, shiftRow, "arrow_up") == 14)
  assert(keyX(layoutId, shiftRow, "end") == 15)
  assert(keyX(layoutId, bottomRow, "arrow_left") == 13)
  assert(keyX(layoutId, bottomRow, "arrow_down") == 14)
  assert(keyX(layoutId, bottomRow, "arrow_right") == 15)
end

print("keyboard layout tests: ok")
