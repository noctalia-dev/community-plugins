-- tests/compute_positions_test.lua
noctalia = {
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  writeFile = function() return true end,
  readFile = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
}

assert(loadfile("writer_service.luau"))()

local monitorsByName = {
  ["eDP-1"] = { width = 1920, height = 1080, scale = 1.5 },
  ["HEADLESS-1"] = { width = 1280, height = 720, scale = 1 },
  ["DP-2"] = { width = 2560, height = 1440, scale = 2 },
}

local positions = computePositions({ "eDP-1", "HEADLESS-1", "DP-2" }, monitorsByName)

assert(positions["eDP-1"].x == 0, "first monitor x should be 0")
assert(positions["eDP-1"].y == 0)
-- 1920 / 1.5 = 1280
assert(positions["HEADLESS-1"].x == 1280, "got " .. tostring(positions["HEADLESS-1"].x))
-- 1280 + 1280 / 1 = 2560
assert(positions["DP-2"].x == 2560, "got " .. tostring(positions["DP-2"].x))

print("compute_positions_test: ok")
