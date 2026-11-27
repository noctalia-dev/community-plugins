-- Detached argv launching: mocks only, no real application or phone commands.
dofile("tests/test_runtime.lua")
local watch, argv, executable, errors, launches = {}, nil, "", 0, 0
local succeeds = true
noctalia = {
  getConfig = function(key)
    if key == "executable" then
      return executable
    end
  end,
  json = {
    decode = function(v)
      return v
    end,
    encode = function(v)
      return v
    end,
  },
  state = {
    watch = function(k, cb)
      watch[k] = cb
    end,
  },
  runAsync = function(...)
    assert(select("#", ...) == 1, "detached launch must have no callback or timeout")
    argv = ...
    launches = launches + 1
    return succeeds
  end,
  notifyError = function()
    errors = errors + 1
  end,
}
dofile("service.luau")
local function command(action)
  watch["nl.command"]({ action = action })
end
command("open")
assert(#argv == 1 and argv[1] == "nectarlink-desktop")
executable = "/home/Other User/Apps/NectarLink;literal"
command("timeline")
assert(#argv == 3 and argv[1] == executable and argv[2] == "--task" and argv[3] == "open-timeline")
executable = "./relative/path"
command("open")
assert(launches == 2 and errors == 1)
executable = ""
succeeds = false
command("open")
assert(launches == 3 and errors == 2)
assert(#argv == 1, "failed launch must not retry")
print(
  "PASS: detached argv, spaces/metacharacters, relative path rejection, launch failure, no retry"
)
