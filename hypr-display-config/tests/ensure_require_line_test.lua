-- tests/ensure_require_line_test.lua
noctalia = {
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  writeFile = function() return true end,
  readFile = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
}

assert(loadfile("writer_service.luau"))()

local requireLine = 'require("hypr-display-config")'

-- Case 1: line absent, gets appended with a trailing newline preserved
local original = 'require("config.monitors")\n'
local updated = ensureRequireLine(original, requireLine)
assert(updated == 'require("config.monitors")\n' .. requireLine .. '\n',
  "unexpected result:\n" .. updated)

-- Case 2: line already present, text unchanged
local alreadyThere = 'require("config.monitors")\n' .. requireLine .. '\n'
local unchanged = ensureRequireLine(alreadyThere, requireLine)
assert(unchanged == alreadyThere, "should be idempotent")

-- Case 3: file has no trailing newline
local noTrailingNewline = 'require("config.monitors")'
local withNewlineAdded = ensureRequireLine(noTrailingNewline, requireLine)
assert(withNewlineAdded == 'require("config.monitors")\n' .. requireLine .. '\n',
  "unexpected result:\n" .. withNewlineAdded)

print("ensure_require_line_test: ok")
