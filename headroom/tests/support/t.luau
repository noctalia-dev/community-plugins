--!nonstrict
-- A tiny test framework: t.test(name, fn), t.eq / t.ok / t.near, t.run().

local M = {}

local tests = {}
local currentGroup = ""

function M.group(name: string, fn: () -> ())
  local previous = currentGroup
  currentGroup = if previous == "" then name else `{previous} › {name}`
  fn()
  currentGroup = previous
end

function M.test(name: string, fn: () -> ())
  table.insert(tests, { name = if currentGroup == "" then name else `{currentGroup} › {name}`, fn = fn })
end

local function show(v): string
  if type(v) == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end

function M.eq(actual, expected, label: string?)
  if actual ~= expected then
    error(`{label or "value"}: expected {show(expected)}, got {show(actual)}`, 2)
  end
end

function M.ok(value, label: string?)
  if not value then
    error(`{label or "assertion"} failed`, 2)
  end
end

function M.near(actual: number, expected: number, tolerance: number, label: string?)
  if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
    error(`{label or "value"}: expected ~{expected}, got {show(actual)}`, 2)
  end
end

function M.contains(list, expected, label: string?)
  for _, v in list do
    if v == expected then
      return
    end
  end
  error(`{label or "list"}: {show(expected)} not found in \{{table.concat(list, ", ")}}`, 2)
end

function M.run(): number
  local failed = 0
  for _, case in tests do
    local ok, err = pcall(case.fn)
    if ok then
      print(`  ✓ {case.name}`)
    else
      failed += 1
      print(`  ✗ {case.name}\n      {err}`)
    end
  end
  print(`\n{#tests - failed} passed, {failed} failed`)
  return failed
end

return M
