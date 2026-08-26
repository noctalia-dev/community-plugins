-- tests/render_managed_file_test.lua
noctalia = {
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  writeFile = function() return true end,
  readFile = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
}

assert(loadfile("writer_service.luau"))()

local monitors = {
  { name = "eDP-1", x = 0, y = 0, scale = 1.5, transform = 0,
    mode = "1920x1080@60.00Hz", disabled = false, workspaces = { 1, 3 } },
  { name = "HEADLESS-1", x = 1280, y = 0, scale = 1, transform = 0,
    mode = "preferred", disabled = false, workspaces = { 2 } },
}

local rendered = renderManagedFile(monitors)

assert(rendered:find('hl.monitor({ output = "eDP-1", mode = "1920x1080@60.00Hz", position = "0x0", scale = 1.5, transform = 0, disabled = false })', 1, true) ~= nil,
  "eDP-1 monitor line missing or malformed:\n" .. rendered)
assert(rendered:find('hl.monitor({ output = "HEADLESS-1", mode = "preferred", position = "1280x0", scale = 1, transform = 0, disabled = false })', 1, true) ~= nil,
  "HEADLESS-1 monitor line missing or malformed:\n" .. rendered)
assert(rendered:find('hl.workspace_rule({ workspace = "1", monitor = "eDP-1" })', 1, true) ~= nil)
assert(rendered:find('hl.workspace_rule({ workspace = "3", monitor = "eDP-1" })', 1, true) ~= nil)
assert(rendered:find('hl.workspace_rule({ workspace = "2", monitor = "HEADLESS-1" })', 1, true) ~= nil)

print("render_managed_file_test: ok")
