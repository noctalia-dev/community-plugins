local sourceLines = {}
for index = 1, 120 do
  if index % 20 == 1 then
    sourceLines[#sourceLines + 1] = "# Group " .. tostring(math.floor(index / 20) + 1)
  end
  sourceLines[#sourceLines + 1] = string.format(
    'bind=SUPER,Key%d,spawn_shell,true #"Action %d"', index, index
  )
end
local source = table.concat(sourceLines, "\n")

local values, watchers = {
  ["keymap.snapshot"] = {
    status = "ready", compositor = "MangoWC", total = 1,
    categories = { { name = "Previous", binds = { { id = "previous" } } } },
  },
}, {}
local reads, xorCalls, loadingCategoryCount = 0, 0, -1
local originalBit32 = bit32
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
      if key == "keymap.snapshot" and value.status == "loading" then
        loadingCategoryCount = #(value.categories or {})
      end
      values[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  getConfig = function(key)
    return ({ compositor = "mangowc", mangowc_config = "/fixture/config.conf", merge_sequential = false })[key]
  end,
  getenv = function(key) return key == "MANGO_INSTANCE_SIGNATURE" and "test" or "" end,
  expandPath = function(path) return path end,
  fileExists = function(path) return path == "/fixture/config.conf" end,
  listDir = function() return nil end,
  readFile = function(path)
    if path ~= "/fixture/config.conf" then return nil end
    reads = reads + 1
    return source
  end,
  tr = function(key, args)
    if args ~= nil and args.action ~= nil then return args.action end
    return key == "category.other" and "Other" or key
  end,
}

local instructionBlocks = 0
debug.sethook(function() instructionBlocks = instructionBlocks + 1 end, "", 1000)
assert(loadfile("mangowc_service.luau"))()
debug.sethook()
bit32 = originalBit32

local snapshot = values["keymap.snapshot"]
assert(snapshot.status == "ready", "large MangoWC fixture did not parse")
assert(snapshot.total == 120, "large MangoWC fixture lost binds")
assert(#snapshot.categories == 6, "large MangoWC fixture lost category markers")
assert(reads == 1, "MangoWC root config should only be read once per refresh")
assert(loadingCategoryCount == 0, "loading snapshot should not reserialize the previous bind tree")
assert(xorCalls == 0, "MangoWC visible binds still use per-character fingerprinting")
assert(instructionBlocks < 250, "MangoWC parser exceeded its regression instruction budget")

local seenIds = {}
for _, category in ipairs(snapshot.categories) do
  for _, bind in ipairs(category.binds) do
    assert(bind.id:match("^mango:"), "invalid MangoWC bind ID")
    assert(not seenIds[bind.id], "duplicate MangoWC bind ID")
    assert(bind.fingerprint == "exact-v1", "MangoWC bind did not use exact source verification")
    seenIds[bind.id] = true
  end
end

print(string.format("MangoWC scale tests: ok (%d blocks)", instructionBlocks))
