local rootLines = {}
for index = 1, 420 do
  rootLines[#rootLines + 1] = "// Stock Niri configuration documentation line " .. tostring(index)
end
rootLines[#rootLines + 1] = "binds {"
for index = 1, 114 do
  rootLines[#rootLines + 1] = string.format(
    "    Mod+Key%d repeat=false { focus-workspace %d; }", index, index
  )
end
rootLines[#rootLines + 1] = "}"
rootLines[#rootLines + 1] = 'include "mine/binds.kdl"'
rootLines[#rootLines + 1] = 'include optional=true "mine/debug.kdl"'
rootLines[#rootLines + 1] = 'include "mine/theme.kdl"'

local includeLines = { "binds {" }
for index = 115, 126 do
  includeLines[#includeLines + 1] = string.format(
    '    Mod+Key%d hotkey-overlay-title="Included %d" { focus-workspace %d; }',
    index, index, index
  )
end
includeLines[#includeLines + 1] = "}"

local sources = {
  ["/fixture/config.kdl"] = table.concat(rootLines, "\n"),
  ["/fixture/mine/binds.kdl"] = table.concat(includeLines, "\n"),
  ["/fixture/mine/debug.kdl"] = "binds {\n    Mod+Key127 { toggle-debug-tint; }\n}",
  ["/fixture/mine/theme.kdl"] = string.rep("// unrelated theme setting\n", 500),
}

local values, watchers = {}, {}
local reads = {}
local xorCalls = 0
local stringSubCalls = 0
local originalBit32 = bit32
local originalStringSub = string.sub
string.sub = function(...)
  stringSubCalls = stringSubCalls + 1
  return originalStringSub(...)
end
bit32 = {
  bxor = function(left, right)
    xorCalls = xorCalls + 1
    local result, place = 0, 1
    for _ = 1, 8 do
      if left % 2 ~= right % 2 then result = result + place end
      left = math.floor(left / 2)
      right = math.floor(right / 2)
      place = place * 2
    end
    return result
  end,
}

noctalia = {
  state = {
    get = function(key) return values[key] end,
    set = function(key, value)
      values[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  getConfig = function(key)
    return ({
      compositor = "niri", niri_config = "/fixture/config.kdl", merge_sequential = false,
    })[key]
  end,
  getenv = function(key) return key == "NIRI_SOCKET" and "test" or "" end,
  fileExists = function(path) return path == "/fixture/config.kdl" end,
  listDir = function() return nil end,
  readFile = function(path)
    reads[path] = (reads[path] or 0) + 1
    return sources[path]
  end,
  tr = function(key, args)
    if args ~= nil and args.action ~= nil then return args.action end
    return key == "category.other" and "Other" or key
  end,
}

local instructionBlocks = 0
debug.sethook(function() instructionBlocks = instructionBlocks + 1 end, "", 1000)
assert(loadfile("niri_service.luau"))()
-- The parser yields to stay inside each callback's CPU budget; the host's
-- update timer resumes it. Pump ticks until the snapshot settles.
local pumps = 0
while values["keymap.snapshot"].status == "loading" and pumps < 40 do
  update()
  pumps = pumps + 1
end
debug.sethook()
bit32 = originalBit32
string.sub = originalStringSub

local snapshot = values["keymap.snapshot"]
assert(snapshot.status == "ready", "large, split Niri fixture did not parse")
assert(snapshot.total == 127, "large, split Niri fixture lost binds")
assert(reads["/fixture/config.kdl"] == 1, "Niri root config should only be read once")
assert(reads["/fixture/mine/binds.kdl"] == 1, "Niri bind include should only be read once")
assert(reads["/fixture/mine/debug.kdl"] == 1, "Niri optional include should only be read once")
assert(reads["/fixture/mine/theme.kdl"] == 1, "Niri non-bind include should only be read once")
assert(xorCalls == 0, "Niri visible binds still use per-character fingerprinting")
assert(instructionBlocks < 700, "Niri parser exceeded its regression instruction budget")
assert(
  stringSubCalls < 45000,
  "Niri parser scanned an unrelated include character by character: " .. tostring(stringSubCalls)
)

print(string.format("niri CPU-budget regression tests: ok (%d blocks)", instructionBlocks))
