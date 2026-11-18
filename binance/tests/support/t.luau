--!nonstrict
-- Minimal test harness: t.test(name, fn), t.eq(actual, expected), t.run().

local M = {}
local tests = {}

function M.test(name: string, fn: () -> ())
  table.insert(tests, { name = name, fn = fn })
end

local function show(v): string
  if type(v) ~= "table" then
    return if type(v) == "string" then string.format("%q", v) else tostring(v)
  end
  local keys = {}
  for k in v do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in keys do
    table.insert(parts, `{k}={show(v[k])}`)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function same(a, b): boolean
  if type(a) == "number" and type(b) == "number" then
    return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(a), math.abs(b))
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for k, v in a do
    if not same(v, b[k]) then
      return false
    end
  end
  for k in b do
    if a[k] == nil then
      return false
    end
  end
  return true
end

function M.eq(actual, expected, label: string?)
  if not same(actual, expected) then
    error(`{label or "values differ"}\n  expected {show(expected)}\n  actual   {show(actual)}`, 2)
  end
end

function M.run(): number
  local failed = 0
  for _, case in tests do
    local ok, err = pcall(case.fn)
    if not ok then
      failed += 1
      print(`FAIL {case.name}\n  {err}`)
    end
  end
  print(`{#tests - failed}/{#tests} passed`)
  return failed
end

return M
