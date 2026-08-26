-- tests/build_snapshot_test.lua
noctalia = {
  json = { decode = function() return {} end },
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
  setUpdateInterval = function() end,
  notifyError = function() end,
  tr = function(key) return key end,
}

assert(loadfile("service.luau"))()

local monitors = {
  { name = "HEADLESS-1", width = 1280, height = 720, x = 1280, y = 0,
    scale = 1, transform = 0, refreshRate = 60, availableModes = {}, disabled = false },
  { name = "eDP-1", width = 1920, height = 1080, x = 0, y = 0,
    scale = 1.5, transform = 0, refreshRate = 60.03,
    availableModes = { "1920x1080@60.03Hz", "1920x1080@59.94Hz" }, disabled = false },
}
local bindings = {
  { workspace = 3, monitor = "eDP-1" },
  { workspace = 1, monitor = "eDP-1" },
  { workspace = 2, monitor = "HEADLESS-1" },
}

local snapshot = buildSnapshot(monitors, bindings, 4)

assert(snapshot.status == "ready", "status should be ready")
assert(#snapshot.monitors == 2, "expected 2 monitors in snapshot")
assert(snapshot.monitors[1].name == "eDP-1", "eDP-1 (x=0) should sort first, got " .. snapshot.monitors[1].name)
assert(snapshot.monitors[2].name == "HEADLESS-1", "HEADLESS-1 (x=1280) should sort second")
assert(#snapshot.monitors[1].workspaces == 2, "eDP-1 should have 2 bound workspaces")
assert(snapshot.monitors[1].workspaces[1] == 1, "eDP-1 workspaces should be sorted ascending")
assert(snapshot.monitors[1].workspaces[2] == 3, "eDP-1 workspaces should be sorted ascending")
assert(#snapshot.monitors[2].workspaces == 1, "HEADLESS-1 should have 1 bound workspace")
assert(snapshot.monitors[2].workspaces[1] == 2, "HEADLESS-1 workspace mismatch")
assert(#snapshot.unboundWorkspaces == 1, "workspace 4 should be unbound")
assert(snapshot.unboundWorkspaces[1] == 4, "unbound workspace id mismatch")

assert(snapshot.monitors[1].mode == "1920x1080@60.03Hz",
  "eDP-1 mode should match its availableModes entry, got " .. tostring(snapshot.monitors[1].mode))
assert(snapshot.monitors[2].mode == "preferred",
  "HEADLESS-1 has no matching availableModes entry, should fall back to preferred, got "
    .. tostring(snapshot.monitors[2].mode))

print("build_snapshot_test: ok")
