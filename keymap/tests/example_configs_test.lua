local function read(path)
  local file = assert(io.open(path, "rb"))
  local value = file:read("*a")
  file:close()
  return value
end

local function stateMock()
  local values, watchers = {}, {}
  return values, {
    get = function(key) return values[key] end,
    set = function(key, value)
      values[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
  }
end

local function assertExample(snapshot, compositor, expectedTotal)
  assert(type(snapshot) == "table" and snapshot.status == "ready", compositor .. ": snapshot not ready")
  assert(snapshot.compositor == compositor, compositor .. ": wrong compositor")
  assert(snapshot.total == expectedTotal, compositor .. ": unexpected bind count " .. tostring(snapshot.total))
  local expected = {
    ["Applications"] = true,
    ["Windows"] = true,
    ["Workspaces"] = true,
    ["Screenshots"] = true,
    ["Noctalia"] = true,
    ["Media"] = true,
    ["Utilities"] = true,
  }
  local found = {}
  for _, category in ipairs(snapshot.categories or {}) do
    found[category.name] = true
    for _, bind in ipairs(category.binds or {}) do
      assert(type(bind.id) == "string" and bind.id ~= "", compositor .. ": bind id missing")
      assert(#bind.id <= 249, compositor .. ": bind id exceeds DnD target budget")
      assert(#("before|" .. bind.id) <= 256, compositor .. ": reorder target exceeds core limit")
    end
  end
  for name, _ in pairs(expected) do
    assert(found[name], compositor .. ": missing category " .. name)
  end
end

do
  local values, state = stateMock()
  local source = read("examples/hyprland.lua")
  local descriptions = {}
  local modifierMasks = { SUPER = 64, SHIFT = 1, CTRL = 4, ALT = 8 }
  for line in source:gmatch("[^\r\n]+") do
    local combo = line:match('hl%.bind%s*%(%s*"([^"]+)"')
    local description = line:match('description%s*=%s*"([^"]+)"')
    if combo ~= nil and description ~= nil then
      local modmask, key = 0, nil
      for token in combo:gmatch("[^+]+") do
        local normalized = token:match("^%s*(.-)%s*$")
        local mask = modifierMasks[normalized:upper()]
        if mask ~= nil then modmask = modmask + mask else key = normalized end
      end
      assert(key ~= nil, "Hyprland example bind has no non-modifier key: " .. combo)
      descriptions[#descriptions + 1] = {
        modmask, key, description, line:match("release%s*=%s*true") ~= nil,
      }
    end
  end
  local plainBlocks = {}
  for index, item in ipairs(descriptions) do
    plainBlocks[#plainBlocks + 1] = table.concat({
      item[4] == true and "bindrd" or "bindd",
      "\tmodmask: " .. tostring(item[1]),
      "\tsubmap: ",
      "\tkey: " .. item[2],
      "\tkeycode: 0",
      "\tcatchall: false",
      "\tdescription: " .. item[3],
      "\tdispatcher: __lua",
      "\targ: " .. tostring(index),
    }, "\n")
  end
  local plain = table.concat(plainBlocks, "\n\n") .. "\n"
  noctalia = {
    state = state,
    getConfig = function(key)
      local config = {
        compositor = "hyprland", hyprland_config = "/missing/hyprland.lua",
        merge_sequential = false, show_undescribed = true,
      }
      return config[key]
    end,
    getenv = function(key)
      if key == "HYPRLAND_INSTANCE_SIGNATURE" then return "test" end
      if key == "HOME" then return "/example-home" end
      return ""
    end,
    expandPath = function(path) return path end,
    fileExists = function(path) return path == "/example-home/.config/hypr/shortcuts.lua" end,
    listDir = function(path)
      return path == "/example-home/.config/hypr"
        and { "colors.lua", "keymap.lua", "old.lua.backup", "shortcuts.lua" } or nil
    end,
    readFile = function(path) return path == "/example-home/.config/hypr/shortcuts.lua" and source or nil end,
    commandExists = function(command) return command == "hyprctl" end,
    tr = function(key)
      return ({ ["category.other"] = "Other", ["category.undescribed"] = "Without description" })[key] or key
    end,
    runAsync = function(command, callback)
      callback({ exitCode = 0, timedOut = false, stdout = command == "hyprctl binds" and plain or "invalid-json" })
      return true
    end,
    json = { decode = function() error("malformed JSON fixture") end },
  }
  assert(loadfile("service.luau"))()
  assertExample(values["keymap.snapshot"], "Hyprland", 40)
  assert(values["keymap.snapshot"].source == "/example-home/.config/hypr/shortcuts.lua")
end

do
  local values, state = stateMock()
  local source = read("examples/niri.kdl")
  noctalia = {
    state = state,
    getConfig = function(key)
      local config = { compositor = "niri", niri_config = "/missing/niri.kdl", merge_sequential = false }
      return config[key]
    end,
    getenv = function(key)
      if key == "NIRI_SOCKET" then return "test" end
      if key == "HOME" then return "/example-home" end
      return ""
    end,
    fileExists = function(path) return path == "/example-home/.config/niri/config.kdl" end,
    readFile = function(path) return path == "/example-home/.config/niri/config.kdl" and source or nil end,
    tr = function(key) return key == "category.other" and "Other" or key end,
  }
  assert(loadfile("niri_service.luau"))()
  assertExample(values["keymap.snapshot"], "Niri", 39)
  assert(values["keymap.snapshot"].source == "/example-home/.config/niri/config.kdl")
end

do
  local values, state = stateMock()
  local source = read("examples/mangowc.conf")
  noctalia = {
    state = state,
    getConfig = function(key)
      local config = { compositor = "mangowc", mangowc_config = "/missing/mangowc.conf", merge_sequential = false }
      return config[key]
    end,
    getenv = function(key)
      if key == "MANGO_INSTANCE_SIGNATURE" then return "test" end
      if key == "HOME" then return "/example-home" end
      return ""
    end,
    expandPath = function(path) return path end,
    fileExists = function(path) return path == "/example-home/.config/mango/config.conf" end,
    readFile = function(path) return path == "/example-home/.config/mango/config.conf" and source or nil end,
    tr = function(key) return key == "category.other" and "Other" or key end,
  }
  assert(loadfile("mangowc_service.luau"))()
  assertExample(values["keymap.snapshot"], "MangoWC", 40)
  assert(values["keymap.snapshot"].source == "/example-home/.config/mango/config.conf")
end

print("example config tests: ok")
