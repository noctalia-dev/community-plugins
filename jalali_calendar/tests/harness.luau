--!nonstrict
-- Minimal assertion harness. No dependencies; runs under the `luau` CLI.
--
-- State is module-level and every spec requires this file, so all specs share
-- one instance via require's module cache. If report() ever prints 0 checks
-- while specs clearly ran, that cache is not happening.

local M = {}

local failures = 0
local checks = 0
local current = "(top level)"

function M.describe(name: string, fn: () -> ())
  current = name
  fn()
end

local function fail(label: string, detail: string)
  failures += 1
  print(`FAIL  [{current}] {label}: {detail}`)
end

function M.eq(actual, expected, label: string)
  checks += 1
  if actual ~= expected then
    fail(label, `expected {tostring(expected)}, got {tostring(actual)}`)
  end
end

function M.ok(value, label: string)
  checks += 1
  if not value then
    fail(label, `expected truthy, got {tostring(value)}`)
  end
end

function M.throws(fn: () -> (), label: string)
  checks += 1
  local success = pcall(fn)
  if success then
    fail(label, "expected an error, but the call succeeded")
  end
end

function M.report(): number
  if failures == 0 then
    print(`PASS  {checks} checks`)
    return 0
  end
  print(`\n{failures} failure(s) out of {checks} checks`)
  return 1
end

return M
