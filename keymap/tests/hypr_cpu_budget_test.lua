local rootPath = "/fixture/hypr/hyprland.lua"
local files = {}

local rootLines = {
  "-- Hyprland configuration",
  'require("keybind")',
  'require("colors")',
  'require("noctalia").apply_theme()',
  'require("keymap")',
}
for index = 1, 120 do
  rootLines[#rootLines + 1] = string.format("hl.config({ value_%d = %d })", index, index)
end
files[rootPath] = table.concat(rootLines, "\n")

local bindLines, bindDescriptions = {}, {}
for index = 1, 120 do
  if index % 15 == 1 then
    bindLines[#bindLines + 1] = "-- " .. tostring(math.floor(index / 15) + 1) .. ". Group"
  end
  local description = "Action " .. tostring(index)
  bindDescriptions[#bindDescriptions + 1] = description
  bindLines[#bindLines + 1] = string.format(
    'hl.bind("SUPER + Key%d", hl.dsp.exec_cmd("command-%d"), { description = "%s" })',
    index, index, description
  )
end
files["/fixture/hypr/keybind.lua"] = table.concat(bindLines, "\n")

local unrelated = {}
for index = 1, 100 do
  unrelated[#unrelated + 1] = string.format("local value_%d = %d", index, index)
end
files["/fixture/hypr/colors.lua"] = table.concat(unrelated, "\n")
files["/fixture/hypr/noctalia.lua"] = table.concat(unrelated, "\n")
files["/fixture/hypr/keymap.lua"] = table.concat({
  "-- Managed by Noctalia Keymap.",
  "-- 5. Managed",
  'hl.bind("CTRL + grave", hl.dsp.exec_cmd("managed-command"), { description = "Managed action" })',
}, "\n")
bindDescriptions[#bindDescriptions + 1] = "Managed action"

local textRecords = {}
for index, description in ipairs(bindDescriptions) do
  textRecords[#textRecords + 1] = table.concat({
    "bindd",
    "\tmodmask: 64",
    "\tsubmap: ",
    "\tkey: Key" .. tostring(index),
    "\tkeycode: 0",
    "\tcatchall: false",
    "\tdescription: " .. description,
    "\tdispatcher: __lua",
    "\targ: " .. tostring(index),
    "",
  }, "\n")
end
local textOutput = table.concat(textRecords, "\n")

local values, watchers = {}, {}
local instructionBlocks, firstAsyncInstructionBlocks = 0, nil
noctalia = {
  getConfig = function(key)
    return ({
      compositor = "hyprland",
      hyprland_config = rootPath,
      merge_sequential = false,
      show_undescribed = true,
    })[key]
  end,
  getenv = function(key) return key == "HYPRLAND_INSTANCE_SIGNATURE" and "fixture" or "" end,
  expandPath = function(path) return path end,
  fileExists = function(path) return files[path] ~= nil end,
  listDir = function() return nil end,
  readFile = function(path) return files[path] end,
  commandExists = function(command) return command == "hyprctl" end,
  json = { decode = function() error("Hyprland emitted invalid JSON") end },
  runAsync = function(command, callback)
    if firstAsyncInstructionBlocks == nil then firstAsyncInstructionBlocks = instructionBlocks end
    callback({
      exitCode = 0,
      timedOut = false,
      stdout = command == "hyprctl binds -j" and "{invalid-json" or textOutput,
    })
    return true
  end,
  tr = function(key)
    if key == "category.other" then return "Other" end
    if key == "category.undescribed" then return "Without description" end
    return key
  end,
  state = {
    get = function(key) return values[key] end,
    set = function(key, value)
      values[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    watch = function(key, callback) watchers[key] = callback end,
  },
}

debug.sethook(function() instructionBlocks = instructionBlocks + 1 end, "", 1000)
assert(loadfile("service.luau"))()
debug.sethook()
local initialInstructionBlocks = instructionBlocks
instructionBlocks, firstAsyncInstructionBlocks = 0, nil
debug.sethook(function() instructionBlocks = instructionBlocks + 1 end, "", 1000)
watchers["keymap.refresh_request"](1)
debug.sethook()
local refreshInstructionBlocks = instructionBlocks
local refreshScanInstructionBlocks = firstAsyncInstructionBlocks

local snapshot = values["keymap.snapshot"]
assert(snapshot.status == "ready", "split Hyprland fallback did not publish a ready snapshot")
assert(snapshot.total == #bindDescriptions, "split Hyprland fallback lost binds")

local editable = 0
for _, category in ipairs(snapshot.categories or {}) do
  for _, bind in ipairs(category.binds or {}) do
    if bind.capabilities ~= nil and bind.capabilities.combo == true
      and bind.capabilities.description == true and bind.capabilities.command == true
      and bind.source ~= nil and bind.raw_snippet ~= nil and bind.fingerprint == "exact-v1" then
      editable = editable + 1
    end
  end
end
assert(editable == #bindDescriptions, "literal Hyprland binds did not retain editable source provenance")
assert(refreshScanInstructionBlocks < 50, "Hyprland source scan exceeded its callback instruction budget")
assert(refreshInstructionBlocks < 150, "Hyprland refresh exceeded its regression instruction budget")
assert(refreshScanInstructionBlocks ~= nil, "Hyprland parser did not start the live bind request")

print(string.format(
  "hypr CPU-budget regression tests: ok (%d initial / %d refresh scan / %d refresh total blocks, %d editable binds)",
  initialInstructionBlocks, refreshScanInstructionBlocks, refreshInstructionBlocks, editable
))
