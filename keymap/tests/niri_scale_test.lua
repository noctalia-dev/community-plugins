local bindLines = { "binds {" }
for index = 1, 93 do
  if index % 20 == 1 then
    bindLines[#bindLines + 1] = '    // #"Group ' .. tostring(math.floor(index / 20) + 1) .. '"'
  end
  bindLines[#bindLines + 1] = string.format(
    '    Mod+Key%d repeat=false cooldown-ms=150 { focus-workspace %d; }', index, index
  )
end
bindLines[#bindLines + 1] = "}"
local source = table.concat(bindLines, "\n")

local values, watchers = {
  ["keymap.snapshot"] = {
    status = "ready", compositor = "Niri", total = 1,
    categories = { { name = "Previous", binds = { { id = "previous" } } } },
  },
}, {}
local reads = 0
local xorCalls = 0
local loadingCategoryCount = -1
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
    return ({ compositor = "niri", niri_config = "/fixture/config.kdl", merge_sequential = false })[key]
  end,
  getenv = function(key) return key == "NIRI_SOCKET" and "test" or "" end,
  fileExists = function(path) return path == "/fixture/config.kdl" end,
  listDir = function() return nil end,
  readFile = function(path)
    if path ~= "/fixture/config.kdl" then return nil end
    reads = reads + 1
    return source
  end,
  tr = function(key, args)
    if args ~= nil and args.action ~= nil then return args.action end
    return key == "category.other" and "Other" or key
  end,
}

assert(loadfile("niri_service.luau"))()
-- The parser yields between slices; pump update ticks until it settles.
local pumps = 0
while values["keymap.snapshot"].status == "loading" and pumps < 100 do
  update()
  pumps = pumps + 1
end
bit32 = originalBit32

local snapshot = values["keymap.snapshot"]
assert(snapshot.status == "ready", "large Niri fixture did not parse")
assert(snapshot.total == 93, "large Niri fixture lost binds")
assert(#snapshot.categories == 5, "large Niri fixture lost category markers")
assert(reads == 1, "Niri root config should only be read once per refresh")
assert(loadingCategoryCount == 0, "loading snapshot should not reserialize the previous bind tree")
assert(xorCalls == 0, "Niri visible binds still use per-character fingerprinting")

local seenIds = {}
for _, category in ipairs(snapshot.categories) do
  for _, bind in ipairs(category.binds) do
    assert(bind.id:match("^niri:"), "invalid Niri bind ID")
    assert(not seenIds[bind.id], "duplicate Niri bind ID")
    assert(bind.fingerprint == "exact-v1", "Niri bind did not use exact source verification")
    seenIds[bind.id] = true
  end
end

print("niri scale tests: ok")
