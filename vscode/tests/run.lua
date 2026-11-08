-- Run from the repo root with any Lua 5.x:  lua vscode/tests/run.lua
--
-- Runs every tests/spec_*.lua. Pure modules are loaded from source with the
-- Luau `--!nonstrict` line stripped; `require("./x.luau")` inside them maps to
-- loadModule("x.luau"). Spec globals: eq, check, fixture, loadModule, json,
-- stubs.

local function scriptDir()
  local path = (arg and arg[0] or "run.lua")
  local dir = path:gsub("tests/run%.lua$", "")
  if dir == path then
    return "./"
  end
  return dir
end

local DIR = scriptDir()

package.path = DIR .. "tests/?.lua;" .. package.path

-- Lua 5.1 loads a string only through loadstring; 5.2+ has load for both.
local chunkLoader = loadstring or load

local function readAll(path)
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return text
end

local cache = {}

function loadModule(relative)
  if cache[relative] == nil then
    local src = readAll(DIR .. relative)
    src = src:gsub("^%-%-!%S+%s*\n", "")
    cache[relative] = { value = assert(chunkLoader(src, "@" .. relative))() }
  end
  return cache[relative].value
end

-- Fresh copy of a module (for service.luau, which reads the noctalia global at load).
function loadFresh(relative)
  cache[relative] = nil
  return loadModule(relative)
end

function require(path)
  local name = path:match("^%./(.+%.luau)$")
  if not name then
    error("test require shim: unsupported path " .. tostring(path), 2)
  end
  return loadModule(name)
end

function fixture(name)
  return readAll(DIR .. "tests/fixtures/" .. name)
end

json = dofile(DIR .. "tests/json.lua")
stubs = dofile(DIR .. "tests/stubs.lua")

local passed, failed = 0, 0

function check(name, cond)
  if cond then
    passed = passed + 1
    print("ok    " .. name)
  else
    failed = failed + 1
    print("FAIL  " .. name)
  end
end

function eq(name, actual, expected)
  local good = actual == expected
  if good then
    passed = passed + 1
    print("ok    " .. name .. " (" .. tostring(actual) .. ")")
  else
    failed = failed + 1
    print("FAIL  " .. name .. " (got " .. tostring(actual) .. ", want " .. tostring(expected) .. ")")
  end
end

local specs = {}
local listing = io.popen('ls "' .. DIR .. 'tests/" 2>/dev/null')
for name in listing:lines() do
  if name:match("^spec_.+%.lua$") then
    specs[#specs + 1] = name
  end
end
listing:close()
table.sort(specs)

for _, name in ipairs(specs) do
  print("== " .. name)
  local ok, err = pcall(dofile, DIR .. "tests/" .. name)
  if not ok then
    failed = failed + 1
    print("FAIL  " .. name .. " crashed: " .. tostring(err))
  end
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
