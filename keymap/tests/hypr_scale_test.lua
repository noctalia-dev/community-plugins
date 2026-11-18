local sourceLines = {}
local liveBinds = {}
for index = 1, 93 do
  if index % 20 == 1 then
    sourceLines[#sourceLines + 1] = "-- " .. tostring(math.floor(index / 20) + 1) .. ". Group "
      .. tostring(math.floor(index / 20) + 1)
  end
  sourceLines[#sourceLines + 1] = string.format(
    'hl.bind("SUPER+Key%d", action, { description = "Action %d" })', index, index
  )
  liveBinds[#liveBinds + 1] = {
    modmask = 64, key = "Key" .. tostring(index), description = "Action " .. tostring(index),
    has_description = true, dispatcher = "__lua", arg = tostring(index), submap = "",
  }
end
local source = table.concat(sourceLines, "\n")

local values, watchers = {
  ["keymap.snapshot"] = {
    status = "ready", compositor = "Hyprland", total = 1,
    categories = { { name = "Previous", binds = { { id = "previous" } } } },
  },
}, {}
local reads, loadingCategoryCount = 0, -1

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
    return ({
      compositor = "hyprland", hyprland_config = "/fixture/hyprland.lua",
      merge_sequential = false, show_undescribed = true,
    })[key]
  end,
  getenv = function(key) return key == "HYPRLAND_INSTANCE_SIGNATURE" and "test" or "" end,
  expandPath = function(path) return path end,
  fileExists = function(path) return path == "/fixture/hyprland.lua" end,
  listDir = function() return nil end,
  readFile = function(path)
    if path ~= "/fixture/hyprland.lua" then return nil end
    reads = reads + 1
    return source
  end,
  commandExists = function(command) return command == "hyprctl" end,
  json = { decode = function() return liveBinds end },
  runAsync = function(command, callback)
    callback({ exitCode = 0, timedOut = false, stdout = "fixture" })
    return true
  end,
  tr = function(key) return key == "category.other" and "Other" or key end,
}

assert(loadfile("service.luau"))()

local snapshot = values["keymap.snapshot"]
assert(snapshot.status == "ready", "large Hyprland fixture did not parse")
assert(snapshot.total == 93, "large Hyprland fixture lost binds")
assert(#snapshot.categories == 5, "large Hyprland fixture lost category markers")
assert(reads == 1, "Hyprland root config should only be read once per refresh")
assert(loadingCategoryCount == 0, "loading snapshot should not reserialize the previous bind tree")
local seenIds = {}
for _, category in ipairs(snapshot.categories) do
  for _, bind in ipairs(category.binds) do
    assert(bind.id:match("^hypr:"), "invalid Hyprland bind ID")
    assert(not seenIds[bind.id], "duplicate Hyprland bind ID")
    seenIds[bind.id] = true
  end
end

print("hypr scale tests: ok")
