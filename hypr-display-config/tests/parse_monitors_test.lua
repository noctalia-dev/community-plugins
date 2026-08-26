-- tests/parse_monitors_test.lua
local fixture = [[
[
  {"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"scale":1.5,
   "transform":0,"refreshRate":60.033,"disabled":false,
   "availableModes":["1920x1080@60.03Hz","1920x1080@48.03Hz"]},
  {"name":"HEADLESS-1","width":1280,"height":720,"x":1280,"y":0,"scale":1,
   "transform":0,"refreshRate":60.0,"disabled":true,
   "availableModes":["1280x720@60.00Hz"]}
]
]]

noctalia = {
  json = {
    decode = function(text)
      assert(text == fixture, "decode called with unexpected text")
      return {
        { name = "eDP-1", width = 1920, height = 1080, x = 0, y = 0,
          scale = 1.5, transform = 0, refreshRate = 60.033, disabled = false,
          availableModes = { "1920x1080@60.03Hz", "1920x1080@48.03Hz" } },
        { name = "HEADLESS-1", width = 1280, height = 720, x = 1280, y = 0,
          scale = 1, transform = 0, refreshRate = 60.0, disabled = true,
          availableModes = { "1280x720@60.00Hz" } },
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

_G.__PARSE_MONITORS_TEST_FIXTURE = fixture

assert(loadfile("service.luau"))()

local monitors = parseMonitors(fixture)
assert(#monitors == 2, "expected 2 monitors, got " .. tostring(#monitors))
assert(monitors[1].name == "eDP-1", "monitor 1 name mismatch")
assert(monitors[1].scale == 1.5, "monitor 1 scale mismatch")
assert(monitors[1].disabled == false, "monitor 1 should be enabled")
assert(#monitors[1].availableModes == 2, "monitor 1 availableModes count mismatch")
assert(monitors[2].name == "HEADLESS-1", "monitor 2 name mismatch")
assert(monitors[2].disabled == true, "monitor 2 should be disabled")

print("parse_monitors_test: ok")
