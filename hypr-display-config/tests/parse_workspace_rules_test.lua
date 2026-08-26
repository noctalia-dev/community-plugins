-- tests/parse_workspace_rules_test.lua
local fixture = "workspacerules-fixture"

noctalia = {
  json = {
    decode = function(text)
      assert(text == fixture)
      return {
        { workspaceString = "5", monitor = "eDP-1", enabled = true },
        { workspaceString = "2", monitor = "HEADLESS-1", enabled = true },
        { workspaceString = "special:scratch", monitor = "eDP-1", enabled = true },
      }
    end,
  },
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
  setUpdateInterval = function() end,
  notifyError = function() end,
  tr = function(key) return key end,
}

assert(loadfile("service.luau"))()

local bindings = parseWorkspaceRules(fixture)
assert(#bindings == 2, "named workspace rule should be skipped, got " .. tostring(#bindings))
local byId = {}
for _, binding in ipairs(bindings) do byId[binding.workspace] = binding.monitor end
assert(byId[5] == "eDP-1", "workspace 5 binding mismatch")
assert(byId[2] == "HEADLESS-1", "workspace 2 binding mismatch")

print("parse_workspace_rules_test: ok")
