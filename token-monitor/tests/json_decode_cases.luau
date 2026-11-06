local Json = require("../lib/json_decode.luau")
local total = 0
local function test(name, fn) fn(); total += 1; print("PASS " .. name) end
local text = string.rep("x", 768)
local rawRow = '{"text":"' .. text .. '\\"\\\\\\t\\u263a","number":-12.5e2,"flag":true,"nothing":null}'
local function row() return {text = text .. '"\\\t☺', number = -1250, flag = true} end
-- Finite fixture literals, not another JSON parser. Each accepted byte sequence
-- has a declared value; production/native integration validates real JSON grammar.
local function rig()
  local r = { calls = 0, ticks = 0, maximum = 0 }
  local literals = {
    {raw = rawRow, make = row},
    {raw = '["dup",' .. rawRow .. ']', make = function() return {"dup", row()} end},
    {raw = '["dup",null]', make = function() return {"dup"} end},
    {raw = '["tail",true]', make = function() return {"tail", true} end},
    {raw = '["empty",{}]', make = function() return {"empty", {}} end},
    {raw = '["nil",null]', make = function() return {"nil"} end},
    {raw = 'null', make = function() return nil end},
    {raw = 'true', make = function() return true end},
    {raw = 'false', make = function() return false end},
    {raw = '0', make = function() return 0 end},
  }
  r.native = function(fragment)
    r.calls += 1; r.maximum = math.max(r.maximum, #fragment)
    assert(#fragment <= 32768, "unbounded native decode")
    if fragment == '"rows"' then return "rows" end
    if fragment == '"dup"' then return "dup" end
    if fragment == '{}' then return {} end
    if fragment == rawRow then return row() end
    if fragment == 'null' then return nil end
    if fragment:sub(1, 1) ~= '[' or fragment:sub(-1) ~= ']' then return nil, "unknown fixture literal" end
    local out, count, cursor = {}, 0, 2
    if cursor == #fragment then return out end
    while cursor < #fragment do
      local matched = false
      for _, literal in ipairs(literals) do
        if fragment:sub(cursor, cursor + #literal.raw - 1) == literal.raw then
          count += 1; out[count] = literal.make(); cursor += #literal.raw; matched = true; break
        end
      end
      if not matched then return nil, "unknown fixture literal" end
      if cursor == #fragment then break end
      if fragment:sub(cursor, cursor) ~= ',' then return nil, "unknown fixture delimiter" end
      cursor += 1
      if cursor == #fragment then return nil, "trailing fixture comma" end
    end
    return out
  end
  r.step = function() r.ticks += 1 end
  function r.decode(body) return Json.decode(body, r.native, r.step) end
  return r
end
local function rows(count) return '[' .. string.rep(rawRow .. ',', count - 1) .. rawRow .. ']' end
local padding = string.rep('null,', 9000) .. 'null'

test("small bodies retain the native fast path including null and errors", function()
  local r = rig(); local value, error = r.decode(rawRow)
  assert(not error and value.text == row().text and value.number == -1250 and value.flag and value.nothing == nil)
  assert(r.calls == 1 and r.ticks == 0)
  local null, nullError = r.decode('null'); assert(null == nil and nullError == nil)
  local _, malformed = r.decode('{bad'); assert(malformed == 'invalid_response')
end)

test("large nested objects reconstruct every row without a giant native call", function()
  local r = rig(); local body = '{"rows":' .. rows(1900) .. ',"tail":true,"empty":{},"nil":null}'
  assert(#body > 1500000 and #body < 2 * 1024 * 1024)
  local value, error = r.decode(body)
  assert(not error and #value.rows == 1900 and value.tail == true and type(value.empty) == 'table' and value["nil"] == nil)
  assert(value.rows[1].text == row().text and value.rows[1900].number == -1250)
  assert(value.rows[1900].flag == true and value.rows[1900].nothing == nil)
  assert(r.calls > 40 and r.maximum <= 32768 and r.ticks >= r.calls)
end)

test("partitioned arrays retain false zero and null indices", function()
  local r = rig(); local body = '[' .. padding .. ',false,0,true]'
  local value, error = r.decode(body)
  assert(not error and value[1] == nil and value[9001] == nil)
  assert(value[9002] == false and value[9003] == 0 and value[9004] == true)
end)

test("duplicate object keys and a final null remove earlier values across blocks", function()
  local r = rig(); local entry = '"dup":' .. rawRow
  local body = '{' .. string.rep(entry .. ',', 100) .. '"dup":null,"tail":true}'
  local value, error = r.decode(body)
  assert(not error and value.dup == nil and value.tail == true)
  local second, secondError = rig().decode('{"dup":null,' .. string.rep(entry .. ',', 100) .. '"dup":' .. rawRow .. '}')
  assert(not secondError and second.dup.text == row().text)
end)

test("structural delimiters and quoted escape boundaries fail visibly", function()
  local cases = {
    '[' .. padding .. ',]', '[' .. padding .. ',,0]', '[' .. padding .. ' 0]',
    '{"rows" ' .. rows(45) .. '}', '{"rows":' .. rows(45) .. ',}',
    '{"rows":' .. rows(45) .. ']', '{"rows":' .. rows(45) .. '} trailing',
    '[' .. padding .. ',"unterminated]', '[' .. padding .. ',"bad\nstring"]',
    '[' .. padding .. ',"bad\\\nstring"]', '[' .. padding .. ',"bad\\qescape"]',
    '[' .. padding .. ',01]', '[' .. padding .. ',true false]',
    '{"rows":' .. rows(45) .. ',"escaped\\":true}',
  }
  for index, body in ipairs(cases) do
    local _, error = rig().decode(body)
    assert(error == 'invalid_response', 'malformed case ' .. tostring(index) .. ' was accepted: ' .. tostring(error))
  end
end)

test("scanner checks its time slice and separates native calls from scan work", function()
  local r = rig(); local now, ticks, nativeTicks = 0, 0, -1
  local function native(fragment)
    assert(ticks > nativeTicks)
    nativeTicks = ticks
    return r.native(fragment)
  end
  local value, error = Json.decode('[' .. padding .. ']', native, function() ticks += 1 end, function() now += 0.005; return now end)
  assert(not error and type(value) == "table" and ticks > 20)
end)

test("depth node body and scalar bounds report too_large", function()
  local r = rig(); local _, depth = r.decode(string.rep('[', 65) .. padding .. string.rep(']', 65))
  assert(depth == 'too_large' and r.calls == 0)
  local _, nodes = rig().decode('[' .. string.rep('0,', 262145) .. '0]'); assert(nodes == 'too_large')
  local _, scalar = rig().decode('{"rows":"' .. string.rep('a', 32769) .. '"}'); assert(scalar == 'too_large')
  local _, key = rig().decode('{"' .. string.rep('a', 32769) .. '":null}'); assert(key == 'too_large')
  local _, bytes = rig().decode(string.rep(' ', 4 * 1024 * 1024 + 1)); assert(bytes == 'too_large')
end)

print(tostring(total) .. " json decode cases passed")
